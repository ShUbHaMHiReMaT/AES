//=============================================================================
// xadc_mon.v -- die temperature and VCCINT from the Artix-7 XADC
//
// The XADC runs in its default mode, in which it samples the on-chip sensors
// continuously with no configuration. This module reads the two result
// registers over the DRP every ~1.3 ms. Raw 16-bit codes are returned; the
// 12-bit result is in [15:4]:
//
//   temperature (C) = code12 x 503.975 / 4096 - 273.15
//   VCCINT      (V) = code12 x 3 / 4096
//
// In simulation (no SYNTHESIS macro) the primitive is replaced by constants
// equal to 30.0 C and 1.000 V, so the testbench needs no UNISIM library.
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module xadc_mon (
    input  wire        clk,
    input  wire        rst_n,
    output reg  [15:0] temp,
    output reg  [15:0] vccint
);

`ifdef SYNTHESIS
    reg  [6:0]  daddr;
    reg         den;
    wire        drdy;
    wire [15:0] dout;

    XADC #(
        .INIT_40 (16'h0000),    // no averaging override
        .INIT_41 (16'h0FFF),    // default sequencer mode, alarms off, calibration on
        .INIT_42 (16'h0400)     // ADCCLK = DCLK / 4 = 25 MHz (max 26)
    ) u_xadc (
        .DCLK        (clk),
        .RESET       (1'b0),
        .DADDR       (daddr),
        .DEN         (den),
        .DWE         (1'b0),
        .DI          (16'h0000),
        .DO          (dout),
        .DRDY        (drdy),
        .CONVST      (1'b0),
        .CONVSTCLK   (1'b0),
        .VP          (1'b0),
        .VN          (1'b0),
        .VAUXP       (16'h0000),
        .VAUXN       (16'h0000),
        .ALM         (),
        .OT          (),
        .BUSY        (),
        .CHANNEL     (),
        .EOC         (),
        .EOS         (),
        .JTAGBUSY    (),
        .JTAGLOCKED  (),
        .JTAGMODIFIED(),
        .MUXADDR     ()
    );

    // A DRP request can go unanswered: while JTAG holds the DRP (Vivado's
    // Hardware Manager reads the sensors during and after programming),
    // DEN from the fabric is ignored. So every request has a timeout and is
    // simply retried on the next tick rather than waiting forever.
    reg [16:0] tmr;
    reg        waiting;
    reg [9:0]  wait_cnt;
    reg        ch;              // 0 = temperature, 1 = VCCINT

    always @(posedge clk) begin
        den <= 1'b0;
        if (!rst_n) begin
            tmr      <= 17'd1;
            waiting  <= 1'b0;
            wait_cnt <= 10'd0;
            ch       <= 1'b0;
            daddr    <= 7'h00;
            temp     <= 16'd0;
            vccint   <= 16'd0;
        end else if (!waiting) begin
            tmr <= tmr + 17'd1;
            if (tmr == 17'd0) begin
                daddr    <= ch ? 7'h01 : 7'h00;
                den      <= 1'b1;
                waiting  <= 1'b1;
                wait_cnt <= 10'd0;
            end
        end else if (drdy) begin
            if (ch) vccint <= dout;
            else    temp   <= dout;
            ch      <= ~ch;
            waiting <= 1'b0;
            tmr     <= 17'd1;
        end else if (wait_cnt == 10'h3ff) begin
            waiting <= 1'b0;            // no answer in ~10 us: retry later
            tmr     <= 17'd1;
        end else begin
            wait_cnt <= wait_cnt + 10'd1;
        end
    end
`else
    always @(posedge clk) begin
        temp   <= 16'h9a00;     // 30.0 C
        vccint <= 16'h5550;     // 1.000 V
    end
`endif

endmodule

`default_nettype wire
