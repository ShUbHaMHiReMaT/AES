//=============================================================================
// tdc_sensor.v -- on-chip power/voltage sensor (no external hardware)
//
// A time-to-digital converter made from the FPGA's own carry chain. Every
// clock a launch edge is fired into a long CARRY4 delay line; how far it
// propagates in one clock period depends on transistor delay, which depends
// on the core supply voltage, which dips every time the nearby AES logic
// switches. Counting how many taps the edge reached gives a number that
// tracks the chip's instantaneous power draw -- the signal an attacker would
// normally need an oscilloscope and a probe to see.
//
// Calibration without rebuilding: the raw tap count can be hundreds, while a
// trace sample is one byte, and the useful (data-dependent) swing is only a
// few taps sitting on a large DC level. So the readout is HOST-TUNABLE:
//
//     sample = clamp( (popcount >> shift) - off , 0 , 255 )
//
// The host sweeps `shift`/`off` (command 0x51) until the samples sit in the
// middle of 0..255 with real variance -- turning sensor calibration into a
// software sweep instead of a 20-minute re-synthesis.
//
// This is a passive observer wired to nothing in the AES datapath; it cannot
// change the ciphertext. Define SYNTHESIS for the real sensor; a behavioural
// model stands in for simulation.
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tdc_sensor #(
    parameter integer NBLK = 128                 // CARRY4 blocks -> NBLK*4 taps
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [2:0]  shift,                     // host calibration: right-shift
    input  wire [7:0]  off,                       // host calibration: DC offset
    input  wire [7:0]  activity,                  // sim-only switching estimate
    output reg  [7:0]  sample
);
    localparam integer NTAPS = NBLK * 4;          // 512 taps by default

    // launch edge, toggles every clock so there is always a transition to time
    reg launch = 1'b0;
    always @(posedge clk) launch <= ~launch;

`ifdef SYNTHESIS
    //-------------------------------------------------------------------------
    // Long delay line: NBLK CARRY4s in series, every stage set to propagate
    // (S = 1111) so the launch level ripples down the carry chain. Making the
    // chain much longer than one period's worth of propagation guarantees the
    // edge lands partway along it, so the tap count is graded (not railed).
    //-------------------------------------------------------------------------
    wire [NTAPS-1:0] co;
    genvar i;
    generate
        for (i = 0; i < NBLK; i = i + 1) begin : dl
            (* DONT_TOUCH = "true" *)
            CARRY4 u_c4 (
                .CO     (co[i*4 +: 4]),
                .O      (),
                .CI     (i == 0 ? 1'b0    : co[i*4-1]),
                .CYINIT (i == 0 ? launch  : 1'b0),
                .DI     (4'b0000),
                .S      (4'b1111)
            );
        end
    endgenerate

    (* ASYNC_REG = "true", DONT_TOUCH = "true" *) reg [NTAPS-1:0] tap_q;
    (* ASYNC_REG = "true" *)                      reg [NTAPS-1:0] tap_qq;
    always @(posedge clk) begin
        tap_q  <= co;
        tap_qq <= tap_q;
    end

    // Two-stage population count so a 1024-input add never sits on one clock:
    // stage 1 sums four quarter-chains, stage 2 adds the quarters.
    localparam integer Q = NTAPS / 4;
    integer b;
    reg [11:0] q0, q1, q2, q3;
    reg [12:0] pc;
    always @(posedge clk) begin
        q0 = 12'd0; q1 = 12'd0; q2 = 12'd0; q3 = 12'd0;
        for (b = 0;     b < Q;     b = b + 1) q0 = q0 + tap_qq[b];
        for (b = Q;     b < 2*Q;   b = b + 1) q1 = q1 + tap_qq[b];
        for (b = 2*Q;   b < 3*Q;   b = b + 1) q2 = q2 + tap_qq[b];
        for (b = 3*Q;   b < NTAPS; b = b + 1) q3 = q3 + tap_qq[b];
        pc <= q0 + q1 + q2 + q3;
    end

    // host-tunable mapping of the big count into one byte
    wire [12:0] sh  = pc >> shift;
    wire [12:0] sub = (sh > {5'd0, off}) ? (sh - {5'd0, off}) : 13'd0;
    always @(posedge clk) begin
        if (!rst_n) sample <= 8'd0;
        else        sample <= (sub > 13'd255) ? 8'd255 : sub[7:0];
    end
`else
    //-------------------------------------------------------------------------
    // Behavioural stand-in for simulation: a centred value modulated by the
    // AES switching activity plus LFSR jitter, so captured traces are
    // data-dependent and the host tool-chain can be tested without the board.
    //-------------------------------------------------------------------------
    reg [15:0] jit = 16'hACE1;
    always @(posedge clk) begin
        if (!rst_n) begin
            jit    <= 16'hACE1;
            sample <= 8'd0;
        end else begin
            jit    <= {jit[14:0], jit[15] ^ jit[13] ^ jit[12] ^ jit[10]};
            sample <= 8'd100 + activity[7:2] + {4'd0, jit[3:0]}
                      + (launch ? 8'd2 : 8'd0);
        end
    end
    // reference the calibration inputs so they are not flagged unused in sim
    wire _unused_cal = &{1'b0, shift, off};
`endif

endmodule

`default_nettype wire
