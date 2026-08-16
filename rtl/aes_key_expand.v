//=============================================================================
// aes_key_expand.v -- one step of the AES-128 key schedule (on-the-fly)
//
// FIPS-197 Section 5.2. Given round key W[4i..4i+3] and Rcon[i+1], produces
// round key W[4i+4..4i+7]. Purely combinational: the caller registers the
// result, so the whole key schedule costs 4 S-boxes and 128 flops rather than
// the 1408 flops a precomputed schedule would need.
//
// Word ordering: key_in[127:96] = W[4i] (leftmost word), key_in[31:0] = W[4i+3]
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module aes_key_expand (
    input  wire [127:0] key_in,
    input  wire [7:0]   rcon,
    output wire [127:0] key_out
);

    wire [31:0] w0 = key_in[127:96];
    wire [31:0] w1 = key_in[ 95:64];
    wire [31:0] w2 = key_in[ 63:32];
    wire [31:0] w3 = key_in[ 31: 0];

    // RotWord: [a0,a1,a2,a3] -> [a1,a2,a3,a0]
    wire [31:0] rot = {w3[23:0], w3[31:24]};

    // SubWord
    wire [31:0] sub;
    aes_sbox u_sb0 (.addr(rot[31:24]), .dout(sub[31:24]));
    aes_sbox u_sb1 (.addr(rot[23:16]), .dout(sub[23:16]));
    aes_sbox u_sb2 (.addr(rot[15: 8]), .dout(sub[15: 8]));
    aes_sbox u_sb3 (.addr(rot[ 7: 0]), .dout(sub[ 7: 0]));

    // temp = SubWord(RotWord(W[4i+3])) xor Rcon
    wire [31:0] temp = sub ^ {rcon, 24'h000000};

    wire [31:0] nw0 = w0  ^ temp;
    wire [31:0] nw1 = nw0 ^ w1;
    wire [31:0] nw2 = nw1 ^ w2;
    wire [31:0] nw3 = nw2 ^ w3;

    assign key_out = {nw0, nw1, nw2, nw3};

endmodule

`default_nettype wire
