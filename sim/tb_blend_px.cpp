// BLIT-007/BLIT-008 datapath check: blend_px against sim/blend_ref.h.
//
// The datapath is a composition of per-byte stages, so each stage is
// checked exhaustively in isolation and the composition by random vectors:
//   1. every (source alpha, alpha modulation) pair, blended and plain;
//   2. every (source channel, colour modulation) pair, blended and plain;
//   3. every (alpha, source channel, destination channel) triple with
//      identity modulation, blended, on all four bytes at once;
//   4. 16M random vectors over all inputs and both modes.
// One input is launched per cycle and compared 5 cycles later.

#include <cstdint>
#include <cstdio>
#include <deque>
#include <memory>
#include <random>

#include "Vblend_px.h"
#include "verilated.h"
#include "../sim/blend_ref.h"

namespace {

struct Expect { uint32_t src, dst, mod, blend, out; };

class Bench {
public:
    Bench() : dut_(new Vblend_px) {
        dut_->reset = 1;
        dut_->in_valid = 0;
        for (int i = 0; i < 4; ++i) Tick();
        dut_->reset = 0;
    }
    ~Bench() { dut_->final(); }

    void Push(uint32_t src, uint32_t dst, uint32_t mod, uint32_t blend) {
        dut_->in_valid = 1;
        dut_->src = src;
        dut_->dst = dst;
        dut_->mod = mod;
        dut_->blend = blend;
        pending_.push_back({src, dst, mod, blend, noodles_draw_ref(src, dst, mod, int(blend))});
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
                std::fprintf(stderr, "FAIL: src=%08x dst=%08x mod=%08x blend=%u got %08x want %08x\n",
                             e.src, e.dst, e.mod, e.blend, dut_->out, e.out);
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

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Bench bench;

    for (uint32_t blend = 0; blend < 2; ++blend) {
        for (uint32_t x = 0; x < 256; ++x) {
            for (uint32_t m = 0; m < 256; ++m) {
                bench.Push((x << 24) | 0x00ff80ffu, 0x40ff0000u, (m << 24) | 0x00ffffffu, blend);
                bench.Push(0xff000000u | (x << 16) | (x << 8) | x, 0x12345678u,
                           0xff000000u | (m << 16) | ((m ^ 0x5au) << 8) | m, blend);
            }
        }
    }

    for (uint32_t alpha = 0; alpha < 256; ++alpha) {
        for (uint32_t s = 0; s < 256; ++s) {
            for (uint32_t d = 0; d < 256; ++d) {
                const uint32_t src = (alpha << 24) | (s ^ 0x5au) << 16 | d << 8 | s;
                const uint32_t dst = d << 24 | (d ^ 0xa5u) << 16 | s << 8 | d;
                bench.Push(src, dst, 0xffffffffu, 1);
            }
        }
    }

    std::mt19937 rng(0x626c656e);
    for (uint32_t i = 0; i < (1u << 24); ++i)
        bench.Push(rng(), rng(), rng(), rng() & 1);
    bench.Drain();

    std::printf("PASS: blend_px bit-exact on %llu vectors (exhaustive modulation and blend stages, "
                "16M random compositions)\n",
                static_cast<unsigned long long>(bench.checked()));
    return 0;
}
