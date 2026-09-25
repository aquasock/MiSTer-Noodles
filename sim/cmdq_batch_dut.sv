module cmdq_batch_dut (
    input logic clk, input logic reset,
    input logic cmd_valid, input logic [255:0] cmd_data,
    output logic cmd_ready, output logic batch_start,
    output logic [31:0] batch_base,
    output logic [15:0] batch_count,
    input logic batch_busy, input logic batch_done,
    output logic fill_batch_start, output logic [31:0] fill_batch_base,
    output logic [15:0] fill_batch_count,
    input logic fill_batch_busy, input logic fill_batch_done,
    output logic blend_start, output logic [7:0] blend_mod,
    output logic blend_solid, output logic [31:0] blend_solid_color,
    output logic blend_mode_en, output logic [23:0] blend_mode,
    output logic [31:0] copy_dst_addr, output logic [31:0] copy_src_addr,
    output logic [15:0] copy_width, output logic [15:0] copy_height,
    input logic blend_busy, input logic blend_done,
    // OUT-013: the real present engine behind CMDQ, with the display
    // boundary and scaler retirement acknowledgement driven by the testbench.
    input logic fb_vbl, input logic fb_retired,
    output logic present_start, output logic present_accept,
    output logic present_busy, output logic present_done,
    output logic present_retired, output logic [1:0] front_idx
);
    logic present_queued;
    logic [1:0] present_target;
    present #(.RETIRE_VBLANKS(0)) present_i (
        .clk(clk), .reset(reset), .fb_vbl(fb_vbl), .fb_retired(fb_retired),
        .start(present_start), .queued(present_queued), .target(present_target),
        .busy(present_busy), .done(present_done), .retired(present_retired),
        .front_idx(front_idx)
    );
    cmdq dut (
        .clk(clk), .reset(reset), .cmd_valid(cmd_valid), .cmd_data(cmd_data),
        .cmd_ready(cmd_ready),
        .blit_start(), .blit_dst_addr(), .blit_dst_pitch(), .blit_width(),
        .blit_height(), .blit_color(), .blit_busy(1'b0), .blit_done(1'b0),
        .memory_idle(1'b1),
        .copy_start(), .copy_dst_addr(copy_dst_addr), .copy_dst_pitch(),
        .copy_src_addr(copy_src_addr), .copy_src_pitch(), .copy_width(copy_width),
        .copy_height(copy_height), .copy_key_enable(),
        .copy_key_value(), .copy_busy(1'b0), .copy_done(1'b0),
        .blend_start(blend_start), .blend_mod(blend_mod),
        .blend_solid(blend_solid), .blend_solid_color(blend_solid_color),
        .blend_mode_en(blend_mode_en), .blend_mode(blend_mode),
        .blend_busy(blend_busy), .blend_done(blend_done),
        .batch_start(batch_start), .batch_base(batch_base), .batch_count(batch_count),
        .batch_busy(batch_busy), .batch_done(batch_done),
        .fill_batch_start(fill_batch_start), .fill_batch_base(fill_batch_base),
        .fill_batch_count(fill_batch_count), .fill_batch_busy(fill_batch_busy),
        .fill_batch_done(fill_batch_done),
        .present_start(present_start), .present_queued(present_queued),
        .present_target(present_target), .present_accept(present_accept),
        .present_busy(present_busy), .present_done(present_done),
        .loader_start(), .loader_src_addr(), .loader_dst_addr(), .loader_length(),
        .loader_busy(1'b0), .loader_done(1'b0)
    );
endmodule
