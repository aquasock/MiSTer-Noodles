// Verilator testbench for rtl/sdram_loader.sv (core-log entry 66's step
// 5a). Follows the dual-independent-clock idiom introduced by
// tb_sdram_cdc.cpp/tb_sdram_adapter.cpp.
//
// sim/sdram_loader_dut.sv's two mocks stand in for ddram_adapter's real
// rd64 contract (DDR3 source) and sdram.sv's real copy-port protocol
// (SDRAM destination); see that file's header for why the real modules
// can't be instantiated under Verilator. This test checks:
//   (a) a multi-page load issues the right number of pages, each landing
//       at the correct sequential 512-word-spaced destination address;
//   (b) every one of the 512 words per page is captured, in order, with
//       data matching the DDR3 mock's address-derived pattern for the
//       corresponding source offset;
//   (c) a length that isn't a whole number of pages still flushes a
//       whole final page (rounds up), matching the documented "whole
//       pages always written" behavior;
//   (d) busy/done pulse correctly bracketing the whole multi-page
//       transfer, and varied DDR3 mock latencies don't break addressing.
//   (e) a regression test for a real hardware-only hang this project's
//       sdram_adapter.sv also had (SDR-004/step 5b, core-log entry 67):
//       the flush side's cpreq is only a one-cycle pulse, which sdram.sv
//       accepts purely via edge detection against its own old_cpreq --
//       and old_cpreq itself only advances while the controller is truly
//       idle. A cpreq pulse landing entirely inside a busy window (real
//       auto-refresh, or a concurrent sdram_adapter read) vanishes with
//       no visible rejection, hanging this module forever. mock_busy
//       reproduces that window; see sdram_loader.sv's own B_ISSUE fix.

#include <cstdint>
#include <cstdio>
#include <memory>
#include <vector>

#include "Vsdram_loader_dut.h"
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
    Testbench() : dut_(new Vsdram_loader_dut) {}
    ~Testbench() { dut_->final(); }

    Vsdram_loader_dut &dut() { return *dut_; }

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

private:
    std::unique_ptr<Vsdram_loader_dut> dut_;
    uint64_t next_a_ = kPeriodA / 2;
    uint64_t next_b_ = kPeriodB / 2;
};

int Fail(const char *msg) {
    std::fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

// Matches sdram_loader_dut.sv's ddr_pattern() function and
// tb_sdram_adapter.cpp's ExpectedData() convention: each 16-bit sub-word
// is 0x8000 | (sub_addr & 0x7FFF).
uint16_t ExpectedWord(uint32_t word_addr) {
    return static_cast<uint16_t>(0x8000u | (word_addr & 0x7FFFu));
}

struct PageCapture {
    uint32_t addr = 0;
    uint16_t words[512];
    int count = 0;
};

// Runs one full load, watching domain B's copy-port probes to record
// every page/word actually written, then validates page count, addresses,
// and data against the expected model.
bool RunOneLoad(Testbench &tb, uint32_t src_addr, uint32_t dst_addr,
                 uint32_t length, uint8_t ddr_delay, int busy_hold_cycles = 0) {
    Vsdram_loader_dut &dut = tb.dut();

    if (dut.busy) {
        std::fprintf(stderr, "  precondition failed: busy before start\n");
        return false;
    }

    dut.src_addr       = src_addr;
    dut.dst_addr       = dst_addr;
    dut.length         = length;
    dut.ddr_mock_delay = ddr_delay;
    dut.start          = 1;
    // Hold the mock's copy-port busy window from the very start of the
    // transfer: the flush side's first cpreq pulse (issued as soon as
    // the first page's fill loop hands off) must therefore land while
    // mock_busy is asserted, exactly reproducing the real bug's
    // vanishing-edge scenario.
    if (busy_hold_cycles > 0) dut.mock_busy = 1;
    tb.WaitPosedgeA();
    dut.start = 0;

    if (!dut.busy) {
        std::fprintf(stderr, "  busy did not assert after start\n");
        return false;
    }

    std::vector<PageCapture> pages;
    bool saw_done = false;
    int busy_remaining = busy_hold_cycles;
    for (int i = 0; i < 2000000 && !saw_done; ++i) {
        tb.WaitPosedgeB();
        if (busy_remaining > 0) {
            --busy_remaining;
            if (busy_remaining == 0) dut.mock_busy = 0;
        }
        if (dut.cp_accept_probe) {
            pages.emplace_back();
            pages.back().addr = dut.cp_addr_probe;
        }
        if (dut.cp_word_valid_probe) {
            if (pages.empty()) {
                std::fprintf(stderr, "  word captured with no page accepted\n");
                return false;
            }
            PageCapture &p = pages.back();
            uint32_t idx = dut.cp_word_idx_probe;
            if (idx != static_cast<uint32_t>(p.count)) {
                std::fprintf(stderr, "  page word out of order: got idx %u, expected %d\n",
                              idx, p.count);
                return false;
            }
            p.words[p.count++] = dut.cp_word_data_probe;
        }
        // done is a clk_sys-domain pulse; sampling it once per clk_sdram
        // step is safe since it stays high a full clk_sys half-period,
        // much longer than one clk_sdram step.
        if (dut.done) saw_done = true;
    }
    if (!saw_done) {
        std::fprintf(stderr, "  done never observed\n");
        return false;
    }

    uint32_t expected_pages = (length + 1023) / 1024;
    if (pages.size() != expected_pages) {
        std::fprintf(stderr, "  got %zu pages, expected %u\n", pages.size(), expected_pages);
        return false;
    }

    uint32_t dst_word_base = dst_addr >> 1;
    for (size_t pi = 0; pi < pages.size(); ++pi) {
        const PageCapture &p = pages[pi];
        uint32_t expected_page_addr = dst_word_base + static_cast<uint32_t>(pi) * 512u;
        if (p.addr != expected_page_addr) {
            std::fprintf(stderr, "  page %zu addr=0x%x, expected 0x%x\n", pi, p.addr,
                          expected_page_addr);
            return false;
        }
        if (p.count != 512) {
            std::fprintf(stderr, "  page %zu only captured %d of 512 words\n", pi, p.count);
            return false;
        }
        // Only the words actually covered by `length` (not the whole
        // page) are checked against the DDR3 pattern -- any tail beyond
        // that is documented as stale/don't-care.
        uint32_t page_byte_base = static_cast<uint32_t>(pi) * 1024u;
        for (int wi = 0; wi < 512; ++wi) {
            uint32_t byte_off = page_byte_base + static_cast<uint32_t>(wi) * 2u;
            if (byte_off >= length) break;
            uint32_t src_word_addr = (src_addr >> 1) + byte_off / 2;
            uint16_t expected = ExpectedWord(src_word_addr);
            if (p.words[wi] != expected) {
                std::fprintf(stderr,
                              "  page %zu word %d = 0x%04x, expected 0x%04x (src_word_addr=0x%x)\n",
                              pi, wi, p.words[wi], expected, src_word_addr);
                return false;
            }
        }
    }

    // Give the clk_sys side a few more cycles to settle back to idle.
    for (int i = 0; i < 8; ++i) tb.WaitPosedgeA();
    if (dut.busy) {
        std::fprintf(stderr, "  busy did not clear after done\n");
        return false;
    }
    return true;
}

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    Testbench tb;
    Vsdram_loader_dut &dut = tb.dut();

    dut.clk_sys = 0;
    dut.clk_sdram = 0;
    dut.reset = 1;
    dut.reset_b = 1;
    dut.start = 0;
    dut.src_addr = 0;
    dut.dst_addr = 0;
    dut.length = 0;
    dut.ddr_mock_delay = 0;
    dut.mock_busy = 0;
    for (int i = 0; i < 8; ++i) tb.WaitPosedgeA();
    for (int i = 0; i < 8; ++i) tb.WaitPosedgeB();
    dut.reset = 0;
    dut.reset_b = 0;
    tb.WaitPosedgeA();
    tb.WaitPosedgeB();

    if (dut.busy || dut.done)
        return Fail("reset state is wrong");

    const struct {
        uint32_t src, dst, length;
        uint8_t delay;
    } kLoads[] = {
        {0x3140'0000u, 0x0000'0000u, 1024, 0},     // exactly one page
        {0x3140'0000u, 0x0000'0400u, 2304, 2},     // 24x24x4B sprite, not page-aligned length
        {0x3140'2000u, 0x0000'3000u, 9216, 0},     // 48x48x4B sprite, several pages
        {0x0000'0008u, 0x0010'0000u, 8, 5},        // tiny, sub-page length
    };

    for (const auto &l : kLoads) {
        if (!RunOneLoad(tb, l.src, l.dst, l.length, l.delay)) {
            std::fprintf(stderr, "  (src=0x%08x dst=0x%08x length=%u delay=%u)\n",
                          l.src, l.dst, l.length, l.delay);
            return Fail("sdram_loader page load failed");
        }
    }

    // Regression test for the real hardware-only hang this session found
    // (see this file's header and sdram_loader.sv's B_ISSUE comment): a
    // busy window held from the moment the transfer starts, long enough
    // to guarantee the first cpreq pulse would have landed inside it
    // under the old one-cycle-pulse design.
    if (!RunOneLoad(tb, 0x3140'0000u, 0x0000'0000u, 1024, /*ddr_delay=*/0,
                     /*busy_hold_cycles=*/50000)) {
        return Fail("sdram_loader hung across a busy copy-port window");
    }

    std::printf(
        "PASS: sdram_loader copies DDR3 source pages into sdram.sv's copy "
        "port with correct addressing, ordering, and data\n");
    return 0;
}
