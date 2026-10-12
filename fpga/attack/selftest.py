#!/usr/bin/env python3
"""
selftest.py -- prove the attack maths works, with no board and no network.

Generates fake sensor traces from a known key (sca.simulate_traces), then:
  1. runs CPA and checks it recovers all 16 key bytes (UNPROTECTED);
  2. runs CPA on PROTECTED (masked) traces and checks it FAILS;
  3. runs TVLA on both and checks leakage is detected on unprotected
     and suppressed on protected.

If this passes, the analysis in sca.py is correct and the only open question
on real hardware is signal quality -- not the code. Run:

    python fpga/attack/selftest.py
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sca  # noqa: E402

THRESH = 4.5  # ISO 17825 TVLA leakage threshold


def random_plaintexts(n, seed):
    return np.random.default_rng(seed).integers(0, 256, size=(n, 16), dtype=np.uint8)


def run():
    key = bytes.fromhex("2b7e151628aed2a6abf7158809cf4f3c")  # FIPS-197 C.1-ish
    ok = True

    # ---- 1. CPA recovers the key from unprotected traces ----
    print("=" * 66)
    print(" 1. CPA on UNPROTECTED traces  (should recover the key)")
    print("=" * 66)
    pt = random_plaintexts(4000, seed=1)
    tr = sca.simulate_traces(key, pt, noise=4.0, protected=False, seed=2)
    rec, ncorr, _ = sca.cpa_key(tr, pt, known_key=key, verbose=True)
    print(f"\n  recovered : {rec.hex()}")
    print(f"  real key  : {key.hex()}")
    print(f"  {ncorr}/16 key bytes correct from {len(pt)} traces")
    ok &= (ncorr == 16)
    print("  => PASS\n" if ncorr == 16 else "  => FAIL\n")

    # ---- 2. CPA fails on protected (masked) traces ----
    print("=" * 66)
    print(" 2. CPA on PROTECTED traces  (should FAIL -- that's the point)")
    print("=" * 66)
    trp = sca.simulate_traces(key, pt, noise=4.0, protected=True, seed=3)
    recp, ncorrp, _ = sca.cpa_key(trp, pt, known_key=key)
    print(f"  {ncorrp}/16 key bytes correct from {len(pt)} traces "
          f"(random guessing ~0/16)")
    # masking should keep first-order CPA near chance (allow a couple of flukes)
    ok &= (ncorrp <= 3)
    print("  => PASS (masking defeats first-order CPA)\n" if ncorrp <= 3
          else "  => FAIL (masking did not help)\n")

    # ---- 3. TVLA: leakage on unprotected, none on protected ----
    print("=" * 66)
    print(" 3. TVLA fixed-vs-random t-test")
    print("=" * 66)
    fixed_pt = np.tile(np.frombuffer(bytes.fromhex(
        "00112233445566778899aabbccddeeff"), dtype=np.uint8), (3000, 1))
    rand_pt = random_plaintexts(3000, seed=4)

    t_u = sca.tvla_ttest(
        sca.simulate_traces(key, fixed_pt, noise=4.0, protected=False, seed=5),
        sca.simulate_traces(key, rand_pt, noise=4.0, protected=False, seed=6))
    t_p = sca.tvla_ttest(
        sca.simulate_traces(key, fixed_pt, noise=4.0, protected=True, seed=7),
        sca.simulate_traces(key, rand_pt, noise=4.0, protected=True, seed=8))
    mu, mp = np.abs(t_u).max(), np.abs(t_p).max()
    print(f"  unprotected : max|t| = {mu:6.1f}   {'LEAKS' if mu > THRESH else 'ok'} "
          f"(> {THRESH} means it leaks)")
    print(f"  protected   : max|t| = {mp:6.1f}   {'LEAKS' if mp > THRESH else 'ok'}")
    ok &= (mu > THRESH) and (mp < THRESH)
    print("  => PASS\n" if ok else "  => FAIL\n")

    print("=" * 66)
    print(" OVERALL:", "ALL CHECKS PASSED -- analysis is correct"
          if ok else "SOMETHING FAILED")
    print("=" * 66)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(run())
