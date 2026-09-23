// SDR-002 (core-log entry 61's step 3): a generic single-outstanding
// clock-domain-crossing bridge between clk_sys and clk_sdram.
//
// Uses the classic toggle-and-2FF-synchronize handshake, not an async
// FIFO: this project's DDRAM read port started single-outstanding-first
// too (DDR-003, before DDR-007 added explicit-length bursts once the
// simple case was proven), and a single-outstanding request/response is
// all sdram_adapter.sv (step 4) needs for sprite-source-bitmap reads.
// Address and response data are "quasi-static" busses -- they only change
// once per full round trip, and every side only reads them after
// observing its own synchronized, edge-detected toggle, which is
// guaranteed to arrive at least 2 destination-clock cycles after the
// source register changed (2FF synchronizer latency) and to stay stable
// for the entire round trip after that (the a_ready/busy_a gate below
// blocks a new request until the previous one's response has been
// consumed). This is why only the single-bit toggle needs synchronizer
// flops -- per-bit synchronizers on ADDR_WIDTH/DATA_WIDTH busses are not
// needed and would not be more correct, only slower.
//
// Reset is intentionally NOT crossed here: reset_a and reset_b are
// expected to already be the same physical reset signal (or safely
// derived from it) fed into each domain's own flops, exactly as Noodles.sv
// already does for clk_sys's `reset` and would do for clk_sdram's copy of
// it -- see the sdram_cdc_dut wrapper for how simulation exercises this.
module sdram_cdc #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 64
) (
    // Domain A: the requester (clk_sys today; sdram_adapter.sv's future
    // sprite-source read port).
    input  logic                   clk_a,
    input  logic                   reset_a,
    input  logic [ADDR_WIDTH-1:0]  a_addr,
    input  logic                   a_en,
    output logic                   a_ready,
    output logic [DATA_WIDTH-1:0]  a_data,
    output logic                   a_valid,

    // Domain B: the responder (clk_sdram; the sdram module's own
    // sel/addr/rd/ready/dout port, driven by whatever FSM step 4 adds).
    input  logic                   clk_b,
    input  logic                   reset_b,
    output logic [ADDR_WIDTH-1:0]  b_addr,
    output logic                   b_start,
    input  logic [DATA_WIDTH-1:0]  b_data,
    input  logic                   b_done
);

    // ---- Domain A: request side ----
    logic                  req_toggle_a;
    logic [ADDR_WIDTH-1:0] addr_captured_a;
    logic                  busy_a;

    assign a_ready = !busy_a;

    always_ff @(posedge clk_a or posedge reset_a) begin
        if (reset_a) begin
            req_toggle_a    <= 1'b0;
            addr_captured_a <= '0;
            busy_a          <= 1'b0;
        end else begin
            if (a_en && a_ready) begin
                addr_captured_a <= a_addr;
                req_toggle_a    <= ~req_toggle_a;
                busy_a          <= 1'b1;
            end
            if (a_valid) busy_a <= 1'b0;
        end
    end

    assign b_addr = addr_captured_a;

    // ---- req_toggle_a: domain A -> domain B ----
    (* ASYNC_REG = "TRUE" *) logic [1:0] req_toggle_b_sync;
    logic                               req_toggle_b_prev;

    always_ff @(posedge clk_b or posedge reset_b) begin
        if (reset_b) begin
            req_toggle_b_sync <= 2'b00;
            req_toggle_b_prev <= 1'b0;
        end else begin
            req_toggle_b_sync <= {req_toggle_b_sync[0], req_toggle_a};
            req_toggle_b_prev <= req_toggle_b_sync[1];
        end
    end

    assign b_start = req_toggle_b_sync[1] ^ req_toggle_b_prev;

    // ---- Domain B: response side ----
    logic                  resp_toggle_b;
    logic [DATA_WIDTH-1:0] data_captured_b;

    always_ff @(posedge clk_b or posedge reset_b) begin
        if (reset_b) begin
            resp_toggle_b   <= 1'b0;
            data_captured_b <= '0;
        end else if (b_done) begin
            data_captured_b <= b_data;
            resp_toggle_b   <= ~resp_toggle_b;
        end
    end

    // ---- resp_toggle_b: domain B -> domain A ----
    (* ASYNC_REG = "TRUE" *) logic [1:0] resp_toggle_a_sync;
    logic                               resp_toggle_a_prev;

    always_ff @(posedge clk_a or posedge reset_a) begin
        if (reset_a) begin
            resp_toggle_a_sync <= 2'b00;
            resp_toggle_a_prev <= 1'b0;
        end else begin
            resp_toggle_a_sync <= {resp_toggle_a_sync[0], resp_toggle_b};
            resp_toggle_a_prev <= resp_toggle_a_sync[1];
        end
    end

    assign a_valid = resp_toggle_a_sync[1] ^ resp_toggle_a_prev;

    // data_captured_b is quasi-static (see header comment): it changed at
    // most once, at least 2 clk_b cycles before this a_valid pulse, and
    // will not change again until the next round trip's b_done. So it can
    // be read directly here rather than re-registered into domain A --
    // re-registering it would delay a_data by one clk_a cycle relative to
    // a_valid, making the pulse and the data it announces land on
    // different cycles.
    assign a_data = data_captured_b;

endmodule
