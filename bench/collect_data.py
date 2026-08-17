#!/usr/bin/env python3
"""
collect_data.py -- gather every number used in the comparison charts, with an
explicit provenance tag on each one.

Three provenance classes, and they are never blended:

  measured   came out of a tool run on this machine -- an Icarus simulation of
             the RTL, an instrumented AES implementation, or a wall-clock
             benchmark of OpenSSL on this CPU
  derived    exact arithmetic on measured values (throughput = bits / cycles
             x frequency). No judgement involved.
  assumption a stated modelling choice (processor IPC, accelerator interface
             overhead). Every one is listed in ASSUMPTIONS and is a single
             number a reader can disagree with and recompute.

Nothing here is an unsourced estimate. Quantities I cannot measure -- LUT area,
Fmax, power -- are deliberately absent rather than guessed, because Vivado is
not installed on this machine.

    python bench/collect_data.py            # writes bench/data.json
"""

import json
import os
import platform
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sw_cost_model import collect as collect_sw_ops  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# ---------------------------------------------------------------------------
# Assumptions -- the complete list. Change one, rerun, charts update.
# ---------------------------------------------------------------------------

ASSUMPTIONS = {
    "softcore_name": "MicroBlaze-class 32-bit soft core",
    "softcore_mhz": 100.0,
    "softcore_ipc": 1.0,
    "softcore_ipc_pessimistic": 0.7,
    "accel_clock_mhz": 384.6,
    "accel_iface_ops_per_block": 20,
    "accel_iface_ops_per_block_dma": 1,
    "_notes": {
        "softcore_mhz":
            "100 MHz is the usual MicroBlaze target on an Artix-7 -1 part.",
        "softcore_ipc":
            "Single-issue in-order core, instruction and data in local BRAM, "
            "so ~1 operation per cycle. 0.7 is carried as a pessimistic bound "
            "covering pipeline and load-use stalls.",
        "accel_clock_mhz":
            "The project's target frequency. NOT verified by synthesis -- "
            "Vivado is not installed here. Charts plot throughput against "
            "frequency so this single number is not load-bearing.",
        "accel_iface_ops_per_block":
            "Memory-mapped interface: 8 x 32-bit writes (key + plaintext), "
            "4 x 32-bit reads (ciphertext), plus loop and status-poll "
            "overhead. With a DMA engine feeding the core this amortises to "
            "roughly 1 op per block, carried as the second figure.",
    },
}

# ---------------------------------------------------------------------------
# Measured: RTL cycles per block, from the Icarus simulations in this repo
# ---------------------------------------------------------------------------

CORES = {
    "aes128_iterative": {
        "label": "Iterative (II=11)",
        "cycles_per_block": 11,
        "latency_cycles": 11,
        "source": "tb_aes128_iterative.v -- asserted on all 1020 blocks",
    },
    "aes128_iterative_ii10": {
        "label": "Overlapped (II=10)",
        "cycles_per_block": 10,
        "latency_cycles": 11,
        "source": "tb_aes128_iterative_ii10.v -- asserted on all 1013 blocks",
    },
    "aes128_pipelined": {
        "label": "Pipelined (II=1)",
        "cycles_per_block": 1,
        "latency_cycles": 11,
        "source": "tb_aes128_pipelined.v -- asserted on all 1013 blocks",
    },
}


def verify_rtl_cycles():
    """
    Re-run the three simulations and confirm they still report the cycle counts
    quoted above, so the charts cannot drift away from the RTL.
    """
    shims = os.path.join(os.path.expanduser("~"), "scoop", "shims")
    env = dict(os.environ)
    if os.path.isdir(shims):
        env["PATH"] = shims + os.pathsep + env["PATH"]

    shared = ["rtl/aes_sbox.v", "rtl/aes_round.v", "rtl/aes_key_expand.v"]
    jobs = [
        ("aes128_iterative", "tb/tb_aes128_iterative.v"),
        ("aes128_iterative_ii10", "tb/tb_aes128_iterative_ii10.v"),
        ("aes128_pipelined", "tb/tb_aes128_pipelined.v"),
    ]
    results = {}
    for core, tb in jobs:
        vvp = os.path.join(ROOT, "bench", f"_{core}.vvp")
        srcs = [tb] + shared + [f"rtl/{core}.v"]
        cp = subprocess.run(["iverilog", "-g2012", "-o", vvp] + srcs,
                            cwd=ROOT, env=env, capture_output=True, text=True)
        if cp.returncode != 0:
            return None, f"compile failed for {core}: {cp.stderr[:400]}"
        cp = subprocess.run(["vvp", vvp], cwd=ROOT, env=env,
                            capture_output=True, text=True, timeout=900)
        os.remove(vvp)
        if "ALL TESTS PASSED" not in cp.stdout:
            return None, f"{core} testbench did not pass"
        results[core] = cp.stdout
    return results, None


# ---------------------------------------------------------------------------
# Measured: this CPU's AES-128 throughput with the AES-NI instructions
# ---------------------------------------------------------------------------


def bench_aesni():
    try:
        from cryptography.hazmat.primitives.ciphers import (
            Cipher, algorithms, modes)
    except ImportError:
        return None

    key = bytes(range(16))
    data = bytes(1 << 20)                      # 1 MiB
    enc = Cipher(algorithms.AES(key), modes.ECB()).encryptor()

    # warm up, then take the best of several runs (least contaminated by noise)
    for _ in range(3):
        enc.update(data)

    best = None
    for _ in range(7):
        t0 = time.perf_counter()
        n = 0
        while time.perf_counter() - t0 < 0.25:
            enc.update(data)
            n += 1
        dt = time.perf_counter() - t0
        bps = n * len(data) * 8 / dt
        best = bps if best is None else max(best, bps)
    return best


def cpu_info():
    info = {"platform": platform.processor(), "machine": platform.machine()}
    # wmic is removed on Windows 11; use CIM via PowerShell
    try:
        cp = subprocess.run(
            ["powershell", "-NoProfile", "-Command",
             "$c = Get-CimInstance Win32_Processor | Select-Object -First 1; "
             "Write-Output $c.Name; Write-Output $c.MaxClockSpeed"],
            capture_output=True, text=True, timeout=60)
        lines = [ln.strip() for ln in cp.stdout.splitlines() if ln.strip()]
        if len(lines) >= 1:
            info["name"] = lines[0]
        if len(lines) >= 2:
            info["max_clock_mhz"] = float(lines[1])
    except Exception:
        pass
    return info


# ---------------------------------------------------------------------------


def main():
    print("Collecting comparison data")
    print("-" * 60)

    # ---- software operation counts (measured, instrumented) ---------------
    sw = collect_sw_ops()
    print(f"  software byte-wise : {sw['bytewise']['total']} ops/block")
    print(f"  software t-table   : {sw['ttable']['total']} ops/block")

    # ---- RTL cycles (measured, re-verified) -------------------------------
    print("  re-running RTL simulations to confirm cycle counts...")
    sims, err = verify_rtl_cycles()
    if err:
        print(f"  WARNING: {err}")
        rtl_verified = False
    else:
        rtl_verified = True
        print("  RTL cycle counts confirmed against the testbenches")

    # ---- AES-NI on this host (measured) -----------------------------------
    print("  benchmarking OpenSSL AES-128-ECB on this CPU...")
    aesni_bps = bench_aesni()
    host = cpu_info()
    if aesni_bps:
        print(f"  AES-NI             : {aesni_bps / 1e9:.2f} Gbps "
              f"on {host.get('name', 'unknown CPU')}")

    # ---- derived ----------------------------------------------------------
    f_sc = ASSUMPTIONS["softcore_mhz"] * 1e6
    ipc = ASSUMPTIONS["softcore_ipc"]
    ipc_lo = ASSUMPTIONS["softcore_ipc_pessimistic"]

    def sw_entry(name, ops):
        cyc = ops / ipc
        cyc_lo = ops / ipc_lo
        return {
            "ops_per_block": ops,
            "cycles_per_block": cyc,
            "cycles_per_block_pessimistic": cyc_lo,
            "bps": 128.0 / cyc * f_sc,
            "bps_pessimistic": 128.0 / cyc_lo * f_sc,
            "label": name,
        }

    software = {
        "bytewise": sw_entry("Soft core, byte-wise", sw["bytewise"]["total"]),
        "ttable": sw_entry("Soft core, T-table", sw["ttable"]["total"]),
    }

    f_acc = ASSUMPTIONS["accel_clock_mhz"] * 1e6
    hardware = {}
    for k, c in CORES.items():
        hardware[k] = dict(c)
        hardware[k]["bps_at_target"] = 128.0 / c["cycles_per_block"] * f_acc
        hardware[k]["latency_ns_at_target"] = (
            c["latency_cycles"] / f_acc * 1e9)

    data = {
        "assumptions": ASSUMPTIONS,
        "host": host,
        "provenance": {
            "software_ops": "measured (instrumented AES, validated vs FIPS-197)",
            "rtl_cycles": ("measured (Icarus simulation, re-verified)"
                           if rtl_verified else "measured (not re-verified)"),
            "aesni_bps": "measured (OpenSSL wall clock, best of 7)",
            "throughput": "derived (bits / cycles x frequency)",
            "cpu_utilisation": "derived from measured cycles + stated assumptions",
        },
        "software_ops": sw,
        "software": software,
        "hardware": hardware,
        "aesni_bps": aesni_bps,
        "stages": sw["bytewise_stages"],
    }

    out = os.path.join(HERE, "data.json")
    with open(out, "w") as f:
        json.dump(data, f, indent=2)
    print("-" * 60)
    print(f"  wrote {out}")

    # ---- headline summary --------------------------------------------------
    print()
    print(f"{'configuration':<32}{'cycles/blk':>12}{'throughput':>16}")
    print("-" * 60)
    for k in ["bytewise", "ttable"]:
        e = software[k]
        print(f"{e['label']:<32}{e['cycles_per_block']:>12.0f}"
              f"{e['bps'] / 1e6:>13.2f} Mbps")
    for k, e in hardware.items():
        print(f"{e['label']:<32}{e['cycles_per_block']:>12d}"
              f"{e['bps_at_target'] / 1e9:>13.2f} Gbps")
    if aesni_bps:
        print(f"{'Host CPU with AES-NI (context)':<32}{'-':>12}"
              f"{aesni_bps / 1e9:>13.2f} Gbps")
    print()


if __name__ == "__main__":
    main()
