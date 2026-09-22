//============================================================================
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================
//
// MiSTer-Noodles top-level glue between the sys/ framework and the core.
//
// CMDQ, BLIT and the DDRAM write adapter (DDR-001) are wired for real below
// and drive the actual DDRAM_* pins. This is still a bring-up checkpoint,
// not the finished engine -- CMDQ's only command source is one hardcoded,
// OSD-triggered test command (CMDQ-002), not LINK's ring buffer.
//
// Every address used below is deliberately inside SURF-003's confirmed-safe
// window (physical [0x20000000,0x40000000), FPGA-reserved DDR3, read
// straight from MiSTer-devel/Main_MiSTer's own source) AND avoids
// 0x20000000 itself per SURF-004: MiSTer's own system video scaler uses
// that exact physical address as its RAM base, a real collision the
// MiSTer-Raster project hit and fixed on this same platform. Every address
// here is 0x30000000+, the region that project's own hardware-accepted
// releases have used safely since. Nothing here should ever target an
// address outside that without a new record explaining why it's safe.
//
// DDR-002 was checked on real hardware and, after an initial wrong guess
// (DDRAM_ADDR=0 landed at physical 0x0, not 0x20000000 -- see the marker
// test's own history and CMDQ/DDR-002 records), confirmed DDRAM_ADDR is an
// unwindowed, direct physical word address (word N = byte N*8 in the same
// address space as everything else). SURF-004 then found 0x20000000 itself
// unsafe for a different reason (see above), so ddram_marker_test's
// address moved again, to 0x30000000/8 = word 0x06000000.
//
// A real command now flows end to end: the "Draw Test" OSD button fires
// one hardcoded SOLID_FILL through CMDQ (CMDQ-002), filling a 64x64 32bpp
// surface at 0x30000000 with a fixed color, and
// FB_EN/FB_BASE/FB_STRIDE/FB_WIDTH/FB_HEIGHT/FB_FORMAT scan that surface
// out over HDMI via MISTER_FB -- gated behind a "draw ever completed" latch
// so nothing is displayed (FB_EN stays 0) until that button has actually
// been pressed once, rather than showing whatever was in memory at boot.
// A second button, "Blit Copy Test", fires a hardcoded BLIT_COPY (BLIT-003)
// copying an 8x8 rect from an arbitrary safe address into the visible
// surface's corner -- the source is never pre-filled by anything, so its
// content is whatever happened to already be in that DDR3, not a chosen
// color; the point is proving the real read+write path on hardware, not a
// pretty picture.
//
// LINK-001's ring buffer (rtl/link_ring.sv, LINK-002/LINK-003) is now wired
// in too: tools/link_push.c is a real ARM host process pushing a SOLID_FILL
// (cyan, distinct from the OSD "Draw Test" button's magenta) directly into
// shared DDR3, no OSD involved. All three command sources -- draw_test,
// copy_test, and link_ring -- feed the same single CMDQ instance through a
// small priority mux, since CMDQ only accepts one command at a time anyway;
// the OSD buttons stay in place as a known-good fallback during LINK's own
// bring-up, per the plan recorded in core-log.md, not because they're
// meant to coexist with LINK long-term.
// See OUT-001/OUT-002, SURF-001/SURF-002/SURF-003/SURF-004, BLIT-002/BLIT-003,
// LINK-001/LINK-002/LINK-003 and DDR-001/DDR-002/DDR-003/DDR-004.

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 0;
assign AUDIO_L = 0;
assign AUDIO_R = 0;
assign AUDIO_MIX = 0;

// LED_DISK: diagnostic for the read-mux bug fixed in link_ring.sv/rd_active
// (see the comment there and the write-port mux comment below for the full
// story). Latches solid if blit_start EVER fires with blit_dst_addr not
// equal to the one address every hardware test so far has used
// (0x30000000) -- i.e. "the bug is still happening". Should stay OFF now.
reg dst_addr_wrong_ever;
always @(posedge clk_sys or posedge reset)
	if (reset) dst_addr_wrong_ever <= 1'b0;
	else if (blit_start && blit_dst_addr != 32'h3000_0000) dst_addr_wrong_ever <= 1'b1;

assign LED_DISK = dst_addr_wrong_ever;

// LED_POWER is otherwise unused -- diagnostic for LINK-001's first
// hardware test: latches solid once link_ring has actually dispatched a
// command to CMDQ (not just fetched it), independent of what happens
// downstream. If this never lights after link-push, the bug is inside
// link_ring itself (init, polling, or fetch); if it lights but nothing
// visible changes, the bug is downstream in CMDQ/BLIT/the write path for
// this specific mux integration. bit[1]=1 takes full manual control of the
// LED instead of leaving it OR'd with system status (emu_ports.vh).
reg link_dispatch_ever;
always @(posedge clk_sys or posedge reset)
	if (reset) link_dispatch_ever <= 1'b0;
	else if (link_cmd_valid && link_cmd_ready) link_dispatch_ever <= 1'b1;

assign LED_POWER = {1'b1, link_dispatch_ever};
assign BUTTONS = 0;

// draw_done_ever gates FB_EN so nothing is displayed until a fill has
// actually completed once -- otherwise the screen would show whatever
// happened to be in memory at boot. Keyed on blit_done (BLIT's own
// completion), not draw_test's trigger-specific done, so a link_ring- or
// blit_copy-driven fill also unblanks the display -- gating on the OSD
// button's own done specifically would mean a link-only session (never
// pressing "Draw Test") could never show anything even if everything else
// worked.
reg draw_done_ever;
always @(posedge clk_sys or posedge reset)
	if (reset) draw_done_ever <= 1'b0;
	else if (blit_done) draw_done_ever <= 1'b1;

// Diagnostic for LINK-001's continued bring-up: LED_POWER already confirmed
// CMDQ accepted a link_ring-dispatched command (link_cmd_valid&&link_cmd_ready),
// but the surface never actually changed (still reads back the OLD magenta
// at 0x30000000 after a link-push, per hardware readback). CMDQ silently
// drops any command whose opcode it doesn't recognize -- "accepted" isn't
// the same as "recognized and started BLIT". Repurposes LED_USER's
// heartbeat blink (not currently needed -- everything else already proves
// the clock runs) to latch solid the first time blit_start fires for ANY
// reason, so we can tell whether CMDQ's opcode decode ever actually saw a
// valid SOLID_FILL from link_ring's reconstructed command data.
reg blit_start_ever;
always @(posedge clk_sys or posedge reset)
	if (reset) blit_start_ever <= 1'b0;
	else if (blit_start) blit_start_ever <= 1'b1;

// MISTER_FB scan-out (OUT-002): a fixed 64x64, 32bpp (FB_FORMAT[2:0]=3'b110)
// surface at 0x30000000 -- NOT 0x20000000, see SURF-004: MiSTer's own
// system video scaler uses physical byte 0x20000000 as its RAM base, a real
// collision hit and fixed by the MiSTer-Raster project on this exact
// platform. 0x30000000 is the address that project has used safely across
// many hardware-accepted releases since.
assign FB_EN = draw_done_ever;
assign FB_FORMAT = {2'b00, 3'b110};
assign FB_WIDTH = 12'd64;
assign FB_HEIGHT = 12'd64;
assign FB_BASE = 32'h3000_0000;
assign FB_STRIDE = 14'd256;
assign FB_FORCE_BLANK = ~draw_done_ever;

///////////////////////   ENGINE   /////////////////////////////////

// CMDQ-002: the "Draw Test" OSD button fires this one hardcoded SOLID_FILL
// command through CMDQ -- stands in for LINK's not-yet-built ring buffer.
// opcode=1 (SOLID_FILL), dst_addr=0x30000000 (SURF-004), dst_pitch=256
// (64px*4B), width=64, height=64, color=0x00FF00FF (magenta). Field order
// matches CMDQ-001's slot layout; must stay identical to
// sim/cmd_trigger_dut.sv's default, which is what `make sim` actually
// verifies.
localparam logic [255:0] DRAW_TEST_COMMAND = {
	32'd0, 32'd0, 32'h00FF00FF, 32'd64, 32'd64, 32'd256, 32'h30000000, 32'd1
};

// CMDQ-002/BLIT-003: "Blit Copy Test" -- opcode=2 (BLIT_COPY), copies an 8x8
// rect from 0x30010000 (arbitrary safe address, content whatever it already
// is) into the visible surface's top-left corner. Must stay identical to
// sim/cmd_copy_trigger_dut.sv's default, which is what `make sim` verifies.
localparam logic [255:0] BLIT_COPY_TEST_COMMAND = {
	32'd32, 32'h3001_0000, 32'd0, 32'd8, 32'd8, 32'd256, 32'h3000_0000, 32'd2
};

wire        engine_cmd_ready;
wire [31:0] engine_wr_addr, engine_wr_data;
wire        engine_wr_en, engine_wr_ready;
wire        blit_start, blit_busy, blit_done;
wire [31:0] blit_dst_addr, blit_color;
wire [15:0] blit_dst_pitch, blit_width, blit_height;
wire        draw_trigger_busy, draw_done;
wire [255:0] draw_cmd_data;
wire         draw_cmd_valid, draw_cmd_ready;

wire        copy_start, copy_busy, copy_done;
wire [31:0] copy_dst_addr, copy_src_addr;
wire [15:0] copy_dst_pitch, copy_src_pitch, copy_width, copy_height;
wire        copytest_busy, copytest_done;
wire [255:0] copytest_cmd_data;
wire         copytest_cmd_valid, copytest_cmd_ready;
wire [31:0] copy_wr_addr, copy_wr_data, copy_rd_addr, copy_rd_data;
wire        copy_wr_en, copy_wr_ready, copy_rd_en, copy_rd_ready, copy_rd_valid;

cmd_test_trigger #(
	.COMMAND(DRAW_TEST_COMMAND)
) draw_test
(
	.clk      (clk_sys),
	.reset    (reset),
	.trigger  (status[2]),
	.busy     (draw_trigger_busy),
	.done     (draw_done),
	.cmd_data (draw_cmd_data),
	.cmd_valid(draw_cmd_valid),
	.cmd_ready(draw_cmd_ready)
);

cmd_test_trigger #(
	.COMMAND(BLIT_COPY_TEST_COMMAND)
) copy_test
(
	.clk      (clk_sys),
	.reset    (reset),
	.trigger  (status[3]),
	.busy     (copytest_busy),
	.done     (copytest_done),
	.cmd_data (copytest_cmd_data),
	.cmd_valid(copytest_cmd_valid),
	.cmd_ready(copytest_cmd_ready)
);

// LINK-001/LINK-002/LINK-003: the real host-driven command path.
// tools/link_push.c writes commands and write_ptr directly into shared
// DDR3; link_ring polls and fetches them here. Only polls/fetches while
// CMDQ is idle (cmd_ready), which is what keeps its reads from ever
// contending with blit_copy's (DDR-003's single-outstanding assumption).
wire         link_cmd_valid, link_cmd_ready;
wire [255:0] link_cmd_data;
wire [31:0]  link_wr_addr, link_wr_data, link_rd_addr, link_rd_data;
wire         link_wr_en, link_wr_ready, link_rd_en, link_rd_active, link_rd_ready, link_rd_valid;

link_ring link_ring
(
	.clk      (clk_sys),
	.reset    (reset),
	.rd_addr  (link_rd_addr),
	.rd_en    (link_rd_en),
	.rd_active(link_rd_active),
	.rd_ready (link_rd_ready),
	.rd_data  (link_rd_data),
	.rd_valid (link_rd_valid),
	.wr_addr  (link_wr_addr),
	.wr_data  (link_wr_data),
	.wr_en    (link_wr_en),
	.wr_ready (link_wr_ready),
	.cmd_data (link_cmd_data),
	.cmd_valid(link_cmd_valid),
	.cmd_ready(link_cmd_ready)
);

// LINK-005: completion fence. blit_done/copy_done fire once per command
// that ACTUALLY finished executing (link_ring's own read_ptr only tracks
// dispatch acceptance -- see LINK-003/LINK-005), ORed here since either one
// completing a command means "one more command is done" from the host's
// point of view; CMDQ never runs both at once. link_fence has no idea which
// engine ran or what command it was -- it is a pure counter, deliberately
// dumber than link_ring, so it never needs touching if link_ring's own FSM
// changes again.
wire cmd_done_pulse = blit_done || copy_done;

wire [31:0] fence_wr_addr, fence_wr_data;
wire        fence_wr_en, fence_wr_ready;

link_fence link_fence
(
	.clk       (clk_sys),
	.reset     (reset),
	.done_pulse(cmd_done_pulse),
	.wr_addr   (fence_wr_addr),
	.wr_data   (fence_wr_data),
	.wr_en     (fence_wr_en),
	.wr_ready  (fence_wr_ready)
);

// Priority mux feeding CMDQ's single command front end. The OSD buttons
// stay ahead of link_ring in priority purely so a deliberate button press
// during bring-up is never starved by a busy ring -- arbitrary otherwise,
// since a human pressing a button and a host process pushing to the ring
// are never expected to race in practice.
wire        cmd_sel_draw = draw_cmd_valid;
wire        cmd_sel_copytest = !cmd_sel_draw && copytest_cmd_valid;
wire [255:0] engine_cmd_data  = cmd_sel_draw ? draw_cmd_data  : cmd_sel_copytest ? copytest_cmd_data  : link_cmd_data;
wire         engine_cmd_valid = cmd_sel_draw ? draw_cmd_valid : cmd_sel_copytest ? copytest_cmd_valid : link_cmd_valid;
assign draw_cmd_ready     = cmd_sel_draw     ? engine_cmd_ready : 1'b0;
assign copytest_cmd_ready = cmd_sel_copytest ? engine_cmd_ready : 1'b0;
assign link_cmd_ready     = (cmd_sel_draw || cmd_sel_copytest) ? 1'b0 : engine_cmd_ready;

cmdq cmdq
(
	.clk           (clk_sys),
	.reset         (reset),
	.cmd_valid     (engine_cmd_valid),
	.cmd_data      (engine_cmd_data),
	.cmd_ready     (engine_cmd_ready),
	.blit_start    (blit_start),
	.blit_dst_addr (blit_dst_addr),
	.blit_dst_pitch(blit_dst_pitch),
	.blit_width    (blit_width),
	.blit_height   (blit_height),
	.blit_color    (blit_color),
	.blit_busy     (blit_busy),
	.blit_done     (blit_done),
	.copy_start    (copy_start),
	.copy_dst_addr (copy_dst_addr),
	.copy_dst_pitch(copy_dst_pitch),
	.copy_src_addr (copy_src_addr),
	.copy_src_pitch(copy_src_pitch),
	.copy_width    (copy_width),
	.copy_height   (copy_height),
	.copy_busy     (copy_busy),
	.copy_done     (copy_done)
);

blit blit
(
	.clk      (clk_sys),
	.reset    (reset),
	.start    (blit_start),
	.dst_addr (blit_dst_addr),
	.dst_pitch(blit_dst_pitch),
	.width    (blit_width),
	.height   (blit_height),
	.color    (blit_color),
	.busy     (blit_busy),
	.done     (blit_done),
	.wr_addr  (engine_wr_addr),
	.wr_data  (engine_wr_data),
	.wr_en    (engine_wr_en),
	.wr_ready (engine_wr_ready)
);

blit_copy blit_copy
(
	.clk      (clk_sys),
	.reset    (reset),
	.start    (copy_start),
	.dst_addr (copy_dst_addr),
	.dst_pitch(copy_dst_pitch),
	.src_addr (copy_src_addr),
	.src_pitch(copy_src_pitch),
	.width    (copy_width),
	.height   (copy_height),
	.busy     (copy_busy),
	.done     (copy_done),
	.rd_addr  (copy_rd_addr),
	.rd_en    (copy_rd_en),
	.rd_ready (copy_rd_ready),
	.rd_data  (copy_rd_data),
	.rd_valid (copy_rd_valid),
	.wr_addr  (copy_wr_addr),
	.wr_data  (copy_wr_data),
	.wr_en    (copy_wr_en),
	.wr_ready (copy_wr_ready)
);

// Deliberately, individually triggered by one OSD button -- writes ONE
// fixed word to physical 0x30000000 per press and stops. See the file
// header, DDR-002 and SURF-004.
//
// MARKER_ADDR history: originally 0, which DDR-002's first hardware test
// showed lands at physical 0x00000000 (DDRAM_ADDR is an unwindowed, direct
// physical word address, not offset from any window). Moved to
// 0x20000000, which DDR-002 then confirmed correctly -- but SURF-004 later
// found 0x20000000 itself collides with MiSTer's own system video scaler.
// Now 0x30000000, the address MiSTer-Raster's own hardware-validated fix
// uses for exactly this reason.
wire        marker_busy, marker_done;
wire [31:0] marker_wr_addr, marker_wr_data;
wire        marker_wr_en, marker_wr_ready;

ddram_marker_test #(
	.MARKER_ADDR(32'h3000_0000)
) marker_test
(
	.clk     (clk_sys),
	.reset   (reset),
	.trigger (status[1]),
	.busy    (marker_busy),
	.done    (marker_done),
	.wr_addr (marker_wr_addr),
	.wr_data (marker_wr_data),
	.wr_en   (marker_wr_en),
	.wr_ready(marker_wr_ready)
);

// 5-way priority mux into the DDRAM adapter's write port: marker_test,
// blit's fill writes, blit_copy's copy writes, link_ring's writes (INIT +
// read_ptr writeback), link_fence's writes (INIT + completion-count
// publish). None can ever be simultaneously active by construction of
// CMDQ's own single-engine dispatch (blit and blit_copy), marker_test's
// independent OSD trigger, and link_ring only writing while idle/finishing
// a dispatch, so this priority is a tie-breaker, not load-bearing
// arbitration -- same caveat as DDR-003's read/write mux. link_fence sits
// lowest: its writes are never time-critical (the host only needs the
// count to arrive eventually, not within any particular cycle), and by the
// time it wants to write, the engine that just triggered it (blit/blit_copy)
// has already stopped writing.
wire        wr_sel_marker = marker_wr_en;
wire        wr_sel_copy   = !wr_sel_marker && copy_wr_en;
wire        wr_sel_link   = !wr_sel_marker && !wr_sel_copy && link_wr_en;
wire        wr_sel_engine = !wr_sel_marker && !wr_sel_copy && !wr_sel_link && engine_wr_en;
wire        wr_sel_fence  = !wr_sel_marker && !wr_sel_copy && !wr_sel_link && !wr_sel_engine && fence_wr_en;
wire [31:0] adapter_wr_addr = wr_sel_marker ? marker_wr_addr : wr_sel_copy ? copy_wr_addr : wr_sel_link ? link_wr_addr : wr_sel_engine ? engine_wr_addr : fence_wr_addr;
wire [31:0] adapter_wr_data = wr_sel_marker ? marker_wr_data : wr_sel_copy ? copy_wr_data : wr_sel_link ? link_wr_data : wr_sel_engine ? engine_wr_data : fence_wr_data;
wire        adapter_wr_en   = wr_sel_marker ? marker_wr_en   : wr_sel_copy ? copy_wr_en   : wr_sel_link ? link_wr_en   : wr_sel_engine ? engine_wr_en   : fence_wr_en;
wire        adapter_wr_ready;
assign marker_wr_ready = wr_sel_marker ? adapter_wr_ready : 1'b0;
assign copy_wr_ready   = wr_sel_copy   ? adapter_wr_ready : 1'b0;
assign link_wr_ready   = wr_sel_link   ? adapter_wr_ready : 1'b0;
assign engine_wr_ready = wr_sel_engine ? adapter_wr_ready : 1'b0;
assign fence_wr_ready  = wr_sel_fence  ? adapter_wr_ready : 1'b0;

// 2-way priority mux into the DDRAM adapter's read port: blit_copy and
// link_ring. LINK-003's cmd_ready gating keeps these from ever actually
// contending (see DDR-003's consequence) -- response data/valid are simply
// broadcast to both, since only whichever one is actually mid-request will
// be in a state that reacts to it.
//
// Selector is link_rd_active (spans link_ring's *_REQ/*_WAIT pair), NOT
// link_rd_en (high only during *_REQ) -- using rd_en here was a real bug
// (found on real hardware): once link_ring moved from FETCH_REQ into
// FETCH_WAIT to await a response, rd_en dropped, so this mux fell through
// to copy_rd_addr (idle at 0) for the rest of the wait -- meaning by the
// time rd_valid actually arrived, ddram_adapter's byte-half-select used
// blit_copy's idle address's bit[2] instead of link's own pinned request
// address, silently handing link_ring the WRONG half of the 64-bit DDRAM
// word it had actually asked for.
wire        rd_sel_link = link_rd_active;
wire [31:0] adapter_rd_addr = rd_sel_link ? link_rd_addr : copy_rd_addr;
wire        adapter_rd_en   = rd_sel_link ? link_rd_en   : copy_rd_en;
wire        adapter_rd_ready, adapter_rd_valid;
wire [31:0] adapter_rd_data;
assign link_rd_ready = rd_sel_link ? adapter_rd_ready : 1'b0;
assign copy_rd_ready = rd_sel_link ? 1'b0 : adapter_rd_ready;
assign link_rd_data  = adapter_rd_data;
assign link_rd_valid = adapter_rd_valid;
assign copy_rd_data  = adapter_rd_data;
assign copy_rd_valid = adapter_rd_valid;

ddram_adapter ddram_adapter
(
	.clk             (clk_sys),
	.wr_addr         (adapter_wr_addr),
	.wr_data         (adapter_wr_data),
	.wr_en           (adapter_wr_en),
	.wr_ready        (adapter_wr_ready),
	.rd_addr         (adapter_rd_addr),
	.rd_en           (adapter_rd_en),
	.rd_ready        (adapter_rd_ready),
	.rd_data         (adapter_rd_data),
	.rd_valid        (adapter_rd_valid),
	.ddram_clk       (DDRAM_CLK),
	.ddram_busy      (DDRAM_BUSY),
	.ddram_burstcnt  (DDRAM_BURSTCNT),
	.ddram_addr      (DDRAM_ADDR),
	.ddram_dout      (DDRAM_DOUT),
	.ddram_dout_ready(DDRAM_DOUT_READY),
	.ddram_din       (DDRAM_DIN),
	.ddram_be        (DDRAM_BE),
	.ddram_we        (DDRAM_WE),
	.ddram_rd        (DDRAM_RD)
);

//////////////////////////////////////////////////////////////////

assign VIDEO_ARX = 12'd4;
assign VIDEO_ARY = 12'd3;

`include "build_id.v"
localparam CONF_STR = {
	"Noodles;;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"-;",
	"T[1],Marker Test -- writes ONE word to phys 0x30000000!;",
	"T[2],Draw Test -- fills a 64x64 test surface via CMDQ/BLIT;",
	"T[3],Blit Copy Test -- copies 8x8 into the surface via CMDQ/BLIT_COPY;",
	"v,0;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),

	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys)
);

wire reset = RESET | status[0] | buttons[1];

assign CLK_VIDEO = clk_sys;

// A permanently-0 CE_PIXEL was never correct -- the framework's OSD
// compositing/mixer chain (sys/sys_top.v, sys/video_mixer.sv) uses it
// regardless of whether the picture comes from MISTER_FB or a core's own
// raster output; ascal generates its own independent output timing for the
// FB path, but the downstream mixer still needs a real toggling enable.
// Exact rate is not yet tuned to any specific video mode -- a modest
// divide-by-4 of clk_sys, the same shape virtually every MiSTer core uses.
reg [1:0] ce_div;
always @(posedge clk_sys) ce_div <= ce_div + 2'd1;
assign CE_PIXEL = (ce_div == 2'd0);

assign VGA_DE = 0;
assign VGA_HS = 0;
assign VGA_VS = 0;
assign VGA_R  = 8'd0;
assign VGA_G  = 8'd0;
assign VGA_B  = 8'd0;

// LED_USER's heartbeat blink is temporarily replaced by blit_start_ever --
// see the comment where that register is declared. Every other LED and the
// HDMI output already prove the clock is alive, so the heartbeat itself
// isn't currently informative.
assign LED_USER = blit_start_ever;

endmodule
