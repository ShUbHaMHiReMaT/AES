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

## Run commands

Run everything in **PowerShell**, from the repository folder. Vivado is not
on the PATH by default, so start every new terminal with these two lines:

```powershell
cd C:\Users\shrey\AES-128\AES
$env:Path = "C:\Users\shrey\OneDrive\Desktop\Vivado\2023.1\bin;" + $env:Path
```

Before you start, plug the USB cable into **PROG/UART** and switch the board on.

### 1. Load the AES design onto the board (about 10 s)

```powershell
vivado -mode batch -source fpga/scripts/program.tcl
```

The output should end with `PROGRAMMED ... (DONE pin high)`, and the display
reads `AES PASS`. Loading is temporary: switch the board off and on and you
must load it again.

### 2. Check the hardware (about 30 s)

```powershell
python fpga/host/aes_board_test.py --port COM9 -n 1000
```

The output should end with `RESULT: ALL CORES CORRECT ON HARDWARE`.

### 3. Open the web console

Double-click **`fpga\web\START_CONSOLE.bat`**. Or, from the terminal:

```powershell
python -m http.server 8000 --bind 127.0.0.1 --directory fpga/web
```

Then open **http://localhost:8000** in Chrome or Edge. Click **Connect board**
and pick **USB Serial Port (COM9)**. Keep the terminal, or the black window,
open while you use the page; closing it stops the page.

Only one program can use COM9 at a time. Close the test script, other console
tabs and serial terminals before connecting.

### 4. Encrypt and decrypt (in the console)

1. Go to **Encrypt** and type a message.
2. Click **Random** next to Key to get a secret key.
3. Click **Encrypt on FPGA**. The **Ciphertext** box shows the scrambled message.
4. Click **Send to Decrypt ↓**. The **Decrypt** panel shows the original message again.
5. Change one character of the key and click **Decrypt**: you get garbage.

The FPGA only encrypts. Decryption runs in the browser.

### 5. Rebuild the bitstream (about 15 min, only after changing Verilog)

```powershell
vivado -mode batch -source fpga/scripts/build.tcl
```

This regenerates the Vivado project, builds `fpga/build/aes_nexys_a7.bit`, and
writes the numbers the console's Implementation page shows. It stops with an
error if timing is not met. Then go back to step 1 to load the new bitstream.

To look at the design in the Vivado GUI:

```powershell
vivado fpga/vivado/aes_nexys_a7.xpr
```

### 6. Simulate (no board needed)

These check the three cores on their own, about 2 minutes:

```powershell
cmd /c sim\run_xsim.bat
```

These check the whole board design, driven through its pins, about 1 minute:

```powershell
mkdir $env:TEMP\aes_sim -Force | Out-Null; mkdir $env:TEMP\aes_sim\tb\vectors -Force | Out-Null
copy tb\vectors\aes128_vectors.txt $env:TEMP\aes_sim\tb\vectors\
$src = @((Resolve-Path fpga\tb\tb_nexys_a7_top.v).Path) + (Get-ChildItem rtl\*.v, fpga\rtl\*.v).FullName
pushd $env:TEMP\aes_sim
xvlog --nolog -sv $src
xelab --nolog -top tb_nexys_a7_top -snapshot top
xsim --nolog top -runall
popd
```

Both should end with `ALL TESTS PASSED`.

### 7. Demo bitstreams

```powershell
vivado -mode batch -source fpga/smoke/build_smoke.tcl                                  # LED walk + UART echo
vivado -mode batch -source fpga/scripts/program.tcl -tclargs fpga/build/smoke.bit
python fpga/host/uart_echo_test.py --port COM9

vivado -mode batch -source fpga/demo7seg/build_seg7.tcl                                # type text -> 7-segment
vivado -mode batch -source fpga/scripts/program.tcl -tclargs fpga/build/seg7_text.bit
# then double-click fpga\web\START_DEMO.bat
```

Load `aes_nexys_a7.bit` again (step 1) to get the full AES design back.

## The console

| Section | What it does |
|---|---|
| Overview | Live board mirror, plus the proposal's objectives checked against the board |
| Encrypt | Text or hex on any core, or all three; each block checked. **Decrypt** panel: ciphertext + key gives the original message |
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
