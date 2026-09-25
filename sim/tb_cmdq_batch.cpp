#include <cstdio>
#include "Vcmdq_batch_dut.h"
#include "verilated.h"

namespace {

void Tick(Vcmdq_batch_dut &dut) {
    dut.clk = 0; dut.eval(); dut.clk = 1; dut.eval();
}

void Command(Vcmdq_batch_dut &dut, uint32_t op, uint32_t word1) {
    for (int i = 0; i < 8; ++i) dut.cmd_data[i] = 0;
    dut.cmd_data[0] = op; dut.cmd_data[1] = word1;
    dut.eval();  // cmd_ready is combinational in the presented opcode
}

// Blend-fill draw into a display buffer, used as the work queued behind a
// pending flip.
void Draw(Vcmdq_batch_dut &dut, uint32_t dst) {
    for (int i = 0; i < 8; ++i) dut.cmd_data[i] = 0;
    dut.cmd_data[0] = 8; dut.cmd_data[1] = dst; dut.cmd_data[2] = 3200;
    dut.cmd_data[3] = 4; dut.cmd_data[4] = 4; dut.cmd_data[5] = 0x80402010;
    dut.cmd_data[6] = 0x6c5a3c10;
    dut.eval();
}

// Offers the prepared command; cmd_ready depends on cmd_valid.
void Offer(Vcmdq_batch_dut &dut) {
    dut.cmd_valid = 1;
    dut.eval();
}

void Vblank(Vcmdq_batch_dut &dut) {
    dut.fb_vbl = 0; Tick(dut);
    dut.fb_vbl = 1; Tick(dut);
}

int Fail(const char *msg) {
    std::fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

// OUT-013: queued three-buffer PRESENT through CMDQ and the real present
// engine, plus the unchanged legacy PRESENT alongside it.
int TestPresent(Vcmdq_batch_dut &dut) {
    int accepts = 0, dones = 0, retirements = 0;
    auto tick = [&]() {
        Tick(dut);
        accepts += dut.present_accept; dones += dut.present_done;
        retirements += dut.present_retired;
    };
    if (dut.front_idx != 0 || dut.present_busy) return Fail("present reset state");

    // A queued PRESENT is accepted at once and completes its command
    // through present_accept while the flip itself stays pending.
    Command(dut, 11, 1); Offer(dut);
    if (!dut.cmd_ready) return Fail("queued PRESENT not ready on an idle engine");
    tick(); dut.cmd_valid = 0;
    if (!dut.present_start) return Fail("queued PRESENT did not start the present engine");
    tick();
    // link_ring leaves the accepted slot on cmd_data with cmd_valid low; that
    // retained PRESENT must not hold CMDQ while its flip is pending.
    dut.eval();
    if (accepts != 1 || !dut.present_busy || !dut.cmd_ready)
        return Fail("queued PRESENT did not complete on acceptance or held CMDQ");

    // A draw behind the pending flip runs immediately.
    Draw(dut, 0x31600000); Offer(dut);
    if (!dut.cmd_ready) return Fail("draw blocked behind a pending queued flip");
    tick(); dut.cmd_valid = 0;
    if (!dut.blend_start || dut.copy_dst_addr != 0x31600000)
        return Fail("draw behind a pending flip did not dispatch");
    dut.blend_done = 1; tick(); dut.blend_done = 0;
    if (!dut.cmd_ready || !dut.present_busy) return Fail("draw did not retire during the flip");

    // A second PRESENT waits unaccepted until the first flip retires.
    Command(dut, 11, 2); Offer(dut);
    for (int i = 0; i < 4; ++i) {
        if (dut.cmd_ready) return Fail("second PRESENT accepted while a flip is pending");
        tick();
        if (dut.present_start) return Fail("second PRESENT started while a flip is pending");
    }

    // An acknowledgement before the flip does not retire it: queued flips
    // capture the retirement level at the flip itself.
    dut.fb_retired ^= 1; tick();
    Vblank(dut);
    if (dut.front_idx != 1) return Fail("queued flip did not show buffer B at vblank");
    for (int i = 0; i < 3; ++i) tick();
    if (!dut.present_busy || retirements)
        return Fail("queued flip retired on an acknowledgement from before the flip");
    dut.fb_retired ^= 1; tick(); tick();
    if (dut.present_busy || retirements != 1 || dones)
        return Fail("queued flip retirement or legacy done pulse is wrong");

    // The held PRESENT is now accepted.
    int waited = 0;
    while (!dut.present_start && waited++ < 4) tick();
    dut.cmd_valid = 0;
    if (!dut.present_start) return Fail("held PRESENT was not accepted after retirement");
    tick();
    if (accepts != 2) return Fail("held PRESENT did not complete on acceptance");
    Vblank(dut);
    if (dut.front_idx != 2) return Fail("queued flip did not show buffer C");
    dut.fb_retired ^= 1; tick(); tick();
    if (dut.present_busy || retirements != 2) return Fail("buffer C flip did not retire");

    // Index 3 is a flip barrier: held while a flip is pending, then
    // completed on acceptance without flipping.
    Command(dut, 11, 0); Offer(dut); tick(); dut.cmd_valid = 0; tick();
    if (accepts != 3 || !dut.present_busy) return Fail("queued flip to A was not accepted");
    Command(dut, 11, 3); Offer(dut);
    for (int i = 0; i < 3; ++i) {
        if (dut.cmd_ready) return Fail("flip barrier accepted while a flip is pending");
        tick();
    }
    Vblank(dut);
    if (dut.front_idx != 0) return Fail("queued flip did not show buffer A");
    dut.fb_retired ^= 1; tick(); tick();
    for (int i = 0; i < 3 && dut.cmd_valid; ++i) {
        if (dut.cmd_ready) { tick(); dut.cmd_valid = 0; }
        else tick();
    }
    tick();
    if (dut.cmd_valid || accepts != 4 || dut.present_busy || dut.front_idx != 0)
        return Fail("flip barrier did not complete without flipping");

    // Out-of-range indices are consumed without starting a flip.
    Command(dut, 11, 4); Offer(dut); tick(); dut.cmd_valid = 0; tick();
    if (dut.present_busy || accepts != 4) return Fail("invalid queued buffer index started a flip");

    // Legacy PRESENT from buffer C shows B, holds CMDQ until retirement and
    // completes through done; the next one returns to A.
    Command(dut, 11, 2); Offer(dut); tick(); dut.cmd_valid = 0; tick();
    Vblank(dut);
    dut.fb_retired ^= 1; tick(); tick();
    if (dut.front_idx != 2 || dut.present_busy || accepts != 5)
        return Fail("queued flip back to C failed");
    const uint8_t legacy_expected[] = {1, 0};
    for (uint8_t expected : legacy_expected) {
        Command(dut, 4, 0); Offer(dut); tick(); dut.cmd_valid = 0;
        if (!dut.present_start) return Fail("legacy PRESENT did not start");
        tick();
        if (dut.cmd_ready) return Fail("legacy PRESENT did not hold CMDQ");
        Vblank(dut);
        if (dut.front_idx != expected) return Fail("legacy PRESENT showed the wrong buffer");
        const int before = dones;
        dut.fb_retired ^= 1; tick(); tick();
        if (dones != before + 1) return Fail("legacy PRESENT did not pulse done");
        for (int i = 0; i < 3 && !dut.cmd_ready; ++i) tick();
        if (!dut.cmd_ready) return Fail("legacy PRESENT did not release CMDQ");
    }
    if (accepts != 5) return Fail("legacy PRESENT pulsed the queued acceptance");
    return 0;
}

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vcmdq_batch_dut dut;
    dut.fb_vbl = 0; dut.fb_retired = 0;
    dut.reset = 1; dut.cmd_valid = 0; dut.batch_busy = 0; dut.batch_done = 0;
    dut.fill_batch_busy = 0; dut.fill_batch_done = 0;
    dut.blend_busy = 0; dut.blend_done = 0;
    for (int i = 0; i < 3; ++i) { dut.clk = 0; dut.eval(); dut.clk = 1; dut.eval(); }
    dut.reset = 0;
    dut.cmd_data[0] = 5; dut.cmd_data[1] = 0x3002a000; dut.cmd_data[3] = 64;
    dut.cmd_valid = 1;
    if (!dut.cmd_ready) return std::fprintf(stderr, "FAIL: batch cmd not ready\n"), 1;
    dut.clk = 0; dut.eval(); dut.clk = 1; dut.eval(); dut.cmd_valid = 0;
    if (!dut.batch_start || dut.batch_base != 0x3002a000 || dut.batch_count != 64)
        return std::fprintf(stderr, "FAIL: batch decode start/base/count\n"), 1;
    dut.batch_done = 1; dut.clk = 0; dut.eval(); dut.clk = 1; dut.eval();
    dut.batch_done = 0;
    if (!dut.cmd_ready) return std::fprintf(stderr, "FAIL: batch controller did not retire\n"), 1;

    // Misaligned and out-of-pool bases are consumed as invalid raw commands
    // without launching the batch engine.
    const uint32_t invalid_bases[] = {0x30022004, 0x30021800, 0x30042000};
    for (uint32_t base : invalid_bases) {
        for (int i = 0; i < 8; ++i) dut.cmd_data[i] = 0;
        dut.cmd_data[0] = 5; dut.cmd_data[1] = base; dut.cmd_data[3] = 1;
        dut.cmd_valid = 1;
        dut.clk = 0; dut.eval(); dut.clk = 1; dut.eval(); dut.cmd_valid = 0;
        if (dut.batch_start)
            return std::fprintf(stderr, "FAIL: invalid batch base 0x%08x launched\n", base), 1;
    }

    // FILL_BATCH uses the same aligned, bounded descriptor tables while
    // dispatching through its own capability-gated opcode.
    for (int i = 0; i < 8; ++i) dut.cmd_data[i] = 0;
    dut.cmd_data[0] = 10; dut.cmd_data[1] = 0x3003f800; dut.cmd_data[3] = 37;
    dut.cmd_valid = 1;
    dut.clk = 0; dut.eval(); dut.clk = 1; dut.eval(); dut.cmd_valid = 0;
    if (!dut.fill_batch_start || dut.fill_batch_base != 0x3003f800 ||
        dut.fill_batch_count != 37 || dut.batch_start)
        return std::fprintf(stderr, "FAIL: fill-batch decode start/base/count\n"), 1;
    dut.fill_batch_done = 1; dut.clk = 0; dut.eval(); dut.clk = 1; dut.eval();
    dut.fill_batch_done = 0;
    if (!dut.cmd_ready)
        return std::fprintf(stderr, "FAIL: fill-batch controller did not retire\n"), 1;
    for (uint32_t base : invalid_bases) {
        for (int i = 0; i < 8; ++i) dut.cmd_data[i] = 0;
        dut.cmd_data[0] = 10; dut.cmd_data[1] = base; dut.cmd_data[3] = 1;
        dut.cmd_valid = 1;
        dut.clk = 0; dut.eval(); dut.clk = 1; dut.eval(); dut.cmd_valid = 0;
        if (dut.fill_batch_start)
            return std::fprintf(stderr, "FAIL: invalid fill-batch base 0x%08x launched\n", base), 1;
    }

    // BLIT_BLEND (BLIT-007): copy geometry plus word 5 [7:0] modulation.
    for (int i = 0; i < 8; ++i) dut.cmd_data[i] = 0;
    dut.cmd_data[0] = 7; dut.cmd_data[1] = 0x31000010; dut.cmd_data[2] = 3200;
    dut.cmd_data[3] = 33; dut.cmd_data[4] = 17; dut.cmd_data[5] = 0x9c;
    dut.cmd_data[6] = 0x32000008; dut.cmd_data[7] = 256;
    dut.blend_busy = 0; dut.blend_done = 0; dut.cmd_valid = 1;
    dut.clk = 0; dut.eval(); dut.clk = 1; dut.eval(); dut.cmd_valid = 0;
    if (!dut.blend_start || dut.blend_mod != 0x9c || dut.copy_dst_addr != 0x31000010 ||
        dut.copy_src_addr != 0x32000008 || dut.copy_width != 33 || dut.copy_height != 17 ||
        dut.batch_start)
        return std::fprintf(stderr, "FAIL: blend decode\n"), 1;
    dut.blend_busy = 1; dut.clk = 0; dut.eval(); dut.clk = 1; dut.eval();
    if (dut.cmd_ready || dut.blend_start)
        return std::fprintf(stderr, "FAIL: blend did not hold the queue\n"), 1;
    dut.blend_busy = 0; dut.blend_done = 1; dut.clk = 0; dut.eval(); dut.clk = 1; dut.eval();
    dut.blend_done = 0;
    if (!dut.cmd_ready) return std::fprintf(stderr, "FAIL: blend did not retire\n"), 1;

    // BLEND_FILL (BLIT-010): destination geometry, constant source colour
    // and explicit mode flags in word 6.
    for (int i = 0; i < 8; ++i) dut.cmd_data[i] = 0;
    dut.cmd_data[0] = 8; dut.cmd_data[1] = 0x31200020; dut.cmd_data[2] = 3200;
    dut.cmd_data[3] = 19; dut.cmd_data[4] = 23; dut.cmd_data[5] = 0x80402010;
    dut.cmd_data[6] = 0x6c5a3c10;
    dut.cmd_valid = 1;
    dut.clk = 0; dut.eval(); dut.clk = 1; dut.eval(); dut.cmd_valid = 0;
    if (!dut.blend_start || dut.blend_mod != 0xff || !dut.blend_solid || !dut.blend_mode_en ||
        dut.blend_solid_color != 0x80402010 || dut.blend_mode != 0x6c5a3c ||
        dut.copy_dst_addr != 0x31200020 || dut.copy_width != 19 || dut.copy_height != 23)
        return std::fprintf(stderr, "FAIL: blend-fill decode\n"), 1;
    dut.blend_done = 1; dut.clk = 0; dut.eval(); dut.clk = 1; dut.eval();
    dut.blend_done = 0;
    if (!dut.cmd_ready) return std::fprintf(stderr, "FAIL: blend-fill did not retire\n"), 1;
    if (TestPresent(dut)) return 1;
    std::puts("PASS: CMDQ SPRITE_BATCH, FILL_BATCH, BLIT_BLEND, BLEND_FILL and PRESENT decode, wait, and retirement");
    dut.final();
    return 0;
}
