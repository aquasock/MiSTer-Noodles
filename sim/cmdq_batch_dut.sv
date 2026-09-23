module cmdq_batch_dut (
    input logic clk, input logic reset,
    input logic cmd_valid, input logic [255:0] cmd_data,
    output logic cmd_ready, output logic batch_start,
    output logic [15:0] batch_count,
    input logic batch_busy, input logic batch_done
);
    cmdq dut (
        .clk(clk), .reset(reset), .cmd_valid(cmd_valid), .cmd_data(cmd_data),
        .cmd_ready(cmd_ready),
        .blit_start(), .blit_dst_addr(), .blit_dst_pitch(), .blit_width(),
        .blit_height(), .blit_color(), .blit_busy(1'b0), .blit_done(1'b0),
        .memory_idle(1'b1),
        .copy_start(), .copy_dst_addr(), .copy_dst_pitch(), .copy_src_addr(),
        .copy_src_pitch(), .copy_width(), .copy_height(), .copy_key_enable(),
        .copy_key_value(), .copy_busy(1'b0), .copy_done(1'b0),
        .batch_start(batch_start), .batch_count(batch_count),
        .batch_busy(batch_busy), .batch_done(batch_done),
        .present_start(), .present_busy(1'b0), .present_done(1'b0),
        .loader_start(), .loader_src_addr(), .loader_dst_addr(), .loader_length(),
        .loader_busy(1'b0), .loader_done(1'b0)
    );
endmodule
