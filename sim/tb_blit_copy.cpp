// Verilator testbench for the BLIT_COPY / BLIT_COPY_KEY path end to end:
// CMDQ (opcode 2/3 decode, CMDQ-001/BLIT-003/BLIT-006) -> blit_copy ->
// ddram_adapter (DDR-003) -> a behavioral Avalon-MM memory model that must
// serve both reads and writes correctly, including the half-word steering
// on each side independently (source and destination addresses are
// deliberately not both aligned the same way). cmd_valid/cmd_data are
// driven directly (same pattern as tb_ddram_adapter.cpp), not through
// cmd_test_trigger -- that module and the OSD buttons it drove were
// retired once LINK-001 proved the real ring-buffer command path end to
// end (see core-log.md).
//
// Two commands in one run: a plain BLIT_COPY (opcode 2, unchanged from
// before), then a BLIT_COPY_KEY (opcode 3) whose source is a checkerboard
// of a chosen "key" color and distinct per-pixel values, copied onto a
// destination pre-seeded with a known background -- verifying key-colored
// source pixels leave the background untouched while everything else
// copies normally, and that keyed-out pixels are still READ (every source
// pixel must be inspected) but not WRITTEN.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <deque>
#include <unordered_map>

#include "Vengine_copy_dut.h"
#include "verilated.h"

namespace {

constexpr uint32_t kOpBlitCopy = 0x02;
constexpr uint32_t kOpBlitCopyKey = 0x03;

constexpr uint32_t kDstAddr = 0x30001004u;  // upper half of its word
constexpr uint32_t kDstPitch = 32;          // 8px * 4B
constexpr uint32_t kSrcAddr = 0x30002000u;  // lower half of its word
constexpr uint32_t kSrcPitch = 16;          // 4px * 4B
constexpr uint32_t kWidth = 4;
constexpr uint32_t kHeight = 3;

uint32_t SourcePixel(uint32_t row, uint32_t col) { return 0xA0000000u | (row << 8) | col; }

void PackCommand(Vengine_copy_dut &dut) {
    dut.cmd_data[0] = kOpBlitCopy;
    dut.cmd_data[1] = kDstAddr;
    dut.cmd_data[2] = kDstPitch;
    dut.cmd_data[3] = kWidth;
    dut.cmd_data[4] = kHeight;
    dut.cmd_data[5] = 0;  // color, unused for BLIT_COPY
    dut.cmd_data[6] = kSrcAddr;
    dut.cmd_data[7] = kSrcPitch;
}

constexpr uint32_t kKeyDstAddr = 0x30004000u;
constexpr uint32_t kKeyDstPitch = 32;  // 8px * 4B
constexpr uint32_t kKeySrcAddr = 0x30003000u;
constexpr uint32_t kKeySrcPitch = 16;  // 4px * 4B
constexpr uint32_t kKeyWidth = 4;
constexpr uint32_t kKeyHeight = 4;
constexpr uint32_t kKeyColor = 0xCAFEBABEu;
constexpr uint32_t kKeyBackground = 0xDEADBEEFu;

// Checkerboard: half the pixels are exactly the key color (must be skipped),
// the rest are distinct per-pixel values (must be copied normally).
bool IsKeyed(uint32_t row, uint32_t col) { return ((row + col) % 2) == 0; }
uint32_t KeySourcePixel(uint32_t row, uint32_t col) {
    return IsKeyed(row, col) ? kKeyColor : SourcePixel(row, col);
}

void PackKeyCommand(Vengine_copy_dut &dut) {
    dut.cmd_data[0] = kOpBlitCopyKey;
    dut.cmd_data[1] = kKeyDstAddr;
    dut.cmd_data[2] = kKeyDstPitch;
    dut.cmd_data[3] = kKeyWidth;
    dut.cmd_data[4] = kKeyHeight;
    dut.cmd_data[5] = kKeyColor;  // colorkey value for BLIT_COPY_KEY
    dut.cmd_data[6] = kKeySrcAddr;
    dut.cmd_data[7] = kKeySrcPitch;
}

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
        dout_ready_ = false;
        if (!pending_reads_.empty()) {
            for (auto &pending : pending_reads_) --pending.cycles;
            if (pending_reads_.front().cycles <= 0) {
                dout_ready_ = true;
                auto it = words_.find(pending_reads_.front().addr);
                dout_ = (it == words_.end()) ? kFillPattern : it->second;
                pending_reads_.pop_front();
            }
        }

        if (we) {
            // words_[addr] would insert a zero-valued entry via operator[]
            // before a find()==end() check could ever see a missing key --
            // look up first, so a first-touch word starts from the fill
            // pattern rather than silent zero.
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
        } else if (rd) {
            pending_reads_.push_back({addr, kReadLatency});
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
    struct PendingRead { uint32_t addr; int cycles; };
    std::deque<PendingRead> pending_reads_;
    bool dout_ready_ = false;
    uint64_t dout_ = 0;
    size_t writes_ = 0;
    size_t reads_ = 0;
};

class Testbench {
public:
    Testbench() : dut_(new Vengine_copy_dut) {}
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

    Vengine_copy_dut &dut() { return *dut_; }

private:
    std::unique_ptr<Vengine_copy_dut> dut_;
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
    Vengine_copy_dut &dut = tb.dut();

    for (uint32_t row = 0; row < kHeight; ++row) {
        for (uint32_t col = 0; col < kWidth; ++col) {
            mem.Seed32(kSrcAddr + row * kSrcPitch + col * 4, SourcePixel(row, col));
        }
    }

    dut.reset = 1;
    dut.cmd_valid = 0;
    for (int i = 0; i < 4; ++i) tb.Tick(mem);
    dut.reset = 0;
    tb.Tick(mem);

    PackCommand(dut);
    dut.cmd_valid = 1;

    if (!dut.cmd_ready) return Fail("cmdq not ready to accept right after reset");
    tb.Tick(mem);
    dut.cmd_valid = 0;

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

    // BLIT_COPY_KEY: seed the source checkerboard and pre-fill the
    // destination with a known background before pushing the command.
    for (uint32_t row = 0; row < kKeyHeight; ++row) {
        for (uint32_t col = 0; col < kKeyWidth; ++col) {
            mem.Seed32(kKeySrcAddr + row * kKeySrcPitch + col * 4, KeySourcePixel(row, col));
            mem.Seed32(kKeyDstAddr + row * kKeyDstPitch + col * 4, kKeyBackground);
        }
    }

    size_t reads_before = mem.reads();
    size_t writes_before = mem.writes();

    PackKeyCommand(dut);
    dut.cmd_valid = 1;
    if (!dut.cmd_ready) return Fail("cmdq not ready before BLIT_COPY_KEY");
    tb.Tick(mem);
    dut.cmd_valid = 0;

    guard = 0;
    const size_t kKeyExpectedWrites = writes_before + (kKeyWidth * kKeyHeight) / 2;
    do {
        tb.Tick(mem);
        if (++guard > 50000) return Fail("keyed copy never completed");
    } while (mem.writes() < kKeyExpectedWrites || !dut.cmd_ready);
    for (int i = 0; i < 8; ++i) tb.Tick(mem);

    size_t key_reads = mem.reads() - reads_before;
    size_t key_writes = mem.writes() - writes_before;
    if (key_reads != kKeyWidth * kKeyHeight) {
        std::fprintf(stderr, "expected %u reads for keyed copy, got %zu\n",
                      kKeyWidth * kKeyHeight, key_reads);
        return Fail("keyed copy read count mismatch (every source pixel must still be read)");
    }
    if (key_writes != kKeyExpectedWrites - writes_before) {
        std::fprintf(stderr, "expected %zu writes for keyed copy (half skipped), got %zu\n",
                      kKeyExpectedWrites - writes_before, key_writes);
        return Fail("keyed copy write count mismatch (keyed pixels must be skipped)");
    }

    for (uint32_t row = 0; row < kKeyHeight; ++row) {
        for (uint32_t col = 0; col < kKeyWidth; ++col) {
            uint32_t got = mem.Read32(kKeyDstAddr + row * kKeyDstPitch + col * 4);
            uint32_t want = IsKeyed(row, col) ? kKeyBackground : KeySourcePixel(row, col);
            if (got != want) {
                std::fprintf(stderr, "keyed pixel (%u,%u) [%s]: expected 0x%08x got 0x%08x\n", col,
                              row, IsKeyed(row, col) ? "keyed, should be untouched" : "copied",
                              want, got);
                return Fail("keyed copy destination mismatch");
            }
        }
    }

    std::printf(
        "PASS: blit_copy %ux%u src=0x%08x dst=0x%08x, %zu reads, %zu writes; "
        "blit_copy_key %ux%u correctly skipped %u/%u keyed pixels (%zu reads, %zu writes)\n",
        kWidth, kHeight, kSrcAddr, kDstAddr, reads_before, writes_before, kKeyWidth, kKeyHeight,
        (kKeyWidth * kKeyHeight) - static_cast<uint32_t>(key_writes), kKeyWidth * kKeyHeight,
        key_reads, key_writes);
    return 0;
}
