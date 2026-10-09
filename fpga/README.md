# AES-128 on the Nexys A7-100T

Hardware implementation of the three AES-128 cores in `rtl/` on a Digilent
Nexys A7-100T (xc7a100tcsg324-1). A web console lets you see and control
everything on the board.

## Measured on the board

| | Iterative | Overlapped (ii10) | Pipelined |
|---|---|---|---|
| Correct vs. reference (8 NIST KATs + 1000 random) | 1008/1008 | 1008/1008 | 1008/1008 |
| Latency, counted in hardware | 11 cycles | 11 cycles | 11 cycles |
| Cycles for 1,048,576 blocks | 11,534,336 (11N) | 10,485,761 (10N+1) | 1,048,586 (N+10) |
| Throughput at 100 MHz | 1.16 Gbps | 1.28 Gbps | **12.8 Gbps** |
| LUTs (share of xc7a100t) | 1,248 (1.97 %) | 1,421 (2.24 %) | 9,393 (14.8 %) |
| Flip-flops | 398 | 655 | 2,699 |
| Fmax proven by this build | ≥ 127 MHz | ≥ 105 MHz | ≥ 118 MHz |

How the figures were obtained:

- **Correctness** is checked against `model/aes_golden.py` and against the
  browser's own AES.
- **Throughput** comes from the FPGA streaming blocks internally and counting
  cycles itself. The XOR of every ciphertext is recomputed on the PC.
- **Fmax** is a lower bound. The build is constrained to the 100 MHz board
  clock, and Vivado stops optimising once that is met.
- **Power and environment:** Vivado estimates 0.6 W for the whole design. The
  die runs at about 37 °C, with VCCINT at 1.009 V (live from the XADC).

## Use it

1. Plug the USB cable into **PROG/UART** and switch the board on.
2. Load the design:
   `vivado -mode batch -source fpga/scripts/program.tcl`. You can also use
   Vivado Hardware Manager → Program Device → `fpga/build/aes_nexys_a7.bit`.
   The display should then read `AES PASS`.
3. Double-click **`fpga/web/START_CONSOLE.bat`**, then click **Connect board**
   and pick the USB Serial Port (COM9).

Only one program can use the COM port at a time. Close other console tabs,
serial terminals and `aes_board_test.py` before connecting.

The console has these sections:

| Section | What it does |
|---|---|
| Overview | Live board mirror, plus the proposal's objectives checked against the board |
| Encrypt | Text or hex on any core, or all three; each block checked and decrypted back |
| Inside AES | Round-by-round state matrices and key schedule, checked on the FPGA |
| Benchmark | Hardware-counted Gbps per core with WebCrypto-verified checksums, and a constant-time check |
| Image Lab | An image encrypted by the FPGA in ECB (structure leaks) and CTR (it doesn't) |
| NIST Verification | KATs plus random vectors through every core |
| Board Control | 7-segment text, LEDs and RGB LEDs, live switches and buttons, self-test |
| Implementation | Utilisation, timing and power from the build, compared with the project targets |

**Board buttons:**

- SW1–SW0 select the core.
- **BTNU** encrypts a random block and scrolls the ciphertext on the display.
- **BTND** runs a 1 M-block benchmark and shows the Gbps figure.
- **BTNC** re-runs the self-test.

## Rebuild, simulate, test

```powershell
vivado -mode batch -source fpga/scripts/build.tcl      # project + bitstream + web/build_info.json
vivado -mode batch -source fpga/scripts/program.tcl    # JTAG, volatile
python fpga/host/aes_board_test.py --port COM9 -n 1000 # hardware regression
```

`build.tcl` regenerates `fpga/vivado/aes_nexys_a7.xpr`, so you can open that
file in the Vivado GUI. In the GUI, **Run Simulation** runs
`tb/tb_nexys_a7_top.v`. That testbench drives the whole design through its pins
and checks every command, benchmark cycle counts and checksums, 40 queued
requests, resynchronisation, buttons and reset.

## Protocol (1 Mbaud, 8N1)

The PC sends a 37-byte request:
`[cmd][arg: 4 bytes][key: 16 bytes][data: 16 bytes]`.
The FPGA replies with 22 bytes:
`[echo][status][aux: 4 bytes][payload: 16 bytes]`.
Multi-byte fields are sent most significant byte first.

| cmd | Action | Reply |
|---|---|---|
| `00` | ping | `aux` = {version, MHz, baud/100k}; payload = ID string |
| `01`–`03` | encrypt `data` with `key` on core 1, 2 or 3 | `aux` = latency in cycles; payload = ciphertext |
| `11`–`13` | benchmark: `arg` blocks, plaintext *i* = `data` + *i* | `aux` = cycles; payload = XOR of all ciphertexts |
| `20` | write 16 display patterns at offset `arg` | ack |
| `21` | show the display; `arg` = {flags, speed, len} | ack |
| `22` | LEDs: `arg[31]` = manual, `arg[5:0]` = RGB; `data[15:0]` = pattern | ack |
| `30` | status: switches, buttons, self-test, temperature, VCCINT, counters | |
| `40` | re-run the self-test | `status` = self-test result |

A 4 KB receive FIFO lets the host keep up to 110 requests in flight. The
console keeps 64, so the Windows FTDI latency timer doesn't throttle the link.
Full details are in `rtl/aes_uart_bridge.v`.

## Files

```
rtl/      nexys_a7_top.v      pins, reset, self-test, arbiter, LEDs, sensors
          aes_engine.v        the three cores: single-block and streaming benchmark
          aes_uart_bridge.v   host protocol;  byte_fifo.v  receive buffer
          seg7_ctrl.v         display;        xadc_mon.v   temperature / VCCINT
          uart_rx.v, uart_tx.v
constr/   nexys_a7_100t.xdc
tb/       tb_nexys_a7_top.v
scripts/  create_project.tcl, build.tcl, program.tcl, board.ps1
host/     aes_board_test.py   hardware regression;  uart_echo_test.py
web/      index.html + js/ + app.css   the console;  START_CONSOLE.bat
          seg7_demo.html + START_DEMO.bat  (needs seg7_text.bit from demo7seg/)
smoke/, demo7seg/  first-power-up and display demos
```

## Not in this build

- **Side-channel masking.** The cores take a constant 11 cycles, which defeats
  timing attacks, but nothing protects them against power or EM analysis.
- **AXI4-Lite.** That needs a soft CPU such as MicroBlaze; this build talks to
  the PC over UART instead.
- **The 384.6 MHz clock from the reference paper.** The overlapped core meets
  the paper's 10 cycles per block, but this build only proves about 105 MHz.
  Reaching 384.6 MHz would need the round split into two pipeline stages, or a
  faster speed grade.
