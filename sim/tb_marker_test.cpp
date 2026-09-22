// Verilator testbench for rtl/ddram_marker_test.sv. Checks: (1) a trigger
// rising edge produces exactly one write of the marker value to the marker
// address, (2) holding trigger high afterward does not cause repeated
// writes, (3) a fresh rising edge (trigger low then high again) arms
// another single write.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <vector>

#include "Vmarker_test_dut.h"
#include "verilated.h"

namespace {

constexpr uint32_t kMarkerAddr = 0x0;
constexpr uint32_t kMarkerValue = 0xDEADBEEFu;

struct Write {
    uint32_t addr;
    uint32_t data;
};

class Testbench {
public:
    Testbench() : dut_(new Vmarker_test_dut) {}
    ~Testbench() { dut_->final(); }

    void Tick(bool wr_ready, std::vector<Write> *writes) {
        dut_->wr_ready = wr_ready ? 1 : 0;

        dut_->clk = 0;
        dut_->eval();

        dut_->clk = 1;
        dut_->eval();
        if (dut_->wr_en && dut_->wr_ready) {
            writes->push_back({dut_->wr_addr, dut_->wr_data});
        }
    }

    Vmarker_test_dut &dut() { return *dut_; }

private:
    std::unique_ptr<Vmarker_test_dut> dut_;
};

int Fail(const char *msg) {
    std::fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    Testbench tb;
    std::vector<Write> writes;
    Vmarker_test_dut &dut = tb.dut();

    dut.reset = 1;
    dut.trigger = 0;
    for (int i = 0; i < 4; ++i) tb.Tick(/*wr_ready=*/true, &writes);
    dut.reset = 0;
    tb.Tick(/*wr_ready=*/true, &writes);

    if (!writes.empty()) return Fail("write occurred before any trigger");

    // Rising edge, under intermittent backpressure.
    dut.trigger = 1;
    int guard = 0;
    do {
        tb.Tick(/*wr_ready=*/(guard % 3) != 1, &writes);
        if (++guard > 10000) return Fail("marker write never completed");
    } while (!dut.done && dut.busy);
    // One more tick to observe `done` settle back and `busy` clear.
    tb.Tick(/*wr_ready=*/true, &writes);

    if (writes.size() != 1) {
        std::fprintf(stderr, "expected exactly 1 write, got %zu\n", writes.size());
        return Fail("write count after first trigger");
    }
    if (writes[0].addr != kMarkerAddr || writes[0].data != kMarkerValue) {
        std::fprintf(stderr, "write was addr=0x%08x data=0x%08x, expected addr=0x%08x data=0x%08x\n",
                      writes[0].addr, writes[0].data, kMarkerAddr, kMarkerValue);
        return Fail("wrong address or value");
    }

    // Holding trigger high must not cause a second write.
    for (int i = 0; i < 50; ++i) tb.Tick(/*wr_ready=*/true, &writes);
    if (writes.size() != 1) return Fail("holding trigger high caused a repeat write");

    // Trigger low, then a fresh rising edge arms exactly one more write.
    dut.trigger = 0;
    tb.Tick(/*wr_ready=*/true, &writes);
    dut.trigger = 1;
    guard = 0;
    do {
        tb.Tick(/*wr_ready=*/true, &writes);
        if (++guard > 10000) return Fail("second marker write never completed");
    } while (!dut.done && dut.busy);
    tb.Tick(/*wr_ready=*/true, &writes);

    if (writes.size() != 2) {
        std::fprintf(stderr, "expected exactly 2 writes total, got %zu\n", writes.size());
        return Fail("second trigger did not arm exactly one more write");
    }

    std::printf("PASS: marker_test wrote 0x%08x to 0x%08x exactly once per trigger edge\n",
                kMarkerValue, kMarkerAddr);
    return 0;
}
