//=============================================================================
// aes128_iterative.v -- AES-128 encryption core, iterative (low-area) variant
//
// One physical round datapath reused 10 times, with the key schedule computed
// on the fly alongside it. Targets resource-constrained deployments.
//
// Cost   : 1 round datapath (16 S-boxes) + 1 key-expand step (4 S-boxes)
// Latency: 11 clock cycles from `start` to `done`
//            cycle  1     : AddRoundKey with W[0..3]      (initial whitening)
//            cycles 2..11 : rounds 1..10
// Throughput: one 128-bit block per 11 cycles (back-to-back starts allowed
//             on the cycle `done` is high).
//
// Handshake:
//   start      pulse high for 1 cycle with key/plaintext valid; ignored while busy
//   busy       high from acceptance until the cycle before done
//   done       high for exactly 1 cycle; ciphertext valid on that cycle and
//              held until the next block is accepted
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module aes128_iterative (
    input  wire         clk,
    input  wire         rst_n,        // active-low synchronous reset

    input  wire         start,
    input  wire [127:0] key,
    input  wire [127:0] plaintext,

    output reg          busy,
    output reg          done,
    output reg  [127:0] ciphertext
);

    //-------------------------------------------------------------------------
    // State
    //-------------------------------------------------------------------------
    reg [127:0] state_r;    // running AES state
    reg [127:0] rkey_r;     // round key currently applied to state_r
    reg [7:0]   rcon_r;     // Rcon for the *next* key-expand step
    reg [3:0]   round_r;    // 1..10, round about to be executed

    //-------------------------------------------------------------------------
    // Shared datapath
    //-------------------------------------------------------------------------
    wire [127:0] rkey_next;
    aes_key_expand u_kexp (
        .key_in  (rkey_r),
        .rcon    (rcon_r),
        .key_out (rkey_next)
    );

    wire is_last = (round_r == 4'd10);

    wire [127:0] state_next;
    aes_round u_round (
        .state_in   (state_r),
        .round_key  (rkey_next),
        .last_round (is_last),
        .state_out  (state_next)
    );

    // Rcon advances 01,02,04,...,80,1b,36 -- xtime() in GF(2^8)
    wire [7:0] rcon_next = {rcon_r[6:0], 1'b0} ^ (rcon_r[7] ? 8'h1b : 8'h00);

    //-------------------------------------------------------------------------
    // Control
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            busy       <= 1'b0;
            done       <= 1'b0;
            state_r    <= 128'd0;
            rkey_r     <= 128'd0;
            rcon_r     <= 8'h01;
            round_r    <= 4'd0;
            ciphertext <= 128'd0;
        end else begin
            done <= 1'b0;

            if (!busy) begin
                if (start) begin
                    // cycle 1: initial AddRoundKey with W[0..3] (= the key itself)
                    state_r <= plaintext ^ key;
                    rkey_r  <= key;
                    rcon_r  <= 8'h01;
                    round_r <= 4'd1;
                    busy    <= 1'b1;
                end
            end else begin
                // cycles 2..11: execute round `round_r`
                state_r <= state_next;
                rkey_r  <= rkey_next;
                rcon_r  <= rcon_next;

                if (is_last) begin
                    ciphertext <= state_next;
                    done       <= 1'b1;
                    busy       <= 1'b0;
                    round_r    <= 4'd0;
                end else begin
                    round_r <= round_r + 4'd1;
                end
            end
        end
    end

endmodule

`default_nettype wire
