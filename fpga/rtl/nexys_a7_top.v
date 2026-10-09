//=============================================================================
// nexys_a7_top.v -- AES-128 accelerator on the Digilent Nexys A7-100T (v2)
//
// All three cores behind aes_engine, at the 100 MHz board clock, reachable
// from the web page over the USB-UART (1 Mbaud, protocol in
// aes_uart_bridge.v). The page can see and control everything here:
//
//   AES       single-block encryption on any core, with the hardware-counted
//             latency; streaming benchmark that measures real throughput
//   display   anything the page draws, static or scrolling; otherwise the
//             self-test result
//   LEDs      status (auto) or any pattern the page sets, incl. both RGBs
//   inputs    16 switches, 5 buttons -- reported live to the page
//   sensors   die temperature and VCCINT from the XADC
//
// Without a PC: after configuration, CPU_RESET or BTNC, every core encrypts
// the FIPS-197 C.1 vector and the display reads "AES PASS" / "AES FAIL".
//
// Auto LEDs:
//   LD0..LD2   self-test pass: iterative, ii10, pipelined
//   LD3..LD5   self-test fail
//   LD6        self-test has run        LD7..LD13  requests answered (low bits)
//   LD14       UART activity            LD15       heartbeat
//   LD16 RGB   green = all pass, red = a core failed
//   LD17 RGB   blue while the AES engine is working
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module nexys_a7_top #(
    parameter integer CLK_HZ     = 100_000_000,
    parameter integer BAUD       = 1_000_000,
    parameter integer RX_TIMEOUT = CLK_HZ / 50       // 20 ms
) (
    input  wire        CLK100MHZ,
    input  wire        CPU_RESETN,
    input  wire        BTNC,
    input  wire        BTNU,
    input  wire        BTNL,
    input  wire        BTNR,
    input  wire        BTND,
    input  wire [15:0] SW,
    input  wire        UART_TXD_IN,
    output wire        UART_RXD_OUT,
    output wire [15:0] LED,
    output wire        LED16_R,
    output wire        LED16_G,
    output wire        LED16_B,
    output wire        LED17_R,
    output wire        LED17_G,
    output wire        LED17_B,
    output wire [6:0]  SEG,
    output wire        DP,
    output wire [7:0]  AN
);

    wire clk = CLK100MHZ;

    //-------------------------------------------------------------------------
    // Reset and input synchronisers
    //-------------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg [2:0] rst_sync = 3'b000;
    always @(posedge clk) rst_sync <= {rst_sync[1:0], CPU_RESETN};
    wire rst_n = rst_sync[2];

    (* ASYNC_REG = "TRUE" *) reg [4:0]  btn_m = 5'd0, btn_s = 5'd0;
    (* ASYNC_REG = "TRUE" *) reg [15:0] sw_m  = 16'd0, sw_s = 16'd0;
    reg [4:0] btn_q = 5'd0;
    always @(posedge clk) begin
        btn_m <= {BTNC, BTNU, BTNL, BTNR, BTND};
        btn_s <= btn_m;
        btn_q <= btn_s;
        sw_m  <= SW;
        sw_s  <= sw_m;
    end
    wire btnc_rise = btn_s[4] && !btn_q[4];

    // presses are held until the page's next status read, so a tap shorter
    // than the polling interval still reaches it
    wire       status_read;
    reg  [4:0] btn_latch = 5'd0;
    always @(posedge clk)
        btn_latch <= (status_read ? 5'd0 : btn_latch) | (btn_s & ~btn_q);

    //-------------------------------------------------------------------------
    // Engine and arbiter: self-test has priority
    //-------------------------------------------------------------------------
    localparam [127:0] KAT_KEY = 128'h000102030405060708090a0b0c0d0e0f;
    localparam [127:0] KAT_PT  = 128'h00112233445566778899aabbccddeeff;
    localparam [127:0] KAT_CT  = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;

    reg          bist_req;
    reg  [1:0]   bist_sel;

    wire         br_req, br_bench;
    wire [1:0]   br_sel;
    wire [127:0] br_key, br_data;
    wire [31:0]  br_count;

    wire         eng_busy, eng_done, eng_timeout;
    wire [127:0] eng_result;
    wire [31:0]  eng_cycles, blocks_total;

    wire eng_start = !eng_busy && (bist_req || br_req);
    wire bist_acc  = eng_start && bist_req;
    wire br_acc    = eng_start && !bist_req;

    reg owner_bist;
    always @(posedge clk) begin
        if (!rst_n)         owner_bist <= 1'b0;
        else if (eng_start) owner_bist <= bist_req;
    end

    aes_engine u_engine (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (eng_start),
        .bench        (bist_req ? 1'b0     : br_bench),
        .sel          (bist_req ? bist_sel : br_sel),
        .key          (bist_req ? KAT_KEY  : br_key),
        .data         (bist_req ? KAT_PT   : br_data),
        .count        (bist_req ? 32'd1    : br_count),
        .busy         (eng_busy),
        .done         (eng_done),
        .result       (eng_result),
        .cycles       (eng_cycles),
        .timeout      (eng_timeout),
        .blocks_total (blocks_total)
    );

    wire bist_done = eng_done &&  owner_bist;
    wire br_done   = eng_done && !owner_bist;

    //-------------------------------------------------------------------------
    // Self-test: FIPS-197 C.1 through each core
    //-------------------------------------------------------------------------
    reg [2:0] pass, fail;
    reg       bist_ran, bist_pending, bist_wait;
    wire      bist_trigger;
    wire      bist_busy = bist_pending || bist_req || bist_wait;

    always @(posedge clk) begin
        if (!rst_n) begin
            bist_req     <= 1'b0;
            bist_sel     <= 2'd1;
            pass         <= 3'b000;
            fail         <= 3'b000;
            bist_ran     <= 1'b0;
            bist_pending <= 1'b1;          // once out of every reset
            bist_wait    <= 1'b0;
        end else begin
            if (btnc_rise || bist_trigger) bist_pending <= 1'b1;

            if (bist_pending && !bist_req && !bist_wait) begin
                bist_pending <= 1'b0;
                pass         <= 3'b000;
                fail         <= 3'b000;
                bist_ran     <= 1'b0;
                bist_sel     <= 2'd1;
                bist_req     <= 1'b1;
            end

            if (bist_acc) begin
                bist_req  <= 1'b0;
                bist_wait <= 1'b1;
            end

            if (bist_done) begin
                bist_wait <= 1'b0;
                if (eng_result == KAT_CT && eng_cycles == 32'd11 && !eng_timeout)
                    pass[bist_sel - 2'd1] <= 1'b1;
                else
                    fail[bist_sel - 2'd1] <= 1'b1;

                if (bist_sel == 2'd3) begin
                    bist_ran <= 1'b1;
                end else begin
                    bist_sel <= bist_sel + 2'd1;
                    bist_req <= 1'b1;
                end
            end
        end
    end

    wire [7:0] bist_status = {bist_busy, bist_ran, fail, pass};
    wire       all_pass    = bist_ran && (pass == 3'b111);

    //-------------------------------------------------------------------------
    // Sensors and uptime
    //-------------------------------------------------------------------------
    wire [15:0] temp, vccint;
    xadc_mon u_xadc (
        .clk    (clk),
        .rst_n  (rst_n),
        .temp   (temp),
        .vccint (vccint)
    );

    reg [26:0] sec_div = 27'd0;
    reg [31:0] uptime  = 32'd0;
    always @(posedge clk) begin
        if (sec_div == CLK_HZ - 1) begin
            sec_div <= 27'd0;
            uptime  <= uptime + 32'd1;
        end else begin
            sec_div <= sec_div + 27'd1;
        end
    end

    //-------------------------------------------------------------------------
    // Host link
    //-------------------------------------------------------------------------
    wire        disp_we, disp_commit, led_we, rx_activity, overflow;
    wire [5:0]  disp_waddr;
    wire [7:0]  disp_wdata;
    wire [31:0] disp_cfg, led_cfg, frames_done;
    wire [15:0] led_pattern;
    wire        page_mode;

    reg         led_manual = 1'b0;
    reg  [2:0]  rgb16_man  = 3'd0;
    reg  [2:0]  rgb17_man  = 3'd0;
    reg  [15:0] led_man    = 16'd0;

    aes_uart_bridge #(
        .CLKS_PER_BIT (CLK_HZ / BAUD),
        .RX_TIMEOUT   (RX_TIMEOUT),
        .CLK_MHZ      (CLK_HZ / 1_000_000),
        .BAUD_100K    (BAUD / 100_000)
    ) u_bridge (
        .clk          (clk),
        .rst_n        (rst_n),
        .uart_rx      (UART_TXD_IN),
        .uart_tx      (UART_RXD_OUT),
        .eng_req      (br_req),
        .eng_accepted (br_acc),
        .eng_bench    (br_bench),
        .eng_sel      (br_sel),
        .eng_key      (br_key),
        .eng_data     (br_data),
        .eng_count    (br_count),
        .eng_done     (br_done),
        .eng_result   (eng_result),
        .eng_cycles   (eng_cycles),
        .eng_timeout  (eng_timeout),
        .disp_we      (disp_we),
        .disp_waddr   (disp_waddr),
        .disp_wdata   (disp_wdata),
        .disp_commit  (disp_commit),
        .disp_cfg     (disp_cfg),
        .led_we       (led_we),
        .led_cfg      (led_cfg),
        .led_pattern  (led_pattern),
        .bist_trigger (bist_trigger),
        .bist_busy    (bist_busy),
        .bist_status  (bist_status),
        .switches     (sw_s),
        .buttons      (btn_s | btn_latch),
        .temp         (temp),
        .vccint       (vccint),
        .blocks_total (blocks_total),
        .uptime       (uptime),
        .flags        ({led_manual, page_mode, 5'd0, overflow}),
        .status_read  (status_read),
        .frames_done  (frames_done),
        .rx_activity  (rx_activity),
        .overflow     (overflow)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            led_manual <= 1'b0;
        end else if (led_we) begin
            led_manual <= led_cfg[31];
            rgb17_man  <= led_cfg[5:3];
            rgb16_man  <= led_cfg[2:0];
            led_man    <= led_pattern;
        end
    end

    //-------------------------------------------------------------------------
    // 7-segment display. Auto text: "  tESt  " / "AES PASS" / "AES FAIL"
    //-------------------------------------------------------------------------
    localparam [63:0] TXT_TEST = {8'h00, 8'h00, 8'h78, 8'h79, 8'h6d, 8'h78, 8'h00, 8'h00};
    localparam [63:0] TXT_PASS = {8'h77, 8'h79, 8'h6d, 8'h00, 8'h73, 8'h77, 8'h6d, 8'h6d};
    localparam [63:0] TXT_FAIL = {8'h77, 8'h79, 8'h6d, 8'h00, 8'h71, 8'h77, 8'h30, 8'h38};

    wire [63:0] auto_segs = !bist_ran ? TXT_TEST : all_pass ? TXT_PASS : TXT_FAIL;

    seg7_ctrl u_seg7 (
        .clk       (clk),
        .rst_n     (rst_n),
        .we        (disp_we),
        .waddr     (disp_waddr),
        .wdata     (disp_wdata),
        .commit    (disp_commit),
        .cfg       (disp_cfg),
        .auto_segs (auto_segs),
        .SEG       (SEG),
        .DP        (DP),
        .AN        (AN),
        .page_mode (page_mode)
    );

    //-------------------------------------------------------------------------
    // LEDs
    //-------------------------------------------------------------------------
    reg [25:0] heartbeat = 26'd0;
    always @(posedge clk) heartbeat <= heartbeat + 26'd1;

    reg [21:0] rx_led = 22'd0;          // ~40 ms stretch
    reg [22:0] eng_led = 23'd0;         // ~80 ms stretch
    always @(posedge clk) begin
        if (rx_activity)      rx_led <= {22{1'b1}};
        else if (rx_led != 0) rx_led <= rx_led - 22'd1;
        if (eng_busy)          eng_led <= {23{1'b1}};
        else if (eng_led != 0) eng_led <= eng_led - 23'd1;
    end

    wire [15:0] led_auto = {heartbeat[25], (rx_led != 0), frames_done[6:0],
                            bist_ran, fail, pass};
    assign LED = led_manual ? led_man : led_auto;

    // RGB LEDs are much brighter than the others: 1/16 duty
    wire rgb_on = (heartbeat[3:0] == 4'd0);

    wire [2:0] rgb16 = led_manual ? rgb16_man
                     : !bist_ran  ? 3'b000
                     : all_pass   ? 3'b010 : 3'b100;
    wire [2:0] rgb17 = led_manual ? rgb17_man
                     : (eng_led != 0) ? 3'b001 : 3'b000;

    assign {LED16_R, LED16_G, LED16_B} = rgb_on ? rgb16 : 3'b000;
    assign {LED17_R, LED17_G, LED17_B} = rgb_on ? rgb17 : 3'b000;

endmodule

`default_nettype wire
