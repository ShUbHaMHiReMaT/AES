//=============================================================================
// aes128_iterative_ii10.v -- AES-128 iterative core, overlapped (II = 10)
//
// Same single round datapath as aes128_iterative.v, but the initial
// AddRoundKey ("whitening") lives in its own small register stage so it can
// overlap with round 10 of the *previous* block. That removes the whitening
// cycle from the recurrence:
//
//   plain    : round datapath busy 10 cycles + 1 whitening cycle -> II = 11
//   this core: whitening overlaps round 10 of block N-1          -> II = 10
//
// Latency   : 11 cycles (unchanged -- the whitened block feeds the round
//             datapath combinationally on its first round, no extra hop)
// Throughput: 128 bits / 10 cycles x f_clk
//               at 384.6 MHz -> 4.92 Gbps   <-- the project's target figure
// Cost over the plain iterative core: one 128-bit state register, one 128-bit
//             key register, and two 128-bit 2:1 muxes (~128 FF + ~128 LUT).
//
// Handshake:
//   ready    high when a new block can be accepted this cycle
//   start    accepted on any cycle where ready is high
//   done     1-cycle pulse; ciphertext valid on that cycle and held after
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module aes128_iterative_ii10 (
    input  wire         clk,
    input  wire         rst_n,        // active-low synchronous reset

    output wire         ready,
    input  wire         start,
    input  wire [127:0] key,
    input  wire [127:0] plaintext,

    output reg          done,
    output reg  [127:0] ciphertext
);

    //-------------------------------------------------------------------------
    // Whitening stage
    //-------------------------------------------------------------------------
    reg [127:0] w_state;    // plaintext ^ W[0..3]
    reg [127:0] w_key;      // W[0..3] for this block
    reg         w_valid;    // a whitened block is parked here

    //-------------------------------------------------------------------------
    // Round stage
    //-------------------------------------------------------------------------
    reg [127:0] r_state;
    reg [127:0] r_rkey;
    reg [7:0]   r_rcon;
    reg [3:0]   r_round;    // round being executed this cycle, 1..10
    reg         r_busy;

    //-------------------------------------------------------------------------
    // Round-1 bypass: on its first round a block is read straight out of the
    // whitening registers, so entering the round stage costs no extra cycle.
    //-------------------------------------------------------------------------
    wire        first     = (r_round == 4'd1);
    wire [127:0] cur_state = first ? w_state : r_state;
    wire [127:0] cur_rkey  = first ? w_key   : r_rkey;
    wire [7:0]   cur_rcon  = first ? 8'h01   : r_rcon;

    wire [127:0] rkey_next;
    aes_key_expand u_kexp (
        .key_in  (cur_rkey),
        .rcon    (cur_rcon),
        .key_out (rkey_next)
    );

    wire is_last = (r_round == 4'd10);

    wire [127:0] state_next;
    aes_round u_round (
        .state_in   (cur_state),
        .round_key  (rkey_next),
        .last_round (is_last),
        .state_out  (state_next)
    );

    wire [7:0] rcon_next = {cur_rcon[6:0], 1'b0} ^ (cur_rcon[7] ? 8'h1b : 8'h00);

    //-------------------------------------------------------------------------
    // Scheduling
    //-------------------------------------------------------------------------
    // The whitening stage is free whenever it is not holding a parked block.
    assign ready = !w_valid;

    wire start_accept = start && ready;

    // Round datapath is available for a new block on the next cycle if it is
    // idle, or if it is finishing round 10 right now.
    wire free_next = !r_busy || is_last;

    // A block moves into the round datapath next cycle: either the parked one,
    // or -- when the whitening stage is empty -- the one arriving right now,
    // which bypasses straight through (w_state is written this edge and read
    // on the next cycle, so the bypass costs nothing).
    wire enter = free_next && (w_valid || start_accept);

    always @(posedge clk) begin
        if (!rst_n) begin
            w_state    <= 128'd0;
            w_key      <= 128'd0;
            w_valid    <= 1'b0;
            r_state    <= 128'd0;
            r_rkey     <= 128'd0;
            r_rcon     <= 8'h01;
            r_round    <= 4'd0;
            r_busy     <= 1'b0;
            done       <= 1'b0;
            ciphertext <= 128'd0;
        end else begin
            done <= 1'b0;

            //-- whitening stage ------------------------------------------------
            if (start_accept) begin
                w_state <= plaintext ^ key;
                w_key   <= key;
            end
            // start_accept implies !w_valid, so these two cases never collide
            if (start_accept) w_valid <= !enter;
            else if (enter)   w_valid <= 1'b0;

            //-- round datapath -------------------------------------------------
            if (r_busy) begin
                r_state <= state_next;
                r_rkey  <= rkey_next;
                r_rcon  <= rcon_next;
                if (is_last) begin
                    ciphertext <= state_next;
                    done       <= 1'b1;
                end
            end

            if (enter) begin
                r_busy  <= 1'b1;
                r_round <= 4'd1;
            end else if (r_busy) begin
                if (is_last) r_busy  <= 1'b0;
                else         r_round <= r_round + 4'd1;
            end
        end
    end

endmodule

`default_nettype wire
