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
// This is still a hardcoded, single test command, not LINK's ring buffer --
// see LINK-001's still-open consequence and CMDQ-002.
// See OUT-001/OUT-002, SURF-001/SURF-002/SURF-003/SURF-004 and DDR-001/DDR-002.

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

// LED_DISK is otherwise unused -- diagnostic left in place from DDR-002's
// bring-up: latches solid on once the marker write has actually completed
// on the DDRAM_* bus (not just been requested), independent of where it
// landed. Still useful for future low-level DDRAM_* debugging.
reg marker_done_ever;
always @(posedge clk_sys or posedge reset)
	if (reset) marker_done_ever <= 1'b0;
	else if (marker_done) marker_done_ever <= 1'b1;

assign LED_DISK = marker_done_ever;
assign LED_POWER = 0;
assign BUTTONS = 0;

// draw_done_ever gates FB_EN so nothing is displayed until "Draw Test" has
// actually completed once -- otherwise the screen would show whatever
// happened to be in memory at 0x20000000 at boot (possibly still
// marker_test's stray value from DDR-002's bring-up).
reg draw_done_ever;
always @(posedge clk_sys or posedge reset)
	if (reset) draw_done_ever <= 1'b0;
	else if (draw_done) draw_done_ever <= 1'b1;

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

wire        engine_cmd_ready;
wire [31:0] engine_wr_addr, engine_wr_data;
wire        engine_wr_en, engine_wr_ready;
wire        blit_start, blit_busy, blit_done;
wire [31:0] blit_dst_addr, blit_color;
wire [15:0] blit_dst_pitch, blit_width, blit_height;
wire        draw_trigger_busy, draw_done;
wire [255:0] draw_cmd_data;
wire         draw_cmd_valid;

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
	.cmd_ready(engine_cmd_ready)
);

cmdq cmdq
(
	.clk           (clk_sys),
	.reset         (reset),
	.cmd_valid     (draw_cmd_valid),
	.cmd_data      (draw_cmd_data),
	.cmd_ready     (engine_cmd_ready),
	.blit_start    (blit_start),
	.blit_dst_addr (blit_dst_addr),
	.blit_dst_pitch(blit_dst_pitch),
	.blit_width    (blit_width),
	.blit_height   (blit_height),
	.blit_color    (blit_color),
	.blit_busy     (blit_busy),
	.blit_done     (blit_done)
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

// Single-master mux into the DDRAM write adapter. BLIT can never assert
// wr_en (cmd_valid is tied to 0 above), so the marker test always has a
// clear path whenever it fires; this priority is arbitrary since the two
// sources are never simultaneously active.
wire        adapter_wr_addr_sel = marker_wr_en;
wire [31:0] adapter_wr_addr = adapter_wr_addr_sel ? marker_wr_addr : engine_wr_addr;
wire [31:0] adapter_wr_data = adapter_wr_addr_sel ? marker_wr_data : engine_wr_data;
wire        adapter_wr_en   = adapter_wr_addr_sel ? marker_wr_en   : engine_wr_en;
wire        adapter_wr_ready;
assign marker_wr_ready = adapter_wr_addr_sel ? adapter_wr_ready : 1'b0;
assign engine_wr_ready = adapter_wr_addr_sel ? 1'b0 : adapter_wr_ready;

ddram_write_adapter ddram_write_adapter
(
	.clk           (clk_sys),
	.wr_addr       (adapter_wr_addr),
	.wr_data       (adapter_wr_data),
	.wr_en         (adapter_wr_en),
	.wr_ready      (adapter_wr_ready),
	.ddram_clk     (DDRAM_CLK),
	.ddram_busy    (DDRAM_BUSY),
	.ddram_burstcnt(DDRAM_BURSTCNT),
	.ddram_addr    (DDRAM_ADDR),
	.ddram_din     (DDRAM_DIN),
	.ddram_be      (DDRAM_BE),
	.ddram_we      (DDRAM_WE),
	.ddram_rd      (DDRAM_RD)
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
	"T[1],Marker Test -- writes ONE word to phys 0x20000000!;",
	"T[2],Draw Test -- fills a 64x64 test surface via CMDQ/BLIT;",
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

reg  [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER    = act_cnt[26]  ? act_cnt[25:18]  > act_cnt[7:0]  : act_cnt[25:18]  <= act_cnt[7:0];

endmodule
