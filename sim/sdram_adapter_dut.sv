// Simulation-only exposure of sdram_adapter's ports, for
// tb_sdram_adapter.cpp.
//
// The sd_* mock below is NOT rtl/sdram.sv itself -- that file instantiates
// real Cyclone-V altddio_out primitives Verilator cannot elaborate. It is
// a small behavioral model of sdram.sv's own documented normal-port
// protocol (traced from its STATE_IDLE/STATE_WAIT/STATE_RW logic): sel&rd
// accepted for one cycle, sd_ready drops one cycle later, then rises again
// after a configurable delay with sd_dout holding a value derived
// reversibly from the requested address, and stays high (with dout
// unchanged) until the next request is accepted. This lets
// sdram_adapter's own 4-step sequencer and address math be verified
// end-to-end without needing real SDRAM IP in simulation.
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

    // Exposed for the testbench to check each of the 4 sub-word accesses
    // actually reached the mock with the right address and in order.
    output logic [25:0]  sd_addr_probe,
    output logic         sd_accept_probe
);

    logic        sd_sel, sd_rd, sd_ready;
    logic [25:0] sd_addr;
    logic [15:0] sd_dout;

    assign sd_addr_probe   = sd_addr;
    assign sd_accept_probe = sd_sel && sd_rd && sd_ready;

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

    always_ff @(posedge clk_sdram or posedge reset_b) begin
        if (reset_b) begin
            mstate       <= M_IDLE;
            mcount       <= '0;
            sd_ready     <= 1'b1;
            sd_dout      <= '0;
            addr_latched <= '0;
        end else begin
            case (mstate)
                M_IDLE: if (sd_sel && sd_rd) begin
                    addr_latched <= sd_addr;
                    sd_ready     <= 1'b0;
                    mcount       <= mock_delay;
                    mstate       <= M_BUSY;
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
