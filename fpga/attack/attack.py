#!/usr/bin/env python3
"""
attack.py -- run the side-channel demo end to end.

On Kali (or the Windows laptop), against the board via relay.py or a local COM
port. It collects traces from the on-chip sensor, then runs TVLA and CPA and
writes plots you can drop straight into the slides.

  # does the chip leak? (fixed-vs-random t-test; needs no key)
  python fpga/attack/attack.py --server 192.168.1.20:5555 tvla  -n 2000

  # recover the key from the UNPROTECTED core
  python fpga/attack/attack.py --server 192.168.1.20:5555 cpa   -n 5000

  # the money shot: attack unprotected (breaks) then protected (survives)
  python fpga/attack/attack.py --server 192.168.1.20:5555 demo  -n 5000

  # analyse traces captured earlier, no board needed
  python fpga/attack/attack.py cpa --load out/cpa_unprot.npz

Plots and .npz trace files land in fpga/attack/out/.
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sca        # noqa: E402
import collect    # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
os.makedirs(OUT, exist_ok=True)
THRESH = 4.5
# demo key the FPGA uses for the capture command (also set in the RTL default)
DEMO_KEY = bytes.fromhex("2b7e151628aed2a6abf7158809cf4f3c")


def _plt():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    return plt


def _rand_pt(n, seed):
    return np.random.default_rng(seed).integers(0, 256, size=(n, 16), dtype=np.uint8)


# ---------------------------------------------------------------- TVLA
def do_tvla(traces_fixed, traces_random, tag, title):
    t = sca.tvla_ttest(traces_fixed, traces_random)
    peak = float(np.abs(t).max())
    verdict = "LEAKS" if peak > THRESH else "no leakage detected"
    print(f"  TVLA {tag}: max|t| = {peak:.1f}  ->  {verdict}")
    plt = _plt()
    fig, ax = plt.subplots(figsize=(9, 3.2))
    ax.plot(t, lw=0.9, color="#1d4ed8")
    ax.axhline(THRESH, color="#dc2626", ls="--", lw=1)
    ax.axhline(-THRESH, color="#dc2626", ls="--", lw=1)
    ax.set_title(f"{title}   max|t|={peak:.1f}  ({verdict})")
    ax.set_xlabel("sample (clock cycle)")
    ax.set_ylabel("t")
    fig.tight_layout()
    p = os.path.join(OUT, f"tvla_{tag}.png")
    fig.savefig(p, dpi=130)
    plt.close(fig)
    print(f"  -> {p}")
    return peak


# ---------------------------------------------------------------- CPA
def do_cpa(traces, plaintexts, tag, title, known_key=None):
    rec, ncorr, confid = sca.cpa_key(traces, plaintexts, known_key=known_key,
                                     verbose=True)
    print(f"  recovered key: {rec.hex()}")
    if known_key is not None:
        print(f"  real key     : {known_key.hex()}   ({ncorr}/16 correct)")

    # how many bytes are recovered as traces accumulate -- the convincing plot
    steps = np.unique(np.linspace(200, len(traces), 12).astype(int))
    got = []
    if known_key is not None:
        for m in steps:
            r, nc, _ = sca.cpa_key(traces[:m], plaintexts[:m], known_key=known_key)
            got.append(nc)
    plt = _plt()
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(11, 3.4))
    a1.bar(range(16), confid, color=["#16a34a" if (known_key and rec[i] == known_key[i])
                                     else "#dc2626" for i in range(16)])
    a1.set_title(f"{title}: peak |correlation| per key byte")
    a1.set_xlabel("key byte"); a1.set_ylabel("|rho|"); a1.set_ylim(0, 1)
    if known_key is not None:
        a2.plot(steps, got, "-o", color="#1d4ed8")
        a2.axhline(16, color="#16a34a", ls="--", lw=1)
        a2.set_title("key bytes recovered vs. traces used")
        a2.set_xlabel("traces"); a2.set_ylabel("bytes correct (of 16)")
        a2.set_ylim(0, 16.5)
    fig.tight_layout()
    p = os.path.join(OUT, f"cpa_{tag}.png")
    fig.savefig(p, dpi=130)
    plt.close(fig)
    print(f"  -> {p}")
    return rec, ncorr


# ---------------------------------------------------------------- collection
def gather_cpa(dev, core, n, protected, seed):
    pt = _rand_pt(n, seed)
    print(f"  collecting {n} CPA traces (core {core}, "
          f"{'PROTECTED' if protected else 'unprotected'})...")
    tr = collect.capture_set(dev, core, pt, DEMO_KEY, protected=protected)
    return tr, pt


def gather_tvla(dev, core, n, protected, seed):
    fixed = np.tile(np.frombuffer(bytes.fromhex(
        "00112233445566778899aabbccddeeff"), np.uint8), (n, 1))
    rnd = _rand_pt(n, seed)
    # interleave fixed/random to cancel slow drift (standard TVLA practice)
    print(f"  collecting {n}+{n} TVLA traces "
          f"({'PROTECTED' if protected else 'unprotected'})...")
    tf = collect.capture_set(dev, core, fixed, DEMO_KEY, protected=protected)
    tr = collect.capture_set(dev, core, rnd, DEMO_KEY, protected=protected)
    return tf, tr


def main():
    ap = argparse.ArgumentParser(description="AES side-channel attack/leakage demo")
    ap.add_argument("mode", choices=["tvla", "cpa", "demo", "collect"])
    ap.add_argument("--server", help="relay host:port (Kali -> Windows)")
    ap.add_argument("--port", help="local COM port instead of --server")
    ap.add_argument("--core", type=int, default=1, choices=[1, 2, 3])
    ap.add_argument("-n", type=int, default=3000, help="traces (per class for tvla)")
    ap.add_argument("--protected", action="store_true")
    ap.add_argument("--load", help="analyse a saved .npz instead of capturing")
    ap.add_argument("--seed", type=int, default=1234)
    args = ap.parse_args()

    core_name = collect.CORE_NAMES.get(args.core, "?")

    if args.load:  # offline analysis path
        tr, pt, key = collect.load(args.load)
        if args.mode == "cpa":
            do_cpa(tr, pt, "loaded", f"core {core_name}", known_key=key)
        else:
            sys.exit("--load supports cpa only; capture tvla pairs live")
        return 0

    dev = collect.connect(port=args.port, server=args.server)

    # calibrate the on-chip sensor into range (software sweep, no rebuild)
    print("  calibrating on-chip sensor...")
    collect.auto_calibrate(dev, core=args.core, key=DEMO_KEY)

    if args.mode == "tvla":
        tf, tr = gather_tvla(dev, args.core, args.n, args.protected, args.seed)
        tag = f"{core_name}_{'prot' if args.protected else 'unprot'}"
        collect.save(os.path.join(OUT, f"tvla_{tag}.npz"),
                     np.vstack([tf, tr]),
                     np.zeros((len(tf) + len(tr), 16), np.uint8),
                     meta={"fixed": len(tf)})
        do_tvla(tf, tr, tag, f"TVLA  core {core_name} "
                             f"({'protected' if args.protected else 'unprotected'})")

    elif args.mode == "cpa":
        tr, pt = gather_cpa(dev, args.core, args.n, args.protected, args.seed)
        tag = f"{core_name}_{'prot' if args.protected else 'unprot'}"
        collect.save(os.path.join(OUT, f"cpa_{tag}.npz"), tr, pt, key=DEMO_KEY)
        do_cpa(tr, pt, tag, f"CPA core {core_name} "
                            f"({'protected' if args.protected else 'unprotected'})",
               known_key=DEMO_KEY)

    elif args.mode == "demo":
        print("\n### 1/2  UNPROTECTED core -- attack should SUCCEED")
        tr, pt = gather_cpa(dev, args.core, args.n, False, args.seed)
        collect.save(os.path.join(OUT, "cpa_unprot.npz"), tr, pt, key=DEMO_KEY)
        _, nc_u = do_cpa(tr, pt, "demo_unprot",
                         f"UNPROTECTED core {core_name}", known_key=DEMO_KEY)
        tf, trr = gather_tvla(dev, args.core, args.n // 2, False, args.seed + 1)
        mu = do_tvla(tf, trr, "demo_unprot", f"UNPROTECTED core {core_name}")

        print("\n### 2/2  PROTECTED core -- attack should FAIL")
        trp, ptp = gather_cpa(dev, args.core, args.n, True, args.seed + 2)
        collect.save(os.path.join(OUT, "cpa_prot.npz"), trp, ptp, key=DEMO_KEY)
        _, nc_p = do_cpa(trp, ptp, "demo_prot",
                         f"PROTECTED core {core_name}", known_key=DEMO_KEY)
        tfp, trrp = gather_tvla(dev, args.core, args.n // 2, True, args.seed + 3)
        mp = do_tvla(tfp, trrp, "demo_prot", f"PROTECTED core {core_name}")

        print("\n" + "=" * 60)
        print(f" UNPROTECTED : CPA {nc_u}/16 key bytes,  TVLA max|t|={mu:.1f}")
        print(f" PROTECTED   : CPA {nc_p}/16 key bytes,  TVLA max|t|={mp:.1f}")
        print("=" * 60)
    return 0


if __name__ == "__main__":
    sys.exit(main())
