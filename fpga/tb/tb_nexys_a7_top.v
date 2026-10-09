//=============================================================================
// tb_nexys_a7_top.v -- board-level testbench for nexys_a7_top (protocol v2)
//
// Drives the top level only through its pins, as the board sees it: a UART
// model on UART_TXD_IN/UART_RXD_OUT, the buttons and the switches. The baud
// rate is raised to 10 Mbaud so a run takes seconds.
//
// Checks every command the web page uses:
//   ping, encrypt on all three cores (vectors from the golden model, latency
//   11), benchmark (XOR checksum from the golden model, exact cycle counts,
//   128-bit counter wrap, count = 0), display write/show, LED override,
//   board status (switches, buttons, sensors, counters), self-test command,
//   two requests in flight, unknown command, resync after a partial frame,
//   BTNC and CPU_RESET.
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_nexys_a7_top;

    localparam integer CLK_HZ     = 100_000_000;
    localparam integer BAUD       = 10_000_000;
    localparam integer RX_TIMEOUT = 500;
    localparam real    CLK_NS     = 10.0;
    localparam real    BIT_NS     = CLK_NS * (CLK_HZ / BAUD);
    localparam integer N_PER_CORE = 50;
    localparam integer MAX_VEC    = 2048;

    reg         clk     = 1'b0;
    reg         resetn  = 1'b1;
    reg  [4:0]  btn     = 5'd0;           // {C, U, L, R, D}
    reg  [15:0] sw      = 16'd0;
    reg         uart_in = 1'b1;
    wire        uart_out;
    wire [15:0] led;
    wire [6:0]  seg;
    wire        dp;
    wire [7:0]  an;
    wire        l16r, l16g, l16b, l17r, l17g, l17b;

    nexys_a7_top #(
        .CLK_HZ     (CLK_HZ),
        .BAUD       (BAUD),
        .RX_TIMEOUT (RX_TIMEOUT)
    ) dut (
        .CLK100MHZ    (clk),
        .CPU_RESETN   (resetn),
        .BTNC         (btn[4]),
        .BTNU         (btn[3]),
        .BTNL         (btn[2]),
        .BTNR         (btn[1]),
        .BTND         (btn[0]),
        .SW           (sw),
        .UART_TXD_IN  (uart_in),
        .UART_RXD_OUT (uart_out),
        .LED          (led),
        .LED16_R      (l16r),
        .LED16_G      (l16g),
        .LED16_B      (l16b),
        .LED17_R      (l17r),
        .LED17_G      (l17g),
        .LED17_B      (l17b),
        .SEG          (seg),
        .DP           (dp),
        .AN           (an)
    );

    always #(CLK_NS / 2.0) clk = ~clk;

    integer errors  = 0;
    integer checks  = 0;
    integer n_blocks = 0;       // blocks the engine should have encrypted for us

    //-------------------------------------------------------------------------
    // UART models
    //-------------------------------------------------------------------------
    reg [7:0] rx_fifo [0:1023];
    integer   rx_wr = 0, rx_rd = 0;
    reg [7:0] rb;
    integer   bi;

    always begin
        @(negedge uart_out);
        #(BIT_NS * 1.5);
        for (bi = 0; bi < 8; bi = bi + 1) begin
            rb[bi] = uart_out;
            #(BIT_NS);
        end
        if (uart_out !== 1'b1) begin
            $display("ERROR: framing error on FPGA transmit");
            errors = errors + 1;
        end
        rx_fifo[rx_wr % 1024] = rb;
        rx_wr = rx_wr + 1;
    end

    task send_byte (input [7:0] b);
        integer i;
        begin
            uart_in = 1'b0;
            #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin
                uart_in = b[i];
                #(BIT_NS);
            end
            uart_in = 1'b1;
            #(BIT_NS);
        end
    endtask

    task send_req (input [7:0] cmd, input [31:0] arg, input [127:0] k, input [127:0] d);
        integer i;
        begin
            send_byte(cmd);
            for (i = 3;  i >= 0; i = i - 1) send_byte(arg[i*8 +: 8]);
            for (i = 15; i >= 0; i = i - 1) send_byte(k[i*8 +: 8]);
            for (i = 15; i >= 0; i = i - 1) send_byte(d[i*8 +: 8]);
        end
    endtask

    // 22-byte response: {echo, status, aux[31:0], payload[127:0]}
    task get_resp (output [175:0] r);
        integer i, t;
        begin
            t = 0;
            while ((rx_wr - rx_rd) < 22 && t < 400000) begin
                @(posedge clk);
                t = t + 1;
            end
            if ((rx_wr - rx_rd) < 22) begin
                $display("ERROR: response timeout (%0d bytes)", rx_wr - rx_rd);
                errors = errors + 1;
                r = 176'd0;
            end else begin
                for (i = 0; i < 22; i = i + 1) begin
                    r = {r[167:0], rx_fifo[rx_rd % 1024]};
                    rx_rd = rx_rd + 1;
                end
            end
        end
    endtask

    task expect_ack (input [7:0] cmd, input [8*20-1:0] label);
        reg [175:0] r;
        begin
            get_resp(r);
            if (r[175:168] !== cmd || r[167:160] !== 8'h00) begin
                $display("ERROR [%0s]: response %044h", label, r);
                errors = errors + 1;
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // Encrypt / benchmark helpers
    //-------------------------------------------------------------------------
    task encrypt_check (input [1:0] core, input [127:0] k, input [127:0] p,
                        input [127:0] exp, input integer idx);
        reg [175:0] r;
        begin
            send_req({6'd0, core}, 32'd0, k, p);
            get_resp(r);
            checks   = checks + 1;
            n_blocks = n_blocks + 1;
            if (r[175:168] !== {6'd0, core} || r[167:160] !== 8'h00 ||
                r[159:128] !== 32'd11 || r[127:0] !== exp) begin
                $display("ERROR: core %0d vec %0d: echo %02h status %02h lat %0d",
                         core, idx, r[175:168], r[167:160], r[159:128]);
                $display("        got = %032h", r[127:0]);
                $display("        exp = %032h", exp);
                errors = errors + 1;
            end
        end
    endtask

    task bench_check (input [1:0] core, input [31:0] n, input [127:0] k,
                      input [127:0] seed, input [127:0] exp_xor,
                      input [31:0] exp_cycles);
        reg [175:0] r;
        begin
            send_req({4'h1, 2'b00, core}, n, k, seed);
            get_resp(r);
            checks   = checks + 1;
            n_blocks = n_blocks + n;
            if (r[167:160] !== 8'h00 || r[159:128] !== exp_cycles ||
                r[127:0] !== exp_xor) begin
                $display("ERROR: bench core %0d N=%0d: status %02h cycles %0d (exp %0d)",
                         core, n, r[167:160], r[159:128], exp_cycles);
                $display("        xor = %032h", r[127:0]);
                $display("        exp = %032h", exp_xor);
                errors = errors + 1;
            end else begin
                $display("  [PASS] bench core %0d, %0d blocks: %0d cycles, checksum ok",
                         core, n, r[159:128]);
            end
        end
    endtask

    task check_selftest_display (input [8*16-1:0] label);
        begin
            if (dut.bist_status !== 8'h47 || dut.u_seg7.page_mode !== 1'b0 ||
                dut.auto_segs !== dut.TXT_PASS) begin
                $display("ERROR [%0s]: self-test status %02h, display not AES PASS",
                         label, dut.bist_status);
                errors = errors + 1;
            end else begin
                $display("  [PASS] %0s: all cores pass, display reads AES PASS", label);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // Vectors
    //-------------------------------------------------------------------------
    reg [127:0] v_key [0:MAX_VEC-1];
    reg [127:0] v_pt  [0:MAX_VEC-1];
    reg [127:0] v_ct  [0:MAX_VEC-1];
    integer     n_vec = 0;
    integer     fd, code;
    reg [8*256-1:0] line_rest;
    reg [127:0] k, p, c;
    reg [8*512-1:0] vec_path;

    // +vectors=<path> overrides the default; the Vivado project passes an
    // absolute path because its simulator runs deep inside the project tree
    task load_vectors;
        begin
            if (!$value$plusargs("vectors=%s", vec_path))
                vec_path = "tb/vectors/aes128_vectors.txt";
            fd = $fopen(vec_path, "r");
            if (fd == 0) begin
                $display("ERROR: cannot open %0s", vec_path);
                $fatal(1);
            end
            while (!$feof(fd) && n_vec < MAX_VEC) begin
                code = $fscanf(fd, "%h %h %h", k, p, c);
                if (code == 3) begin
                    v_key[n_vec] = k;  v_pt[n_vec] = p;  v_ct[n_vec] = c;
                    n_vec = n_vec + 1;
                end
                if (code != 3) code = $fgets(line_rest, fd);
            end
            $fclose(fd);
            $display("  loaded %0d vectors", n_vec);
        end
    endtask

    //-------------------------------------------------------------------------
    localparam [127:0] K1 = 128'h2b7e151628aed2a6abf7158809cf4f3c;

    integer i, j, core, e0;
    reg [175:0] r, r2;

    initial begin
        if ($test$plusargs("dumpvcd")) begin
            $dumpfile("tb_nexys_a7_top.vcd");
            $dumpvars(0, tb_nexys_a7_top);
        end

        $display("");
        $display("=====================================================");
        $display(" Nexys A7 top level v2 -- %0d baud", BAUD);
        $display("=====================================================");
        load_vectors;

        //-- self-test at power-on --------------------------------------------
        $display("");
        $display("-- Power-on self-test --------------------------------");
        repeat (300) @(posedge clk);
        check_selftest_display("power-on");

        //-- ping -------------------------------------------------------------
        $display("");
        $display("-- Commands ------------------------------------------");
        send_req(8'h00, 0, 0, 0);
        get_resp(r);
        if (r[175:168] !== 8'h00 || r[167:160] !== 8'h47 ||
            r[159:128] !== {8'h02, 8'd100, 8'd100, 8'h00} ||
            r[127:0] !== "AES128-NEXYSA7v2") begin
            $display("ERROR: ping got %044h", r);
            errors = errors + 1;
        end else begin
            $display("  [PASS] ping: \"%0s\", status %02h", r[127:0], r[167:160]);
        end

        //-- encrypt ----------------------------------------------------------
        for (core = 1; core <= 3; core = core + 1) begin
            e0 = errors;
            for (j = 0; j < N_PER_CORE && j < n_vec; j = j + 1)
                encrypt_check(core[1:0], v_key[j], v_pt[j], v_ct[j], j);
            if (errors == e0)
                $display("  [PASS] encrypt core %0d: %0d vectors, latency 11", core, N_PER_CORE);
        end

        //-- benchmark --------------------------------------------------------
        // expected checksums from model/aes_golden.py
        bench_check(2'd1, 8,   K1, {128{1'b1}} - 128'd2,
                    128'hd485da7430de18b0a453eeafcb0e8154, 8 * 11);
        bench_check(2'd2, 8,   K1, {128{1'b1}} - 128'd2,
                    128'hd485da7430de18b0a453eeafcb0e8154, 8 * 10 + 1);
        bench_check(2'd3, 8,   K1, {128{1'b1}} - 128'd2,
                    128'hd485da7430de18b0a453eeafcb0e8154, 8 + 10);
        bench_check(2'd1, 100, K1, 128'h000102030405060708090a0b0c0d0e0f,
                    128'h042fb88b4e10a1086c6503273f21dd76, 100 * 11);
        bench_check(2'd2, 100, K1, 128'h000102030405060708090a0b0c0d0e0f,
                    128'h042fb88b4e10a1086c6503273f21dd76, 100 * 10 + 1);
        bench_check(2'd3, 100, K1, 128'h000102030405060708090a0b0c0d0e0f,
                    128'h042fb88b4e10a1086c6503273f21dd76, 100 + 10);
        bench_check(2'd3, 0,   K1, 128'd0, 128'd0, 0);

        //-- display ----------------------------------------------------------
        send_req(8'h20, 32'd0, 0, 128'h76_79_38_38_3f_00_00_00_01_02_03_04_05_06_07_08);
        expect_ack(8'h20, "disp write");
        send_req(8'h20, 32'd60, 0, 128'haa_bb_cc_dd_ee_ff_00_00_00_00_00_00_00_00_00_00);
        expect_ack(8'h20, "disp write clip");
        // flags = page | bright 7 | static; speed 3; len 8
        send_req(8'h21, {8'b0001_1110, 8'd3, 8'd8, 8'd0}, 0, 0);
        expect_ack(8'h21, "disp show");
        if (dut.u_seg7.page_mode !== 1'b1 || dut.u_seg7.buffer[0] !== 8'h76 ||
            dut.u_seg7.buffer[4] !== 8'h3f || dut.u_seg7.buffer[15] !== 8'h08 ||
            dut.u_seg7.buffer[63] !== 8'hdd) begin
            $display("ERROR: display buffer/mode not as written");
            errors = errors + 1;
        end else begin
            $display("  [PASS] display: patterns written, page mode on, end clipped");
        end
        // the leftmost digit must eventually show 'H' (0x76 -> segments active low)
        i = 0;
        repeat (140000) begin
            @(posedge clk);
            if (an === 8'b0111_1111 && seg === ~7'h76) i = 1;
        end
        if (i == 0) begin
            $display("ERROR: leftmost digit never showed H");
            errors = errors + 1;
        end

        //-- LEDs -------------------------------------------------------------
        send_req(8'h22, {1'b1, 25'd0, 3'b001, 3'b100}, 0, 128'h0000_a5a5);
        expect_ack(8'h22, "leds manual");
        @(posedge clk);
        if (led !== 16'ha5a5) begin
            $display("ERROR: manual LED pattern %04h", led);
            errors = errors + 1;
        end else begin
            $display("  [PASS] LEDs follow the page (A5A5)");
        end
        send_req(8'h22, 32'd0, 0, 0);
        expect_ack(8'h22, "leds auto");
        @(posedge clk);
        if (led[6:0] !== 7'b1_000_111) begin
            $display("ERROR: auto LEDs not restored: %04h", led);
            errors = errors + 1;
        end

        //-- status -----------------------------------------------------------
        sw  = 16'h1234;
        btn = 5'b01000;                 // BTNU
        repeat (5) @(posedge clk);
        send_req(8'h30, 0, 0, 0);
        get_resp(r);
        btn = 5'd0;
        if (r[175:168] !== 8'h30 || r[127:112] !== 16'h1234 ||
            r[111:104] !== 8'h08 || r[103:96] !== 8'h47 ||
            r[95:80] !== 16'h9a00 || r[79:64] !== 16'h5550 ||
            r[63:32] !== n_blocks + 3) begin     // + the power-on self-test
            $display("ERROR: status %044h (expected %0d blocks)", r, n_blocks + 3);
            errors = errors + 1;
        end else begin
            $display("  [PASS] status: switches %04h, BTNU, %0d blocks, %0d frames",
                     r[127:112], r[63:32], r[31:0]);
        end

        //-- self-test command ------------------------------------------------
        send_req(8'h40, 0, 0, 0);
        get_resp(r);
        if (r[175:168] !== 8'h40 || r[167:160] !== 8'h47) begin
            $display("ERROR: self-test command got %044h", r);
            errors = errors + 1;
        end else begin
            $display("  [PASS] self-test on request");
        end

        //-- 40 requests queued without waiting --------------------------------
        for (j = 0; j < 40; j = j + 1)
            send_req({6'd0, 2'd1 + j[1:0] % 3}, 0, v_key[100 + j], v_pt[100 + j]);
        e0 = errors;
        for (j = 0; j < 40; j = j + 1) begin
            get_resp(r);
            if (r[127:0] !== v_ct[100 + j]) begin
                $display("ERROR: queued request %0d answered %032h", j, r[127:0]);
                errors = errors + 1;
            end
        end
        n_blocks = n_blocks + 40;
        if (dut.overflow !== 1'b0) begin
            $display("ERROR: FIFO overflow flagged");
            errors = errors + 1;
        end
        if (errors == e0)
            $display("  [PASS] 40 requests queued, all answered in order");

        //-- protocol errors --------------------------------------------------
        send_req(8'h42, 0, 0, 0);
        get_resp(r);
        if (r[175:168] !== 8'hee || r[167:160] !== 8'h42) begin
            $display("ERROR: unknown command got %044h", r);
            errors = errors + 1;
        end else begin
            $display("  [PASS] unknown command answered with EE");
        end

        for (i = 0; i < 10; i = i + 1) send_byte(8'h02);
        repeat (RX_TIMEOUT + 100) @(posedge clk);
        e0 = errors;
        encrypt_check(2'd2, v_key[0], v_pt[0], v_ct[0], 0);
        if (errors == e0) $display("  [PASS] partial frame discarded, next frame correct");

        //-- buttons and reset ------------------------------------------------
        $display("");
        $display("-- Self-test re-run ----------------------------------");
        btn = 5'b10000;
        repeat (8) @(posedge clk);
        btn = 5'd0;
        repeat (300) @(posedge clk);
        // the display stays in page mode until the page releases it
        send_req(8'h21, 32'd0, 0, 0);
        expect_ack(8'h21, "disp auto");
        check_selftest_display("BTNC");

        resetn = 1'b0;
        repeat (10) @(posedge clk);
        resetn = 1'b1;
        repeat (300) @(posedge clk);
        check_selftest_display("after reset");
        e0 = errors;
        encrypt_check(2'd3, v_key[5], v_pt[5], v_ct[5], 5);
        if (errors == e0) $display("  [PASS] UART works after CPU_RESET");

        $display("");
        $display("=====================================================");
        $display(" requests checked : %0d", checks);
        $display(" errors           : %0d", errors);
        if (errors == 0) begin
            $display(" RESULT           : *** ALL TESTS PASSED ***");
            $display("=====================================================");
            $finish;
        end else begin
            $display(" RESULT           : *** FAILED ***");
            $display("=====================================================");
            $fatal(1);
        end
    end

    initial begin
        #200_000_000;
        $display("ERROR: global timeout");
        $fatal(1);
    end

endmodule

`default_nettype wire
