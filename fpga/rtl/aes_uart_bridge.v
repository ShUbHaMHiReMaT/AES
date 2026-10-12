//=============================================================================
// aes_uart_bridge.v -- host protocol: everything the web page can see and do
//
// Request, host -> FPGA, 37 bytes, multi-byte fields most significant first:
//   [0] cmd   [1..4] arg (32 bit)   [5..20] key (128)   [21..36] data (128)
//
// Response, FPGA -> host, 22 bytes:
//   [0] echo of cmd (0xEE = unknown command)   [1] status
//   [2..5] aux (32 bit)                        [6..21] payload (128)
//
//   cmd        action                          status     aux        payload
//   0x00       ping                            self-test  version    ID string
//   0x01-03    encrypt `data` with `key` on    FF=timeout latency    ciphertext
//              core 1/2/3                                 (cycles)
//   0x11-13    benchmark: arg blocks, plaintext FF=timeout total      XOR of all
//              data+i, on core 1/2/3                      cycles     ciphertexts
//   0x20       write 16 display patterns from  0          0          0
//              `data` at buffer offset arg[5:0]
//   0x21       show display: arg = {flags,     0          0          0
//              speed, len, -} (see seg7_ctrl)
//   0x22       LEDs: arg[31] = manual, arg[5:3] 0         0          0
//              RGB17, arg[2:0] RGB16 ({r,g,b}),
//              data[15:0] = LD15..LD0
//   0x30       board status                    flags      uptime s   see below
//   0x40       re-run the self-test            self-test  0          0
//
// Status payload (0x30): switches[16] buttons[8] self-test[8] temp[16]
//                        vccint[16] blocks_total[32] frames[32]
//   buttons = {3'b0, C, U, L, R, D}: held now, or pressed since the last
//   status read (so a short tap between two polls is never missed).
//   temp/vccint are raw XADC codes.
//   self-test byte = {busy, ran, fail[2:0], pass[2:0]}
//
// Flow: incoming bytes go through a 4 KB FIFO, so the host can keep up to
// 110 requests in flight (the web page uses 64) and the link never idles.
// Overrunning the FIFO sets the overflow flag. A partial frame is discarded
// after RX_TIMEOUT cycles of silence.
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module aes_uart_bridge #(
    parameter integer CLKS_PER_BIT = 100,           // 1 Mbaud at 100 MHz
    parameter integer RX_TIMEOUT   = 2_000_000,     // 20 ms
    parameter [7:0]   CLK_MHZ      = 8'd100,
    parameter [7:0]   BAUD_100K    = 8'd10,          // baud / 100000
    parameter integer TRACE_LEN    = 256,            // sensor samples per trace
    parameter integer TRACE_AW     = 8               // ceil(log2(TRACE_LEN))
) (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         uart_rx,
    output wire         uart_tx,

    // AES engine, through the arbiter
    output reg          eng_req,
    input  wire         eng_accepted,
    output reg          eng_bench,
    output reg  [1:0]   eng_sel,
    output reg  [127:0] eng_key,
    output reg  [127:0] eng_data,
    output reg  [31:0]  eng_count,
    input  wire         eng_done,
    input  wire [127:0] eng_result,
    input  wire [31:0]  eng_cycles,
    input  wire         eng_timeout,

    // 7-segment display
    output reg          disp_we,
    output reg  [5:0]   disp_waddr,
    output reg  [7:0]   disp_wdata,
    output reg          disp_commit,
    output reg  [31:0]  disp_cfg,

    // LEDs
    output reg          led_we,
    output reg  [31:0]  led_cfg,
    output reg  [15:0]  led_pattern,

    // self-test
    output reg          bist_trigger,
    input  wire         bist_busy,
    input  wire [7:0]   bist_status,

    // side-channel capture unit (command 0x50)
    output reg          cap_trigger,
    output reg          cap_protected,
    output reg  [127:0] cap_key,
    output reg  [127:0] cap_pt,
    output reg  [2:0]   cap_shift,       // sensor calibration (cmd 0x51)
    output reg  [7:0]   cap_off,
    input  wire         cap_busy,
    input  wire         cap_done,
    input  wire [127:0] cap_ct,
    output reg  [TRACE_AW-1:0] trace_raddr,
    input  wire [7:0]   trace_rdata,

    // board state for the status command
    input  wire [15:0]  switches,
    input  wire [4:0]   buttons,
    input  wire [15:0]  temp,
    input  wire [15:0]  vccint,
    input  wire [31:0]  blocks_total,
    input  wire [31:0]  uptime,
    input  wire [7:0]   flags,

    output reg          status_read,    // pulses when 0x30 samples `buttons`
    output reg  [31:0]  frames_done,
    output wire         rx_activity,
    output reg          overflow
);

    localparam [127:0] ID_STRING = "AES128-NEXYSA7v2";
    localparam [7:0]   VERSION   = 8'h02;

    localparam integer REQ_BYTES  = 37;
    localparam integer RESP_BYTES = 22;
    localparam [31:0]  TRACE_LEN32 = TRACE_LEN;

    //-------------------------------------------------------------------------
    // UART
    //-------------------------------------------------------------------------
    wire [7:0] rx_data;
    wire       rx_valid, rx_ferr;
    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk       (clk),
        .rst_n     (rst_n),
        .rx        (uart_rx),
        .data      (rx_data),
        .valid     (rx_valid),
        .frame_err (rx_ferr)
    );

    reg  [175:0] resp;              // sent MSB byte first
    wire         tx_busy;
    reg  [3:0]   xs;
    localparam [3:0] X_IDLE     = 4'd0,
                     X_DISPATCH = 4'd1,
                     X_ENGWAIT  = 4'd2,
                     X_DISPW    = 4'd3,
                     X_BIST     = 4'd4,
                     X_BISTWAIT = 4'd5,
                     X_TX       = 4'd6,
                     X_CAPWAIT  = 4'd7,
                     X_TRACE    = 4'd8,   // set read address
                     X_TRACE2   = 4'd9;   // send the byte just read

    reg [TRACE_AW:0] traddr;             // 0..TRACE_LEN

    // the 22-byte header streams out of `resp`; the trace bytes that follow
    // stream straight from the trace RAM
    wire [7:0] tx_data  = (xs == X_TRACE2) ? trace_rdata : resp[175:168];
    wire       tx_start = ((xs == X_TX) || (xs == X_TRACE2)) && !tx_busy;
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk   (clk),
        .rst_n (rst_n),
        .data  (tx_data),
        .start (tx_start),
        .busy  (tx_busy),
        .tx    (uart_tx)
    );

    assign rx_activity = rx_valid;

    //-------------------------------------------------------------------------
    // Receive FIFO: the host may queue up to 4 KB (110 requests) ahead.
    // A UART framing error just drops that byte; the frame it belonged to
    // is then recovered by the silence timeout below.
    //-------------------------------------------------------------------------
    wire       f_full, f_valid;
    wire [7:0] f_data;
    wire       f_pop;

    byte_fifo #(.AW(12)) u_fifo (
        .clk   (clk),
        .rst_n (rst_n),
        .wr    (rx_valid),
        .din   (rx_data),
        .full  (f_full),
        .rd    (f_pop),
        .dout  (f_data),
        .valid (f_valid)
    );

    //-------------------------------------------------------------------------
    // Frame assembler: FIFO -> one-deep job slot. The last byte of a frame is
    // only taken when the slot can accept it, so frames wait in the FIFO
    // rather than being dropped.
    //-------------------------------------------------------------------------
    reg [295:0] sh;
    reg [5:0]   n_rx;
    reg [31:0]  idle;
    reg [295:0] job;
    reg         job_full;

    wire take = (xs == X_IDLE) && job_full;
    assign f_pop = f_valid && !(n_rx == REQ_BYTES - 1 && job_full && !take);

    always @(posedge clk) begin
        if (!rst_n) begin
            sh       <= 296'd0;
            n_rx     <= 6'd0;
            idle     <= 32'd0;
            job      <= 296'd0;
            job_full <= 1'b0;
            overflow <= 1'b0;
        end else begin
            if (take) job_full <= 1'b0;
            if (rx_valid && f_full) overflow <= 1'b1;

            if (f_pop) begin
                sh   <= {sh[287:0], f_data};
                idle <= 32'd0;
                if (n_rx == REQ_BYTES - 1) begin
                    n_rx     <= 6'd0;
                    job      <= {sh[287:0], f_data};
                    job_full <= 1'b1;
                end else begin
                    n_rx <= n_rx + 6'd1;
                end
            end else if (n_rx != 6'd0 && !f_valid) begin
                if (idle == RX_TIMEOUT - 1) begin
                    n_rx <= 6'd0;
                    idle <= 32'd0;
                end else begin
                    idle <= idle + 32'd1;
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // Executor
    //-------------------------------------------------------------------------
    reg [7:0]   cmd;
    reg [31:0]  arg;
    reg [127:0] key;
    reg [127:0] data;
    reg [4:0]   n_tx;
    reg [4:0]   wcnt;

    wire [7:0] waddr_full = {2'b00, arg[5:0]} + {3'b000, wcnt};

    always @(posedge clk) begin
        if (!rst_n) begin
            xs           <= X_IDLE;
            cmd          <= 8'd0;
            arg          <= 32'd0;
            key          <= 128'd0;
            data         <= 128'd0;
            resp         <= 176'd0;
            n_tx         <= 5'd0;
            wcnt         <= 5'd0;
            eng_req      <= 1'b0;
            eng_bench    <= 1'b0;
            eng_sel      <= 2'd0;
            eng_key      <= 128'd0;
            eng_data     <= 128'd0;
            eng_count    <= 32'd0;
            disp_we      <= 1'b0;
            disp_waddr   <= 6'd0;
            disp_wdata   <= 8'd0;
            disp_commit  <= 1'b0;
            disp_cfg     <= 32'd0;
            led_we       <= 1'b0;
            led_cfg      <= 32'd0;
            led_pattern  <= 16'd0;
            bist_trigger <= 1'b0;
            status_read  <= 1'b0;
            frames_done  <= 32'd0;
            cap_trigger   <= 1'b0;
            cap_protected <= 1'b0;
            cap_key       <= 128'd0;
            cap_pt        <= 128'd0;
            cap_shift     <= 3'd0;
            cap_off       <= 8'd0;
            traddr        <= {(TRACE_AW+1){1'b0}};
            trace_raddr   <= {TRACE_AW{1'b0}};
        end else begin
            disp_we      <= 1'b0;
            disp_commit  <= 1'b0;
            led_we       <= 1'b0;
            bist_trigger <= 1'b0;
            status_read  <= 1'b0;
            cap_trigger  <= 1'b0;

            case (xs)
                X_IDLE:
                    if (take) begin
                        cmd  <= job[295:288];
                        arg  <= job[287:256];
                        key  <= job[255:128];
                        data <= job[127:0];
                        xs   <= X_DISPATCH;
                    end

                X_DISPATCH: begin
                    n_tx <= 5'd0;
                    case (cmd)
                        8'h00: begin
                            resp <= {8'h00, bist_status,
                                     VERSION, CLK_MHZ, BAUD_100K, 8'h00,
                                     ID_STRING};
                            xs   <= X_TX;
                        end
                        8'h01, 8'h02, 8'h03,
                        8'h11, 8'h12, 8'h13: begin
                            eng_bench <= cmd[4];
                            eng_sel   <= cmd[1:0];
                            eng_key   <= key;
                            eng_data  <= data;
                            eng_count <= cmd[4] ? arg : 32'd1;
                            eng_req   <= 1'b1;
                            xs        <= X_ENGWAIT;
                        end
                        8'h20: begin
                            wcnt <= 5'd0;
                            xs   <= X_DISPW;
                        end
                        8'h21: begin
                            disp_cfg    <= arg;
                            disp_commit <= 1'b1;
                            resp        <= {8'h21, 8'h00, 32'd0, 128'd0};
                            xs          <= X_TX;
                        end
                        8'h22: begin
                            led_cfg     <= arg;
                            led_pattern <= data[15:0];
                            led_we      <= 1'b1;
                            resp        <= {8'h22, 8'h00, 32'd0, 128'd0};
                            xs          <= X_TX;
                        end
                        8'h30: begin
                            status_read <= 1'b1;
                            resp <= {8'h30, flags, uptime,
                                     switches, {3'b000, buttons}, bist_status,
                                     temp, vccint, blocks_total, frames_done};
                            xs   <= X_TX;
                        end
                        8'h40: begin
                            bist_trigger <= 1'b1;
                            xs           <= X_BIST;
                        end
                        // side-channel trace capture: encrypt `data` on the
                        // capture unit's own core while recording the sensor;
                        // arg[8] selects the protected (hiding) mode
                        8'h50: begin
                            cap_key       <= key;
                            cap_pt        <= data;
                            cap_protected <= arg[8];
                            cap_trigger   <= 1'b1;
                            xs            <= X_CAPWAIT;
                        end
                        // set sensor calibration: arg[2:0]=shift, arg[15:8]=off
                        8'h51: begin
                            cap_shift <= arg[2:0];
                            cap_off   <= arg[15:8];
                            resp      <= {8'h51, 8'h00, 32'd0, 128'd0};
                            xs        <= X_TX;
                        end
                        default: begin
                            resp <= {8'hee, cmd, 32'd0, 128'd0};
                            xs   <= X_TX;
                        end
                    endcase
                end

                X_ENGWAIT: begin
                    if (eng_accepted) eng_req <= 1'b0;
                    if (eng_done) begin
                        eng_req <= 1'b0;
                        resp    <= {cmd, (eng_timeout ? 8'hff : 8'h00),
                                    eng_cycles, eng_result};
                        xs      <= X_TX;
                    end
                end

                // one pattern per cycle; bytes past the end of the buffer
                // are dropped rather than wrapped
                X_DISPW: begin
                    if (waddr_full < 8'd64) begin
                        disp_we    <= 1'b1;
                        disp_waddr <= waddr_full[5:0];
                        disp_wdata <= data[(15 - wcnt) * 8 +: 8];
                    end
                    if (wcnt == 5'd15) begin
                        resp <= {8'h20, 8'h00, 32'd0, 128'd0};
                        xs   <= X_TX;
                    end
                    wcnt <= wcnt + 5'd1;
                end

                // wait for the self-test to start, then to finish
                X_BIST:
                    if (bist_busy) xs <= X_BISTWAIT;
                X_BISTWAIT:
                    if (!bist_busy) begin
                        resp <= {8'h40, bist_status, 32'd0, 128'd0};
                        xs   <= X_TX;
                    end

                // wait for the capture unit, then send the 22-byte header
                // (echo, status, aux = TRACE_LEN, ciphertext) and fall into
                // the trace stream
                X_CAPWAIT:
                    if (cap_done) begin
                        resp <= {8'h50, 8'h00, TRACE_LEN32, cap_ct};
                        n_tx <= 5'd0;
                        xs   <= X_TX;
                    end

                X_TX:
                    if (tx_start) begin
                        resp <= {resp[167:0], 8'h00};
                        if (n_tx == RESP_BYTES - 1) begin
                            if (cmd == 8'h50) begin
                                traddr      <= {(TRACE_AW+1){1'b0}};
                                trace_raddr <= {TRACE_AW{1'b0}};
                                xs          <= X_TRACE;
                            end else begin
                                frames_done <= frames_done + 32'd1;
                                xs          <= X_IDLE;
                            end
                        end else begin
                            n_tx <= n_tx + 5'd1;
                        end
                    end

                // trace RAM is a registered read: set the address in X_TRACE,
                // send the byte that appears one cycle later in X_TRACE2
                X_TRACE: begin
                    trace_raddr <= traddr[TRACE_AW-1:0];
                    xs          <= X_TRACE2;
                end
                X_TRACE2:
                    if (tx_start) begin
                        if (traddr == TRACE_LEN - 1) begin
                            frames_done <= frames_done + 32'd1;
                            xs          <= X_IDLE;
                        end else begin
                            traddr <= traddr + 1'b1;
                            xs     <= X_TRACE;
                        end
                    end

                default: xs <= X_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
