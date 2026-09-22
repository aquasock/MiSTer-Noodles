// Verilator testbench for rtl/present.sv. Checks: (1) reset lands with
// front_sel=0, busy/done clear, (2) a start pulse followed by a fresh
// fb_vbl rising edge flips front_sel exactly once and waits for the
// configured retirement edges before pulsing done, (3) a
// start pulse that arrives while fb_vbl is ALREADY high does NOT flip
// immediately -- it must wait for fb_vbl to go low then high again (a
// fresh edge), not just "currently in blank", (4) repeated flips toggle
// front_sel correctly each time (0->1->0->1).

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

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    Testbench tb;
    Vpresent_dut &dut = tb.dut();

    dut.reset = 1;
    dut.fb_vbl = 0;
    dut.start = 0;
    for (int i = 0; i < 4; ++i) tb.Tick();
    dut.reset = 0;
    tb.Tick();

    if (dut.front_sel != 0) return Fail("front_sel not 0 after reset");
    if (dut.busy || dut.done) return Fail("busy/done not clear after reset");

    // Case 1: start while fb_vbl=0, then a fresh rising edge -- should flip.
    dut.start = 1;
    tb.Tick();
    dut.start = 0;
    if (!dut.busy) return Fail("busy did not assert after start");

    for (int i = 0; i < 5; ++i) tb.Tick();  // stay low a while, must not flip yet
    if (dut.front_sel != 0) return Fail("front_sel flipped before any vblank edge");

    dut.fb_vbl = 1;  // first rising edge: flip, but do not finish yet
    tb.Tick();
    if (dut.front_sel != 1) return Fail("front_sel did not flip on vblank rising edge");
    if (!dut.busy || dut.done) return Fail("present completed on first retirement edge");
    dut.fb_vbl = 0;
    tb.Tick();
    dut.fb_vbl = 1;  // second fresh edge
    tb.Tick();
    if (!dut.busy || dut.done) return Fail("present completed on second retirement edge");
    dut.fb_vbl = 0;
    tb.Tick();
    dut.fb_vbl = 1;  // third fresh edge: retirement margin is satisfied
    tb.Tick();
    tb.Tick();  // FINISH -> done pulses this cycle, sampled after Tick()
    if (!dut.done) return Fail("done did not pulse after flip");
    tb.Tick();
    if (dut.done || dut.busy) return Fail("busy/done did not clear after FINISH");

    // Case 2: start while fb_vbl is ALREADY high (mid-blank, no fresh edge)
    // -- must wait for a low-then-high transition, not flip immediately.
    dut.start = 1;
    tb.Tick();
    dut.start = 0;
    if (dut.front_sel != 1) return Fail("front_sel changed the instant start was issued");

    for (int i = 0; i < 5; ++i) tb.Tick();  // fb_vbl still held high -- no fresh edge yet
    if (dut.front_sel != 1) return Fail("front_sel flipped without a fresh vblank edge");

    dut.fb_vbl = 0;  // still not a rising edge
    tb.Tick();
    if (dut.front_sel != 1) return Fail("front_sel flipped on a falling edge");

    dut.fb_vbl = 1;  // first fresh rising edge: flip, but remain busy
    tb.Tick();
    if (dut.front_sel != 0) return Fail("front_sel did not flip on the fresh rising edge");
    for (int edge = 0; edge < 2; ++edge) {
        dut.fb_vbl = 0;
        tb.Tick();
        dut.fb_vbl = 1;
        tb.Tick();
    }
    tb.Tick();
    if (!dut.done) return Fail("delayed present did not complete after three fresh edges");

    // Case 3: repeated flips toggle correctly. front_sel is 0 here (case 2
    // left it there); each iteration must invert it.
    uint8_t expected = dut.front_sel;
    for (int i = 0; i < 4; ++i) {
        expected = expected ? 0 : 1;

        dut.fb_vbl = 0;
        tb.Tick();
        dut.start = 1;
        tb.Tick();
        dut.start = 0;
        for (int j = 0; j < 3; ++j) tb.Tick();  // idle low, must not flip yet
        dut.fb_vbl = 1;
        tb.Tick();

        if (dut.front_sel != expected) {
            std::fprintf(stderr, "flip %d: expected front_sel=%u, got %u\n", i, expected,
                          (unsigned)dut.front_sel);
            return Fail("repeated flip toggled incorrectly");
        }
        for (int edge = 0; edge < 2; ++edge) {
            dut.fb_vbl = 0;
            tb.Tick();
            dut.fb_vbl = 1;
            tb.Tick();
        }
        tb.Tick();  // let FINISH/done clear before next start
    }

    std::printf("PASS: present vblank-synced flip, waits for a fresh edge, toggles correctly\n");
    return 0;
}
