// SDR-003 (core-log entry 66's step 5a): a small 1KB dual-clock page
// buffer used by sdram_loader.sv to bridge a single 512x16-bit-word SDRAM
// page between clk_sys (filled from DDR3 via ddram_adapter's rd64
// interface) and clk_sdram (drained into sdram.sv's real copy port,
// which demands one new 16-bit word every clk_sdram cycle for 512
// consecutive cycles once triggered -- see sdram_loader.sv's header for
// why the fill and flush stages cannot share a clock domain).
//
// This is the standard inferable simple-dual-port dual-clock RAM idiom:
// one write port (domain A), one read port (domain B), sharing a single
// memory array. Quartus recognizes this pattern and maps it to an M10K
// block; it is not simulated bit-exactly against real M10K read-during-
// write behavior here because sdram_loader.sv's own handshake (via
// sdram_cdc) guarantees the two domains never touch the buffer at
// overlapping times -- a full fill always completes (and its "page
// ready" toggle synchronizes into domain B) before flush's first read,
// and flush always completes (and its "page done" toggle synchronizes
// back into domain A) before the next fill's first write.
module sdram_page_buffer (
    input  logic        clk_a,
    input  logic        we_a,
    input  logic [8:0]  addr_a,
    input  logic [15:0] din_a,

    input  logic        clk_b,
    input  logic [8:0]  addr_b,
    output logic [15:0] dout_b
);

    logic [15:0] mem [0:511];

    always_ff @(posedge clk_a) begin
        if (we_a) mem[addr_a] <= din_a;
    end

    always_ff @(posedge clk_b) begin
        dout_b <= mem[addr_b];
    end

endmodule
