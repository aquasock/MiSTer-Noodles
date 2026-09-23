#include <cstdio>
#include "Vcmdq_batch_dut.h"
#include "verilated.h"

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vcmdq_batch_dut dut;
    dut.reset = 1; dut.cmd_valid = 0; dut.batch_busy = 0; dut.batch_done = 0;
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
    std::puts("PASS: CMDQ SPRITE_BATCH decode, wait, and retirement");
    dut.final();
    return 0;
}
