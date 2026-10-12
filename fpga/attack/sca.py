#!/usr/bin/env python3
"""
sca.py -- the maths of the side-channel demo, with no board and no network.

This is the "brain" shared by every tool in fpga/attack/:

  * the AES first-round leakage model (what an attacker predicts),
  * CPA  -- recover the 16 key bytes from a set of power traces,
  * TVLA -- the ISO 17825 fixed-vs-random t-test that says, pass/fail,
            "does this chip leak?",
  * a leakage *simulator* that fakes traces from a known key, so the two
    analyses above can be proven correct before a single real trace exists.

Everything works on a trace set shaped (n_traces, n_samples) of small
integers -- exactly what the on-chip TDC sensor streams back over the link.

Run  python fpga/attack/selftest.py  to see CPA pull a known key out of
simulated traces and TVLA light up, all in software.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "model"))
from aes_golden import SBOX  # noqa: E402  (the same S-box the cores use)

SBOX = np.array(SBOX, dtype=np.uint8)
# Hamming weight of every byte value, precomputed.
HW = np.array([bin(x).count("1") for x in range(256)], dtype=np.uint8)


# ---------------------------------------------------------------- leakage model
def sbox_out(pt_byte, key_guess):
    """First-round SubBytes output: v = S[p xor k]. Vectorised over either arg."""
    return SBOX[np.bitwise_xor(pt_byte, key_guess)]


def hw_model(plaintext_bytes, key_guess):
    """Predicted leakage HW(S[p xor k]) for one key byte, over many plaintexts.

    plaintext_bytes : (n_traces,) uint8 -- one byte column of the plaintexts
    key_guess       : int 0..255
    returns         : (n_traces,) float
    """
    return HW[SBOX[plaintext_bytes ^ key_guess]].astype(np.float64)


# ---------------------------------------------------------------- CPA
def cpa_byte(traces, pt_col, return_curve=False):
    """Correlation Power Analysis for ONE key byte.

    traces : (n_traces, n_samples) real
    pt_col : (n_traces,) uint8 -- the plaintext byte at this position
    Returns the best key guess 0..255. The correct guess is the one whose
    predicted Hamming weight correlates most strongly (in absolute value)
    with the measured power at some sample point.

    With return_curve, also returns (best_corr, corr_per_key) where
    corr_per_key[k] is the peak |correlation| over all samples for guess k.
    """
    traces = np.asarray(traces, dtype=np.float64)
    n, m = traces.shape
    # mean-centre the traces once (Pearson numerator/denominator reuse)
    t = traces - traces.mean(axis=0)
    t_ss = np.sqrt((t * t).sum(axis=0))         # (n_samples,)
    t_ss[t_ss == 0] = 1e-12

    peak = np.zeros(256)
    best_k, best_r, best_s = 0, -1.0, 0
    for k in range(256):
        h = hw_model(pt_col, k)
        h = h - h.mean()
        h_ss = np.sqrt((h * h).sum())
        if h_ss == 0:
            continue
        # correlation of this model with every sample point at once
        r = (h @ t) / (h_ss * t_ss)             # (n_samples,)
        ar = np.abs(r)
        s = int(ar.argmax())
        peak[k] = ar[s]
        if ar[s] > best_r:
            best_r, best_k, best_s = ar[s], k, s
    if return_curve:
        return best_k, best_r, best_s, peak
    return best_k


def cpa_key(traces, plaintexts, known_key=None, verbose=False):
    """Recover all 16 key bytes. plaintexts : (n_traces, 16) uint8.

    Returns (recovered_key bytes, n_correct) -- n_correct is only meaningful
    when known_key is given (the self-test and the unprotected demo know it;
    a real attack would not).
    """
    traces = np.asarray(traces, dtype=np.float64)
    plaintexts = np.asarray(plaintexts, dtype=np.uint8)
    rec = bytearray(16)
    confid = []
    for b in range(16):
        k, r, s, _ = cpa_byte(traces, plaintexts[:, b], return_curve=True)
        rec[b] = k
        confid.append(r)
        if verbose:
            mark = ""
            if known_key is not None:
                mark = "  OK" if k == known_key[b] else f"  (want {known_key[b]:02x})"
            print(f"  byte {b:2d}: key=0x{k:02x}  peak |rho|={r:.3f} @ sample {s}{mark}")
    n_correct = (sum(1 for i in range(16) if rec[i] == known_key[i])
                 if known_key is not None else -1)
    return bytes(rec), n_correct, confid


# ---------------------------------------------------------------- TVLA
def tvla_ttest(traces_fixed, traces_random):
    """Welch's two-sample t-test per sample point (non-specific fixed-vs-random).

    Returns t : (n_samples,). The ISO 17825 rule of thumb: if max|t| > 4.5 the
    device is declared to leak. This needs no key and no leakage model -- it
    only asks whether 'encrypting a fixed input' looks different, in power,
    from 'encrypting random inputs'.
    """
    a = np.asarray(traces_fixed, dtype=np.float64)
    b = np.asarray(traces_random, dtype=np.float64)
    ma, mb = a.mean(axis=0), b.mean(axis=0)
    va, vb = a.var(axis=0, ddof=1), b.var(axis=0, ddof=1)
    na, nb = len(a), len(b)
    denom = np.sqrt(va / na + vb / nb)
    denom[denom == 0] = 1e-12
    return (ma - mb) / denom


# ---------------------------------------------------------------- simulator
def simulate_traces(key, plaintexts, n_samples=64, leak_coef=8.0, noise=3.0,
                    protected=False, seed=0):
    """Fake what the TDC sensor would stream, from a KNOWN key.

    Each of the 16 first-round S-box outputs leaks its Hamming weight at a
    distinct sample point (bytes spaced across the window). Everything else is
    Gaussian noise plus a DC level, like a real mean-centred sensor trace.

    protected=True mimics a first-order countermeasure: the leaked value is
    split with a fresh random mask each trace (v -> v^mask and mask), so the
    *first-order* correlation on v vanishes into the noise. CPA then fails and
    TVLA (non-specific) drops below the 4.5 threshold -- the before/after we
    show on the board.
    """
    rng = np.random.default_rng(seed)
    key = np.frombuffer(bytes(key), dtype=np.uint8)
    pt = np.asarray(plaintexts, dtype=np.uint8)
    n = len(pt)
    tr = rng.normal(128.0, noise, size=(n, n_samples))
    # put byte b's leak at an evenly spaced, non-overlapping sample point
    for b in range(16):
        s = 4 + (b * (n_samples - 8)) // 16
        v = SBOX[pt[:, b] ^ key[b]].astype(np.int64)
        if protected:
            mask = rng.integers(0, 256, size=n, dtype=np.int64)
            # sensor sees the two shares' weights, not the secret value's
            lk = HW[(v ^ mask).astype(np.uint8)] + HW[mask.astype(np.uint8)]
            lk = lk.astype(np.float64) - 8.0        # ~zero-mean, data-independent
        else:
            lk = HW[v].astype(np.float64) - 4.0
        tr[:, s] += leak_coef * lk
    return tr
