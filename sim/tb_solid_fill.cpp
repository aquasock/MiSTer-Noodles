// Verilator testbench for CMDQ + BLIT's SOLID_FILL path (BLIT-001/BLIT-002).
// Issues one SOLID_FILL command against a modelled byte-addressed memory and
// checks that exactly the destination rectangle was written, at the right
// addresses, with the right pixel value, and nothing outside it was touched.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <vector>

#include "Vengine_dut.h"
#include "verilated.h"

namespace {

constexpr uint32_t kOpSolidFill = 0x01;

struct Command {
    uint32_t opcode;
    uint32_t dst_addr;
    uint32_t dst_pitch;
    uint32_t width;
    uint32_t height;
    uint32_t color;
    uint32_t reserved0 = 0;
    uint32_t reserved1 = 0;
};

void PackCommand(const Command &c, Vengine_dut &dut) {
    dut.cmd_data[0] = c.opcode;
    dut.cmd_data[1] = c.dst_addr;
    dut.cmd_data[2] = c.dst_pitch;
    dut.cmd_data[3] = c.width;
    dut.cmd_data[4] = c.height;
    dut.cmd_data[5] = c.color;
    dut.cmd_data[6] = c.reserved0;
    dut.cmd_data[7] = c.reserved1;
}

class Memory {
public:
    explicit Memory(size_t bytes) : data_(bytes, 0xEE) {}

    void MaybeWrite(bool wr_en, bool wr_ready, uint32_t addr, uint32_t value) {
        if (!(wr_en && wr_ready)) return;
        if (addr + 4 > data_.size()) {
            std::fprintf(stderr, "write out of bounds: addr=0x%08x\n", addr);
            std::exit(1);
        }
        for (int i = 0; i < 4; ++i) data_[addr + i] = (value >> (8 * i)) & 0xFF;
        writes_.push_back(addr);
    }

    void MaybeWrite64(bool wr_en, bool wr_ready, uint32_t addr, uint64_t value) {
        if (!(wr_en && wr_ready)) return;
        for (int i = 0; i < 8; ++i) data_[addr + i] = (value >> (8 * i)) & 0xFF;
        writes_.push_back(addr);
        writes_.push_back(addr + 4);
    }

    uint32_t Read32(uint32_t addr) const {
        return data_[addr] | (data_[addr + 1] << 8) | (data_[addr + 2] << 16) |
               (data_[addr + 3] << 24);
    }

    const std::vector<uint32_t> &writes() const { return writes_; }
    uint8_t RawByte(uint32_t addr) const { return data_[addr]; }

private:
    std::vector<uint8_t> data_;
    std::vector<uint32_t> writes_;
};

class Testbench {
public:
    Testbench() : dut_(new Vengine_dut) {}
    ~Testbench() { dut_->final(); }

    void Tick(Memory &mem, bool wr_ready) {
        dut_->wr_ready = wr_ready ? 1 : 0;
        dut_->wr64_ready = wr_ready ? 1 : 0;

        dut_->clk = 0;
        dut_->eval();

        dut_->clk = 1;
        dut_->eval();
        mem.MaybeWrite(dut_->wr_en, dut_->wr_ready, dut_->wr_addr, dut_->wr_data);
        mem.MaybeWrite64(dut_->wr64_en, dut_->wr64_ready, dut_->wr64_addr,
                         dut_->wr64_data);
    }

    Vengine_dut &dut() { return *dut_; }

private:
    std::unique_ptr<Vengine_dut> dut_;
};

int Fail(const char *msg) {
    std::fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    Testbench tb;
    Memory mem(0x4000);
    Vengine_dut &dut = tb.dut();

    // Reset for a few cycles.
    dut.reset = 1;
    dut.cmd_valid = 0;
    for (int i = 0; i < 4; ++i) tb.Tick(mem, /*wr_ready=*/true);
    dut.reset = 0;
    tb.Tick(mem, /*wr_ready=*/true);

    const Command cmd{
        .opcode = kOpSolidFill,
        .dst_addr = 0x1000,
        .dst_pitch = 8 * 4,  // 8px wide surface, 4 bytes/pixel
        .width = 8,
        .height = 4,
        .color = 0xAABBCCDDu,
    };
    PackCommand(cmd, dut);
    dut.cmd_valid = 1;

    // cmdq is idle and blit is not busy right after reset, so the very next
    // edge accepts the command (cmdq.sv's IDLE branch has no other gate).
    if (!dut.cmd_ready) return Fail("cmdq not ready to accept right after reset");
    tb.Tick(mem, /*wr_ready=*/true);
    dut.cmd_valid = 0;

    // Run until cmd_ready returns (blit finished) or we time out.
    int guard = 0;
    do {
        tb.Tick(mem, /*wr_ready=*/(guard % 3) != 1);
        if (++guard > 10000) return Fail("blit never completed");
    } while (!dut.cmd_ready);

    // Verify: exactly width*height writes, each landing inside the rect,
    // each holding the fill color, row pitch respected.
    const auto &writes = mem.writes();
    if (writes.size() != cmd.width * cmd.height) {
        std::fprintf(stderr, "expected %u writes, got %zu\n",
                     cmd.width * cmd.height, writes.size());
        return Fail("write count mismatch");
    }

    for (uint32_t row = 0; row < cmd.height; ++row) {
        for (uint32_t col = 0; col < cmd.width; ++col) {
            const uint32_t addr = cmd.dst_addr + row * cmd.dst_pitch + col * 4;
            const uint32_t got = mem.Read32(addr);
            if (got != cmd.color) {
                std::fprintf(stderr,
                              "pixel (%u,%u) at 0x%08x: expected 0x%08x got 0x%08x\n",
                              col, row, addr, cmd.color, got);
                return Fail("pixel value mismatch");
            }
        }
    }

    // Sanity: a byte just past the last row of the rect was never touched.
    const uint32_t past_end = cmd.dst_addr + cmd.height * cmd.dst_pitch;
    if (mem.RawByte(past_end) != 0xEE) {
        return Fail("write escaped destination rectangle");
    }

    std::printf("PASS: solid-fill %ux%u at 0x%08x, %zu writes, pitch %u\n",
                cmd.width, cmd.height, cmd.dst_addr, writes.size(), cmd.dst_pitch);
    return 0;
}
