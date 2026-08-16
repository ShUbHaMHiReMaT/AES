#!/usr/bin/env python3
"""
mutation_test.py -- proves the testbenches actually detect broken hardware.

A regression suite that passes tells you nothing until you have shown it can
fail. This injects a series of realistic single-point RTL bugs -- the kinds of
mistake people actually make writing an AES datapath -- and asserts that the
self-checking testbench rejects each one.

Every mutation must be caught. A mutation that still passes is reported as an
ESCAPE and fails this script.

    python sim/mutation_test.py
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RTL = os.path.join(ROOT, "rtl")
TB = os.path.join(ROOT, "tb")

# (name, file, description, old_text, new_text)
MUTATIONS = [
    ("sbox-entry",
     "aes_sbox.v",
     "single wrong S-box entry (0x63 -> 0x62 at addr 0)",
     "128'h637c777bf26b6fc53001672bfed7ab76",
     "128'h627c777bf26b6fc53001672bfed7ab76"),

    ("shiftrows-row3",
     "aes_round.v",
     "ShiftRows row 3 rotated by 1 instead of 3",
     "sub[ 24 +: 8], sub[112 +: 8], sub[ 72 +: 8], sub[ 32 +: 8]",
     "sub[ 24 +: 8], sub[112 +: 8], sub[ 72 +: 8], sub[ 96 +: 8]"),

    ("mixcolumns-coeff",
     "aes_round.v",
     "MixColumns first row uses {01} where it should use {02}",
     "xtime(a0)      ^ xtime(a1) ^ a1 ^ a2             ^ a3,",
     "a0             ^ xtime(a1) ^ a1 ^ a2             ^ a3,"),

    ("rcon-placement",
     "aes_key_expand.v",
     "Rcon XORed into the last byte of the word instead of the first",
     "wire [31:0] temp = sub ^ {rcon, 24'h000000};",
     "wire [31:0] temp = sub ^ {24'h000000, rcon};"),

    ("keyexp-chain",
     "aes_key_expand.v",
     "key schedule words not chained (nw2 uses w1 instead of nw1)",
     "wire [31:0] nw2 = nw1 ^ w2;",
     "wire [31:0] nw2 = w1  ^ w2;"),

    ("final-round-mix",
     "aes_round.v",
     "MixColumns not bypassed on the final round",
     "wire [127:0] pre_key = last_round ? shifted : mixed;",
     "wire [127:0] pre_key = mixed;"),
]

# (label, testbench file, dut source)
TARGETS = [
    ("iterative", "tb_aes128_iterative.v", "aes128_iterative.v"),
    ("ii10", "tb_aes128_iterative_ii10.v", "aes128_iterative_ii10.v"),
    ("pipelined", "tb_aes128_pipelined.v", "aes128_pipelined.v"),
]

SHARED = ["aes_sbox.v", "aes_round.v", "aes_key_expand.v"]


def run_sim(workdir, tb_file, dut_file):
    """Compile and run; return True if the testbench reported success."""
    out = os.path.join(workdir, "mut.vvp")
    srcs = [os.path.join(workdir, "tb", tb_file)]
    srcs += [os.path.join(workdir, "rtl", f) for f in SHARED + [dut_file]]

    cp = subprocess.run(["iverilog", "-g2012", "-o", out] + srcs,
                        capture_output=True, text=True, cwd=workdir)
    if cp.returncode != 0:
        return False, "compile failed:\n" + cp.stderr

    cp = subprocess.run(["vvp", out], capture_output=True, text=True,
                        cwd=workdir, timeout=900)
    passed = "ALL TESTS PASSED" in cp.stdout and cp.returncode == 0
    return passed, cp.stdout


def make_workdir(tmp):
    work = os.path.join(tmp, "work")
    os.makedirs(work)
    shutil.copytree(RTL, os.path.join(work, "rtl"))
    shutil.copytree(TB, os.path.join(work, "tb"))
    return work


def main():
    print("=" * 62)
    print(" Mutation testing -- can the testbenches detect broken RTL?")
    print("=" * 62)

    with tempfile.TemporaryDirectory() as tmp:
        # sanity: the unmutated design must pass, or nothing below means anything
        work = make_workdir(tmp)
        print("\nBaseline (no mutation):")
        for label, tb, dut in TARGETS:
            ok, log = run_sim(work, tb, dut)
            print(f"  {label:<12} {'PASS' if ok else 'FAIL'}")
            if not ok:
                print("  baseline must pass before mutations mean anything")
                print(log[-3000:])
                return 1

        escapes = []
        print("\nInjected faults (every one must be caught):")
        for mname, mfile, desc, old, new in MUTATIONS:
            work = make_workdir(tempfile.mkdtemp(dir=tmp))
            path = os.path.join(work, "rtl", mfile)
            with open(path) as f:
                src = f.read()
            if src.count(old) != 1:
                print(f"  [SETUP FAIL] {mname}: anchor text not unique in {mfile}")
                escapes.append(mname)
                continue
            with open(path, "w") as f:
                f.write(src.replace(old, new))

            print(f"\n  {mname}: {desc}")
            for label, tb, dut in TARGETS:
                ok, log = run_sim(work, tb, dut)
                if ok:
                    print(f"    {label:<12} ESCAPED -- testbench did not notice")
                    escapes.append(f"{mname}/{label}")
                else:
                    first = ""
                    for line in log.splitlines():
                        if line.strip().startswith("ERROR"):
                            first = line.strip()
                            break
                    print(f"    {label:<12} caught   {first[:64]}")

    print("\n" + "=" * 62)
    if escapes:
        print(f" RESULT: {len(escapes)} MUTATION(S) ESCAPED: {', '.join(escapes)}")
        print("=" * 62)
        return 1
    print(f" RESULT: all {len(MUTATIONS)} mutations caught by all "
          f"{len(TARGETS)} testbenches")
    print("=" * 62)
    return 0


if __name__ == "__main__":
    sys.exit(main())
