// Verilator testbench for rtl/ddram_write_adapter.sv (DDR-001), driven
// through CMDQ+BLIT exactly like tb_solid_fill.cpp, but checked against a
// behavioral Avalon-MM memory model that enforces byte-enable correctness:
// each 4-byte pixel write must land in the correct half of its 8-byte
// DDRAM word and must not disturb the other half.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <memory>
#include <vector>

#include "Vengine_ddram_dut.h"
#include "verilated.h"

namespace {

constexpr uint32_t kOpSolidFill = 0x01;

struct Command {
    uint32_t opcode;
    uint32_t dst_addr;
    uint32_t dst_pitch;
    uint32_t width;
    uint32_t height;
    uint32_t color;
    uint32_t reserved0 = 0;
    uint32_t reserved1 = 0;
};

void PackCommand(const Command &c, Vengine_ddram_dut &dut) {
    dut.cmd_data[0] = c.opcode;
    dut.cmd_data[1] = c.dst_addr;
    dut.cmd_data[2] = c.dst_pitch;
    dut.cmd_data[3] = c.width;
    dut.cmd_data[4] = c.height;
    dut.cmd_data[5] = c.color;
    dut.cmd_data[6] = c.reserved0;
    dut.cmd_data[7] = c.reserved1;
}

constexpr uint64_t kFillPattern = 0xEEEEEEEEEEEEEEEEull;

class AvalonMemory {
public:
    explicit AvalonMemory(size_t words) : words_(words, kFillPattern) {}

    // Applies a write iff (we && !busy) -- the Avalon-MM acceptance
    // condition -- masking bytes per `be`.
    void MaybeWrite(bool we, bool busy, uint32_t burstcnt, bool rd,
                     uint32_t word_addr, uint64_t din, uint8_t be) {
        if (!(we && !busy)) return;
        if (rd) {
            std::fprintf(stderr, "RD asserted alongside WE\n");
            std::exit(1);
        }
        if (burstcnt != 1) {
            std::fprintf(stderr, "unexpected burstcnt=%u\n", burstcnt);
            std::exit(1);
        }
        if (word_addr >= words_.size()) {
            std::fprintf(stderr, "write out of bounds: word_addr=0x%08x\n", word_addr);
            std::exit(1);
        }
        uint64_t &word = words_[word_addr];
        for (int i = 0; i < 8; ++i) {
            if (be & (1u << i)) {
                const uint64_t byte = (din >> (8 * i)) & 0xFF;
                word = (word & ~(0xFFull << (8 * i))) | (byte << (8 * i));
            }
        }
        writes_.push_back(word_addr);
    }

    uint64_t Word(uint32_t word_addr) const { return words_[word_addr]; }
    const std::vector<uint32_t> &writes() const { return writes_; }

private:
    std::vector<uint64_t> words_;
    std::vector<uint32_t> writes_;
};

class Testbench {
public:
    Testbench() : dut_(new Vengine_ddram_dut) {}
    ~Testbench() { dut_->final(); }

    void Tick(AvalonMemory &mem, bool busy) {
        dut_->DDRAM_BUSY = busy ? 1 : 0;

        dut_->clk = 0;
        dut_->eval();

        dut_->clk = 1;
        dut_->eval();
        mem.MaybeWrite(dut_->DDRAM_WE, dut_->DDRAM_BUSY, dut_->DDRAM_BURSTCNT,
                        dut_->DDRAM_RD, dut_->DDRAM_ADDR, dut_->DDRAM_DIN,
                        dut_->DDRAM_BE);
    }

    Vengine_ddram_dut &dut() { return *dut_; }

private:
    std::unique_ptr<Vengine_ddram_dut> dut_;
};

int Fail(const char *msg) {
    std::fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    Testbench tb;
    AvalonMemory mem(0x1000);
    Vengine_ddram_dut &dut = tb.dut();

    dut.reset = 1;
    dut.cmd_valid = 0;
    for (int i = 0; i < 4; ++i) tb.Tick(mem, /*busy=*/false);
    dut.reset = 0;
    tb.Tick(mem, /*busy=*/false);

    // dst_addr is not 8-byte aligned (0x1004, addr[2]=1) and width is odd
    // (3), so consecutive rows alternate which half of the DDRAM word each
    // row's pixels start in -- exercises both BE patterns.
    const Command cmd{
        .opcode = kOpSolidFill,
        .dst_addr = 0x1004,
        .dst_pitch = 3 * 4,
        .width = 3,
        .height = 2,
        .color = 0x11223344u,
    };
    PackCommand(cmd, dut);
    dut.cmd_valid = 1;

    if (!dut.cmd_ready) return Fail("cmdq not ready to accept right after reset");
    tb.Tick(mem, /*busy=*/false);
    dut.cmd_valid = 0;

    int guard = 0;
    do {
        tb.Tick(mem, /*busy=*/(guard % 3) == 1);  // intermittent Avalon backpressure
        if (++guard > 10000) return Fail("blit never completed");
    } while (!dut.cmd_ready);

    // Two adjacent pixels can legitimately share one 8-byte DDRAM word (one
    // in each half), so the correctness model is: replay the same per-pixel
    // half-word writes into a shadow word map, then compare every touched
    // word (and a few untouched neighbors) against that shadow -- not a
    // naive "the other half must still be the fill pattern" check.
    std::map<uint32_t, uint64_t> shadow;
    auto shadow_word = [&](uint32_t word_addr) -> uint64_t & {
        auto it = shadow.find(word_addr);
        if (it != shadow.end()) return it->second;
        return shadow.emplace(word_addr, kFillPattern).first->second;
    };

    for (uint32_t row = 0; row < cmd.height; ++row) {
        for (uint32_t col = 0; col < cmd.width; ++col) {
            const uint32_t byte_addr = cmd.dst_addr + row * cmd.dst_pitch + col * 4;
            const uint32_t word_addr = byte_addr >> 3;
            const bool upper_half = (byte_addr >> 2) & 1;
            uint64_t &word = shadow_word(word_addr);
            const uint64_t mask = upper_half ? 0xFFFFFFFF00000000ull : 0x00000000FFFFFFFFull;
            const uint64_t placed = upper_half ? (uint64_t(cmd.color) << 32) : uint64_t(cmd.color);
            word = (word & ~mask) | placed;
        }
    }

    for (const auto &[word_addr, expected] : shadow) {
        const uint64_t got = mem.Word(word_addr);
        if (got != expected) {
            std::fprintf(stderr, "word 0x%08x: expected 0x%016lx got 0x%016lx\n", word_addr,
                          expected, got);
            return Fail("pixel value mismatch");
        }
    }
    // Sentinel: the word immediately before the destination rect must be
    // completely untouched.
    const uint32_t sentinel = (cmd.dst_addr >> 3) - 1;
    if (mem.Word(sentinel) != kFillPattern) {
        return Fail("write escaped destination rectangle (sentinel word disturbed)");
    }

    std::printf("PASS: ddram-adapter solid-fill %ux%u at 0x%08x, %zu word writes\n",
                cmd.width, cmd.height, cmd.dst_addr, mem.writes().size());
    return 0;
}
