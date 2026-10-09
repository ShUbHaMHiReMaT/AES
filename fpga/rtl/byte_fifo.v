//=============================================================================
// byte_fifo.v -- synchronous byte FIFO, first-word-fall-through
//
// Buffers incoming UART bytes so the host can queue many requests ahead.
// That matters on Windows: the FTDI driver holds received data for up to its
// latency timer (16 ms by default), so a host that waits for each response
// before sending the next request gets ~100 blocks/s. With requests queued
// here, the link stays busy and the timer stops mattering.
//
// Storage is inferred as block RAM (registered read); one output register
// makes the head byte visible without a read request (dout valid when
// `valid`; `rd` consumes it).
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module byte_fifo #(
    parameter integer AW = 12               // 4096 bytes = one RAMB36
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       wr,
    input  wire [7:0] din,
    output wire       full,
    input  wire       rd,
    output reg  [7:0] dout,
    output reg        valid
);

    reg [7:0]  mem [0:(1 << AW) - 1];
    reg [AW:0] wp, rp;

    wire mem_empty = (wp == rp);
    assign full = (wp - rp) == (1 << AW);

    always @(posedge clk) begin
        if (wr && !full) mem[wp[AW-1:0]] <= din;
    end

    // refill the output register whenever it is empty or being consumed
    wire fetch = !mem_empty && (!valid || rd);

    always @(posedge clk) begin
        if (fetch) dout <= mem[rp[AW-1:0]];
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            wp    <= {(AW+1){1'b0}};
            rp    <= {(AW+1){1'b0}};
            valid <= 1'b0;
        end else begin
            if (wr && !full) wp <= wp + 1'b1;
            if (fetch) begin
                rp    <= rp + 1'b1;
                valid <= 1'b1;
            end else if (rd) begin
                valid <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
