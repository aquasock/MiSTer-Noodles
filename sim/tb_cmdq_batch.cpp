#include <cstdio>
#include "Vcmdq_batch_dut.h"
#include "verilated.h"

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vcmdq_batch_dut dut;
    dut.reset = 1; dut.cmd_valid = 0; dut.batch_busy = 0; dut.batch_done = 0;
    dut.blend_busy = 0; dut.blend_done = 0;
    for (int i = 0; i < 3; ++i) { dut.clk = 0; dut.eval(); dut.clk = 1; dut.eval(); }
    dut.reset = 0;
    dut.cmd_data[0] = 5; dut.cmd_data[3] = 64; dut.cmd_valid = 1;
    if (!dut.cmd_ready) return std::fprintf(stderr, "FAIL: batch cmd not ready\n"), 1;
    dut.clk = 0; dut.eval(); dut.clk = 1; dut.eval(); dut.cmd_valid = 0;
    if (!dut.batch_start || dut.batch_count != 64)
        return std::fprintf(stderr, "FAIL: batch decode start/count\n"), 1;
    dut.batch_done = 1; dut.clk = 0; dut.eval(); dut.clk = 1; dut.eval();
    dut.batch_done = 0;
    if (!dut.cmd_ready) return std::fprintf(stderr, "FAIL: batch controller did not retire\n"), 1;

    // BLIT_BLEND (BLIT-007): copy geometry plus word 5 [7:0] modulation.
    for (int i = 0; i < 8; ++i) dut.cmd_data[i] = 0;
    dut.cmd_data[0] = 7; dut.cmd_data[1] = 0x31000010; dut.cmd_data[2] = 3200;
    dut.cmd_data[3] = 33; dut.cmd_data[4] = 17; dut.cmd_data[5] = 0x9c;
    dut.cmd_data[6] = 0x32000008; dut.cmd_data[7] = 256;
    dut.blend_busy = 0; dut.blend_done = 0; dut.cmd_valid = 1;
    dut.clk = 0; dut.eval(); dut.clk = 1; dut.eval(); dut.cmd_valid = 0;
    if (!dut.blend_start || dut.blend_mod != 0x9c || dut.copy_dst_addr != 0x31000010 ||
        dut.copy_src_addr != 0x32000008 || dut.copy_width != 33 || dut.copy_height != 17 ||
        dut.batch_start)
        return std::fprintf(stderr, "FAIL: blend decode\n"), 1;
    dut.blend_busy = 1; dut.clk = 0; dut.eval(); dut.clk = 1; dut.eval();
    if (dut.cmd_ready || dut.blend_start)
        return std::fprintf(stderr, "FAIL: blend did not hold the queue\n"), 1;
    dut.blend_busy = 0; dut.blend_done = 1; dut.clk = 0; dut.eval(); dut.clk = 1; dut.eval();
    dut.blend_done = 0;
    if (!dut.cmd_ready) return std::fprintf(stderr, "FAIL: blend did not retire\n"), 1;

    // BLEND_FILL (BLIT-010): destination geometry, constant source colour
    // and explicit mode flags in word 6.
    for (int i = 0; i < 8; ++i) dut.cmd_data[i] = 0;
    dut.cmd_data[0] = 8; dut.cmd_data[1] = 0x31200020; dut.cmd_data[2] = 3200;
    dut.cmd_data[3] = 19; dut.cmd_data[4] = 23; dut.cmd_data[5] = 0x80402010;
    dut.cmd_data[6] = 0x6c5a3c10;
    dut.cmd_valid = 1;
    dut.clk = 0; dut.eval(); dut.clk = 1; dut.eval(); dut.cmd_valid = 0;
    if (!dut.blend_start || dut.blend_mod != 0xff || !dut.blend_solid || !dut.blend_mode_en ||
        dut.blend_solid_color != 0x80402010 || dut.blend_mode != 0x6c5a3c ||
        dut.copy_dst_addr != 0x31200020 || dut.copy_width != 19 || dut.copy_height != 23)
        return std::fprintf(stderr, "FAIL: blend-fill decode\n"), 1;
    dut.blend_done = 1; dut.clk = 0; dut.eval(); dut.clk = 1; dut.eval();
    dut.blend_done = 0;
    if (!dut.cmd_ready) return std::fprintf(stderr, "FAIL: blend-fill did not retire\n"), 1;
    std::puts("PASS: CMDQ SPRITE_BATCH, BLIT_BLEND and BLEND_FILL decode, wait, and retirement");
    dut.final();
    return 0;
}
