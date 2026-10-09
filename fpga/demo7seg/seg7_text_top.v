//=============================================================================
// seg7_text_top.v -- show text sent from a web page on the 7-segment display
//
// The page (fpga/web/seg7_demo.html) does the font: it turns each character
// into a segment pattern and sends the patterns, so any glyph the page can
// draw, the board can show. The FPGA only stores and displays them.
//
// Frame, PC -> FPGA (115200 8N1):
//   [0xA5] [flags] [speed] [len] [seg 0] ... [seg len-1]
//     flags  bit 0     1 = scroll, 0 = static (first 8 patterns)
//            bits 3:1  brightness 0..7 (7 = full)
//     speed  scroll step = (speed + 1) x 21 ms
//     len    1..64; scrolling needs len >= 8 (the page pads)
//     seg    bit 7 = DP, bits 6:0 = g..a, 1 = lit
// Reply, FPGA -> PC: [0x5A] [len] once the new text is on the display.
//
// A partial frame is dropped after 20 ms of silence, so the page can always
// resynchronise by pausing.
//
// LEDs: LD7..LD0 = length of the current text, LD14 = byte received,
//       LD15 = heartbeat.
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module seg7_text_top (
    input  wire        CLK100MHZ,
    input  wire        CPU_RESETN,
    input  wire        UART_TXD_IN,
    output wire        UART_RXD_OUT,
    output wire [15:0] LED,
    output wire [6:0]  SEG,         // {CG..CA}, active low
    output wire        DP,          // active low
    output wire [7:0]  AN           // active low, AN[7] = leftmost
);

    localparam integer CLKS_PER_BIT = 868;          // 115200 at 100 MHz
    localparam integer RX_TIMEOUT   = 2_000_000;    // 20 ms
    localparam integer MAX_LEN      = 64;

    wire clk = CLK100MHZ;

    (* ASYNC_REG = "TRUE" *) reg [2:0] rst_sync = 3'b000;
    always @(posedge clk) rst_sync <= {rst_sync[1:0], CPU_RESETN};
    wire rst_n = rst_sync[2];

    //-------------------------------------------------------------------------
    // UART
    //-------------------------------------------------------------------------
    wire [7:0] rx_data;
    wire       rx_valid, rx_ferr, tx_busy;
    reg  [7:0] tx_data;
    reg        tx_go;

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(clk), .rst_n(rst_n), .rx(UART_TXD_IN),
        .data(rx_data), .valid(rx_valid), .frame_err(rx_ferr)
    );
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .rst_n(rst_n), .data(tx_data),
        .start(tx_go && !tx_busy), .busy(tx_busy), .tx(UART_RXD_OUT)
    );

    //-------------------------------------------------------------------------
    // Display memory. Two copies: the frame is received into rx_buf and
    // copied to disp_buf only when complete, so a half-received message is
    // never shown.
    //-------------------------------------------------------------------------
    reg [7:0] rx_buf   [0:MAX_LEN-1];
    reg [7:0] disp_buf [0:MAX_LEN-1];

    reg [6:0] disp_len;
    reg       disp_scroll;
    reg [2:0] disp_bright;
    reg [7:0] disp_speed;

    // power-up text: "HI PC" -- static, until the page sends something
    integer n;
    initial begin
        for (n = 0; n < MAX_LEN; n = n + 1) begin
            rx_buf[n]   = 8'h00;
            disp_buf[n] = 8'h00;
        end
        disp_buf[0] = 8'h76;    // H
        disp_buf[1] = 8'h30;    // I
        disp_buf[3] = 8'h73;    // P
        disp_buf[4] = 8'h39;    // C
        disp_len    = 7'd8;
        disp_scroll = 1'b0;
        disp_bright = 3'd7;
        disp_speed  = 8'd15;
    end

    //-------------------------------------------------------------------------
    // Frame receiver
    //-------------------------------------------------------------------------
    localparam [2:0] S_SYNC  = 3'd0,
                     S_FLAGS = 3'd1,
                     S_SPEED = 3'd2,
                     S_LEN   = 3'd3,
                     S_DATA  = 3'd4,
                     S_COPY  = 3'd5,
                     S_ACK0  = 3'd6,
                     S_ACK1  = 3'd7;

    reg [2:0]  st;
    reg [7:0]  f_flags, f_speed;
    reg [6:0]  f_len;
    reg [6:0]  f_idx;
    reg [31:0] idle;
    reg        commit;          // pulses when disp_* takes the new frame

    always @(posedge clk) begin
        commit <= 1'b0;
        if (!rst_n) begin
            st    <= S_SYNC;
            idle  <= 32'd0;
            tx_go <= 1'b0;
        end else begin
            // drop a stalled partial frame
            if (st != S_SYNC && st < S_COPY && !rx_valid) begin
                if (idle == RX_TIMEOUT - 1) st <= S_SYNC;
                idle <= idle + 32'd1;
            end else begin
                idle <= 32'd0;
            end

            case (st)
                S_SYNC:  if (rx_valid && rx_data == 8'ha5) st <= S_FLAGS;
                S_FLAGS: if (rx_valid) begin f_flags <= rx_data; st <= S_SPEED; end
                S_SPEED: if (rx_valid) begin f_speed <= rx_data; st <= S_LEN;   end
                S_LEN:   if (rx_valid) begin
                             if (rx_data == 8'd0 || rx_data > MAX_LEN) begin
                                 st <= S_SYNC;              // malformed
                             end else begin
                                 f_len <= rx_data[6:0];
                                 f_idx <= 7'd0;
                                 st    <= S_DATA;
                             end
                         end
                S_DATA:  if (rx_valid) begin
                             rx_buf[f_idx[5:0]] <= rx_data;
                             if (f_idx == f_len - 7'd1) begin
                                 f_idx <= 7'd0;
                                 st    <= S_COPY;
                             end else begin
                                 f_idx <= f_idx + 7'd1;
                             end
                         end
                // one byte per cycle, 64 cycles: invisible on the display
                S_COPY:  begin
                             disp_buf[f_idx[5:0]] <= rx_buf[f_idx[5:0]];
                             if (f_idx == MAX_LEN - 1) begin
                                 disp_len    <= f_len;
                                 disp_scroll <= f_flags[0] && (f_len >= 7'd8);
                                 disp_bright <= f_flags[3:1];
                                 disp_speed  <= f_speed;
                                 commit      <= 1'b1;
                                 tx_data     <= 8'h5a;
                                 tx_go       <= 1'b1;
                                 st          <= S_ACK0;
                             end
                             f_idx <= f_idx + 7'd1;
                         end
                S_ACK0:  if (!tx_busy) begin        // 0x5A accepted this edge
                             tx_data <= {1'b0, f_len};
                             st      <= S_ACK1;
                         end
                S_ACK1:  if (!tx_busy) begin
                             tx_go <= 1'b0;
                             st    <= S_SYNC;
                         end
                default: st <= S_SYNC;
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // Scrolling
    //-------------------------------------------------------------------------
    reg [20:0] tick = 21'd0;        // 2^21 cycles = 21 ms
    reg [7:0]  step_cnt = 8'd0;
    reg [6:0]  pos = 7'd0;          // buffer index on the leftmost digit

    always @(posedge clk) begin
        tick <= tick + 21'd1;
        if (commit) begin
            pos      <= 7'd0;
            step_cnt <= 8'd0;
        end else if (disp_scroll && tick == {21{1'b1}}) begin
            if (step_cnt >= disp_speed) begin
                step_cnt <= 8'd0;
                pos      <= (pos == disp_len - 7'd1) ? 7'd0 : pos + 7'd1;
            end else begin
                step_cnt <= step_cnt + 8'd1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // Multiplexing: one digit at a time, 164 us each, whole display ~760 Hz.
    // Brightness dims by lighting the digit for only part of its slot.
    //-------------------------------------------------------------------------
    reg [16:0] scan = 17'd0;
    always @(posedge clk) scan <= scan + 17'd1;

    wire [2:0] digit = scan[16:14];             // 7 = leftmost
    wire [2:0] k     = 3'd7 - digit;            // 0 = leftmost character
    wire       lit   = (scan[13:11] <= disp_bright);

    // index of the character on this digit; in scroll mode pos < len and
    // len >= 8, so one wrap is always enough
    wire [7:0] raw = {1'b0, pos} + {5'd0, k};
    wire [7:0] idx = disp_scroll ? ((raw >= {1'b0, disp_len}) ? raw - {1'b0, disp_len} : raw)
                                 : {5'd0, k};
    wire       in_range = disp_scroll || ({4'd0, k} < disp_len);

    reg [7:0] seg_r = 8'h00;
    reg [7:0] an_r  = 8'hff;
    always @(posedge clk) begin
        seg_r <= in_range ? disp_buf[idx[5:0]] : 8'h00;
        an_r  <= lit ? ~(8'd1 << digit) : 8'hff;
    end

    assign SEG = ~seg_r[6:0];
    assign DP  = ~seg_r[7];
    assign AN  = an_r;

    //-------------------------------------------------------------------------
    // LEDs
    //-------------------------------------------------------------------------
    reg [25:0] hb = 26'd0;
    always @(posedge clk) hb <= hb + 26'd1;

    reg [21:0] rx_led = 22'd0;
    always @(posedge clk) begin
        if (rx_valid)           rx_led <= {22{1'b1}};
        else if (rx_led != 0)   rx_led <= rx_led - 22'd1;
    end

    assign LED[7:0]  = {1'b0, disp_len};
    assign LED[13:8] = 6'd0;
    assign LED[14]   = (rx_led != 0);
    assign LED[15]   = hb[25];

endmodule

`default_nettype wire
