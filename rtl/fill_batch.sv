// Ordered solid-fill descriptor sequencer. Each command selects one aligned
// 2 KiB table from the protocol's bounded descriptor pool and executes up to
// 64 descriptors through the existing blit fill engine. A descriptor keeps
// the 32-byte command-slot stride so sprite and fill batches can share the
// same table ring and host ownership machinery:
//   word 0 destination address
//   word 1 destination pitch
//   word 2 width
//   word 3 height
//   word 4 colour
//   words 5-7 reserved zero (validated by the SDK)
module fill_batch #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32
) (
    input  logic                  clk,
    input  logic                  reset,
    input  logic                  start,
    input  logic [ADDR_WIDTH-1:0] descriptor_base,
    input  logic [15:0]           count,
    output logic                  busy,
    output logic                  done,

    output logic [ADDR_WIDTH-1:0] rd_addr,
    output logic                  rd_en,
    output logic                  rd_active,
    input  logic                  rd_ready,
    input  logic [DATA_WIDTH-1:0] rd_data,
    input  logic                  rd_valid,

    output logic                  fill_start,
    output logic [ADDR_WIDTH-1:0] fill_dst_addr,
    output logic [15:0]           fill_dst_pitch,
    output logic [15:0]           fill_width,
    output logic [15:0]           fill_height,
    output logic [DATA_WIDTH-1:0] fill_color,
    input  logic                  fill_done
);
    typedef enum logic [2:0] {IDLE, DESC_REQ, DESC_WAIT, LAUNCH, FILL, FINISH} state_t;
    state_t state;
    logic [15:0] index, count_r;
    logic [2:0] word_index;
    logic [31:0] desc[0:4];

    assign rd_addr = descriptor_base + {11'd0, index, 5'b0} +
                     {27'd0, word_index, 2'b0};
    assign rd_en = state == DESC_REQ;
    assign rd_active = state == DESC_REQ || state == DESC_WAIT;
    assign fill_dst_addr = desc[0];
    assign fill_dst_pitch = desc[1][15:0];
    assign fill_width = desc[2][15:0];
    assign fill_height = desc[3][15:0];
    assign fill_color = desc[4];

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            fill_start <= 1'b0;
            index <= '0;
            count_r <= '0;
            word_index <= '0;
            for (int i = 0; i < 5; i++) desc[i] <= '0;
        end else begin
            done <= 1'b0;
            fill_start <= 1'b0;
            unique case (state)
                IDLE: if (start && count != 0 && count <= 64) begin
                    busy <= 1'b1;
                    index <= '0;
                    count_r <= count;
                    word_index <= '0;
                    state <= DESC_REQ;
                end
                DESC_REQ: if (rd_ready) state <= DESC_WAIT;
                DESC_WAIT: if (rd_valid) begin
                    desc[word_index] <= rd_data;
                    if (word_index == 3'd4) begin
                        state <= LAUNCH;
                    end else begin
                        word_index <= word_index + 1'b1;
                        state <= DESC_REQ;
                    end
                end
                LAUNCH: begin
                    fill_start <= 1'b1;
                    state <= FILL;
                end
                FILL: if (fill_done) begin
                    if (index + 1'b1 >= count_r) begin
                        state <= FINISH;
                    end else begin
                        index <= index + 1'b1;
                        word_index <= '0;
                        state <= DESC_REQ;
                    end
                end
                FINISH: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
