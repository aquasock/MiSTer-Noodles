// Row/word walker for blit_blend: steps through the 64-bit DDRAM words that
// cover a width x height pixel rectangle, one row at a time.
//
// A row starting at byte address `row` covers lanes row[2] .. row[2]+width-1
// counted in 32-bit pixels from the row's first 64-bit word, so it spans
// (row[2] + width + 1) / 2 words. Each step consumes the next burst of the
// current row: at most BURST words and never crossing the row. A row change
// spends one setup cycle with `valid` low while the next row's alignment is
// derived.
//
// reverse walks each row from its last word towards its first, still
// issuing every burst in ascending address order; the caller reverses the
// pixels inside each burst (BLIT-008 horizontal mirroring). pitch_neg steps
// rows downwards in memory (vertical mirroring; `base` is then the last
// row).
//
// The next burst is prepared into registers one cycle ahead: its first
// word's address, word count, in-rectangle pixel count and whether its
// lowest and highest pixel lanes belong to the rectangle. `valid` is low for
// the cycle after each step while that preparation catches up, so callers
// act only on registered values and no state-to-request path spans a cycle.

module blend_walk #(
    parameter int BURST = 8
) (
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
    output logic        valid,
    output logic [31:0] burst_addr,
    output logic [4:0]  burst_len,
    output logic [5:0]  burst_px,
    output logic        burst_lo,
    output logic        burst_hi,
    output logic        finished
);

    logic [31:0] row, addr;
    logic [16:0] left;
    logic [15:0] rows_left;
    logic        in_row, setup, first, off, pitch_neg_r, reverse_r, fresh;

    // Preparation from the current state.
    wire [4:0]  len = (left < 17'(BURST)) ? left[4:0] : 5'(BURST);
    wire        ends_row = (left <= 17'(BURST));
    wire        first_word_lo = !off;
    wire        last_word_hi = (off == width[0]);
    wire        lo = reverse_r ? (!ends_row || first_word_lo) : (!first || first_word_lo);
    wire        hi = reverse_r ? (!first || last_word_hi) : (!ends_row || last_word_hi);
    // Index of the row's last word, from the next row's own alignment.
    wire [16:0] last_lane = {16'd0, row[2]} + {1'b0, width} - 17'd1;
    wire [16:0] last_word = last_lane >> 1;

    assign valid = in_row && fresh;

    always_ff @(posedge clk) begin
        burst_len <= len;
        burst_addr <= reverse_r ? addr - {24'd0, len - 5'd1, 3'b000} : addr;
        burst_lo <= lo;
        burst_hi <= hi;
        burst_px <= {len, 1'b0} - {5'd0, !lo} - {5'd0, !hi};
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            in_row <= 1'b0;
            fresh <= 1'b0;
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
        end else begin
            // Registered burst values lag every state change by one cycle.
            fresh <= !(start || setup || (valid && step));
            if (start) begin
                in_row <= 1'b0;
                row <= base;
                rows_left <= height;
                pitch_neg_r <= pitch_neg;
                reverse_r <= reverse;
                finished <= (width == 16'd0) || (height == 16'd0);
                setup <= (width != 16'd0) && (height != 16'd0);
            end else if (setup) begin
                setup <= 1'b0;
                in_row <= 1'b1;
                off <= row[2];
                first <= 1'b1;
                left <= ({16'd0, row[2]} + {1'b0, width} + 17'd1) >> 1;
                // Last word of the row: the word holding lane row[2]+width-1.
                addr <= reverse_r ? {row[31:3], 3'b000} + {12'd0, last_word, 3'b000}
                                  : {row[31:3], 3'b000};
            end else if (valid && step) begin
                first <= 1'b0;
                addr <= reverse_r ? addr - {24'd0, burst_len, 3'b000}
                                  : addr + {24'd0, burst_len, 3'b000};
                left <= left - {12'd0, burst_len};
                if (left == {12'd0, burst_len}) begin
                    in_row <= 1'b0;
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
    end

endmodule
