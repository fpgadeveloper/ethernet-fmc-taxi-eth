# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

SUMMARY = "Ethernet FMC Taxi MAC port self-test script"
DESCRIPTION = "Installs /usr/bin/taxi-eth-test: finds the Ethernet FMC ports \
bound to the taxi_mac driver, reports link state / speed and the driver's \
ethtool counters per port, and on every port with a link cable acquires a \
DHCP lease and pings the gateway. Bench fixture: port 0 cabled to the LAN \
router (DHCP), ports 1-3 may be left unconnected (--all-ports requires a \
link on all four)."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${TAXI_ETH_REPO_DIR}/LICENSE;md5=2a1bef1c3867b8fbfdf01d52ba095e79"

SRC_URI = "file://taxi-eth-test"

S = "${WORKDIR}"

do_install() {
	install -d ${D}${bindir}
	install -m 0755 ${WORKDIR}/taxi-eth-test ${D}${bindir}/taxi-eth-test
}

FILES:${PN} = "${bindir}/taxi-eth-test"

# iproute2/ethtool: needed by the test itself (busybox is disabled in the
# EDF image, so the full ip/ping tools must be present). iperf3: throughput
# checks from the bench. i2c-tools/phytool: bench debug standard - FMC EEPROM
# forensics and MDIO/PHY register access without a debugger.
# pktgen is a kernel module - enabled as CONFIG_NET_PKTGEN=m in the board's
# kernel bsp.cfg; RRECOMMENDS pulls the package in wherever it is built.
RDEPENDS:${PN} += "iproute2 iputils-ping iperf3 ethtool i2c-tools phytool"
RRECOMMENDS:${PN} += "kernel-module-pktgen"
