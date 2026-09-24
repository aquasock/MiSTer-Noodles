// Single-clock 1KB page buffer with one-cycle synchronous read latency.
// The loader completes fill before flush and waits for flush completion
// before refilling, so no read-during-write data is consumed.
module sdram_page_buffer (
    input  logic        clk,
    input  logic        we_a,
    input  logic [8:0]  addr_a,
    input  logic [15:0] din_a,
    input  logic [8:0]  addr_b,
    output logic [15:0] dout_b
);
    logic [15:0] mem [0:511];

    always_ff @(posedge clk) begin
        if (we_a) mem[addr_a] <= din_a;
        dout_b <= mem[addr_b];
    end
endmodule
