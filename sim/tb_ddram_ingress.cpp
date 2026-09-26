#include "Vddram_adapter.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <deque>

static void Check(bool ok, const char *message) {
    if (!ok) {
        std::fprintf(stderr, "FAIL: %s\n", message);
        std::exit(1);
    }
}

struct Command {
    bool we = false, rd = false;
    uint32_t addr = 0;
    uint64_t din = 0;
    uint8_t be = 0, burstcnt = 0;
    bool operator==(const Command &o) const {
        return we == o.we && rd == o.rd && addr == o.addr && burstcnt == o.burstcnt &&
               (!we || (din == o.din && be == o.be));
    }
};

struct Write {
    uint32_t addr;
    uint64_t data;
    uint8_t be;
};

class Testbench {
public:
    Vddram_adapter dut;
    std::deque<Write> writes;
    unsigned accepted = 0, issued = 0, read_accepted = 0, read_returned = 0;
    unsigned run = 0, longest_run = 0;
    unsigned write_burst_left = 0, write_burst_index = 0;
    unsigned write_burst_base = 0, write_burst_count = 0, max_write_burst = 0;
    int response_delay = 0;
    bool read_pending = false;
    bool response_next = false;
    Command held;

    void Reset() {
        dut.wr_en = dut.wr64_en = dut.rd_en = dut.rd64_en = 0;
        dut.ddram_busy = dut.ddram_dout_ready = 0;
        dut.rd64_len = 1;
        dut.reset = 1;
        for (int i = 0; i < 3; ++i) {
            dut.clk = 0; dut.eval();
            dut.clk = 1; dut.eval();
        }
        dut.reset = 0;
        writes.clear();
        response_delay = 0;
        read_pending = false;
        held = Command{};
        response_next = false;
        run = longest_run = 0;
        write_burst_left = write_burst_index = 0;
        write_burst_base = write_burst_count = max_write_burst = 0;
        accepted = issued = read_accepted = read_returned = 0;
        dut.clk = 0; dut.eval();
        Check(dut.idle, "reset did not empty ingress and queue");
    }

    void DriveWrite(unsigned n, bool scalar, bool paired) {
        dut.wr_en = scalar;
        dut.wr64_en = paired;
        dut.wr_addr = 0x1000 + n * 4;
        dut.wr_data = 0xa5000000u ^ n;
        dut.wr64_addr = 0x2000 + n * 8;
        dut.wr64_data = 0x123456789abcdef0ull ^ n;
    }

    void Tick(bool busy, bool reads = false) {
        dut.ddram_busy = busy;
        dut.rd_en = reads && !read_pending;
        dut.rd_addr = 0x8004;
        dut.ddram_dout_ready = response_delay == 1;
        dut.ddram_dout = 0x1122334455667788ull;
        dut.clk = 0; dut.eval();
        Check(!(dut.ddram_we && dut.ddram_rd), "read/write commands overlap");
        Check(!dut.idle || (writes.empty() && !read_pending), "idle with accepted work outstanding");
        // Avalon-MM: a command presented while the bridge is busy is not
        // accepted and must be held unchanged until a non-busy cycle.
        Command now{bool(dut.ddram_we), bool(dut.ddram_rd), uint32_t(dut.ddram_addr),
                    uint64_t(dut.ddram_din), uint8_t(dut.ddram_be), uint8_t(dut.ddram_burstcnt)};
        if (held.we || held.rd)
            Check(now == held, "command changed or withdrawn while the bridge was busy");
        held = busy ? now : Command{};

        if (dut.ddram_we && !busy) {
            Check(!writes.empty(), "write issued before acceptance/commit");
            if (!write_burst_left) {
                Check(dut.ddram_burstcnt >= 1 && dut.ddram_burstcnt <= 8,
                      "write burst length is outside the adapter limit");
                write_burst_base = dut.ddram_addr;
                write_burst_count = dut.ddram_burstcnt;
                write_burst_left = write_burst_count;
                write_burst_index = 0;
                if (write_burst_count > max_write_burst)
                    max_write_burst = write_burst_count;
            } else {
                Check(dut.ddram_addr == write_burst_base &&
                      dut.ddram_burstcnt == write_burst_count,
                      "write burst address or count changed between beats");
            }
            auto expected = writes.front();
            writes.pop_front();
            Check(write_burst_base + write_burst_index == expected.addr &&
                  dut.ddram_din == expected.data && dut.ddram_be == expected.be,
                  "write lost, reordered, duplicated or wrong byte lanes");
            ++write_burst_index;
            --write_burst_left;
            ++issued;
            if (++run > longest_run) longest_run = run;
        } else {
            run = 0;
        }
        bool scalar = dut.wr_en && dut.wr_ready;
        bool paired = dut.wr64_en && dut.wr64_ready;
        Check(!(scalar && paired), "both input ports acknowledged into one slot");
        if (paired) {
            writes.push_back({dut.wr64_addr >> 3, dut.wr64_data, 0xff});
            ++accepted;
        } else if (scalar) {
            bool upper = (dut.wr_addr & 4) != 0;
            writes.push_back({dut.wr_addr >> 3,
                              uint64_t(dut.wr_data) << (upper ? 32 : 0),
                              uint8_t(upper ? 0xf0 : 0x0f)});
            ++accepted;
        }
        Check(writes.size() <= 16, "ingress increased accepted capacity beyond sixteen writes");
        if (dut.rd_en && dut.rd_ready) {
            read_pending = true;
            ++read_accepted;
        }
        if (response_delay) --response_delay;
        if (dut.ddram_rd && !busy) {
            Check(dut.ddram_addr == (0x8004 >> 3) && dut.ddram_burstcnt == 1,
                  "read corrupted under write contention");
            Check(response_delay == 0, "unexpected extra read");
            response_delay = 3;
        }
        // The adapter registers returned data, so a word the bridge returns
        // reaches the client on the following cycle.
        if (response_next) {
            Check(dut.rd_valid && dut.rd_data == 0x11223344u && !dut.rd64_valid,
                  "scalar response corrupted under write contention");
            read_pending = false;
            ++read_returned;
        } else {
            Check(!dut.rd_valid && !dut.rd64_valid, "response without a returned word");
        }
        response_next = dut.ddram_dout_ready;
        dut.clk = 1; dut.eval();
    }

    void Drain() {
        dut.wr_en = dut.wr64_en = 0;
        for (int i = 0; i < 1000; ++i) {
            Tick(false);
            if (dut.idle) {
                Check(writes.empty() && accepted == issued && read_accepted == read_returned,
                      "idle before all accepted commands completed");
                Check(write_burst_left == 0, "idle in the middle of a write burst");
                return;
            }
        }
        Check(false, "queue failed to drain");
    }
};

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Testbench tb;
    tb.Reset();
    // Freeze the bridge: the ingress reservation must count against capacity.
    for (unsigned n = 0; n < 48; ++n) {
        tb.DriveWrite(n, n % 2 == 0, n % 2 != 0);
        tb.Tick(true);
    }
    Check(tb.accepted == 16 && !tb.dut.wr_ready && !tb.dut.wr64_ready,
          "full queue did not accept exactly sixteen writes");
    tb.Drain();

    tb.Reset();
    for (unsigned n = 0; n < 256; ++n) {
        unsigned before = tb.accepted;
        do {
            tb.DriveWrite(n, false, true);
            tb.Tick(false);
        } while (tb.accepted == before);
    }
    tb.Drain();
    std::printf("contiguous: accepted=%u issued=%u max-burst=%u longest-run=%u\n",
                tb.accepted, tb.issued, tb.max_write_burst, tb.longest_run);
    Check(tb.accepted == 256 && tb.max_write_burst == 8 && tb.longest_run >= 8,
          "contiguous full writes did not form eight-beat bursts");

    tb.Reset();
    uint32_t random = 0x12345678;
    for (unsigned n = 0; n < 6000; ++n) {
        random = random * 1664525u + 1013904223u;
        tb.DriveWrite(n, (random & 1) != 0, (random & 2) != 0);
        tb.Tick((random & 0x70) != 0, true);
    }
    tb.Drain();
    Check(tb.issued > 100 && tb.read_returned > 100, "contention did not make progress");

    for (unsigned age : {1u, 2u, 16u}) {
        tb.Reset();
        for (unsigned n = 0; n < age; ++n) {
            tb.DriveWrite(n, false, true);
            tb.Tick(true);
        }
        tb.Reset();
        for (int i = 0; i < 20; ++i) tb.Tick(false);
        Check(tb.issued == 0, "stale write escaped reset");
        tb.DriveWrite(99, true, false);
        tb.Tick(false);
        tb.Drain();
        Check(tb.issued == 1, "post-reset write missing");
    }
    std::puts("PASS: DDRAM ingress preserves 16-write capacity, ordering, eight-beat bursts, arbitration and reset");
    return 0;
}
