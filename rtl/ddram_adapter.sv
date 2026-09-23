// Registered request queues for the shared DDRAM Avalon-MM port.
//
// Client requests are captured before arbitration, so DDRAM_BUSY cannot
// change a client's valid/ready handshake and no client signal is fed back
// through the physical-bus grant. Reads retain ordered response metadata.

module ddram_adapter (
    input  logic         clk,
    input  logic         reset,

    input  logic [31:0]  wr_addr,
    input  logic [31:0]  wr_data,
    input  logic         wr_en,
    output logic         wr_ready,
    input  logic [31:0]  wr64_addr,
    input  logic [63:0]  wr64_data,
    input  logic         wr64_en,
    output logic         wr64_ready,

    input  logic [31:0]  rd_addr,
    input  logic         rd_en,
    output logic         rd_ready,
    output logic [31:0]  rd_data,
    output logic         rd_valid,
    input  logic [31:0]  rd64_addr,
    input  logic         rd64_en,
    output logic         rd64_ready,
    output logic [63:0]  rd64_data,
    output logic         rd64_valid,

    output logic         ddram_clk,
    input  logic         ddram_busy,
    output logic [7:0]   ddram_burstcnt,
    output logic [28:0]  ddram_addr,
    input  logic [63:0]  ddram_dout,
    input  logic         ddram_dout_ready,
    output logic [63:0]  ddram_din,
    output logic [7:0]   ddram_be,
    output logic         ddram_we,
    output logic         ddram_rd,
    output logic         idle
);

    localparam int DEPTH = 4;
    localparam int PTR_W = $clog2(DEPTH);

    logic [31:0] wr_addr_q [0:DEPTH-1];
    logic [63:0] wr_data_q [0:DEPTH-1];
    logic        wr_full_q [0:DEPTH-1];
    logic [PTR_W-1:0] wr_head, wr_tail;
    logic [PTR_W:0] wr_count;

    logic [31:0] rd_addr_q [0:DEPTH-1];
    logic        rd_is64_q [0:DEPTH-1];
    logic        rd_half_q [0:DEPTH-1];
    logic [PTR_W-1:0] rd_head, rd_tail;
    logic [PTR_W:0] rd_count;

    logic        rsp_is64_q [0:DEPTH-1];
    logic        rsp_half_q [0:DEPTH-1];
    logic [PTR_W-1:0] rsp_head, rsp_tail;
    logic [PTR_W:0] rsp_count;

    wire wr_fire   = wr_en && wr_ready;
    wire wr64_fire = wr64_en && wr64_ready;
    wire rd_fire   = rd_en && rd_ready;
    wire rd64_fire = rd64_en && rd64_ready;

    wire read_issue = (rd_count != 0) && (rsp_count < DEPTH) && !ddram_busy;
    wire write_issue = (wr_count != 0) && !read_issue && !ddram_busy;
    wire read_rsp = ddram_dout_ready && (rsp_count != 0);

    assign ddram_clk = clk;
    assign ddram_burstcnt = 8'd1;

    // Queues accept requests independently of the physical bus.  A 64-bit
    // write has priority over a scalar write only when both are presented by
    // the same client, which is the only legal producer behavior.
    assign wr_ready = (wr_count < DEPTH);
    assign wr64_ready = (wr_count < DEPTH);
    assign rd_ready = (rd_count < DEPTH) && (rsp_count < DEPTH);
    assign rd64_ready = (rd_count < DEPTH) && (rsp_count < DEPTH);

    assign ddram_rd = read_issue;
    assign ddram_we = write_issue;
    assign ddram_addr = read_issue ? rd_addr_q[rd_head][31:3] :
                        wr_count != 0 ? wr_addr_q[wr_head][31:3] : 29'b0;
    assign ddram_be = write_issue ? (wr_full_q[wr_head] ? 8'hff :
                                     (wr_addr_q[wr_head][2] ? 8'hf0 : 8'h0f)) : 8'b0;
    assign ddram_din = write_issue ? (wr_full_q[wr_head] ? wr_data_q[wr_head] :
                                      (wr_addr_q[wr_head][2] ?
                                       {wr_data_q[wr_head][31:0], 32'b0} :
                                       {32'b0, wr_data_q[wr_head][31:0]})) : 64'b0;
    assign idle = (wr_count == 0) && (rd_count == 0) &&
                  (rsp_count == 0) && !ddram_busy;

    assign rd_valid = read_rsp && !rsp_is64_q[rsp_head];
    assign rd64_valid = read_rsp && rsp_is64_q[rsp_head];
    assign rd_data = rsp_half_q[rsp_head] ? ddram_dout[63:32] : ddram_dout[31:0];
    assign rd64_data = ddram_dout;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            wr_head <= 0;
            wr_tail <= 0;
            wr_count <= 0;
            rd_head <= 0;
            rd_tail <= 0;
            rd_count <= 0;
            rsp_head <= 0;
            rsp_tail <= 0;
            rsp_count <= 0;
        end else begin
            if (wr_fire || wr64_fire) begin
                wr_addr_q[wr_tail] <= wr64_fire ? wr64_addr : wr_addr;
                wr_data_q[wr_tail] <= wr64_fire ? wr64_data : {32'b0, wr_data};
                wr_full_q[wr_tail] <= wr64_fire;
                wr_tail <= wr_tail + 1'b1;
            end
            if (write_issue)
                wr_head <= wr_head + 1'b1;
            case ({wr_fire || wr64_fire, write_issue})
                2'b10: wr_count <= wr_count + 1'b1;
                2'b01: wr_count <= wr_count - 1'b1;
                default: ;
            endcase

            if (rd_fire || rd64_fire) begin
                rd_addr_q[rd_tail] <= rd64_fire ? rd64_addr : rd_addr;
                rd_is64_q[rd_tail] <= rd64_fire;
                rd_half_q[rd_tail] <= rd64_fire ? 1'b0 :
                                      (rd_addr[2]);
                rd_tail <= rd_tail + 1'b1;
            end
            if (read_issue)
                rd_head <= rd_head + 1'b1;
            case ({rd_fire || rd64_fire, read_issue})
                2'b10: rd_count <= rd_count + 1'b1;
                2'b01: rd_count <= rd_count - 1'b1;
                default: ;
            endcase

            if (read_issue) begin
                rsp_is64_q[rsp_tail] <= rd_is64_q[rd_head];
                rsp_half_q[rsp_tail] <= rd_half_q[rd_head];
                rsp_tail <= rsp_tail + 1'b1;
            end
            if (read_rsp)
                rsp_head <= rsp_head + 1'b1;
            case ({read_issue, read_rsp})
                2'b10: rsp_count <= rsp_count + 1'b1;
                2'b01: rsp_count <= rsp_count - 1'b1;
                default: ;
            endcase
        end
    end

endmodule
