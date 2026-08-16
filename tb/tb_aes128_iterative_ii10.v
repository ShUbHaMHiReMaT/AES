//=============================================================================
// tb_aes128_iterative_ii10.v -- self-checking TB for the overlapped iterative core
//
// Checks:
//   1. Isolated-block latency is exactly 11 cycles (start cycle -> done cycle).
//   2. Streaming a full vector file with the driver always asserting start
//      whenever ready: every ciphertext correct, in order, and the steady-state
//      initiation interval is exactly 10 cycles -- which is what turns 384.6 MHz
//      into the project's 4.92 Gbps target.
//   3. The core never asserts done without an outstanding block.
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_aes128_iterative_ii10;

    localparam real CLK_PERIOD = 2.6;      // 384.6 MHz
    localparam integer MAX_VEC = 2048;

    reg          clk = 1'b0;
    reg          rst_n = 1'b0;
    reg          start = 1'b0;
    reg  [127:0] key = 128'd0;
    reg  [127:0] plaintext = 128'd0;
    wire         ready;
    wire         done;
    wire [127:0] ciphertext;

    aes128_iterative_ii10 dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .ready      (ready),
        .start      (start),
        .key        (key),
        .plaintext  (plaintext),
        .done       (done),
        .ciphertext (ciphertext)
    );

    always #(CLK_PERIOD / 2.0) clk = ~clk;

    //-------------------------------------------------------------------------
    reg [127:0] v_key [0:MAX_VEC-1];
    reg [127:0] v_pt  [0:MAX_VEC-1];
    reg [127:0] v_ct  [0:MAX_VEC-1];
    integer     n_vec = 0;

    integer errors  = 0;
    integer in_idx  = 0;
    integer out_idx = 0;
    integer cycle   = 0;

    reg     checking   = 1'b0;
    integer last_done  = -1;
    integer min_gap    = 9999;
    integer max_gap    = 0;

    always @(posedge clk) if (rst_n) cycle <= cycle + 1;

    //-------------------------------------------------------------------------
    // Output monitor
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && checking && done) begin
            if (out_idx >= in_idx) begin
                $display("ERROR: done with no outstanding block (idx %0d)", out_idx);
                errors = errors + 1;
            end else begin
                if (ciphertext !== v_ct[out_idx]) begin
                    $display("ERROR: vector %0d mismatch", out_idx);
                    $display("        key = %032h", v_key[out_idx]);
                    $display("         pt = %032h", v_pt [out_idx]);
                    $display("        got = %032h", ciphertext);
                    $display("        exp = %032h", v_ct [out_idx]);
                    errors = errors + 1;
                end
                if (last_done >= 0) begin
                    if (cycle - last_done < min_gap) min_gap = cycle - last_done;
                    if (cycle - last_done > max_gap) max_gap = cycle - last_done;
                end
                last_done = cycle;
                out_idx = out_idx + 1;
                if (errors > 10) begin
                    $display("ERROR: too many failures, aborting");
                    $fatal(1);
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    integer fd, code;
    reg [8*256-1:0] line_rest;
    reg [127:0] k, p, c;

    task load_vectors;
        begin
            fd = $fopen("tb/vectors/aes128_vectors.txt", "r");
            if (fd == 0) fd = $fopen("vectors/aes128_vectors.txt", "r");
            if (fd == 0) begin
                $display("ERROR: cannot open tb/vectors/aes128_vectors.txt");
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
    // Isolated block: measure true start-to-done latency with an empty core
    //-------------------------------------------------------------------------
    task check_isolated_latency (
        input [127:0] tk, input [127:0] tp, input [127:0] te,
        input [8*24-1:0] label
    );
        integer t0, n;
        begin
            @(negedge clk);
            while (!ready) @(negedge clk);
            key = tk;  plaintext = tp;  start = 1'b1;
            t0 = cycle;
            @(negedge clk);
            start = 1'b0;
            n = 0;
            while (!done) begin
                @(negedge clk);
                n = n + 1;
                if (n > 40) begin
                    $display("ERROR [%0s]: hang", label);
                    errors = errors + 1;
                    disable check_isolated_latency;
                end
            end
            if ((cycle - t0) !== 11) begin
                $display("ERROR [%0s]: latency %0d cycles, expected 11",
                         label, cycle - t0);
                errors = errors + 1;
            end
            if (ciphertext !== te) begin
                $display("ERROR [%0s]: got %032h exp %032h", label, ciphertext, te);
                errors = errors + 1;
            end
            @(negedge clk);
        end
    endtask

    //-------------------------------------------------------------------------
    integer i;
    real gbps;

    initial begin
        if ($test$plusargs("dumpvcd")) begin
            $dumpfile("tb_aes128_iterative_ii10.vcd");
            $dumpvars(0, tb_aes128_iterative_ii10);
        end

        $display("");
        $display("=====================================================");
        $display(" AES-128 overlapped iterative core (II=10)");
        $display(" clock period %0.2f ns (%0.1f MHz)",
                 CLK_PERIOD, 1000.0 / CLK_PERIOD);
        $display("=====================================================");
        $display("");

        load_vectors;

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        $display("");
        $display("-- Isolated-block latency ----------------------------");
        // checking is off, so the monitor ignores these
        check_isolated_latency(128'h2b7e151628aed2a6abf7158809cf4f3c,
                               128'h3243f6a8885a308d313198a2e0370734,
                               128'h3925841d02dc09fbdc118597196a0b32,
                               "FIPS-197 App. B");
        check_isolated_latency(128'h000102030405060708090a0b0c0d0e0f,
                               128'h00112233445566778899aabbccddeeff,
                               128'h69c4e0d86a7b0430d8cdb78070b4c55a,
                               "FIPS-197 App. C.1");
        if (errors == 0)
            $display("  [PASS] 2 isolated blocks, 11-cycle latency each");

        // let the core settle before the streaming phase
        repeat (4) @(negedge clk);
        checking = 1'b1;

        $display("");
        $display("-- Streaming at maximum rate -------------------------");
        while (in_idx < n_vec) begin
            @(negedge clk);
            if (ready) begin
                key       = v_key[in_idx];
                plaintext = v_pt [in_idx];
                start     = 1'b1;
                in_idx    = in_idx + 1;
            end else begin
                key       = 128'hdeadbeef_deadbeef_deadbeef_deadbeef;
                plaintext = 128'hcafebabe_cafebabe_cafebabe_cafebabe;
                start     = 1'b0;
            end
        end
        @(negedge clk);
        start = 1'b0;
        // drain
        i = 0;
        while (out_idx < n_vec && i < 200) begin
            @(negedge clk);
            i = i + 1;
        end

        if (out_idx != n_vec) begin
            $display("ERROR: drained %0d of %0d blocks", out_idx, n_vec);
            errors = errors + 1;
        end else begin
            $display("  [PASS] %0d blocks streamed, all ciphertexts matched",
                     n_vec);
        end

        if (min_gap !== 10 || max_gap !== 10) begin
            $display("ERROR: initiation interval min %0d max %0d, expected 10",
                     min_gap, max_gap);
            errors = errors + 1;
        end else begin
            $display("  [PASS] initiation interval is 10 cycles, every block");
        end

        gbps = 128.0 / (10.0 * CLK_PERIOD);

        $display("");
        $display("=====================================================");
        $display(" blocks encrypted : %0d", out_idx);
        $display(" latency          : 11 cycles");
        $display(" initiation intvl : %0d cycles", min_gap);
        $display(" throughput       : 128 bits / %0d cycles @ %0.1f MHz = %0.2f Gbps",
                 min_gap, 1000.0 / CLK_PERIOD, gbps);
        $display(" errors           : %0d", errors);
        if (errors == 0) begin
            $display(" RESULT           : *** ALL TESTS PASSED ***");
            $display("=====================================================");
            $display("");
            $finish;
        end else begin
            $display(" RESULT           : *** FAILED ***");
            $display("=====================================================");
            $display("");
            $fatal(1);
        end
    end

    initial begin
        #20_000_000;
        $display("ERROR: global timeout");
        $fatal(1);
    end

endmodule

`default_nettype wire
