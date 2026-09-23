// Verilator testbench for rtl/sdram_cdc.sv (core-log entry 61's step 3).
//
// Runs clk_a and clk_b as two genuinely independent, non-integer-ratio
// clocks (not just two derived phases of one simulation clock) to
// actually exercise the synchronizer across arbitrary phase
// relationships -- the whole point of this module. A convenient integer
// ratio would risk hiding a race that only shows up when an edge of one
// clock lands very close to an edge of the other.

#include <cstdint>
#include <cstdio>
#include <memory>

#include "Vsdram_cdc_dut.h"
#include "verilated.h"

namespace {

// Deliberately not an integer multiple of each other (50 vs 11 time
// units), so posedges of clk_a and clk_b drift through every possible
// phase relationship over the course of a test run.
constexpr uint64_t kPeriodA = 50;  // clk_a (stands in for clk_sys)
constexpr uint64_t kPeriodB = 11;  // clk_b (stands in for clk_sdram)

enum EdgeFlags {
    kNone      = 0,
    kAPosedge  = 1 << 0,
    kANegedge  = 1 << 1,
    kBPosedge  = 1 << 2,
    kBNegedge  = 1 << 3,
};

class Testbench {
public:
    Testbench() : dut_(new Vsdram_cdc_dut) {}
    ~Testbench() { dut_->final(); }

    Vsdram_cdc_dut &dut() { return *dut_; }

    // Advances simulation time to the next pending clock edge (whichever
    // of clk_a/clk_b is sooner; both if they land simultaneously),
    // toggles it, and evaluates. Returns which edge(s) occurred.
    int Step() {
        uint64_t next = std::min(next_a_, next_b_);
        int flags = kNone;
        time_ = next;
        if (next == next_a_) {
            dut_->clk_a = !dut_->clk_a;
            flags |= dut_->clk_a ? kAPosedge : kANegedge;
            next_a_ += kPeriodA / 2;
        }
        if (next == next_b_) {
            dut_->clk_b = !dut_->clk_b;
            flags |= dut_->clk_b ? kBPosedge : kBNegedge;
            next_b_ += kPeriodB / 2;
        }
        dut_->eval();
        return flags;
    }

    // Runs until (and including) the next posedge of clk_a.
    void WaitPosedgeA() {
        while (!(Step() & kAPosedge)) {}
    }

    // Runs until (and including) the next posedge of clk_b.
    void WaitPosedgeB() {
        while (!(Step() & kBPosedge)) {}
    }

    void WaitPosedgesA(int n) {
        for (int i = 0; i < n; ++i) WaitPosedgeA();
    }

private:
    std::unique_ptr<Vsdram_cdc_dut> dut_;
    uint64_t time_    = 0;
    uint64_t next_a_  = kPeriodA / 2;
    uint64_t next_b_  = kPeriodB / 2;
};

int Fail(const char *msg) {
    std::fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

// Issues one request (addr, resp_delay), waits for it to be seen in
// domain B with the right address, then waits for the response to land
// back in domain A, and checks a_data against the DUT's known
// {32'hCAFEF00D, addr} response pattern. Bails out (returns false) if
// nothing arrives within a generous cycle budget, rather than hanging.
bool RunOneRequest(Testbench &tb, uint32_t addr, uint8_t resp_delay) {
    Vsdram_cdc_dut &dut = tb.dut();

    if (!dut.a_ready) {
        std::fprintf(stderr, "  precondition failed: a_ready low before request\n");
        return false;
    }

    dut.a_addr     = addr;
    dut.resp_delay = resp_delay;
    dut.a_en       = 1;
    tb.WaitPosedgeA();
    dut.a_en = 0;

    if (dut.a_ready) {
        std::fprintf(stderr, "  a_ready did not drop after an accepted request\n");
        return false;
    }

    bool saw_b_start = false;
    for (int i = 0; i < 40 && !saw_b_start; ++i) {
        tb.WaitPosedgeB();
        if (dut.b_start_probe) {
            saw_b_start = true;
            if (dut.b_addr_probe != addr) {
                std::fprintf(stderr, "  b_addr_probe=0x%08x, expected 0x%08x\n",
                              dut.b_addr_probe, addr);
                return false;
            }
        }
    }
    if (!saw_b_start) {
        std::fprintf(stderr, "  b_start never observed in domain B\n");
        return false;
    }

    bool saw_a_valid = false;
    for (int i = 0; i < 400 && !saw_a_valid; ++i) {
        tb.WaitPosedgeA();
        if (dut.a_valid) {
            saw_a_valid = true;
            uint64_t expected =
                (static_cast<uint64_t>(0xCAFEF00Du) << 32) | addr;
            uint64_t got = dut.a_data;
            if (got != expected) {
                std::fprintf(stderr, "  a_data=0x%016llx, expected 0x%016llx\n",
                              static_cast<unsigned long long>(got),
                              static_cast<unsigned long long>(expected));
                return false;
            }
        }
    }
    if (!saw_a_valid) {
        std::fprintf(stderr, "  a_valid never observed in domain A\n");
        return false;
    }

    // a_ready must return within a cycle or two of a_valid.
    tb.WaitPosedgesA(2);
    if (!dut.a_ready) {
        std::fprintf(stderr, "  a_ready did not return after the response\n");
        return false;
    }
    return true;
}

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    Testbench tb;
    Vsdram_cdc_dut &dut = tb.dut();

    dut.clk_a = 0;
    dut.clk_b = 0;
    dut.reset_a = 1;
    dut.reset_b = 1;
    dut.a_en = 0;
    dut.a_addr = 0;
    dut.resp_delay = 0;
    for (int i = 0; i < 8; ++i) tb.WaitPosedgeA();
    for (int i = 0; i < 8; ++i) tb.WaitPosedgeB();
    dut.reset_a = 0;
    dut.reset_b = 0;
    tb.WaitPosedgeA();
    tb.WaitPosedgeB();

    if (!dut.a_ready || dut.a_valid)
        return Fail("reset state is wrong");

    // A spread of round-trip latencies, including the minimum (0) and a
    // latency long enough to span many clk_a cycles, to exercise the
    // synchronizer across the full range this project's real sdram
    // controller might eventually take.
    const struct { uint32_t addr; uint8_t delay; } kRequests[] = {
        {0x3040'0000u, 0},
        {0x3040'0004u, 1},
        {0x3040'0100u, 5},
        {0x3040'2000u, 20},
        {0x3041'0000u, 60},
        {0x1234'5678u, 3},
        {0xAAAA'AAA0u, 0},
        {0x0000'0000u, 10},
    };

    for (const auto &req : kRequests) {
        if (!RunOneRequest(tb, req.addr, req.delay)) {
            std::fprintf(stderr, "  (addr=0x%08x, resp_delay=%u)\n", req.addr,
                          req.delay);
            return Fail("request/response round trip failed");
        }
    }

    // A request issued while busy (a_en held during a_ready==0) must be
    // ignored, not corrupt the in-flight request -- exercise by holding
    // a_en high across several extra clk_a cycles past acceptance. Uses a
    // large resp_delay so the round trip provably cannot complete within
    // the held window, regardless of the clk_a/clk_b ratio.
    dut.a_addr     = 0x3050'0000u;
    dut.resp_delay = 200;
    dut.a_en       = 1;
    tb.WaitPosedgeA();
    // Change addr and keep a_en asserted while busy: must not affect the
    // already-accepted request, since busy_a masks a_en until a_valid.
    dut.a_addr = 0xFFFF'FFFFu;
    tb.WaitPosedgesA(3);
    dut.a_en = 0;

    bool saw_a_valid = false;
    for (int i = 0; i < 4000 && !saw_a_valid; ++i) {
        tb.WaitPosedgeA();
        if (dut.a_valid) {
            saw_a_valid = true;
            uint64_t expected =
                (static_cast<uint64_t>(0xCAFEF00Du) << 32) | 0x3050'0000u;
            uint64_t got = dut.a_data;
            if (got != expected)
                return Fail("a_en held past acceptance corrupted the in-flight request");
        }
    }
    if (!saw_a_valid)
        return Fail("held-a_en request never completed");

    std::printf(
        "PASS: sdram_cdc round-trips request/response correctly across "
        "independent, non-integer-ratio clocks at varied latency\n");
    return 0;
}
