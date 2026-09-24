// Verilator testbench for the single-clock SDRAM read adapter.
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

class Testbench {
public:
    Testbench() : dut_(new Vsdram_adapter_dut) {}
    ~Testbench() { dut_->final(); }

    Vsdram_adapter_dut &dut() { return *dut_; }

    void Tick() {
        dut_->clk = 0;
        dut_->eval();
        dut_->clk = 1;
        dut_->eval();
    }
    void Ticks(int n) {
        for (int i = 0; i < n; ++i) Tick();
    }

private:
    std::unique_ptr<Vsdram_adapter_dut> dut_;
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

bool RunOneRequest(Testbench &tb, uint32_t byte_addr, uint8_t mock_delay,
                    int busy_hold_cycles = 0) {
    Vsdram_adapter_dut &dut = tb.dut();

    if (!dut.rd64_ready) {
        std::fprintf(stderr, "  precondition failed: rd64_ready low before request\n");
        return false;
    }

    dut.rd64_addr  = byte_addr;
    dut.rd64_len   = 1;
    dut.mock_delay = mock_delay;
    // Simulates a real sdram.sv refresh/copy-port busy window that
    // happens to overlap the moment our request is first raised: mock_busy
    // makes the mock ignore sel&rd (without ever dropping sd_ready) for
    // busy_hold_cycles clk_sys edges, proving sdram_adapter's sequencer
    // holds its request as a level and retries rather than assuming a
    // blind one-cycle pulse is always accepted (the real, hardware-only
    // bug this regression test guards against -- see sdram_adapter.sv's
    // SEQ_ISSUE comment).
    if (busy_hold_cycles > 0) dut.mock_busy = 1;
    dut.rd64_en    = 1;
    tb.Tick();
    dut.rd64_en = 0;
    for (int i = 0; i < busy_hold_cycles; ++i) {
        tb.Tick();
        // The whole point of the regression test: while mock_busy is
        // asserted, the mock must NEVER accept, no matter how long
        // sdram_adapter holds sd_sel/sd_rd asserted -- this confirms the
        // busy window is actually gating anything, rather than the
        // request already having sailed through before we even started
        // watching.
        if (dut.sd_accept_probe) {
            std::fprintf(stderr, "  mock accepted a request during the busy window\n");
            return false;
        }
    }
    dut.mock_busy = 0;

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
        tb.Tick();
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

    tb.Ticks(2);
    if (!dut.rd64_ready) {
        std::fprintf(stderr, "  rd64_ready did not return after the response\n");
        return false;
    }
    return true;
}

// SDR-004/step 5b: a length-N burst is accepted ONCE and must produce N
// separate rd64_valid pulses, one per contiguous 64-bit word (each 8 bytes
// past the previous), with rd64_ready staying low for the whole burst --
// exactly the shape blit_copy64.sv (DDR-007) relies on.
bool RunBurstRequest(Testbench &tb, uint32_t byte_addr, uint8_t len,
                      uint8_t mock_delay) {
    Vsdram_adapter_dut &dut = tb.dut();

    if (!dut.rd64_ready) {
        std::fprintf(stderr, "  precondition failed: rd64_ready low before burst request\n");
        return false;
    }

    dut.rd64_addr  = byte_addr;
    dut.rd64_len   = len;
    dut.mock_delay = mock_delay;
    dut.rd64_en    = 1;
    tb.Tick();
    dut.rd64_en = 0;

    if (dut.rd64_ready) {
        std::fprintf(stderr, "  rd64_ready did not drop after an accepted burst request\n");
        return false;
    }

    const int words = len ? len : 1;
    for (int word = 0; word < words; ++word) {
        uint32_t word_addr = byte_addr + static_cast<uint32_t>(word) * 8;
        uint32_t word_base = (word_addr >> 1) & 0x3FFFFFFu;
        int next_expected = 0;
        bool saw_valid = false;
        for (int i = 0; i < 4000 && !saw_valid; ++i) {
            tb.Tick();
            if (dut.sd_accept_probe) {
                if (next_expected >= 4) {
                    std::fprintf(stderr, "  word %d: observed a 5th sub-word access\n", word);
                    return false;
                }
                uint32_t expected_addr = word_base + next_expected;
                if (dut.sd_addr_probe != expected_addr) {
                    std::fprintf(stderr,
                                  "  word %d sub-word %d addr=0x%08x, expected 0x%08x\n",
                                  word, next_expected, dut.sd_addr_probe, expected_addr);
                    return false;
                }
                ++next_expected;
            }
            // rd64_ready must stay low for every word except possibly the
            // very last, and even then only once the final response has
            // actually landed (checked separately below).
            if (word != words - 1 && dut.rd64_ready) {
                std::fprintf(stderr, "  rd64_ready rose mid-burst before word %d\n", word);
                return false;
            }
            if (dut.rd64_valid) saw_valid = true;
        }
        if (!saw_valid) {
            std::fprintf(stderr, "  word %d: rd64_valid never observed\n", word);
            return false;
        }
        if (next_expected != 4) {
            std::fprintf(stderr, "  word %d: only observed %d of 4 sub-word accesses\n",
                          word, next_expected);
            return false;
        }
        uint64_t expected = ExpectedData(word_addr);
        uint64_t got = dut.rd64_data;
        if (got != expected) {
            std::fprintf(stderr, "  word %d rd64_data=0x%016llx, expected 0x%016llx\n", word,
                          static_cast<unsigned long long>(got),
                          static_cast<unsigned long long>(expected));
            return false;
        }

        // rd64_valid is a single-cycle pulse but can still read as high for
        // a couple of iterations of this polling loop; drain it before
        // starting the next word's search, or that next word's loop could
        // catch this word's still-falling tail and declare victory with
        // zero sub-word accesses actually observed.
        for (int i = 0; i < 4000 && dut.rd64_valid; ++i) tb.Tick();
    }

    tb.Ticks(2);
    if (!dut.rd64_ready) {
        std::fprintf(stderr, "  rd64_ready did not return after the full burst\n");
        return false;
    }
    return true;
}

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    Testbench tb;
    Vsdram_adapter_dut &dut = tb.dut();

    dut.clk = 0;
    dut.reset = 1;
    dut.rd64_en = 0;
    dut.rd64_addr = 0;
    dut.rd64_len = 1;
    dut.mock_delay = 0;
    dut.mock_busy = 0;
    for (int i = 0; i < 8; ++i) tb.Tick();
    dut.reset = 0;
    tb.Tick();

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

    const struct { uint32_t addr; uint8_t len; uint8_t delay; } kBurstRequests[] = {
        {0x0000'0020u, 0, 0},
        {0x3040'0000u, 4, 0},
        {0x3040'0100u, 2, 3},
        {0x0000'0000u, 8, 1},
        {0x0000'0100u, 16, 0},
    };

    for (const auto &req : kBurstRequests) {
        if (!RunBurstRequest(tb, req.addr, req.len, req.delay)) {
            std::fprintf(stderr, "  (addr=0x%08x, len=%u, mock_delay=%u)\n", req.addr,
                          req.len, req.delay);
            return Fail("sdram_adapter burst request/response round trip failed");
        }
    }

    // Regression test for the real hardware-only hang this session found:
    // sdram_adapter's sequencer used to pulse sd_sel/sd_rd for
    // exactly one cycle and assume acceptance, which is unsafe whenever
    // the real sdram.sv controller happens to be busy elsewhere (periodic
    // auto-refresh, or the loader's copy-port burst) at that exact
    // moment -- during those windows sd_ready never drops, so the old
    // one-shot-pulse design would wait forever for an acceptance signal
    // that was never coming. Holding the request as a level and retrying
    // until sd_ready actually drops (this fix) must survive an arbitrarily
    // long busy window.
    if (!RunOneRequest(tb, 0x3040'0000u, /*mock_delay=*/2, /*busy_hold_cycles=*/9)) {
        return Fail("sdram_adapter request did not survive an sd_ready-silent busy window");
    }

    // Abort at acceptance, within a sub-word read, and at response time.
    for (int age : {1, 5, 25, 80}) {
        dut.rd64_addr = 0x1000;
        dut.rd64_len = 16;
        dut.mock_delay = 3;
        dut.rd64_en = 1;
        tb.Tick();
        dut.rd64_en = 0;
        tb.Ticks(age);
        dut.reset = 1;
        tb.Tick();
        dut.reset = 0;
        tb.Tick();
        if (!dut.rd64_ready || dut.rd64_valid)
            return Fail("reset did not discard the active burst");
        for (int i = 0; i < 12; ++i) {
            tb.Tick();
            if (dut.rd64_valid || dut.sd_accept_probe)
                return Fail("stale read escaped after reset");
        }
        if (!RunOneRequest(tb, 0x2000, 1))
            return Fail("read failed after mid-burst reset");
    }

    std::printf(
        "PASS: sdram_adapter assembles 64-bit reads from 4 correctly "
        "ordered/addressed 16-bit sdram.sv-protocol accesses, including "
        "multi-word bursts and a silent (sd_ready-preserving) controller "
        "busy window\n");
    return 0;
}
