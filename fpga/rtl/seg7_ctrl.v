//=============================================================================
// seg7_ctrl.v -- 8-digit 7-segment display driver
//
// Two sources:
//   auto mode   8 patterns from the top level (self-test result, etc.)
//   page mode   up to 64 patterns written by the host, static or scrolling
//
// Patterns: bit 7 = DP, bits 6:0 = g..a, 1 = lit. The host does the font,
// so the board shows whatever the page draws.
//
// commit cfg = {flags[7:0], speed[7:0], len[7:0], unused[7:0]}
//   flags bit 0     scroll (needs len >= 8; the host pads)
//         bits 3:1  brightness 0..7
//         bit 4     1 = page mode, 0 = back to auto
//   scroll step = (speed + 1) x 21 ms
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module seg7_ctrl (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        we,
    input  wire [5:0]  waddr,
    input  wire [7:0]  wdata,

    input  wire        commit,
    input  wire [31:0] cfg,

    input  wire [63:0] auto_segs,   // leftmost digit in [63:56]

    output wire [6:0]  SEG,         // active low
    output wire        DP,          // active low
    output wire [7:0]  AN,          // active low, AN[7] = leftmost
    output reg         page_mode
);

    reg [7:0] buffer [0:63];
    integer n;
    initial for (n = 0; n < 64; n = n + 1) buffer[n] = 8'h00;
    always @(posedge clk) if (we) buffer[waddr] <= wdata;

    reg [6:0] len;
    reg       scroll;
    reg [2:0] bright;
    reg [7:0] speed;

    always @(posedge clk) begin
        if (!rst_n) begin
            page_mode <= 1'b0;
            len       <= 7'd8;
            scroll    <= 1'b0;
            bright    <= 3'd7;
            speed     <= 8'd15;
        end else if (commit) begin
            page_mode <= cfg[28];
            len       <= (cfg[15:8] == 8'd0) ? 7'd1
                       : (cfg[15:8] > 8'd64) ? 7'd64 : cfg[14:8];
            scroll    <= cfg[24] && (cfg[15:8] >= 8'd8);
            bright    <= cfg[27:25];
            speed     <= cfg[23:16];
        end
    end

    //-------------------------------------------------------------------------
    // Scrolling
    //-------------------------------------------------------------------------
    reg [20:0] tick = 21'd0;            // 2^21 cycles = 21 ms
    reg [7:0]  step_cnt = 8'd0;
    reg [6:0]  pos = 7'd0;

    always @(posedge clk) begin
        tick <= tick + 21'd1;
        if (commit) begin
            pos      <= 7'd0;
            step_cnt <= 8'd0;
        end else if (scroll && tick == {21{1'b1}}) begin
            if (step_cnt >= speed) begin
                step_cnt <= 8'd0;
                pos      <= (pos >= len - 7'd1) ? 7'd0 : pos + 7'd1;
            end else begin
                step_cnt <= step_cnt + 8'd1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // Multiplexing: 164 us per digit, whole display ~760 Hz
    //-------------------------------------------------------------------------
    reg [16:0] scan = 17'd0;
    always @(posedge clk) scan <= scan + 17'd1;

    wire [2:0] digit = scan[16:14];             // 7 = leftmost
    wire [2:0] k     = 3'd7 - digit;            // 0 = leftmost character
    wire       lit   = (scan[13:11] <= bright) || !page_mode;

    wire [7:0] raw = {1'b0, pos} + {5'd0, k};
    wire [7:0] idx = scroll ? ((raw >= {1'b0, len}) ? raw - {1'b0, len} : raw)
                            : {5'd0, k};
    wire       in_range = scroll || ({4'd0, k} < len);

    wire [7:0] page_seg = in_range ? buffer[idx[5:0]] : 8'h00;
    wire [7:0] auto_seg = auto_segs[(7 - k) * 8 +: 8];

    reg [7:0] seg_r = 8'h00;
    reg [7:0] an_r  = 8'hff;
    always @(posedge clk) begin
        seg_r <= page_mode ? page_seg : auto_seg;
        an_r  <= lit ? ~(8'd1 << digit) : 8'hff;
    end

    assign SEG = ~seg_r[6:0];
    assign DP  = ~seg_r[7];
    assign AN  = an_r;

endmodule

`default_nettype wire
