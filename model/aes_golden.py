#!/usr/bin/env python3
"""
aes_golden.py -- independent AES-128 reference model + test-vector generator.

Nothing here is imported from the RTL. The S-box is *derived* from its
algebraic definition (multiplicative inverse in GF(2^8) followed by the affine
transform), not typed in as a table, so it is a genuine cross-check of
rtl/aes_sbox.v rather than a copy of it.

Usage:
    python aes_golden.py --check-sbox ../rtl/aes_sbox.v
    python aes_golden.py --gen-vectors ../tb/vectors/aes128_vectors.txt -n 1000
"""

import argparse
import random
import re
import sys

# ---------------------------------------------------------------------------
# GF(2^8) arithmetic, modulus x^8 + x^4 + x^3 + x + 1 (0x11B)
# ---------------------------------------------------------------------------


def gf_mul(a, b):
    p = 0
    for _ in range(8):
        if b & 1:
            p ^= a
        hi = a & 0x80
        a = (a << 1) & 0xFF
        if hi:
            a ^= 0x1B
        b >>= 1
    return p


def gf_inv(a):
    """Multiplicative inverse in GF(2^8); 0 maps to 0 by definition."""
    if a == 0:
        return 0
    for x in range(1, 256):
        if gf_mul(a, x) == 1:
            return x
    raise AssertionError("no inverse")


def build_sbox():
    """FIPS-197 Sec 5.1.1: affine(inverse(a))."""
    sbox = []
    for a in range(256):
        inv = gf_inv(a)
        s = 0x63
        for i in range(8):
            bit = (
                ((inv >> i) & 1)
                ^ ((inv >> ((i + 4) % 8)) & 1)
                ^ ((inv >> ((i + 5) % 8)) & 1)
                ^ ((inv >> ((i + 6) % 8)) & 1)
                ^ ((inv >> ((i + 7) % 8)) & 1)
            )
            s ^= bit << i
        # the 0x63 constant is folded in above via s starting at 0x63 and XOR
        sbox.append(s)
    return sbox


SBOX = build_sbox()
RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36]

# ---------------------------------------------------------------------------
# AES-128 encryption, state as a list of 16 bytes in column-major order
# (matches the RTL: byte index i = state[(15-i)*8 +: 8], s(r,c) = byte[r + 4c])
# ---------------------------------------------------------------------------


def key_expansion(key):
    """Return 11 round keys, each a list of 16 bytes."""
    w = [list(key[4 * i:4 * i + 4]) for i in range(4)]
    for i in range(4, 44):
        t = list(w[i - 1])
        if i % 4 == 0:
            t = t[1:] + t[:1]                       # RotWord
            t = [SBOX[b] for b in t]                # SubWord
            t[0] ^= RCON[i // 4 - 1]
        w.append([w[i - 4][j] ^ t[j] for j in range(4)])
    return [sum(w[4 * r:4 * r + 4], []) for r in range(11)]


def add_round_key(s, rk):
    return [s[i] ^ rk[i] for i in range(16)]


def sub_bytes(s):
    return [SBOX[b] for b in s]


def shift_rows(s):
    # out[r + 4c] = in[r + 4*((c + r) % 4)]
    return [s[r + 4 * ((c + r) % 4)] for c in range(4) for r in range(4)]


def mix_columns(s):
    out = []
    for c in range(4):
        a = s[4 * c:4 * c + 4]
        out += [
            gf_mul(a[0], 2) ^ gf_mul(a[1], 3) ^ a[2] ^ a[3],
            a[0] ^ gf_mul(a[1], 2) ^ gf_mul(a[2], 3) ^ a[3],
            a[0] ^ a[1] ^ gf_mul(a[2], 2) ^ gf_mul(a[3], 3),
            gf_mul(a[0], 3) ^ a[1] ^ a[2] ^ gf_mul(a[3], 2),
        ]
    return out


def aes128_encrypt(key, plaintext):
    """key, plaintext: 16-byte sequences. Returns 16 bytes."""
    rk = key_expansion(key)
    s = add_round_key(list(plaintext), rk[0])
    for rnd in range(1, 10):
        s = add_round_key(mix_columns(shift_rows(sub_bytes(s))), rk[rnd])
    s = add_round_key(shift_rows(sub_bytes(s)), rk[10])
    return s


def enc_hex(key_hex, pt_hex):
    key = bytes.fromhex(key_hex)
    pt = bytes.fromhex(pt_hex)
    return bytes(aes128_encrypt(key, pt)).hex()


# ---------------------------------------------------------------------------
# Known-answer tests
# ---------------------------------------------------------------------------

KAT = [
    # (name, key, plaintext, expected ciphertext)
    ("FIPS-197 App. B",
     "2b7e151628aed2a6abf7158809cf4f3c",
     "3243f6a8885a308d313198a2e0370734",
     "3925841d02dc09fbdc118597196a0b32"),
    ("FIPS-197 App. C.1",
     "000102030405060708090a0b0c0d0e0f",
     "00112233445566778899aabbccddeeff",
     "69c4e0d86a7b0430d8cdb78070b4c55a"),
    ("SP 800-38A ECB #1",
     "2b7e151628aed2a6abf7158809cf4f3c",
     "6bc1bee22e409f96e93d7e117393172a",
     "3ad77bb40d7a3660a89ecaf32466ef97"),
    ("SP 800-38A ECB #2",
     "2b7e151628aed2a6abf7158809cf4f3c",
     "ae2d8a571e03ac9c9eb76fac45af8e51",
     "f5d3d58503b9699de785895a96fdbaaf"),
    ("SP 800-38A ECB #3",
     "2b7e151628aed2a6abf7158809cf4f3c",
     "30c81c46a35ce411e5fbc1191a0a52ef",
     "43b1cd7f598ece23881b00e3ed030688"),
    ("SP 800-38A ECB #4",
     "2b7e151628aed2a6abf7158809cf4f3c",
     "f69f2445df4f9b17ad2b417be66c3710",
     "7b0c785e27e8ad3f8223207104725dd4"),
    ("AESAVS all-zero",
     "00000000000000000000000000000000",
     "00000000000000000000000000000000",
     "66e94bd4ef8a2c3b884cfa59ca342b2e"),
    ("AESAVS all-ones key",
     "ffffffffffffffffffffffffffffffff",
     "00000000000000000000000000000000",
     "a1f6258c877d5fcd8964484538bfc92c"),
]


def run_kat():
    ok = True
    for name, k, p, c in KAT:
        got = enc_hex(k, p)
        status = "PASS" if got == c else "FAIL"
        if got != c:
            ok = False
        print(f"  [{status}] {name:<20} -> {got}")
    return ok


# ---------------------------------------------------------------------------
# S-box cross-check against the Verilog source
# ---------------------------------------------------------------------------


def check_sbox_rtl(path):
    """Parse the 16 128-bit rows out of rtl/aes_sbox.v and diff against SBOX."""
    with open(path) as f:
        src = f.read()
    rows = re.findall(r"128'h([0-9a-fA-F]{32})", src)
    if len(rows) != 16:
        print(f"  [FAIL] expected 16 table rows in {path}, found {len(rows)}")
        return False
    rtl = []
    for row in rows:
        rtl += [int(row[i:i + 2], 16) for i in range(0, 32, 2)]

    bad = [(i, rtl[i], SBOX[i]) for i in range(256) if rtl[i] != SBOX[i]]
    if bad:
        for i, got, exp in bad[:16]:
            print(f"  [FAIL] SBOX[0x{i:02x}]: rtl=0x{got:02x} expected=0x{exp:02x}")
        print(f"  [FAIL] {len(bad)} S-box entries differ")
        return False
    print("  [PASS] all 256 S-box entries match the algebraic definition")
    return True


# ---------------------------------------------------------------------------
# Vector file generation
# ---------------------------------------------------------------------------


def gen_vectors(path, n_random, seed):
    rng = random.Random(seed)
    lines = []
    for name, k, p, c in KAT:
        assert enc_hex(k, p) == c, f"model disagrees with published KAT: {name}"
        lines.append((k, p, c, name))

    # edge cases the KATs do not cover
    edge = [
        ("00000000000000000000000000000000", "ffffffffffffffffffffffffffffffff"),
        ("ffffffffffffffffffffffffffffffff", "ffffffffffffffffffffffffffffffff"),
        ("80000000000000000000000000000000", "00000000000000000000000000000000"),
        ("00000000000000000000000000000001", "00000000000000000000000000000000"),
        ("0f0e0d0c0b0a09080706050403020100", "0f0e0d0c0b0a09080706050403020100"),
    ]
    for k, p in edge:
        lines.append((k, p, enc_hex(k, p), "edge"))

    for i in range(n_random):
        k = "%032x" % rng.getrandbits(128)
        p = "%032x" % rng.getrandbits(128)
        lines.append((k, p, enc_hex(k, p), f"random_{i}"))

    with open(path, "w") as f:
        f.write("// AES-128 ECB test vectors: KEY PLAINTEXT CIPHERTEXT\n")
        f.write("// Generated by model/aes_golden.py -- do not edit by hand.\n")
        f.write(f"// {len(lines)} vectors, random seed {seed}\n")
        for k, p, c, name in lines:
            f.write(f"{k} {p} {c}  // {name}\n")
    print(f"  wrote {len(lines)} vectors to {path}")
    return len(lines)


# ---------------------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser(description="AES-128 golden model")
    ap.add_argument("--check-sbox", metavar="VERILOG",
                    help="cross-check the S-box table in the given .v file")
    ap.add_argument("--gen-vectors", metavar="OUT",
                    help="write a test-vector file")
    ap.add_argument("-n", "--num-random", type=int, default=1000,
                    help="number of random vectors (default 1000)")
    ap.add_argument("--seed", type=int, default=20260816)
    ap.add_argument("--encrypt", nargs=2, metavar=("KEY", "PT"),
                    help="encrypt one block and print the ciphertext")
    args = ap.parse_args()

    ok = True

    if args.encrypt:
        print(enc_hex(args.encrypt[0], args.encrypt[1]))
        return 0

    print("Golden model known-answer tests:")
    ok &= run_kat()

    if args.check_sbox:
        print(f"\nS-box cross-check ({args.check_sbox}):")
        ok &= check_sbox_rtl(args.check_sbox)

    if args.gen_vectors:
        print("\nVector generation:")
        gen_vectors(args.gen_vectors, args.num_random, args.seed)

    print("\nRESULT: " + ("OK" if ok else "FAILURES PRESENT"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
