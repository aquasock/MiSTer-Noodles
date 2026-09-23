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
// CMDQ's sole command source is LINK-001's real host-driven ring buffer
// (rtl/link_ring.sv, LINK-002/LINK-003): a host process (lib/noodles_link.h,
// LINK-004) writes commands directly into shared DDR3 and link_ring polls,
// fetches, and dispatches them -- no OSD involved. CMDQ dispatches to BLIT
// (SOLID_FILL, BLIT-002), blit_copy (BLIT_COPY/BLIT_COPY_KEY, BLIT-003/
// BLIT-006), or present (PRESENT, OUT-004's double-buffer flip). BLIT/
// blit_copy drive the real DDRAM_* pins via ddram_adapter (DDR-001/DDR-003);
// present touches no DDRAM_* at all, it only flips which of two fixed
// surfaces FB_BASE points at, synced to the framework's vertical blank and
// completed when ascal acknowledges latching the new base. LINK-005's fence
// (rtl/link_fence.sv) publishes a done-count back to DRAM so the host can
// tell when a specific command -- a draw OR a present -- actually finished,
// not just got dispatched.
//
// This used to also carry three OSD test buttons (Marker Test, Draw Test,
// Blit Copy Test) that fed CMDQ hardcoded commands directly, as a
// known-good fallback while LINK's ring buffer was still being brought up
// and hardware-debugged (see DDR-002 through DDR-005's history in
// core-log.md). They were retired once LINK proved the real path correct
// end to end on real hardware, including completion signaling -- CMDQ's
// command front end and the write-port mux are back down to their real,
// permanent client lists (link_ring only for commands; blit/blit_copy/
// link_ring/link_fence for writes), not a bring-up-era multiplexed stand-in.
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
// See OUT-001/OUT-002/OUT-004/OUT-005, SURF-001/SURF-002/SURF-003/SURF-004,
// BLIT-002/BLIT-003/BLIT-006, LINK-001 through LINK-005, and DDR-001
// through DDR-005.

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

// OUT-004/SURF-005: the two double-buffer surfaces' fixed addresses,
// declared up front since both the LED_DISK regression check below and
// FB_BASE's own mux need them. See the MISTER_FB scan-out comment further
// down for the full sizing/placement rationale.
localparam logic [31:0] BUFFER_A_ADDR = 32'h3100_0000;
localparam logic [31:0] BUFFER_B_ADDR = 32'h3120_0000;

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

// LED_DISK: standing regression check for the read-mux bug DDR-005 fixed
// (rtl/link_ring.sv's rd_active, see the comment there and the write-port
// mux comment below for the full story). Latches solid if blit_start EVER
// fires with blit_dst_addr not equal to EITHER double-buffer surface
// (OUT-004 -- a legitimate SOLID_FILL can target whichever one is
// currently back, not just a single fixed address) -- should stay OFF; if
// it ever lights, something reintroduced dst_addr corruption between
// link_ring and CMDQ.
reg dst_addr_wrong_ever;
always @(posedge clk_sys or posedge reset)
	if (reset) dst_addr_wrong_ever <= 1'b0;
	else if (blit_start && blit_dst_addr != BUFFER_A_ADDR && blit_dst_addr != BUFFER_B_ADDR)
		dst_addr_wrong_ever <= 1'b1;

assign LED_DISK = dst_addr_wrong_ever;

// LED_POWER: latches solid once link_ring has actually dispatched a
// command to CMDQ -- a basic "has the ring buffer ever delivered a command"
// health indicator. bit[1]=1 takes full manual control of the LED instead
// of leaving it OR'd with system status (emu_ports.vh).
reg link_dispatch_ever;
always @(posedge clk_sys or posedge reset)
	if (reset) link_dispatch_ever <= 1'b0;
	else if (link_cmd_valid && link_cmd_ready) link_dispatch_ever <= 1'b1;

assign LED_POWER = {1'b1, link_dispatch_ever};
assign BUTTONS = 0;

// Keep the framebuffer path enabled from reset so ascal can acknowledge its
// first FB_BASE latch; FB_FORCE_BLANK remains asserted until a PRESENT has
// completed, so uninitialized memory is never displayed.
reg present_done_ever;
always @(posedge clk_sys or posedge reset)
	if (reset) present_done_ever <= 1'b0;
	else if (present_done) present_done_ever <= 1'b1;

// LED_USER: latches solid the first time blit_start fires for any reason --
// a basic "has the fill engine ever run" health indicator. Was originally
// LED_USER's heartbeat blink; that heartbeat isn't informative once
// everything else already proves the clock is alive.
reg blit_start_ever;
always @(posedge clk_sys or posedge reset)
	if (reset) blit_start_ever <= 1'b0;
	else if (blit_start) blit_start_ever <= 1'b1;

// MISTER_FB scan-out (OUT-002) + double buffering (OUT-004): two fixed
// 640x480, 32bpp (FB_FORMAT[2:0]=3'b110) surfaces (BUFFER_A_ADDR/
// BUFFER_B_ADDR, declared up top) -- SURF-005 sized this up from the
// original 64x64 bring-up surface to something StarCraft/OpenBW-scale.
// Each buffer is ~1.17MB (640*480*4); the two sit in their own 2MB-aligned
// slots for generous headroom, well clear of each other and of LINK-002's
// ring (header+slots, a few KB, at 0x30020000+). NOT based at 0x20000000,
// see SURF-004: MiSTer's own system video scaler uses physical byte
// 0x20000000 as its RAM base, a real collision the MiSTer-Raster project
// hit and fixed on this exact platform. front_sel (from present.sv,
// flipped by PRESENT) selects which buffer FB_BASE currently points at;
// the host draws into whichever one is NOT front.
assign FB_EN = 1'b1;
assign FB_FORMAT = {2'b00, 3'b110};
assign FB_WIDTH = 12'd640;
assign FB_HEIGHT = 12'd480;
assign FB_BASE = front_sel ? BUFFER_B_ADDR : BUFFER_A_ADDR;
assign FB_STRIDE = 14'd2560;
assign FB_FORCE_BLANK = ~present_done_ever;

///////////////////////   ENGINE   /////////////////////////////////

wire [31:0] engine_wr_addr, engine_wr_data;
wire        engine_wr64_en, engine_wr64_ready;
wire [31:0] engine_wr64_addr;
wire [63:0] engine_wr64_data;
wire        engine_wr_en, engine_wr_ready;
wire        blit_start, blit_busy, blit_done;
wire [31:0] blit_dst_addr, blit_color;
wire [15:0] blit_dst_pitch, blit_width, blit_height;

wire        copy_start, copy_busy, copy_done;
wire [31:0] copy_dst_addr, copy_src_addr;
wire [15:0] copy_dst_pitch, copy_src_pitch, copy_width, copy_height;
wire        copy_key_enable;
wire [31:0] copy_key_value;
wire [31:0] copy_wr_addr, copy_wr_data, copy_rd_addr, copy_rd_data;
wire        copy_wr_en, copy_wr_ready, copy_rd_en, copy_rd_ready, copy_rd_valid;
wire        batch_start, batch_busy, batch_done;
wire [15:0] batch_count;
wire [31:0] batch_wr_addr, batch_wr_data, batch_rd_addr, batch_rd_data;
wire        batch_wr_en, batch_wr_ready, batch_rd_en, batch_rd_ready, batch_rd_valid, batch_rd_active;
wire [31:0] batch_rd64_addr, batch_wr64_addr;
wire [63:0] batch_rd64_data, batch_wr64_data;
wire        batch_rd64_en, batch_rd64_ready, batch_rd64_valid;
wire        batch_wr64_en, batch_wr64_ready;

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

// OUT-004: double-buffer flip. present.sv owns front_sel (which of
// BUFFER_A/BUFFER_B is currently scanned out) and only changes it synced to
// FB_VBL, the framework's vertical blank signal -- safe to sample directly
// with no cross-clock synchronizer since CLK_VIDEO (this core's own output,
// tied to clk_sys below) is what the framework uses to generate it in the
// first place, so present.sv's own clk IS that same domain.
wire present_start, present_busy, present_done;
wire front_sel;

present present
(
	.clk       (clk_sys),
	.reset     (reset),
	.fb_vbl    (FB_VBL),
	.fb_retired(FB_RETIRED),
	.start     (present_start),
	.busy      (present_busy),
	.done      (present_done),
	.front_sel (front_sel)
);

// LINK-005: completion fence. blit_done/copy_done/present_done fire once
// per command that ACTUALLY finished executing (link_ring's own read_ptr
// only tracks dispatch acceptance -- see LINK-003/LINK-005), ORed here
// since any one completing means "one more command is done" from the
// host's point of view; CMDQ never runs more than one at once. link_fence
// has no idea which engine ran or what command it was -- it is a pure
// counter, deliberately dumber than link_ring, so it never needs touching
// if link_ring's own FSM changes again.
// Batch completion is a single command completion even though the batch
// internally executes many descriptor copies.  Omitting it leaves the host
// fence unchanged, so sprite-demo's one-descriptor diagnostic waits forever
// and a following PRESENT can never retire.
wire cmd_done_pulse = blit_done || copy_done || batch_done || present_done;

wire [31:0] fence_wr_addr, fence_wr_data;
wire        fence_wr_en, fence_wr_ready;

link_fence link_fence
(
	.clk       (clk_sys),
	.reset     (reset),
	.done_pulse(cmd_done_pulse),
	.front_sel (front_sel),
	.wr_addr   (fence_wr_addr),
	.wr_data   (fence_wr_data),
	.wr_en     (fence_wr_en),
	.wr_ready  (fence_wr_ready)
);

// Temporary diagnostic (present-stage stutter investigation): publish
// ascal's per-retirement debug counters to DRAM. See
// rtl/dbg_present_probe.sv.
reg  fb_retired_prev;
always_ff @(posedge clk_sys or posedge reset)
	if (reset) fb_retired_prev <= 1'b0;
	else       fb_retired_prev <= FB_RETIRED;
wire fb_retired_edge = FB_RETIRED != fb_retired_prev;

wire [31:0] dbg_wr_addr, dbg_wr_data;
wire        dbg_wr_en, dbg_wr_ready;

dbg_present_probe dbg_present_probe
(
	.clk                (clk_sys),
	.reset              (reset),
	.retired_edge       (fb_retired_edge),
	.retire_wait_cyc    (DBG_RETIRE_WAIT_CYC),
	.missed_boundaries  (DBG_MISSED_BOUNDARIES),
	.read_outstanding_pk(DBG_READ_OUTSTANDING_PK),
	.wr_addr            (dbg_wr_addr),
	.wr_data            (dbg_wr_data),
	.wr_en              (dbg_wr_en),
	.wr_ready           (dbg_wr_ready)
);

cmdq cmdq
(
	.clk           (clk_sys),
	.reset         (reset),
	.cmd_valid     (link_cmd_valid),
	.cmd_data      (link_cmd_data),
	.cmd_ready     (link_cmd_ready),
	.blit_start    (blit_start),
	.blit_dst_addr (blit_dst_addr),
	.blit_dst_pitch(blit_dst_pitch),
	.blit_width    (blit_width),
	.blit_height   (blit_height),
	.blit_color    (blit_color),
	.blit_busy     (blit_busy),
	.blit_done     (blit_done),
	.memory_idle   (adapter_idle),
	.copy_start    (copy_start),
	.copy_dst_addr (copy_dst_addr),
	.copy_dst_pitch(copy_dst_pitch),
	.copy_src_addr (copy_src_addr),
	.copy_src_pitch(copy_src_pitch),
	.copy_width    (copy_width),
	.copy_height   (copy_height),
	.copy_key_enable(copy_key_enable),
	.copy_key_value(copy_key_value),
	.copy_busy     (copy_busy),
	.copy_done     (copy_done),
	.batch_start    (batch_start),
	.batch_count    (batch_count),
	.batch_busy     (batch_busy),
	.batch_done     (batch_done),
	.present_start  (present_start),
	.present_busy  (present_busy),
	.present_done  (present_done)
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
	.wr_ready (engine_wr_ready),
	.wr64_addr(engine_wr64_addr),
	.wr64_data(engine_wr64_data),
	.wr64_en  (engine_wr64_en),
	.wr64_ready(engine_wr64_ready)
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
	.key_enable(copy_key_enable),
	.key_value(copy_key_value),
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

sprite_batch sprite_batch
(
	.clk(clk_sys), .reset(reset), .start(batch_start), .count(batch_count),
	.busy(batch_busy), .done(batch_done),
	.rd_addr(batch_rd_addr), .rd_en(batch_rd_en), .rd_active(batch_rd_active),
	.rd_ready(batch_rd_ready), .rd_data(batch_rd_data), .rd_valid(batch_rd_valid),
	.rd64_addr(batch_rd64_addr), .rd64_en(batch_rd64_en),
	.rd64_ready(batch_rd64_ready), .rd64_data(batch_rd64_data), .rd64_valid(batch_rd64_valid),
	.wr_addr(batch_wr_addr), .wr_data(batch_wr_data), .wr_en(batch_wr_en),
	.wr_ready(batch_wr_ready),
	.wr64_addr(batch_wr64_addr), .wr64_data(batch_wr64_data),
	.wr64_en(batch_wr64_en), .wr64_ready(batch_wr64_ready)
);

// 4-way priority mux into the DDRAM adapter's write port: blit_copy's copy
// writes, link_ring's writes (INIT + read_ptr writeback), blit's fill
// writes, link_fence's writes (INIT + completion-count publish), and the
// temporary dbg_present_probe (present-stage stutter investigation). None
// can ever be simultaneously active by construction of CMDQ's own
// single-engine dispatch (blit and blit_copy) and link_ring only writing
// while idle/finishing a dispatch, so this priority is a tie-breaker, not
// load-bearing arbitration -- same caveat as DDR-003's read/write mux.
// link_fence sits below the engines: its writes are never time-critical
// (the host only needs the count to arrive eventually, not within any
// particular cycle), and by the time it wants to write, the engine that
// just triggered it (blit/blit_copy) has already stopped writing.
// dbg_present_probe sits lowest of all: same non-time-critical reasoning,
// and it is not part of the real design -- it must never be able to delay
// a real client's write.
wire        wr_sel_batch  = batch_busy;
wire        wr_sel_copy   = !wr_sel_batch && copy_busy;
wire        wr_sel_link   = !wr_sel_batch && !wr_sel_copy && link_wr_en;
wire        wr_sel_engine = !wr_sel_batch && !wr_sel_copy && !wr_sel_link &&
                            blit_busy;
wire        wr_sel_fence  = !wr_sel_batch && !wr_sel_copy && !wr_sel_link && !wr_sel_engine && fence_wr_en;
wire        wr_sel_dbg    = !wr_sel_batch && !wr_sel_copy && !wr_sel_link && !wr_sel_engine && !wr_sel_fence && dbg_wr_en;
wire [31:0] adapter_wr_addr = wr_sel_batch ? batch_wr_addr : wr_sel_copy ? copy_wr_addr : wr_sel_link ? link_wr_addr : wr_sel_engine ? engine_wr_addr : wr_sel_fence ? fence_wr_addr : dbg_wr_addr;
wire [31:0] adapter_wr_data = wr_sel_batch ? batch_wr_data : wr_sel_copy ? copy_wr_data : wr_sel_link ? link_wr_data : wr_sel_engine ? engine_wr_data : wr_sel_fence ? fence_wr_data : dbg_wr_data;
wire        adapter_wr_en   = wr_sel_batch ? batch_wr_en : wr_sel_copy ? copy_wr_en   : wr_sel_link ? link_wr_en   : wr_sel_engine ? engine_wr_en   : wr_sel_fence ? fence_wr_en : dbg_wr_en;
assign batch_wr_ready  = wr_sel_batch ? adapter_wr_ready : 1'b0;
wire        adapter_wr_ready;
assign copy_wr_ready   = wr_sel_copy   ? adapter_wr_ready : 1'b0;
assign link_wr_ready   = wr_sel_link   ? adapter_wr_ready : 1'b0;
assign engine_wr_ready = wr_sel_engine ? adapter_wr_ready : 1'b0;
assign fence_wr_ready  = wr_sel_fence  ? adapter_wr_ready : 1'b0;
assign dbg_wr_ready    = wr_sel_dbg    ? adapter_wr_ready : 1'b0;
wire adapter_wr64_en = (wr_sel_engine && engine_wr64_en) ||
                       (wr_sel_batch && batch_wr64_en);
wire        adapter_wr64_ready;
assign engine_wr64_ready = adapter_wr64_en ? adapter_wr64_ready : 1'b0;
wire adapter_batch_wr64_en = wr_sel_batch && batch_wr64_en;
assign batch_wr64_ready = adapter_batch_wr64_en ? adapter_wr64_ready : 1'b0;
wire [31:0] adapter_wr64_addr = wr_sel_batch ? batch_wr64_addr : engine_wr64_addr;
wire [63:0] adapter_wr64_data = wr_sel_batch ? batch_wr64_data : engine_wr64_data;

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
wire        rd_sel_batch = !rd_sel_link && batch_rd_active;
wire        rd_sel_batch64 = rd_sel_batch && batch_rd64_en;
wire [31:0] adapter_rd_addr = rd_sel_link ? link_rd_addr : rd_sel_batch ? batch_rd_addr : copy_rd_addr;
wire [31:0] adapter_rd64_addr = rd_sel_batch64 ? batch_rd64_addr : 32'b0;
wire        adapter_rd_en   = rd_sel_link ? link_rd_en   : (rd_sel_batch ? batch_rd_en : copy_rd_en);
wire        adapter_rd64_en = rd_sel_batch64;
wire        adapter_rd_ready, adapter_rd_valid;
wire [31:0] adapter_rd_data;
wire        adapter_rd64_ready, adapter_rd64_valid;
wire [63:0] adapter_rd64_data;
wire        adapter_idle;
assign link_rd_ready = rd_sel_link ? adapter_rd_ready : 1'b0;
assign batch_rd_ready = rd_sel_batch ? adapter_rd_ready : 1'b0;
assign batch_rd64_ready = rd_sel_batch64 ? adapter_rd64_ready : 1'b0;
assign copy_rd_ready = (rd_sel_link || rd_sel_batch) ? 1'b0 : adapter_rd_ready;
assign link_rd_data  = adapter_rd_data;
assign link_rd_valid = adapter_rd_valid;
assign batch_rd_data = adapter_rd_data;
assign batch_rd_valid = adapter_rd_valid;
assign batch_rd64_data = adapter_rd64_data;
assign batch_rd64_valid = rd_sel_batch ? adapter_rd64_valid : 1'b0;
assign copy_rd_data  = adapter_rd_data;
assign copy_rd_valid = adapter_rd_valid;

ddram_adapter ddram_adapter
(
	.clk             (clk_sys),
	.reset           (reset),
	.wr_addr         (adapter_wr_addr),
	.wr_data         (adapter_wr_data),
	.wr_en           (adapter_wr_en),
	.wr_ready        (adapter_wr_ready),
	.wr64_addr       (adapter_wr64_addr),
	.wr64_data       (adapter_wr64_data),
	.wr64_en         (adapter_wr64_en),
	.wr64_ready      (adapter_wr64_ready),
	.rd_addr         (adapter_rd_addr),
	.rd_en           (adapter_rd_en),
	.rd_ready        (adapter_rd_ready),
	.rd_data         (adapter_rd_data),
	.rd_valid        (adapter_rd_valid),
	.rd64_addr       (adapter_rd64_addr),
	.rd64_en         (adapter_rd64_en),
	.rd64_ready      (adapter_rd64_ready),
	.rd64_data       (adapter_rd64_data),
	.rd64_valid      (adapter_rd64_valid),
	.ddram_clk       (DDRAM_CLK),
	.ddram_busy      (DDRAM_BUSY),
	.ddram_burstcnt  (DDRAM_BURSTCNT),
	.ddram_addr      (DDRAM_ADDR),
	.ddram_dout      (DDRAM_DOUT),
	.ddram_dout_ready(DDRAM_DOUT_READY),
	.ddram_din       (DDRAM_DIN),
	.ddram_be        (DDRAM_BE),
	.ddram_we        (DDRAM_WE),
	.ddram_rd        (DDRAM_RD),
	.idle            (adapter_idle)
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

assign LED_USER = blit_start_ever;

endmodule
