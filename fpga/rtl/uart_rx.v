//=============================================================================
// uart_rx.v -- 8N1 UART receiver
//
// Samples the middle of each bit. The input is asynchronous to clk, so it is
// passed through a two-flop synchroniser before anything looks at it.
//
//   CLKS_PER_BIT = f_clk / baud      100 MHz / 115200 -> 868
//
// valid pulses for one cycle with the byte on data. A stop bit that reads low
// (framing error / line break) pulses frame_err instead and the byte is
// dropped, so a garbled byte never reaches the frame assembler.
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module uart_rx #(
    parameter integer CLKS_PER_BIT = 868
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,
    output reg  [7:0] data,
    output reg        valid,
    output reg        frame_err
);

    // idle-high line: initialise the synchroniser high so power-up does not
    // look like a start bit
    (* ASYNC_REG = "TRUE" *) reg rx_meta = 1'b1;
    (* ASYNC_REG = "TRUE" *) reg rx_sync = 1'b1;
    always @(posedge clk) begin
        rx_meta <= rx;
        rx_sync <= rx_meta;
    end

    localparam [1:0] S_IDLE  = 2'd0,
                     S_START = 2'd1,
                     S_DATA  = 2'd2,
                     S_STOP  = 2'd3;

    reg [1:0]  st;
    reg [19:0] cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  shreg;

    always @(posedge clk) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            cnt       <= 20'd0;
            bit_idx   <= 3'd0;
            shreg     <= 8'd0;
            data      <= 8'd0;
            valid     <= 1'b0;
            frame_err <= 1'b0;
        end else begin
            valid     <= 1'b0;
            frame_err <= 1'b0;

            case (st)
                S_IDLE:
                    if (!rx_sync) begin
                        st  <= S_START;
                        cnt <= 20'd0;
                    end

                // re-check the start bit half a bit in; a glitch shorter than
                // that returns to idle instead of producing a byte
                S_START:
                    if (cnt == CLKS_PER_BIT / 2 - 1) begin
                        cnt <= 20'd0;
                        if (!rx_sync) begin
                            st      <= S_DATA;
                            bit_idx <= 3'd0;
                        end else begin
                            st <= S_IDLE;
                        end
                    end else begin
                        cnt <= cnt + 20'd1;
                    end

                // LSB first
                S_DATA:
                    if (cnt == CLKS_PER_BIT - 1) begin
                        cnt   <= 20'd0;
                        shreg <= {rx_sync, shreg[7:1]};
                        if (bit_idx == 3'd7) st <= S_STOP;
                        else                 bit_idx <= bit_idx + 3'd1;
                    end else begin
                        cnt <= cnt + 20'd1;
                    end

                S_STOP:
                    if (cnt == CLKS_PER_BIT - 1) begin
                        st <= S_IDLE;
                        if (rx_sync) begin
                            data  <= shreg;
                            valid <= 1'b1;
                        end else begin
                            frame_err <= 1'b1;
                        end
                    end else begin
                        cnt <= cnt + 20'd1;
                    end
            endcase
        end
    end

endmodule

`default_nettype wire
