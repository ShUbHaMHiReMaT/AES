//=============================================================================
// aes_round.v -- one full AES-128 encryption round (combinational)
//
//   SubBytes -> ShiftRows -> MixColumns -> AddRoundKey
//
// last_round = 1 bypasses MixColumns, per FIPS-197 Section 5.1 (round Nr).
// Making the bypass a runtime input costs 128 2:1 muxes (~64 LUT6) and lets
// the iterative core fold round 10 into the same hardware. In the pipelined
// core the input is tied to a constant and synthesis removes the muxes.
//
// State layout (FIPS-197 Section 3.4, column-major):
//   state_in[127:120] = s(0,0)   state_in[119:112] = s(1,0)  ...
//   i.e. byte index i = state_in[(15-i)*8 +: 8], and s(r,c) = byte(r + 4c)
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module aes_round (
    input  wire [127:0] state_in,
    input  wire [127:0] round_key,
    input  wire         last_round,
    output wire [127:0] state_out
);

    //-------------------------------------------------------------------------
    // SubBytes: 16 parallel S-boxes
    //-------------------------------------------------------------------------
    wire [127:0] sub;
    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : g_subbytes
            aes_sbox u_sbox (
                .addr (state_in[gi*8 +: 8]),
                .dout (sub     [gi*8 +: 8])
            );
        end
    endgenerate

    //-------------------------------------------------------------------------
    // ShiftRows: row r rotated left by r bytes
    //   out(r,c) = in(r, (c+r) mod 4)  ->  out[r+4c] = in[r + 4*((c+r) mod 4)]
    //-------------------------------------------------------------------------
    wire [127:0] shifted = {
        sub[120 +: 8], sub[ 80 +: 8], sub[ 40 +: 8], sub[  0 +: 8],  // col 0: b0  b5  b10 b15
        sub[ 88 +: 8], sub[ 48 +: 8], sub[  8 +: 8], sub[ 96 +: 8],  // col 1: b4  b9  b14 b3
        sub[ 56 +: 8], sub[ 16 +: 8], sub[104 +: 8], sub[ 64 +: 8],  // col 2: b8  b13 b2  b7
        sub[ 24 +: 8], sub[112 +: 8], sub[ 72 +: 8], sub[ 32 +: 8]   // col 3: b12 b1  b6  b11
    };

    //-------------------------------------------------------------------------
    // MixColumns: each column multiplied by the fixed polynomial in GF(2^8)
    //-------------------------------------------------------------------------
    function [7:0] xtime;
        input [7:0] b;
        begin
            xtime = {b[6:0], 1'b0} ^ (b[7] ? 8'h1b : 8'h00);
        end
    endfunction

    function [31:0] mixcolumn;
        input [31:0] col;
        reg [7:0] a0, a1, a2, a3;
        begin
            a0 = col[31:24];
            a1 = col[23:16];
            a2 = col[15: 8];
            a3 = col[ 7: 0];
            mixcolumn = {
                xtime(a0)      ^ xtime(a1) ^ a1 ^ a2             ^ a3,
                a0             ^ xtime(a1) ^ xtime(a2) ^ a2      ^ a3,
                a0             ^ a1        ^ xtime(a2) ^ xtime(a3) ^ a3,
                xtime(a0) ^ a0 ^ a1        ^ a2             ^ xtime(a3)
            };
        end
    endfunction

    wire [127:0] mixed = {
        mixcolumn(shifted[127:96]),
        mixcolumn(shifted[ 95:64]),
        mixcolumn(shifted[ 63:32]),
        mixcolumn(shifted[ 31: 0])
    };

    wire [127:0] pre_key = last_round ? shifted : mixed;

    //-------------------------------------------------------------------------
    // AddRoundKey
    //-------------------------------------------------------------------------
    assign state_out = pre_key ^ round_key;

endmodule

`default_nettype wire
