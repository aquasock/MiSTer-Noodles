// Exhaustive BLIT-007 datapath check: blend_px against sim/blend_ref.h.
//
// Pass 1 covers every (source alpha, modulation) pair, so every effective
// alpha derivation is checked. Pass 2 fixes modulation at 255 and covers
// every (alpha, source channel, destination channel) triple on all four
// output bytes at once, rotating which value each colour channel carries.
// One input is launched per cycle and outputs are compared LATENCY cycles
// later.

#include <cstdint>
#include <cstdio>
#include <deque>
#include <memory>

#include "Vblend_px.h"
#include "verilated.h"
#include "../sim/blend_ref.h"

namespace {

struct Expect { uint32_t src, dst, mod, out; };

class Bench {
public:
    Bench() : dut_(new Vblend_px) {
        dut_->reset = 1;
        dut_->in_valid = 0;
        for (int i = 0; i < 4; ++i) Tick();
        dut_->reset = 0;
    }
    ~Bench() { dut_->final(); }

    void Push(uint32_t src, uint32_t dst, uint32_t mod) {
        dut_->in_valid = 1;
        dut_->src = src;
        dut_->dst = dst;
        dut_->mod = mod;
        pending_.push_back({src, dst, mod, noodles_blend_ref(src, dst, mod)});
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
                std::fprintf(stderr, "FAIL: src=%08x dst=%08x mod=%02x got %08x want %08x\n",
                             e.src, e.dst, e.mod, dut_->out, e.out);
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

    for (uint32_t alpha = 0; alpha < 256; ++alpha)
        for (uint32_t mod = 0; mod < 256; ++mod)
            bench.Push((alpha << 24) | 0x00ff80ffu, 0x40ff0000u, mod);

    for (uint32_t alpha = 0; alpha < 256; ++alpha) {
        for (uint32_t s = 0; s < 256; ++s) {
            for (uint32_t d = 0; d < 256; ++d) {
                const uint32_t src = (alpha << 24) | (s ^ 0x5au) << 16 | d << 8 | s;
                const uint32_t dst = d << 24 | (d ^ 0xa5u) << 16 | s << 8 | d;
                bench.Push(src, dst, 255);
            }
        }
    }
    bench.Drain();

    std::printf("PASS: blend_px bit-exact on %llu vectors (all alpha/mod pairs, all alpha/src/dst channel triples)\n",
                static_cast<unsigned long long>(bench.checked()));
    return 0;
}
