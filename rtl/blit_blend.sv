// Flagged-draw engine: BLIT_BLEND (opcode 7, BLIT-007) and flagged
// SPRITE_BATCH descriptors (BLIT-008). Applies RGBA modulation, then stores
// or straight-alpha blends a source rectangle onto a destination rectangle,
// optionally mirrored on either axis, over the burst-capable 64-bit DDRAM
// read port. sprite_batch also sends it unflagged copies that blit_copy64
// cannot perform (odd widths, sources not 8-byte aligned) as plain stores
// with identity modulation, including colour-keyed ones: a source pixel
// equal to key_value then leaves its destination pixel unchanged.
//
// Structure:
//   - Two blend_walk request walkers issue source and destination read
//     bursts (never crossing a row, at most BURST words). A burst is only
//     formed once space for every word it returns has been reserved, because
//     rd64_valid has no backpressure. Requests are registered before they
//     reach the adapter, and each accepted request pushes a tag recording
//     which stream it feeds, its start address and its edge-lane validity.
//   - Source bursts reserve exactly as many pixel FIFO slots as they carry
//     in-rectangle pixels. Their beats write those slots in order, or in
//     reverse order for horizontal mirroring (the walker then visits bursts
//     from the row's end); a burst's pixels become readable once its last
//     beat lands. Vertical mirroring walks source rows upwards from the
//     last. The FIFO thereby realigns source pixels to destination lanes
//     whatever the two rectangles' 8-byte alignments are. Destination beats
//     enter a word FIFO with their address and lane validity.
//   - Each destination word takes one or two pixels from the pixel FIFO and
//     passes through two blend_px lanes. A word with both lanes inside the
//     rectangle is written as a full 64-bit word; a row-edge word with one
//     lane inside is written as that 32-bit lane only, because with tightly
//     packed rows the other lane belongs to the neighbouring row, whose own
//     read of the shared word may predate this row's write. A word whose
//     result equals what was read is not written at all.
//   - Launches are credit-limited by the output FIFO, so the fixed-latency
//     pipeline never stalls.
// Source and destination rectangles must not overlap. Reads may pass queued
// writes inside ddram_adapter; distinct words make that harmless within a
// command, and callers wait for adapter idle between draws.

module blit_blend #(
    parameter int BURST = 8,
    parameter int PX_DEPTH = 32,
    parameter int DST_DEPTH = 16,
    parameter int OUT_DEPTH = 16,
    parameter int TAG_DEPTH = 16
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        start,
    input  logic [31:0] dst_addr,
    input  logic [15:0] dst_pitch,
    input  logic [31:0] src_addr,
    input  logic [15:0] src_pitch,
    input  logic [15:0] width,
    input  logic [15:0] height,
    input  logic [31:0] mod,
    input  logic        blend,
    // BLIT-009: explicit blend mode (descriptor flags 31:8) when mode_en,
    // otherwise BLEND or a plain store as selected by `blend`.
    input  logic        mode_en,
    input  logic [23:0] mode,
    input  logic        mirror_x,
    input  logic        mirror_y,
    input  logic        key_enable,
    input  logic [31:0] key_value,
    output logic        busy,
    output logic        done,

    output logic [31:0] rd64_addr,
    output logic        rd64_en,
    output logic [7:0]  rd64_len,
    input  logic        rd64_ready,
    input  logic [63:0] rd64_data,
    input  logic        rd64_valid,

    output logic [31:0] wr_addr,
    output logic [31:0] wr_data,
    output logic        wr_en,
    input  logic        wr_ready,

    output logic [31:0] wr64_addr,
    output logic [63:0] wr64_data,
    output logic        wr64_en,
    input  logic        wr64_ready
);

    localparam int PX_W  = $clog2(PX_DEPTH);
    localparam int DST_W = $clog2(DST_DEPTH);
    localparam int OUT_W = $clog2(OUT_DEPTH);
    localparam int TAG_W = $clog2(TAG_DEPTH);
    localparam int LATENCY = 7;  // blend_px
    // BLIT-009 presets, blend_px mode layout (aop, adf, asf, cop, cdf, csf,
    // reserved, single): SDL BLEND and NONE.
    localparam logic [23:0] MODE_BLEND = {3'd1, 4'd6, 4'd2, 3'd1, 4'd6, 4'd5, 2'b00};
    localparam logic [23:0] MODE_NONE  = {3'd1, 4'd1, 4'd2, 3'd1, 4'd1, 4'd2, 2'b00};

    // ---------------------------------------------------------------
    // Command capture. The mirrored source base needs a multiply, so the
    // walkers start three cycles after the command is accepted.
    logic [31:0] dst_r, src_r, src_base_r, mod_r;
    logic [31:0] src_span_r;
    logic [15:0] dst_pitch_r, src_pitch_r, width_r, height_r;
    logic        mirror_x_r, mirror_y_r, key_enable_r;
    logic [23:0] mode_r;
    logic [31:0] key_r;
    logic [1:0]  prep;
    logic        walk_start;

    // ---------------------------------------------------------------
    // Request walkers.
    logic        s_valid, d_valid, s_finished, d_finished;
    logic [31:0] s_addr, d_addr;
    logic [4:0]  s_len, d_len;
    // In-rectangle pixels carried by the source burst being formed.
    logic [5:0]  s_px;
    logic        s_lo, d_lo, s_hi, d_hi;
    logic        s_form, d_form;

    blend_walk #(.BURST(BURST)) src_walk (
        .clk(clk), .reset(reset), .start(walk_start),
        .base(src_base_r), .pitch(src_pitch_r), .pitch_neg(mirror_y_r), .reverse(mirror_x_r),
        .width(width_r), .height(height_r),
        .step(s_form),
        .valid(s_valid), .burst_addr(s_addr), .burst_len(s_len), .burst_px(s_px),
        .burst_lo(s_lo), .burst_hi(s_hi), .finished(s_finished)
    );

    blend_walk #(.BURST(BURST)) dst_walk (
        .clk(clk), .reset(reset), .start(walk_start),
        .base(dst_r), .pitch(dst_pitch_r), .pitch_neg(1'b0), .reverse(1'b0),
        .width(width_r), .height(height_r),
        .step(d_form),
        .valid(d_valid), .burst_addr(d_addr), .burst_len(d_len),
        /* verilator lint_off PINCONNECTEMPTY */
        .burst_px(),
        /* verilator lint_on PINCONNECTEMPTY */
        .burst_lo(d_lo), .burst_hi(d_hi), .finished(d_finished)
    );

    // ---------------------------------------------------------------
    // Reservations. px_res counts pixel FIFO slots in use or reserved by
    // outstanding source bursts; dst_res counts destination FIFO entries
    // plus outstanding destination words; out_res counts pipeline occupants
    // plus output FIFO entries.
    logic [PX_W:0]  px_res;
    logic [DST_W:0] dst_res;
    logic [OUT_W:0] out_res;
    logic [TAG_W:0] tag_count;

    // Registered request.
    logic        req_valid, req_is_dst, req_lo, req_hi;
    logic [4:0]  req_len;
    logic [5:0]  req_px;
    logic [PX_W-1:0] req_px_base;
    logic [31:0] req_addr;
    logic        prefer_dst;

    wire s_ok = s_valid && ({1'b0, px_res} + (PX_W+2)'(s_px) <= (PX_W+2)'(PX_DEPTH));
    wire d_ok = d_valid && ({1'b0, dst_res} + (DST_W+2)'(d_len) <= (DST_W+2)'(DST_DEPTH));
    wire can_form = busy && !req_valid && (tag_count < (TAG_W+1)'(TAG_DEPTH));
    assign d_form = can_form && d_ok && (!s_ok || prefer_dst);
    assign s_form = can_form && s_ok && !d_form;

    assign rd64_en = req_valid;
    assign rd64_addr = req_addr;
    assign rd64_len = {3'b000, req_len};
    wire req_fire = req_valid && rd64_ready;

    // ---------------------------------------------------------------
    // Tag FIFO: one entry per accepted burst, in adapter response order.
    // Kept in registers: as block RAM its unregistered read feeds the slot
    // arithmetic below and set the 100MHz critical path.
    (* ramstyle = "logic" *) logic [TAG_DEPTH-1:0] tag_is_dst, tag_lo, tag_hi;
    (* ramstyle = "logic" *) logic [4:0]  tag_len  [0:TAG_DEPTH-1];
    (* ramstyle = "logic" *) logic [5:0]  tag_px   [0:TAG_DEPTH-1];
    (* ramstyle = "logic" *) logic [PX_W-1:0] tag_px_base [0:TAG_DEPTH-1];
    (* ramstyle = "logic" *) logic [28:0] tag_word [0:TAG_DEPTH-1];
    logic [TAG_W-1:0] tag_head, tag_tail;
    logic [4:0]  beat;
    logic [5:0]  burst_px;   // pixels already placed from the current burst

    wire h_is_dst = tag_is_dst[tag_head];
    wire h_last   = (beat + 5'd1 == tag_len[tag_head]);
    wire beat_lo  = (beat != 5'd0) || tag_lo[tag_head];
    wire beat_hi  = !h_last || tag_hi[tag_head];
    wire src_beat = rd64_valid && !h_is_dst;
    wire dst_beat = rd64_valid && h_is_dst;

    // ---------------------------------------------------------------
    // Pixel FIFO: slots are allocated per burst at formation; beats fill
    // them in place (reversed when mirroring) and a burst is published when
    // complete. Up to two pops per cycle.
    logic [31:0] px_mem [0:PX_DEPTH-1];
    logic [PX_W-1:0] px_wp, px_rp;
    logic [PX_W:0]   px_count;

    wire [1:0] push_n = {1'b0, src_beat && beat_lo} + {1'b0, src_beat && beat_hi};
    wire [5:0] slot_lo_k = burst_px;
    wire [5:0] slot_hi_k = burst_px + {5'd0, beat_lo};
    wire [5:0] h_px = tag_px[tag_head];
    wire [PX_W-1:0] slot_lo = tag_px_base[tag_head] +
        PX_W'(mirror_x_r ? h_px - 6'd1 - slot_lo_k : slot_lo_k);
    wire [PX_W-1:0] slot_hi = tag_px_base[tag_head] +
        PX_W'(mirror_x_r ? h_px - 6'd1 - slot_hi_k : slot_hi_k);
    wire [31:0] px0 = px_mem[px_rp];
    wire [31:0] px1 = px_mem[px_rp + 1'b1];

    // Response stage: each beat, with its pixel slots and destination
    // metadata already decoded from the tag, is registered here and written
    // into the pixel or destination FIFO on the following cycle. Counters
    // that make those entries visible use this stage, so nothing can read
    // an entry before it is written.
    logic        r_src, r_dst, r_we_lo, r_we_hi, r_publish, r_dlo, r_dhi;
    logic [63:0] r_data;
    logic [PX_W-1:0] r_slot_lo, r_slot_hi;
    logic [5:0]  r_px;
    logic [28:0] r_word;

    // ---------------------------------------------------------------
    // Destination word FIFO.
    logic [63:0] dw_mem   [0:DST_DEPTH-1];
    logic [28:0] dw_word  [0:DST_DEPTH-1];
    logic [DST_DEPTH-1:0] dw_lo, dw_hi;
    logic [DST_W-1:0] dw_wp, dw_rp;
    logic [DST_W:0]   dw_count;

    wire       head_lo = dw_lo[dw_rp];
    wire       head_hi = dw_hi[dw_rp];
    wire [1:0] pop_n = {1'b0, head_lo} + {1'b0, head_hi};

    wire launch = (dw_count != 0) && ({1'b0, px_count} >= (PX_W+2)'(pop_n)) &&
                  (out_res < (OUT_W+1)'(OUT_DEPTH));
    wire [31:0] lane_src_lo = px0;
    wire [31:0] lane_src_hi = head_lo ? px1 : px0;

    // ---------------------------------------------------------------
    // Pixel lanes and sideband.
    logic        lo_out_valid;
    logic [31:0] lo_out, hi_out;
    logic [63:0] sb_dst  [0:LATENCY-1];
    logic [28:0] sb_word [0:LATENCY-1];
    logic [LATENCY-1:0] sb_lo, sb_hi;
    // Colour-keyed lanes keep their destination value like out-of-rectangle
    // lanes; the key is compared with the unmodulated source pixel.
    wire key_lo = key_enable_r && lane_src_lo == key_r;
    wire key_hi = key_enable_r && lane_src_hi == key_r;

    blend_px lane_lo (
        .clk(clk), .reset(reset), .in_valid(launch),
        .src(lane_src_lo), .dst(dw_mem[dw_rp][31:0]), .mod(mod_r), .mode(mode_r),
        .out_valid(lo_out_valid), .out(lo_out)
    );

    blend_px lane_hi (
        .clk(clk), .reset(reset), .in_valid(launch),
        .src(lane_src_hi), .dst(dw_mem[dw_rp][63:32]), .mod(mod_r), .mode(mode_r),
        /* verilator lint_off PINCONNECTEMPTY */
        .out_valid(),
        /* verilator lint_on PINCONNECTEMPTY */
        .out(hi_out)
    );

    wire [63:0] result = {sb_hi[LATENCY-1] ? hi_out : sb_dst[LATENCY-1][63:32],
                          sb_lo[LATENCY-1] ? lo_out : sb_dst[LATENCY-1][31:0]};
    wire result_write = lo_out_valid && (result != sb_dst[LATENCY-1]);
    wire result_skip  = lo_out_valid && !result_write;

    // ---------------------------------------------------------------
    // Output FIFO feeding the paired write port, or the scalar port for
    // single-lane edge words.
    logic [63:0] of_data [0:OUT_DEPTH-1];
    logic [28:0] of_word [0:OUT_DEPTH-1];
    logic [OUT_DEPTH-1:0] of_full, of_hi;
    logic [OUT_W-1:0] of_wp, of_rp;
    logic [OUT_W:0]   of_count;

    wire of_head_full = of_full[of_rp];
    assign wr64_en = (of_count != 0) && of_head_full;
    assign wr64_addr = {of_word[of_rp], 3'b000};
    assign wr64_data = of_data[of_rp];
    assign wr_en = (of_count != 0) && !of_head_full;
    assign wr_addr = {of_word[of_rp], of_hi[of_rp], 2'b00};
    assign wr_data = of_hi[of_rp] ? of_data[of_rp][63:32] : of_data[of_rp][31:0];
    wire wr_fire = (wr64_en && wr64_ready) || (wr_en && wr_ready);

    wire finished = busy && prep == 2'd0 && !walk_start && s_finished && d_finished &&
                    !req_valid && (tag_count == 0) && !r_src && !r_dst && (dw_count == 0) &&
                    (out_res == 0);

    // ---------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (req_fire) begin
            tag_is_dst[tag_tail] <= req_is_dst;
            tag_lo[tag_tail] <= req_lo;
            tag_hi[tag_tail] <= req_hi;
            tag_len[tag_tail] <= req_len;
            tag_px[tag_tail] <= req_px;
            tag_px_base[tag_tail] <= req_px_base;
            tag_word[tag_tail] <= req_addr[31:3];
        end
        r_data <= rd64_data;
        r_slot_lo <= slot_lo;
        r_slot_hi <= slot_hi;
        r_px <= h_px;
        r_word <= tag_word[tag_head] + {24'd0, beat};
        r_dlo <= beat_lo;
        r_dhi <= beat_hi;
        if (r_we_lo)
            px_mem[r_slot_lo] <= r_data[31:0];
        if (r_we_hi)
            px_mem[r_slot_hi] <= r_data[63:32];
        if (r_dst) begin
            dw_mem[dw_wp] <= r_data;
            dw_word[dw_wp] <= r_word;
            dw_lo[dw_wp] <= r_dlo;
            dw_hi[dw_wp] <= r_dhi;
        end
        sb_dst[0] <= dw_mem[dw_rp];
        sb_word[0] <= dw_word[dw_rp];
        sb_lo[0] <= head_lo && !key_lo;
        sb_hi[0] <= head_hi && !key_hi;
        for (int i = 1; i < LATENCY; i++) begin
            sb_dst[i] <= sb_dst[i-1];
            sb_word[i] <= sb_word[i-1];
            sb_lo[i] <= sb_lo[i-1];
            sb_hi[i] <= sb_hi[i-1];
        end
        if (result_write) begin
            // A word with only one written lane (row edge or colour key)
            // stores just that lane, never the other lane's stale read.
            of_data[of_wp] <= result;
            of_word[of_wp] <= sb_word[LATENCY-1];
            of_full[of_wp] <= sb_lo[LATENCY-1] && sb_hi[LATENCY-1];
            of_hi[of_wp] <= !sb_lo[LATENCY-1];
        end
        // Mirrored source base: src + (height - 1) * pitch, over two cycles.
        src_span_r <= {16'd0, height_r - 16'd1} * {16'd0, src_pitch_r};
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            busy <= 1'b0;
            done <= 1'b0;
            prep <= '0;
            walk_start <= 1'b0;
            dst_r <= '0; src_r <= '0; src_base_r <= '0; mod_r <= '0;
            dst_pitch_r <= '0; src_pitch_r <= '0;
            width_r <= '0; height_r <= '0;
            mode_r <= MODE_NONE; mirror_x_r <= 1'b0; mirror_y_r <= 1'b0;
            key_enable_r <= 1'b0; key_r <= '0;
            req_valid <= 1'b0;
            req_is_dst <= 1'b0; req_lo <= 1'b0; req_hi <= 1'b0;
            req_len <= '0; req_px <= '0; req_px_base <= '0; req_addr <= '0;
            prefer_dst <= 1'b1;
            px_res <= '0; dst_res <= '0; out_res <= '0;
            tag_count <= '0; tag_head <= '0; tag_tail <= '0; beat <= '0; burst_px <= '0;
            r_src <= 1'b0; r_dst <= 1'b0; r_we_lo <= 1'b0; r_we_hi <= 1'b0; r_publish <= 1'b0;
            px_wp <= '0; px_rp <= '0; px_count <= '0;
            dw_wp <= '0; dw_rp <= '0; dw_count <= '0;
            of_wp <= '0; of_rp <= '0; of_count <= '0;
        end else begin
            done <= 1'b0;
            walk_start <= 1'b0;
            if (start && !busy) begin
                busy <= 1'b1;
                prep <= 2'd3;
                dst_r <= dst_addr; src_r <= src_addr;
                dst_pitch_r <= dst_pitch; src_pitch_r <= src_pitch;
                width_r <= width; height_r <= height;
                mod_r <= mod;
                mode_r <= mode_en ? mode : blend ? MODE_BLEND : MODE_NONE;
                mirror_x_r <= mirror_x; mirror_y_r <= mirror_y;
                key_enable_r <= key_enable; key_r <= key_value;
                prefer_dst <= 1'b1;
            end else if (prep != 2'd0) begin
                // prep 3: span multiply settles; 2: base add; 1: start walkers.
                prep <= prep - 2'd1;
                if (prep == 2'd2)
                    src_base_r <= mirror_y_r ? src_r + src_span_r : src_r;
                if (prep == 2'd1)
                    walk_start <= 1'b1;
            end else if (finished) begin
                busy <= 1'b0;
                done <= 1'b1;
            end

            if (s_form || d_form) begin
                req_valid <= 1'b1;
                req_is_dst <= d_form;
                req_addr <= d_form ? d_addr : s_addr;
                req_len <= d_form ? d_len : s_len;
                req_lo <= d_form ? d_lo : s_lo;
                req_hi <= d_form ? d_hi : s_hi;
                req_px <= s_px;
                req_px_base <= px_wp;
                prefer_dst <= !d_form;
            end else if (req_fire) begin
                req_valid <= 1'b0;
            end

            if (req_fire) tag_tail <= tag_tail + 1'b1;
            if (rd64_valid) begin
                if (h_last) begin
                    beat <= '0;
                    burst_px <= '0;
                    tag_head <= tag_head + 1'b1;
                end else begin
                    beat <= beat + 5'd1;
                    burst_px <= burst_px + 6'(push_n);
                end
            end
            tag_count <= tag_count + (req_fire ? (TAG_W+1)'(1) : '0)
                                   - ((rd64_valid && h_last) ? (TAG_W+1)'(1) : '0);

            r_src <= src_beat;
            r_dst <= dst_beat;
            r_we_lo <= src_beat && beat_lo;
            r_we_hi <= src_beat && beat_hi;
            r_publish <= src_beat && h_last;

            if (s_form) px_wp <= px_wp + PX_W'(s_px);
            if (launch) px_rp <= px_rp + PX_W'(pop_n);
            px_count <= px_count + (r_publish ? (PX_W+1)'(r_px) : '0)
                                 - (launch ? (PX_W+1)'(pop_n) : '0);
            px_res <= px_res + (s_form ? (PX_W+1)'(s_px) : '0)
                             - (launch ? (PX_W+1)'(pop_n) : '0);

            if (r_dst) dw_wp <= dw_wp + 1'b1;
            if (launch) dw_rp <= dw_rp + 1'b1;
            dw_count <= dw_count + (r_dst ? (DST_W+1)'(1) : '0)
                                 - (launch ? (DST_W+1)'(1) : '0);
            dst_res <= dst_res + (d_form ? (DST_W+1)'(d_len) : '0)
                               - (launch ? (DST_W+1)'(1) : '0);

            if (result_write) of_wp <= of_wp + 1'b1;
            if (wr_fire) of_rp <= of_rp + 1'b1;
            of_count <= of_count + (result_write ? (OUT_W+1)'(1) : '0)
                                 - (wr_fire ? (OUT_W+1)'(1) : '0);
            out_res <= out_res + (launch ? (OUT_W+1)'(1) : '0)
                               - (result_skip ? (OUT_W+1)'(1) : '0)
                               - (wr_fire ? (OUT_W+1)'(1) : '0);
        end
    end

endmodule
