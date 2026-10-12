//=============================================================================
// tdc_sensor.v -- on-chip power/voltage sensor (no external hardware)
//
// A time-to-digital converter made from the FPGA's own carry chain. Every
// clock a launch edge is fired into a long CARRY4 delay line; how far it
// propagates in one clock period depends on the transistor delay, which
// depends on the core supply voltage, which dips a little every time the
// nearby AES logic switches. Sampling the chain and counting how many taps
// the edge reached gives a number that rises and falls with the chip's
// instantaneous power draw -- the same signal an attacker would normally
// need an oscilloscope and a probe to see.
//
//   sample (8 bit) = population count of the delay-line taps, one per clock
//
// This is a passive observer: it is wired to nothing in the AES datapath and
// cannot change the ciphertext. It only exists in the capture unit and is
// idle unless a trace is being recorded.
//
// For simulation (no CARRY4 primitive) a behavioural model stands in: it is
// driven by `activity`, a running bit-switch estimate of the AES state, so
// the testbench produces data-dependent traces and the tool-chain can be
// exercised without the board. Define SYNTHESIS for the real sensor.
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tdc_sensor #(
    parameter integer NBLK = 32          // CARRY4 blocks -> NBLK*4 taps
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  activity,         // sim-only: switching estimate
    output reg  [7:0]  sample
);
    localparam integer NTAPS = NBLK * 4;

    // launch edge, toggles every clock so there is always a transition to time
    reg launch = 1'b0;
    always @(posedge clk) launch <= ~launch;

`ifdef SYNTHESIS
    //-------------------------------------------------------------------------
    // Real delay line: NBLK CARRY4s in series, all stages set to propagate
    // (S = 1111) so the launch level ripples down the carry chain. The chain
    // is sampled into FFs; the number of high taps is the delay measurement.
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

    integer b;
    reg [15:0] pc;
    always @(posedge clk) begin
        if (!rst_n) begin
            sample <= 8'd0;
        end else begin
            pc = 16'd0;
            for (b = 0; b < NTAPS; b = b + 1) pc = pc + tap_qq[b];
            sample <= (pc > 16'd255) ? 8'd255 : pc[7:0];
        end
    end
`else
    //-------------------------------------------------------------------------
    // Behavioural stand-in for simulation: delay-line length modulated by the
    // AES switching activity plus a little pseudo-random jitter, so captured
    // traces are data-dependent and the host tool-chain can be tested.
    //-------------------------------------------------------------------------
    reg [15:0] jit = 16'hACE1;
    always @(posedge clk) begin
        if (!rst_n) begin
            jit    <= 16'hACE1;
            sample <= 8'd0;
        end else begin
            jit    <= {jit[14:0], jit[15] ^ jit[13] ^ jit[12] ^ jit[10]};
            // centre ~100, swing with activity, dither with the LFSR
            sample <= 8'd100 + activity[7:2] + {4'd0, jit[3:0]}
                      + (launch ? 8'd2 : 8'd0);
        end
    end
`endif

endmodule

`default_nettype wire
