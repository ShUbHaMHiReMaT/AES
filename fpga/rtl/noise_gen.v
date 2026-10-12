//=============================================================================
// noise_gen.v -- data-independent switching noise for the "hiding" defence
//
// A bank of free-running LFSRs. When `en` is high, ~half of these flip-flops
// toggle every clock, drawing a random, data-INDEPENDENT amount of current
// right next to the AES logic. To the on-chip sensor this looks like extra
// broadband noise laid on top of the data-dependent signal, so an attacker
// needs many more traces to average it away (classic power-analysis hiding).
//
// It carries no secret and touches no AES signal. `busy_bits` is a reduction
// the capture unit keeps live so synthesis cannot optimise the bank away.
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module noise_gen #(
    parameter integer N = 8              // number of 32-bit LFSRs
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       en,
    output wire       busy_bits
);
    genvar i;
    wire [N-1:0] msb;
    generate
        for (i = 0; i < N; i = i + 1) begin : bank
            (* DONT_TOUCH = "true" *) reg [31:0] s = 32'h1 + (i * 32'h9E37_79B9);
            always @(posedge clk) begin
                if (!rst_n)  s <= 32'h1 + (i * 32'h9E37_79B9);
                else if (en) s <= {s[30:0], 1'b0} ^ (s[31] ? 32'h8020_0003 : 32'h0);
            end
            assign msb[i] = s[31];
        end
    endgenerate
    assign busy_bits = ^msb;             // keeps the bank from being trimmed
endmodule

`default_nettype wire
