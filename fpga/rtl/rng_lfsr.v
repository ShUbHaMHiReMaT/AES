//=============================================================================
// rng_lfsr.v -- small pseudo-random source for the capture unit
//
// A 32-bit maximal-length Galois LFSR (taps 32,22,2,1). Used only by the
// side-channel capture unit to pick random dummy-operation counts, random
// trigger offsets and random dummy plaintexts for the "hiding" protected
// mode. It is not cryptographic and is not in any AES datapath.
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module rng_lfsr #(
    parameter [31:0] SEED = 32'h1357_9BDF
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,
    output wire [31:0] rnd
);
    reg [31:0] s = SEED;
    always @(posedge clk) begin
        if (!rst_n)   s <= SEED;
        else if (en)  s <= {s[30:0], 1'b0} ^ (s[31] ? 32'h8020_0003 : 32'h0);
    end
    assign rnd = s;
endmodule

`default_nettype wire
