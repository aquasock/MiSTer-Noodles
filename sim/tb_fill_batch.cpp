#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <memory>
#include <unordered_map>
#include <vector>

#include "Vengine_fill_batch_dut.h"
#include "verilated.h"

namespace {

constexpr uint64_t kPattern = 0x5a5a5a5a5a5a5a5aull;
constexpr uint32_t kDescriptorBase = 0x30032000u;
constexpr uint32_t kCanvasBase = 0x31200000u;
constexpr uint32_t kCanvasWidth = 32;
constexpr uint32_t kCanvasHeight = 32;
constexpr uint32_t kCanvasPitch = kCanvasWidth * 4;

class AvalonMemory {
public:
    void Seed32(uint32_t byte_addr, uint32_t value) {
        uint64_t &word = words_[byte_addr >> 3];
        const unsigned shift = (byte_addr & 4) ? 32 : 0;
        word = (word & ~(uint64_t(0xffffffffu) << shift)) | (uint64_t(value) << shift);
    }

    uint32_t Read32(uint32_t byte_addr) const {
        auto it = words_.find(byte_addr >> 3);
        uint64_t word = it == words_.end() ? kPattern : it->second;
        return (byte_addr & 4) ? uint32_t(word >> 32) : uint32_t(word);
    }

    void Step(bool we, bool rd, uint32_t word_addr, uint8_t burstcnt,
              uint64_t din, uint8_t be) {
        dout_ready_ = false;
        if (!reads_pending_.empty()) {
            Read &job = reads_pending_.front();
            if (job.latency) {
                --job.latency;
            } else {
                auto it = words_.find(job.address);
                dout_ = it == words_.end() ? kPattern : it->second;
                dout_ready_ = true;
                if (!--job.remaining) reads_pending_.pop_front();
                else ++job.address;
            }
        }
        if (we) {
            if (write_remaining_ == 0) {
                if (burstcnt == 0 || burstcnt > 8) std::exit(2);
                write_base_ = word_addr;
                write_count_ = burstcnt;
                write_remaining_ = burstcnt;
            } else if (word_addr != write_base_ || burstcnt != write_count_) {
                std::fprintf(stderr, "write command changed within burst\n");
                std::exit(2);
            }
            const uint32_t write_addr = write_base_ + (write_count_ - write_remaining_);
            uint64_t &word = words_[write_addr];
            if (!initialized_[write_addr]) {
                word = kPattern;
                initialized_[write_addr] = true;
            }
            for (unsigned byte = 0; byte < 8; ++byte) {
                if (be & (1u << byte)) {
                    const uint64_t mask = uint64_t(0xff) << (byte * 8);
                    word = (word & ~mask) | (din & mask);
                }
            }
            --write_remaining_;
            ++writes_;
        }
        if (rd) {
            if (!burstcnt) std::exit(2);
            reads_pending_.push_back({word_addr, burstcnt, 3});
            reads_ += burstcnt;
        }
    }

    uint64_t dout() const { return dout_; }
    bool dout_ready() const { return dout_ready_; }
    size_t reads() const { return reads_; }
    size_t writes() const { return writes_; }

private:
    struct Read { uint32_t address; unsigned remaining; unsigned latency; };
    std::unordered_map<uint32_t, uint64_t> words_;
    std::unordered_map<uint32_t, bool> initialized_;
    std::deque<Read> reads_pending_;
    uint64_t dout_ = 0;
    bool dout_ready_ = false;
    size_t reads_ = 0, writes_ = 0;
    uint32_t write_base_ = 0;
    unsigned write_count_ = 0, write_remaining_ = 0;
};

class Testbench {
public:
    Testbench() : dut_(new Vengine_fill_batch_dut) {}
    ~Testbench() { dut_->final(); }

    void Tick(AvalonMemory &mem) {
        dut_->DDRAM_BUSY = 0;
        dut_->DDRAM_DOUT = mem.dout();
        dut_->DDRAM_DOUT_READY = mem.dout_ready();
        dut_->clk = 0;
        dut_->eval();
        dut_->clk = 1;
        dut_->eval();
        mem.Step(dut_->DDRAM_WE, dut_->DDRAM_RD, dut_->DDRAM_ADDR,
                 dut_->DDRAM_BURSTCNT, dut_->DDRAM_DIN, dut_->DDRAM_BE);
    }

    Vengine_fill_batch_dut &dut() { return *dut_; }

private:
    std::unique_ptr<Vengine_fill_batch_dut> dut_;
};

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Testbench tb;
    AvalonMemory mem;
    auto &dut = tb.dut();
    std::vector<uint32_t> expected(kCanvasWidth * kCanvasHeight, uint32_t(kPattern));

    constexpr unsigned kCount = 64;
    for (unsigned i = 0; i < kCount; ++i) {
        const uint32_t x = (i * 7) % (kCanvasWidth - 3);
        const uint32_t y = (i * 11) % (kCanvasHeight - 2);
        const uint32_t width = 2 + (i & 1);
        const uint32_t height = 2;
        const uint32_t color = 0xff000000u | (i * 0x00020409u);
        const uint32_t words[8] = {
            kCanvasBase + y * kCanvasPitch + x * 4, kCanvasPitch,
            width, height, color, 0, 0, 0
        };
        for (unsigned w = 0; w < 8; ++w)
            mem.Seed32(kDescriptorBase + i * 32 + w * 4, words[w]);
        for (uint32_t row = 0; row < height; ++row)
            for (uint32_t col = 0; col < width; ++col)
                expected[(y + row) * kCanvasWidth + x + col] = color;
    }

    dut.reset = 1;
    dut.start = 0;
    dut.descriptor_base = kDescriptorBase;
    dut.count = kCount;
    for (int i = 0; i < 4; ++i) tb.Tick(mem);
    dut.reset = 0;
    tb.Tick(mem);
    dut.start = 1;
    tb.Tick(mem);
    dut.start = 0;

    unsigned cycles = 0;
    while (!dut.done) {
        tb.Tick(mem);
        if (++cycles > 200000) {
            std::fprintf(stderr, "FAIL: FILL_BATCH did not complete\n");
            return 1;
        }
    }
    while (dut.busy) tb.Tick(mem);
    for (int i = 0; i < 32; ++i) tb.Tick(mem);

    unsigned mismatches = 0;
    for (uint32_t y = 0; y < kCanvasHeight; ++y) {
        for (uint32_t x = 0; x < kCanvasWidth; ++x) {
            uint32_t got = mem.Read32(kCanvasBase + y * kCanvasPitch + x * 4);
            uint32_t want = expected[y * kCanvasWidth + x];
            if (got != want && mismatches++ < 12)
                std::fprintf(stderr, "pixel (%u,%u): expected %08x got %08x\n",
                             x, y, want, got);
        }
    }
    if (mismatches) {
        std::fprintf(stderr, "FAIL: %u fill-batch pixel mismatches\n", mismatches);
        return 1;
    }
    if (mem.reads() != kCount * 5) {
        std::fprintf(stderr, "FAIL: expected %u descriptor reads, got %zu\n",
                     kCount * 5, mem.reads());
        return 1;
    }
    std::printf("PASS: FILL_BATCH %u ordered descriptors, %u cycles, %zu reads, %zu writes\n",
                kCount, cycles, mem.reads(), mem.writes());
    return 0;
}
