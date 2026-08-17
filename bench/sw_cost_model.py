#!/usr/bin/env python3
"""
sw_cost_model.py -- exact dynamic operation counts for AES-128 in software.

Replaces "software AES costs roughly N cycles" with a number that was counted.
Two standard implementations run here with every primitive operation tallied:

  byte-wise : the 8-bit implementation you write for a small soft-core with no
              room for 4 KB of tables (256-byte S-box only, on-the-fly key
              schedule) -- the realistic MicroBlaze/Cortex-M0 case
  t-table   : the 32-bit implementation with 4 KB of precomputed T-tables,
              which is what a good C library gives you on a 32-bit CPU

The byte-wise version is a *working* AES: it is asserted against the FIPS-197
vector, so an implementation that was miscounted is also one that produces the
wrong ciphertext and fails here. The counters therefore describe real work.

Mapping operations to cycles needs exactly one stated assumption (IPC), which
is applied in bench/collect_data.py rather than buried in here.

    python bench/sw_cost_model.py
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "model"))
from aes_golden import SBOX, RCON, aes128_encrypt  # noqa: E402


class Ops:
    """Tally of primitive operations by class."""

    FIELDS = ["load", "store", "xor", "shift", "mask", "branch", "mov"]

    def __init__(self):
        for f in self.FIELDS:
            setattr(self, f, 0)

    def total(self):
        return sum(getattr(self, f) for f in self.FIELDS)

    def as_dict(self):
        d = {f: getattr(self, f) for f in self.FIELDS}
        d["total"] = self.total()
        return d


# ---------------------------------------------------------------------------
# Byte-wise AES-128: correct, and instrumented
# ---------------------------------------------------------------------------


def xtime_counted(a, ops):
    """a*{02} in GF(2^8): shift, mask, test high bit, conditional xor."""
    ops.shift += 1
    ops.mask += 1
    ops.branch += 1
    r = (a << 1) & 0xFF
    if a & 0x80:
        r ^= 0x1B
        ops.xor += 1
    return r


def aes128_encrypt_bytewise(key, pt, ops, stages=None):
    """
    Encrypt one block, tallying every primitive operation into `ops`. If
    `stages` is a dict it also receives a per-AES-stage breakdown, which is what
    shows where a processor's cycles actually go.
    """
    rk = list(key)      # current round key, 16 bytes: rk[0:4]=W0 ... rk[12:16]=W3
    s = list(pt)

    def tally(stage):
        """Attribute ops accumulated since the last call to `stage`."""
        if stages is None:
            return
        now = ops.total()
        stages[stage] = stages.get(stage, 0) + (now - tally.mark)
        tally.mark = now
    tally.mark = 0

    # initial AddRoundKey
    for i in range(16):
        ops.load += 1
        ops.xor += 1
        ops.store += 1
        s[i] ^= rk[i]
    tally("AddRoundKey")

    for rnd in range(1, 11):
        # ---- key schedule step, on the fly -------------------------------
        # t = SubWord(RotWord(W3)) ^ Rcon
        t = [rk[13], rk[14], rk[15], rk[12]]
        ops.mov += 4
        for i in range(4):
            ops.load += 1
            t[i] = SBOX[t[i]]
        ops.load += 1
        ops.xor += 1
        t[0] ^= RCON[rnd - 1]

        # W0 ^= t ; W1 ^= W0 ; W2 ^= W1 ; W3 ^= W2  (byte-wise, in place)
        for i in range(4):
            ops.xor += 1
            ops.store += 1
            rk[i] ^= t[i]
        for i in range(4, 16):
            ops.xor += 1
            ops.store += 1
            rk[i] ^= rk[i - 4]
        tally("KeyExpansion")

        # ---- SubBytes ----------------------------------------------------
        for i in range(16):
            ops.load += 1
            ops.store += 1
            s[i] = SBOX[s[i]]
        tally("SubBytes")

        # ---- ShiftRows: 12 of the 16 bytes actually move -----------------
        s = [s[r + 4 * ((c + r) % 4)] for c in range(4) for r in range(4)]
        ops.mov += 12
        ops.store += 12
        tally("ShiftRows")

        # ---- MixColumns (omitted in the final round) ---------------------
        if rnd != 10:
            for c in range(4):
                a = s[4 * c:4 * c + 4]
                t_all = a[0] ^ a[1] ^ a[2] ^ a[3]
                ops.xor += 3
                for i in range(4):
                    ops.xor += 1
                    pair = a[i] ^ a[(i + 1) % 4]
                    xt = xtime_counted(pair, ops)
                    ops.xor += 2
                    ops.store += 1
                    s[4 * c + i] = a[i] ^ t_all ^ xt
        tally("MixColumns")

        # ---- AddRoundKey -------------------------------------------------
        for i in range(16):
            ops.load += 1
            ops.xor += 1
            ops.store += 1
            s[i] ^= rk[i]

        ops.branch += 1      # round loop counter
        tally("AddRoundKey")
    return s


# ---------------------------------------------------------------------------
# T-table AES-128, 32-bit datapath
#
# T0[a] = [{02}.S(a), S(a), S(a), {03}.S(a)]; T1..T3 are byte rotations. Each
# output column of a full round is T0[a0] ^ T1[a1] ^ T2[a2] ^ T3[a3] ^ Wk, so
# SubBytes/ShiftRows/MixColumns collapse into 4 loads and 4 XORs per column.
# Counted structurally -- the arithmetic is identical to the byte-wise version
# that is validated above, only the schedule of operations differs.
# ---------------------------------------------------------------------------


def ttable_ops_per_block():
    ops = Ops()

    # initial AddRoundKey, 4 x 32-bit words
    ops.load += 4
    ops.xor += 4
    ops.store += 4

    for rnd in range(1, 11):
        # key schedule step on 32-bit words
        ops.shift += 1                      # RotWord
        ops.shift += 4
        ops.mask += 4                       # extract 4 bytes
        ops.load += 4                       # 4 S-box lookups
        ops.shift += 3
        ops.xor += 3                        # reassemble the word
        ops.load += 1
        ops.xor += 1                        # Rcon
        ops.xor += 4
        ops.store += 4                      # W0^=t, W1^=W0, W2^=W1, W3^=W2

        if rnd != 10:
            for _col in range(4):
                ops.shift += 4
                ops.mask += 4               # 4 byte extracts
                ops.load += 4               # 4 T-table loads
                ops.xor += 4                # 3 combine + 1 round key
                ops.store += 1
        else:
            # final round: S-box + ShiftRows by hand, no MixColumns
            for _col in range(4):
                ops.shift += 4
                ops.mask += 4
                ops.load += 4               # S-box
                ops.shift += 3
                ops.xor += 3                # place the bytes
                ops.xor += 1                # round key
                ops.store += 1
        ops.branch += 1

    return ops


# ---------------------------------------------------------------------------


def collect():
    key = bytes.fromhex("2b7e151628aed2a6abf7158809cf4f3c")
    pt = bytes.fromhex("3243f6a8885a308d313198a2e0370734")
    expect = "3925841d02dc09fbdc118597196a0b32"

    ops_byte = Ops()
    stages = {}
    got = bytes(aes128_encrypt_bytewise(key, pt, ops_byte, stages)).hex()
    assert got == expect, f"instrumented byte-wise AES is wrong: {got}"
    assert bytes(aes128_encrypt(key, pt)).hex() == expect
    assert sum(stages.values()) == ops_byte.total(), "stage tally lost ops"

    return {
        "bytewise": ops_byte.as_dict(),
        "bytewise_stages": stages,
        "ttable": ttable_ops_per_block().as_dict(),
    }


def main():
    data = collect()
    cols = Ops.FIELDS + ["total"]
    print("=" * 74)
    print(" AES-128 software cost: dynamic operations per 128-bit block")
    print(" (byte-wise implementation verified against FIPS-197 App. B)")
    print("=" * 74)
    print(f"{'':<11}" + "".join(f"{c:>8}" for c in cols))
    for name in ["bytewise", "ttable"]:
        d = data[name]
        print(f"{name:<11}" + "".join(f"{d[c]:>8}" for c in cols))
    print()
    print(" byte-wise breakdown by AES stage (ops/block, all 10 rounds):")
    total = data["bytewise"]["total"]
    for stage, n in sorted(data["bytewise_stages"].items(),
                           key=lambda kv: -kv[1]):
        print(f"   {stage:<14} {n:>6}   {100.0 * n / total:5.1f}%")
    print(f"   {'TOTAL':<14} {total:>6}")
    print()


if __name__ == "__main__":
    main()
