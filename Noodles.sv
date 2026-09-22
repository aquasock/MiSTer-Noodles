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
// write on real hardware: cmd_valid is tied to 0 (no trigger exists yet),
// so DDRAM_WE can never assert no matter what is flashed to the board.
//
// That is intentional, not an oversight. BLIT-002's dst_addr is whatever the
// command says -- nothing in this core yet validates it against what's
// actually safe to write in the HPS's shared DDR3 (Linux owns most of that
// physical memory; MiSTer's own framebuffer/loader conventions reserve some
// of it, per docs/mister-framebuffer.md's FB_ADDR research, but this project
// has not confirmed the safe region for our own use). Until that's nailed
// down, wiring a live trigger (an OSD button, LINK's future ring buffer)
// would let a build actually stomp on running Linux memory the moment
// someone presses it. FB_EN stays 0 for the same reason: nothing is being
// displayed, so there's no reason to point FB_BASE at a guessed address
// either. See OUT-001, SURF-001/SURF-002 and DDR-001 for what is decided.

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

// No trigger exists yet -- see the file header. This block is wired to the
// real DDRAM_* pins and will place/route/time as part of a real build, but
// cmd_valid tied to 0 means CMDQ never leaves IDLE and DDRAM_WE never
// asserts.
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

ddram_write_adapter ddram_write_adapter
(
	.clk           (clk_sys),
	.wr_addr       (engine_wr_addr),
	.wr_data       (engine_wr_data),
	.wr_en         (engine_wr_en),
	.wr_ready      (engine_wr_ready),
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
