// Verilator testbench for rtl/link_ring.sv (LINK-002/LINK-003). Acts as the
// "host": writes commands and write_ptr directly into a behavioral Avalon-MM
// memory model, exactly as an ARM process would via /dev/mem, and checks
// that link_ring polls, fetches, and dispatches each one to CMDQ in order
// with byte-exact command data -- including across a ring wraparound
// (RING_SLOTS=4 in link_ring_dut.sv, so 5 commands forces slot reuse).

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <unordered_map>

#include "Vlink_ring_dut.h"
#include "verilated.h"

namespace {

constexpr uint32_t kHeaderAddr = 0x30020000u;
constexpr uint32_t kSlotBaseAddr = 0x30021000u;
constexpr uint32_t kRingSlots = 4;

struct Command {
    uint32_t words[8];
};

Command MakeCommand(int i) {
    return Command{{1u, 0x1000u + uint32_t(i) * 0x100u, 4u, 1u, 1u, 0xC0FFEE00u + uint32_t(i), 0u,
                     0u}};
}

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

    void WriteCommand(uint32_t slot, const Command &cmd) {
        for (int i = 0; i < 8; ++i) Seed32(kSlotBaseAddr + slot * 32 + i * 4, cmd.words[i]);
    }

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
        } else if (rd && pending_read_countdown_ == 0 && !dout_ready_) {
            pending_read_addr_ = addr;
            pending_read_countdown_ = kReadLatency;
        }
    }

    uint64_t dout() const { return dout_; }
    bool dout_ready() const { return dout_ready_; }

private:
    static constexpr int kReadLatency = 3;
    static constexpr uint64_t kFillPattern = 0xEEEEEEEEEEEEEEEEull;
    std::unordered_map<uint32_t, uint64_t> words_;
    uint32_t pending_read_addr_ = 0;
    int pending_read_countdown_ = 0;
    bool dout_ready_ = false;
    uint64_t dout_ = 0;
};

class Testbench {
public:
    Testbench() : dut_(new Vlink_ring_dut) {}
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

    Vlink_ring_dut &dut() { return *dut_; }

private:
    std::unique_ptr<Vlink_ring_dut> dut_;
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
    Vlink_ring_dut &dut = tb.dut();

    dut.reset = 1;
    dut.cmd_ready = 1;
    for (int i = 0; i < 4; ++i) tb.Tick(mem);
    dut.reset = 0;
    tb.Tick(mem);

    // Quiescent check: with write_ptr == read_ptr (both 0, the reset
    // default), cmd_valid must never assert.
    for (int i = 0; i < 200; ++i) {
        tb.Tick(mem);
        if (dut.cmd_valid) return Fail("cmd_valid asserted with an empty ring");
    }

    constexpr int kCommands = 5;  // > RING_SLOTS(4): forces one wraparound
    for (int i = 0; i < kCommands; ++i) {
        const uint32_t slot = uint32_t(i) % kRingSlots;
        const Command cmd = MakeCommand(i);
        mem.WriteCommand(slot, cmd);
        mem.Seed32(kHeaderAddr + 0, (uint32_t(i) + 1) % kRingSlots);

        int guard = 0;
        while (!dut.cmd_valid) {
            tb.Tick(mem);
            if (++guard > 20000) return Fail("command never dispatched");
        }

        for (int w = 0; w < 8; ++w) {
            if (dut.cmd_data[w] != cmd.words[w]) {
                std::fprintf(stderr, "command %d word %d: expected 0x%08x got 0x%08x\n", i, w,
                              cmd.words[w], dut.cmd_data[w]);
                return Fail("dispatched command data mismatch");
            }
        }

        tb.Tick(mem);  // let the accept edge (cmd_valid && cmd_ready) happen

        // Wait for read_ptr's writeback to land in memory.
        const uint32_t want_read_ptr = (uint32_t(i) + 1) % kRingSlots;
        guard = 0;
        while (mem.Read32(kHeaderAddr + 8) != want_read_ptr) {
            tb.Tick(mem);
            if (++guard > 20000) return Fail("read_ptr writeback never landed");
        }
    }

    std::printf("PASS: link_ring dispatched %d commands in order, wraparound included\n",
                kCommands);
    return 0;
}
