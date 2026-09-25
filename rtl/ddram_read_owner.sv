// Registered owner of the DDRAM adapter's shared read ports.
//
// Each client raises active across every request it issues and every
// response it still expects. The owner is a register: it is released only
// when its client has dropped active and no read response of any kind is
// still outstanding, and the next owner is then the highest-priority active
// client (bit 0 first). No client's state reaches another client's ready or
// valid combinationally, and a response always returns to the client that
// requested it. A newly active client waits one cycle for its grant.
//
// Clients never contend in practice: link and control read only while CMDQ
// is idle, and CMDQ runs one engine at a time. Priority therefore only
// orders simultaneous requests; nothing is ever preempted.

module ddram_read_owner #(
    parameter int CLIENTS = 7
) (
    input  logic               clk,
    input  logic               reset,
    input  logic [CLIENTS-1:0] active,
    input  logic               rd_accept,      // scalar read accepted: one word
    input  logic               rd64_accept,    // 64-bit read accepted: rd64_len words
    input  logic [7:0]         rd64_len,
    input  logic               rd_response,    // one scalar word returned
    input  logic               rd64_response,  // one 64-bit word returned
    output logic [CLIENTS-1:0] owner           // one-hot, or zero when unowned
);

    // The adapter bounds outstanding response words to its queue depth (16).
    // Accepted words are counted from a registered copy of the accept event,
    // so client request logic does not reach the counter; a word cannot
    // return until several cycles after its request is accepted.
    logic [8:0] outstanding, requested_q;
    wire  [8:0] requested = (rd_accept ? 9'd1 : 9'd0) + (rd64_accept ? {1'b0, rd64_len} : 9'd0);
    wire  [8:0] returned  = (rd_response ? 9'd1 : 9'd0) + (rd64_response ? 9'd1 : 9'd0);
    wire released = (owner & active) == '0 && outstanding == '0 && requested_q == '0 &&
                    !rd_accept && !rd64_accept;

    logic [CLIENTS-1:0] next_owner;
    always_comb begin
        next_owner = '0;
        for (int i = CLIENTS - 1; i >= 0; i--)
            if (active[i]) next_owner = CLIENTS'(1) << i;
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            owner       <= '0;
            outstanding <= '0;
            requested_q <= '0;
        end else begin
            requested_q <= requested;
            outstanding <= outstanding + requested_q - returned;
            if (released) owner <= next_owner;
        end
    end

`ifdef FORMAL
    // Properties proved by fv/ddram_read_owner.sby. The adapter accepts only
    // the owner's requests and returns each requested word exactly once, in
    // any later cycle; activity is otherwise unconstrained.
    logic f_past_valid = 1'b0;
    always_ff @(posedge clk) f_past_valid <= 1'b1;
    always_comb begin
        if (!f_past_valid) assume(reset);
        if (rd_accept || rd64_accept) assume(owner != '0);
        if (rd64_accept) assume(rd64_len != 8'd0 && rd64_len <= 8'd16);
        assume(returned <= outstanding);
        assume({1'b0, outstanding} + {1'b0, requested_q} + {1'b0, requested} <= 10'd16);
    end

    always_ff @(posedge clk) if (f_past_valid && !reset && !$past(reset)) begin
        // The owner changes only once released, and then to the client that
        // had the highest priority among those active at release.
        if (owner != $past(owner)) assert($past(released) && owner == $past(next_owner));
        // An owner that is still active or still expects words keeps the port.
        if ($past((owner & active) != '0 || outstanding != '0 || requested_q != '0))
            assert(owner == $past(owner));
    end

    always_comb if (f_past_valid && !reset) begin
        assert($onehot0(owner));
        // Every outstanding or just-accepted word belongs to the current owner.
        if (outstanding != '0 || requested_q != '0) assert(owner != '0);
        assert({1'b0, outstanding} + {1'b0, requested_q} <= 10'd16);
    end

    always_comb if (f_past_valid && !reset) begin
        cover(owner == CLIENTS'(2) && active[0]);           // link holds the port while control waits
        cover(owner == CLIENTS'(4) && outstanding == 9'd16);
    end
    always_ff @(posedge clk) if (f_past_valid && !reset && !$past(reset))
        cover(owner == CLIENTS'(64) && $past(owner) == CLIENTS'(2));  // handover link to copy
`endif

endmodule
