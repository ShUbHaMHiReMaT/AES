//=============================================================================
// sca_unit.v -- side-channel capture + defence unit (fully self-contained)
//
// Added for the attack-and-defend demo. It is completely separate from the
// main aes_engine / arbiter: it has its OWN aes128_iterative core, so nothing
// here can change how the existing three cores, benchmarks, display, LEDs or
// self-test behave. It only does anything when the host sends command 0x50.
//
// On a capture request it encrypts one block and, cycle by cycle, records the
// on-chip TDC sensor into a small trace RAM. The host reads the ciphertext and
// then the TRACE_LEN-byte trace back over the link.
//
//   unprotected (protected=0): the real encryption starts at sample 0 and the
//       noise generator is off -- clean, aligned traces, so CPA/TVLA succeed.
//
//   protected  (protected=1): "hiding" countermeasures are switched on --
//       (1) the noise generator floods the sensor with data-independent
//           switching current, and
//       (2) the real encryption is launched at a RANDOM offset inside the
//           capture window, so traces no longer line up.
//       Same ciphertext, but CPA/TVLA now need far more traces / fail. This is
//       first-order *hiding*; algorithmic masking (DOM/TI) is the documented
//       next step and would drop in here as an alternative core.
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module sca_unit #(
    parameter integer TRACE_LEN = 256,              // samples per trace
    parameter integer AW        = 8                 // ceil(log2(TRACE_LEN))
) (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         trigger,                    // 1-cycle pulse: start capture
    input  wire         protected_mode,
    input  wire [127:0] key,
    input  wire [127:0] plaintext,
    input  wire [2:0]   cal_shift,                   // sensor calibration (cmd 0x51)
    input  wire [7:0]   cal_off,

    output reg          busy,
    output reg          done,                        // 1-cycle pulse when trace ready
    output reg  [127:0] ciphertext,

    // trace read-back port (host side, via the bridge)
    input  wire [AW-1:0] trace_raddr,
    output reg  [7:0]    trace_rdata
);
    //-------------------------------------------------------------------------
    // Dedicated iterative core (independent of the main engine)
    //-------------------------------------------------------------------------
    reg          core_start;
    reg  [127:0] core_key, core_pt;
    wire         core_busy, core_done;
    wire [127:0] core_ct;

    aes128_iterative u_core (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (core_start),
        .key        (core_key),
        .plaintext  (core_pt),
        .busy       (core_busy),
        .done       (core_done),
        .ciphertext (core_ct)
    );

    //-------------------------------------------------------------------------
    // Capture FSM state (declared early: the sim sensor's activity hint reads
    // smp_idx below)
    //-------------------------------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0, S_CAP = 2'd1, S_WAIT = 2'd2, S_DONE = 2'd3;
    reg [1:0]    st;
    reg [AW:0]   smp_idx;               // 0..TRACE_LEN
    reg [AW-1:0] issue_at;              // sample index at which the real enc starts
    reg          issued;
    reg          enc_done_f;            // real encryption has completed

    //-------------------------------------------------------------------------
    // Randomness, sensor, noise
    //-------------------------------------------------------------------------
    wire [31:0] rnd;
    reg         rng_en;
    rng_lfsr u_rng (.clk(clk), .rst_n(rst_n), .en(rng_en), .rnd(rnd));

    reg        noise_en;
    wire       noise_busy;
    noise_gen #(.N(8)) u_noise (.clk(clk), .rst_n(rst_n), .en(noise_en),
                                .busy_bits(noise_busy));

    // sim-only activity hint so the behavioural sensor makes data-dependent
    // traces; ignored by the real CARRY4 sensor.
    wire [7:0] activity = core_busy ? (core_pt[7:0] ^ core_key[7:0] ^ smp_idx[7:0])
                                    : (noise_en ? rnd[7:0] : 8'd0);
    wire [7:0] sensor;
    tdc_sensor u_tdc (.clk(clk), .rst_n(rst_n), .shift(cal_shift), .off(cal_off),
                      .activity(activity), .sample(sensor));

    //-------------------------------------------------------------------------
    // Trace RAM
    //-------------------------------------------------------------------------
    reg [7:0] tram [0:TRACE_LEN-1];
    always @(posedge clk) trace_rdata <= tram[trace_raddr];

    //-------------------------------------------------------------------------
    // Capture FSM
    //-------------------------------------------------------------------------
    // latch the ciphertext the moment the core finishes, in any state
    always @(posedge clk)
        if (core_done && issued) ciphertext <= core_ct;

    always @(posedge clk) begin
        if (!rst_n) begin
            st         <= S_IDLE;
            busy       <= 1'b0;
            done       <= 1'b0;
            core_start <= 1'b0;
            rng_en     <= 1'b1;         // keep the LFSR advancing for entropy
            noise_en   <= 1'b0;
            smp_idx    <= {(AW+1){1'b0}};
            issued     <= 1'b0;
            enc_done_f <= 1'b0;
        end else begin
            done       <= 1'b0;
            core_start <= 1'b0;
            if (core_done && issued) enc_done_f <= 1'b1;

            case (st)
                S_IDLE: if (trigger) begin
                    core_key   <= key;
                    core_pt    <= plaintext;
                    busy       <= 1'b1;
                    smp_idx    <= {(AW+1){1'b0}};
                    issued     <= 1'b0;
                    enc_done_f <= 1'b0;
                    noise_en   <= protected_mode;
                    // protected: random start offset inside the window, leaving
                    // room for the 11-cycle encryption; unprotected: start at 0
                    issue_at   <= protected_mode
                                  ? (8'd8 + {1'b0, rnd[6:0]})    // 8..135
                                  : {AW{1'b0}};
                    st         <= S_CAP;
                end

                S_CAP: begin
                    // record one sensor sample per clock across the window
                    tram[smp_idx[AW-1:0]] <= sensor;
                    // launch the real encryption once, at the chosen offset
                    if (!issued && smp_idx[AW-1:0] == issue_at) begin
                        core_start <= 1'b1;
                        issued     <= 1'b1;
                    end
                    if (smp_idx == TRACE_LEN - 1) begin
                        smp_idx <= {(AW+1){1'b0}};
                        st      <= S_WAIT;
                    end else begin
                        smp_idx <= smp_idx + 1'b1;
                    end
                end

                // sampling is longer than any encryption, so by here the core
                // has finished; publish and return to idle
                S_WAIT: if (enc_done_f) begin
                    noise_en <= 1'b0;
                    busy     <= 1'b0;
                    done     <= 1'b1;
                    st       <= S_IDLE;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
