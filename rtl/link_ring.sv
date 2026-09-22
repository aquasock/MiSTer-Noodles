// LINK: polls a host-built ring buffer in shared DDR3 and dispatches queued
// commands to CMDQ. Polls write_ptr only while CMDQ is idle (cmd_ready) --
// this keeps DDR-003's single-outstanding-read assumption valid without
// needing real arbitration against blit_copy's reads, and DDR-004
// established polling doesn't contend with video scan-out bandwidth anyway.
//
// DRAM content is not reset by an FPGA reset -- whatever was last written to
// HEADER_ADDR persists across a core reload. Without initializing it,
// write_ptr could read back as arbitrary garbage that never equals
// read_ptr's reset value of 0, causing a fetch and dispatch of a garbage
// command before the host ever touches the ring. INIT_WPTR/INIT_RPTR write
// both pointers to a known 0/0 (empty) state before any polling begins, so
// the host can start producing at any time after boot and always finds a
// well-defined starting point.
//
// ai/core-reference.md LINK-002 defines the ring's memory layout;
// LINK-003 defines this polling/dispatch protocol.

module link_ring #(
    parameter logic [31:0] HEADER_ADDR    = 32'h3002_0000,  // write_ptr at +0, read_ptr at +8
    parameter logic [31:0] SLOT_BASE_ADDR = 32'h3002_1000,
    parameter int          RING_SLOTS     = 64               // must be a power of 2
) (
    input  logic clk,
    input  logic reset,

    // generic read port
    output logic [31:0] rd_addr,
    output logic         rd_en,
    output logic         rd_active,  // high across the *_REQ/*_WAIT pair, not just *_REQ
    input  logic         rd_ready,
    input  logic [31:0]  rd_data,
    input  logic         rd_valid,

    // generic write port (read_ptr writeback only)
    output logic [31:0] wr_addr,
    output logic [31:0] wr_data,
    output logic         wr_en,
    input  logic         wr_ready,

    // CMDQ front end
    output logic [255:0] cmd_data,
    output logic          cmd_valid,
    input  logic          cmd_ready
);

    localparam int SLOT_INDEX_WIDTH = $clog2(RING_SLOTS);

    typedef enum logic [3:0] {
        INIT_WPTR, INIT_RPTR, IDLE, POLL_REQ, POLL_WAIT, FETCH_REQ, FETCH_WAIT, DISPATCH, WRITE_BACK
    } state_t;
    state_t state;

    logic [SLOT_INDEX_WIDTH-1:0] read_ptr;
    logic [2:0]                  word_idx;   // 0..7 across the 32-byte slot
    logic [255:0]                slot_reg;

    wire [31:0] slot_word_addr =
        SLOT_BASE_ADDR + (32'(read_ptr) << 5) + {27'd0, word_idx, 2'b00};
    wire [SLOT_INDEX_WIDTH-1:0] next_read_ptr = read_ptr + 1'b1;

    // Explicit width-safe word_idx*32 (bit offset into slot_reg), matching
    // slot_word_addr's own concatenation-based word_idx*4 above rather than
    // a raw multiply inside an indexed part-select's base expression.
    wire [7:0] slot_bit_offset = {word_idx, 5'b00000};

    // rd_addr must stay pinned to the address that was actually requested
    // for as long as a response can still be pending -- i.e. across the
    // *_REQ/*_WAIT pair together, not just during *_REQ. Getting this wrong
    // makes the adapter's byte-half-select use a different (stale) address
    // than the one the read was issued against once the requester moves to
    // its WAIT state.
    //
    // rd_active exists for the SAME reason but one level up: Noodles.sv's
    // read-port mux between link_ring and blit_copy previously keyed its
    // selector on rd_en alone, which drops as soon as the request is
    // accepted (during *_REQ only) -- so by the time rd_valid actually
    // arrives (during *_WAIT), the mux had already fallen through to
    // blit_copy's idle address (0, bit[2]=0), making the shared
    // ddram_adapter select the WRONG half of the 64-bit DDRAM word for
    // link's own pending response. This is exactly how a link-pushed
    // SOLID_FILL's dst_addr field was observed reading back as opcode's own
    // raw value (1) on real hardware: word_idx=1 (dst_addr, upper half of
    // the same aligned word as word_idx=0/opcode) got the lower half
    // instead. rd_active spans the *_REQ/*_WAIT pair so the mux can stay
    // pinned to link_ring for as long as ITS response can still be pending,
    // mirroring rd_addr's own pinning above.
    assign rd_en     = (state == POLL_REQ) || (state == FETCH_REQ);
    assign rd_active = (state == POLL_REQ) || (state == POLL_WAIT) || (state == FETCH_REQ) || (state == FETCH_WAIT);
    assign rd_addr   = (state == POLL_REQ || state == POLL_WAIT) ? HEADER_ADDR : slot_word_addr;

    // read_ptr is already advanced by the time WRITE_BACK runs (DISPATCH's
    // transition updates it), so wr_data is simply the current register --
    // NOT next_read_ptr again, which would double-advance.
    assign wr_en   = (state == INIT_WPTR) || (state == INIT_RPTR) || (state == WRITE_BACK);
    assign wr_addr = (state == INIT_WPTR) ? HEADER_ADDR : HEADER_ADDR + 32'd8;
    assign wr_data = (state == INIT_WPTR) || (state == INIT_RPTR) ? 32'd0 : 32'(read_ptr);

    assign cmd_valid = (state == DISPATCH);
    assign cmd_data  = slot_reg;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state    <= INIT_WPTR;
            read_ptr <= '0;
            word_idx <= '0;
            slot_reg <= '0;
        end else begin
            unique case (state)
                INIT_WPTR: begin
                    if (wr_en && wr_ready) state <= INIT_RPTR;
                end

                INIT_RPTR: begin
                    if (wr_en && wr_ready) state <= IDLE;
                end

                IDLE: begin
                    if (cmd_ready) state <= POLL_REQ;
                end

                POLL_REQ: begin
                    if (rd_en && rd_ready) state <= POLL_WAIT;
                end

                POLL_WAIT: begin
                    if (rd_valid) begin
                        if (rd_data[SLOT_INDEX_WIDTH-1:0] == read_ptr) begin
                            state <= IDLE;  // nothing new queued
                        end else begin
                            word_idx <= 3'd0;
                            state    <= FETCH_REQ;
                        end
                    end
                end

                FETCH_REQ: begin
                    if (rd_en && rd_ready) state <= FETCH_WAIT;
                end

                FETCH_WAIT: begin
                    if (rd_valid) begin
                        slot_reg[slot_bit_offset +: 32] <= rd_data;
                        if (word_idx == 3'd7) begin
                            state <= DISPATCH;
                        end else begin
                            word_idx <= word_idx + 3'd1;
                            state    <= FETCH_REQ;
                        end
                    end
                end

                DISPATCH: begin
                    if (cmd_valid && cmd_ready) begin
                        read_ptr <= next_read_ptr;
                        state    <= WRITE_BACK;
                    end
                end

                WRITE_BACK: begin
                    if (wr_en && wr_ready) state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
