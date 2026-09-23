// Simulation-only exposure of sdram_cdc's ports, for tb_sdram_cdc.cpp.
//
// The domain-B "responder" below is NOT a timing model of rtl/sdram.sv --
// it is a deliberately simple, testbench-controlled stand-in (an
// arbitrary, per-request configurable cycle delay before completing) whose
// only job is to exercise sdram_cdc's handshake correctness under
// variable round-trip latency. Wiring the real sdram module in as the
// domain-B responder is step 4's job (sdram_adapter.sv), once this
// generic CDC bridge is proven correct on its own.
module sdram_cdc_dut (
    input  logic        clk_a,
    input  logic        reset_a,
    input  logic [31:0]  a_addr,
    input  logic         a_en,
    output logic         a_ready,
    output logic [63:0]  a_data,
    output logic         a_valid,

    input  logic        clk_b,
    input  logic        reset_b,
    input  logic [7:0]   resp_delay,

    // Exposed for the testbench to check the request actually reached
    // domain B with the right address, independent of the response path.
    output logic [31:0]  b_addr_probe,
    output logic         b_start_probe
);

    logic [31:0] b_addr;
    logic        b_start;
    logic [63:0] b_data;
    logic        b_done;

    assign b_addr_probe  = b_addr;
    assign b_start_probe = b_start;

    sdram_cdc #(.ADDR_WIDTH(32), .DATA_WIDTH(64)) cdc_i (
        .clk_a  (clk_a),
        .reset_a(reset_a),
        .a_addr (a_addr),
        .a_en   (a_en),
        .a_ready(a_ready),
        .a_data (a_data),
        .a_valid(a_valid),

        .clk_b  (clk_b),
        .reset_b(reset_b),
        .b_addr (b_addr),
        .b_start(b_start),
        .b_data (b_data),
        .b_done (b_done)
    );

    typedef enum logic [1:0] {B_IDLE, B_WAIT, B_DONE} bstate_t;
    bstate_t     bstate;
    logic [7:0]  bcount;
    logic [31:0] addr_latched;

    always_ff @(posedge clk_b or posedge reset_b) begin
        if (reset_b) begin
            bstate       <= B_IDLE;
            bcount       <= '0;
            b_data       <= '0;
            b_done       <= 1'b0;
            addr_latched <= '0;
        end else begin
            b_done <= 1'b0;
            case (bstate)
                B_IDLE: if (b_start) begin
                    addr_latched <= b_addr;
                    bcount       <= resp_delay;
                    bstate       <= (resp_delay == 8'd0) ? B_DONE : B_WAIT;
                end
                B_WAIT: begin
                    if (bcount == 8'd1) bstate <= B_DONE;
                    bcount <= bcount - 1'b1;
                end
                B_DONE: begin
                    // A reversible, address-derived pattern so the
                    // testbench can verify the response corresponds to
                    // the request it thinks it does, not just that some
                    // response arrived.
                    b_data <= {32'hCAFEF00D, addr_latched};
                    b_done <= 1'b1;
                    bstate <= B_IDLE;
                end
                default: bstate <= B_IDLE;
            endcase
        end
    end

endmodule
