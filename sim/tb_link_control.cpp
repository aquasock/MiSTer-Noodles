#include <cstdint>
#include <cstdio>
#include <memory>
#include <unordered_map>

#include "Vlink_control_dut.h"
#include "verilated.h"

namespace {
constexpr uint32_t kBase = 0x30020010u;
constexpr uint32_t kMagic = 0x4e444c53u;
constexpr uint32_t kClaim = 0x434c414du;
constexpr uint32_t kReqLo = kBase + 0x18;
constexpr uint32_t kReqHi = kBase + 0x1c;
constexpr uint32_t kReqSeq = kBase + 0x20;
constexpr uint32_t kRspLo = kBase + 0x28;
constexpr uint32_t kRspHi = kBase + 0x2c;
constexpr uint32_t kRspSeq = kBase + 0x30;

class Testbench {
public:
    Testbench() : dut(new Vlink_control_dut) {
        dut->rd_ready = 1;
        dut->wr_ready = 1;
        dut->device_initialized = 0;
        dut->bus_available = 1;
    }
    ~Testbench() { dut->final(); }

    void Tick() {
        dut->rd_valid = pending;
        dut->rd_data = pending ? memory[pending_addr] : 0;
        dut->clk = 0;
        dut->eval();
        bool accepted = dut->rd_en && dut->rd_ready;
        uint32_t accepted_addr = dut->rd_addr;
        dut->clk = 1;
        dut->eval();
        if (dut->wr_en && dut->wr_ready) memory[dut->wr_addr] = dut->wr_data;
        pending = accepted;
        if (pending) pending_addr = accepted_addr;
    }

    bool RunUntil(uint32_t addr, uint32_t value, int limit = 1000) {
        while (memory[addr] != value && limit-- > 0) Tick();
        return memory[addr] == value;
    }

    std::unique_ptr<Vlink_control_dut> dut;
    std::unordered_map<uint32_t, uint32_t> memory;
    bool pending = false;
    uint32_t pending_addr = 0;
};

int Fail(const char *message) {
    std::fprintf(stderr, "FAIL: %s\n", message);
    return 1;
}
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Testbench tb;
    tb.memory[kBase] = kMagic;
    tb.memory[kReqSeq] = 0x12345678;
    tb.memory[kRspSeq] = 0x87654321;
    tb.dut->reset = 1;
    for (int i = 0; i < 3; ++i) tb.Tick();
    tb.dut->reset = 0;
    if (!tb.RunUntil(kBase, kMagic)) return Fail("identity initialization did not finish");
    if (tb.memory[kReqSeq] || tb.memory[kRspSeq]) return Fail("reset did not clear sequence words");
    if (tb.memory[kBase + 4] != 0x00010000 || tb.memory[kBase + 8] != 0x7e ||
        tb.memory[kBase + 0xc] != ((800u << 16) | 600u) || tb.memory[kBase + 0x10] != 3200) {
        return Fail("identity fields do not match protocol");
    }

    tb.memory[kReqLo] = 0x11223344;
    tb.memory[kReqHi] = 0x55667788;
    tb.memory[kReqSeq] = 1;
    for (int i = 0; i < 50; ++i) tb.Tick();
    if (tb.dut->session_active || tb.memory[kRspSeq]) return Fail("inactive core accepted a ping");

    tb.memory[kReqSeq] = kClaim;
    for (int i = 0; i < 50; ++i) tb.Tick();
    if (tb.dut->session_active || tb.memory[kRspSeq])
        return Fail("claim was accepted before device initialization");
    tb.dut->device_initialized = 1;
    if (!tb.RunUntil(kRspSeq, kClaim) || !tb.dut->session_active)
        return Fail("valid session claim was not acknowledged");
    if (tb.memory[kRspLo] != 0x11223344 || tb.memory[kRspHi] != 0x55667788)
        return Fail("claim response token mismatch");

    tb.memory[kReqSeq] = 2;
    if (!tb.RunUntil(kRspSeq, 2)) return Fail("live ping was not acknowledged");
    tb.memory[kReqLo] ^= 1;
    tb.memory[kReqSeq] = 3;
    for (int i = 0; i < 50; ++i) tb.Tick();
    if (tb.memory[kRspSeq] == 3) return Fail("wrong-token ping was acknowledged");
    tb.memory[kReqLo] ^= 1;
    tb.memory[kReqSeq] = 0;
    if (!tb.RunUntil(kRspSeq, 0) || tb.dut->session_active) return Fail("close did not disarm");

    tb.memory[kReqSeq] = kClaim;
    if (!tb.RunUntil(kRspSeq, kClaim) || !tb.dut->session_active) return Fail("reclaim failed");
    tb.dut->reset = 1;
    tb.Tick();
    tb.dut->reset = 0;
    tb.memory[kReqSeq] = 9;
    if (!tb.RunUntil(kRspSeq, 0)) return Fail("reset response clear did not land");
    for (int i = 0; i < 100; ++i) tb.Tick();
    if (tb.dut->session_active || tb.memory[kRspSeq] != 0)
        return Fail("stale post-reset ping reactivated session");

    std::puts("PASS: live identity initialization, claim, ping, close and reset disarm");
    return 0;
}
