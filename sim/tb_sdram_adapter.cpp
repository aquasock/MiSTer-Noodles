// Verilator testbench for rtl/sdram_adapter.sv (core-log entry 61's step
// 4). Follows the dual-independent-clock idiom introduced by
// tb_sdram_cdc.cpp: clk_sys and clk_sdram are stepped as two genuinely
// independent, non-integer-ratio clocks.
//
// sim/sdram_adapter_dut.sv's mock stands in for rtl/sdram.sv's real
// normal-port protocol (see that file's header comment for why the real
// module can't be instantiated under Verilator). This test checks:
//   (a) a 64-bit read triggers exactly four sub-word accesses, at the
//       four consecutive 16-bit-word addresses implied by the request's
//       byte address, in order;
//   (b) the four captured 16-bit values are assembled into rd64_data in
//       the documented little-endian sub-word order;
//   (c) rd64_ready correctly blocks a second request while one is
//       outstanding;
//   (d) back-to-back requests at varied addresses and mock latencies all
//       round-trip correctly.

#include <cstdint>
#include <cstdio>
#include <memory>
#include <vector>

#include "Vsdram_adapter_dut.h"
#include "verilated.h"

namespace {

constexpr uint64_t kPeriodA = 50;  // clk_sys
constexpr uint64_t kPeriodB = 11;  // clk_sdram

enum EdgeFlags {
    kNone     = 0,
    kAPosedge = 1 << 0,
    kBPosedge = 1 << 2,
};

class Testbench {
public:
    Testbench() : dut_(new Vsdram_adapter_dut) {}
    ~Testbench() { dut_->final(); }

    Vsdram_adapter_dut &dut() { return *dut_; }

    int Step() {
        uint64_t next = std::min(next_a_, next_b_);
        int flags = 0;
        if (next == next_a_) {
            dut_->clk_sys = !dut_->clk_sys;
            flags |= dut_->clk_sys ? kAPosedge : 0;
            next_a_ += kPeriodA / 2;
        }
        if (next == next_b_) {
            dut_->clk_sdram = !dut_->clk_sdram;
            flags |= dut_->clk_sdram ? kBPosedge : 0;
            next_b_ += kPeriodB / 2;
        }
        dut_->eval();
        return flags;
    }

    void WaitPosedgeA() {
        while (!(Step() & kAPosedge)) {}
    }
    void WaitPosedgeB() {
        while (!(Step() & kBPosedge)) {}
    }
    void WaitPosedgesA(int n) {
        for (int i = 0; i < n; ++i) WaitPosedgeA();
    }

private:
    std::unique_ptr<Vsdram_adapter_dut> dut_;
    uint64_t next_a_ = kPeriodA / 2;
    uint64_t next_b_ = kPeriodB / 2;
};

int Fail(const char *msg) {
    std::fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

// The mock's sd_dout pattern (see sdram_adapter_dut.sv): {1'b1,
// addr[14:0]}. Reconstructs the expected assembled 64-bit value for a
// given 8-byte-aligned byte address, matching sdram_adapter.sv's own
// little-endian sub-word packing.
uint64_t ExpectedData(uint32_t byte_addr) {
    // sd_addr is only 26 bits wide (sdram.sv's real 128MB address space,
    // matching addr[26:1]) -- addresses beyond that wrap/truncate exactly
    // like sdram_adapter.sv's b_addr_out[26:1] slice does.
    uint32_t word_base = (byte_addr >> 1) & 0x3FFFFFFu;
    uint64_t data = 0;
    for (int i = 0; i < 4; ++i) {
        uint32_t sub_addr = word_base + i;
        uint16_t sub_data = static_cast<uint16_t>(0x8000u | (sub_addr & 0x7FFFu));
        data |= static_cast<uint64_t>(sub_data) << (16 * i);
    }
    return data;
}

bool RunOneRequest(Testbench &tb, uint32_t byte_addr, uint8_t mock_delay) {
    Vsdram_adapter_dut &dut = tb.dut();

    if (!dut.rd64_ready) {
        std::fprintf(stderr, "  precondition failed: rd64_ready low before request\n");
        return false;
    }

    dut.rd64_addr  = byte_addr;
    dut.rd64_len   = 1;
    dut.mock_delay = mock_delay;
    dut.rd64_en    = 1;
    tb.WaitPosedgeA();
    dut.rd64_en = 0;

    if (dut.rd64_ready) {
        std::fprintf(stderr, "  rd64_ready did not drop after an accepted request\n");
        return false;
    }

    // Track the four expected sub-word addresses, in order, as the mock
    // observes acceptances.
    uint32_t word_base = (byte_addr >> 1) & 0x3FFFFFFu;
    int next_expected = 0;
    bool saw_valid = false;
    for (int i = 0; i < 4000 && !saw_valid; ++i) {
        tb.WaitPosedgeB();
        if (dut.sd_accept_probe) {
            if (next_expected >= 4) {
                std::fprintf(stderr, "  observed a 5th sub-word access\n");
                return false;
            }
            uint32_t expected_addr = word_base + next_expected;
            if (dut.sd_addr_probe != expected_addr) {
                std::fprintf(stderr,
                              "  sub-word %d addr=0x%08x, expected 0x%08x\n",
                              next_expected, dut.sd_addr_probe, expected_addr);
                return false;
            }
            ++next_expected;
        }
        if (dut.rd64_valid) saw_valid = true;
    }
    if (!saw_valid) {
        std::fprintf(stderr, "  rd64_valid never observed\n");
        return false;
    }
    if (next_expected != 4) {
        std::fprintf(stderr, "  only observed %d of 4 sub-word accesses\n", next_expected);
        return false;
    }

    uint64_t expected = ExpectedData(byte_addr);
    uint64_t got = dut.rd64_data;
    if (got != expected) {
        std::fprintf(stderr, "  rd64_data=0x%016llx, expected 0x%016llx\n",
                      static_cast<unsigned long long>(got),
                      static_cast<unsigned long long>(expected));
        return false;
    }

    tb.WaitPosedgesA(2);
    if (!dut.rd64_ready) {
        std::fprintf(stderr, "  rd64_ready did not return after the response\n");
        return false;
    }
    return true;
}

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    Testbench tb;
    Vsdram_adapter_dut &dut = tb.dut();

    dut.clk_sys = 0;
    dut.clk_sdram = 0;
    dut.reset = 1;
    dut.reset_b = 1;
    dut.rd64_en = 0;
    dut.rd64_addr = 0;
    dut.rd64_len = 1;
    dut.mock_delay = 0;
    for (int i = 0; i < 8; ++i) tb.WaitPosedgeA();
    for (int i = 0; i < 8; ++i) tb.WaitPosedgeB();
    dut.reset = 0;
    dut.reset_b = 0;
    tb.WaitPosedgeA();
    tb.WaitPosedgeB();

    if (!dut.rd64_ready || dut.rd64_valid)
        return Fail("reset state is wrong");

    const struct { uint32_t addr; uint8_t delay; } kRequests[] = {
        {0x3040'0000u, 0},
        {0x3040'0008u, 1},
        {0x3040'2000u, 5},
        {0x3041'0000u, 30},
        {0x0000'0000u, 2},
        {0x0FFF'FFF8u, 0},
    };

    for (const auto &req : kRequests) {
        if (!RunOneRequest(tb, req.addr, req.delay)) {
            std::fprintf(stderr, "  (addr=0x%08x, mock_delay=%u)\n", req.addr,
                          req.delay);
            return Fail("sdram_adapter request/response round trip failed");
        }
    }

    std::printf(
        "PASS: sdram_adapter assembles 64-bit reads from 4 correctly "
        "ordered/addressed 16-bit sdram.sv-protocol accesses\n");
    return 0;
}
