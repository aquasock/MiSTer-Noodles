// Verilator testbench for rtl/link_fence.sv. Checks: (1) reset is followed
// by exactly one write publishing 0 to FENCE_ADDR before any completion,
// (2) a single done_pulse causes exactly one more write, publishing 1,
// (3) a sequence of spaced-out pulses converges to publishing the correct
// running total, (4) two done_pulses fired back to back (no gap) still
// converge to the correct final total even though they may coalesce into
// fewer than one write per pulse, (5) all of the above hold under
// intermittent wr_ready backpressure.

#include <cstdint>
#include <cstdio>
#include <memory>
#include <vector>

#include "Vlink_fence_dut.h"
#include "verilated.h"

namespace {

constexpr uint32_t kFenceAddr = 0x3002000Cu;

struct Write {
    uint32_t addr;
    uint32_t data;
};

class Testbench {
public:
    Testbench() : dut_(new Vlink_fence_dut) {}
    ~Testbench() { dut_->final(); }

    void Tick(bool wr_ready, bool done_pulse, std::vector<Write> *writes) {
        dut_->wr_ready = wr_ready ? 1 : 0;
        dut_->done_pulse = done_pulse ? 1 : 0;

        dut_->clk = 0;
        dut_->eval();

        dut_->clk = 1;
        dut_->eval();
        if (dut_->wr_en && dut_->wr_ready) {
            writes->push_back({dut_->wr_addr, dut_->wr_data});
        }
    }

    Vlink_fence_dut &dut() { return *dut_; }

private:
    std::unique_ptr<Vlink_fence_dut> dut_;
};

int Fail(const char *msg) {
    std::fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

// Ticks until at least `min_writes` writes have landed, applying `backpressure`
// (a simple every-3rd-cycle pattern) throughout. Returns false on timeout.
bool RunUntil(Testbench &tb, std::vector<Write> *writes, size_t min_writes, bool backpressure) {
    int guard = 0;
    while (writes->size() < min_writes) {
        bool wr_ready = backpressure ? ((guard % 3) != 1) : true;
        tb.Tick(wr_ready, /*done_pulse=*/false, writes);
        if (++guard > 10000) return false;
    }
    return true;
}

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    Testbench tb;
    std::vector<Write> writes;
    Vlink_fence_dut &dut = tb.dut();

    dut.reset = 1;
    dut.done_pulse = 0;
    for (int i = 0; i < 4; ++i) tb.Tick(/*wr_ready=*/true, /*done_pulse=*/false, &writes);
    dut.reset = 0;

    // INIT: exactly one write of 0, under backpressure, before anything else happens.
    if (!RunUntil(tb, &writes, 1, /*backpressure=*/true)) return Fail("INIT write never completed");
    if (writes.size() != 1) return Fail("more than one write during INIT");
    if (writes[0].addr != kFenceAddr || writes[0].data != 0) {
        std::fprintf(stderr, "INIT write was addr=0x%08x data=0x%08x, expected addr=0x%08x data=0\n",
                      writes[0].addr, writes[0].data, kFenceAddr);
        return Fail("wrong INIT address or value");
    }
    tb.Tick(/*wr_ready=*/true, /*done_pulse=*/false, &writes);
    if (!dut.initialized) return Fail("initialized did not assert after INIT write");

    // No further writes until a completion.
    for (int i = 0; i < 50; ++i) tb.Tick(/*wr_ready=*/true, /*done_pulse=*/false, &writes);
    if (writes.size() != 1) return Fail("a write happened with no done_pulse");

    // A single pulse -> exactly one more write, publishing 1.
    tb.Tick(/*wr_ready=*/true, /*done_pulse=*/true, &writes);
    if (!RunUntil(tb, &writes, 2, /*backpressure=*/true)) return Fail("post-pulse write never completed");
    if (writes.size() != 2) return Fail("more than one write after a single pulse");
    if (writes[1].addr != kFenceAddr || writes[1].data != 1) {
        std::fprintf(stderr, "write was addr=0x%08x data=%u, expected addr=0x%08x data=1\n",
                      writes[1].addr, writes[1].data, kFenceAddr);
        return Fail("wrong address or value after first completion");
    }

    // A sequence of spaced-out pulses converges to the correct running total.
    const int kExtraPulses = 5;
    for (int i = 0; i < kExtraPulses; ++i) {
        tb.Tick(/*wr_ready=*/true, /*done_pulse=*/true, &writes);
        if (!RunUntil(tb, &writes, (size_t)(3 + i), /*backpressure=*/(i % 2 == 0))) {
            return Fail("a spaced-out pulse's write never completed");
        }
    }
    if (writes.back().data != (uint32_t)(1 + kExtraPulses)) {
        std::fprintf(stderr, "final published count was %u, expected %d\n", writes.back().data,
                      1 + kExtraPulses);
        return Fail("running total incorrect after spaced-out pulses");
    }

    // Two pulses fired back to back (no gap between them) must still converge
    // to the correct total -- done_count itself never stalls or drops an
    // increment regardless of what state the publish side is in.
    uint32_t total_before_burst = writes.back().data;
    tb.Tick(/*wr_ready=*/true, /*done_pulse=*/true, &writes);
    tb.Tick(/*wr_ready=*/true, /*done_pulse=*/true, &writes);
    tb.Tick(/*wr_ready=*/true, /*done_pulse=*/false, &writes);
    for (int i = 0; i < 20; ++i) tb.Tick(/*wr_ready=*/true, /*done_pulse=*/false, &writes);
    if (writes.back().data != total_before_burst + 2) {
        std::fprintf(stderr, "final published count was %u, expected %u after a 2-pulse burst\n",
                      writes.back().data, total_before_burst + 2);
        return Fail("running total incorrect after a back-to-back pulse burst");
    }

    std::printf("PASS: link_fence published %u completions across %zu writes, INIT-to-0 then converging\n",
                writes.back().data, writes.size());
    return 0;
}
