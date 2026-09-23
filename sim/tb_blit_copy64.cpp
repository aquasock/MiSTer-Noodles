// Verilator testbench for blit_copy64 (sprite_batch's actual production copy
// engine, BLIT-003/BLIT-006 via BLIT_COPY_KEY) driven straight through
// ddram_adapter's real DDRAM_* pins (DDR-003/DDR-007), against a behavioral
// Avalon-MM memory model that honors DDRAM_BURSTCNT: a read command is
// accepted once and then streams `burstcnt` consecutive words back over
// consecutive cycles with no further command, matching the real DDR3
// target's burst semantics (see ai/core-reference.md DDR-007 and the
// aquasock/MiSTer-Raster arbiter this project's own history already treats
// as the proven reference for that assumption). This is the first
// simulation coverage of blit_copy64 at all -- previously validated only on
// real hardware via sprite_batch/stress_demo.
//
// Two runs: a plain copy over a source/destination pair whose row pitch is
// deliberately larger than the tight-packed row width, so within-row rd64
// addresses are contiguous (burst-eligible) but each row boundary breaks
// contiguity (forcing the adapter to re-form a new, shorter burst) -- then a
// BLIT_COPY_KEY-style run (key_enable=1) verifying keyed source pixels are
// still read (every source pixel must be inspected to check the key) but not
// written, exactly like tb_blit_copy.cpp's existing check for the scalar
// engine.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <unordered_map>

#include "Vengine_copy64_dut.h"
#include "verilated.h"

namespace {

constexpr uint64_t kFillPattern = 0xEEEEEEEEEEEEEEEEull;
constexpr int kReadLatency = 3;

// Behavioral Avalon-MM memory: word-addressed (8 bytes/word), honors
// DDRAM_BURSTCNT by streaming that many consecutive words back once a read
// is accepted, with no further RD assertion required for the remaining
// beats -- the same assumption DDR-007's adapter change relies on.
class AvalonMemory {
public:
    void Seed32(uint32_t byte_addr, uint32_t value) {
        uint64_t &word = words_[byte_addr >> 3];
        const uint64_t mask = (byte_addr & 4) ? 0xFFFFFFFF00000000ull : 0x00000000FFFFFFFFull;
        const uint64_t placed = (byte_addr & 4) ? (uint64_t(value) << 32) : uint64_t(value);
        word = (word & ~mask) | placed;
    }

    uint64_t Word(uint32_t word_addr) const {
        auto it = words_.find(word_addr);
        return (it == words_.end()) ? kFillPattern : it->second;
    }

    void Step(bool we, bool rd, uint32_t word_addr, uint8_t burstcnt, uint64_t din, uint8_t be) {
        dout_ready_ = false;
        if (!jobs_.empty()) {
            Job &job = jobs_.front();
            if (job.latency > 0) {
                --job.latency;
            } else {
                dout_ready_ = true;
                auto it = words_.find(job.addr);
                dout_ = (it == words_.end()) ? kFillPattern : it->second;
                ++job.addr;
                --job.remaining;
                if (job.remaining == 0) jobs_.pop_front();
            }
        }

        if (we) {
            auto it = words_.find(word_addr);
            uint64_t word = (it != words_.end()) ? it->second : kFillPattern;
            for (int i = 0; i < 8; ++i) {
                if (be & (1u << i)) {
                    const uint64_t byte = (din >> (8 * i)) & 0xFF;
                    word = (word & ~(0xFFull << (8 * i))) | (byte << (8 * i));
                }
            }
            words_[word_addr] = word;
            ++writes_;
        } else if (rd) {
            if (burstcnt == 0) {
                std::fprintf(stderr, "RD asserted with burstcnt=0\n");
                std::exit(1);
            }
            max_burstcnt_ = std::max<unsigned>(max_burstcnt_, burstcnt);
            jobs_.push_back({word_addr, burstcnt, kReadLatency});
            reads_ += burstcnt;
        }
    }

    uint64_t dout() const { return dout_; }
    bool dout_ready() const { return dout_ready_; }
    size_t writes() const { return writes_; }
    size_t reads() const { return reads_; }
    unsigned max_burstcnt() const { return max_burstcnt_; }

private:
    struct Job { uint32_t addr; unsigned remaining; int latency; };
    std::unordered_map<uint32_t, uint64_t> words_;
    std::deque<Job> jobs_;
    bool dout_ready_ = false;
    uint64_t dout_ = 0;
    size_t writes_ = 0;
    size_t reads_ = 0;
    unsigned max_burstcnt_ = 0;
};

class Testbench {
public:
    Testbench() : dut_(new Vengine_copy64_dut) {}
    ~Testbench() { dut_->final(); }

    void Tick(AvalonMemory &mem) {
        dut_->DDRAM_BUSY = 0;
        dut_->DDRAM_DOUT = mem.dout();
        dut_->DDRAM_DOUT_READY = mem.dout_ready() ? 1 : 0;

        dut_->clk = 0;
        dut_->eval();
        dut_->clk = 1;
        dut_->eval();

        mem.Step(dut_->DDRAM_WE, dut_->DDRAM_RD, dut_->DDRAM_ADDR,
                  dut_->DDRAM_BURSTCNT, dut_->DDRAM_DIN, dut_->DDRAM_BE);
    }

    Vengine_copy64_dut &dut() { return *dut_; }

private:
    std::unique_ptr<Vengine_copy64_dut> dut_;
};

int Fail(const char *msg) {
    std::fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

uint32_t SourcePixel(uint32_t row, uint32_t col) { return 0xB0000000u | (row << 8) | col; }

void RunCopy(Testbench &tb, AvalonMemory &mem, uint32_t dst_addr, uint32_t dst_pitch,
             uint32_t src_addr, uint32_t src_pitch, uint16_t width, uint16_t height,
             bool key_enable, uint32_t key_value) {
    Vengine_copy64_dut &dut = tb.dut();
    dut.start = 1;
    dut.dst_addr = dst_addr; dut.dst_pitch = dst_pitch;
    dut.src_addr = src_addr; dut.src_pitch = src_pitch;
    dut.width = width; dut.height = height;
    dut.key_enable = key_enable ? 1 : 0; dut.key_value = key_value;
    tb.Tick(mem);
    dut.start = 0;

    int guard = 0;
    do {
        tb.Tick(mem);
        if (++guard > 200000) { std::fprintf(stderr, "copy never completed\n"); std::exit(1); }
    } while (!dut.done);
    tb.Tick(mem);
}

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    Testbench tb;
    AvalonMemory mem;
    Vengine_copy64_dut &dut = tb.dut();

    dut.reset = 1;
    dut.start = 0;
    for (int i = 0; i < 4; ++i) tb.Tick(mem);
    dut.reset = 0;
    tb.Tick(mem);

    // Plain copy: width=8 (4 rd64 pairs/row, well within blit_copy64's
    // 8-deep pair FIFO -- exercises a full-row burst), height=3, source row
    // pitch padded 16 bytes beyond the tight-packed 32 bytes so each row
    // boundary breaks rd64 address contiguity and forces the adapter to
    // close one burst and open the next.
    constexpr uint32_t kDstAddr = 0x30001000u;
    constexpr uint32_t kDstPitch = 8 * 4;       // tight-packed destination
    constexpr uint32_t kSrcAddr = 0x30002000u;
    constexpr uint32_t kSrcPitch = 8 * 4 + 16;  // padded: breaks row-to-row contiguity
    constexpr uint16_t kWidth = 8, kHeight = 3;

    for (uint32_t row = 0; row < kHeight; ++row)
        for (uint32_t col = 0; col < kWidth; ++col)
            mem.Seed32(kSrcAddr + row * kSrcPitch + col * 4, SourcePixel(row, col));

    RunCopy(tb, mem, kDstAddr, kDstPitch, kSrcAddr, kSrcPitch, kWidth, kHeight,
            /*key_enable=*/false, /*key_value=*/0);

    for (uint32_t row = 0; row < kHeight; ++row) {
        for (uint32_t col = 0; col < kWidth; ++col) {
            const uint32_t byte_addr = kDstAddr + row * kDstPitch + col * 4;
            const uint32_t word_addr = byte_addr >> 3;
            const bool upper = (byte_addr >> 2) & 1;
            const uint64_t word = mem.Word(word_addr);
            const uint32_t got = upper ? uint32_t(word >> 32) : uint32_t(word);
            if (got != SourcePixel(row, col)) {
                std::fprintf(stderr, "row %u col %u: expected 0x%08x got 0x%08x\n", row, col,
                              SourcePixel(row, col), got);
                return Fail("plain copy pixel mismatch");
            }
        }
    }
    if (mem.max_burstcnt() <= 1) {
        return Fail("adapter never issued a burst (DDR-007 coalescing did not engage)");
    }
    std::printf("PASS: plain blit_copy64 %ux%u, max burstcnt observed=%u\n", kWidth, kHeight,
                mem.max_burstcnt());

    // BLIT_COPY_KEY-style run: checkerboard source, half exactly the key
    // color. Destination is pre-seeded with a known background so a keyed
    // pixel left untouched is distinguishable from a copied one.
    constexpr uint32_t kKeyDstAddr = 0x30003000u;
    constexpr uint32_t kKeyDstPitch = 8 * 4;
    constexpr uint32_t kKeySrcAddr = 0x30004000u;
    constexpr uint32_t kKeySrcPitch = 8 * 4 + 16;
    constexpr uint32_t kKeyColor = 0xCAFEBABEu;
    constexpr uint32_t kBackground = 0xDEADBEEFu;
    auto is_keyed = [](uint32_t row, uint32_t col) { return ((row + col) % 2) == 0; };
    auto key_source_pixel = [&](uint32_t row, uint32_t col) {
        return is_keyed(row, col) ? kKeyColor : SourcePixel(row, col);
    };

    for (uint32_t row = 0; row < kHeight; ++row) {
        for (uint32_t col = 0; col < kWidth; ++col) {
            mem.Seed32(kKeySrcAddr + row * kKeySrcPitch + col * 4, key_source_pixel(row, col));
            mem.Seed32(kKeyDstAddr + row * kKeyDstPitch + col * 4, kBackground);
        }
    }

    const size_t reads_before = mem.reads();
    RunCopy(tb, mem, kKeyDstAddr, kKeyDstPitch, kKeySrcAddr, kKeySrcPitch, kWidth, kHeight,
            /*key_enable=*/true, kKeyColor);
    const size_t reads_issued = mem.reads() - reads_before;

    // blit_copy64 reads one 64-bit word per PAIR of pixels (unlike the
    // scalar tb_blit_copy.cpp reference this comment originally echoed), so
    // "every source pixel inspected" means every pair's word is read --
    // width*height/2 words, not width*height individual pixel reads.
    if (reads_issued != (size_t(kWidth) * kHeight) / 2) {
        std::fprintf(stderr, "expected %u source word reads (every pair inspected), got %zu\n",
                      (unsigned(kWidth) * kHeight) / 2, reads_issued);
        return Fail("keyed run did not read every source pixel");
    }

    for (uint32_t row = 0; row < kHeight; ++row) {
        for (uint32_t col = 0; col < kWidth; ++col) {
            const uint32_t byte_addr = kKeyDstAddr + row * kKeyDstPitch + col * 4;
            const uint32_t word_addr = byte_addr >> 3;
            const bool upper = (byte_addr >> 2) & 1;
            const uint64_t word = mem.Word(word_addr);
            const uint32_t got = upper ? uint32_t(word >> 32) : uint32_t(word);
            const uint32_t expected = is_keyed(row, col) ? kBackground : SourcePixel(row, col);
            if (got != expected) {
                std::fprintf(stderr, "keyed row %u col %u: expected 0x%08x got 0x%08x\n", row, col,
                              expected, got);
                return Fail("keyed copy pixel mismatch");
            }
        }
    }
    std::printf("PASS: keyed blit_copy64 %ux%u, %zu source reads, max burstcnt observed=%u\n",
                kWidth, kHeight, reads_issued, mem.max_burstcnt());

    // Wide-row run: width=48 (24 rd64 pairs/row) forces a single row's
    // fetch to split across multiple bursts, since FIFO_DEPTH=16 pairs is
    // less than a full row -- this is the exact shape sprite_batch's real
    // 48px sprites hit and that no prior test (kWidth=8, single burst per
    // row) ever exercised.
    constexpr uint32_t kWideDstAddr = 0x30020000u;
    constexpr uint32_t kWideDstPitch = 640 * 4;
    constexpr uint32_t kWideSrcAddr = 0x30006000u;
    constexpr uint32_t kWideSrcPitch = 48 * 4;
    constexpr uint16_t kWideWidth = 48, kWideHeight = 6;

    for (uint32_t row = 0; row < kWideHeight; ++row)
        for (uint32_t col = 0; col < kWideWidth; ++col)
            mem.Seed32(kWideSrcAddr + row * kWideSrcPitch + col * 4, SourcePixel(row, col));

    RunCopy(tb, mem, kWideDstAddr, kWideDstPitch, kWideSrcAddr, kWideSrcPitch, kWideWidth,
            kWideHeight, /*key_enable=*/false, /*key_value=*/0);

    unsigned wide_mismatches = 0;
    for (uint32_t row = 0; row < kWideHeight; ++row) {
        for (uint32_t col = 0; col < kWideWidth; ++col) {
            const uint32_t byte_addr = kWideDstAddr + row * kWideDstPitch + col * 4;
            const uint32_t word_addr = byte_addr >> 3;
            const bool upper = (byte_addr >> 2) & 1;
            const uint64_t word = mem.Word(word_addr);
            const uint32_t got = upper ? uint32_t(word >> 32) : uint32_t(word);
            const uint32_t expected = SourcePixel(row, col);
            if (got != expected && wide_mismatches < 300) {
                std::fprintf(stderr, "wide-row row %u col %u: expected 0x%08x got 0x%08x\n", row,
                              col, expected, got);
                ++wide_mismatches;
            }
        }
    }
    if (wide_mismatches != 0) {
        return Fail("wide-row (multi-burst-per-row) copy pixel mismatch");
    }
    std::printf("PASS: wide-row blit_copy64 %ux%u (multi-burst rows), max burstcnt observed=%u\n",
                kWideWidth, kWideHeight, mem.max_burstcnt());

    return 0;
}
