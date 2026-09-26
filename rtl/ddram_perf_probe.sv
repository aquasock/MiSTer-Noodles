// Temporary DDRAM cadence probe. Counts the physical Avalon-MM traffic for
// one direct fill, copy, or blend command and publishes a snapshot only after
// that engine and the adapter have drained. The publication therefore cannot
// affect the interval being measured.
module ddram_perf_probe #(
    parameter logic [31:0] SNAP_ADDR = 32'h3005_0000
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        fill_start,
    input  logic        fill_done,
    input  logic        copy_start,
    input  logic        copy_done,
    input  logic        blend_start,
    input  logic        blend_done,
    input  logic        adapter_idle,

    input  logic        ddram_busy,
    input  logic [7:0]  ddram_burstcnt,
    input  logic        ddram_rd,
    input  logic        ddram_we,
    input  logic        ddram_dout_ready,

    output logic [31:0] wr_addr,
    output logic [31:0] wr_data,
    output logic        wr_en,
    input  logic        wr_ready
);
    localparam logic [31:0] MAGIC = 32'h4e44_5046; // "NDPF"

    logic        active, done_seen;
    logic [7:0]  kind, snapshot_seq;
    logic [31:0] cycles, command_cycles, stalled_cycles;
    logic [31:0] busy_cycles, idle_cycles;
    logic [31:0] read_commands, read_words, read_responses, write_beats;
    logic [7:0]  max_read_burst;

    logic [31:0] snap_cycles, snap_command_cycles, snap_stalled_cycles;
    logic [31:0] snap_busy_cycles, snap_idle_cycles;
    logic [31:0] snap_read_commands, snap_read_words;
    logic [31:0] snap_read_responses, snap_write_beats;
    logic [7:0]  snap_kind, snap_max_read_burst;

    logic        publish;
    logic [3:0]  publish_index;

    wire start_any = fill_start || copy_start || blend_start;
    wire [7:0] start_kind = fill_start ? 8'd1 : copy_start ? 8'd2 : 8'd3;
    wire selected_done = (kind == 8'd1 && fill_done) ||
                         (kind == 8'd2 && copy_done) ||
                         (kind == 8'd3 && blend_done);
    wire command = ddram_rd || ddram_we;
    wire accepted_read = ddram_rd && !ddram_busy;
    wire accepted_write = ddram_we && !ddram_busy;

    // Words 2-11 are written first, then word 0, and word 1 last. A host can
    // treat a changed sequence in word 1 as the atomic publication point.
    always_comb begin
        wr_en = publish;
        unique case (publish_index)
            4'd0: begin wr_addr = SNAP_ADDR + 32'd8;  wr_data = snap_cycles; end
            4'd1: begin wr_addr = SNAP_ADDR + 32'd12; wr_data = snap_command_cycles; end
            4'd2: begin wr_addr = SNAP_ADDR + 32'd16; wr_data = snap_stalled_cycles; end
            4'd3: begin wr_addr = SNAP_ADDR + 32'd20; wr_data = snap_busy_cycles; end
            4'd4: begin wr_addr = SNAP_ADDR + 32'd24; wr_data = snap_idle_cycles; end
            4'd5: begin wr_addr = SNAP_ADDR + 32'd28; wr_data = snap_read_commands; end
            4'd6: begin wr_addr = SNAP_ADDR + 32'd32; wr_data = snap_read_words; end
            4'd7: begin wr_addr = SNAP_ADDR + 32'd36; wr_data = snap_read_responses; end
            4'd8: begin wr_addr = SNAP_ADDR + 32'd40; wr_data = snap_write_beats; end
            4'd9: begin wr_addr = SNAP_ADDR + 32'd44; wr_data = {24'd0, snap_max_read_burst}; end
            4'd10: begin wr_addr = SNAP_ADDR;         wr_data = MAGIC; end
            default: begin
                wr_addr = SNAP_ADDR + 32'd4;
                wr_data = {snapshot_seq, 16'd0, snap_kind};
            end
        endcase
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            active <= 1'b0;
            done_seen <= 1'b0;
            kind <= 8'd0;
            snapshot_seq <= 8'd0;
            cycles <= 32'd0;
            command_cycles <= 32'd0;
            stalled_cycles <= 32'd0;
            busy_cycles <= 32'd0;
            idle_cycles <= 32'd0;
            read_commands <= 32'd0;
            read_words <= 32'd0;
            read_responses <= 32'd0;
            write_beats <= 32'd0;
            max_read_burst <= 8'd0;
            snap_cycles <= 32'd0;
            snap_command_cycles <= 32'd0;
            snap_stalled_cycles <= 32'd0;
            snap_busy_cycles <= 32'd0;
            snap_idle_cycles <= 32'd0;
            snap_read_commands <= 32'd0;
            snap_read_words <= 32'd0;
            snap_read_responses <= 32'd0;
            snap_write_beats <= 32'd0;
            snap_kind <= 8'd0;
            snap_max_read_burst <= 8'd0;
            publish <= 1'b0;
            publish_index <= 4'd0;
        end else begin
            if (!active && !publish && start_any) begin
                active <= 1'b1;
                done_seen <= 1'b0;
                kind <= start_kind;
                cycles <= 32'd0;
                command_cycles <= 32'd0;
                stalled_cycles <= 32'd0;
                busy_cycles <= 32'd0;
                idle_cycles <= 32'd0;
                read_commands <= 32'd0;
                read_words <= 32'd0;
                read_responses <= 32'd0;
                write_beats <= 32'd0;
                max_read_burst <= 8'd0;
            end else if (active) begin
                cycles <= cycles + 32'd1;
                if (command) command_cycles <= command_cycles + 32'd1;
                else idle_cycles <= idle_cycles + 32'd1;
                if (ddram_busy) busy_cycles <= busy_cycles + 32'd1;
                if (command && ddram_busy)
                    stalled_cycles <= stalled_cycles + 32'd1;
                if (accepted_read) begin
                    read_commands <= read_commands + 32'd1;
                    read_words <= read_words + {24'd0, ddram_burstcnt};
                    if (ddram_burstcnt > max_read_burst)
                        max_read_burst <= ddram_burstcnt;
                end
                if (ddram_dout_ready)
                    read_responses <= read_responses + 32'd1;
                if (accepted_write)
                    write_beats <= write_beats + 32'd1;
                if (selected_done)
                    done_seen <= 1'b1;

                if ((selected_done || done_seen) && adapter_idle) begin
                    active <= 1'b0;
                    done_seen <= 1'b0;
                    snapshot_seq <= snapshot_seq + 8'd1;
                    // Include this final active cycle in the time and in any
                    // event whose physical signal is asserted on it.
                    snap_cycles <= cycles + 32'd1;
                    snap_command_cycles <= command_cycles + {31'd0, command};
                    snap_stalled_cycles <= stalled_cycles + {31'd0, command && ddram_busy};
                    snap_busy_cycles <= busy_cycles + {31'd0, ddram_busy};
                    snap_idle_cycles <= idle_cycles + {31'd0, !command};
                    snap_read_commands <= read_commands + {31'd0, accepted_read};
                    snap_read_words <= read_words + (accepted_read ? {24'd0, ddram_burstcnt} : 32'd0);
                    snap_read_responses <= read_responses + {31'd0, ddram_dout_ready};
                    snap_write_beats <= write_beats + {31'd0, accepted_write};
                    snap_kind <= kind;
                    snap_max_read_burst <= accepted_read && ddram_burstcnt > max_read_burst
                                           ? ddram_burstcnt : max_read_burst;
                    publish <= 1'b1;
                    publish_index <= 4'd0;
                end
            end

            if (publish && wr_ready) begin
                if (publish_index == 4'd11) begin
                    publish <= 1'b0;
                    publish_index <= 4'd0;
                end else begin
                    publish_index <= publish_index + 4'd1;
                end
            end
        end
    end
endmodule
