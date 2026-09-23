// Simulation-only exposure of sdram_adapter's ports, for
// tb_sdram_adapter.cpp.
//
// The sd_* mock below is NOT rtl/sdram.sv itself -- that file instantiates
// real Cyclone-V altddio_out primitives Verilator cannot elaborate. It is
// a small behavioral model of sdram.sv's own documented normal-port
// protocol (traced from its STATE_IDLE/STATE_WAIT/STATE_RW logic): sel&rd
// accepted only while the mock is idle, sd_ready drops one cycle later,
// then rises again after a configurable delay with sd_dout holding a
// value derived reversibly from the requested address, and stays high
// (with dout unchanged) until the next request is accepted. This lets
// sdram_adapter's own 4-step sequencer and address math be verified
// end-to-end without needing real SDRAM IP in simulation.
//
// mock_busy additionally reproduces sdram.sv's own periodic auto-refresh/
// copy-port busy windows (STATE_RFSH/IDLE_x, STATE_WAITCP/STATE_CP): while
// asserted, sel&rd is silently IGNORED (as sdram.sv's real STATE_IDLE case
// does whenever it isn't actually the active case branch) while sd_ready
// stays high the whole time -- i.e. no visible sign of rejection at all,
// exactly like a real refresh window. sdram_adapter's sequencer must
// therefore re-issue (hold, not pulse) its request until real acceptance
// is observed; a mock that always accepted immediately (as this one used
// to, unconditionally, in M_IDLE) could never have caught the real,
// hardware-only hang this was fixed for (see sdram_adapter.sv's own
// SEQ_ISSUE comment).
module sdram_adapter_dut (
    input  logic        clk_sys,
    input  logic         reset,
    input  logic [31:0]  rd64_addr,
    input  logic         rd64_en,
    input  logic [7:0]   rd64_len,
    output logic         rd64_ready,
    output logic [63:0]  rd64_data,
    output logic         rd64_valid,

    input  logic        clk_sdram,
    input  logic         reset_b,
    input  logic [7:0]   mock_delay,
    input  logic         mock_busy,

    // Exposed for the testbench to check each of the 4 sub-word accesses
    // actually reached the mock with the right address and in order.
    output logic [25:0]  sd_addr_probe,
    output logic         sd_accept_probe
);

    logic        sd_sel, sd_rd, sd_ready;
    logic [25:0] sd_addr;
    logic [15:0] sd_dout;

    assign sd_addr_probe = sd_addr;

    sdram_adapter #(.ADDR_WIDTH(32)) dut_i (
        .clk_sys   (clk_sys),
        .reset     (reset),
        .rd64_addr (rd64_addr),
        .rd64_en   (rd64_en),
        .rd64_len  (rd64_len),
        .rd64_ready(rd64_ready),
        .rd64_data (rd64_data),
        .rd64_valid(rd64_valid),

        .clk_sdram (clk_sdram),
        .reset_b   (reset_b),
        .sd_sel    (sd_sel),
        .sd_addr   (sd_addr),
        .sd_dout   (sd_dout),
        .sd_rd     (sd_rd),
        .sd_ready  (sd_ready)
    );

    typedef enum logic [1:0] {M_IDLE, M_BUSY} mstate_t;
    mstate_t     mstate;
    logic [7:0]  mcount;
    logic [25:0] addr_latched;

    // sd_accept_probe is the mock's own registered acceptance pulse (the
    // exact cycle the M_IDLE->M_BUSY transition below fires), NOT a raw
    // combinational sd_sel&&sd_rd&&sd_ready glance: now that
    // sdram_adapter holds sd_sel/sd_rd asserted as a LEVEL until real
    // acceptance (rather than a one-shot pulse), that raw AND can stay
    // true for many consecutive cycles while sd_ready simply hasn't
    // dropped yet (including the entire mock_busy window, where it never
    // will) -- a false positive that would let a testbench believe an
    // access happened when the mock actually never left M_IDLE.
    logic accept_pulse;
    assign sd_accept_probe = accept_pulse;

    always_ff @(posedge clk_sdram or posedge reset_b) begin
        if (reset_b) begin
            mstate       <= M_IDLE;
            mcount       <= '0;
            sd_ready     <= 1'b1;
            sd_dout      <= '0;
            addr_latched <= '0;
            accept_pulse <= 1'b0;
        end else begin
            accept_pulse <= 1'b0;
            case (mstate)
                M_IDLE: if (!mock_busy && sd_sel && sd_rd) begin
                    addr_latched <= sd_addr;
                    sd_ready     <= 1'b0;
                    mcount       <= mock_delay;
                    mstate       <= M_BUSY;
                    accept_pulse <= 1'b1;
                end
                M_BUSY: begin
                    if (mcount == 8'd0) begin
                        // A reversible, address-derived pattern (address in
                        // the low 15 bits, a fixed marker bit on top) so
                        // the testbench can verify which sub-word address
                        // actually produced each captured 16-bit value.
                        sd_dout  <= {1'b1, addr_latched[14:0]};
                        sd_ready <= 1'b1;
                        mstate   <= M_IDLE;
                    end else begin
                        mcount <= mcount - 1'b1;
                    end
                end
                default: mstate <= M_IDLE;
            endcase
        end
    end

endmodule

