// Verilator testbench for cmd_test_trigger driving the real CMDQ->BLIT path
// (CMDQ-002's "Draw Test" command), end to end: one trigger edge should
// produce exactly one SOLID_FILL covering the whole 64x64 surface at
// 0x30000000 with color 0x00FF00FF, and holding trigger high must not
// repeat it.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <vector>

#include "Vcmd_trigger_dut.h"
#include "verilated.h"

namespace {

constexpr uint32_t kDstAddr = 0x30000000u;
constexpr uint32_t kPitch = 256;
constexpr uint32_t kWidth = 64;
constexpr uint32_t kHeight = 64;
constexpr uint32_t kColor = 0x00FF00FFu;

class Memory {
public:
    explicit Memory(size_t bytes) : data_(bytes, 0xEE) {}

    void MaybeWrite(bool wr_en, bool wr_ready, uint32_t addr, uint32_t value) {
        if (!(wr_en && wr_ready)) return;
        uint32_t off = addr - kDstAddr;
        if (off + 4 > data_.size()) {
            std::fprintf(stderr, "write out of modelled range: addr=0x%08x\n", addr);
            std::exit(1);
        }
        for (int i = 0; i < 4; ++i) data_[off + i] = (value >> (8 * i)) & 0xFF;
        ++writes_;
    }

    uint32_t Read32(uint32_t addr) const {
        uint32_t off = addr - kDstAddr;
        return data_[off] | (data_[off + 1] << 8) | (data_[off + 2] << 16) |
               (data_[off + 3] << 24);
    }

    size_t writes() const { return writes_; }

private:
    std::vector<uint8_t> data_;
    size_t writes_ = 0;
};

class Testbench {
public:
    Testbench() : dut_(new Vcmd_trigger_dut) {}
    ~Testbench() { dut_->final(); }

    void Tick(Memory &mem, bool wr_ready) {
        dut_->wr_ready = wr_ready ? 1 : 0;
        dut_->clk = 0;
        dut_->eval();
        dut_->clk = 1;
        dut_->eval();
        mem.MaybeWrite(dut_->wr_en, dut_->wr_ready, dut_->wr_addr, dut_->wr_data);
    }

    Vcmd_trigger_dut &dut() { return *dut_; }

private:
    std::unique_ptr<Vcmd_trigger_dut> dut_;
};

int Fail(const char *msg) {
    std::fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    Testbench tb;
    Memory mem(kHeight * kPitch);
    Vcmd_trigger_dut &dut = tb.dut();

    dut.reset = 1;
    dut.trigger = 0;
    for (int i = 0; i < 4; ++i) tb.Tick(mem, /*wr_ready=*/true);
    dut.reset = 0;
    tb.Tick(mem, /*wr_ready=*/true);

    dut.trigger = 1;
    // cmd_test_trigger's own done/busy only track CMDQ *accepting* the
    // command, not BLIT finishing the fill -- wait for the actual pixel
    // count to land before checking anything about repeats.
    int guard = 0;
    do {
        tb.Tick(mem, /*wr_ready=*/(guard % 3) != 1);
        if (++guard > 20000) return Fail("draw test never completed");
    } while (mem.writes() < kWidth * kHeight);
    for (int i = 0; i < 8; ++i) tb.Tick(mem, /*wr_ready=*/true);  // let it settle

    // Holding trigger high (now that the whole draw is done) must not
    // cause a second command submission.
    const size_t writes_after_first = mem.writes();
    for (int i = 0; i < 100; ++i) tb.Tick(mem, /*wr_ready=*/true);
    if (mem.writes() != writes_after_first) return Fail("holding trigger high re-fired the draw");

    if (mem.writes() != kWidth * kHeight) {
        std::fprintf(stderr, "expected %u writes, got %zu\n", kWidth * kHeight, mem.writes());
        return Fail("write count mismatch");
    }

    for (uint32_t row = 0; row < kHeight; ++row) {
        for (uint32_t col = 0; col < kWidth; ++col) {
            uint32_t addr = kDstAddr + row * kPitch + col * 4;
            uint32_t got = mem.Read32(addr);
            if (got != kColor) {
                std::fprintf(stderr, "pixel (%u,%u): expected 0x%08x got 0x%08x\n", col, row,
                              kColor, got);
                return Fail("pixel value mismatch");
            }
        }
    }

    std::printf("PASS: cmd_test_trigger drew %ux%u at 0x%08x via CMDQ->BLIT, %zu writes\n",
                kWidth, kHeight, kDstAddr, mem.writes());
    return 0;
}
