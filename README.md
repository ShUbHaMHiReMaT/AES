# AES-128 Encryption Accelerator — Front-End RTL & Simulation

Verilog-2001 RTL, self-checking testbenches, and an independent golden model for
an AES-128 (ECB, encrypt-only) accelerator targeting AMD Artix-7. Covers Phases
1–3 of the project plan: RTL design, simulation/verification, and the synthesis
setup. No ASIC back-end content.

## Status

Everything below has been run and passes:

```
Golden model vs. published NIST vectors ....... 8/8 PASS
RTL S-box vs. algebraic definition ............ 256/256 PASS
aes128_iterative .............................. 1020 blocks, 0 errors
aes128_iterative_ii10 ......................... 1013 blocks, 0 errors
aes128_pipelined .............................. 1013 blocks, 0 errors
Mutation testing .............................. 6/6 faults caught by 3/3 TBs
```

## Quick start

```powershell
scoop install main/iverilog        # one-time; or use Vivado's xsim, see below
.\sim\run_all.ps1                  # full regression, ~2 minutes
```

On Linux/macOS or with GNU make:

```
make                    # everything
make ii10               # one core
make wave CORE=ii10     # same, dumping a VCD for GTKWave
make mutation
```

Under the Vivado Simulator instead of Icarus, from the repo root:

```
sim\run_xsim.bat
```

## The three cores

| Core | Cycles/block | Latency | Datapath | Intended for |
|---|---|---|---|---|
| `aes128_iterative` | 11 | 11 | 1 round + 1 key-expand | smallest; IoT / area-bound |
| `aes128_iterative_ii10` | 10 | 11 | + whitening stage | **hits the 4.92 Gbps target** |
| `aes128_pipelined` | 1 | 11 | 10 rounds unrolled | data-centre throughput |

All three share `aes_sbox.v`, `aes_round.v`, and `aes_key_expand.v`, and all
compute the key schedule **on the fly** — 4 S-boxes and 128 flops per key-expand
step, instead of the 1408 flops a precomputed schedule would need.

### Why there are two iterative cores

The project spec asks for **4.92 Gbps at 384.6 MHz with 11-cycle latency**. Those
three numbers are only consistent if the *initiation interval* is 10, not 11:

```
128 bits x 384.6 MHz / 10 cycles = 4.923 Gbps   <- the spec figure
128 bits x 384.6 MHz / 11 cycles = 4.476 Gbps   <- plain iterative
```

The plain iterative core spends one cycle on the initial AddRoundKey and ten on
the rounds, so a new block can only start every 11 cycles. `aes128_iterative_ii10`
puts the initial AddRoundKey in its own small register stage, which then overlaps
with round 10 of the previous block. A block still takes 11 cycles end to end,
but a new one starts every 10 — the testbench asserts this holds for *every*
block in the stream, not just on average:

```
initiation intvl : 10 cycles
throughput       : 128 bits / 10 cycles @ 384.6 MHz = 4.92 Gbps
```

Cost of the overlap: one 128-bit state register, one 128-bit key register, and
two 128-bit 2:1 muxes.

## How correctness is established

Three independent layers, because a passing testbench proves nothing on its own:

**1. The golden model is not derived from the RTL.** `model/aes_golden.py` is a
standalone AES-128 implementation. Its S-box is *computed* from the algebraic
definition (multiplicative inverse in GF(2⁸) followed by the affine transform),
not typed in as a table. It is first checked against eight published vectors
(FIPS-197 Appendix B and C.1, the four SP 800-38A ECB vectors, and two AESAVS
cases) before it is trusted to generate anything.

**2. The RTL S-box table is diffed against that computed table**, all 256
entries. A single mistyped byte fails the regression instead of silently
producing wrong ciphertext for a fraction of inputs.

**3. Mutation testing proves the testbenches can fail.** `sim/mutation_test.py`
injects six realistic single-point bugs — a wrong S-box entry, ShiftRows row 3
rotated by 1 instead of 3, a MixColumns coefficient of {01} where {02} belongs,
Rcon XORed into the wrong byte of the word, a broken key-schedule chain, and
MixColumns not bypassed on the final round — and asserts every testbench rejects
every one. All 6 × 3 combinations are currently caught.

Beyond ciphertext, the testbenches check the things that break real integrations:
exact cycle latency, `done` being a single pulse, ciphertext holding after
`done`, `start` ignored while busy, back-to-back issue, mid-flight reset
recovery, and — for the pipelined core — a **different key on every cycle** with
garbage driven on the data buses during invalid beats. That last one is the case
that catches designs sharing one key-schedule register across the pipeline.

Vectors are 1013 per run: 8 published KATs, 5 hand-picked edge cases, and 1000
random key/plaintext pairs from a fixed seed (reproducible; change with
`-Vectors N` or `VECTORS=N`).

## Files

```
rtl/    aes_sbox.v                 256-byte ROM, distributed-LUT
        aes_round.v                SubBytes/ShiftRows/MixColumns/AddRoundKey
        aes_key_expand.v           one on-the-fly key-schedule step
        aes128_iterative.v         II=11 low-area core
        aes128_iterative_ii10.v    II=10 overlapped core
        aes128_pipelined.v         11-stage unrolled pipeline
tb/     tb_aes128_*.v              self-checking testbenches
        vectors/                   generated; not hand-edited
model/  aes_golden.py              independent reference + vector generator
sim/    run_all.ps1                full regression (Windows)
        mutation_test.py           fault injection
        run_xsim.bat               Vivado Simulator flow
        run_vivado_synth.tcl       OOC synth + impl, utilisation and Fmax
constr/ aes_core_ooc.xdc           out-of-context timing constraints
Makefile                           same flow via GNU make
```

## Synthesis (Phase 3)

```
vivado -mode batch -source sim/run_vivado_synth.tcl
vivado -mode batch -source sim/run_vivado_synth.tcl -tclargs xc7a35ticsg324-1L
```

Synthesises each core out-of-context, implements it, and prints a table of
LUT/FF/BRAM/DSP counts plus the Fmax implied by the post-route WNS. Reports land
in `sim/synth_out/`.

**I have not run this** — Vivado is not installed on this machine, so the script
is written but unverified, and the expectations below are estimates from the
structure of the design, not measurements. Treat them as such until you run it.

Two things I would expect to differ from the reference paper's numbers:

- **The `<3% LUT` target applies to the iterative cores only.** Roughly 20
  S-boxes at ~32 LUT6 each plus the MixColumns XOR tree puts them near
  1000–1300 LUTs, which is ~2% of an xc7a100t — consistent with the paper's
  2.14%. The pipelined core instantiates 200 S-boxes and 10 MixColumns networks;
  expect roughly 10–12k LUTs, or ~18% of the same device. That is the price of
  49 Gbps and it cannot be reconciled with a 3% budget. Pick one target or the
  other.
- **384.6 MHz on a -1 speed grade Artix-7 is aggressive** for a datapath with a
  full round (S-box → MixColumns → XOR) between registers. Without splitting the
  round, expect something in the 150–250 MHz range. To close at the target,
  either register the S-box output inside the round (sub-pipelining, which adds
  a stage to the latency) or move to a faster speed grade. The constraint file
  is set to the 2.600 ns target so the failure is visible rather than hidden.

BRAM usage is zero as written — the S-boxes map to distributed ROM. That clears
the `<15% BRAM` target trivially. If you want the S-boxes in block RAM instead
(useful only for the iterative cores, where the ROM's registered output can be
absorbed), add a pipeline register inside `aes_sbox` and add one cycle to the
round; `(* rom_style = "block" *)` on `SBOX_ROM` then gets Vivado to infer it.

## Scope

Encrypt-only, ECB, 128-bit key. No decryption datapath, no chaining mode, no bus
interface (AXI/AXI-Stream) — the cores expose a plain start/done or valid/valid
handshake, and a wrapper is Phase 4 work once the board is chosen.

Both iterative cores are **not** constant-time-hardened against side channels:
the S-box is a plain ROM lookup and there is no masking. Timing is data
independent (fixed cycle count), so remote timing attacks are not a concern, but
power/EM analysis is out of scope here — worth stating explicitly in the design
report rather than leaving implied.

## References

- NIST FIPS-197, *Advanced Encryption Standard* — algorithm and Appendix B/C vectors
- NIST SP 800-38A — ECB mode vectors
- AESAVS — the all-zero and all-ones known-answer cases
