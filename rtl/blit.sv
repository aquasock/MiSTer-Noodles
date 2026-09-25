// BLIT: raster/draw unit. v1 implements SOLID_FILL only -- write a constant
// pixel value across a width x height rectangle of a destination surface,
// one pixel per accepted cycle on a generic byte-addressed write port.
//
// ai/core-reference.md BLIT-002 defines the field semantics this module
// implements.

module blit #(
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
    input  logic [15:0]           width,
    input  logic [15:0]           height,
    input  logic [DATA_WIDTH-1:0] color,

    output logic                  busy,
    output logic                  done,   // one-cycle pulse

    // generic pixel write port
    output logic [ADDR_WIDTH-1:0] wr_addr,
    output logic [DATA_WIDTH-1:0] wr_data,
    output logic                  wr_en,
    input  logic                  wr_ready
    ,output logic [ADDR_WIDTH-1:0] wr64_addr,
    output logic [63:0] wr64_data,
    output logic wr64_en,
    input logic wr64_ready
);

    typedef enum logic [1:0] {IDLE, RUN, FINISH} state_t;
    state_t state;

    // The write address and the pixels left in the row are kept as running
    // registers so the write port's address and pair decision come straight
    // from registers rather than from row_addr + col * 4 and col compares.
    // A row pairs pixels only when its start is 8-byte aligned, as before.
    logic [ADDR_WIDTH-1:0] row_addr, cur_addr;
    logic [15:0]           remain, rows_left;
    logic                  row_aligned;

    wire pixel_valid = (state == RUN);
    wire pixel_fire  = pixel_valid && wr_ready;
    wire pair_valid = pixel_valid && row_aligned && !cur_addr[2] && remain >= 16'd2;
    wire pair_fire = pair_valid && wr64_ready;

    wire row_end  = pair_fire ? (remain == 16'd2) : (remain == 16'd1);
    wire last_row = (rows_left == 16'd1);
    wire [ADDR_WIDTH-1:0] next_row_addr = row_addr + ADDR_WIDTH'(dst_pitch);

    assign wr_addr = cur_addr;
    assign wr_data = color;
    assign wr_en   = pixel_valid && !pair_valid;
    assign wr64_addr = cur_addr;
    assign wr64_data = {color, color};
    assign wr64_en = pair_valid;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state       <= IDLE;
            busy        <= 1'b0;
            done        <= 1'b0;
            row_addr    <= '0;
            cur_addr    <= '0;
            remain      <= '0;
            rows_left   <= '0;
            row_aligned <= 1'b0;
        end else begin
            done <= 1'b0;

            unique case (state)
                IDLE: begin
                    if (start && width != 16'd0 && height != 16'd0) begin
                        busy        <= 1'b1;
                        row_addr    <= dst_addr;
                        cur_addr    <= dst_addr;
                        remain      <= width;
                        rows_left   <= height;
                        row_aligned <= !dst_addr[2];
                        state       <= RUN;
                    end
                end

                RUN: begin
                    if (pair_fire || pixel_fire) begin
                        if (row_end) begin
                            if (last_row) begin
                                state <= FINISH;
                            end else begin
                                rows_left   <= rows_left - 16'd1;
                                row_addr    <= next_row_addr;
                                cur_addr    <= next_row_addr;
                                remain      <= width;
                                row_aligned <= !next_row_addr[2];
                            end
                        end else begin
                            cur_addr <= cur_addr + (pair_fire ? ADDR_WIDTH'(8) : ADDR_WIDTH'(4));
                            remain   <= remain - (pair_fire ? 16'd2 : 16'd1);
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
