//=============================================================================
// aes_engine.v -- all three AES-128 cores behind one request interface
//
// Two modes, both on whichever core `sel` picks:
//
//   single (bench = 0)   encrypt `data` once; result = ciphertext
//   bench  (bench = 1)   encrypt `count` blocks back to back at the core's
//                        full rate, plaintext i = data + i (a CTR-style
//                        counter, so the host can recompute every block);
//                        result = XOR of all `count` ciphertexts
//
//   sel  1 aes128_iterative   2 aes128_iterative_ii10   3 aes128_pipelined
//
// cycles is counted in hardware: the edge that issues the first block is
// cycle 1, and the count is taken on the cycle the last result is valid.
// For one block that is the latency (11 on every core). For a stream it is
// the whole run, which is what the throughput figure must be computed from:
//
//   iterative   11 N          (one block every 11 cycles)
//   ii10        10 N + 1      (one every 10, plus the first block's extra)
//   pipelined   N + 10        (one every cycle, plus the pipe fill)
//
// Handshake: start is acted on only while busy is low; done pulses once with
// result/cycles/timeout valid and held. timeout = the core went 255 cycles
// without accepting or returning a block.
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module aes_engine (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         start,
    input  wire         bench,
    input  wire [1:0]   sel,
    input  wire [127:0] key,
    input  wire [127:0] data,
    input  wire [31:0]  count,

    output reg          busy,
    output reg          done,
    output reg  [127:0] result,
    output reg  [31:0]  cycles,
    output reg          timeout,
    output reg  [31:0]  blocks_total
);

    localparam [1:0] SEL_ITER = 2'd1,
                     SEL_II10 = 2'd2,
                     SEL_PIPE = 2'd3;

    //-------------------------------------------------------------------------
    // Request state
    //-------------------------------------------------------------------------
    reg [127:0] key_r;
    reg [127:0] data_r;     // next plaintext to issue
    reg [127:0] acc;        // XOR of results so far
    reg [1:0]   sel_r;
    reg [31:0]  to_issue;
    reg [31:0]  to_recv;
    reg [31:0]  cnt;
    reg         started;
    reg [7:0]   quiet;      // cycles with neither an issue nor a result

    //-------------------------------------------------------------------------
    // Cores
    //-------------------------------------------------------------------------
    wire         it_busy, it_done;
    wire [127:0] it_ct;
    wire         ii_ready, ii_done;
    wire [127:0] ii_ct;
    wire         pl_valid;
    wire [127:0] pl_ct;

    reg can_accept;
    always @(*) begin
        case (sel_r)
            SEL_ITER: can_accept = !it_busy;    // incl. the cycle done is high
            SEL_II10: can_accept = ii_ready;
            SEL_PIPE: can_accept = 1'b1;        // never stalls
            default:  can_accept = 1'b0;
        endcase
    end

    wire issue = busy && (to_issue != 32'd0) && can_accept;

    aes128_iterative u_iter (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (issue && sel_r == SEL_ITER),
        .key        (key_r),
        .plaintext  (data_r),
        .busy       (it_busy),
        .done       (it_done),
        .ciphertext (it_ct)
    );

    aes128_iterative_ii10 u_ii10 (
        .clk        (clk),
        .rst_n      (rst_n),
        .ready      (ii_ready),
        .start      (issue && sel_r == SEL_II10),
        .key        (key_r),
        .plaintext  (data_r),
        .done       (ii_done),
        .ciphertext (ii_ct)
    );

    aes128_pipelined u_pipe (
        .clk        (clk),
        .rst_n      (rst_n),
        .in_valid   (issue && sel_r == SEL_PIPE),
        .key        (key_r),
        .plaintext  (data_r),
        .out_valid  (pl_valid),
        .ciphertext (pl_ct)
    );

    reg         core_done;
    reg [127:0] core_ct;
    always @(*) begin
        case (sel_r)
            SEL_ITER: begin core_done = it_done;  core_ct = it_ct; end
            SEL_II10: begin core_done = ii_done;  core_ct = ii_ct; end
            SEL_PIPE: begin core_done = pl_valid; core_ct = pl_ct; end
            default:  begin core_done = 1'b0;     core_ct = 128'd0; end
        endcase
    end

    //-------------------------------------------------------------------------
    // Control
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            key_r        <= 128'd0;
            data_r       <= 128'd0;
            acc          <= 128'd0;
            sel_r        <= 2'd0;
            to_issue     <= 32'd0;
            to_recv      <= 32'd0;
            cnt          <= 32'd0;
            started      <= 1'b0;
            quiet        <= 8'd0;
            busy         <= 1'b0;
            done         <= 1'b0;
            result       <= 128'd0;
            cycles       <= 32'd0;
            timeout      <= 1'b0;
            blocks_total <= 32'd0;
        end else begin
            done <= 1'b0;

            if (!busy) begin
                if (start) begin
                    key_r    <= key;
                    data_r   <= data;
                    sel_r    <= sel;
                    to_issue <= bench ? count : 32'd1;
                    to_recv  <= bench ? count : 32'd1;
                    acc      <= 128'd0;
                    cnt      <= 32'd0;
                    started  <= 1'b0;
                    quiet    <= 8'd0;
                    busy     <= 1'b1;
                end
            end else if (to_recv == 32'd0) begin
                // bench with count = 0: nothing to do
                busy    <= 1'b0;
                done    <= 1'b1;
                result  <= 128'd0;
                cycles  <= 32'd0;
                timeout <= 1'b0;
            end else begin
                if (issue) begin
                    to_issue <= to_issue - 32'd1;
                    data_r   <= data_r + 128'd1;
                end

                if (!started) begin
                    if (issue) begin
                        started <= 1'b1;
                        cnt     <= 32'd1;
                    end
                end else begin
                    cnt <= cnt + 32'd1;
                end

                if (core_done) begin
                    acc          <= acc ^ core_ct;
                    to_recv      <= to_recv - 32'd1;
                    blocks_total <= blocks_total + 32'd1;
                end

                if (core_done && to_recv == 32'd1) begin
                    busy    <= 1'b0;
                    done    <= 1'b1;
                    result  <= acc ^ core_ct;
                    cycles  <= cnt;
                    timeout <= 1'b0;
                end else if (issue || core_done) begin
                    quiet <= 8'd0;
                end else if (quiet == 8'hff) begin
                    busy    <= 1'b0;
                    done    <= 1'b1;
                    result  <= 128'd0;
                    cycles  <= cnt;
                    timeout <= 1'b1;
                end else begin
                    quiet <= quiet + 8'd1;
                end
            end
        end
    end

endmodule

`default_nettype wire
