// Verilator testbench for sprite_batch (the multi-descriptor sequencer
// CMDQ's SPRITE_BATCH opcode dispatches to) driven straight through
// ddram_adapter's real DDRAM_* pins, against the same burst-aware
// behavioral Avalon-MM memory model tb_blit_copy64.cpp already validated.
// Descriptors are seeded directly in DRAM at sprite_batch's fixed
// DESCRIPTOR_BASE (0x3002_2000), matching how noodles_link_upload() lands
// the host's descriptor array in production. This is the first simulation
// coverage of sprite_batch's own DESC_REQ/DESC_WAIT/LAUNCH/COPY loop
// running more than one descriptor back to back -- reproducing (or ruling
// out) the "present failed"/ring-stuck hang stress-demo's sprites-batch
// mode hits deterministically on real hardware.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <unordered_map>

#include <random>
#include <vector>

#include "Vengine_sprite_batch_dut.h"
#include "../sim/blend_ref.h"
#include "verilated.h"
#include "../lib/noodles_link.h"

namespace {

constexpr uint64_t kFillPattern = 0xEEEEEEEEEEEEEEEEull;
constexpr int kReadLatency = 3;
constexpr uint32_t kDescriptorBase = 0x3002'2000u;

// Same behavioral Avalon-MM memory as tb_blit_copy64.cpp: word-addressed (8
// bytes/word), honors DDRAM_BURSTCNT by streaming that many consecutive
// words back once a read is accepted.
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
            jobs_.push_back({word_addr, burstcnt, kReadLatency});
            reads_ += burstcnt;
        }
    }

    uint64_t dout() const { return dout_; }
    bool dout_ready() const { return dout_ready_; }
    size_t writes() const { return writes_; }
    size_t reads() const { return reads_; }

private:
    struct Job { uint32_t addr; unsigned remaining; int latency; };
    std::unordered_map<uint32_t, uint64_t> words_;
    std::deque<Job> jobs_;
    bool dout_ready_ = false;
    uint64_t dout_ = 0;
    size_t writes_ = 0;
    size_t reads_ = 0;
};

class Testbench {
public:
    Testbench() : dut_(new Vengine_sprite_batch_dut) {}
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

    Vengine_sprite_batch_dut &dut() { return *dut_; }

private:
    std::unique_ptr<Vengine_sprite_batch_dut> dut_;
};

int Fail(const char *msg) {
    std::fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

// Descriptor word layout, matching sprite_batch.sv's comment: dst,
// dst_pitch, width, height, key, src, src_pitch, flags (bit 0 = key_enable).
void SeedDescriptor(AvalonMemory &mem, unsigned index, uint32_t dst, uint32_t dst_pitch,
                    uint32_t width, uint32_t height, uint32_t key, uint32_t src,
                    uint32_t src_pitch, uint32_t flags) {
    const uint32_t base = kDescriptorBase + index * 32;
    const uint32_t words[8] = {dst, dst_pitch, width, height, key, src, src_pitch, flags};
    for (int i = 0; i < 8; ++i) mem.Seed32(base + i * 4, words[i]);
}

uint32_t SourcePixel(uint32_t row, uint32_t col) { return 0xB0000000u | (row << 8) | col; }

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    Testbench tb;
    AvalonMemory mem;
    Vengine_sprite_batch_dut &dut = tb.dut();

    dut.reset = 1;
    dut.start = 0;
    for (int i = 0; i < 4; ++i) tb.Tick(mem);
    dut.reset = 0;
    tb.Tick(mem);

    // Reproduce stress-demo's sprites-batch mode as closely as possible:
    // 64 descriptors, one shared 48x48 source sprite per descriptor (like
    // stress_demo.c's SPRITE_SRC_ADDR), each landing at a distinct
    // destination offset (like each bouncing sprite's own screen position),
    // colorkey enabled with a border pattern (colorkey along row/col 0,
    // opaque everywhere else) -- NOT the checkerboard key-checker uses,
    // matching sprites-batch's actual content.
    constexpr unsigned kCount = 64;
    constexpr uint32_t kSpriteW = 48, kSpriteH = 48;
    constexpr uint32_t kSrcPitch = kSpriteW * 4;
    constexpr uint32_t kDstPitch = NOODLES_BUFFER_PITCH;
    constexpr uint32_t kKeyColor = 0xFF00FF00u;
    constexpr uint32_t kSrcBase = 0x4000'0000u;  // clear of the destination span below
    constexpr uint32_t kDstBase = 0x3120'0000u;  // back buffer, like stress-demo

    for (unsigned s = 0; s < kCount; ++s) {
        const uint32_t src = kSrcBase;  // one shared uploaded sprite bitmap
        // Each descriptor's 48-row destination footprint (kSpriteH rows of
        // kDstPitch bytes each) must not overlap any other descriptor's --
        // a tight per-sprite x-offset (e.g. s*64*4) aliases against
        // kDstPitch, landing one sprite's
        // rows inside another's. Space sprites a full footprint apart so
        // no two descriptors can ever address the same byte.
        const uint32_t dst = kDstBase + s * (kSpriteH * kDstPitch);
        SeedDescriptor(mem, s, dst, kDstPitch, kSpriteW, kSpriteH, kKeyColor, src, kSrcPitch,
                       /*flags=*/1);
    }
    // The source bitmap is uploaded once and shared by every descriptor,
    // exactly like stress-demo's single SPRITE_SRC_ADDR reused across all
    // 64 sprites -- content differs only by row/col, not by which
    // descriptor is copying it.
    for (uint32_t row = 0; row < kSpriteH; ++row) {
        for (uint32_t col = 0; col < kSpriteW; ++col) {
            const bool border = (row == 0 || col == 0 || row == kSpriteH - 1 ||
                                 col == kSpriteW - 1);
            mem.Seed32(kSrcBase + row * kSrcPitch + col * 4,
                      border ? kKeyColor : SourcePixel(row, col));
        }
    }

    dut.start = 1;
    dut.count = kCount;
    tb.Tick(mem);
    dut.start = 0;

    int guard = 0;
    do {
        tb.Tick(mem);
        if (++guard > 2000000) {
            std::fprintf(stderr, "sprite_batch never completed (busy=%d) after %d cycles\n",
                         dut.busy, guard);
            return Fail("batch of 64 descriptors hung");
        }
    } while (!dut.done);
    tb.Tick(mem);

    // Verify every one of the 64 descriptors: colorkey border pixels must
    // stay untouched (background fill), interior pixels must match the
    // shared source sprite's (row,col)-encoded content exactly.
    unsigned mismatches = 0;
    for (unsigned s = 0; s < kCount && mismatches < 40; ++s) {
        const uint32_t dst = kDstBase + s * (kSpriteH * kDstPitch);
        for (uint32_t row = 0; row < kSpriteH && mismatches < 40; ++row) {
            for (uint32_t col = 0; col < kSpriteW && mismatches < 40; ++col) {
                const bool border = (row == 0 || col == 0 || row == kSpriteH - 1 ||
                                     col == kSpriteW - 1);
                const uint32_t byte_addr = dst + row * kDstPitch + col * 4;
                const uint32_t word_addr = byte_addr >> 3;
                const bool upper = (byte_addr >> 2) & 1;
                const uint64_t word = mem.Word(word_addr);
                const uint32_t got = upper ? uint32_t(word >> 32) : uint32_t(word);
                const uint32_t expected = border ? uint32_t(kFillPattern) : SourcePixel(row, col);
                if (got != expected) {
                    std::fprintf(stderr, "sprite %u (row=%u,col=%u)%s: expected 0x%08x got 0x%08x\n",
                                 s, row, col, border ? " [keyed border]" : "", expected, got);
                    ++mismatches;
                }
            }
        }
    }
    if (mismatches != 0) {
        return Fail("batch of 64 descriptors produced pixel mismatches");
    }

    std::printf("PASS: sprite_batch %u descriptors of %ux%u, completed in %d cycles, %zu reads, %zu writes\n",
               kCount, kSpriteW, kSpriteH, guard, mem.reads(), mem.writes());

    // BLIT-008: a mixed batch of plain copies, keyed copies and flagged
    // draws (blend, mirror-x, mirror-y, RGBA modulation), all overlapping on
    // one canvas, must match a sequential software model: each descriptor
    // sees every earlier one's completed writes.
    unsigned mixed_flagged = 0, mixed_total = 0;
    for (unsigned round = 0; round < 8; ++round) {
        std::mt19937 rng(0x62617463 + round);
        auto rnd = [&](uint32_t n) { return uint32_t(rng() % n); };
        constexpr uint32_t kCanvasW = 96, kCanvasH = 64, kMargin = 2;
        constexpr uint32_t kCanvasPitch = (kCanvasW + 2 * kMargin + 1) * 4;
        constexpr uint32_t kCanvas = 0x3130'0000u + kMargin * 4 + kCanvasPitch;
        constexpr unsigned kMixed = 40;
        auto read32 = [&](uint32_t addr) {
            const uint64_t w = mem.Word(addr >> 3);
            return (addr & 4) ? uint32_t(w >> 32) : uint32_t(w);
        };
        // Model covers the canvas plus a margin that must stay untouched.
        std::unordered_map<uint32_t, uint32_t> model;
        for (int y = -1; y <= int(kCanvasH); ++y)
            for (int x = -int(kMargin); x < int(kCanvasW + kMargin); ++x) {
                const uint32_t a = kCanvas + uint32_t(y * int(kCanvasPitch) + x * 4);
                const uint32_t v = rng();
                mem.Seed32(a, v);
                model[a] = v;
            }
        unsigned flagged_count = 0;
        for (unsigned d = 0; d < kMixed; ++d) {
            const uint32_t w = 1 + rnd(40), h = 1 + rnd(20);
            const uint32_t dx = rnd(kCanvasW - w + 1), dy = rnd(kCanvasH - h + 1);
            const uint32_t spitch = (w + rnd(3)) * 4;
            const uint32_t src = 0x4010'0000u + d * 0x4000u + rnd(2) * 4;
            const uint32_t dst = kCanvas + dy * kCanvasPitch + dx * 4;
            const uint32_t kind = rnd(4);
            uint32_t flags = 0, word4 = 0;
            if (kind == 0) {
                flags = 0;
            } else if (kind == 1) {
                flags = 1;
                word4 = 0x00123456u;
            } else {
                flags = (rnd(4) != 0 ? 2u : 0u) | (rnd(2) ? 4u : 0u) | (rnd(2) ? 8u : 0u);
                if (!flags) flags = 4;
                if (rnd(3) == 0) {   // BLIT-009 explicit blend mode replaces bit 1
                    const uint32_t op_c = 1 + rnd(5), op_a = 1 + rnd(5);
                    const int single = (op_c == 1 && op_a == 1) ? int(rnd(2)) : 0;
                    flags = (flags & 0xcu) |
                            noodles_ref_mode(1 + rnd(10), 1 + rnd(10), op_c, 1 + rnd(10),
                                             1 + rnd(10), op_a, single);
                }
                word4 = rnd(3) == 0 ? 0xffffffffu : uint32_t(rng());
                ++flagged_count;
            }
            std::vector<uint32_t> pixels(w * h);
            for (uint32_t y = 0; y < h; ++y)
                for (uint32_t x = 0; x < w; ++x) {
                    const uint32_t pick = rnd(5);
                    uint32_t v = pick == 0 ? 0x00123456u : (pick == 1 ? 0u : rnd(256)) << 24 |
                                                               (rng() & 0xffffffu);
                    if (pick == 2) v |= 0xff000000u;
                    pixels[y * w + x] = v;
                    mem.Seed32(src + y * spitch + x * 4, v);
                }
            for (uint32_t y = 0; y < h; ++y)
                for (uint32_t x = 0; x < w; ++x) {
                    const uint32_t a = dst + y * kCanvasPitch + x * 4;
                    if (flags & 0x1e) {
                        const uint32_t sx = (flags & 4) ? w - 1 - x : x;
                        const uint32_t sy = (flags & 8) ? h - 1 - y : y;
                        model[a] = noodles_mode_ref(pixels[sy * w + sx], model[a], word4, flags);
                    } else if (!(flags & 1) || pixels[y * w + x] != word4) {
                        model[a] = pixels[y * w + x];
                    }
                }
            SeedDescriptor(mem, d, dst, kCanvasPitch, w, h, word4, src, spitch, flags);
        }
        const size_t writes_before = mem.writes();
        dut.start = 1;
        dut.count = kMixed;
        tb.Tick(mem);
        dut.start = 0;
        int mixed_cycles = 0;
        do {
            tb.Tick(mem);
            if (++mixed_cycles > 4000000) return Fail("mixed flagged batch hung");
        } while (!dut.done);
        for (int i = 0; i < 64; ++i) tb.Tick(mem);
        unsigned bad = 0;
        for (const auto &[a, want] : model) {
            const uint32_t got = read32(a);
            if (got != want && bad++ < 12)
                std::fprintf(stderr, "mixed batch at %08x: got %08x want %08x\n", a, got, want);
        }
        if (bad) {
            std::fprintf(stderr, "%u mismatches\n", bad);
            return Fail("mixed flagged batch produced pixel mismatches");
        }
        (void)writes_before;
        mixed_flagged += flagged_count;
        mixed_total += kMixed;
        if (round == 7)
            std::printf("PASS: sprite_batch 8 mixed batches, %u overlapping descriptors (%u flagged, "
                        "odd widths and unaligned sources included) match the sequential model\n",
                        mixed_total, mixed_flagged);
    }
    return 0;
}
