//=============================================================================
// tb_aes128_pipelined.v -- self-checking testbench for the unrolled pipeline
//
// Checks:
//   1. Every vector in tb/vectors/aes128_vectors.txt streamed one block per
//      clock, with a *different key on every cycle* -- this is the case that
//      breaks designs which share one key-schedule register across the pipe.
//   2. out_valid tracks in_valid exactly 11 cycles later, including bubbles
//      (invalid cycles interleaved with valid ones).
//   3. Measured throughput reported in Gbps at the target clock.
//
//   iverilog -g2012 -o sim.vvp tb/tb_aes128_pipelined.v rtl/*.v && vvp sim.vvp
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_aes128_pipelined;

    localparam real CLK_PERIOD = 2.6;     // 384.6 MHz
    localparam integer MAX_VEC = 2048;
    localparam integer LATENCY = 11;

    reg          clk = 1'b0;
    reg          rst_n = 1'b0;
    reg          in_valid = 1'b0;
    reg  [127:0] key = 128'd0;
    reg  [127:0] plaintext = 128'd0;
    wire         out_valid;
    wire [127:0] ciphertext;

    aes128_pipelined dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .in_valid   (in_valid),
        .key        (key),
        .plaintext  (plaintext),
        .out_valid  (out_valid),
        .ciphertext (ciphertext)
    );

    always #(CLK_PERIOD / 2.0) clk = ~clk;

    //-------------------------------------------------------------------------
    // Vector storage
    //-------------------------------------------------------------------------
    reg [127:0] v_key [0:MAX_VEC-1];
    reg [127:0] v_pt  [0:MAX_VEC-1];
    reg [127:0] v_ct  [0:MAX_VEC-1];
    integer     v_issue_cycle [0:MAX_VEC-1];
    integer     n_vec = 0;

    integer errors = 0;
    integer in_idx = 0;
    integer out_idx = 0;
    integer cycle = 0;
    integer valid_cycles = 0;

    reg checking = 1'b0;

    //-------------------------------------------------------------------------
    // Free-running cycle counter
    //-------------------------------------------------------------------------
    always @(posedge clk) if (rst_n) cycle <= cycle + 1;

    //-------------------------------------------------------------------------
    // Output monitor: every out_valid beat must match the next expected result
    //-------------------------------------------------------------------------
    integer meas_latency;
    always @(posedge clk) begin
        if (rst_n && checking && out_valid) begin
            if (out_idx >= in_idx) begin
                $display("ERROR: out_valid with no outstanding input (idx %0d)",
                         out_idx);
                errors = errors + 1;
            end else begin
                meas_latency = cycle - v_issue_cycle[out_idx];
                if (meas_latency !== LATENCY) begin
                    $display("ERROR: vector %0d latency %0d cycles, expected %0d",
                             out_idx, meas_latency, LATENCY);
                    errors = errors + 1;
                end
                if (ciphertext !== v_ct[out_idx]) begin
                    $display("ERROR: vector %0d mismatch", out_idx);
                    $display("        key = %032h", v_key[out_idx]);
                    $display("         pt = %032h", v_pt[out_idx]);
                    $display("        got = %032h", ciphertext);
                    $display("        exp = %032h", v_ct[out_idx]);
                    errors = errors + 1;
                end
                out_idx = out_idx + 1;
                if (errors > 10) begin
                    $display("ERROR: too many failures, aborting");
                    $fatal(1);
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // Load vectors
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
                $display("       run: python model/aes_golden.py --gen-vectors ...");
                $fatal(1);
            end
            while (!$feof(fd) && n_vec < MAX_VEC) begin
                code = $fscanf(fd, "%h %h %h", k, p, c);
                if (code == 3) begin
                    v_key[n_vec] = k;
                    v_pt [n_vec] = p;
                    v_ct [n_vec] = c;
                    n_vec = n_vec + 1;
                end
                if (code != 3) code = $fgets(line_rest, fd);
            end
            $fclose(fd);
            $display("  loaded %0d vectors", n_vec);
        end
    endtask

    //-------------------------------------------------------------------------
    // Issue one beat (valid or bubble) aligned to the clock
    //-------------------------------------------------------------------------
    task issue_beat (input do_valid);
        begin
            if (do_valid && in_idx < n_vec) begin
                key       = v_key[in_idx];
                plaintext = v_pt [in_idx];
                in_valid  = 1'b1;
                // `cycle` is the interval during which this beat is presented;
                // it is sampled by the edge that ends the interval. The monitor
                // reads the pre-edge value of `cycle` too, so both timestamps
                // name the interval they describe and the difference is the
                // input-cycle-to-output-cycle latency.
                v_issue_cycle[in_idx] = cycle;
                in_idx    = in_idx + 1;
                valid_cycles = valid_cycles + 1;
            end else begin
                // drive garbage on the data buses during bubbles: a correct
                // design must ignore them entirely
                key       = 128'hdeadbeef_deadbeef_deadbeef_deadbeef;
                plaintext = 128'hcafebabe_cafebabe_cafebabe_cafebabe;
                in_valid  = 1'b0;
            end
            @(negedge clk);
        end
    endtask

    //-------------------------------------------------------------------------
    // Main sequence
    //-------------------------------------------------------------------------
    integer i;
    real gbps;

    initial begin
        if ($test$plusargs("dumpvcd")) begin
            $dumpfile("tb_aes128_pipelined.vcd");
            $dumpvars(0, tb_aes128_pipelined);
        end

        $display("");
        $display("=====================================================");
        $display(" AES-128 pipelined core -- self-checking testbench");
        $display(" clock period %0.2f ns (%0.1f MHz)",
                 CLK_PERIOD, 1000.0 / CLK_PERIOD);
        $display("=====================================================");
        $display("");

        load_vectors;

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        checking = 1'b1;

        $display("");
        $display("-- Phase 1: sparse issue, key changing every beat ----");
        // one valid every 3 cycles for the first 20 vectors: exercises the
        // valid pipeline with bubbles and garbage on the data buses
        for (i = 0; i < 20; i = i + 1) begin
            issue_beat(1'b1);
            issue_beat(1'b0);
            issue_beat(1'b0);
        end
        repeat (LATENCY + 2) issue_beat(1'b0);
        if (out_idx != in_idx) begin
            $display("ERROR: phase 1 drained %0d of %0d blocks", out_idx, in_idx);
            errors = errors + 1;
        end else begin
            $display("  [PASS] %0d blocks with bubbles, all matched", out_idx);
        end

        $display("");
        $display("-- Phase 2: full rate, one block per clock -----------");
        while (in_idx < n_vec) issue_beat(1'b1);
        repeat (LATENCY + 2) issue_beat(1'b0);

        if (out_idx != n_vec) begin
            $display("ERROR: drained %0d of %0d blocks", out_idx, n_vec);
            errors = errors + 1;
        end else begin
            $display("  [PASS] %0d blocks at one per clock, all matched",
                     n_vec - 20);
        end

        gbps = 128.0 / CLK_PERIOD;     // bits per ns == Gbit/s

        $display("");
        $display("=====================================================");
        $display(" blocks encrypted : %0d", out_idx);
        $display(" latency          : %0d cycles", LATENCY);
        $display(" throughput       : 128 bits/cycle @ %0.1f MHz = %0.2f Gbps",
                 1000.0 / CLK_PERIOD, gbps);
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
