# Side-channel attack & defend — on-chip power analysis

Attack our own AES on the Nexys A7 with **no oscilloscope and no extra
hardware**: a tiny time-to-digital sensor built from the FPGA's own carry
chain measures the chip's power as it encrypts, and streams the readings out
over the same USB link. A second laptop (Kali) does the analysis.

```
 Kali laptop                       Windows laptop                 Nexys A7
 (CPA / TVLA / plots)   LAN/TCP     (relay.py: COM <-> TCP)   USB  (AES + sensor)
 ----------------------------------------------------------------------------
 attack.py  --------------------->  relay.py  <-------------------> command 0x50
            <---------------------            <------------------->  trace bytes
```

Everything here is **additive**: the three AES cores, benchmarks, display,
LEDs and self-test are unchanged. The sensor + capture live in their own unit
(`fpga/rtl/sca_unit.v`) with its own AES core, reachable only through the new
command `0x50`. Default behaviour is identical to before.

Two defence levels, both keeping the ciphertext identical:
* **unprotected** — clean aligned traces; CPA recovers the key, TVLA screams.
* **protected** (hiding) — an on-chip noise generator + a random trigger
  offset per encryption. Same output, but traces no longer align, so CPA
  needs far more traces / fails and TVLA drops toward the 4.5 pass line.
  Algorithmic masking (DOM/TI) is the documented next step and drops into
  `sca_unit.v` as an alternative core.

---

## 0. Right now, with NO board (prove the maths)

On either laptop, in the repo:

```
python fpga/attack/selftest.py
```

It fakes sensor traces from a known key and shows CPA pulling all 16 key bytes
out of the unprotected traces, failing on the protected (masked) traces, and
TVLA reading ~100 (leaks) vs ~2 (safe). If this passes, the analysis is
correct and only signal quality is left to the real hardware.

---

## 1. Flash the board (Windows, once)

Rebuild the bitstream with the sensor + `0x50`, then program it. In the Vivado
**Tcl Console**:

```
cd C:/Users/shrey/AES-128/AES
source fpga/scripts/build.tcl
```

Program `C:\Users\shrey\AES-128\AES\fpga\build\aes_nexys_a7.bit` from the
Hardware Manager. Sanity-check the normal functions still work:

```
python fpga/host/aes_board_test.py --port COM9 -n 200
```

---

## 2. Start the relay (Windows laptop, the board is plugged into it)

```
python fpga/host/relay.py --port COM9 --listen 0.0.0.0:5555
```

Leave it running. It is a transparent byte pipe; it understands nothing about
AES and changes nothing on the board.

> Firewall: if Kali cannot connect, allow Python through the Windows firewall
> for Private networks, or run once (Admin PowerShell):
> `New-NetFirewallRule -DisplayName "AES relay" -Direction Inbound -LocalPort 5555 -Protocol TCP -Action Allow`

---

## 3. Attack from Kali

One-time setup on Kali:

```
sudo apt update && sudo apt install -y python3-numpy python3-matplotlib
# (pyserial not needed on Kali — it talks to the relay over TCP)
```

Copy this repo (or just `fpga/attack/` and `model/aes_golden.py`) to Kali,
then — with `<WIN_IP>` = the Windows laptop's address (currently
**10.45.175.11**):

```
# Does the chip leak?  (fixed-vs-random t-test, no key needed)
python3 fpga/attack/attack.py --server 10.45.175.11:5555 tvla -n 2000

# Recover the key from the UNPROTECTED core
python3 fpga/attack/attack.py --server 10.45.175.11:5555 cpa  -n 5000

# The money shot: attack unprotected (breaks) then protected (survives)
python3 fpga/attack/attack.py --server 10.45.175.11:5555 demo -n 5000
```

Plots and raw traces land in `fpga/attack/out/` (`cpa_*.png`, `tvla_*.png`,
`*.npz`). Re-analyse saved traces later with no board:

```
python3 fpga/attack/attack.py cpa --load fpga/attack/out/cpa_unprot.npz
```

Pick the core with `--core 1|2|3` (1 = iterative, the capture unit's core).

---

## How many traces?

Rough guide for an on-chip sensor (noisier than a lab scope):

| Goal | Unprotected | Protected |
|---|---|---|
| TVLA shows leakage | 1k–5k | 20k+ (should stay under 4.5) |
| CPA recovers the key | 5k–50k | 100k+ / fails |

At ~2.7 ms per trace over 1 Mbaud, 50k traces ≈ 2–3 minutes.

---

## Files

| File | Runs on | What |
|---|---|---|
| `sca.py` | both | leakage model, CPA, TVLA, trace simulator |
| `selftest.py` | both | proves CPA/TVLA with no board |
| `collect.py` | both | capture traces over serial or TCP |
| `attack.py` | Kali | orchestrates collect + analysis + plots |
| `../host/relay.py` | Windows | COM ↔ TCP bridge |

RTL: `../rtl/tdc_sensor.v` (sensor), `../rtl/sca_unit.v` (capture + defence),
`../rtl/noise_gen.v`, `../rtl/rng_lfsr.v`; command `0x50` in
`../rtl/aes_uart_bridge.v`.

---

## Troubleshooting

* **`bad reply 0x.. to capture`** — the board still has the old bitstream;
  rebuild and reprogram (step 1).
* **All trace samples equal / flat** — the sensor is railing. Change `NBLK` in
  `tdc_sensor.v` (fewer blocks if stuck at 255, more if stuck at 0) and
  rebuild. A quick check: `cpa -n 200` and look at `out/cpa_*.png`.
* **Kali can't connect** — ping the Windows IP; check the firewall rule above;
  make sure `relay.py` prints "client connected".
* **CPA doesn't recover the key on real traces** — collect more; confirm the
  key in `attack.py` (`DEMO_KEY`) matches the key used for capture.
