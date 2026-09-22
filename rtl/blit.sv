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
);

    typedef enum logic [1:0] {IDLE, RUN, FINISH} state_t;
    state_t state;

    logic [15:0]           col, row;
    logic [ADDR_WIDTH-1:0] row_addr;

    wire pixel_valid = (state == RUN);
    wire pixel_fire  = pixel_valid && wr_ready;

    wire last_col = (col == width  - 16'd1);
    wire last_row = (row == height - 16'd1);

    assign wr_addr = row_addr + ADDR_WIDTH'(col) * BYTES_PER_PIXEL;
    assign wr_data = color;
    assign wr_en   = pixel_valid;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state    <= IDLE;
            busy     <= 1'b0;
            done     <= 1'b0;
            col      <= '0;
            row      <= '0;
            row_addr <= '0;
        end else begin
            done <= 1'b0;

            unique case (state)
                IDLE: begin
                    if (start && width != 16'd0 && height != 16'd0) begin
                        busy     <= 1'b1;
                        col      <= 16'd0;
                        row      <= 16'd0;
                        row_addr <= dst_addr;
                        state    <= RUN;
                    end
                end

                RUN: begin
                    if (pixel_fire) begin
                        if (last_col) begin
                            col <= 16'd0;
                            if (last_row) begin
                                state <= FINISH;
                            end else begin
                                row      <= row + 16'd1;
                                row_addr <= row_addr + ADDR_WIDTH'(dst_pitch);
                            end
                        end else begin
                            col <= col + 16'd1;
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
