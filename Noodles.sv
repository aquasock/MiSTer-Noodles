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
// not the finished engine, and deliberately stops short of ever firing a
// BLIT-driven write on real hardware: cmd_valid is tied to 0 (no trigger
// exists yet), so CMDQ/BLIT can never assert DDRAM_WE no matter what is
// flashed to the board.
//
// That is intentional, not an oversight. BLIT-002's dst_addr is whatever the
// command says, and this project had not confirmed what DDR3 address range
// is actually safe to write given Linux owns most of that physical memory.
// It has now: SURF-003, read straight from MiSTer-devel/Main_MiSTer's own
// source, confirms physical [0x20000000,0x40000000) is FPGA-reserved, with
// the first 32MB of it (0x20000000-0x21FFFFFF) explicitly a core's own to
// use ("Core's fb" in video.cpp). What is NOT yet confirmed is DDR-002:
// whether DDRAM_ADDR=0 (the FPGA-side address) really corresponds to that
// physical 0x20000000, or something else -- inferred from Main's fpga_mem()
// macro, but not verified against our own RTL. ddram_marker_test below
// exists to check exactly that, in isolation: pressing the OSD's single
// "Marker Test" button writes one fixed word to DDRAM_ADDR=0, once, and
// nothing else. tools/ddram_marker_check.c reads Linux physical 0x20000000
// back and reports whether it matches. Until that check has actually been
// run and passed, treat DDR-002 as unverified -- FB_EN stays 0 and nothing
// beyond this one marker word should be trusted to land where intended.
// See OUT-001, SURF-001/SURF-002/SURF-003 and DDR-001/DDR-002.

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

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

// MISTER_FB is enabled at the project level (Noodles.qsf) for the eventual
// SURF/OUT scan-out path, but it is not driven yet -- disabled and blanked.
assign FB_EN = 0;
assign FB_FORMAT = 0;
assign FB_WIDTH = 0;
assign FB_HEIGHT = 0;
assign FB_BASE = 0;
assign FB_STRIDE = 0;
assign FB_FORCE_BLANK = 1;

///////////////////////   ENGINE   /////////////////////////////////

// cmd_valid tied to 0 means CMDQ never leaves IDLE, so BLIT can never
// assert wr_en -- no trigger exists for it yet. See the file header.
wire        engine_cmd_ready;
wire [31:0] engine_wr_addr, engine_wr_data;
wire        engine_wr_en, engine_wr_ready;
wire        blit_start, blit_busy, blit_done;
wire [31:0] blit_dst_addr, blit_color;
wire [15:0] blit_dst_pitch, blit_width, blit_height;

cmdq cmdq
(
	.clk           (clk_sys),
	.reset         (reset),
	.cmd_valid     (1'b0),
	.cmd_data      (256'd0),
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
// fixed word to DDRAM_ADDR=0 per press and stops. See the file header and
// DDR-002.
wire        marker_busy, marker_done;
wire [31:0] marker_wr_addr, marker_wr_data;
wire        marker_wr_en, marker_wr_ready;

ddram_marker_test marker_test
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
assign CE_PIXEL = 0;

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
