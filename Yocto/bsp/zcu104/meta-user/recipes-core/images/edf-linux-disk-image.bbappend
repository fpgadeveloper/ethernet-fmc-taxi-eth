# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

# Ethernet FMC Taxi Ethernet reference-design rootfs packages (design test /
# utility tools layered on the amd-edf base):
#   taxi-mac        the out-of-tree Linux network driver for the Taxi RGMII MAC
#                   ports (Yocto/common/meta-taxi-eth, built from Linux/taxi-mac)
#   taxi-eth-test   the port self-test script (/usr/bin/taxi-eth-test)
#   ethtool/iperf3/i2c-tools/phytool  bench-standard link / PHY diagnostics
IMAGE_INSTALL:append = " \
    ethtool \
    iperf3 \
    i2c-tools \
    phytool \
    taxi-mac \
    taxi-eth-test \
"
