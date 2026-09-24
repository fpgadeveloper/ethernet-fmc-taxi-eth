# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
#
# Out-of-tree build of the taxi_mac network driver. Also the shape that the
# Yocto module.bbclass expects (KERNEL_SRC, O=, `modules`, `modules_install`).

obj-m += taxi_mac.o

ifneq ($(KERNEL_SRC),)
KDIR ?= $(KERNEL_SRC)
endif
KDIR ?= /lib/modules/$(shell uname -r)/build
SRC := $(shell pwd)

all: modules

modules:
	$(MAKE) -C $(KDIR) M=$(SRC) modules

modules_install:
	$(MAKE) -C $(KDIR) M=$(SRC) modules_install

clean:
	$(MAKE) -C $(KDIR) M=$(SRC) clean

.PHONY: all modules modules_install clean
