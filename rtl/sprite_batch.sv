// Fixed-DDRAM sprite descriptor sequencer.  This first version is a generic
// sequential executor, not a parallel or pipelined multi-sprite compositor:
// it reduces command-ring traffic but still runs one existing copy at a time.
// The 64 descriptors occupy exactly 2 KiB at 0x30022000, immediately after
// the 0x30021000-0x300218ff command-slot region.
// Each 32-byte descriptor contains
// dst, dst_pitch, width, height, key, src, src_pitch, and flags (bit 0 enables
// the colorkey).  Descriptors are fetched one word at a time, then handed to
// the existing blit_copy engine; only one copy is ever active.
//
// BLIT-008/009: a descriptor with any of flag bits 1-4 (blend, mirror-x,
// mirror-y, explicit blend mode) is a flagged draw handed to the external blit_blend engine,
// with word 4 as its RGBA modulation. blit_blend reads the destination, and
// ddram_adapter lets reads pass queued writes, so the sequencer waits for
// the adapter to go idle before a flagged draw and before the draw that
// follows one; each descriptor then observes every earlier one's writes.
// Unflagged runs keep their original back-to-back copy behaviour.
//
// blit_copy64 only moves whole, 8-byte-aligned source pixel pairs: an odd
// width leaves each row's last pixel uncopied (and hangs from the second
// row on), and a source row that is not 8-byte aligned is read from the
// wrong address. Unflagged descriptors outside its safe case -- even width,
// 8-byte-aligned source address and pitch -- therefore also run on
// blit_blend, as plain stores with identity modulation and the descriptor's
// colour key.
module sprite_batch #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32,
    parameter logic [ADDR_WIDTH-1:0] DESCRIPTOR_BASE = 32'h3002_2000
) (
    input logic clk, input logic reset,
    input logic start,
    input logic [15:0] count,
    output logic busy, output logic done,
    output logic [ADDR_WIDTH-1:0] rd_addr, output logic rd_en,
    output logic rd_active,
    input logic rd_ready, input logic [DATA_WIDTH-1:0] rd_data, input logic rd_valid,
    output logic [ADDR_WIDTH-1:0] rd64_addr, output logic rd64_en,
    output logic [7:0] rd64_len,
    input logic rd64_ready, input logic [63:0] rd64_data, input logic rd64_valid,
    output logic [ADDR_WIDTH-1:0] wr_addr, output logic [DATA_WIDTH-1:0] wr_data,
    output logic wr_en, input logic wr_ready,
    output logic [ADDR_WIDTH-1:0] wr64_addr, output logic [63:0] wr64_data,
    output logic wr64_en, input logic wr64_ready,
    input logic memory_idle,
    // Flagged draws: fields are stable from blend_start until blend_done.
    output logic blend_start,
    output logic [ADDR_WIDTH-1:0] blend_dst_addr, output logic [15:0] blend_dst_pitch,
    output logic [ADDR_WIDTH-1:0] blend_src_addr, output logic [15:0] blend_src_pitch,
    output logic [15:0] blend_width, output logic [15:0] blend_height,
    output logic [31:0] blend_mod,
    output logic blend_enable, output logic blend_mirror_x, output logic blend_mirror_y,
    output logic blend_key_enable, output logic [31:0] blend_key_value,
    output logic blend_mode_en, output logic [23:0] blend_mode,
    input logic blend_done
);
    // LAUNCH is deliberately separate from DESC_WAIT.  The final descriptor
    // word is captured with a nonblocking assignment; starting blit_copy in
    // that same clock would let it sample the previous descriptor's fields.
    typedef enum logic [3:0] {IDLE, DESC_REQ, DESC_WAIT, LAUNCH, DRAIN, COPY, BLEND,
                              FINISH} state_t;
    state_t state;
    logic prev_flagged;
    // BLIT-008 bits 1-3 and BLIT-009 bit 4 (explicit blend mode).
    wire draw_flags = desc[7][4:1] != 4'b0000;
    wire copy64_safe = !desc[2][0] && desc[5][2:0] == 3'b000 && desc[6][2:0] == 3'b000;
    // Runs on blit_blend: a flagged draw, or a copy blit_copy64 cannot do.
    wire flagged = draw_flags || !copy64_safe;
    logic [15:0] index, word_index, count_r;
    logic [31:0] desc[0:7];
    logic copy_start, copy_busy, copy_done;
    logic [31:0] copy_rd_addr, copy_wr_addr, copy_wr_data;
    logic [63:0] copy_rd64_data, copy_wr64_data;
    logic copy_rd64_en, copy_rd64_ready, copy_rd64_valid;
    logic [7:0] copy_rd64_len;
    logic copy_wr_en, copy_wr_ready, copy_wr64_en, copy_wr64_ready;

    blit_copy64 copy_i (
        .clk(clk), .reset(reset), .start(copy_start),
        .dst_addr(desc[0]), .dst_pitch(desc[1][15:0]),
        .src_addr(desc[5]), .src_pitch(desc[6][15:0]),
        .width(desc[2][15:0]), .height(desc[3][15:0]),
        .key_enable(desc[7][0]), .key_value(desc[4]),
        .busy(copy_busy), .done(copy_done),
        .wr_addr(copy_wr_addr), .wr_data(copy_wr_data),
        .wr_en(copy_wr_en), .wr_ready(copy_wr_ready),
        .rd64_addr(copy_rd_addr), .rd64_en(copy_rd64_en),
        .rd64_len(copy_rd64_len),
        .rd64_ready(copy_rd64_ready), .rd64_data(copy_rd64_data),
        .rd64_valid(copy_rd64_valid),
        .wr64_addr(wr64_addr), .wr64_data(wr64_data),
        .wr64_en(copy_wr64_en), .wr64_ready(copy_wr64_ready)
    );

    assign rd_addr = (state == DESC_WAIT || state == DESC_REQ)
                   ? (DESCRIPTOR_BASE + (index * 32) + (word_index * 4))
                   : '0;
    assign rd_en = (state == DESC_REQ);
    assign rd64_addr = (state == COPY) ? copy_rd_addr : '0;
    assign rd64_en = (state == COPY) ? copy_rd64_en : 1'b0;
    assign rd64_len = (state == COPY) ? copy_rd64_len : 8'd1;
    assign rd_active = (state == DESC_REQ || state == DESC_WAIT ||
                        state == COPY);
    assign copy_rd64_ready = (state == COPY) ? rd64_ready : 1'b0;
    assign copy_rd64_data = rd64_data;
    assign copy_rd64_valid = (state == COPY) ? rd64_valid : 1'b0;
    assign wr_addr = copy_wr_addr;
    assign wr_data = copy_wr_data;
    assign wr_en = (state == COPY) ? copy_wr_en : 1'b0;
    assign copy_wr_ready = (state == COPY) ? wr_ready : 1'b0;
    assign copy_wr64_ready = (state == COPY) ? wr64_ready : 1'b0;
    assign wr64_en = (state == COPY) ? copy_wr64_en : 1'b0;

    assign blend_dst_addr = desc[0];
    assign blend_dst_pitch = desc[1][15:0];
    assign blend_width = desc[2][15:0];
    assign blend_height = desc[3][15:0];
    assign blend_mod = draw_flags ? desc[4] : 32'hffff_ffff;
    assign blend_src_addr = desc[5];
    assign blend_src_pitch = desc[6][15:0];
    assign blend_enable = desc[7][1];
    assign blend_mirror_x = desc[7][2];
    assign blend_mirror_y = desc[7][3];
    assign blend_key_enable = !draw_flags && desc[7][0];
    assign blend_key_value = desc[4];
    assign blend_mode_en = desc[7][4];
    assign blend_mode = desc[7][31:8];

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= IDLE; busy <= 1'b0; done <= 1'b0;
            index <= '0; word_index <= '0; count_r <= '0; copy_start <= 1'b0;
            blend_start <= 1'b0; prev_flagged <= 1'b0;
            for (int i = 0; i < 8; i++) desc[i] <= '0;
        end else begin
            done <= 1'b0;
            copy_start <= 1'b0;
            blend_start <= 1'b0;
            case (state)
                IDLE: if (start && count != 0 && count <= 64) begin
                    busy <= 1'b1; index <= 0; word_index <= 0; count_r <= count;
                    prev_flagged <= 1'b0;
                    state <= DESC_REQ;
                end
                DESC_REQ: if (rd_ready) state <= DESC_WAIT;
                DESC_WAIT: if (rd_valid) begin
                    desc[word_index] <= rd_data;
                    if (word_index == 7) begin
                        state <= LAUNCH;
                    end else begin
                        word_index <= word_index + 1'b1;
                        state <= DESC_REQ;
                    end
                end
                LAUNCH: begin
                    // All eight descriptor words are now stable.
                    if (flagged || prev_flagged) begin
                        state <= DRAIN;
                    end else begin
                        copy_start <= 1'b1;
                        state <= COPY;
                    end
                end
                DRAIN: if (memory_idle) begin
                    prev_flagged <= flagged;
                    if (flagged) begin
                        blend_start <= 1'b1;
                        state <= BLEND;
                    end else begin
                        copy_start <= 1'b1;
                        state <= COPY;
                    end
                end
                COPY, BLEND: if ((state == COPY) ? copy_done : blend_done) begin
                    if (index + 1 >= count_r) state <= FINISH;
                    else begin
                        index <= index + 1'b1;
                        word_index <= 0;
                        state <= DESC_REQ;
                    end
                end
                FINISH: begin busy <= 1'b0; done <= 1'b1; state <= IDLE; end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
