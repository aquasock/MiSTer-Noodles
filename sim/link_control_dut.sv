module link_control_dut (
    input  logic clk,
    input  logic reset,
    input  logic device_initialized,
    input  logic bus_available,
    output logic [31:0] rd_addr,
    output logic rd_en,
    output logic rd_active,
    input  logic rd_ready,
    input  logic [31:0] rd_data,
    input  logic rd_valid,
    output logic [31:0] wr_addr,
    output logic [31:0] wr_data,
    output logic wr_en,
    input  logic wr_ready,
    output logic session_active
);
    link_control #(.POLL_CYCLES(2)) control_i (
        .clk(clk), .reset(reset), .device_initialized(device_initialized),
        .bus_available(bus_available), .rd_addr(rd_addr), .rd_en(rd_en),
        .rd_active(rd_active), .rd_ready(rd_ready), .rd_data(rd_data),
        .rd_valid(rd_valid), .wr_addr(wr_addr), .wr_data(wr_data),
        .wr_en(wr_en), .wr_ready(wr_ready), .session_active(session_active)
    );
endmodule
