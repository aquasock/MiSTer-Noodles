// CMDQ: command processor. Decodes one 32-byte command slot at a time,
// presented on a simple valid/ready front end, and dispatches it to BLIT
// (SOLID_FILL), blit_copy (BLIT_COPY / BLIT_COPY_KEY -- both dispatch to
// the same engine, differing only in whether colorkey transparency is on),
// blit_blend (BLIT_BLEND / BLEND_FILL -- BLIT-007/BLIT-010), fill_batch
// (FILL_BATCH), or present (PRESENT, the double-buffer flip -- OUT-004;
// PRESENT_QUEUED, the three-buffer flip -- OUT-013).
//
// ai/core-reference.md CMDQ-001 defines the command slot layout this module
// decodes; BLIT-002/BLIT-003/BLIT-006/BLIT-007 define what each BLIT opcode's fields
// mean; OUT-004 defines PRESENT's.

module cmdq #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32
) (
    input  logic          clk,
    input  logic          reset,

    input  logic          cmd_valid,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [255:0]  cmd_data,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic          cmd_ready,

    output logic                  blit_start,
    output logic [ADDR_WIDTH-1:0] blit_dst_addr,
    output logic [15:0]           blit_dst_pitch,
    output logic [15:0]           blit_width,
    output logic [15:0]           blit_height,
    output logic [DATA_WIDTH-1:0] blit_color,
    input  logic                  blit_busy,
    input  logic                  blit_done,
    input  logic                  memory_idle,

    output logic                  copy_start,
    output logic [ADDR_WIDTH-1:0] copy_dst_addr,
    output logic [15:0]           copy_dst_pitch,
    output logic [ADDR_WIDTH-1:0] copy_src_addr,
    output logic [15:0]           copy_src_pitch,
    output logic [15:0]           copy_width,
    output logic [15:0]           copy_height,
    output logic                  copy_key_enable,
    output logic [DATA_WIDTH-1:0] copy_key_value,
    input  logic                  copy_busy,
    input  logic                  copy_done,

    // BLIT_BLEND and BLEND_FILL share the copy_* destination geometry above.
    output logic                  blend_start,
    output logic [7:0]            blend_mod,
    output logic                  blend_solid,
    output logic [DATA_WIDTH-1:0] blend_solid_color,
    output logic                  blend_mode_en,
    output logic [23:0]           blend_mode,
    input  logic                  blend_busy,
    input  logic                  blend_done,

    output logic                  batch_start,
    output logic [ADDR_WIDTH-1:0] batch_base,
    output logic [15:0]           batch_count,
    input  logic                  batch_busy,
    input  logic                  batch_done,

    output logic                  fill_batch_start,
    output logic [ADDR_WIDTH-1:0] fill_batch_base,
    output logic [15:0]           fill_batch_count,
    input  logic                  fill_batch_busy,
    input  logic                  fill_batch_done,

    output logic                  present_start,
    output logic                  present_queued,
    output logic [1:0]            present_target,
    output logic                  present_accept,  // queued flip's command completion
    input  logic                  present_busy,
    input  logic                  present_done,

    output logic                   loader_start,
    output logic [ADDR_WIDTH-1:0]  loader_src_addr,
    output logic [ADDR_WIDTH-1:0]  loader_dst_addr,
    output logic [ADDR_WIDTH-1:0]  loader_length,
    input  logic                   loader_busy,
    input  logic                   loader_done
);

    // Command slot layout (32 bytes / 256 bits), all fields plain uint32:
    //   [ 31:  0] opcode    (only [7:0] used)
    //   [ 63: 32] dst_addr
    //   [ 95: 64] dst_pitch (only [15:0] used)
    //   [127: 96] width     (only [15:0] used)
    //   [159:128] height    (only [15:0] used)
    //   [191:160] color                          (SOLID_FILL only)
    //                                             (BLIT_COPY_KEY: colorkey value)
    //                                             (BLIT_BLEND: [7:0] alpha modulation)
    //                                             (BLEND_FILL: constant RGBA source)
    //   [223:192] src_addr                       (BLIT_COPY/BLIT_COPY_KEY only)
    //                                             (LOAD_SDRAM: DDR3 source addr)
    //                                             (BLEND_FILL: explicit mode flags)
    //   [255:224] src_pitch (only [15:0] used)    (BLIT_COPY/BLIT_COPY_KEY only)
    // LOAD_SDRAM (SDR-003) repurposes dst_addr as the SDRAM destination
    // byte address (must be page-aligned, see sdram_loader.sv's header)
    // and color as the 32-bit byte length to copy; dst_pitch/width/height
    // are unused.
    // PRESENT_QUEUED (OUT-013) carries the target display buffer index 0-2
    // in dst_addr; other fields are zero. Index 3 is a flip barrier: it is
    // accepted once no flip is pending and completes without flipping.
    localparam logic [7:0] OP_SOLID_FILL    = 8'h01;
    localparam logic [7:0] OP_BLIT_COPY     = 8'h02;
    localparam logic [7:0] OP_BLIT_COPY_KEY = 8'h03;
    localparam logic [7:0] OP_PRESENT       = 8'h04;
    localparam logic [7:0] OP_SPRITE_BATCH  = 8'h05;
    localparam logic [7:0] OP_LOAD_SDRAM    = 8'h06;
    localparam logic [7:0] OP_BLIT_BLEND    = 8'h07;
    localparam logic [7:0] OP_BLEND_FILL    = 8'h08;
    localparam logic [7:0] OP_FILL_BATCH    = 8'h0a;
    localparam logic [7:0] OP_PRESENT_QUEUED = 8'h0b;
    localparam logic [31:0] DESCRIPTOR_BASE = 32'h3002_2000;
    localparam logic [31:0] DESCRIPTOR_END  = 32'h3004_2000;

    wire [7:0]  op          = cmd_data[7:0];
    wire [31:0] c_dst_addr  = cmd_data[63:32];
    wire [15:0] c_dst_pitch = cmd_data[79:64];
    wire [15:0] c_width     = cmd_data[111:96];
    wire [15:0] c_height    = cmd_data[143:128];
    wire [31:0] c_color     = cmd_data[191:160];
    wire [31:0] c_src_addr  = cmd_data[223:192];
    wire [15:0] c_src_pitch = cmd_data[239:224];

    typedef enum logic [1:0] {IDLE, WAIT_DONE, ACCEPT_PRESENT} state_t;
    state_t state;

    // A PRESENT of either kind waits in IDLE, without being accepted, while
    // an earlier flip is still pending; other commands proceed.
    wire present_op = op == OP_PRESENT || op == OP_PRESENT_QUEUED;
    // cmd_data keeps the last presented slot after link_ring's handshake,
    // so only a PRESENT that is actually being offered may hold cmd_ready
    // low; otherwise the retained queued PRESENT would stop link_ring from
    // fetching the commands that are meant to run during the flip.
    wire present_blocked = cmd_valid && present_op && present_busy;

    // ENGINE_NONE follows a queued PRESENT: its flip runs in the background,
    // so nothing holds CMDQ once the command has been accepted.
    typedef enum logic [2:0] {ENGINE_BLIT, ENGINE_COPY, ENGINE_PRESENT, ENGINE_BATCH, ENGINE_LOAD,
                              ENGINE_BLEND, ENGINE_FILL_BATCH, ENGINE_NONE} engine_t;
    engine_t active_engine;
    logic engine_done_seen;
    wire engine_busy = (active_engine == ENGINE_COPY)    ? copy_busy :
                        (active_engine == ENGINE_PRESENT) ? present_busy :
                        (active_engine == ENGINE_BATCH) ? batch_busy :
                        (active_engine == ENGINE_FILL_BATCH) ? fill_batch_busy :
                        (active_engine == ENGINE_LOAD) ? loader_busy :
                        (active_engine == ENGINE_NONE) ? 1'b0 :
                        (active_engine == ENGINE_BLEND) ? blend_busy : blit_busy;
    wire engine_done = (active_engine == ENGINE_COPY)    ? copy_done :
                        (active_engine == ENGINE_PRESENT) ? present_done :
                        (active_engine == ENGINE_BATCH) ? batch_done :
                       (active_engine == ENGINE_FILL_BATCH) ? fill_batch_done :
                        (active_engine == ENGINE_LOAD) ? loader_done :
                        (active_engine == ENGINE_NONE) ? 1'b0 :
                        (active_engine == ENGINE_BLEND) ? blend_done : blit_done;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state          <= IDLE;
            active_engine  <= ENGINE_BLIT;
            engine_done_seen<= 1'b0;
            blit_start     <= 1'b0;
            blit_dst_addr  <= '0;
            blit_dst_pitch <= '0;
            blit_width     <= '0;
            blit_height    <= '0;
            blit_color     <= '0;
            copy_start     <= 1'b0;
            copy_dst_addr  <= '0;
            copy_dst_pitch <= '0;
            copy_src_addr  <= '0;
            copy_src_pitch <= '0;
            copy_width     <= '0;
            copy_height    <= '0;
            copy_key_enable<= 1'b0;
            copy_key_value <= '0;
            blend_start    <= 1'b0;
            blend_mod      <= '0;
            blend_solid    <= 1'b0;
            blend_solid_color <= '0;
            blend_mode_en  <= 1'b0;
            blend_mode     <= '0;
            batch_start    <= 1'b0;
            batch_base     <= '0;
            batch_count    <= '0;
            fill_batch_start <= 1'b0;
            fill_batch_base <= '0;
            fill_batch_count <= '0;
            present_start  <= 1'b0;
            present_queued <= 1'b0;
            present_target <= 2'd0;
            present_accept <= 1'b0;
            loader_start    <= 1'b0;
            loader_src_addr <= '0;
            loader_dst_addr <= '0;
            loader_length   <= '0;
        end else begin
            blit_start    <= 1'b0;
            copy_start    <= 1'b0;
            blend_start   <= 1'b0;
            present_start <= 1'b0;
            present_accept <= 1'b0;
            batch_start    <= 1'b0;
            fill_batch_start <= 1'b0;
            loader_start   <= 1'b0;

            unique case (state)
                IDLE: begin
                    // Unknown opcodes are accepted and dropped.
                    if (cmd_valid && !blit_busy && !copy_busy && !blend_busy && !present_blocked) begin
                        if (op == OP_SOLID_FILL) begin
                            blit_dst_addr  <= c_dst_addr;
                            blit_dst_pitch <= c_dst_pitch;
                            blit_width     <= c_width;
                            blit_height    <= c_height;
                            blit_color     <= c_color;
                            blit_start     <= 1'b1;
                            active_engine  <= ENGINE_BLIT;
                            state          <= WAIT_DONE;
                        end else if (op == OP_BLIT_COPY || op == OP_BLIT_COPY_KEY) begin
                            copy_dst_addr  <= c_dst_addr;
                            copy_dst_pitch <= c_dst_pitch;
                            copy_width     <= c_width;
                            copy_height    <= c_height;
                            copy_src_addr  <= c_src_addr;
                            copy_src_pitch <= c_src_pitch;
                            copy_key_enable<= (op == OP_BLIT_COPY_KEY);
                            copy_key_value <= c_color;
                            copy_start     <= 1'b1;
                            active_engine  <= ENGINE_COPY;
                            state          <= WAIT_DONE;
                        end else if (op == OP_BLIT_BLEND) begin
                            copy_dst_addr  <= c_dst_addr;
                            copy_dst_pitch <= c_dst_pitch;
                            copy_width     <= c_width;
                            copy_height    <= c_height;
                            copy_src_addr  <= c_src_addr;
                            copy_src_pitch <= c_src_pitch;
                            blend_mod      <= c_color[7:0];
                            blend_solid    <= 1'b0;
                            blend_mode_en  <= 1'b0;
                            blend_start    <= 1'b1;
                            active_engine  <= ENGINE_BLEND;
                            state          <= WAIT_DONE;
                        end else if (op == OP_BLEND_FILL) begin
                            copy_dst_addr  <= c_dst_addr;
                            copy_dst_pitch <= c_dst_pitch;
                            copy_width     <= c_width;
                            copy_height    <= c_height;
                            blend_mod      <= 8'hff;
                            blend_solid_color <= c_color;
                            blend_solid    <= 1'b1;
                            blend_mode_en  <= 1'b1;
                            blend_mode     <= c_src_addr[31:8];
                            blend_start    <= 1'b1;
                            active_engine  <= ENGINE_BLEND;
                            state          <= WAIT_DONE;
                        end else if (op == OP_PRESENT) begin
                            present_start <= 1'b1;
                            present_queued <= 1'b0;
                            active_engine <= ENGINE_PRESENT;
                            state         <= WAIT_DONE;
                        end else if (op == OP_PRESENT_QUEUED && c_dst_addr <= 32'd3) begin
                            present_start  <= c_dst_addr != 32'd3;
                            present_queued <= 1'b1;
                            present_target <= c_dst_addr[1:0];
                            active_engine  <= ENGINE_NONE;
                            state          <= ACCEPT_PRESENT;
                        end else if (op == OP_SPRITE_BATCH && c_width != 0 && c_width <= 64 &&
                                     c_dst_addr >= DESCRIPTOR_BASE &&
                                     c_dst_addr < DESCRIPTOR_END &&
                                     c_dst_addr[10:0] == 11'd0) begin
                            // Protocol 1.5 selects one aligned 2 KiB table
                            // from the bounded 64-table descriptor pool.
                            batch_base <= c_dst_addr;
                            batch_count <= c_width;
                            batch_start <= 1'b1;
                            active_engine <= ENGINE_BATCH;
                            state <= WAIT_DONE;
                        end else if (op == OP_FILL_BATCH && c_width != 0 && c_width <= 64 &&
                                     c_dst_addr >= DESCRIPTOR_BASE &&
                                     c_dst_addr < DESCRIPTOR_END &&
                                     c_dst_addr[10:0] == 11'd0) begin
                            fill_batch_base <= c_dst_addr;
                            fill_batch_count <= c_width;
                            fill_batch_start <= 1'b1;
                            active_engine <= ENGINE_FILL_BATCH;
                            state <= WAIT_DONE;
                        end else if (op == OP_LOAD_SDRAM) begin
                            loader_src_addr <= c_src_addr;
                            loader_dst_addr <= c_dst_addr;
                            loader_length   <= c_color;
                            loader_start    <= 1'b1;
                            active_engine   <= ENGINE_LOAD;
                            state           <= WAIT_DONE;
                        end
                    end
                end

                // present sees start this cycle and is busy from the next,
                // which is when IDLE can first consider another PRESENT.
                ACCEPT_PRESENT: begin
                    present_accept <= 1'b1;
                    state          <= IDLE;
                end

                WAIT_DONE: begin
                    if (engine_done) engine_done_seen <= 1'b1;
                    if ((engine_done || engine_done_seen) && memory_idle) begin
                        state <= IDLE;
                        engine_done_seen <= 1'b0;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

    assign cmd_ready = (state == IDLE) && !engine_busy && !present_blocked;

`ifdef FORMAL
    // Properties proved by fv/cmdq.sby. Engines are abstract: each may raise
    // busy and pulse done only while a command it was started for is still
    // outstanding. The display flip follows present.sv's contract: busy from
    // the cycle after start until it finishes, done only for a legacy
    // PRESENT and only on the cycle busy falls. Everything else, including
    // cmd_data, is unconstrained.
    logic f_past_valid = 1'b0;
    always_ff @(posedge clk) f_past_valid <= 1'b1;
    always_comb if (!f_past_valid) assume(reset);

    // A command is recognized when CMDQ must complete it exactly once; any
    // other offered command is accepted and dropped without a completion.
    wire f_batch_ok = c_width != 0 && c_width <= 64 && c_dst_addr >= DESCRIPTOR_BASE &&
                      c_dst_addr < DESCRIPTOR_END && c_dst_addr[10:0] == 11'd0;
    wire f_recognized = op == OP_SOLID_FILL || op == OP_BLIT_COPY || op == OP_BLIT_COPY_KEY ||
                        op == OP_BLIT_BLEND || op == OP_BLEND_FILL || op == OP_PRESENT ||
                        op == OP_LOAD_SDRAM || (op == OP_PRESENT_QUEUED && c_dst_addr <= 32'd3) ||
                        ((op == OP_SPRITE_BATCH || op == OP_FILL_BATCH) && f_batch_ok);
    wire f_accept = cmd_valid && cmd_ready;

    logic f_blit, f_copy, f_blend, f_batch, f_fill, f_load, f_flip, f_legacy;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            {f_blit, f_copy, f_blend, f_batch, f_fill, f_load, f_flip, f_legacy} <= '0;
        end else begin
            if (blit_start) f_blit <= 1'b1; else if (blit_done) f_blit <= 1'b0;
            if (copy_start) f_copy <= 1'b1; else if (copy_done) f_copy <= 1'b0;
            if (blend_start) f_blend <= 1'b1; else if (blend_done) f_blend <= 1'b0;
            if (batch_start) f_batch <= 1'b1; else if (batch_done) f_batch <= 1'b0;
            if (fill_batch_start) f_fill <= 1'b1; else if (fill_batch_done) f_fill <= 1'b0;
            if (loader_start) f_load <= 1'b1; else if (loader_done) f_load <= 1'b0;
            if (present_start) begin
                f_flip   <= 1'b1;
                f_legacy <= !present_queued;
            end else if (f_flip && f_past_start && !present_busy) begin
                f_flip   <= 1'b0;
            end
        end
    end
    // f_past_start: the flip has been busy at least once since its start.
    logic f_past_start;
    always_ff @(posedge clk or posedge reset)
        if (reset) f_past_start <= 1'b0;
        else if (present_start) f_past_start <= 1'b0;
        else if (f_flip) f_past_start <= 1'b1;

    always_comb begin
        if (!f_blit) assume(!blit_busy && !blit_done);
        if (!f_copy) assume(!copy_busy && !copy_done);
        if (!f_blend) assume(!blend_busy && !blend_done);
        if (!f_batch) assume(!batch_busy && !batch_done);
        if (!f_fill) assume(!fill_batch_busy && !fill_batch_done);
        if (!f_load) assume(!loader_busy && !loader_done);
        if (!f_flip) assume(!present_busy && !present_done);
        if (f_flip && !f_past_start) assume(present_busy);
        if (present_done) assume(f_flip && f_legacy && f_past_start && !present_busy);
    end
    logic f_busy_q;
    always_ff @(posedge clk or posedge reset)
        if (reset) f_busy_q <= 1'b0;
        else f_busy_q <= present_busy;
    // A finished flip does not become busy again by itself, and a legacy
    // flip ends exactly when it reports done.
    always_comb if (f_past_valid && !reset) begin
        if (f_flip && f_past_start && !f_busy_q) assume(!present_busy);
        if (f_flip && f_legacy && f_past_start && f_busy_q && !present_busy) assume(present_done);
    end

    // Completion accounting, as link_fence counts it for CMDQ's commands.
    wire f_complete = blit_done || copy_done || blend_done || batch_done || fill_batch_done ||
                      loader_done || present_done || present_accept;
    wire [6:0] f_engine_starts = {blit_start, copy_start, blend_start, batch_start,
                                  fill_batch_start, loader_start, present_start};
    wire f_launch = (|f_engine_starts) || state == ACCEPT_PRESENT;
    // An engine counts as running from its start pulse until its done.
    wire [6:0] f_running = {f_blit || blit_start, f_copy || copy_start, f_blend || blend_start,
                            f_batch || batch_start, f_fill || fill_batch_start,
                            f_load || loader_start,
                            (f_flip && f_legacy) || (present_start && !present_queued)};
    wire [6:0] f_active_onehot =
        active_engine == ENGINE_BLIT ? 7'b1000000 : active_engine == ENGINE_COPY ? 7'b0100000 :
        active_engine == ENGINE_BLEND ? 7'b0010000 : active_engine == ENGINE_BATCH ? 7'b0001000 :
        active_engine == ENGINE_FILL_BATCH ? 7'b0000100 : active_engine == ENGINE_LOAD ? 7'b0000010 :
        active_engine == ENGINE_PRESENT ? 7'b0000001 : 7'b0000000;
    logic [1:0] f_outstanding;
    logic       f_accepted_recognized;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            f_outstanding <= 2'd0;
            f_accepted_recognized <= 1'b0;
        end else begin
            f_outstanding <= f_outstanding + {1'b0, f_accept && f_recognized} - {1'b0, f_complete};
            f_accepted_recognized <= f_accept && f_recognized;
        end
    end

    always_comb if (f_past_valid && !reset) begin
        // cmd_ready never depends on cmd_data while no command is offered.
        if (!cmd_valid) assert(cmd_ready == (state == IDLE && !engine_busy));
        // At most one command is in flight, and a completion never arrives
        // without one. CMDQ offers ready only once its command has completed
        // or completes on that same cycle (a queued PRESENT's acceptance).
        assert(f_outstanding <= 2'd1);
        if (f_complete) assert(f_outstanding == 2'd1);
        if (cmd_ready) assert(f_outstanding == {1'b0, f_complete});
        // Exactly one engine start or queued-flip acceptance follows each
        // recognized command, and nothing else starts an engine.
        assert($onehot0(f_engine_starts));
        assert(f_launch == f_accepted_recognized);
        // A PRESENT of either kind is never accepted while a flip is pending,
        // and no engine is started while it is still running a command.
        if (f_accept && present_op) assert(!present_busy);
        if (present_start) assert(!present_busy && !f_flip);
        if (blit_start) assert(!f_blit);
        if (copy_start) assert(!f_copy);
        if (blend_start) assert(!f_blend);
        if (batch_start) assert(!f_batch);
        if (fill_batch_start) assert(!f_fill);
        if (loader_start) assert(!f_load);
        // Inductive link between the model and CMDQ's own state; a queued
        // flip may still be running in the background.
        if (state == IDLE) assert(f_outstanding == {1'b0, present_accept} && f_running == 7'd0);
        if (state == ACCEPT_PRESENT) assert(f_outstanding == 2'd1 && f_running == 7'd0 &&
                                            active_engine == ENGINE_NONE && !present_accept);
        // CMDQ acts on an offered command exactly when it reports ready, so
        // link_ring's handshake and CMDQ's dispatch always agree.
        if (state == IDLE && cmd_valid)
            assert(cmd_ready == (!blit_busy && !copy_busy && !blend_busy && !present_blocked));
        // A background queued flip never coexists with a legacy PRESENT as
        // CMDQ's last engine, since no PRESENT is accepted while one is busy.
        if (f_flip && !f_legacy) assert(active_engine != ENGINE_PRESENT);
        // A remembered completion never outlives the command it belongs to,
        // so a new command cannot inherit an earlier engine's done.
        if (state != WAIT_DONE) assert(!engine_done_seen);
        // A start pulse occurs only on the first cycle after acceptance: a
        // queued flip's in ACCEPT_PRESENT, any other in WAIT_DONE for the
        // engine that pulse starts.
        if (present_start && present_queued) assert(state == ACCEPT_PRESENT);
        if ((|f_engine_starts) && !(present_start && present_queued))
            assert(state == WAIT_DONE && !engine_done_seen && f_outstanding == 2'd1 &&
                   f_engine_starts == f_active_onehot);
        if (state == WAIT_DONE) begin
            assert(active_engine != ENGINE_NONE && !present_accept);
            assert(f_outstanding == {1'b0, !engine_done_seen});
            assert(f_running == (engine_done_seen ? 7'd0 : f_active_onehot));
        end
    end

    // Reachability checks (fv/cmdq.sby cover task): the assumptions still
    // allow every command kind to complete, unknown commands to be dropped
    // and drawing to proceed while a queued flip waits for vertical blank.
    always_comb if (f_past_valid && !reset) begin
        cover(f_accept && !f_recognized);
        cover(blit_done);
        cover(copy_done);
        cover(blend_done);
        cover(batch_done);
        cover(fill_batch_done);
        cover(loader_done);
        cover(present_done);
        cover(present_accept && !present_busy);
        cover(state == WAIT_DONE && engine_done_seen);
        cover(f_flip && !f_legacy && present_busy && (blit_start || copy_start || batch_start));
        cover(f_flip && !f_legacy && present_busy && cmd_valid && present_op && !cmd_ready);
    end
`endif

endmodule
