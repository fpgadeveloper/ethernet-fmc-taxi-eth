# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

# Per-target Ethernet port-config overlay. Supplies, for each Taxi RGMII MAC
# port, everything the taxi_mac Linux driver needs that the XSA / SDT does not
# describe: the driver's compatible string, the AXI DMA channels (tx = MM2S,
# rx = S2MM), the MAC address, phy-handle, MDIO bus and RGMII phy-mode (the
# PHYs live off-chip on the Ethernet FMC). configure-build.sh adds this layer
# per target, selected by the target's "portcfg" in config/data.json
# (ports-0123 = all four ports), so a board BSP can be shared across targets
# that differ only in active ports.
#
# Injected via EXTRA_DT_INCLUDE_FILES (meta-xilinx device-tree.bb appends a
# `#include "port-config.dtsi"` to the base DTS). Scoped to the Linux (APU)
# domain DTS, same as the board system-user.dtsi.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

EXTRA_DT_INCLUDE_FILES:append = "${@' port-config.dtsi' if 'linux' in os.path.basename(d.getVar('CONFIG_DTFILE') or '') else ''}"
