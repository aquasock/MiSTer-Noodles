// Registered request queues for the shared DDRAM Avalon-MM port.
//
// Client requests are captured before arbitration, so DDRAM_BUSY cannot
// change a client's valid/ready handshake and no client signal is fed back
// through the physical-bus grant. Reads retain ordered response metadata.
//
// DDR-007: the 64-bit read port gained an explicit rd64_len field so a
// client (blit_copy64/sprite_batch) can declare up front "read N contiguous
// words", issued as a single Avalon burst (ddram_burstcnt=N) instead of N
// separate burstcnt=1 commands. This is deliberately NOT after-the-fact
// contiguity detection over an already-queued run: this adapter drains its
// read queue combinationally as fast as a client can fill it, so a producer
// issuing one word per cycle never actually lets a multi-entry run build up
// for the adapter to discover -- only an explicit, atomic N-word request
// from the producer itself forms a real burst. The real DDR3 controller
// amortizes row-activation/CAS command overhead across a burst's beats,
// streaming N sequential words back after one accepted command with no
// further command required -- the same assumption aquasock/MiSTer-Raster's
// proven DDR arbiter (mpeg2_h262_ddram_arbiter.sv) already relies on.
// Scalar (32-bit) reads always have an implicit length of 1, unchanged from
// before. Contiguous full-word writes are likewise gathered explicitly in
// the queue and emitted as one Avalon write burst. Partial or discontinuous
// writes retain their original single-beat shape.

module ddram_adapter (
    input  logic         clk,
    input  logic         reset,

    input  logic [31:0]  wr_addr,
    input  logic [31:0]  wr_data,
    input  logic         wr_en,
    output logic         wr_ready,
    input  logic [31:0]  wr64_addr,
    input  logic [63:0]  wr64_data,
    input  logic         wr64_en,
    output logic         wr64_ready,
    // Registered queue space. Multiplexed callers derive each client's ready
    // from this and that client's own requests, so no client's request logic
    // reaches another client's ready through the shared wr64_en term below.
    output logic         wr_space,

    input  logic [31:0]  rd_addr,
    input  logic         rd_en,
    output logic         rd_ready,
    output logic [31:0]  rd_data,
    output logic         rd_valid,
    input  logic [31:0]  rd64_addr,
    input  logic         rd64_en,
    input  logic [7:0]   rd64_len,
    output logic         rd64_ready,
    output logic [63:0]  rd64_data,
    output logic         rd64_valid,

    output logic         ddram_clk,
    input  logic         ddram_busy,
    output logic [7:0]   ddram_burstcnt,
    output logic [28:0]  ddram_addr,
    input  logic [63:0]  ddram_dout,
    input  logic         ddram_dout_ready,
    output logic [63:0]  ddram_din,
    output logic [7:0]   ddram_be,
    output logic         ddram_we,
    output logic         ddram_rd,
    output logic         idle
);

    // DEPTH bounds both the descriptor queue (one entry per accepted
    // request, regardless of its word length) and the total number of
    // response words that may be outstanding across all queued descriptors
    // combined -- a single rd64 request may itself claim up to DEPTH words.
    localparam int DEPTH = 16;
    localparam int PTR_W = $clog2(DEPTH);
    localparam int MAX_BURST = DEPTH;
    localparam int WRITE_BURST_MAX = 8;

    logic [31:0] wr_addr_q [0:DEPTH-1];
    logic [63:0] wr_data_q [0:DEPTH-1];
    logic        wr_full_q [0:DEPTH-1];
    logic [PTR_W-1:0] wr_head;
    logic [DEPTH-1:0] wr_tail, wr_slot_en;  // one-hot reservation and delayed commit
    logic [31:0] wr_ingress_addr;
    logic [63:0] wr_ingress_data;
    logic wr_ingress_full, wr_pending;
    // Counts all accepted writes, including the reserved ingress slot.
    logic [PTR_W:0] wr_count;

    logic [31:0] rd_addr_q [0:DEPTH-1];
    logic        rd_is64_q [0:DEPTH-1];
    logic        rd_half_q [0:DEPTH-1];
    logic [7:0]  rd_len_q  [0:DEPTH-1];
    logic [PTR_W-1:0] rd_head, rd_tail;
    logic [PTR_W:0] rd_count;
    // Read ingress: an accepted request is captured here and committed to
    // the queue on the next cycle, so client request logic never drives the
    // queue's write decode. rd_count reserves the slot at acceptance.
    logic        rd_in_valid, rd_in_is64, rd_in_half;
    logic [31:0] rd_in_addr;
    logic [7:0]  rd_in_len;

    logic        rsp_is64_q [0:DEPTH-1];
    logic        rsp_half_q [0:DEPTH-1];
    logic [PTR_W-1:0] rsp_head, rsp_tail;
    logic [PTR_W:0] rsp_count;

    // DDR-007 fairness: a burst request can now keep rd_count non-zero for
    // long stretches (blit_copy64 immediately re-fills its FIFO the moment
    // any slot frees up), which would starve writes forever under the old
    // "read always wins whenever any read is queued" priority -- queued
    // writes would sit in wr_addr_q/wr_data_q indefinitely, never actually
    // reaching the DDRAM_WE/DDRAM_DIN pins. rr is a free-running toggle
    // that alternates which side wins the single shared command slot on
    // cycles where BOTH have pending work, guaranteeing every queued write
    // is issued within a bounded number of cycles regardless of how
    // continuously reads are being requested.
    logic rr;

    wire wr_fire   = wr_en && wr_ready;
    wire wr64_fire = wr64_en && wr64_ready;
    wire rd_fire   = rd_en && rd_ready;
    wire rd64_fire = rd64_en && rd64_ready;

    // Total response-word space already spoken for: words waiting to be
    // consumed plus the declared lengths of descriptors already queued but
    // not yet issued. A new request may only be admitted if it still fits
    // within DEPTH once that full commitment is counted -- not just against
    // the current rsp_count -- so multiple in-flight descriptors (of any
    // length) can never collectively overrun the response arrays.
    //
    // Maintained as a running counter rather than recomputed every cycle.
    // It was previously a combinational MAX_BURST-iteration accumulator
    // that walked the descriptor queue from rd_head, summing a 16:1 mux of
    // rd_len_q per iteration into a serial adder chain -- roughly 40ns of
    // ripple, which fit under clk_sys's old 50ns period at 20MHz but blows
    // through it by 25ns at 65MHz. A latent hazard masked by the slow clock,
    // exactly like the sdram_cdc constraint gap.
    //
    // The running form is exactly equivalent because the issue step is
    // self-cancelling: when a descriptor is issued it leaves the pending
    // sum and enters rsp_count by the same head_len, so the total only
    // changes when a descriptor is admitted (+its length) or a response
    // word is consumed (-1). Underflow is impossible: read_rsp requires
    // rsp_count != 0, which implies a nonzero commitment.
    logic [8:0] rsp_committed;
    wire  [8:0] admit_words = rd64_fire ? {1'b0, rd64_len} : 9'd1;

    // A single ingress accepts one lane per cycle; paired writes take priority.
    assign wr_space   = (wr_count < DEPTH);
    assign wr_ready   = wr_space && !wr64_en;
    assign wr64_ready = wr_space;
    assign rd_ready   = (rd_count < DEPTH) && (rsp_committed + 9'd1 <= 9'(DEPTH));
    assign rd64_ready = (rd_count < DEPTH) &&
                        (rsp_committed + {1'b0, rd64_len} <= 9'(DEPTH));

    wire [7:0] head_len = (rd_count != 0 && rd_is64_q[rd_head]) ? rd_len_q[rd_head] : 8'd1;
    wire [PTR_W:0] wr_committed = wr_count -
        (wr_pending ? (PTR_W+1)'(1) : (PTR_W+1)'(0));
    wire want_read = (rd_count != 0) && ((rd_count != 1) || !rd_in_valid);

    // A producer that supplies one word per cycle never lets the old queue
    // grow: each entry was issued as soon as it committed. Gather up to eight
    // committed, contiguous full words before starting a transaction. When
    // ingress pauses, flush any shorter run immediately. Scalar and sparse
    // writes never wait for a full burst, and pending reads may force a short
    // write run so the existing round-robin arbitration remains bounded.
    logic [7:0] write_burst_len;
    always_comb begin
        write_burst_len = 8'd1;
        for (int i = 1; i < WRITE_BURST_MAX; i++) begin
            if (wr_committed > (PTR_W+1)'(i) &&
                write_burst_len == 8'(i) &&
                wr_full_q[wr_head] &&
                wr_full_q[wr_head + PTR_W'(i)] &&
                wr_addr_q[wr_head + PTR_W'(i)] ==
                    wr_addr_q[wr_head] + 32'(i * 8))
                write_burst_len = 8'(i + 1);
        end
    end
    wire write_ingress = wr_fire || wr64_fire;
    wire write_flush = (wr_committed >= (PTR_W+1)'(WRITE_BURST_MAX)) ||
                       (!wr_pending && !write_ingress) ||
                       (wr_committed != 0 && !wr_full_q[wr_head]) ||
                       want_read;
    wire want_write = (wr_committed != 0) && write_flush;
    // Choose the payload without bridge backpressure. Gating the address
    // mux with busy creates a bridge-ready -> address -> bridge-input path.
    // Busy still gates command acceptance and queue advancement.
    wire select_read = want_read && (!want_write || rr);
    wire select_write = want_write && (!want_read || !rr);
    // Read data is registered once before it fans out to the clients.
    logic        rsp_valid_q;
    logic [63:0] rsp_data_q;
    wire read_rsp = rsp_valid_q && (rsp_count != 0);
    // Response metadata for an issued read is written one cycle after the
    // issue, from these registered copies, so the queue's length RAM does
    // not feed the per-word metadata writes. The command reaches the port
    // only on the following cycle, so no response can overtake it.
    logic        meta_valid, meta_is64, meta_half;
    logic [7:0]  meta_len;

    // Registered Avalon command stage. The queue heads' wide multiplexers
    // feed this register rather than the HPS F2SDRAM port, and DDRAM_BUSY
    // reaches only the stage's load enable. The stage reloads when it is
    // empty or when the port accepts its command, so commands still issue
    // on consecutive cycles; a queued request reaches the port one cycle
    // later than before. Dequeueing into the stage is what "issue" means
    // for the queues and the response metadata below.
    logic        cmd_valid, cmd_read;
    logic [28:0] cmd_addr;
    logic [7:0]  cmd_burstcnt, cmd_be, cmd_write_left;
    logic [63:0] cmd_din;
    wire cmd_accept = cmd_valid && !ddram_busy;
    wire read_accept = cmd_accept && cmd_read;
    wire write_accept = cmd_accept && !cmd_read;
    // An accepted read may be replaced without a bubble. A write burst owns
    // the stage until its last data beat; the following command starts one
    // cycle later because the next queue head is not visible until that edge.
    wire cmd_load = !cmd_valid || read_accept;
    wire read_issue = select_read && cmd_load;
    wire write_issue = select_write && cmd_load;

    assign ddram_clk = clk;
    // A read command's burstcnt spans head_len contiguous words -- 1 for a
    // scalar read or any 64-bit request that declared no extra length --
    // and the real Avalon-MM target auto-increments its own address and
    // streams that many beats back with no further command from this
    // adapter. A write burst holds address and burstcnt while advancing its
    // data and byte enable on each accepted beat, as Avalon-MM requires.
    assign ddram_burstcnt = cmd_burstcnt;
    assign ddram_rd = cmd_valid && cmd_read;
    assign ddram_we = cmd_valid && !cmd_read;
    assign ddram_addr = cmd_addr;
    assign ddram_be = cmd_be;
    assign ddram_din = cmd_din;
    assign idle = (wr_count == 0) && (rd_count == 0) &&
                  (rsp_count == 0) && !cmd_valid && !ddram_busy;

    assign rd_valid = read_rsp && !rsp_is64_q[rsp_head];
    assign rd64_valid = read_rsp && rsp_is64_q[rsp_head];
    assign rd_data = rsp_half_q[rsp_head] ? rsp_data_q[63:32] : rsp_data_q[31:0];
    assign rd64_data = rsp_data_q;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            rr <= 1'b0;
            wr_head <= 0;
            wr_tail <= {{(DEPTH-1){1'b0}}, 1'b1};
            wr_slot_en <= '0;
            wr_pending <= 1'b0;
            wr_count <= 0;
            rd_head <= 0;
            rd_tail <= 0;
            rd_count <= 0;
            rsp_head <= 0;
            rsp_tail <= 0;
            rsp_count <= 0;
            rsp_committed <= 0;
            rsp_valid_q <= 1'b0;
            rsp_data_q <= '0;
            rd_in_valid <= 1'b0;
            rd_in_is64 <= 1'b0;
            rd_in_half <= 1'b0;
            rd_in_addr <= '0;
            rd_in_len <= 8'd1;
            meta_valid <= 1'b0;
            meta_is64 <= 1'b0;
            meta_half <= 1'b0;
            meta_len <= 8'd0;
            cmd_valid <= 1'b0;
            cmd_read <= 1'b0;
            cmd_addr <= '0;
            cmd_burstcnt <= 8'd1;
            cmd_be <= '0;
            cmd_din <= '0;
            cmd_write_left <= 8'd0;
        end else begin
            rr <= !rr;
            rsp_valid_q <= ddram_dout_ready;
            rsp_data_q <= ddram_dout;
            meta_valid <= read_issue;
            meta_is64 <= rd_is64_q[rd_head];
            meta_half <= rd_half_q[rd_head];
            meta_len <= head_len;
            if (cmd_valid && !cmd_read) begin
                if (!ddram_busy) begin
                    if (cmd_write_left > 8'd1) begin
                        cmd_write_left <= cmd_write_left - 8'd1;
                        cmd_be <= wr_full_q[wr_head + PTR_W'(1)] ? 8'hff :
                                  (wr_addr_q[wr_head + PTR_W'(1)][2] ? 8'hf0 : 8'h0f);
                        cmd_din <= wr_full_q[wr_head + PTR_W'(1)] ?
                                   wr_data_q[wr_head + PTR_W'(1)] :
                                   (wr_addr_q[wr_head + PTR_W'(1)][2] ?
                                    {wr_data_q[wr_head + PTR_W'(1)][31:0], 32'b0} :
                                    {32'b0, wr_data_q[wr_head + PTR_W'(1)][31:0]});
                    end else begin
                        cmd_valid <= 1'b0;
                        cmd_write_left <= 8'd0;
                    end
                end
            end else if (cmd_load) begin
                cmd_valid <= read_issue || write_issue;
                cmd_read <= select_read;
                cmd_addr <= select_read ? rd_addr_q[rd_head][31:3] : wr_addr_q[wr_head][31:3];
                cmd_burstcnt <= select_read ? head_len : write_burst_len;
                cmd_be <= wr_full_q[wr_head] ? 8'hff : (wr_addr_q[wr_head][2] ? 8'hf0 : 8'h0f);
                cmd_din <= wr_full_q[wr_head] ? wr_data_q[wr_head] :
                           (wr_addr_q[wr_head][2] ? {wr_data_q[wr_head][31:0], 32'b0} :
                                                    {32'b0, wr_data_q[wr_head][31:0]});
                cmd_write_left <= write_issue ? write_burst_len : 8'd0;
            end
            // Every accepted write reserves its slot before the next-cycle
            // commit. Producer decisions never drive the queue's wide enables.
            wr_pending <= write_ingress;
            wr_slot_en <= wr_tail & {DEPTH{write_ingress}};
            if (write_ingress) begin
                wr_ingress_addr <= wr64_fire ? wr64_addr : wr_addr;
                wr_ingress_data <= wr64_fire ? wr64_data : {32'b0, wr_data};
                wr_ingress_full <= wr64_fire;
                wr_tail <= {wr_tail[DEPTH-2:0], wr_tail[DEPTH-1]};
            end
            for (int i = 0; i < DEPTH; i++) begin
                if (wr_slot_en[i]) begin
                    wr_addr_q[i] <= wr_ingress_addr;
                    wr_data_q[i] <= wr_ingress_data;
                    wr_full_q[i] <= wr_ingress_full;
                end
            end
            if (write_accept)
                wr_head <= wr_head + 1'b1;
            case ({write_ingress, write_accept})
                2'b10: wr_count <= wr_count + 1'b1;
                2'b01: wr_count <= wr_count - 1'b1;
                default: ;
            endcase

            rd_in_valid <= rd_fire || rd64_fire;
            if (rd_fire || rd64_fire) begin
                rd_in_addr <= rd64_fire ? rd64_addr : rd_addr;
                rd_in_is64 <= rd64_fire;
                rd_in_half <= rd64_fire ? 1'b0 : rd_addr[2];
                rd_in_len  <= rd64_fire ? rd64_len : 8'd1;
            end
            if (rd_in_valid) begin
                rd_addr_q[rd_tail] <= rd_in_addr;
                rd_is64_q[rd_tail] <= rd_in_is64;
                rd_half_q[rd_tail] <= rd_in_half;
                rd_len_q[rd_tail]  <= rd_in_len;
                rd_tail <= rd_tail + 1'b1;
            end
            if (read_issue)
                rd_head <= rd_head + 1'b1;
            case ({rd_fire || rd64_fire, read_issue})
                2'b10: rd_count <= rd_count + 1'b1;
                2'b01: rd_count <= rd_count - 1'b1;
                default: ;
            endcase

            if (meta_valid) begin
                for (int i = 0; i < MAX_BURST; i++) begin
                    if (i < int'(meta_len)) begin
                        rsp_is64_q[rsp_tail + i[PTR_W-1:0]] <= meta_is64;
                        rsp_half_q[rsp_tail + i[PTR_W-1:0]] <= meta_half;
                    end
                end
                rsp_tail <= rsp_tail + meta_len[PTR_W-1:0];
            end
            if (read_rsp)
                rsp_head <= rsp_head + 1'b1;
            // head_len is at most DEPTH, which fits in rsp_count's own
            // width without truncation -- unlike the tail-pointer advance
            // above, this accumulator needs the untruncated magnitude, not
            // a mod-DEPTH wraparound.
            rsp_count <= rsp_count + (read_issue ? (PTR_W+1)'(head_len) : (PTR_W+1)'(0))
                                    - (read_rsp ? (PTR_W+1)'(1) : (PTR_W+1)'(0));
            rsp_committed <= rsp_committed
                             + ((rd_fire || rd64_fire) ? admit_words : 9'd0)
                             - (read_rsp ? 9'd1 : 9'd0);
        end
    end

endmodule
