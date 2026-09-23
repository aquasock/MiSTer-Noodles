// Simulation-only exposure of sdram_loader's ports, for
// tb_sdram_loader.cpp.
//
// Two mocks stand in for the real hardware sdram_loader talks to (same
// rationale as sdram_adapter_dut.sv: the real modules use Cyclone-V
// primitives Verilator cannot elaborate):
//
//  - A single-outstanding rd64 responder mock, standing in for
//    ddram_adapter's real (client-facing) contract: rd64_ready high when
//    idle, drops on acceptance, and rd64_valid pulses after a
//    configurable delay with rd64_data derived reversibly from the
//    requested address -- lets the testbench reconstruct exactly what
//    "DDR3 contents" the loader believed it read.
//
//  - A faithful behavioral model of sdram.sv's own copy-port protocol,
//    traced from its STATE_IDLE/STATE_WAITCP/STATE_CP logic (see
//    sdram_loader.sv's header): accepts cpreq's rising edge while cpsel
//    is high, asserts cpbusy, asserts cprd for exactly 513 cycles (1
//    WAITCP + 512 CP), sampling cpdin every one of the 512 CP cycles
//    into a local capture buffer, then holds cpbusy high for a few extra
//    idle-wait cycles (matching sdram.sv's STATE_IDLE_4..STATE_IDLE_1
//    tail) before dropping it -- exercising the loader's edge-triggered
//    (not fixed-count) completion detection.
module sdram_loader_dut (
    input  logic        clk_sys,
    input  logic         reset,
    input  logic         start,
    input  logic [31:0]  src_addr,
    input  logic [31:0]  dst_addr,
    input  logic [31:0]  length,
    output logic         busy,
    output logic         done,
    input  logic [7:0]   ddr_mock_delay,

    input  logic        clk_sdram,
    input  logic         reset_b,

    // SDR-004's refresh-hang fix (sdram_adapter.sv) revealed the same
    // one-cycle-pulse anti-pattern on this module's own cpreq write
    // request -- this mock never modeled a "busy elsewhere" window
    // (sdram.sv's periodic auto-refresh, or a concurrent sdram_adapter
    // read) either, so it could not have caught it. mock_busy reproduces
    // that: while asserted, cpreq's rising edge is silently ignored
    // (old_cpreq is NOT updated, mirroring how sdram.sv's own old_cpreq
    // only advances inside STATE_IDLE's real-idle branch), exactly like
    // sdram_adapter_dut.sv's own mock_busy for sd_sel/sd_rd.
    input  logic         mock_busy,

    // Exposed for the testbench to reconstruct exactly what was written.
    output logic         cp_accept_probe,
    output logic [25:0]  cp_addr_probe,
    output logic         cp_word_valid_probe,
    output logic [8:0]   cp_word_idx_probe,
    output logic [15:0]  cp_word_data_probe
);

    // ---- rd64 (DDR3) responder mock ----
    logic [31:0] rd64_addr;
    logic        rd64_en;
    logic        rd64_active;
    logic [7:0]  rd64_len;
    logic        rd64_ready;
    logic [63:0] rd64_data;
    logic        rd64_valid;

    logic [31:0] ddr_latched_addr;
    logic [8:0]  ddr_delay_cnt;
    typedef enum logic [1:0] {DDR_IDLE, DDR_WAIT, DDR_VALID} ddr_state_t;
    ddr_state_t ddr_state;

    // Reversible, address-derived 64-bit pattern: each of the 4 16-bit
    // sub-words is {1'b1, sub_addr[14:0]} where sub_addr is the 16-bit
    // word index (byte_addr>>1)+i -- the same 0x8000|(addr&0x7FFF)
    // convention tb_sdram_adapter.cpp's ExpectedData() already uses, so
    // both mocks share one mental model.
    function automatic [63:0] ddr_pattern(input logic [31:0] byte_addr);
        logic [31:0] word_base;
        logic [31:0] sub_addr;
        logic [63:0] result;
        begin
            word_base = byte_addr >> 1;
            for (int i = 0; i < 4; i++) begin
                sub_addr = word_base + i;
                result[16*i +: 16] = {1'b1, sub_addr[14:0]};
            end
            ddr_pattern = result;
        end
    endfunction

    assign rd64_ready = (ddr_state == DDR_IDLE);
    assign rd64_valid = (ddr_state == DDR_VALID);
    assign rd64_data  = ddr_pattern(ddr_latched_addr);

    always_ff @(posedge clk_sys or posedge reset) begin
        if (reset) begin
            ddr_state        <= DDR_IDLE;
            ddr_latched_addr <= '0;
            ddr_delay_cnt    <= '0;
        end else begin
            case (ddr_state)
                DDR_IDLE: if (rd64_en) begin
                    ddr_latched_addr <= rd64_addr;
                    ddr_delay_cnt    <= {1'b0, ddr_mock_delay};
                    ddr_state        <= (ddr_mock_delay == 0) ? DDR_VALID : DDR_WAIT;
                end
                DDR_WAIT: begin
                    if (ddr_delay_cnt == 0) ddr_state <= DDR_VALID;
                    else ddr_delay_cnt <= ddr_delay_cnt - 9'd1;
                end
                DDR_VALID: ddr_state <= DDR_IDLE;
                default: ddr_state <= DDR_IDLE;
            endcase
        end
    end

    // ---- sdram.sv copy-port protocol mock ----
    logic        cpsel, cpreq, cpbusy, cprd;
    logic [26:1] cpaddr;
    logic [15:0] cpdin;

    logic        old_cpreq;
    logic [8:0]  cpcnt;
    logic [3:0]  tail_cnt;
    typedef enum logic [2:0] {
        CP_IDLE, CP_WAITCP, CP_CP, CP_TAIL
    } cp_state_t;
    cp_state_t cp_state;

    logic cp_accept_probe_r;

    assign cp_accept_probe    = cp_accept_probe_r;
    assign cp_word_valid_probe= (cp_state == CP_CP);
    assign cp_word_idx_probe  = 9'd511 - cpcnt;
    assign cp_word_data_probe = cpdin;

    always_ff @(posedge clk_sdram or posedge reset_b) begin
        if (reset_b) begin
            cp_state   <= CP_IDLE;
            old_cpreq  <= 1'b0;
            cpbusy     <= 1'b0;
            cprd       <= 1'b0;
            cpcnt      <= '0;
            tail_cnt   <= '0;
            cp_addr_probe <= '0;
            cp_accept_probe_r <= 1'b0;
        end else begin
            // cp_addr_probe is a registered capture (visible one cycle
            // after the acceptance decision below is made), so
            // cp_accept_probe_r must be delayed to line up with it --
            // otherwise the testbench would read cp_addr_probe one
            // cycle too early, seeing the *previous* page's address.
            cp_accept_probe_r <= 1'b0;
            case (cp_state)
                CP_IDLE: begin
                    cpbusy    <= 1'b0;
                    cprd      <= 1'b0;
                    if (!mock_busy) begin
                        old_cpreq <= cpreq;
                        if (~old_cpreq & cpreq & cpsel) begin
                            cp_addr_probe <= cpaddr;
                            cp_accept_probe_r <= 1'b1;
                            cpbusy   <= 1'b1;
                            cprd     <= 1'b1;
                            cpcnt    <= 9'd511;
                            cp_state <= CP_WAITCP;
                        end
                    end
                end
                CP_WAITCP: cp_state <= CP_CP;
                CP_CP: begin
                    cpcnt <= cpcnt - 9'd1;
                    if (cpcnt == 9'd0) begin
                        cprd     <= 1'b0;
                        tail_cnt <= 4'd4;
                        cp_state <= CP_TAIL;
                    end
                end
                CP_TAIL: begin
                    if (tail_cnt == 4'd0) begin
                        cpbusy   <= 1'b0;
                        cp_state <= CP_IDLE;
                    end else begin
                        tail_cnt <= tail_cnt - 4'd1;
                    end
                end
                default: cp_state <= CP_IDLE;
            endcase
        end
    end

    sdram_loader #(.ADDR_WIDTH(32)) dut (
        .clk(clk_sys), .reset(reset),
        .start(start), .src_addr(src_addr), .dst_addr(dst_addr), .length(length),
        .busy(busy), .done(done),
        .rd64_addr(rd64_addr), .rd64_en(rd64_en), .rd64_active(rd64_active), .rd64_len(rd64_len),
        .rd64_ready(rd64_ready), .rd64_data(rd64_data), .rd64_valid(rd64_valid),
        .clk_sdram(clk_sdram), .reset_b(reset_b),
        .cpsel(cpsel), .cpaddr(cpaddr), .cpdin(cpdin),
        .cprd(cprd), .cpreq(cpreq), .cpbusy(cpbusy)
    );

endmodule
