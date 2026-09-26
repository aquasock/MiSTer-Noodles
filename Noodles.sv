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
localparam logic [31:0] BUFFER_C_ADDR = 32'h3160_0000;  // OUT-013 third buffer

// Declared ahead of their first use; present.sv drives them (OUT-004/OUT-013).
wire       present_retired;
wire [1:0] front_idx;

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

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
wire blit_any_start;
wire [31:0] blit_any_dst_addr;
reg dst_addr_wrong_ever;
always @(posedge clk_sys or posedge reset)
	if (reset) dst_addr_wrong_ever <= 1'b0;
	else if (blit_any_start && blit_any_dst_addr != BUFFER_A_ADDR && blit_any_dst_addr != BUFFER_B_ADDR &&
	         blit_any_dst_addr != BUFFER_C_ADDR)
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
// first FB_BASE latch; FB_FORCE_BLANK remains asserted until a flip of
// either kind has retired, so uninitialized memory is never displayed.
reg present_done_ever;
always @(posedge clk_sys or posedge reset)
	if (reset) present_done_ever <= 1'b0;
	else if (present_retired) present_done_ever <= 1'b1;

// LED_USER: latches solid the first time blit_start fires for any reason --
// a basic "has the fill engine ever run" health indicator. Was originally
// LED_USER's heartbeat blink; that heartbeat isn't informative once
// everything else already proves the clock is alive.
reg blit_start_ever;
always @(posedge clk_sys or posedge reset)
	if (reset) blit_start_ever <= 1'b0;
	else if (blit_any_start) blit_start_ever <= 1'b1;

// MISTER_FB scan-out (OUT-002) + double buffering (OUT-004): two fixed
// 800x600, 32bpp (FB_FORMAT[2:0]=3'b110) surfaces (BUFFER_A_ADDR/
// BUFFER_B_ADDR, declared up top).
// Each buffer is 1920000 bytes (800*600*4); the two sit in their own 2MB-aligned
// slots for generous headroom, well clear of each other and of LINK-002's
// ring (header+slots, a few KB, at 0x30020000+). NOT based at 0x20000000,
// see SURF-004: MiSTer's own system video scaler uses physical byte
// 0x20000000 as its RAM base, a real collision the MiSTer-Raster project
// hit and fixed on this exact platform. front_idx (from present.sv,
// changed by PRESENT or PRESENT_QUEUED) selects which buffer FB_BASE
// currently points at; the host draws into a buffer that is neither front
// nor awaiting a flip. BUFFER_C (OUT-013) occupies the free 2MB slot after
// the 0x31400000 tool scratch slot and is used only by queued flips.
assign FB_EN = 1'b1;
assign FB_FORMAT = {2'b00, 3'b110};
assign FB_WIDTH = 12'd800;
assign FB_HEIGHT = 12'd600;
assign FB_BASE = front_idx == 2'd2 ? BUFFER_C_ADDR :
                 front_idx == 2'd1 ? BUFFER_B_ADDR : BUFFER_A_ADDR;
assign FB_STRIDE = 14'd3200;
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
wire [7:0]  batch_rd64_len;
wire        batch_wr64_en, batch_wr64_ready;
wire [31:0] batch_base;
wire        fill_batch_start, fill_batch_busy, fill_batch_done;
wire [15:0] fill_batch_count;
wire [31:0] fill_batch_base;
wire [31:0] fill_batch_rd_addr, fill_batch_rd_data;
wire        fill_batch_rd_en, fill_batch_rd_ready, fill_batch_rd_valid, fill_batch_rd_active;
wire        fb_fill_start;
wire [31:0] fb_fill_dst_addr, fb_fill_color;
wire [15:0] fb_fill_dst_pitch, fb_fill_width, fb_fill_height;
// BLIT_BLEND (BLIT-007) reuses CMDQ's copy_* geometry registers.
wire        blend_start, blend_busy, blend_done;
wire [7:0]  blend_mod;
wire        blend_solid, blend_mode_en;
wire [31:0] blend_solid_color;
wire [23:0] blend_mode;
wire [31:0] blend_rd64_addr, blend_wr_addr, blend_wr_data, blend_wr64_addr;
wire [63:0] blend_rd64_data, blend_wr64_data;
wire [7:0]  blend_rd64_len;
wire        blend_rd64_en, blend_rd64_ready, blend_rd64_valid;
wire        blend_wr_en, blend_wr_ready, blend_wr64_en, blend_wr64_ready;
// BLIT-008: sprite_batch also launches blit_blend, for flagged descriptors
// and for copies blit_copy64 cannot perform. CMDQ and sprite_batch never
// launch it at the same time (CMDQ runs one engine per command).
wire        sb_blend_start, sb_blend_enable, sb_blend_mirror_x, sb_blend_mirror_y;
wire        sb_blend_key_enable, sb_blend_mode_en;
wire [23:0] sb_blend_mode;
wire [31:0] sb_blend_dst_addr, sb_blend_src_addr, sb_blend_mod, sb_blend_key_value;
wire [15:0] sb_blend_dst_pitch, sb_blend_src_pitch, sb_blend_width, sb_blend_height;

// LINK-001/LINK-002/LINK-003: the real host-driven command path.
// tools/link_push.c writes commands and write_ptr directly into shared
// DDR3; link_ring polls and fetches them here. Only polls/fetches while
// CMDQ is idle (cmd_ready), which is what keeps its reads from ever
// contending with blit_copy's (DDR-003's single-outstanding assumption).
wire         link_cmd_valid, link_cmd_ready;
wire [255:0] link_cmd_data;
wire [31:0]  link_wr_addr, link_wr_data, link_rd_addr, link_rd_data;
wire         link_wr_en, link_wr_ready, link_rd_en, link_rd_active, link_rd_ready, link_rd_valid;
wire         link_initialized, fence_initialized, link_session_active;
wire         adapter_idle;

link_ring link_ring
(
	.clk      (clk_sys),
	.reset    (reset),
	.enable   (link_session_active),
	.initialized(link_initialized),
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

// LINK-011: live identity and session challenge. Static metadata is useful
// only after this block echoes a host-selected token; DDR3 itself survives
// reset and therefore cannot prove that this core instance is alive.
wire [31:0] control_wr_addr, control_wr_data, control_rd_addr, control_rd_data;
wire        control_wr_en, control_wr_ready;
wire        control_rd_en, control_rd_active, control_rd_ready, control_rd_valid;

link_control link_control
(
	.clk             (clk_sys),
	.reset           (reset),
	.device_initialized(link_initialized && fence_initialized),
	.bus_available   (link_cmd_ready && !link_rd_active && adapter_idle),
	.rd_addr         (control_rd_addr),
	.rd_en           (control_rd_en),
	.rd_active       (control_rd_active),
	.rd_ready        (control_rd_ready),
	.rd_data         (control_rd_data),
	.rd_valid        (control_rd_valid),
	.wr_addr         (control_wr_addr),
	.wr_data         (control_wr_data),
	.wr_en           (control_wr_en),
	.wr_ready        (control_wr_ready),
	.session_active  (link_session_active)
);

// OUT-004/OUT-013: display flip. present.sv owns front_idx (which of
// BUFFER_A/B/C is currently scanned out) and only changes it synced to
// FB_VBL, the framework's vertical blank signal. FB_VBL is registered on
// CLK_VIDEO, now a separate 100MHz clock, and FB_RETIRED on the framework's
// own clock, so both are levels from other domains and pass through two
// flops here. The added latency only delays a flip within vertical blank.
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *) reg [1:0] fb_vbl_sync;
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *) reg [1:0] fb_retired_sync;
always @(posedge clk_sys or posedge reset)
	if (reset) begin
		fb_vbl_sync     <= 2'b00;
		fb_retired_sync <= 2'b00;
	end else begin
		fb_vbl_sync     <= {fb_vbl_sync[0], FB_VBL};
		fb_retired_sync <= {fb_retired_sync[0], FB_RETIRED};
	end

wire present_start, present_queued, present_accept, present_busy, present_done;
wire [1:0] present_target;
// Legacy fence parity (OUT-012) reports B as front; A and C both read as 0,
// which keeps a legacy client's next draw off the scanned-out buffer.
wire front_sel = front_idx == 2'd1;

present #(
	.RETIRE_VBLANKS(0)
) present
(
	.clk       (clk_sys),
	.reset     (reset),
	.fb_vbl    (fb_vbl_sync[1]),
	.fb_retired(fb_retired_sync[1]),
	.start     (present_start),
	.queued    (present_queued),
	.target    (present_target),
	.busy      (present_busy),
	.done      (present_done),
	.retired   (present_retired),
	.front_idx (front_idx)
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
// A queued PRESENT (OUT-013) completes its command on acceptance through
// present_accept; its background flip and retirement advance nothing.
// A blend launched by sprite_batch is one descriptor of a batch, not a
// command of its own; only CMDQ-launched BLIT_BLENDs advance the fence.
wire cmd_done_pulse = (blit_done && !fill_batch_busy) || copy_done || batch_done ||
                      fill_batch_done || present_done || present_accept || loader_done ||
                      (blend_done && !batch_busy);

wire [31:0] fence_wr_addr, fence_wr_data;
wire        fence_wr_en, fence_wr_ready;

link_fence link_fence
(
	.clk       (clk_sys),
	.reset     (reset),
	.initialized(fence_initialized),
	.done_pulse(cmd_done_pulse),
	.front_sel (front_sel),
	.wr_addr   (fence_wr_addr),
	.wr_data   (fence_wr_data),
	.wr_en     (fence_wr_en),
	.wr_ready  (fence_wr_ready)
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
	.blend_start   (blend_start),
	.blend_mod     (blend_mod),
	.blend_solid   (blend_solid),
	.blend_solid_color(blend_solid_color),
	.blend_mode_en (blend_mode_en),
	.blend_mode    (blend_mode),
	.blend_busy    (blend_busy),
	.blend_done    (blend_done),
	.batch_start    (batch_start),
	.batch_base     (batch_base),
	.batch_count    (batch_count),
	.batch_busy     (batch_busy),
	.batch_done     (batch_done),
	.fill_batch_start(fill_batch_start),
	.fill_batch_base(fill_batch_base),
	.fill_batch_count(fill_batch_count),
	.fill_batch_busy(fill_batch_busy),
	.fill_batch_done(fill_batch_done),
	.present_start  (present_start),
	.present_queued (present_queued),
	.present_target (present_target),
	.present_accept (present_accept),
	.present_busy  (present_busy),
	.present_done  (present_done),
	.loader_start   (loader_start),
	.loader_src_addr(loader_src_addr),
	.loader_dst_addr(loader_dst_addr),
	.loader_length  (loader_length),
	.loader_busy    (loader_busy),
	.loader_done    (loader_done)
);

blit blit
(
	.clk      (clk_sys),
	.reset    (reset),
	.start    (blit_any_start),
	.dst_addr (blit_any_dst_addr),
	.dst_pitch(fill_batch_busy ? fb_fill_dst_pitch : blit_dst_pitch),
	.width    (fill_batch_busy ? fb_fill_width : blit_width),
	.height   (fill_batch_busy ? fb_fill_height : blit_height),
	.color    (fill_batch_busy ? fb_fill_color : blit_color),
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

assign blit_any_start = blit_start || fb_fill_start;
assign blit_any_dst_addr = fill_batch_busy ? fb_fill_dst_addr : blit_dst_addr;

fill_batch fill_batch
(
	.clk(clk_sys), .reset(reset), .start(fill_batch_start),
	.descriptor_base(fill_batch_base), .count(fill_batch_count),
	.busy(fill_batch_busy), .done(fill_batch_done),
	.rd_addr(fill_batch_rd_addr), .rd_en(fill_batch_rd_en),
	.rd_active(fill_batch_rd_active), .rd_ready(fill_batch_rd_ready),
	.rd_data(fill_batch_rd_data), .rd_valid(fill_batch_rd_valid),
	.fill_start(fb_fill_start), .fill_dst_addr(fb_fill_dst_addr),
	.fill_dst_pitch(fb_fill_dst_pitch), .fill_width(fb_fill_width),
	.fill_height(fb_fill_height), .fill_color(fb_fill_color),
	.fill_done(blit_done)
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
	.clk(clk_sys), .reset(reset), .start(batch_start), .descriptor_base(batch_base),
	.count(batch_count),
	.busy(batch_busy), .done(batch_done),
	.rd_addr(batch_rd_addr), .rd_en(batch_rd_en), .rd_active(batch_rd_active),
	.rd_ready(batch_rd_ready), .rd_data(batch_rd_data), .rd_valid(batch_rd_valid),
	.rd64_addr(batch_rd64_addr), .rd64_en(batch_rd64_en),
	.rd64_len(batch_rd64_len),
	.rd64_ready(batch_rd64_ready), .rd64_data(batch_rd64_data), .rd64_valid(batch_rd64_valid),
	.wr_addr(batch_wr_addr), .wr_data(batch_wr_data), .wr_en(batch_wr_en),
	.wr_ready(batch_wr_ready),
	.wr64_addr(batch_wr64_addr), .wr64_data(batch_wr64_data),
	.wr64_en(batch_wr64_en), .wr64_ready(batch_wr64_ready),
	.memory_idle(adapter_idle),
	.blend_start(sb_blend_start),
	.blend_dst_addr(sb_blend_dst_addr), .blend_dst_pitch(sb_blend_dst_pitch),
	.blend_src_addr(sb_blend_src_addr), .blend_src_pitch(sb_blend_src_pitch),
	.blend_width(sb_blend_width), .blend_height(sb_blend_height), .blend_mod(sb_blend_mod),
	.blend_enable(sb_blend_enable), .blend_mirror_x(sb_blend_mirror_x),
	.blend_mirror_y(sb_blend_mirror_y), .blend_key_enable(sb_blend_key_enable),
	.blend_key_value(sb_blend_key_value), .blend_mode_en(sb_blend_mode_en),
	.blend_mode(sb_blend_mode), .blend_done(blend_done)
);

// Command fields are captured by blit_blend on start, so this mux only needs
// to be valid on the start cycle; batch_busy selects sprite_batch's.
blit_blend blit_blend
(
	.clk(clk_sys), .reset(reset), .start(blend_start || sb_blend_start),
	.dst_addr(batch_busy ? sb_blend_dst_addr : copy_dst_addr),
	.dst_pitch(batch_busy ? sb_blend_dst_pitch : copy_dst_pitch),
	.src_addr(batch_busy ? sb_blend_src_addr : copy_src_addr),
	.src_pitch(batch_busy ? sb_blend_src_pitch : copy_src_pitch),
	.width(batch_busy ? sb_blend_width : copy_width),
	.height(batch_busy ? sb_blend_height : copy_height),
	.mod(batch_busy ? sb_blend_mod : {blend_mod, 24'hff_ffff}),
	.blend(batch_busy ? sb_blend_enable : 1'b1),
	.solid(!batch_busy && blend_solid),
	.solid_color(blend_solid_color),
	.mode_en(batch_busy ? sb_blend_mode_en : blend_mode_en),
	.mode(batch_busy ? sb_blend_mode : blend_mode),
	.mirror_x(batch_busy && sb_blend_mirror_x),
	.mirror_y(batch_busy && sb_blend_mirror_y),
	.key_enable(batch_busy && sb_blend_key_enable),
	.key_value(sb_blend_key_value),
	.busy(blend_busy), .done(blend_done),
	.rd64_addr(blend_rd64_addr), .rd64_en(blend_rd64_en), .rd64_len(blend_rd64_len),
	.rd64_ready(blend_rd64_ready), .rd64_data(blend_rd64_data), .rd64_valid(blend_rd64_valid),
	.wr_addr(blend_wr_addr), .wr_data(blend_wr_data), .wr_en(blend_wr_en),
	.wr_ready(blend_wr_ready),
	.wr64_addr(blend_wr64_addr), .wr64_data(blend_wr64_data),
	.wr64_en(blend_wr64_en), .wr64_ready(blend_wr64_ready)
);

// Temporary throughput diagnostic. It observes the physical DDRAM port only
// while a direct engine command runs, then publishes the completed counters
// after the adapter drains. The publisher is the lowest-priority write client.
wire [31:0] perf_wr_addr, perf_wr_data;
wire        perf_wr_en, perf_wr_ready;
ddram_perf_probe ddram_perf_probe
(
	.clk(clk_sys), .reset(reset),
	.fill_start(blit_start), .fill_done(blit_done),
	.copy_start(copy_start), .copy_done(copy_done),
	.blend_start(blend_start), .blend_done(blend_done),
	.adapter_idle(adapter_idle),
	.ddram_busy(DDRAM_BUSY), .ddram_burstcnt(DDRAM_BURSTCNT),
	.ddram_rd(DDRAM_RD), .ddram_we(DDRAM_WE),
	.ddram_dout_ready(DDRAM_DOUT_READY),
	.wr_addr(perf_wr_addr), .wr_data(perf_wr_data),
	.wr_en(perf_wr_en), .wr_ready(perf_wr_ready)
);

// Priority mux into the DDRAM adapter's write port: batch/blend/copy, link_ring,
// link_control, fill, link_fence and the temporary performance probe. None
// can ever be simultaneously active by construction of CMDQ's own
// single-engine dispatch (blit and blit_copy) and link_ring only writing
// while idle/finishing a dispatch, so this priority is a tie-breaker, not
// load-bearing arbitration -- same caveat as DDR-003's read/write mux.
// link_fence sits below the engines: its writes are never time-critical
// (the host only needs the count to arrive eventually, not within any
// particular cycle), and by the time it wants to write, the engine that
// just triggered it (blit/blit_copy) has already stopped writing.
// blit_blend runs both as a command and inside a batch, so it outranks
// sprite_batch, which issues nothing while its blend runs.
wire        wr_sel_blend  = blend_busy;
wire        wr_sel_batch  = !wr_sel_blend && batch_busy;
wire        wr_sel_copy   = !wr_sel_batch && !wr_sel_blend && copy_busy;
wire        wr_sel_link   = !wr_sel_batch && !wr_sel_blend && !wr_sel_copy && link_wr_en;
wire        wr_sel_control = !wr_sel_batch && !wr_sel_blend && !wr_sel_copy && !wr_sel_link &&
                             control_wr_en;
wire        wr_sel_engine = !wr_sel_batch && !wr_sel_blend && !wr_sel_copy && !wr_sel_link &&
                            !wr_sel_control && blit_busy;
wire        wr_sel_fence  = !wr_sel_batch && !wr_sel_blend && !wr_sel_copy && !wr_sel_link &&
                            !wr_sel_control && !wr_sel_engine && fence_wr_en;
wire        wr_sel_perf   = !wr_sel_batch && !wr_sel_blend && !wr_sel_copy && !wr_sel_link &&
                            !wr_sel_control && !wr_sel_engine && !wr_sel_fence && perf_wr_en;
wire [31:0] adapter_wr_addr = wr_sel_blend ? blend_wr_addr : wr_sel_batch ? batch_wr_addr :
                              wr_sel_copy ? copy_wr_addr :
                              wr_sel_link ? link_wr_addr : wr_sel_control ? control_wr_addr :
                              wr_sel_engine ? engine_wr_addr : wr_sel_fence ? fence_wr_addr :
                              perf_wr_addr;
wire [31:0] adapter_wr_data = wr_sel_blend ? blend_wr_data : wr_sel_batch ? batch_wr_data :
                              wr_sel_copy ? copy_wr_data :
                              wr_sel_link ? link_wr_data : wr_sel_control ? control_wr_data :
                              wr_sel_engine ? engine_wr_data : wr_sel_fence ? fence_wr_data :
                              perf_wr_data;
wire        adapter_wr_en   = wr_sel_blend ? blend_wr_en : wr_sel_batch ? batch_wr_en :
                              wr_sel_copy ? copy_wr_en :
                              wr_sel_link ? link_wr_en : wr_sel_control ? control_wr_en :
                              wr_sel_engine ? engine_wr_en : wr_sel_fence ? fence_wr_en :
                              perf_wr_en;
// Each client's ready is its select, the adapter's registered queue space
// and, for the scalar port, only that client's own paired request -- the
// adapter's own ready depends on the muxed wr64_en, which let one engine's
// request logic (the fill engine's column compare) reach another engine's
// ready combinationally and set the 100MHz critical path. The selects are
// exclusive, so each ready equals the adapter's view whenever it matters.
wire        adapter_wr_space;
assign blend_wr_ready  = wr_sel_blend  && adapter_wr_space && !blend_wr64_en;
assign batch_wr_ready  = wr_sel_batch  && adapter_wr_space && !batch_wr64_en;
assign copy_wr_ready   = wr_sel_copy   && adapter_wr_space;
assign link_wr_ready   = wr_sel_link   && adapter_wr_space;
assign control_wr_ready = wr_sel_control && adapter_wr_space;
assign engine_wr_ready = wr_sel_engine && adapter_wr_space && !engine_wr64_en;
assign fence_wr_ready  = wr_sel_fence  && adapter_wr_space;
assign perf_wr_ready   = wr_sel_perf   && adapter_wr_space;
wire adapter_wr64_en = (wr_sel_engine && engine_wr64_en) ||
                       (wr_sel_batch && batch_wr64_en) ||
                       (wr_sel_blend && blend_wr64_en);
assign engine_wr64_ready = wr_sel_engine && adapter_wr_space;
assign batch_wr64_ready = wr_sel_batch && adapter_wr_space;
assign blend_wr64_ready = wr_sel_blend && adapter_wr_space;
wire [31:0] adapter_wr64_addr = wr_sel_blend ? blend_wr64_addr :
                                wr_sel_batch ? batch_wr64_addr : engine_wr64_addr;
wire [63:0] adapter_wr64_data = wr_sel_blend ? blend_wr64_data :
                                wr_sel_batch ? batch_wr64_data : engine_wr64_data;

// Priority mux into the DDRAM adapter's read port: link_control, link_ring,
// batch, then blit_copy. LINK-003's cmd_ready gating keeps these from
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
//
// Engine clients (batch, fill_batch, blend, loader, copy) never overlap:
// CMDQ runs one engine command at a time, sprite_batch reads its next
// descriptor only after the copy or blend it launched is done, and each
// client's rd_active or busy spans every outstanding response. Their owner
// is therefore taken from a register, one cycle after the client becomes
// active, instead of a combinational priority chain: the chain placed
// fill_batch's state on the rd64_len -> rd64_ready -> blit_copy64 commit
// path and failed 100MHz setup (OUT-013 build). A request simply waits one
// cycle for its grant; control and link keep combinational priority, and
// they use the port only while CMDQ is idle.
// Every client's port ownership, including link and control, now comes
// from a register (rtl/ddram_read_owner.sv, proved by fv/ddram_read_owner.sby):
// the owner is released only once its client drops active and no response
// is outstanding, then passes to the highest-priority active client. The
// previous combinational link/control priority placed link_ring's state on
// sprite_batch's copy-address path. A request simply waits one cycle for its
// grant; the adapter enable must remain low until that registered grant, so
// it cannot accept a request that the client did not see accepted. Each
// client's active spans every request and response it owns
// (DDR-005): link_ring's and fill_batch's rd_active, sprite_batch's
// rd_active across descriptor reads and copies, blit_blend's busy,
// sdram_loader's rd64_active and blit_copy's busy.
wire [6:0] rd_owner;
wire        rd_sel_control = rd_owner[0];
wire        rd_sel_link = rd_owner[1];
wire        rd_sel_batch = rd_owner[2];
wire        rd_sel_fill_batch = rd_owner[3];
// Sprite reads remain on the hardware-proven DDR3 burst path. SDR-008
// removes the SDRAM CDC overhead without changing this routing choice;
// the optional SDRAM path still performs four 16-bit reads per pair.
wire        rd_sel_batch64 = rd_sel_batch && batch_rd64_en;
wire        rd_sel_blend = rd_owner[4];
wire        rd_sel_blend64 = rd_sel_blend && blend_rd64_en;
// SDR-003: sdram_loader is a rd64-only client that drives adapter_rd64_en
// through this select, so the select also requires its rd64_active.
wire        rd_sel_loader64 = rd_owner[5] && loader_rd64_active;
wire        rd_sel_copy = rd_owner[6];
wire [31:0] adapter_rd_addr = rd_sel_control ? control_rd_addr :
                              rd_sel_link ? link_rd_addr :
                              rd_sel_batch ? batch_rd_addr :
                              rd_sel_fill_batch ? fill_batch_rd_addr :
                              rd_sel_copy ? copy_rd_addr : 32'b0;
wire [31:0] adapter_rd64_addr = rd_sel_batch64 ? batch_rd64_addr :
                                rd_sel_blend64 ? blend_rd64_addr :
                                rd_sel_loader64 ? loader_rd64_addr : 32'b0;
wire [7:0]  adapter_rd64_len = rd_sel_batch64 ? batch_rd64_len :
                               rd_sel_blend64 ? blend_rd64_len :
                               rd_sel_loader64 ? loader_rd64_len : 8'd1;
wire        adapter_rd_en   = rd_sel_control ? control_rd_en :
                              rd_sel_link ? link_rd_en :
                              rd_sel_batch ? batch_rd_en :
                              rd_sel_fill_batch ? fill_batch_rd_en :
                              rd_sel_copy ? copy_rd_en : 1'b0;
wire        adapter_rd64_en = rd_sel_batch64 || rd_sel_blend64 || rd_sel_loader64;
wire        adapter_rd_ready, adapter_rd_valid;
wire [31:0] adapter_rd_data;
wire        adapter_rd64_ready, adapter_rd64_valid;
wire [63:0] adapter_rd64_data;

ddram_read_owner #(.CLIENTS(7)) ddram_read_owner
(
	.clk          (clk_sys),
	.reset        (reset),
	.active       ({copy_busy, loader_rd64_active, blend_busy, fill_batch_rd_active,
	                batch_rd_active, link_rd_active, control_rd_active}),
	.rd_accept    (adapter_rd_en && adapter_rd_ready),
	.rd64_accept  (adapter_rd64_en && adapter_rd64_ready),
	.rd64_len     (adapter_rd64_len),
	.rd_response  (adapter_rd_valid),
	.rd64_response(adapter_rd64_valid),
	.owner        (rd_owner)
);
assign link_rd_ready = rd_sel_link ? adapter_rd_ready : 1'b0;
assign control_rd_ready = rd_sel_control ? adapter_rd_ready : 1'b0;
assign batch_rd_ready = rd_sel_batch ? adapter_rd_ready : 1'b0;
assign fill_batch_rd_ready = rd_sel_fill_batch ? adapter_rd_ready : 1'b0;
assign batch_rd64_ready = rd_sel_batch64 ? adapter_rd64_ready : 1'b0;
assign loader_rd64_ready = rd_sel_loader64 ? adapter_rd64_ready : 1'b0;
assign blend_rd64_ready = rd_sel_blend64 ? adapter_rd64_ready : 1'b0;
assign copy_rd_ready = rd_sel_copy ? adapter_rd_ready : 1'b0;
assign control_rd_data = adapter_rd_data;
assign control_rd_valid = rd_sel_control ? adapter_rd_valid : 1'b0;
assign link_rd_data  = adapter_rd_data;
assign link_rd_valid = rd_sel_link ? adapter_rd_valid : 1'b0;
assign batch_rd_data = adapter_rd_data;
assign batch_rd_valid = adapter_rd_valid;
assign fill_batch_rd_data = adapter_rd_data;
assign fill_batch_rd_valid = rd_sel_fill_batch ? adapter_rd_valid : 1'b0;
assign batch_rd64_data = adapter_rd64_data;
assign batch_rd64_valid = rd_sel_batch ? adapter_rd64_valid : 1'b0;
assign loader_rd64_data = adapter_rd64_data;
assign blend_rd64_data = adapter_rd64_data;
assign blend_rd64_valid = rd_sel_blend ? adapter_rd64_valid : 1'b0;
assign loader_rd64_valid = rd_sel_loader64 ? adapter_rd64_valid : 1'b0;
assign copy_rd_data  = adapter_rd_data;
assign copy_rd_valid = rd_sel_copy ? adapter_rd_valid : 1'b0;

ddram_adapter ddram_adapter
(
	.clk             (clk_sys),
	.reset           (reset),
	.wr_addr         (adapter_wr_addr),
	.wr_data         (adapter_wr_data),
	.wr_en           (adapter_wr_en),
	/* Clients use per-client readies derived from wr_space above. */
	.wr_ready        (),
	.wr64_addr       (adapter_wr64_addr),
	.wr64_data       (adapter_wr64_data),
	.wr64_en         (adapter_wr64_en),
	.wr64_ready      (),
	.wr_space        (adapter_wr_space),
	.rd_addr         (adapter_rd_addr),
	.rd_en           (adapter_rd_en),
	.rd_ready        (adapter_rd_ready),
	.rd_data         (adapter_rd_data),
	.rd_valid        (adapter_rd_valid),
	.rd64_addr       (adapter_rd64_addr),
	.rd64_en         (adapter_rd64_en),
	.rd64_len        (adapter_rd64_len),
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

// SDR-008: core and board SDRAM share one PLL output, now 120MHz. The video
// clock is a separate 100MHz output so the framework's scaler input and
// output logic do not run at the core clock.
localparam int CLK_SYS_MHZ = 120;
// Board-SDRAM timing in cycles, from the 20ns tRCD/tRP and 60ns tRFC the
// controller's original 100MHz sequencing provided (2, 2 and 6 cycles).
localparam int SDRAM_TRCD_EXTRA = (20 * CLK_SYS_MHZ + 999) / 1000 - 2;
localparam int SDRAM_TRP_EXTRA  = (20 * CLK_SYS_MHZ + 999) / 1000 - 2;
localparam int SDRAM_TRFC_EXTRA = (60 * CLK_SYS_MHZ + 999) / 1000 - 6;
wire clk_sys, clk_video, pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_video),
	.locked(pll_locked)
);

// Reset asserts asynchronously and releases synchronously. The releasing
// register stays off the global clock network, whose insertion delay failed
// 120MHz recovery, and is duplicated by fanout so each copy reaches nearby
// registers over local routing; every copy releases on the same edge.
wire reset_raw = RESET | status[0] | buttons[1];
(* altera_attribute = "-name GLOBAL_SIGNAL OFF" *) (* maxfan = 128 *) reg [1:0] reset_sync = 2'b11;
always @(posedge clk_sys or posedge reset_raw)
	if (reset_raw) reset_sync <= 2'b11;
	else reset_sync <= {reset_sync[0], 1'b0};
wire reset = reset_sync[1];

// SDR-001 (core-log entry 62, step 2): the local SDRAM board
// controller, vendored from MiSTer-devel/NeoGeo_MiSTer's rtl/sdram.sv (see
// rtl/sdram.sv's own header). It is HPS-invisible (GPIO-wired to FPGA
// fabric only, confirmed this step -- see core-log entry 62's discovery
// note) and physically separate from DDRAM_*'s DDR3/F2H bridge, so it
// cannot be reached by the host and never shares an address space with
// SURF-003's DDR3 window. Its normal-port sel/addr/rd/dout/ready pins are
// driven by sdram_adapter.sv (core-log entry 64, step 4); its copy port
// (cpsel/cpaddr/cpdin/cprd/cpreq/cpbusy) is now driven by sdram_loader.sv
// (SDR-003, step 5a) -- the one-shot DDR3->SDRAM bulk copy needed because
// this board has no HPS/host write path at all (SDR-001 above). wr/bs/din
// remain tied inactive; sdram_adapter only implements the read path (see
// its own header for why).
sdram #(.CLK_MHZ(CLK_SYS_MHZ), .TRCD_EXTRA(SDRAM_TRCD_EXTRA), .TRP_EXTRA(SDRAM_TRP_EXTRA),
        .TRFC_EXTRA(SDRAM_TRFC_EXTRA)) sdram
(
	.init    (~pll_locked),
	.clk     (clk_sys),

	.SDRAM_DQ  (SDRAM_DQ),
	.SDRAM_A   (SDRAM_A),
	.SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA  (SDRAM_BA),
	.SDRAM_nCS (SDRAM_nCS),
	.SDRAM_nWE (SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CKE (SDRAM_CKE),
	.SDRAM_CLK (SDRAM_CLK),
	.SDRAM_EN  (1'b1),

	.sel   (sdram_adapter_sel),
	.addr  (sdram_adapter_addr),
	.dout  (sdram_adapter_dout),
	.din   ('0),
	.wr    (1'b0),
	.bs    (2'b00),
	.rd    (sdram_adapter_rd),
	.ready (sdram_adapter_ready),
	.refresh(sdram_refresh),

	.cpsel (loader_cpsel),
	.cpaddr(loader_cpaddr),
	.cpdin (loader_cpdin),
	.cprd  (loader_cprd),
	.cpreq (loader_cpreq),
	.cpbusy(loader_cpbusy)
);

// SDR-007: sprite_batch's rd64 reads reverted to DDR3 (see the mux above),
// so sdram_adapter's client-facing rd64 port is tied inactive again, as it
// was in step 4 before entry 67's step 5b. The adapter,
// sdram.sv controller and sdram_loader all remain instantiated and
// functional -- SDRAM is simply no longer in the sprite read path. Kept
// wired (rather than deleted) so it stays available as a potential second
// parallel memory channel rather than a DDR3 replacement.
wire        sdram_adapter_sel, sdram_adapter_rd, sdram_adapter_ready;
wire [26:1] sdram_adapter_addr;
wire [15:0] sdram_adapter_dout;
wire        sdram_rd64_ready_unused, sdram_rd64_valid_unused;
wire [63:0] sdram_rd64_data_unused;

sdram_adapter #(.ADDR_WIDTH(32)) sdram_adapter
(
	.clk     (clk_sys),
	.reset   (reset),

	.rd64_addr (32'b0),
	.rd64_en   (1'b0),
	.rd64_len  (8'd1),
	.rd64_ready(sdram_rd64_ready_unused),
	.rd64_data (sdram_rd64_data_unused),
	.rd64_valid(sdram_rd64_valid_unused),

	.sd_sel  (sdram_adapter_sel),
	.sd_addr (sdram_adapter_addr),
	.sd_dout (sdram_adapter_dout),
	.sd_rd   (sdram_adapter_rd),
	.sd_ready(sdram_adapter_ready)
);

// SDR-003 (core-log entry 66, step 5a): the one-shot DDR3 -> SDRAM bulk
// loader. Triggered by cmdq.sv's new OP_LOAD_SDRAM opcode; its fill side
// shares ddram_adapter's rd64 port (see rd_sel_loader64 above) and its
// flush side drives sdram.sv's real copy port directly (wired above,
// replacing the previously-tied-inactive stubs).
wire        loader_start, loader_busy, loader_done;
wire [31:0] loader_src_addr, loader_dst_addr, loader_length;
wire [31:0] loader_rd64_addr;
wire        loader_rd64_en, loader_rd64_active;
wire [7:0]  loader_rd64_len;
wire        loader_rd64_ready;
wire [63:0] loader_rd64_data;
wire        loader_rd64_valid;
wire        loader_cpsel, loader_cprd, loader_cpreq, loader_cpbusy;
wire [26:1] loader_cpaddr;
wire [15:0] loader_cpdin;

sdram_loader #(.ADDR_WIDTH(32), .CPDIN_STAGES(SDRAM_TRCD_EXTRA)) sdram_loader
(
	.clk     (clk_sys),
	.reset   (reset),

	.start   (loader_start),
	.src_addr(loader_src_addr),
	.dst_addr(loader_dst_addr),
	.length  (loader_length),
	.busy    (loader_busy),
	.done    (loader_done),

	.rd64_addr  (loader_rd64_addr),
	.rd64_en    (loader_rd64_en),
	.rd64_active(loader_rd64_active),
	.rd64_len   (loader_rd64_len),
	.rd64_ready (loader_rd64_ready),
	.rd64_data  (loader_rd64_data),
	.rd64_valid (loader_rd64_valid),

	.cpsel (loader_cpsel),
	.cpaddr(loader_cpaddr),
	.cpdin (loader_cpdin),
	.cprd  (loader_cprd),
	.cpreq (loader_cpreq),
	.cpbusy(loader_cpbusy)
);

// The controller's periodic auto-refresh is host-timed, not self-timed
// (see rtl/sdram.sv: `if (refresh ^ refresh_old)`) -- toggling on every
// rising edge of a free-running counter every 7.8us (the standard 64ms/8192-
// row JEDEC refresh interval, 936 clk_sys cycles at 120MHz) keeps the chip
// refreshed even while nothing is issuing real reads/writes yet.
localparam int SDRAM_REFRESH_CYCLES = (78 * CLK_SYS_MHZ) / 10;
reg [9:0] sdram_refresh_count;
reg       sdram_refresh;
always_ff @(posedge clk_sys) begin
	if (sdram_refresh_count == 10'(SDRAM_REFRESH_CYCLES - 1)) begin
		sdram_refresh_count <= '0;
		sdram_refresh <= ~sdram_refresh;
	end else begin
		sdram_refresh_count <= sdram_refresh_count + 1'b1;
	end
end

assign CLK_VIDEO = clk_video;

// A permanently-0 CE_PIXEL was never correct -- the framework's OSD
// compositing/mixer chain (sys/sys_top.v, sys/video_mixer.sv) uses it
// regardless of whether the picture comes from MISTER_FB or a core's own
// raster output; ascal generates its own independent output timing for the
// FB path, but the downstream mixer still needs a real toggling enable.
// Exact rate is not yet tuned to any specific video mode -- a modest
// divide-by-4 of clk_sys, the same shape virtually every MiSTer core uses.
reg [1:0] ce_div;
always @(posedge clk_video) ce_div <= ce_div + 2'd1;
assign CE_PIXEL = (ce_div == 2'd0);

assign VGA_DE = 0;
assign VGA_HS = 0;
assign VGA_VS = 0;
assign VGA_R  = 8'd0;
assign VGA_G  = 8'd0;
assign VGA_B  = 8'd0;

assign LED_USER = blit_start_ever;

endmodule
