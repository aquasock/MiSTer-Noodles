// BLIT_COPY / BLIT_COPY_KEY: copies a width x height rectangle from a
// source surface to a destination surface, 4 bytes/pixel, no scale/blend/
// format conversion. Separate module from rtl/blit.sv (SOLID_FILL) rather
// than a merged FSM -- keeps the already-proven fill engine untouched. Per
// pixel: issue a read at the source address, wait for the one word, write
// it to the destination (unless key_enable and it matches key_value, in
// which case the destination pixel is left untouched -- colorkey
// transparency, BLIT-006), advance. Never more than one outstanding read.
//
// key_enable/key_value distinguish CMDQ-001's two BLIT_COPY-family
// opcodes: CMDQ latches key_enable=0 for plain BLIT_COPY (opcode 2) and
// key_enable=1/key_value=the command's color field for BLIT_COPY_KEY
// (opcode 3) -- this module doesn't know or care which opcode dispatched
// it, only whether keying is on.
//
// ai/core-reference.md BLIT-003 defines plain BLIT_COPY's field semantics;
// BLIT-006 defines BLIT_COPY_KEY's; DDR-003 defines the generic read port
// protocol.

module blit_copy #(
    parameter int ADDR_WIDTH      = 32,
    parameter int DATA_WIDTH      = 32,
    parameter int BYTES_PER_PIXEL = 4
) (
    input  logic                  clk,
    input  logic                  reset,

    // command in -- pulse start for one cycle with the fields below held
    // stable until busy deasserts
    input  logic                  start,
    input  logic [ADDR_WIDTH-1:0] dst_addr,
    input  logic [15:0]           dst_pitch,
    input  logic [ADDR_WIDTH-1:0] src_addr,
    input  logic [15:0]           src_pitch,
    input  logic [15:0]           width,
    input  logic [15:0]           height,
    input  logic                  key_enable,
    input  logic [DATA_WIDTH-1:0] key_value,

    output logic                  busy,
    output logic                  done,   // one-cycle pulse

    // generic read port
    output logic [ADDR_WIDTH-1:0] rd_addr,
    output logic                  rd_en,
    input  logic                  rd_ready,
    input  logic [DATA_WIDTH-1:0] rd_data,
    input  logic                  rd_valid,

    // generic write port
    output logic [ADDR_WIDTH-1:0] wr_addr,
    output logic [DATA_WIDTH-1:0] wr_data,
    output logic                  wr_en,
    input  logic                  wr_ready
);

    typedef enum logic [2:0] {IDLE, READ_REQ, READ_WAIT, WRITE_REQ, FINISH} state_t;
    state_t state;

    logic [15:0]           col, row;
    logic [ADDR_WIDTH-1:0] src_row_addr, dst_row_addr;
    logic [DATA_WIDTH-1:0] pixel;
    logic                  key_enable_r;  // latched at start, held stable across the whole op
    logic [DATA_WIDTH-1:0] key_value_r;

    wire [ADDR_WIDTH-1:0] src_pixel_addr = src_row_addr + ADDR_WIDTH'(col) * BYTES_PER_PIXEL;
    wire [ADDR_WIDTH-1:0] dst_pixel_addr = dst_row_addr + ADDR_WIDTH'(col) * BYTES_PER_PIXEL;

    assign rd_addr = src_pixel_addr;
    assign rd_en   = (state == READ_REQ);

    assign wr_addr = dst_pixel_addr;
    assign wr_data = pixel;
    assign wr_en   = (state == WRITE_REQ);

    wire last_col   = (col == width  - 16'd1);
    wire last_row   = (row == height - 16'd1);
    wire key_match  = key_enable_r && (rd_data == key_value_r);

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state        <= IDLE;
            busy         <= 1'b0;
            done         <= 1'b0;
            col          <= '0;
            row          <= '0;
            src_row_addr <= '0;
            dst_row_addr <= '0;
            pixel        <= '0;
            key_enable_r <= 1'b0;
            key_value_r  <= '0;
        end else begin
            done <= 1'b0;

            unique case (state)
                IDLE: begin
                    if (start && width != 16'd0 && height != 16'd0) begin
                        busy         <= 1'b1;
                        col          <= 16'd0;
                        row          <= 16'd0;
                        src_row_addr <= src_addr;
                        dst_row_addr <= dst_addr;
                        key_enable_r <= key_enable;
                        key_value_r  <= key_value;
                        state        <= READ_REQ;
                    end
                end

                READ_REQ: begin
                    if (rd_en && rd_ready) state <= READ_WAIT;
                end

                READ_WAIT: begin
                    if (rd_valid) begin
                        pixel <= rd_data;
                        if (key_match) begin
                            // Skip the write -- same index-advance logic as
                            // WRITE_REQ's completion below, just reached
                            // without ever asserting wr_en for this pixel.
                            if (last_col) begin
                                col <= 16'd0;
                                if (last_row) begin
                                    state <= FINISH;
                                end else begin
                                    row          <= row + 16'd1;
                                    src_row_addr <= src_row_addr + ADDR_WIDTH'(src_pitch);
                                    dst_row_addr <= dst_row_addr + ADDR_WIDTH'(dst_pitch);
                                    state        <= READ_REQ;
                                end
                            end else begin
                                col   <= col + 16'd1;
                                state <= READ_REQ;
                            end
                        end else begin
                            state <= WRITE_REQ;
                        end
                    end
                end

                WRITE_REQ: begin
                    if (wr_en && wr_ready) begin
                        if (last_col) begin
                            col <= 16'd0;
                            if (last_row) begin
                                state <= FINISH;
                            end else begin
                                row          <= row + 16'd1;
                                src_row_addr <= src_row_addr + ADDR_WIDTH'(src_pitch);
                                dst_row_addr <= dst_row_addr + ADDR_WIDTH'(dst_pitch);
                                state        <= READ_REQ;
                            end
                        end else begin
                            col   <= col + 16'd1;
                            state <= READ_REQ;
                        end
                    end
                end

                FINISH: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
