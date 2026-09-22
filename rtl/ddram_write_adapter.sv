// Adapts BLIT's generic byte-addressed write port (rtl/blit.sv) onto the
// framework's real DDRAM_* pins -- a standard Avalon-MM master interface
// (F2H SDRAM bridge into HPS DDR3). Write-only: BLIT never reads, so RD and
// BURSTCNT are fixed. DDRAM is 8 bytes/word; BLIT writes 4-byte pixels, so
// this steers each write into the upper or lower half of the 64-bit word
// using wr_addr[2] and masks the other half off with DDRAM_BE. Requires
// wr_addr to always be 4-byte aligned.
//
// ai/core-reference.md DDR-001 defines this mapping.

module ddram_write_adapter (
    input  logic        clk,

    // BLIT-facing generic write port
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] wr_addr,  // [1:0] unused: BLIT-002/DDR-001 require 4-byte alignment
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [31:0] wr_data,
    input  logic        wr_en,
    output logic        wr_ready,

    // DDRAM_*-facing Avalon-MM master port
    output logic        ddram_clk,
    input  logic        ddram_busy,
    output logic [7:0]  ddram_burstcnt,
    output logic [28:0] ddram_addr,
    output logic [63:0] ddram_din,
    output logic [7:0]  ddram_be,
    output logic        ddram_we,
    output logic        ddram_rd
);

    assign ddram_clk      = clk;
    assign ddram_rd       = 1'b0;
    assign ddram_burstcnt = 8'd1;

    assign ddram_we   = wr_en;
    assign ddram_addr = wr_addr[31:3];
    assign ddram_be   = wr_addr[2] ? 8'b1111_0000 : 8'b0000_1111;
    assign ddram_din  = wr_addr[2] ? {wr_data, 32'h0} : {32'h0, wr_data};

    assign wr_ready = ~ddram_busy;

endmodule
