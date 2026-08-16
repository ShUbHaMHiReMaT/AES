//=============================================================================
// aes_sbox.v -- AES forward substitution box (SubBytes primitive)
//
// FIPS-197 Section 5.1.1. Combinational ROM lookup.
//
// Implementation note:
//   The table is held in a packed localparam so synthesis sees a single
//   constant ROM. Vivado maps each instance to 32 LUT6 (distributed ROM).
//   See README ("BRAM S-box variant") for the block-RAM alternative.
//
// The table below is checked byte-for-byte against the algebraic definition
// (multiplicative inverse in GF(2^8) + affine transform) by
//   python model/aes_golden.py --check-sbox rtl/aes_sbox.v
// so a typo here fails the regression rather than the board.
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module aes_sbox (
    input  wire [7:0] addr,
    output wire [7:0] dout
);

    // 16 bytes per line; line r holds entries addr[7:4] == r
    localparam [2047:0] SBOX_ROM = {
        128'h637c777bf26b6fc53001672bfed7ab76,  // 0x0_
        128'hca82c97dfa5947f0add4a2af9ca472c0,  // 0x1_
        128'hb7fd9326363ff7cc34a5e5f171d83115,  // 0x2_
        128'h04c723c31896059a071280e2eb27b275,  // 0x3_
        128'h09832c1a1b6e5aa0523bd6b329e32f84,  // 0x4_
        128'h53d100ed20fcb15b6acbbe394a4c58cf,  // 0x5_
        128'hd0efaafb434d338545f9027f503c9fa8,  // 0x6_
        128'h51a3408f929d38f5bcb6da2110fff3d2,  // 0x7_
        128'hcd0c13ec5f974417c4a77e3d645d1973,  // 0x8_
        128'h60814fdc222a908846eeb814de5e0bdb,  // 0x9_
        128'he0323a0a4906245cc2d3ac629195e479,  // 0xa_
        128'he7c8376d8dd54ea96c56f4ea657aae08,  // 0xb_
        128'hba78252e1ca6b4c6e8dd741f4bbd8b8a,  // 0xc_
        128'h703eb5664803f60e613557b986c11d9e,  // 0xd_
        128'he1f8981169d98e949b1e87e9ce5528df,  // 0xe_
        128'h8ca1890dbfe6426841992d0fb054bb16   // 0xf_
    };

    // entry 0 (addr == 0) sits in the MSBs of SBOX_ROM
    assign dout = SBOX_ROM[(255 - addr) * 8 +: 8];

endmodule

`default_nettype wire
