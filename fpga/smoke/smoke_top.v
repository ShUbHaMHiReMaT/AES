//=============================================================================
// smoke_top.v -- first-power-up check for the Nexys A7-100T
//
// Deliberately trivial, to prove the board, JTAG programming and USB-UART
// before the AES design goes on:
//
//   LED[15:0]   one LED walks LD0 -> LD15 at ~6 steps/s: clock + config OK
//   7-segment   "HELLO AES-128" scrolls across all 8 digits
//   UART        every byte received is sent straight back (115200 8N1)
//   CPU_RESET   held: LEDs and display freeze at their start position
//
// Uses the same uart_rx/uart_tx as the AES bridge, so a passing echo also
// checks those two modules on silicon.
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module smoke_top (
    input  wire        CLK100MHZ,
    input  wire        CPU_RESETN,
    input  wire        UART_TXD_IN,
    output wire        UART_RXD_OUT,
    output reg  [15:0] LED,
    output wire [6:0]  SEG,         // {CG,CF,CE,CD,CC,CB,CA}, active low
    output wire        DP,          // decimal point, active low
    output wire [7:0]  AN           // digit enables, active low; AN[7] = leftmost
);

    wire clk = CLK100MHZ;

    (* ASYNC_REG = "TRUE" *) reg [2:0] rst_sync = 3'b000;
    always @(posedge clk) rst_sync <= {rst_sync[1:0], CPU_RESETN};
    wire rst_n = rst_sync[2];

    // walking LED
    reg [23:0] div = 24'd0;
    initial LED = 16'h0001;
    always @(posedge clk) begin
        if (!rst_n) begin
            div <= 24'd0;
            LED <= 16'h0001;
        end else begin
            div <= div + 24'd1;
            if (div == 24'hffffff) LED <= {LED[14:0], LED[15]};
        end
    end

    //-------------------------------------------------------------------------
    // 7-segment display. The 8 digits share one set of segment lines, so they
    // are lit one at a time, each for 164 us (whole display ~760 Hz -- far
    // too fast to see flicker).
    //-------------------------------------------------------------------------
    // segments for message position i, active high, bit 0 = a ... bit 6 = g
    function [6:0] msg_seg;
        input [3:0] i;
        begin
            case (i)                       // "HELLO AES-128   "
                4'd0:  msg_seg = 7'h76;    // H
                4'd1:  msg_seg = 7'h79;    // E
                4'd2:  msg_seg = 7'h38;    // L
                4'd3:  msg_seg = 7'h38;    // L
                4'd4:  msg_seg = 7'h3f;    // O
                4'd5:  msg_seg = 7'h00;    // (space)
                4'd6:  msg_seg = 7'h77;    // A
                4'd7:  msg_seg = 7'h79;    // E
                4'd8:  msg_seg = 7'h6d;    // S
                4'd9:  msg_seg = 7'h40;    // -
                4'd10: msg_seg = 7'h06;    // 1
                4'd11: msg_seg = 7'h5b;    // 2
                4'd12: msg_seg = 7'h7f;    // 8
                default: msg_seg = 7'h00;  // trailing spaces
            endcase
        end
    endfunction

    reg [16:0] scan   = 17'd0;      // [16:14] = digit being lit
    reg [24:0] scroll = 25'd0;      // one step every 0.34 s
    reg [3:0]  pos    = 4'd0;       // message index shown on the leftmost digit

    always @(posedge clk) begin
        scan <= scan + 17'd1;
        if (!rst_n) begin
            scroll <= 25'd0;
            pos    <= 4'd0;
        end else begin
            scroll <= scroll + 25'd1;
            if (scroll == {25{1'b1}}) pos <= pos + 4'd1;   // wraps at 16
        end
    end

    wire [2:0] digit = scan[16:14];                 // 7 = leftmost
    wire [3:0] idx   = pos + (4'd7 - {1'b0, digit});

    reg [6:0] seg_r;
    reg [7:0] an_r;
    always @(posedge clk) begin
        seg_r <= ~msg_seg(idx);
        an_r  <= ~(8'd1 << digit);
    end

    initial begin
        seg_r = 7'h7f;
        an_r  = 8'hff;
    end

    assign SEG = seg_r;
    assign AN  = an_r;
    assign DP  = 1'b1;

    // UART echo
    wire [7:0] rx_data;
    wire       rx_valid, rx_ferr, tx_busy;
    uart_rx #(.CLKS_PER_BIT(868)) u_rx (
        .clk(clk), .rst_n(rst_n), .rx(UART_TXD_IN),
        .data(rx_data), .valid(rx_valid), .frame_err(rx_ferr)
    );
    uart_tx #(.CLKS_PER_BIT(868)) u_tx (
        .clk(clk), .rst_n(rst_n), .data(rx_data),
        .start(rx_valid), .busy(tx_busy), .tx(UART_RXD_OUT)
    );

endmodule

`default_nettype wire
