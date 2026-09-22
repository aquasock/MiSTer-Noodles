// Verilator testbench for the BLIT_COPY path end to end: cmd_test_trigger
// -> CMDQ (opcode 2 decode, CMDQ-001/BLIT-003) -> blit_copy -> ddram_adapter
// (DDR-003) -> a behavioral Avalon-MM memory model that must serve both
// reads and writes correctly, including the half-word steering on each
// side independently (source and destination addresses are deliberately
// not both aligned the same way).
//
// The command itself is a compile-time default on cmd_copy_trigger_dut
// (cmd_test_trigger has no runtime command input, same pattern as
// sim/tb_cmd_trigger.cpp) -- kDstAddr etc. below must match that default.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <unordered_map>

#include "Vcmd_copy_trigger_dut.h"
#include "verilated.h"

namespace {

constexpr uint32_t kDstAddr = 0x30001004u;  // upper half of its word
constexpr uint32_t kDstPitch = 32;          // 8px * 4B
constexpr uint32_t kSrcAddr = 0x30002000u;  // lower half of its word
constexpr uint32_t kSrcPitch = 16;          // 4px * 4B
constexpr uint32_t kWidth = 4;
constexpr uint32_t kHeight = 3;

uint32_t SourcePixel(uint32_t row, uint32_t col) { return 0xA0000000u | (row << 8) | col; }

// Behavioral Avalon-MM memory: word-addressed, 8 bytes/word, single
// outstanding read at a time (matches blit_copy's own contract), fixed
// response latency after a read is accepted. Sparse -- real addresses
// (0x30000000+) are far too large for a flat array.
class AvalonMemory {
public:
    AvalonMemory() = default;

    void Seed32(uint32_t byte_addr, uint32_t value) {
        uint64_t &word = words_[byte_addr >> 3];
        const uint64_t mask = (byte_addr & 4) ? 0xFFFFFFFF00000000ull : 0x00000000FFFFFFFFull;
        const uint64_t placed = (byte_addr & 4) ? (uint64_t(value) << 32) : uint64_t(value);
        word = (word & ~mask) | placed;
    }

    uint32_t Read32(uint32_t byte_addr) const {
        auto it = words_.find(byte_addr >> 3);
        uint64_t word = (it == words_.end()) ? kFillPattern : it->second;
        return (byte_addr & 4) ? uint32_t(word >> 32) : uint32_t(word);
    }

    // Called every cycle with the DUT's DDRAM_* outputs; drives
    // DDRAM_DOUT/DDRAM_DOUT_READY for the next eval (DDRAM_BUSY stays low
    // throughout -- backpressure is already covered by tb_ddram_adapter.cpp).
    void Step(bool we, bool rd, uint32_t addr, uint64_t din, uint8_t be) {
        if (pending_read_countdown_ > 0) {
            if (--pending_read_countdown_ == 0) {
                dout_ready_ = true;
                auto it = words_.find(pending_read_addr_);
                dout_ = (it == words_.end()) ? kFillPattern : it->second;
            }
        } else {
            dout_ready_ = false;
        }

        if (we) {
            // NOTE: words_[addr] would insert a zero-valued entry via
            // operator[] before a find()==end() check could ever see a
            // missing key -- look up first, so a first-touch word starts
            // from the fill pattern rather than silent zero.
            auto it = words_.find(addr);
            uint64_t word = (it != words_.end()) ? it->second : kFillPattern;
            for (int i = 0; i < 8; ++i) {
                if (be & (1u << i)) {
                    uint64_t byte = (din >> (8 * i)) & 0xFF;
                    word = (word & ~(0xFFull << (8 * i))) | (byte << (8 * i));
                }
            }
            words_[addr] = word;
            ++writes_;
        } else if (rd && pending_read_countdown_ == 0 && !dout_ready_) {
            pending_read_addr_ = addr;
            pending_read_countdown_ = kReadLatency;
            ++reads_;
        }
    }

    uint64_t dout() const { return dout_; }
    bool dout_ready() const { return dout_ready_; }
    size_t writes() const { return writes_; }
    size_t reads() const { return reads_; }

private:
    static constexpr int kReadLatency = 3;
    static constexpr uint64_t kFillPattern = 0xEEEEEEEEEEEEEEEEull;
    std::unordered_map<uint32_t, uint64_t> words_;
    uint32_t pending_read_addr_ = 0;
    int pending_read_countdown_ = 0;
    bool dout_ready_ = false;
    uint64_t dout_ = 0;
    size_t writes_ = 0;
    size_t reads_ = 0;
};

class Testbench {
public:
    Testbench() : dut_(new Vcmd_copy_trigger_dut) {}
    ~Testbench() { dut_->final(); }

    void Tick(AvalonMemory &mem) {
        dut_->DDRAM_BUSY = 0;
        dut_->DDRAM_DOUT = mem.dout();
        dut_->DDRAM_DOUT_READY = mem.dout_ready() ? 1 : 0;

        dut_->clk = 0;
        dut_->eval();
        dut_->clk = 1;
        dut_->eval();

        mem.Step(dut_->DDRAM_WE, dut_->DDRAM_RD, dut_->DDRAM_ADDR, dut_->DDRAM_DIN, dut_->DDRAM_BE);
    }

    Vcmd_copy_trigger_dut &dut() { return *dut_; }

private:
    std::unique_ptr<Vcmd_copy_trigger_dut> dut_;
};

int Fail(const char *msg) {
    std::fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    Testbench tb;
    AvalonMemory mem;
    Vcmd_copy_trigger_dut &dut = tb.dut();

    for (uint32_t row = 0; row < kHeight; ++row) {
        for (uint32_t col = 0; col < kWidth; ++col) {
            mem.Seed32(kSrcAddr + row * kSrcPitch + col * 4, SourcePixel(row, col));
        }
    }

    dut.reset = 1;
    dut.trigger = 0;
    for (int i = 0; i < 4; ++i) tb.Tick(mem);
    dut.reset = 0;
    tb.Tick(mem);

    dut.trigger = 1;

    // dut.busy/dut.done are cmd_test_trigger's signals -- they track CMDQ
    // *accepting* the command, not blit_copy finishing it (same distinction
    // tb_cmd_trigger.cpp already had to account for). Wait for the actual
    // pixel count instead.
    int guard = 0;
    do {
        tb.Tick(mem);
        if (++guard > 50000) return Fail("copy never completed");
    } while (mem.writes() < kWidth * kHeight);
    for (int i = 0; i < 8; ++i) tb.Tick(mem);

    if (mem.writes() != kWidth * kHeight) {
        std::fprintf(stderr, "expected %u writes, got %zu\n", kWidth * kHeight, mem.writes());
        return Fail("write count mismatch");
    }
    if (mem.reads() != kWidth * kHeight) {
        std::fprintf(stderr, "expected %u reads, got %zu\n", kWidth * kHeight, mem.reads());
        return Fail("read count mismatch");
    }

    for (uint32_t row = 0; row < kHeight; ++row) {
        for (uint32_t col = 0; col < kWidth; ++col) {
            uint32_t got = mem.Read32(kDstAddr + row * kDstPitch + col * 4);
            uint32_t want = SourcePixel(row, col);
            if (got != want) {
                std::fprintf(stderr, "pixel (%u,%u): expected 0x%08x got 0x%08x\n", col, row,
                              want, got);
                return Fail("copied pixel mismatch");
            }
        }
    }

    std::printf("PASS: blit_copy %ux%u src=0x%08x dst=0x%08x, %zu reads, %zu writes\n", kWidth,
                kHeight, kSrcAddr, kDstAddr, mem.reads(), mem.writes());
    return 0;
}
