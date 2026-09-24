// Verilator testbench for blit_blend (BLIT_BLEND BLIT-007 and flagged draws
// BLIT-008) through the real ddram_adapter against a burst-honoring
// Avalon-MM memory model with variable read latency and DDRAM_BUSY stalls.
//
// Randomized rectangles cover all four source/destination 8-byte alignment
// combinations, pitches with odd pixel counts (so alignment changes from row
// to row), widths from 1 pixel upward, RGBA modulation including 0 and 255,
// blended and plain stores, and both mirror axes. Source alpha is biased
// towards 0 and 255. After each command every
// pixel in a margin around the destination must match sim/blend_ref.h
// inside the rectangle and be unchanged outside it, and the source must be
// unchanged. Fixed cases then check fully transparent sources perform no
// writes, opaque sources copy exactly, zero-size commands complete, and a
// larger rectangle reports its cycle cost.

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <memory>
#include <random>
#include <unordered_map>

#include "Vengine_blend_dut.h"
#include "verilated.h"
#include "../sim/blend_ref.h"

namespace {

std::mt19937 rng(0x6e646c42);

uint32_t Rand(uint32_t n) { return std::uniform_int_distribution<uint32_t>(0, n - 1)(rng); }

class AvalonMemory {
public:
    uint32_t Read32(uint32_t byte_addr) const {
        const uint64_t w = Word(byte_addr >> 3);
        return (byte_addr & 4) ? uint32_t(w >> 32) : uint32_t(w);
    }

    void Write32(uint32_t byte_addr, uint32_t value) {
        uint64_t word = Word(byte_addr >> 3);
        if (byte_addr & 4) word = (word & 0xffffffffull) | (uint64_t(value) << 32);
        else word = (word & ~0xffffffffull) | value;
        words_[byte_addr >> 3] = word;
    }

    uint64_t Word(uint32_t word_addr) const {
        auto it = words_.find(word_addr);
        return it == words_.end() ? 0x0123456789abcdefull ^ (uint64_t(word_addr) * 0x9e3779b97f4a7c15ull)
                                  : it->second;
    }

    void Step(bool we, bool rd, uint32_t word_addr, uint8_t burstcnt, uint64_t din, uint8_t be) {
        dout_ready_ = false;
        if (!jobs_.empty()) {
            Job &job = jobs_.front();
            if (job.latency > 0) {
                --job.latency;
            } else if (Rand(8) != 0) {
                dout_ready_ = true;
                dout_ = Word(job.addr);
                ++job.addr;
                if (--job.remaining == 0) jobs_.pop_front();
            }
        }
        if (we) {
            uint64_t word = Word(word_addr);
            for (int i = 0; i < 8; ++i) {
                if (be & (1u << i))
                    word = (word & ~(0xffull << (8 * i))) | (((din >> (8 * i)) & 0xff) << (8 * i));
            }
            words_[word_addr] = word;
            ++writes_;
        } else if (rd) {
            if (burstcnt == 0 || burstcnt > 16) {
                std::fprintf(stderr, "FAIL: bad burstcnt %u\n", burstcnt);
                std::exit(1);
            }
            jobs_.push_back({word_addr, burstcnt, int(latency_ + Rand(jitter_ + 1))});
            reads_ += burstcnt;
        }
    }

    void SetLatency(unsigned base, unsigned jitter) { latency_ = base; jitter_ = jitter; }
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
    size_t writes_ = 0, reads_ = 0;
    unsigned latency_ = 3, jitter_ = 0;
};

class Testbench {
public:
    Testbench() : dut_(new Vengine_blend_dut) {}
    ~Testbench() { dut_->final(); }

    void Tick(AvalonMemory &mem) {
        dut_->DDRAM_BUSY = busy_ ? (Rand(4) == 0) : 0;
        dut_->DDRAM_DOUT = mem.dout();
        dut_->DDRAM_DOUT_READY = mem.dout_ready();
        dut_->clk = 0;
        dut_->eval();
        const bool accepted = !dut_->DDRAM_BUSY;
        mem.Step(accepted && dut_->DDRAM_WE, accepted && dut_->DDRAM_RD, dut_->DDRAM_ADDR,
                 dut_->DDRAM_BURSTCNT, dut_->DDRAM_DIN, dut_->DDRAM_BE);
        dut_->clk = 1;
        dut_->eval();
        ++cycles_;
    }

    void SetBusy(bool busy) { busy_ = busy; }
    uint64_t cycles() const { return cycles_; }
    Vengine_blend_dut &dut() { return *dut_; }

private:
    std::unique_ptr<Vengine_blend_dut> dut_;
    bool busy_ = false;
    uint64_t cycles_ = 0;
};

struct Rect {
    uint32_t dst, dst_pitch, src, src_pitch;
    uint16_t width, height;
    uint32_t mod;   // RGBA; BLIT_BLEND's 8-bit form is 0x00ffffff | m << 24
    bool blend = true, mirror_x = false, mirror_y = false;
    bool key = false;
    uint32_t key_value = 0;
    uint32_t mode_flags = 0;   // BLIT-009 flags word with bit 4, or 0 for blend/store
};

// A random valid BLIT-009 mode (descriptor flags with bit 4).
uint32_t RandomMode() {
    const uint32_t op_c = 1 + Rand(5), op_a = 1 + Rand(5);
    const int single = (op_c == 1 && op_a == 1) ? int(Rand(2)) : 0;
    return noodles_ref_mode(1 + Rand(10), 1 + Rand(10), op_c, 1 + Rand(10), 1 + Rand(10), op_a,
                            single);
}

uint32_t AlphaMod(uint8_t m) { return 0x00ffffffu | (uint32_t(m) << 24); }

uint64_t Run(Testbench &tb, AvalonMemory &mem, const Rect &r) {
    Vengine_blend_dut &dut = tb.dut();
    const uint64_t begin = tb.cycles();
    dut.start = 1;
    dut.dst_addr = r.dst; dut.dst_pitch = r.dst_pitch;
    dut.src_addr = r.src; dut.src_pitch = r.src_pitch;
    dut.width = r.width; dut.height = r.height;
    dut.mod = r.mod;
    dut.blend = r.blend; dut.mirror_x = r.mirror_x; dut.mirror_y = r.mirror_y;
    dut.key_enable = r.key; dut.key_value = r.key_value;
    dut.mode_en = (r.mode_flags & 0x10u) != 0; dut.mode = r.mode_flags >> 8;
    tb.Tick(mem);
    dut.start = 0;
    uint64_t guard = 0;
    while (!dut.done) {
        tb.Tick(mem);
        if (++guard > 5000000) { std::fprintf(stderr, "FAIL: blend never completed\n"); std::exit(1); }
    }
    const uint64_t cost = tb.cycles() - begin;
    while (!dut.adapter_idle) {
        tb.Tick(mem);
        if (++guard > 5000000) { std::fprintf(stderr, "FAIL: adapter never drained\n"); std::exit(1); }
    }
    if (dut.busy) { std::fprintf(stderr, "FAIL: busy after done\n"); std::exit(1); }
    return cost;
}

uint32_t RandomPixel() {
    const uint32_t pick = Rand(4);
    const uint32_t alpha = pick == 0 ? 0 : pick == 1 ? 255 : Rand(256);
    return (alpha << 24) | (Rand(1u << 24));
}

// Seeds src/dst, runs, and checks a one-pixel-plus margin around dst.
void CheckCase(Testbench &tb, AvalonMemory &mem, const Rect &r, const char *label) {
    const int margin = 3;
    std::unordered_map<uint32_t, uint32_t> expect;
    for (int y = -1; y <= int(r.height); ++y) {
        for (int x = -margin; x < int(r.width) + margin; ++x) {
            const uint32_t addr = r.dst + uint32_t(int64_t(y) * r.dst_pitch + int64_t(x) * 4);
            const uint32_t value = Rand(0xffffffffu);
            mem.Write32(addr, value);
            expect[addr] = value;
        }
    }
    std::unordered_map<uint32_t, uint32_t> source;
    for (uint32_t y = 0; y < r.height; ++y) {
        for (uint32_t x = 0; x < r.width; ++x) {
            const uint32_t addr = r.src + y * r.src_pitch + x * 4;
            const uint32_t value = (r.key && Rand(3) == 0) ? r.key_value : RandomPixel();
            mem.Write32(addr, value);
            source[addr] = value;
        }
    }
    for (uint32_t y = 0; y < r.height; ++y) {
        for (uint32_t x = 0; x < r.width; ++x) {
            const uint32_t d = r.dst + y * r.dst_pitch + x * 4;
            const uint32_t sx = r.mirror_x ? r.width - 1 - x : x;
            const uint32_t sy = r.mirror_y ? r.height - 1 - y : y;
            const uint32_t sp = source[r.src + sy * r.src_pitch + sx * 4];
            if (!(r.key && sp == r.key_value))
                expect[d] = noodles_mode_ref(sp, expect[d], r.mod,
                                             r.mode_flags ? r.mode_flags : (r.blend ? 0x2u : 0u));
        }
    }
    std::unordered_map<uint32_t, uint32_t> before;
    for (const auto &[addr, want] : expect) before[addr] = mem.Read32(addr);
    Run(tb, mem, r);
    int bad = 0;
    for (int y = -1; y <= int(r.height); ++y) {
        for (int x = -margin; x < int(r.width) + margin; ++x) {
            const uint32_t addr = r.dst + uint32_t(int64_t(y) * r.dst_pitch + int64_t(x) * 4);
            const uint32_t got = mem.Read32(addr), want = expect[addr];
            if (got == want) continue;
            if (bad++ == 0)
                std::fprintf(stderr, "FAIL %s: dst=%08x pitch=%u src=%08x spitch=%u %ux%u mod=%08x "
                             "blend=%d mx=%d my=%d\n", label, r.dst, r.dst_pitch, r.src,
                             r.src_pitch, r.width, r.height, r.mod, r.blend, r.mirror_x, r.mirror_y);
            if (bad <= 24) {
                uint32_t match = 0xffffffffu;
                for (const auto &[sa, sv] : source)
                    if (noodles_mode_ref(sv, before[addr], r.mod,
                                         r.mode_flags ? r.mode_flags : (r.blend ? 0x2u : 0u)) == got) {
                        match = sa;
                        break;
                    }
                std::fprintf(stderr, "  x=%d y=%d at %08x got %08x want %08x orig %08x from-src %08x\n",
                             x, y, addr, got, want, before[addr], match);
            }
        }
    }
    if (bad) {
        std::fprintf(stderr, "  %d mismatches\n", bad);
        std::exit(1);
    }
    for (const auto &[addr, want] : source) {
        if (mem.Read32(addr) != want) {
            std::fprintf(stderr, "FAIL %s: source modified at %08x\n", label, addr);
            std::exit(1);
        }
    }
}

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Testbench tb;
    AvalonMemory mem;
    Vengine_blend_dut &dut = tb.dut();

    dut.reset = 1;
    dut.start = 0;
    for (int i = 0; i < 4; ++i) tb.Tick(mem);
    dut.reset = 0;
    tb.Tick(mem);

    // Randomized geometry, alignment, latency and bus stalls.
    int cases = 0;
    for (int i = 0; i < 4000; ++i) {
        mem.SetLatency(Rand(12), Rand(8));
        tb.SetBusy(Rand(2));
        Rect r;
        r.width = uint16_t(1 + (Rand(3) == 0 ? Rand(70) : Rand(12)));
        r.height = uint16_t(1 + Rand(6));
        r.dst_pitch = (r.width + Rand(5)) * 4;
        r.src_pitch = (r.width + Rand(5)) * 4;
        r.dst = 0x31000000u + Rand(64) * 4;
        r.src = 0x33000000u + Rand(64) * 4;
        const uint32_t m = Rand(4);
        r.mod = m == 0 ? 0xffffffffu : m == 1 ? AlphaMod(0) : m == 2 ? AlphaMod(uint8_t(Rand(256)))
                                                                    : Rand(0xffffffffu);
        r.blend = Rand(4) != 0;
        r.mirror_x = Rand(2);
        r.mirror_y = Rand(2);
        // sprite_batch's rerouted copies: identity modulation, plain store,
        // optional colour key.
        if (Rand(3) == 0) {
            r.mod = 0xffffffffu;
            r.blend = false;
            r.mirror_x = r.mirror_y = false;
        }
        r.key = Rand(3) == 0;
        r.key_value = RandomPixel();
        if (Rand(3) == 0) r.mode_flags = RandomMode();
        CheckCase(tb, mem, r, "random");
        ++cases;
    }

    // All four alignment pairings with a two-pixel-wide rectangle.
    for (uint32_t so = 0; so < 2; ++so)
        for (uint32_t d = 0; d < 2; ++d)
            for (int mirror = 0; mirror < 4; ++mirror) {
                Rect r{0x31100000u + d * 4, 2 * 4 + 4, 0x33100000u + so * 4, 2 * 4, 2, 5, AlphaMod(200)};
                r.mirror_x = mirror & 1;
                r.mirror_y = mirror & 2;
                CheckCase(tb, mem, r, "alignment");
            }

    // Fully transparent source: no DDRAM writes at all.
    tb.SetBusy(false);
    mem.SetLatency(4, 0);
    {
        Rect r{0x31200000u, 64 * 4, 0x33200000u, 64 * 4, 64, 4, AlphaMod(255)};
        for (uint32_t y = 0; y < r.height; ++y)
            for (uint32_t x = 0; x < r.width; ++x)
                mem.Write32(r.src + y * r.src_pitch + x * 4, 0x00abcdefu);
        const size_t before = mem.writes();
        Run(tb, mem, r);
        if (mem.writes() != before) {
            std::fprintf(stderr, "FAIL: transparent blend issued %zu writes\n", mem.writes() - before);
            return 1;
        }
    }

    // Modulation zero: also no writes, whatever the source alpha.
    {
        Rect r{0x31200000u, 64 * 4, 0x33200000u, 64 * 4, 64, 4, AlphaMod(0)};
        for (uint32_t y = 0; y < r.height; ++y)
            for (uint32_t x = 0; x < r.width; ++x)
                mem.Write32(r.src + y * r.src_pitch + x * 4, 0xff123456u);
        const size_t before = mem.writes();
        Run(tb, mem, r);
        if (mem.writes() != before) {
            std::fprintf(stderr, "FAIL: mod=0 blend wrote\n");
            return 1;
        }
    }

    // Opaque source copies exactly, including destination alpha 255.
    {
        Rect r{0x31300004u, 33 * 4, 0x33300000u, 40 * 4, 31, 3, AlphaMod(255)};
        for (uint32_t y = 0; y < r.height; ++y)
            for (uint32_t x = 0; x < r.width; ++x) {
                mem.Write32(r.src + y * r.src_pitch + x * 4, 0xff000000u | (y << 16) | x);
                mem.Write32(r.dst + y * r.dst_pitch + x * 4, 0x12345678u);
            }
        Run(tb, mem, r);
        for (uint32_t y = 0; y < r.height; ++y)
            for (uint32_t x = 0; x < r.width; ++x)
                if (mem.Read32(r.dst + y * r.dst_pitch + x * 4) != (0xff000000u | (y << 16) | x)) {
                    std::fprintf(stderr, "FAIL: opaque blend is not a copy at %u,%u\n", x, y);
                    return 1;
                }
    }

    // Zero-size commands complete without memory traffic.
    {
        const size_t reads = mem.reads(), writes = mem.writes();
        Run(tb, mem, {0x31000000u, 64, 0x33000000u, 64, 0, 5, AlphaMod(255)});
        Run(tb, mem, {0x31000000u, 64, 0x33000000u, 64, 5, 0, AlphaMod(255)});
        if (mem.reads() != reads || mem.writes() != writes) {
            std::fprintf(stderr, "FAIL: zero-size blend touched memory\n");
            return 1;
        }
    }

    // Throughput sample: 128x16 half-transparent sprite, fixed latency.
    uint64_t cost;
    {
        Rect r{0x31400000u, 800 * 4, 0x33400000u, 128 * 4, 128, 16, AlphaMod(255)};
        for (uint32_t y = 0; y < r.height; ++y)
            for (uint32_t x = 0; x < r.width; ++x)
                mem.Write32(r.src + y * r.src_pitch + x * 4, 0x80406080u);
        mem.SetLatency(10, 0);
        cost = Run(tb, mem, r);
    }

    std::printf("PASS: blit_blend %d randomized rects + alignment/transparent/opaque/zero-size cases; "
                "128x16 blend in %llu cycles (%.2f px/cycle)\n",
                cases, static_cast<unsigned long long>(cost), 128.0 * 16 / double(cost));
    return 0;
}
