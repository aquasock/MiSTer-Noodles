// Single-clock SDRAM read adapter (SDR-008). Accepts one rd64 burst and
// emits one response per 64-bit word, assembled from four consecutive
// 16-bit controller reads. Addresses are byte-addressed and 8-byte aligned.
// The normal-port request remains asserted until the controller accepts
// it, including refresh/copy-port busy windows with ready still high.
module sdram_adapter #(
    parameter int ADDR_WIDTH = 32
) (
    input  logic                  clk,
    input  logic                  reset,

    input  logic [ADDR_WIDTH-1:0] rd64_addr,
    input  logic                  rd64_en,
    input  logic [7:0]            rd64_len,   // sequential single-word round trips; see header
    output logic                  rd64_ready,
    output logic [63:0]           rd64_data,
    output logic                  rd64_valid,

    output logic                  sd_sel,
    output logic [26:1]           sd_addr,
    input  logic [15:0]           sd_dout,
    output logic                  sd_rd,
    input  logic                  sd_ready
);

    // ---- Burst-to-sequential-reads state machine ----
    // See header comment: a length-N rd64 request is accepted ONCE (the
    // client never re-strobes rd64_en mid-burst) and must then produce N
    // separate rd64_valid pulses, one per contiguous 64-bit word, with
    // rd64_ready held low until the whole burst has round-tripped.
    typedef enum logic {A_IDLE, A_BURST} a_state_t;
    a_state_t              a_state;
    logic [ADDR_WIDTH-1:0] a_next_addr;
    logic [7:0]            a_words_left;

    logic [ADDR_WIDTH-1:0] a_addr_in;
    logic                  a_en_in;
    logic                  a_ready_out;
    logic [63:0]           a_data_out;
    logic                  a_valid_out;

    wire [7:0] a_req_len = (rd64_len == 8'd0) ? 8'd1 : rd64_len;
    // Accept only when the previous word sequence has finished.
    wire a_ready_for_client = (a_state == A_IDLE) && a_ready_out;

    assign a_addr_in  = (a_state == A_IDLE) ? rd64_addr : a_next_addr;
    assign a_en_in    = (a_state == A_IDLE) ? (rd64_en && a_ready_for_client)
                                             : (a_words_left != 8'd0);
    assign rd64_ready = a_ready_for_client;
    assign rd64_data  = a_data_out;
    assign rd64_valid = a_valid_out;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            a_state      <= A_IDLE;
            a_next_addr  <= '0;
            a_words_left <= '0;
        end else begin
            case (a_state)
                A_IDLE: if (rd64_en && a_ready_for_client) begin
                    if (a_req_len > 8'd1) begin
                        a_next_addr  <= rd64_addr + 32'd8;
                        a_words_left <= a_req_len - 8'd1;
                        a_state      <= A_BURST;
                    end
                    // Length one stays in A_IDLE; the read sequencer
                    // blocks another acceptance until it finishes.
                end
                A_BURST: if (a_en_in && a_ready_out) begin
                    if (a_words_left == 8'd1) begin
                        a_words_left <= 8'd0;
                        a_state      <= A_IDLE;
                    end else begin
                        a_words_left <= a_words_left - 8'd1;
                        a_next_addr  <= a_next_addr + 32'd8;
                    end
                end
                default: a_state <= A_IDLE;
            endcase
        end
    end

    logic [ADDR_WIDTH-1:0] b_addr_out;
    logic                  b_start_out;
    logic [63:0]           b_data_in;
    logic                  b_done_in;

    // ---- 4-step 16-bit read sequencer ----
    typedef enum logic [2:0] {
        SEQ_IDLE,
        SEQ_ISSUE,
        SEQ_WAIT_READY_HIGH,
        SEQ_DONE
    } seq_state_t;

    seq_state_t  seq_state;
    assign a_ready_out = (seq_state == SEQ_IDLE) && !b_done_in;
    assign b_start_out = a_en_in && a_ready_out;
    assign b_addr_out = a_addr_in;
    assign a_data_out = b_data_in;
    assign a_valid_out = b_done_in;
    // word_base is the 16-bit-word address of this request's first
    // sub-word: since b_addr_out is a byte address and sdram.sv's own
    // addr[26:1] already IS the byte address with bit 0 dropped (16-bit
    // mode), word_base == b_addr_out[26:1] directly -- no separate
    // multiply/shift needed, only a required 8-byte (b_addr[2:0]==0)
    // alignment on the caller's part. Sub-word i then simply sits at
    // word_base + i, since consecutive 16-bit-word addresses are
    // consecutive 2-byte chunks.
    logic [25:0] word_base;
    logic [1:0]  word_idx;    // which of the 4 16-bit sub-words we're on
    logic [63:0] assembled;

    wire [25:0] sd_addr_word = word_base + {24'b0, word_idx};
    assign sd_addr = sd_addr_word;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            seq_state  <= SEQ_IDLE;
            word_base  <= '0;
            word_idx   <= 2'd0;
            assembled  <= '0;
            b_data_in  <= '0;
            b_done_in  <= 1'b0;
            sd_sel     <= 1'b0;
            sd_rd      <= 1'b0;
        end else begin
            b_done_in <= 1'b0;
            case (seq_state)
                SEQ_IDLE: begin
                    sd_sel <= 1'b0;
                    sd_rd  <= 1'b0;
                    if (b_start_out) begin
                        word_base <= b_addr_out[26:1];
                        word_idx  <= 2'd0;
                        seq_state <= SEQ_ISSUE;
                    end
                end
                SEQ_ISSUE: begin
                    // Hold sel&rd asserted as a LEVEL, not a one-cycle
                    // pulse, until sd_ready is actually observed to drop
                    // -- that is sdram.sv's only real acknowledgement
                    // that our request landed while it happened to be in
                    // its own STATE_IDLE. A blind one-cycle pulse is NOT
                    // safe: sdram.sv also silently ignores sel&rd for
                    // several cycles during its own periodic auto-refresh
                    // sequence (STATE_RFSH + 5 IDLE_x cycles, driven
                    // independently by Noodles.sv's free-running refresh
                    // toggle) and during the loader's copy-port bursts
                    // (STATE_WAITCP/STATE_CP) -- and, critically, `ready`
                    // does NOT drop during either of those windows (it
                    // only drops for real reads/writes), so a request
                    // that lands there would vanish with zero visible
                    // sign of rejection. This was a real bug (hung
                    // sprite_batch on actual hardware within the first
                    // second, though never observed in sim's mock model,
                    // which always accepts sel&rd immediately) --
                    // holding the level until !sd_ready is confirmed
                    // fixes it unconditionally, regardless of how long
                    // the controller happens to be busy elsewhere.
                    sd_sel <= 1'b1;
                    sd_rd  <= 1'b1;
                    if (!sd_ready) begin
                        sd_sel    <= 1'b0;
                        sd_rd     <= 1'b0;
                        seq_state <= SEQ_WAIT_READY_HIGH;
                    end
                end
                SEQ_WAIT_READY_HIGH: begin
                    if (sd_ready) begin
                        case (word_idx)
                            2'd0: assembled[15:0]  <= sd_dout;
                            2'd1: assembled[31:16] <= sd_dout;
                            2'd2: assembled[47:32] <= sd_dout;
                            2'd3: assembled[63:48] <= sd_dout;
                        endcase
                        if (word_idx == 2'd3) begin
                            seq_state <= SEQ_DONE;
                        end else begin
                            word_idx  <= word_idx + 1'b1;
                            seq_state <= SEQ_ISSUE;
                        end
                    end
                end
                SEQ_DONE: begin
                    b_data_in <= assembled;
                    b_done_in <= 1'b1;
                    seq_state <= SEQ_IDLE;
                end
                default: seq_state <= SEQ_IDLE;
            endcase
        end
    end

endmodule
