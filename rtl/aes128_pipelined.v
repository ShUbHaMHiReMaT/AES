//=============================================================================
// aes128_pipelined.v -- AES-128 encryption core, fully unrolled pipeline
//
// 10 round datapaths in series, one pipeline register per round, plus a
// register stage for the initial AddRoundKey. The key schedule is unrolled
// alongside the data so each stage carries its own round key -- this lets the
// key change on any cycle without flushing the pipe.
//
// Cost      : 10 round datapaths (160 S-boxes) + 10 key-expand steps (40)
// Latency   : 11 clock cycles
// Throughput: one 128-bit block per clock once full
//               128 bits/cycle x f_max  ->  at 384.6 MHz = 49.2 Gbps
//             (The 4.92 Gbps figure in the spec is the *iterative* number:
//              128 bits / 10 cycles x 384.6 MHz. See README for the arithmetic.)
//
// in_valid marks key/plaintext as live; out_valid follows 11 cycles later with
// the matching ciphertext. There is no backpressure -- the pipe never stalls.
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module aes128_pipelined (
    input  wire         clk,
    input  wire         rst_n,        // active-low synchronous reset

    input  wire         in_valid,
    input  wire [127:0] key,
    input  wire [127:0] plaintext,

    output wire         out_valid,
    output wire [127:0] ciphertext
);

    localparam [79:0] RCON = 80'h01_02_04_08_10_20_40_80_1b_36;

    // stage 0 = initial AddRoundKey, stages 1..10 = rounds 1..10
    reg [127:0] state_p [0:10];
    reg [127:0] rkey_p  [0:10];
    reg [10:0]  valid_p;

    //-------------------------------------------------------------------------
    // Stage 0: initial AddRoundKey with W[0..3]
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            state_p[0] <= 128'd0;
            rkey_p [0] <= 128'd0;
        end else begin
            state_p[0] <= plaintext ^ key;
            rkey_p [0] <= key;
        end
    end

    //-------------------------------------------------------------------------
    // Stages 1..10
    //-------------------------------------------------------------------------
    genvar r;
    generate
        for (r = 1; r <= 10; r = r + 1) begin : g_round
            wire [127:0] rkey_w;
            wire [127:0] state_w;

            aes_key_expand u_kexp (
                .key_in  (rkey_p[r-1]),
                .rcon    (RCON[(10-r)*8 +: 8]),
                .key_out (rkey_w)
            );

            aes_round u_round (
                .state_in   (state_p[r-1]),
                .round_key  (rkey_w),
                .last_round (r == 10),
                .state_out  (state_w)
            );

            always @(posedge clk) begin
                if (!rst_n) begin
                    state_p[r] <= 128'd0;
                    rkey_p [r] <= 128'd0;
                end else begin
                    state_p[r] <= state_w;
                    rkey_p [r] <= rkey_w;
                end
            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // Valid shift register, same depth as the datapath
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) valid_p <= 11'd0;
        else        valid_p <= {valid_p[9:0], in_valid};
    end

    assign ciphertext = state_p[10];
    assign out_valid  = valid_p[10];

endmodule

`default_nettype wire
