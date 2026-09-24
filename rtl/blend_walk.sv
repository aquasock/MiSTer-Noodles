// Row/word walker for blit_blend: steps through the 64-bit DDRAM words that
// cover a width x height pixel rectangle, one row at a time.
//
// A row starting at byte address `row` covers lanes row[2] .. row[2]+width-1
// counted in 32-bit pixels from the row's first 64-bit word, so it spans
// (row[2] + width + 1) / 2 words. A step consumes `step_len` words of the
// current row (1 <= step_len <= left) as one burst. Each row change spends
// one setup cycle with `valid` low while the next row's alignment is
// derived.
//
// reverse walks each row from its last word towards its first, still
// issuing every burst in ascending address order; the caller reverses the
// pixels inside each burst (BLIT-008 horizontal mirroring). pitch_neg steps
// rows downwards in memory (vertical mirroring; `base` is then the last
// row). burst_addr, burst_lo and burst_hi describe the burst that a step of
// `step_len` would issue now: its first word's address and whether its
// lowest and highest pixel lanes belong to the rectangle.

module blend_walk (
    input  logic        clk,
    input  logic        reset,
    input  logic        start,
    input  logic [31:0] base,
    input  logic [15:0] pitch,
    input  logic        pitch_neg,
    input  logic        reverse,
    input  logic [15:0] width,
    input  logic [15:0] height,
    input  logic        step,
    input  logic [4:0]  step_len,
    output logic        valid,
    output logic [31:0] burst_addr,
    output logic [16:0] left,
    output logic        burst_lo,
    output logic        burst_hi,
    output logic        finished
);

    logic [31:0] row, addr;
    logic [15:0] rows_left;
    logic        setup, first, off, pitch_neg_r, reverse_r;

    wire [31:0] span = {24'd0, step_len - 5'd1, 3'b000};
    wire        ends_row = (left == {12'd0, step_len});
    // The row's first word holds its low edge lane; its last word the high.
    wire        first_word_lo = !off;
    wire        last_word_hi = (off == width[0]);
    // Index of the row's last word, from the next row's own alignment.
    wire [16:0] last_lane = {16'd0, row[2]} + {1'b0, width} - 17'd1;
    wire [16:0] last_word = last_lane >> 1;

    assign burst_addr = reverse_r ? addr - span : addr;
    assign burst_lo = reverse_r ? (!ends_row || first_word_lo) : (!first || first_word_lo);
    assign burst_hi = reverse_r ? (!first || last_word_hi) : (!ends_row || last_word_hi);

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
            pitch_neg_r <= 1'b0;
            reverse_r <= 1'b0;
        end else if (start) begin
            valid <= 1'b0;
            row <= base;
            rows_left <= height;
            pitch_neg_r <= pitch_neg;
            reverse_r <= reverse;
            finished <= (width == 16'd0) || (height == 16'd0);
            setup <= (width != 16'd0) && (height != 16'd0);
        end else if (setup) begin
            setup <= 1'b0;
            valid <= 1'b1;
            off <= row[2];
            first <= 1'b1;
            left <= ({16'd0, row[2]} + {1'b0, width} + 17'd1) >> 1;
            // Last word of the row: the word holding lane row[2]+width-1.
            addr <= reverse_r ? {row[31:3], 3'b000} + {12'd0, last_word, 3'b000}
                              : {row[31:3], 3'b000};
        end else if (valid && step) begin
            first <= 1'b0;
            addr <= reverse_r ? addr - {24'd0, step_len, 3'b000}
                              : addr + {24'd0, step_len, 3'b000};
            left <= left - {12'd0, step_len};
            if (ends_row) begin
                valid <= 1'b0;
                rows_left <= rows_left - 16'd1;
                if (rows_left == 16'd1) begin
                    finished <= 1'b1;
                end else begin
                    row <= pitch_neg_r ? row - {16'd0, pitch} : row + {16'd0, pitch};
                    setup <= 1'b1;
                end
            end
        end
    end

endmodule
