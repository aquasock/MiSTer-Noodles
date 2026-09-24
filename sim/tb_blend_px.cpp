// BLIT-007/008/009 datapath check: blend_px against sim/blend_ref.h.
//
// The datapath is a composition of per-byte stages, so each stage is
// checked exhaustively in isolation and the composition by random vectors:
//   1. every (source alpha, alpha modulation) pair, blended and plain;
//   2. every (source channel, colour modulation) pair, blended and plain;
//   3. every (alpha, source channel, destination channel) triple with
//      identity modulation for BLEND and for SDL's ADD, MOD and MUL presets,
//      on all four bytes at once;
//   4. every colour and every alpha (source factor, destination factor,
//      operation) combination, with and without single rounding, over
//      random operands;
//   5. 16M random vectors over all inputs and valid modes.
// One input is launched per cycle and compared 7 cycles later.

#include <cstdint>
#include <cstdio>
#include <deque>
#include <memory>
#include <random>

#include "Vblend_px.h"
#include "verilated.h"
#include "../sim/blend_ref.h"

namespace {

struct Expect { uint32_t src, dst, mod, flags, out; };

class Bench {
public:
    Bench() : dut_(new Vblend_px) {
        dut_->reset = 1;
        dut_->in_valid = 0;
        for (int i = 0; i < 4; ++i) Tick();
        dut_->reset = 0;
    }
    ~Bench() { dut_->final(); }

    // flags: descriptor flags (bit 1 BLEND, or bit 4 with a mode in 31:8).
    void Push(uint32_t src, uint32_t dst, uint32_t mod, uint32_t flags) {
        const uint32_t mode = (flags & 0x10u) ? flags
                            : (flags & 0x2u) ? NOODLES_REF_MODE_BLEND : NOODLES_REF_MODE_NONE;
        dut_->in_valid = 1;
        dut_->src = src;
        dut_->dst = dst;
        dut_->mod = mod;
        dut_->mode = mode >> 8;
        pending_.push_back({src, dst, mod, flags, noodles_mode_ref(src, dst, mod, flags)});
        Tick();
    }

    void Drain() {
        dut_->in_valid = 0;
        for (int i = 0; i < 16 && !pending_.empty(); ++i) Tick();
        if (!pending_.empty()) Fail("outputs missing after drain");
    }

    uint64_t checked() const { return checked_; }

private:
    void Tick() {
        dut_->clk = 0;
        dut_->eval();
        dut_->clk = 1;
        dut_->eval();
        if (dut_->out_valid) {
            if (pending_.empty()) Fail("unexpected out_valid");
            const Expect e = pending_.front();
            pending_.pop_front();
            if (dut_->out != e.out) {
                std::fprintf(stderr, "FAIL: src=%08x dst=%08x mod=%08x flags=%08x got %08x want %08x\n",
                             e.src, e.dst, e.mod, e.flags, dut_->out, e.out);
                std::exit(1);
            }
            ++checked_;
        }
    }

    [[noreturn]] static void Fail(const char *msg) {
        std::fprintf(stderr, "FAIL: %s\n", msg);
        std::exit(1);
    }

    std::unique_ptr<Vblend_px> dut_;
    std::deque<Expect> pending_;
    uint64_t checked_ = 0;
};

uint32_t Mode(uint32_t csf, uint32_t cdf, uint32_t cop, uint32_t asf, uint32_t adf, uint32_t aop,
              int single) {
    return noodles_ref_mode(csf, cdf, cop, asf, adf, aop, single);
}

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Bench bench;

    for (uint32_t blend = 0; blend < 2; ++blend) {
        const uint32_t flags = blend ? 0x2u : 0u;
        for (uint32_t x = 0; x < 256; ++x) {
            for (uint32_t m = 0; m < 256; ++m) {
                bench.Push((x << 24) | 0x00ff80ffu, 0x40ff0000u, (m << 24) | 0x00ffffffu, flags);
                bench.Push(0xff000000u | (x << 16) | (x << 8) | x, 0x12345678u,
                           0xff000000u | (m << 16) | ((m ^ 0x5au) << 8) | m, flags);
            }
        }
    }

    using namespace std;
    const uint32_t kAdd = Mode(NOODLES_REF_SRC_ALPHA, NOODLES_REF_ONE, NOODLES_REF_ADD,
                               NOODLES_REF_ZERO, NOODLES_REF_ONE, NOODLES_REF_ADD, 0);
    const uint32_t kMod = Mode(NOODLES_REF_DST_COLOR, NOODLES_REF_ZERO, NOODLES_REF_ADD,
                               NOODLES_REF_ZERO, NOODLES_REF_ONE, NOODLES_REF_ADD, 0);
    const uint32_t kMul = Mode(NOODLES_REF_DST_COLOR, NOODLES_REF_ONE_MINUS_SRC_ALPHA,
                               NOODLES_REF_ADD, NOODLES_REF_ZERO, NOODLES_REF_ONE,
                               NOODLES_REF_ADD, 1);
    for (uint32_t flags : {0x2u, kAdd, kMod, kMul}) {
        for (uint32_t alpha = 0; alpha < 256; ++alpha) {
            for (uint32_t s = 0; s < 256; ++s) {
                for (uint32_t d = 0; d < 256; ++d) {
                    const uint32_t src = (alpha << 24) | (s ^ 0x5au) << 16 | d << 8 | s;
                    const uint32_t dst = d << 24 | (d ^ 0xa5u) << 16 | s << 8 | d;
                    bench.Push(src, dst, 0xffffffffu, flags);
                }
            }
        }
    }

    std::mt19937 rng(0x626c656e);
    for (uint32_t single = 0; single < 2; ++single)
        for (uint32_t sf = 1; sf <= 10; ++sf)
            for (uint32_t df = 1; df <= 10; ++df)
                for (uint32_t op = 1; op <= 5; ++op) {
                    if (single && op != NOODLES_REF_ADD) continue;
                    const uint32_t colour = Mode(sf, df, op, NOODLES_REF_ONE, NOODLES_REF_ZERO,
                                                 NOODLES_REF_ADD, int(single));
                    const uint32_t alpha = Mode(NOODLES_REF_ONE, NOODLES_REF_ZERO,
                                                NOODLES_REF_ADD, sf, df, op, int(single));
                    for (int i = 0; i < 4096; ++i) {
                        bench.Push(rng(), rng(), rng(), colour);
                        bench.Push(rng(), rng(), rng(), alpha);
                    }
                }

    for (uint32_t i = 0; i < (1u << 24); ++i) {
        const uint32_t op_c = 1 + rng() % 5, op_a = 1 + rng() % 5;
        const int single = (op_c == NOODLES_REF_ADD && op_a == NOODLES_REF_ADD) ? int(rng() & 1) : 0;
        const uint32_t pick = rng() % 4;
        const uint32_t flags = pick == 0 ? 0u : pick == 1 ? 0x2u
                             : Mode(1 + rng() % 10, 1 + rng() % 10, op_c, 1 + rng() % 10,
                                    1 + rng() % 10, op_a, single);
        bench.Push(rng(), rng(), rng(), flags);
    }
    bench.Drain();

    std::printf("PASS: blend_px bit-exact on %llu vectors (exhaustive modulation, BLEND/ADD/MOD/MUL "
                "stages, all factor/operation combinations, 16M random compositions)\n",
                static_cast<unsigned long long>(bench.checked()));
    return 0;
}
