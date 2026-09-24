#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <utility>
#include <vector>

#include "Vblit_copy64.h"
#include "verilated.h"

namespace {

constexpr uint32_t kKey = 0xCAFEBABE;
constexpr uint32_t kSrc = 0x30010000;
constexpr uint32_t kDst = 0x30020000;

void Check(bool ok, const char *message) {
    if (!ok) {
        std::fprintf(stderr, "FAIL: %s\n", message);
        std::exit(1);
    }
}

void Edge(Vblit_copy64 &dut) {
    dut.clk = 0;
    dut.eval();
    dut.clk = 1;
    dut.eval();
}

void Reset(Vblit_copy64 &dut) {
    dut.reset = 1;
    dut.start = 0;
    dut.rd64_valid = 0;
    dut.rd64_ready = 0;
    dut.wr_ready = 0;
    dut.wr64_ready = 0;
    Edge(dut);
    dut.reset = 0;
    Edge(dut);
    Check(!dut.busy && !dut.done && !dut.wr_en && !dut.wr64_en && !dut.rd64_en,
          "reset did not clear pending transactions");
}

uint32_t Pixel(unsigned index, unsigned key_mode) {
    // Modes 1..4 cover neither, lower, upper and both pixels keyed in
    // successive pairs; mode 5 makes every pair fully transparent.
    unsigned mask = key_mode == 5 ? 3 : key_mode ? ((index / 2 + key_mode) % 4) : 0;
    return (mask & (1u << (index % 2))) ? kKey : 0xB0000000u + index;
}

void Run(Vblit_copy64 &dut, unsigned width, unsigned height,
         unsigned offset, unsigned key_mode, bool stalls, bool abort = false) {
    using PixelWrite = std::pair<uint32_t, uint32_t>;
    const unsigned src_pitch = width * 4 + 16;
    const unsigned dst_pitch = width * 4 + 12; // alternates row alignment
    std::vector<PixelWrite> expected;
    for (unsigned y = 0; y < height; ++y) {
        for (unsigned x = 0; x < width; ++x) {
            uint32_t value = Pixel(y * width + x, key_mode);
            if (!key_mode || value != kKey)
                expected.emplace_back(kDst + offset + y * dst_pitch + x * 4, value);
        }
    }
    dut.dst_addr = kDst + offset;
    dut.src_addr = kSrc;
    dut.src_pitch = src_pitch;
    dut.dst_pitch = dst_pitch;
    dut.width = width;
    dut.height = height;
    dut.key_enable = key_mode != 0;
    dut.key_value = kKey;
    dut.start = 1;
    Edge(dut);
    dut.start = 0;

    struct Response { uint64_t data; unsigned earliest; };
    std::deque<Response> responses;
    size_t written = 0;
    unsigned requested = 0, returned = 0;
    unsigned consecutive = 0, max_consecutive = 0;
    unsigned blocked_cycles = 0, final_stall = 0;
    bool stalled_read = false, stalled_scalar = false, stalled_pair = false;
    uint32_t held_read_addr = 0, held_scalar_addr = 0, held_pair_addr = 0;
    unsigned held_len = 0;
    uint32_t held_scalar_data = 0;
    uint64_t held_pair_data = 0;
    auto accept = [&](uint32_t address, uint32_t data) {
        Check(written < expected.size(), "duplicate or unexpected write");
        Check(expected[written] == PixelWrite(address, data), "write data/address/order mismatch");
        ++written;
    };

    for (unsigned cycle = 0; cycle < 20000; ++cycle) {
        dut.rd64_ready = !stalls || cycle % 11 >= 4;
        dut.wr_ready = !stalls || cycle % 37 >= 23;
        dut.wr64_ready = !stalls || cycle % 29 >= 17;
        if (abort) dut.wr_ready = dut.wr64_ready = 0;
        // Hold the very last write to catch premature done/new-start loss.
        if (stalls && !expected.empty() &&
            ((dut.wr_en && written + 1 == expected.size()) ||
             (dut.wr64_en && written + 2 == expected.size())) && final_stall < 40) {
            dut.wr_ready = dut.wr64_ready = 0;
            ++final_stall;
        }
        dut.rd64_valid = !responses.empty() && responses.front().earliest <= cycle &&
                         (!stalls || cycle % 7 != 0);
        dut.rd64_data = dut.rd64_valid ? responses.front().data : 0;
        dut.clk = 0;
        dut.eval();

        Check(!stalled_read || (dut.rd64_en && dut.rd64_addr == held_read_addr &&
                               dut.rd64_len == held_len), "read changed while stalled");
        Check(!stalled_scalar || (dut.wr_en && dut.wr_addr == held_scalar_addr &&
                                 dut.wr_data == held_scalar_data), "scalar changed while stalled");
        Check(!stalled_pair || (dut.wr64_en && dut.wr64_addr == held_pair_addr &&
                               dut.wr64_data == held_pair_data), "pair changed while stalled");
        Check(!(dut.wr_en && dut.wr64_en), "both write ports active (adapter accepts only one)");
        stalled_read = dut.rd64_en && !dut.rd64_ready;
        stalled_scalar = dut.wr_en && !dut.wr_ready;
        stalled_pair = dut.wr64_en && !dut.wr64_ready;
        held_read_addr = dut.rd64_addr; held_len = dut.rd64_len;
        held_scalar_addr = dut.wr_addr; held_scalar_data = dut.wr_data;
        held_pair_addr = dut.wr64_addr; held_pair_data = dut.wr64_data;
        blocked_cycles += stalled_scalar || stalled_pair;

        if (dut.rd64_valid) {
            responses.pop_front();
            ++returned;
        }
        if (dut.rd64_en && dut.rd64_ready) {
            const unsigned row = requested / (width / 2);
            const unsigned col = requested % (width / 2);
            Check(row < height && dut.rd64_len > 0 && dut.rd64_len <= 16,
                  "invalid read burst length/count");
            Check(col + dut.rd64_len <= width / 2, "read crossed a row boundary");
            Check(dut.rd64_addr == kSrc + row * src_pitch + col * 8,
                  "read address skipped or repeated a pair");
            for (unsigned i = 0; i < dut.rd64_len; ++i) {
                unsigned pixel = (requested + i) * 2;
                responses.push_back({uint64_t(Pixel(pixel, key_mode)) |
                                     (uint64_t(Pixel(pixel + 1, key_mode)) << 32), cycle + 3});
            }
            requested += dut.rd64_len;
        }
        if (dut.wr_en && dut.wr_ready) accept(dut.wr_addr, dut.wr_data);
        if (dut.wr64_en && dut.wr64_ready) {
            Check((dut.wr64_addr & 7) == 0, "unaligned paired write");
            accept(dut.wr64_addr, uint32_t(dut.wr64_data));
            accept(dut.wr64_addr + 4, uint32_t(dut.wr64_data >> 32));
            max_consecutive = std::max(max_consecutive, ++consecutive);
        } else {
            consecutive = 0;
        }
        dut.clk = 1;
        dut.eval();
        if (abort && cycle == 100) {
            Check(blocked_cycles > 0 && dut.busy, "reset case never stalled");
            Reset(dut);
            std::puts("PASS: reset with buffered head and stalled output");
            return;
        }
        if (dut.done) {
            Check(!dut.busy && written == expected.size(), "done before all writes accepted");
            Check(requested == width * height / 2 && returned == requested && responses.empty(),
                  "done before all responses consumed");
            Check(!dut.wr_en && !dut.wr64_en && !dut.rd64_en, "pending output at done");
            if (stalls && !expected.empty())
                Check(blocked_cycles > 0 && final_stall == 40, "backpressure coverage missing");
            if (!stalls && !key_mode && !offset && width >= 64)
                Check(max_consecutive >= 8, "pipeline cannot sustain one pair per cycle");
            Edge(dut);
            Check(!dut.done, "done is not a pulse");
            std::printf("PASS: pipeline %ux%u offset=%u key=%u stalls=%u cycles=%u max_run=%u\n",
                        width, height, offset, key_mode, stalls, cycle + 1, max_consecutive);
            return;
        }
        Check(dut.busy, "busy dropped before done");
    }
    Check(false, "pipeline timeout");
}

} // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vblit_copy64 dut;
    Reset(dut);
    Run(dut, 128, 4, 0, 0, false);
    for (unsigned mode = 0; mode <= 5; ++mode) {
        Run(dut, 48, 5, 0, mode, true);
        Run(dut, 34, 3, 4, mode, true);
    }
    Run(dut, 2, 1, 0, 0, true);
    Run(dut, 2, 1, 4, 0, true);
    Run(dut, 64, 4, 0, 0, true, true);
    Run(dut, 64, 2, 0, 0, false);
    dut.final();
    return 0;
}
