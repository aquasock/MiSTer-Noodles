// Live host/core session control for SDK stage 2B.
//
// DDR3 survives FPGA reset, so static magic and fence values cannot prove
// that the expected core is currently alive. This block clears its request
// and response sequence words during initialization, publishes identity last,
// and keeps link_ring disabled until a host claims a session with a 64-bit
// token. While active, only requests carrying that token are echoed. A stale
// process can change its request after reset, but the inactive block ignores
// everything except the explicit CLAIM sequence.

module link_control #(
    parameter logic [31:0] BASE_ADDR = 32'h3002_0010,
    parameter int POLL_CYCLES = 1024
) (
    input  logic clk,
    input  logic reset,
    input  logic device_initialized,
    input  logic bus_available,

    output logic [31:0] rd_addr,
    output logic         rd_en,
    output logic         rd_active,
    input  logic         rd_ready,
    input  logic [31:0]  rd_data,
    input  logic         rd_valid,

    output logic [31:0] wr_addr,
    output logic [31:0] wr_data,
    output logic         wr_en,
    input  logic         wr_ready,

    output logic session_active
);

    localparam logic [31:0] MAGIC = 32'h4e44_4c53;
    localparam logic [31:0] PROTOCOL = 32'h0001_0001;       // LINK-012
    localparam logic [31:0] CAPABILITIES = 32'h0000_00fe;   // opcodes 1-7
    localparam logic [31:0] GEOMETRY = {16'd800, 16'd600};
    localparam logic [31:0] PITCH = 32'd3200;
    localparam logic [31:0] CLAIM = 32'h434c_414d;

    localparam logic [31:0] MAGIC_ADDR = BASE_ADDR;
    localparam logic [31:0] PROTOCOL_ADDR = BASE_ADDR + 32'h04;
    localparam logic [31:0] CAPABILITIES_ADDR = BASE_ADDR + 32'h08;
    localparam logic [31:0] GEOMETRY_ADDR = BASE_ADDR + 32'h0c;
    localparam logic [31:0] PITCH_ADDR = BASE_ADDR + 32'h10;
    localparam logic [31:0] REQUEST_TOKEN_LO_ADDR = BASE_ADDR + 32'h18;
    localparam logic [31:0] REQUEST_TOKEN_HI_ADDR = BASE_ADDR + 32'h1c;
    localparam logic [31:0] REQUEST_SEQ_ADDR = BASE_ADDR + 32'h20;
    localparam logic [31:0] RESPONSE_TOKEN_LO_ADDR = BASE_ADDR + 32'h28;
    localparam logic [31:0] RESPONSE_TOKEN_HI_ADDR = BASE_ADDR + 32'h2c;
    localparam logic [31:0] RESPONSE_SEQ_ADDR = BASE_ADDR + 32'h30;

    localparam int POLL_WIDTH = POLL_CYCLES <= 1 ? 1 : $clog2(POLL_CYCLES);

    typedef enum logic [4:0] {
        INIT_MAGIC_CLEAR, INIT_REQUEST_CLEAR, INIT_RESPONSE_CLEAR,
        INIT_PROTOCOL, INIT_CAPABILITIES, INIT_GEOMETRY, INIT_PITCH, INIT_MAGIC,
        IDLE, POLL_SEQ_REQ, POLL_SEQ_WAIT,
        TOKEN_LO_REQ, TOKEN_LO_WAIT, TOKEN_HI_REQ, TOKEN_HI_WAIT,
        WRITE_TOKEN_LO, WRITE_TOKEN_HI, WRITE_RESPONSE
    } state_t;

    state_t state;
    logic [POLL_WIDTH-1:0] poll_count;
    logic [31:0] last_request_seq, request_seq;
    logic [31:0] candidate_token_lo, candidate_token_hi;
    logic [31:0] session_token_lo, session_token_hi;
    logic [31:0] rd_data_q;
    logic        rd_valid_q;

    assign rd_en = state == POLL_SEQ_REQ || state == TOKEN_LO_REQ || state == TOKEN_HI_REQ;
    assign rd_active = state == POLL_SEQ_REQ || state == POLL_SEQ_WAIT ||
                       state == TOKEN_LO_REQ || state == TOKEN_LO_WAIT ||
                       state == TOKEN_HI_REQ || state == TOKEN_HI_WAIT;
    assign rd_addr = (state == TOKEN_LO_REQ || state == TOKEN_LO_WAIT) ?
                     REQUEST_TOKEN_LO_ADDR :
                     (state == TOKEN_HI_REQ || state == TOKEN_HI_WAIT) ?
                     REQUEST_TOKEN_HI_ADDR : REQUEST_SEQ_ADDR;

    assign wr_en = state == INIT_MAGIC_CLEAR || state == INIT_REQUEST_CLEAR ||
                   state == INIT_RESPONSE_CLEAR || state == INIT_PROTOCOL ||
                   state == INIT_CAPABILITIES || state == INIT_GEOMETRY ||
                   state == INIT_PITCH || state == INIT_MAGIC ||
                   state == WRITE_TOKEN_LO || state == WRITE_TOKEN_HI ||
                   state == WRITE_RESPONSE;
    always_comb begin
        wr_addr = MAGIC_ADDR;
        wr_data = 32'd0;
        unique case (state)
            INIT_MAGIC_CLEAR: begin wr_addr = MAGIC_ADDR; wr_data = 32'd0; end
            INIT_REQUEST_CLEAR: begin wr_addr = REQUEST_SEQ_ADDR; wr_data = 32'd0; end
            INIT_RESPONSE_CLEAR: begin wr_addr = RESPONSE_SEQ_ADDR; wr_data = 32'd0; end
            INIT_PROTOCOL: begin wr_addr = PROTOCOL_ADDR; wr_data = PROTOCOL; end
            INIT_CAPABILITIES: begin wr_addr = CAPABILITIES_ADDR; wr_data = CAPABILITIES; end
            INIT_GEOMETRY: begin wr_addr = GEOMETRY_ADDR; wr_data = GEOMETRY; end
            INIT_PITCH: begin wr_addr = PITCH_ADDR; wr_data = PITCH; end
            INIT_MAGIC: begin wr_addr = MAGIC_ADDR; wr_data = MAGIC; end
            WRITE_TOKEN_LO: begin wr_addr = RESPONSE_TOKEN_LO_ADDR; wr_data = candidate_token_lo; end
            WRITE_TOKEN_HI: begin wr_addr = RESPONSE_TOKEN_HI_ADDR; wr_data = candidate_token_hi; end
            WRITE_RESPONSE: begin wr_addr = RESPONSE_SEQ_ADDR; wr_data = request_seq; end
            default: begin end
        endcase
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= INIT_MAGIC_CLEAR;
            poll_count <= '0;
            last_request_seq <= 32'd0;
            request_seq <= 32'd0;
            candidate_token_lo <= 32'd0;
            candidate_token_hi <= 32'd0;
            session_token_lo <= 32'd0;
            session_token_hi <= 32'd0;
            rd_data_q <= 32'd0;
            rd_valid_q <= 1'b0;
            session_active <= 1'b0;
        end else begin
            // Register DDR3 responses before the session FSM compares them.
            rd_valid_q <= rd_valid;
            if (rd_valid)
                rd_data_q <= rd_data;
            unique case (state)
                INIT_MAGIC_CLEAR: if (wr_en && wr_ready) state <= INIT_REQUEST_CLEAR;
                INIT_REQUEST_CLEAR: if (wr_en && wr_ready) state <= INIT_RESPONSE_CLEAR;
                INIT_RESPONSE_CLEAR: if (wr_en && wr_ready) state <= INIT_PROTOCOL;
                INIT_PROTOCOL: if (wr_en && wr_ready) state <= INIT_CAPABILITIES;
                INIT_CAPABILITIES: if (wr_en && wr_ready) state <= INIT_GEOMETRY;
                INIT_GEOMETRY: if (wr_en && wr_ready) state <= INIT_PITCH;
                INIT_PITCH: if (wr_en && wr_ready) state <= INIT_MAGIC;
                INIT_MAGIC: begin
                    if (wr_en && wr_ready) begin
                        poll_count <= '0;
                        state <= IDLE;
                    end
                end

                IDLE: begin
                    if (poll_count != POLL_WIDTH'(POLL_CYCLES - 1)) begin
                        poll_count <= poll_count + 1'b1;
                    end else if (bus_available) begin
                        poll_count <= '0;
                        state <= POLL_SEQ_REQ;
                    end
                end
                POLL_SEQ_REQ: if (rd_en && rd_ready) state <= POLL_SEQ_WAIT;
                POLL_SEQ_WAIT: begin
                    if (rd_valid_q) begin
                        request_seq <= rd_data_q;
                        if (rd_data_q == last_request_seq) begin
                            state <= IDLE;
                        end else if (session_active && rd_data_q == 32'd0) begin
                            session_active <= 1'b0;
                            session_token_lo <= 32'd0;
                            session_token_hi <= 32'd0;
                            last_request_seq <= 32'd0;
                            state <= WRITE_RESPONSE;
                        end else if (rd_data_q != 32'd0 &&
                                     (session_active || (device_initialized && rd_data_q == CLAIM))) begin
                            state <= TOKEN_LO_REQ;
                        end else begin
                            state <= IDLE;
                        end
                    end
                end
                TOKEN_LO_REQ: if (rd_en && rd_ready) state <= TOKEN_LO_WAIT;
                TOKEN_LO_WAIT: begin
                    if (rd_valid_q) begin
                        candidate_token_lo <= rd_data_q;
                        state <= TOKEN_HI_REQ;
                    end
                end
                TOKEN_HI_REQ: if (rd_en && rd_ready) state <= TOKEN_HI_WAIT;
                TOKEN_HI_WAIT: begin
                    if (rd_valid_q) begin
                        candidate_token_hi <= rd_data_q;
                        if ((!session_active && request_seq == CLAIM &&
                             (candidate_token_lo != 32'd0 || rd_data_q != 32'd0)) ||
                            (session_active && candidate_token_lo == session_token_lo &&
                             rd_data_q == session_token_hi && request_seq != CLAIM)) begin
                            if (!session_active) begin
                                session_token_lo <= candidate_token_lo;
                                session_token_hi <= rd_data_q;
                                session_active <= 1'b1;
                                state <= WRITE_TOKEN_LO;
                            end else begin
                                state <= WRITE_RESPONSE;
                            end
                        end else begin
                            state <= IDLE;
                        end
                    end
                end
                WRITE_TOKEN_LO: if (wr_en && wr_ready) state <= WRITE_TOKEN_HI;
                WRITE_TOKEN_HI: if (wr_en && wr_ready) state <= WRITE_RESPONSE;
                WRITE_RESPONSE: begin
                    if (wr_en && wr_ready) begin
                        last_request_seq <= request_seq;
                        state <= IDLE;
                    end
                end
                default: state <= INIT_MAGIC_CLEAR;
            endcase
        end
    end

endmodule
