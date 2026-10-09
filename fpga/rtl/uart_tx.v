//=============================================================================
// uart_tx.v -- 8N1 UART transmitter
//
// start is sampled only while busy is low; busy rises on the same edge that
// accepts the byte, so a caller driving start = want && !busy cannot issue
// the same byte twice.
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module uart_tx #(
    parameter integer CLKS_PER_BIT = 868
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data,
    input  wire       start,
    output reg        busy,
    output reg        tx
);

    // line idles high from configuration onwards, not just after reset
    initial tx = 1'b1;

    reg [9:0]  shreg;       // {stop, data[7:0], start}, shifted out LSB first
    reg [3:0]  n_bit;       // index of the bit currently on the line, 0..9
    reg [19:0] cnt;

    always @(posedge clk) begin
        if (!rst_n) begin
            busy  <= 1'b0;
            tx    <= 1'b1;
            shreg <= 10'h3ff;
            n_bit <= 4'd0;
            cnt   <= 20'd0;
        end else if (!busy) begin
            tx <= 1'b1;
            if (start) begin
                shreg <= {1'b1, data, 1'b0};
                busy  <= 1'b1;
                n_bit <= 4'd0;
                cnt   <= 20'd0;
                tx    <= 1'b0;                  // start bit
            end
        end else if (cnt == CLKS_PER_BIT - 1) begin
            cnt <= 20'd0;
            if (n_bit == 4'd9) begin            // stop bit has had its full period
                busy <= 1'b0;
                tx   <= 1'b1;
            end else begin
                n_bit <= n_bit + 4'd1;
                shreg <= {1'b1, shreg[9:1]};
                tx    <= shreg[1];
            end
        end else begin
            cnt <= cnt + 20'd1;
        end
    end

endmodule

`default_nettype wire
