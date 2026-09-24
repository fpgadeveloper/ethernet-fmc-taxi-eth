#!/usr/bin/env python3
"""
Generate the block diagram for the Opsero Ethernet FMC Taxi Ethernet reference design docs.

The design drives all four gigabit ports of the Ethernet FMC (OP031) / Robust
Ethernet FMC (OP041) with an open-source 1G RGMII MAC from the Taxi transport
library: per port a `taxi_rgmii_mac_N` block-design module reference (the Taxi
MAC `taxi_eth_mac_1g_rgmii_fifo` + a Taxi MDIO master + an AXI-Lite register
file) paired with an AMD AXI DMA that moves frames to and from system memory.
Two block designs share the same per-port logic: Zynq UltraScale+ (ZCU104,
PS HPM0 for control and HP0 for the DMAs) and MicroBlaze + DDR4 MIG (KCU105).
The 125 MHz reference clock comes from the clock generator on the FMC card and
an MMCM derives gtx_clk, gtx_clk90 and the 300 MHz IDELAYCTRL reference.

The output PNG is written next to this script (i.e. into docs/source/images/):
    taxi-eth-block-diagram.png

Usage (from anywhere):
    python3 docs/source/images/gen_block_diagram.py
"""

import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon, FancyBboxPatch, FancyArrowPatch

# ---- palette (shared with the other Opsero reference-design block diagrams) --
C_PS_FILL      = "#D9D9D9"; C_PS_EDGE      = "#7F7F7F"   # processor / DDR column
C_FAB_FILL     = "#F2F2F2"; C_FAB_EDGE     = "#BFBFBF"   # FPGA fabric container
C_DMA_FILL     = "#808080"; C_DMA_EDGE     = "#404040"   # AXI DMA (dark grey)
C_MAC_FILL     = "#E8E8F2"; C_MAC_EDGE     = "#8C8CC0"   # Taxi RGMII MAC (lavender)
C_GT_FILL      = "#F3EFE2"; C_GT_EDGE      = "#BFB585"   # RGMII I/O (cream)
C_FMC_FILL     = "#DCE6F2"; C_FMC_EDGE     = "#9DB7D4"   # external FMC (blue-grey)
C_CAGE_FILL    = "#FFFFFF"                                # PHY + RJ45 (white on FMC)
C_CLK_FILL     = "#FDE9D9"; C_CLK_EDGE     = "#E0B090"   # clock generator (peach)
C_CTRL_FILL    = "#ECECEC"; C_CTRL_EDGE    = "#BFBFBF"   # control-plane caption
C_AXARR_FILL   = "#EDF3D4"; C_AXARR_EDGE   = "#A6B85A"   # data arrows (pale green)
C_LINKARR_FILL = "#DAE8F5"; C_LINKARR_EDGE = "#6F9FCF"   # link arrows (pale blue)
C_REFCLK_LINE  = "#C8823C"                                # refclk arrows (orange)
TXT = "#1A1A1A"


def box(ax, x, y, w, h, fc, ec, label, fs=10, rot=0, lw=1.2, weight="normal",
        round_=False, txtcolor=None):
    if round_:
        p = FancyBboxPatch((x + 0.4, y + 0.4), w - 0.8, h - 0.8,
                           boxstyle="round,pad=0.0,rounding_size=1.2",
                           fc=fc, ec=ec, lw=lw, zorder=2)
    else:
        p = plt.Rectangle((x, y), w, h, fc=fc, ec=ec, lw=lw, zorder=2)
    ax.add_patch(p)
    ax.text(x + w / 2, y + h / 2, label, ha="center", va="center",
            fontsize=fs, rotation=rot, color=txtcolor or TXT, weight=weight,
            zorder=3, linespacing=1.25)


def titled_box(ax, x, y, w, h, fc, ec, title, body, title_fs=9.5, body_fs=7.6,
               lw=1.2, txtcolor=None, title_dy=2.6):
    """A box() with a bold title line at the top and a smaller body below it."""
    box(ax, x, y, w, h, fc, ec, "", lw=lw)
    cx = x + w / 2
    ax.text(cx, y + h - title_dy, title, ha="center", va="center",
            fontsize=title_fs, weight="bold", color=txtcolor or TXT, zorder=3)
    ax.text(cx, y + (h - title_dy * 1.9) / 2, body, ha="center", va="center",
            fontsize=body_fs, color=txtcolor or TXT, zorder=3, linespacing=1.3)


def harrow(ax, x0, x1, yc, label, fc, ec, double=True, bh=2.0, hh=3.4, hl=3.2,
           fs=8.5, lw=1.1, lab_dy=0.0):
    """Horizontal block arrow from x0 to x1.

    double=True  : double-headed (requires x0 < x1).
    double=False : single-headed with the head at x1; works in either
                   direction (x1 may be < x0 for a leftward arrow).
    """
    if double:
        pts = [(x0, yc), (x0 + hl, yc + hh), (x0 + hl, yc + bh),
               (x1 - hl, yc + bh), (x1 - hl, yc + hh), (x1, yc),
               (x1 - hl, yc - hh), (x1 - hl, yc - bh),
               (x0 + hl, yc - bh), (x0 + hl, yc - hh)]
    else:
        s = 1.0 if x1 >= x0 else -1.0   # direction from tail (x0) to head (x1)
        neck = x1 - s * hl              # base of the arrowhead
        pts = [(x0, yc + bh), (neck, yc + bh), (neck, yc + hh),
               (x1, yc), (neck, yc - hh), (neck, yc - bh), (x0, yc - bh)]
    ax.add_patch(Polygon(pts, closed=True, fc=fc, ec=ec, lw=lw, zorder=2))
    if label:
        ax.text((x0 + x1) / 2, yc + lab_dy, label, ha="center", va="center",
                fontsize=fs, color=TXT, zorder=3, linespacing=1.15)


def refclk_arrow(ax, p0, p1, label, lab_xy, fs=7.8, lw=1.9):
    """Thin single-line arrow (head at p1) for a single clock net, at any angle.

    A reference clock is one net (not a wide bus), so a thin arrow distinguishes
    it from the fat AXI/AXIS/RGMII bus arrows.
    """
    ax.add_patch(FancyArrowPatch(p0, p1, arrowstyle="-|>", mutation_scale=13,
                                 lw=lw, color=C_REFCLK_LINE, zorder=3,
                                 shrinkA=0, shrinkB=0))
    ax.text(lab_xy[0], lab_xy[1], label, ha="center", va="center",
            fontsize=fs, color=C_REFCLK_LINE, zorder=4, weight="bold")


def main():
    fig, ax = plt.subplots(figsize=(15.0, 10.4), dpi=120)
    ax.set_xlim(0, 150)
    ax.set_ylim(0, 106)
    ax.axis("off")

    # ---- containers ----------------------------------------------------------
    # Processor + memory column (one column for both device families)
    ps_x0, ps_w = 3, 18
    box(ax, ps_x0, 10, ps_w, 84, C_PS_FILL, C_PS_EDGE, "", lw=1.3)
    ax.text(ps_x0 + ps_w / 2, 88.0, "Processor\n+ DDR", ha="center", va="center",
            fontsize=11.5, weight="bold", color=TXT, linespacing=1.25)
    ax.text(ps_x0 + ps_w / 2, 52.0,
            "Zynq UltraScale+ PS\n(ZCU104)\n\n"
            "HPM0  AXI-Lite control\n"
            "HP0  DMA access to DDR\n"
            "pl_ps_irq0  interrupts\n\n"
            "— or —\n\n"
            "MicroBlaze\n+ DDR4 MIG\n(KCU105)\n\n"
            "AXI SmartConnect\nto DDR4  |  AXI INTC",
            ha="center", va="center", fontsize=7.5, color=TXT, linespacing=1.45)

    # FPGA fabric container
    fab_x0, fab_x1 = 23, 120
    ax.add_patch(plt.Rectangle((fab_x0, 8), fab_x1 - fab_x0, 92,
                               fc=C_FAB_FILL, ec=C_FAB_EDGE, lw=1.3, zorder=1))
    ax.text((fab_x0 + fab_x1) / 2, 100.6, "FPGA Fabric (PL)", ha="center",
            va="bottom", fontsize=13, weight="bold", color=TXT)

    # External FMC block (the four PHY/RJ45 ports and the 125 MHz clock gen)
    fmc_x0, fmc_x1 = 126, 147
    ax.add_patch(plt.Rectangle((fmc_x0, 8), fmc_x1 - fmc_x0, 92,
                               fc=C_FMC_FILL, ec=C_FMC_EDGE, lw=1.3, zorder=1))
    ax.text((fmc_x0 + fmc_x1) / 2, 100.6, "External to FPGA", ha="center",
            va="bottom", fontsize=12, weight="bold", color=TXT)
    ax.text((fmc_x0 + fmc_x1) / 2, 96.6,
            "Ethernet FMC\n(OP031 / OP041)",
            ha="center", va="center", fontsize=9.8, weight="bold", color=TXT,
            linespacing=1.3)

    # ---- column x-coordinates (shared by all four port rows) -----------------
    dma_x, dma_w = 29, 13
    mac_x, mac_w = 52, 25
    io_x,  io_w  = 86, 17
    box_h = 15

    # (port label, box bottom y) - port 0 on top
    rows = [("0", 80), ("1", 63), ("2", 46), ("3", 29)]
    io_right = io_x + io_w

    # ---- FMC sub-blocks: a PHY + RJ45 per port -------------------------------
    sub_x, sub_w = 128.5, 16
    for plabel, by in rows:
        yc = by + box_h / 2
        titled_box(ax, sub_x, yc - 5.5, sub_w, 11, C_CAGE_FILL, C_FMC_EDGE,
                   "Port %s" % plabel,
                   "Marvell 88E1510\nPHY  +  RJ45",
                   title_fs=8.6, body_fs=7.4, title_dy=2.9)

    # The PHYs add the receive clock delay themselves (rgmii-rxid)
    ax.text(sub_x + sub_w / 2, 26.9,
            "PHYs run rgmii-rxid:\nthe PHY adds the RX delay,\nthe FPGA adds the TX delay",
            ha="center", va="center", fontsize=6.3, color="#555555",
            zorder=3, linespacing=1.35)

    # 125 MHz clock generator on the FMC card
    titled_box(ax, sub_x, 12, sub_w, 11, C_CLK_FILL, C_CLK_EDGE,
               "125 MHz",
               "clock generator\n(OE / FSEL driven\nfrom the PL)",
               title_fs=8.6, body_fs=7.0, title_dy=2.9)

    # ---- per-port datapath rows ----------------------------------------------
    for plabel, by in rows:
        yc = by + box_h / 2
        # memory <-> AXI DMA : 3 AXI masters (scatter-gather, MM2S, S2MM)
        harrow(ax, ps_x0 + ps_w, dma_x, yc, "3x AXI\nSG / MM2S\n/ S2MM",
               C_AXARR_FILL, C_AXARR_EDGE, fs=7.2, lab_dy=0.2)
        # AXI DMA
        titled_box(ax, dma_x, by, dma_w, box_h, C_DMA_FILL, C_DMA_EDGE,
                   "AXI DMA",
                   "scatter-\ngather\n\nMM2S = TX\nS2MM = RX",
                   title_fs=10.0, body_fs=7.4, txtcolor="#FFFFFF", title_dy=3.0)
        # AXI DMA <-> Taxi MAC (32-bit AXI4-Stream, frames without FCS)
        harrow(ax, dma_x + dma_w, mac_x, yc, "AXIS\n32-bit",
               C_AXARR_FILL, C_AXARR_EDGE, fs=7.8, lab_dy=0.2)
        # Taxi RGMII MAC module reference
        titled_box(ax, mac_x, by, mac_w, box_h, C_MAC_FILL, C_MAC_EDGE,
                   "taxi_rgmii_mac_%s" % plabel,
                   "Taxi 1G RGMII MAC\n(taxi_eth_mac_1g_rgmii_fifo)\n"
                   "+ 8 kB TX / RX frame FIFOs\n"
                   "+ Taxi MDIO master\n"
                   "+ AXI-Lite register file",
                   title_fs=9.2, body_fs=7.4, title_dy=2.8)
        # MAC <-> RGMII I/O : TX (->, to the pins) and RX (<-, from the pins)
        harrow(ax, mac_x + mac_w, io_x, yc + 4.2, "TX", C_AXARR_FILL,
               C_AXARR_EDGE, double=False, bh=1.4, hh=2.5, hl=2.6, fs=8.0,
               lab_dy=2.5)
        harrow(ax, io_x, mac_x + mac_w, yc - 4.2, "RX", C_AXARR_FILL,
               C_AXARR_EDGE, double=False, bh=1.4, hh=2.5, hl=2.6, fs=8.0,
               lab_dy=-2.5)
        # RGMII I/O primitives
        titled_box(ax, io_x, by, io_w, box_h, C_GT_FILL, C_GT_EDGE,
                   "RGMII I/O",
                   "IDDR / ODDR\n+ IDELAYE3\nRX delays\n\n4-bit DDR\n@ 125 MHz",
                   title_fs=9.2, body_fs=7.4, title_dy=2.8)
        # RGMII I/O -> PHY : the RGMII link through the FMC connector
        harrow(ax, io_right, sub_x, yc, "RGMII\nport %s" % plabel,
               C_LINKARR_FILL, C_LINKARR_EDGE, bh=2.4, hh=3.9, hl=3.7,
               fs=8.4, lab_dy=0.2)

    # ---- clocking ------------------------------------------------------------
    clk_x, clk_w = 84, 34
    titled_box(ax, clk_x, 11.5, clk_w, 12, C_CLK_FILL, C_CLK_EDGE,
               "Clocking (MMCM)",
               "gtx_clk  125 MHz\n"
               "gtx_clk90  125 MHz, 90° (RGMII TX clock)\n"
               "300 MHz  IDELAYCTRL reference",
               title_fs=9.0, body_fs=7.4, title_dy=2.8)

    # 125 MHz reference: the FMC clock generator -> the MMCM in the fabric
    refclk_arrow(ax, (sub_x, 17.5), (clk_x + clk_w, 17.5), "125 MHz",
                 (123.2, 20.4), fs=7.4)

    # ---- control-plane caption strip -----------------------------------------
    box(ax, 26, 11.5, 54, 12, C_CTRL_FILL, C_CTRL_EDGE,
        "AXI-Lite control (MAC registers + DMA)\n"
        "interrupts: 2 per port (MM2S + S2MM)\n"
        "MDIO / MDC to each PHY  |  PHY reset", fs=8.6)

    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "taxi-eth-block-diagram.png")
    fig.savefig(out, bbox_inches="tight", pad_inches=0.15, facecolor="white")
    print("wrote", out)


if __name__ == "__main__":
    main()
