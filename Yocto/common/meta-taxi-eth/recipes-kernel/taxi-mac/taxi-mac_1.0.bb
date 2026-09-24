# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

SUMMARY = "Linux network driver for the Opsero Taxi RGMII MAC (Ethernet FMC)"
DESCRIPTION = "Out-of-tree kernel module (taxi_mac.ko) for the taxi_rgmii_mac \
PL block of the ethernet-fmc-taxi-eth reference design: one netdev per port, \
data path through the paired Xilinx AXI DMA (dmaengine, tx = MM2S, rx = S2MM), \
PHY via the MAC's own MDIO master. Binds to compatible \
\"opsero,taxi-rgmii-mac-1.0\" (see the bsp port-config overlay)."
HOMEPAGE = "https://github.com/fpgadeveloper/ethernet-fmc-taxi-eth"
SECTION = "kernel/modules"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${TAXI_ETH_REPO_DIR}/LICENSE;md5=2a1bef1c3867b8fbfdf01d52ba095e79"

inherit module

# Sources are taken straight from the repo's Linux/taxi-mac directory (the
# single source of truth; TAXI_ETH_LINUX_DIR is set by this layer's layer.conf).
FILESEXTRAPATHS:prepend := "${TAXI_ETH_LINUX_DIR}/taxi-mac:"
SRC_URI = " \
    file://taxi_mac.c;subdir=src \
    file://Makefile;subdir=src \
"

S = "${WORKDIR}/src"

# The driver Makefile is a KDIR-style out-of-tree build (make -C $(KDIR)
# M=$(pwd) modules) that takes KDIR from KERNEL_SRC when set - which
# module.bbclass passes (KERNEL_SRC=${STAGING_KERNEL_DIR}). KDIR is passed
# explicitly too so the build is pinned to the staged kernel either way.
EXTRA_OEMAKE += "KDIR=${STAGING_KERNEL_DIR}"

# The kernel-module-split class packages the module as kernel-module-taxi-mac
# and this meta package pulls it in; load it at boot.
KERNEL_MODULE_AUTOLOAD += "taxi_mac"

RPROVIDES:${PN} += "kernel-module-taxi-mac"
