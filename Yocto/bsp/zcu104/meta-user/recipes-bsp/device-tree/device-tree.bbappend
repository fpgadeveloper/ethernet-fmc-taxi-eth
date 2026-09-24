# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

# Board-level (SoC-side) device-tree fixups, layered on top of the
# gen-machineconf / lopper-generated CONFIG_DTFILE (...-cortexaN-linux.dts). The
# design-specific PL hardware (taxi_rgmii_mac_N + axi_dma_N) already comes from
# the SDT's pl.dtsi; these two files carry only what the XSA / sdtgen output
# doesn't encode:
#   system-user.dtsi  UART numbering and the sdhci1 (SD card) quirks
#   board-user.dtsi   PS GEM3 (board RJ45): TI DP83867 PHY node + fixed MAC
# The Ethernet FMC PHY wiring for the Taxi ports is supplied separately by the
# bsp/port-configs/<ports-*> overlay layer.
#
# meta-xilinx's device-tree.bb consumes EXTRA_DT_INCLUDE_FILES by copying each
# file into the DT build dir and appending `#include "<file>"` to the base DTS.
# Scope it to the Linux (APU) domain ONLY: the FSBL/PMU domain DTS files don't
# define the SoC peripheral labels these overrides reference, so dtc would fail
# with "Label or path ... not found". Match on os.path.basename(CONFIG_DTFILE)
# containing "linux" -- NOT the full path, which can itself contain "linux".
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

EXTRA_DT_INCLUDE_FILES:append = "${@' system-user.dtsi board-user.dtsi' if 'linux' in os.path.basename(d.getVar('CONFIG_DTFILE') or '') else ''}"
