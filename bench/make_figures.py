#!/usr/bin/env python3
"""
make_figures.py -- report-ready versions of the two comparison graphs.

Reads bench/data.json (produced by collect_data.py) so the figures cannot drift
away from the measurements. Writes PNG at 200 dpi for pasting into a document
and SVG for anything that will be scaled.

    python bench/collect_data.py     # first, to produce data.json
    python bench/make_figures.py

Figure 1  "Normal"  -- where a processor's cycles go on one 128-bit block
Figure 2  "With AES accelerator" -- cycles per block across every configuration
"""

import json
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt          # noqa: E402
from matplotlib.ticker import FixedLocator, NullFormatter  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "figures")

# validated categorical palette (light surface) -- see dataviz/references/palette.md
C_BLUE = "#2a78d6"
C_ORANGE = "#eb6834"
C_AQUA = "#1baf7a"
C_YELLOW = "#eda100"
C_MAGENTA = "#e87ba4"

SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK_2 = "#52514e"
MUTED = "#898781"
GRID = "#e1e0d9"
AXIS = "#c3c2b7"

plt.rcParams.update({
    "font.family": "sans-serif",
    "font.sans-serif": ["Segoe UI", "DejaVu Sans", "Arial"],
    "figure.facecolor": SURFACE,
    "axes.facecolor": SURFACE,
    "savefig.facecolor": SURFACE,
    "text.color": INK,
    "axes.labelcolor": INK_2,
    "xtick.color": MUTED,
    "ytick.color": INK_2,
    "axes.edgecolor": AXIS,
})


def style_axes(ax, xgrid=True):
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.spines["bottom"].set_color(AXIS)
    ax.spines["bottom"].set_linewidth(0.8)
    if xgrid:
        ax.set_axisbelow(True)
        ax.xaxis.grid(True, color=GRID, linewidth=0.8, linestyle="-")
    ax.tick_params(length=0)


def fmt_bps(bps):
    if bps >= 1e9:
        return f"{bps / 1e9:.2f} Gbps"
    return f"{bps / 1e6:.2f} Mbps"


# ---------------------------------------------------------------------------
# Figure 1 -- Normal: the processor does the AES
# ---------------------------------------------------------------------------


def figure_normal(d):
    stages = d["stages"]
    order = ["MixColumns", "AddRoundKey", "KeyExpansion", "SubBytes", "ShiftRows"]
    colors = [C_BLUE, C_ORANGE, C_AQUA, C_YELLOW, C_MAGENTA]
    total = sum(stages.values())

    sw = d["software"]["bytewise"]
    mhz = d["assumptions"]["softcore_mhz"]

    fig, ax = plt.subplots(figsize=(11, 4.4))

    # Percentages go inside the segments (short enough to fit every one); the
    # stage name and op count go below on staggered rows with leader lines, so
    # nothing is ever clipped by a narrow segment.
    centers = []
    left = 0
    for stage, color in zip(order, colors):
        v = stages[stage]
        # a 2px surface gap between fills, not a border around the marks
        ax.barh(0, v, left=left, height=0.46, color=color,
                edgecolor=SURFACE, linewidth=2.0, zorder=3)
        # near-black, not white: white is only 2.2:1 on the yellow segment,
        # while #0b0b0b clears 4.7:1 on every slot colour
        ax.text(left + v / 2, 0, f"{100.0 * v / total:.0f}%",
                ha="center", va="center", fontsize=10.5, color="#0b0b0b",
                fontweight="600", zorder=4)
        centers.append(left + v / 2)
        left += v

    row_y = [-0.62, -1.12]
    for i, (stage, xc) in enumerate(zip(order, centers)):
        y = row_y[i % 2]
        ax.plot([xc, xc], [-0.26, y + 0.16], color=AXIS, linewidth=0.8,
                zorder=2)
        ax.text(xc, y, f"{stage}\n{stages[stage]:,} ops", ha="center",
                va="center", fontsize=9.5, color=INK_2, linespacing=1.5)

    ax.set_xlim(0, total * 1.015)      # room for the rightmost label
    ax.set_ylim(-1.75, 0.85)
    ax.set_yticks([])
    ax.set_xlabel("processor operations (≈ cycles at IPC 1.0) for ONE 128-bit block",
                  fontsize=9.5, labelpad=8)
    style_axes(ax)

    ax.set_title(
        "Without an accelerator: every AES block is 2,702 operations on the CPU",
        fontsize=13.5, fontweight="600", color=INK, loc="left", pad=44)
    ax.text(0, 1.06,
            f"{d['assumptions']['softcore_name']} @ {mhz:.0f} MHz, byte-wise AES-128. "
            f"Ceiling {fmt_bps(sw['bps'])} — and the core is 100% busy reaching it.",
            transform=ax.transAxes, fontsize=10, color=INK_2, va="bottom")

    ax.text(0.0, -0.40,
            "MixColumns alone is 44% of the work: in software each GF(2⁸) doubling "
            "costs a shift, a high-bit test and a conditional XOR, per byte, per round.\n"
            "In hardware it is a fixed tree of XOR gates that settles in one cycle — "
            "which is most of why the accelerator wins.",
            transform=ax.transAxes, fontsize=9, color=MUTED, ha="left",
            va="top", linespacing=1.6)

    fig.tight_layout()
    save(fig, "fig1_normal_cpu_only")


# ---------------------------------------------------------------------------
# Figure 2 -- With the AES accelerator
# ---------------------------------------------------------------------------


def figure_with_aes(d):
    hw = d["hardware"]
    sw = d["software"]
    iface = d["assumptions"]["accel_iface_ops_per_block"]

    # (label, cycles/block, throughput bps or None, kind, sublabel)
    rows = [
        ("Soft core, byte-wise AES",
         sw["bytewise"]["cycles_per_block"], sw["bytewise"]["bps"], "sw",
         "256-byte S-box, on-the-fly key schedule"),
        ("Soft core, T-table AES",
         sw["ttable"]["cycles_per_block"], sw["ttable"]["bps"], "sw",
         "4 KB of tables, 32-bit datapath"),
        ("CPU cost once offloaded",
         iface, None, "sw",
         "memory-mapped handshake per block; ~1 with DMA"),
        ("Accelerator — iterative",
         hw["aes128_iterative"]["cycles_per_block"],
         hw["aes128_iterative"]["bps_at_target"], "hw",
         "one round datapath, II=11"),
        ("Accelerator — overlapped",
         hw["aes128_iterative_ii10"]["cycles_per_block"],
         hw["aes128_iterative_ii10"]["bps_at_target"], "hw",
         "whitening overlaps round 10, II=10"),
        ("Accelerator — pipelined",
         hw["aes128_pipelined"]["cycles_per_block"],
         hw["aes128_pipelined"]["bps_at_target"], "hw",
         "10 rounds unrolled, II=1"),
    ]

    fig, ax = plt.subplots(figsize=(11, 5.0))

    ys = list(range(len(rows)))[::-1]
    for y, (label, cyc, bps, kind, sub) in zip(ys, rows):
        color = C_ORANGE if kind == "sw" else C_BLUE
        ax.plot([1, cyc], [y, y], color=color, linewidth=2.0,
                solid_capstyle="round", alpha=0.35, zorder=2)
        ax.plot([cyc], [y], "o", markersize=11, color=color,
                markeredgecolor=SURFACE, markeredgewidth=2.0, zorder=3)

        txt = f"{cyc:,.0f} cycles" if cyc >= 10 else f"{cyc:,.0f} cycle" \
            if cyc == 1 else f"{cyc:,.0f} cycles"
        if bps:
            txt += f"  ·  {fmt_bps(bps)}"
        else:
            txt += "  ·  accelerator does the crypto"
        ax.text(cyc * 1.35, y + 0.16, txt, va="center", fontsize=9.5,
                color=INK, fontweight="600")
        ax.text(cyc * 1.35, y - 0.22, sub, va="center", fontsize=8.5,
                color=MUTED)

    ax.set_yticks(ys)
    ax.set_yticklabels([r[0] for r in rows], fontsize=10)
    ax.set_xscale("log")
    ax.set_xlim(0.8, 60000)
    ax.set_ylim(-0.8, len(rows) - 0.2)
    ax.xaxis.set_major_locator(FixedLocator([1, 10, 100, 1000, 10000]))
    ax.set_xticklabels(["1", "10", "100", "1,000", "10,000"], fontsize=9)
    ax.xaxis.set_minor_formatter(NullFormatter())
    ax.set_xlabel("clock cycles per 128-bit block  (log scale)",
                  fontsize=9.5, labelpad=8)
    style_axes(ax)

    handles = [
        plt.Line2D([], [], marker="o", linestyle="none", markersize=9,
                   color=C_ORANGE, markeredgecolor=SURFACE, markeredgewidth=1.5,
                   label="runs on the processor"),
        plt.Line2D([], [], marker="o", linestyle="none", markersize=9,
                   color=C_BLUE, markeredgecolor=SURFACE, markeredgewidth=1.5,
                   label="runs in the FPGA accelerator"),
    ]
    ax.legend(handles=handles, loc="lower right", frameon=False, fontsize=9.5,
              handletextpad=0.6, borderaxespad=0.8)

    ax.set_title(
        "With the accelerator: 2,702 cycles of CPU work becomes 10 cycles of hardware",
        fontsize=13.5, fontweight="600", color=INK, loc="left", pad=38)
    ax.text(0, 1.035,
            f"Accelerator cycle counts measured in simulation; throughput at the "
            f"{d['assumptions']['accel_clock_mhz']:.1f} MHz project target. "
            f"Software at {d['assumptions']['softcore_mhz']:.0f} MHz, IPC 1.0.",
            transform=ax.transAxes, fontsize=10, color=INK_2, va="bottom")

    fig.tight_layout()
    save(fig, "fig2_with_aes_accelerator")


# ---------------------------------------------------------------------------


def save(fig, name):
    os.makedirs(OUT, exist_ok=True)
    for ext, kw in (("png", {"dpi": 200}), ("svg", {})):
        p = os.path.join(OUT, f"{name}.{ext}")
        fig.savefig(p, bbox_inches="tight", **kw)
        print(f"  wrote {p}")
    plt.close(fig)


def main():
    with open(os.path.join(HERE, "data.json")) as f:
        d = json.load(f)
    print("Rendering figures")
    figure_normal(d)
    figure_with_aes(d)


if __name__ == "__main__":
    main()
