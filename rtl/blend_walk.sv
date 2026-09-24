// Row/word walker for blit_blend: steps through the 64-bit DDRAM words that
// cover a width x height pixel rectangle, row by row, in address order.
//
// A row starting at byte address `row` covers lanes row[2] .. row[2]+width-1
// counted in 32-bit pixels from the row's first 64-bit word, so it spans
// (row[2] + width + 1) / 2 words. A step consumes `step_len` words of the
// current row (1 <= step_len <= left). Each row change spends one setup
// cycle with `valid` low while the next row's alignment is derived.
//
// lo_valid says whether the current word's low pixel lane belongs to the
// rectangle; end_hi_valid says whether the high lane of the row's LAST word
// does. A step never crosses a row, so these describe a burst's first and
// (when the burst ends the row) last word.

module blend_walk (
    input  logic        clk,
    input  logic        reset,
    input  logic        start,
    input  logic [31:0] base,
    input  logic [15:0] pitch,
    input  logic [15:0] width,
    input  logic [15:0] height,
    input  logic        step,
    input  logic [4:0]  step_len,
    output logic        valid,
    output logic [31:0] addr,
    output logic [16:0] left,
    output logic        lo_valid,
    output logic        end_hi_valid,
    output logic        finished
);

    logic [31:0] row;
    logic [15:0] rows_left;
    logic        setup, first, off;

    assign lo_valid = !(first && off);
    assign end_hi_valid = (off == width[0]);

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            valid <= 1'b0;
            setup <= 1'b0;
            finished <= 1'b1;
            row <= '0;
            rows_left <= '0;
            addr <= '0;
            left <= '0;
            first <= 1'b0;
            off <= 1'b0;
        end else if (start) begin
            valid <= 1'b0;
            row <= base;
            rows_left <= height;
            finished <= (width == 16'd0) || (height == 16'd0);
            setup <= (width != 16'd0) && (height != 16'd0);
        end else if (setup) begin
            setup <= 1'b0;
            valid <= 1'b1;
            off <= row[2];
            first <= 1'b1;
            addr <= {row[31:3], 3'b000};
            left <= ({16'd0, row[2]} + {1'b0, width} + 17'd1) >> 1;
        end else if (valid && step) begin
            first <= 1'b0;
            addr <= addr + {24'd0, step_len, 3'b000};
            left <= left - {12'd0, step_len};
            if (left == {12'd0, step_len}) begin
                valid <= 1'b0;
                rows_left <= rows_left - 16'd1;
                if (rows_left == 16'd1) begin
                    finished <= 1'b1;
                end else begin
                    row <= row + {16'd0, pitch};
                    setup <= 1'b1;
                end
            end
        end
    end

endmodule
