// Registered request queues for the shared DDRAM Avalon-MM port.
//
// Client requests are captured before arbitration, so DDRAM_BUSY cannot
// change a client's valid/ready handshake and no client signal is fed back
// through the physical-bus grant. Reads retain ordered response metadata.
//
// DDR-007: the 64-bit read port gained an explicit rd64_len field so a
// client (blit_copy64/sprite_batch) can declare up front "read N contiguous
// words", issued as a single Avalon burst (ddram_burstcnt=N) instead of N
// separate burstcnt=1 commands. This is deliberately NOT after-the-fact
// contiguity detection over an already-queued run: this adapter drains its
// read queue combinationally as fast as a client can fill it, so a producer
// issuing one word per cycle never actually lets a multi-entry run build up
// for the adapter to discover -- only an explicit, atomic N-word request
// from the producer itself forms a real burst. The real DDR3 controller
// amortizes row-activation/CAS command overhead across a burst's beats,
// streaming N sequential words back after one accepted command with no
// further command required -- the same assumption aquasock/MiSTer-Raster's
// proven DDR arbiter (mpeg2_h262_ddram_arbiter.sv) already relies on.
// Scalar (32-bit) reads always have an implicit length of 1, unchanged from
// before.

module ddram_adapter (
    input  logic         clk,
    input  logic         reset,

    input  logic [31:0]  wr_addr,
    input  logic [31:0]  wr_data,
    input  logic         wr_en,
    output logic         wr_ready,
    input  logic [31:0]  wr64_addr,
    input  logic [63:0]  wr64_data,
    input  logic         wr64_en,
    output logic         wr64_ready,

    input  logic [31:0]  rd_addr,
    input  logic         rd_en,
    output logic         rd_ready,
    output logic [31:0]  rd_data,
    output logic         rd_valid,
    input  logic [31:0]  rd64_addr,
    input  logic         rd64_en,
    input  logic [7:0]   rd64_len,
    output logic         rd64_ready,
    output logic [63:0]  rd64_data,
    output logic         rd64_valid,

    output logic         ddram_clk,
    input  logic         ddram_busy,
    output logic [7:0]   ddram_burstcnt,
    output logic [28:0]  ddram_addr,
    input  logic [63:0]  ddram_dout,
    input  logic         ddram_dout_ready,
    output logic [63:0]  ddram_din,
    output logic [7:0]   ddram_be,
    output logic         ddram_we,
    output logic         ddram_rd,
    output logic         idle
);

    // DEPTH bounds both the descriptor queue (one entry per accepted
    // request, regardless of its word length) and the total number of
    // response words that may be outstanding across all queued descriptors
    // combined -- a single rd64 request may itself claim up to DEPTH words.
    localparam int DEPTH = 32;
    localparam int PTR_W = $clog2(DEPTH);
    localparam int MAX_BURST = DEPTH;

    logic [31:0] wr_addr_q [0:DEPTH-1];
    logic [63:0] wr_data_q [0:DEPTH-1];
    logic        wr_full_q [0:DEPTH-1];
    logic [PTR_W-1:0] wr_head, wr_tail;
    logic [PTR_W:0] wr_count;

    logic [31:0] rd_addr_q [0:DEPTH-1];
    logic        rd_is64_q [0:DEPTH-1];
    logic        rd_half_q [0:DEPTH-1];
    logic [7:0]  rd_len_q  [0:DEPTH-1];
    logic [PTR_W-1:0] rd_head, rd_tail;
    logic [PTR_W:0] rd_count;

    logic        rsp_is64_q [0:DEPTH-1];
    logic        rsp_half_q [0:DEPTH-1];
    logic [PTR_W-1:0] rsp_head, rsp_tail;
    logic [PTR_W:0] rsp_count;

    // DDR-007 fairness: a burst request can now keep rd_count non-zero for
    // long stretches (blit_copy64 immediately re-fills its FIFO the moment
    // any slot frees up), which would starve writes forever under the old
    // "read always wins whenever any read is queued" priority -- queued
    // writes would sit in wr_addr_q/wr_data_q indefinitely, never actually
    // reaching the DDRAM_WE/DDRAM_DIN pins. rr is a free-running toggle
    // that alternates which side wins the single shared command slot on
    // cycles where BOTH have pending work, guaranteeing every queued write
    // is issued within a bounded number of cycles regardless of how
    // continuously reads are being requested.
    logic rr;

    wire wr_fire   = wr_en && wr_ready;
    wire wr64_fire = wr64_en && wr64_ready;
    wire rd_fire   = rd_en && rd_ready;
    wire rd64_fire = rd64_en && rd64_ready;

    // Total response-word space already spoken for: words waiting to be
    // consumed (rsp_count) plus the declared lengths of descriptors already
    // queued but not yet issued. A new request may only be admitted if it
    // still fits within DEPTH once that full commitment is counted -- not
    // just against the current rsp_count -- so multiple in-flight
    // descriptors (of any length) can never collectively overrun the
    // response arrays.
    logic [8:0] pending_words;
    always_comb begin
        pending_words = 9'd0;
        for (int i = 0; i < MAX_BURST; i++) begin
            automatic logic [PTR_W-1:0] idx = rd_head + i[PTR_W-1:0];
            if (i < int'(rd_count))
                pending_words += rd_is64_q[idx] ? {1'b0, rd_len_q[idx]} : 9'd1;
        end
    end
    wire [8:0] rsp_committed = 9'(rsp_count) + pending_words;

    assign wr_ready   = (wr_count < DEPTH);
    assign wr64_ready = (wr_count < DEPTH);
    assign rd_ready   = (rd_count < DEPTH) && (rsp_committed + 9'd1 <= 9'(DEPTH));
    assign rd64_ready = (rd_count < DEPTH) &&
                        (rsp_committed + {1'b0, rd64_len} <= 9'(DEPTH));

    wire [7:0] head_len = (rd_count != 0 && rd_is64_q[rd_head]) ? rd_len_q[rd_head] : 8'd1;
    wire want_read = (rd_count != 0);
    wire want_write = (wr_count != 0);
    wire read_issue = want_read && !ddram_busy && (!want_write || rr);
    wire write_issue = want_write && !ddram_busy && (!want_read || !rr);
    wire read_rsp = ddram_dout_ready && (rsp_count != 0);

    assign ddram_clk = clk;
    // A read command's burstcnt spans head_len contiguous words -- 1 for a
    // scalar read or any 64-bit request that declared no extra length --
    // and the real Avalon-MM target auto-increments its own address and
    // streams that many beats back with no further command from this
    // adapter. Writes are always single-beat.
    assign ddram_burstcnt = read_issue ? head_len : 8'd1;

    assign ddram_rd = read_issue;
    assign ddram_we = write_issue;
    assign ddram_addr = read_issue ? rd_addr_q[rd_head][31:3] :
                        wr_count != 0 ? wr_addr_q[wr_head][31:3] : 29'b0;
    assign ddram_be = write_issue ? (wr_full_q[wr_head] ? 8'hff :
                                     (wr_addr_q[wr_head][2] ? 8'hf0 : 8'h0f)) : 8'b0;
    assign ddram_din = write_issue ? (wr_full_q[wr_head] ? wr_data_q[wr_head] :
                                      (wr_addr_q[wr_head][2] ?
                                       {wr_data_q[wr_head][31:0], 32'b0} :
                                       {32'b0, wr_data_q[wr_head][31:0]})) : 64'b0;
    assign idle = (wr_count == 0) && (rd_count == 0) &&
                  (rsp_count == 0) && !ddram_busy;

    assign rd_valid = read_rsp && !rsp_is64_q[rsp_head];
    assign rd64_valid = read_rsp && rsp_is64_q[rsp_head];
    assign rd_data = rsp_half_q[rsp_head] ? ddram_dout[63:32] : ddram_dout[31:0];
    assign rd64_data = ddram_dout;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            rr <= 1'b0;
            wr_head <= 0;
            wr_tail <= 0;
            wr_count <= 0;
            rd_head <= 0;
            rd_tail <= 0;
            rd_count <= 0;
            rsp_head <= 0;
            rsp_tail <= 0;
            rsp_count <= 0;
        end else begin
            rr <= !rr;
            if (wr_fire || wr64_fire) begin
                wr_addr_q[wr_tail] <= wr64_fire ? wr64_addr : wr_addr;
                wr_data_q[wr_tail] <= wr64_fire ? wr64_data : {32'b0, wr_data};
                wr_full_q[wr_tail] <= wr64_fire;
                wr_tail <= wr_tail + 1'b1;
            end
            if (write_issue)
                wr_head <= wr_head + 1'b1;
            case ({wr_fire || wr64_fire, write_issue})
                2'b10: wr_count <= wr_count + 1'b1;
                2'b01: wr_count <= wr_count - 1'b1;
                default: ;
            endcase

            if (rd_fire || rd64_fire) begin
                rd_addr_q[rd_tail] <= rd64_fire ? rd64_addr : rd_addr;
                rd_is64_q[rd_tail] <= rd64_fire;
                rd_half_q[rd_tail] <= rd64_fire ? 1'b0 :
                                      (rd_addr[2]);
                rd_len_q[rd_tail] <= rd64_fire ? rd64_len : 8'd1;
                rd_tail <= rd_tail + 1'b1;
            end
            if (read_issue)
                rd_head <= rd_head + 1'b1;
            case ({rd_fire || rd64_fire, read_issue})
                2'b10: rd_count <= rd_count + 1'b1;
                2'b01: rd_count <= rd_count - 1'b1;
                default: ;
            endcase

            if (read_issue) begin
                for (int i = 0; i < MAX_BURST; i++) begin
                    if (i < int'(head_len)) begin
                        rsp_is64_q[rsp_tail + i[PTR_W-1:0]] <= rd_is64_q[rd_head];
                        rsp_half_q[rsp_tail + i[PTR_W-1:0]] <= rd_half_q[rd_head];
                    end
                end
                rsp_tail <= rsp_tail + head_len[PTR_W-1:0];
            end
            if (read_rsp)
                rsp_head <= rsp_head + 1'b1;
            // head_len is at most DEPTH, which fits in rsp_count's own
            // width without truncation -- unlike the tail-pointer advance
            // above, this accumulator needs the untruncated magnitude, not
            // a mod-DEPTH wraparound.
            rsp_count <= rsp_count + (read_issue ? (PTR_W+1)'(head_len) : (PTR_W+1)'(0))
                                    - (read_rsp ? (PTR_W+1)'(1) : (PTR_W+1)'(0));
        end
    end

endmodule
