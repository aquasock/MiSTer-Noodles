// Verilator testbench for rtl/present.sv. Exercises arbitrary phase
// relationships between FB_VBL and ascal's framebuffer-base acknowledgement.

#include <cstdint>
#include <cstdio>
#include <memory>

#include "Vpresent_dut.h"
#include "verilated.h"

namespace {

class Testbench {
public:
    Testbench() : dut_(new Vpresent_dut) {}
    ~Testbench() { dut_->final(); }

    void Tick() {
        dut_->clk = 0;
        dut_->eval();
        dut_->clk = 1;
        dut_->eval();
    }

    Vpresent_dut &dut() { return *dut_; }

private:
    std::unique_ptr<Vpresent_dut> dut_;
};

int Fail(const char *msg) {
    std::fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

void FreshVbl(Testbench &tb, Vpresent_dut &dut) {
    dut.fb_vbl = 0;
    tb.Tick();
    dut.fb_vbl = 1;
    tb.Tick();
}

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    Testbench tb;
    Vpresent_dut &dut = tb.dut();

    dut.reset = 1;
    dut.fb_vbl = 0;
    dut.fb_retired = 0;
    dut.start = 0;
    dut.queued = 0;
    dut.target = 0;
    for (int i = 0; i < 4; ++i) tb.Tick();
    dut.reset = 0;
    tb.Tick();

    if (dut.front_idx != 0 || dut.busy || dut.done)
        return Fail("reset state is wrong");

    // Acknowledgement arrives after the first boundary and one additional
    // boundary is required before completion.
    dut.start = 1;
    tb.Tick();
    dut.start = 0;
    for (int i = 0; i < 3; ++i) tb.Tick();
    dut.fb_vbl = 1;
    tb.Tick();
    if (dut.front_idx != 1 || !dut.busy || dut.done)
        return Fail("flip did not wait for a fresh vblank edge");

    dut.fb_retired = 1;
    tb.Tick();
    if (!dut.busy || dut.done)
        return Fail("acknowledgement completed PRESENT too early");
    FreshVbl(tb, dut);
    tb.Tick();
    if (!dut.done || dut.busy)
        return Fail("PRESENT did not complete after acknowledgement margin");
    tb.Tick();

    // Starting while FB_VBL is already high must wait for a fresh edge.
    dut.start = 1;
    tb.Tick();
    dut.start = 0;
    for (int i = 0; i < 3; ++i) tb.Tick();
    if (dut.front_idx != 1)
        return Fail("flip occurred without a fresh vblank edge");
    dut.fb_vbl = 0;
    tb.Tick();
    dut.fb_vbl = 1;
    tb.Tick();
    if (dut.front_idx != 0 || !dut.busy)
        return Fail("second flip did not occur at the fresh edge");
    dut.fb_retired = 0;
    tb.Tick();
    FreshVbl(tb, dut);
    tb.Tick();
    if (!dut.done || dut.busy)
        return Fail("second PRESENT did not complete");
    tb.Tick();

    // Repeated flips toggle correctly, with the acknowledgement intentionally
    // arriving at different points relative to the vblank boundary.
    uint8_t expected = 0;
    for (int i = 0; i < 4; ++i) {
        expected = expected ? 0 : 1;
        dut.fb_vbl = 0;
        dut.start = 1;
        tb.Tick();
        dut.start = 0;
        for (int j = 0; j < 2; ++j) tb.Tick();
        dut.fb_vbl = 1;
        tb.Tick();
        if (dut.front_idx != expected)
            return Fail("repeated flip toggled incorrectly");
        dut.fb_retired = dut.fb_retired ? 0 : 1;
        tb.Tick();
        if (i & 1) FreshVbl(tb, dut);
        else {
            dut.fb_vbl = 0;
            tb.Tick();
            FreshVbl(tb, dut);
        }
        tb.Tick();
        if (!dut.done || dut.busy)
            return Fail("repeated PRESENT did not complete");
        tb.Tick();
    }

    // OUT-013 queued flips: explicit targets, acknowledgement captured at
    // the flip rather than at start, retired pulses without legacy done.
    const uint8_t targets[] = {2, 1, 0, 2};
    for (uint8_t target : targets) {
        dut.fb_vbl = 0;
        dut.queued = 1;
        dut.target = target;
        dut.start = 1;
        tb.Tick();
        dut.start = 0;
        dut.queued = 0;
        // A boundary that arrives before the flip must not retire it.
        dut.fb_retired = dut.fb_retired ? 0 : 1;
        tb.Tick();
        dut.fb_vbl = 1;
        tb.Tick();
        if (dut.front_idx != target || !dut.busy)
            return Fail("queued flip did not show its target at the fresh edge");
        for (int i = 0; i < 3; ++i) {
            tb.Tick();
            if (!dut.busy || dut.retired || dut.done)
                return Fail("queued flip retired on a boundary from before the flip");
        }
        dut.fb_retired = dut.fb_retired ? 0 : 1;
        tb.Tick();
        FreshVbl(tb, dut);
        tb.Tick();
        if (!dut.retired || dut.done || dut.busy)
            return Fail("queued flip did not retire without a legacy done pulse");
        tb.Tick();
    }

    // Legacy PRESENT after a queued flip to C shows B, then A.
    const uint8_t legacy[] = {1, 0};
    for (uint8_t expected : legacy) {
        dut.fb_vbl = 0;
        dut.start = 1;
        tb.Tick();
        dut.start = 0;
        tb.Tick();
        dut.fb_vbl = 1;
        tb.Tick();
        if (dut.front_idx != expected)
            return Fail("legacy PRESENT after queued flips chose the wrong buffer");
        dut.fb_retired = dut.fb_retired ? 0 : 1;
        tb.Tick();
        FreshVbl(tb, dut);
        tb.Tick();
        if (!dut.done || !dut.retired || dut.busy)
            return Fail("legacy PRESENT after queued flips did not complete");
        tb.Tick();
    }

    std::printf("PASS: PRESENT waits for ascal base acknowledgement and retires safely; queued flips rotate three buffers\n");
    return 0;
}
