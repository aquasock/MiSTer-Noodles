// Adapts generic byte-addressed read and write ports onto the framework's
// real DDRAM_* pins -- a standard Avalon-MM master interface (F2H SDRAM
// bridge into HPS DDR3, see DDR-001). Replaces rtl/ddram_write_adapter.sv:
// adds a generic read port (DDR-003) alongside the existing write port,
// muxed onto the one physical bus. Read is given priority whenever both a
// read and a write are requested in the same cycle; today's clients never
// actually contend (each FSM issues at most one kind of request at a time),
// so this priority is a tie-breaker, not load-bearing arbitration -- see
// DDR-003's consequence for what changes if that stops being true.
//
// Both directions are single-word (BURSTCNT=1), 4-byte-into/out-of-8-byte-word,
// steered by address bit 2 exactly as DDR-001 originally specified for
// writes. Requires wr_addr/rd_addr to always be 4-byte aligned.

module ddram_adapter (
    input  logic         clk,

    // generic write port
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0]  wr_addr,  // [1:0] unused: 4-byte alignment required
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [31:0]  wr_data,
    input  logic         wr_en,
    output logic         wr_ready,

    // generic read port
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0]  rd_addr,  // [1:0] unused: 4-byte alignment required
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic         rd_en,
    output logic         rd_ready,
    output logic [31:0]  rd_data,
    output logic         rd_valid,

    // DDRAM_*-facing Avalon-MM master port
    output logic         ddram_clk,
    input  logic         ddram_busy,
    output logic [7:0]   ddram_burstcnt,
    output logic [28:0]  ddram_addr,
    input  logic [63:0]  ddram_dout,
    input  logic         ddram_dout_ready,
    output logic [63:0]  ddram_din,
    output logic [7:0]   ddram_be,
    output logic         ddram_we,
    output logic         ddram_rd
);

    assign ddram_clk      = clk;
    assign ddram_burstcnt = 8'd1;

    wire grant_read  = rd_en;
    wire grant_write = wr_en && !rd_en;

    assign ddram_rd   = grant_read;
    assign ddram_we    = grant_write;
    assign ddram_addr = grant_read ? rd_addr[31:3] : wr_addr[31:3];
    assign ddram_be    = wr_addr[2] ? 8'b1111_0000 : 8'b0000_1111;
    assign ddram_din   = wr_addr[2] ? {wr_data, 32'h0} : {32'h0, wr_data};

    assign wr_ready = grant_write & ~ddram_busy;
    assign rd_ready = grant_read & ~ddram_busy;

    assign rd_valid = ddram_dout_ready;
    assign rd_data  = rd_addr[2] ? ddram_dout[63:32] : ddram_dout[31:0];

endmodule
