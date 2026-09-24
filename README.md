# Taxi Ethernet Reference Designs for Ethernet FMC

## Description

This project demonstrates the use of the Opsero [Ethernet FMC] (OP031) and [Robust Ethernet FMC] (OP041)
with a fully **open-source Ethernet MAC**. Each of the four gigabit ports of the mezzanine card is driven
by a 1G RGMII MAC from the [Taxi] transport library (FPGA Ninja) paired with an AMD AXI DMA — there is no
AXI Ethernet Subsystem in the design, so **no separately-licensed AMD IP is needed** to build it, and the
source of the MAC is in the repository for you to read, simulate and modify.

There are two block designs, one per device family, sharing the same per-port Ethernet logic:

* `Vivado/src/bd/bd_zynqmp.tcl` for **Zynq UltraScale+** boards (ZCU104): the processing system's
  `M_AXI_HPM0_FPD` carries the AXI-Lite control path, `S_AXI_HP0_FPD` gives the DMAs access to DDR,
  `pl_ps_irq0` collects the interrupts and TTC0 on EMIO is the lwIP tick timer.
* `Vivado/src/bd/bd_mb-us.tcl` for **MicroBlaze on UltraScale** boards (KCU105): a DDR4 memory
  controller (MIG), a MicroBlaze soft processor at 100 MHz with 64 KB instruction and data caches,
  an AXI interrupt controller, an AXI timer for the lwIP tick and an AXI UART16550 console
  (9600 baud). The DMAs reach DDR4 through an AXI SmartConnect.

Common to both:

* **Per port (x4)**: `taxi_rgmii_mac_N`, a block-design *module reference* that bundles the Taxi 1G
  RGMII MAC (`taxi_eth_mac_1g_rgmii_fifo`), a Taxi MDIO master for the port's PHY and a small
  AXI-Lite register file (control, status, counters, MDIO — see the header of
  `Vivado/src/hdl/taxi_rgmii_mac.v`). Frames move between the MAC and system memory through an
  `axi_dma_N` (scatter-gather, 32-bit AXI-Stream, MM2S = transmit, S2MM = receive).
* **Clocking**: a clocking wizard takes the 125 MHz reference from the Ethernet FMC and produces
  the 125 MHz RGMII transmit clock and a 90-degree copy for the RGMII TX clock output. A 300 MHz
  reference clock feeds the IDELAYCTRL that calibrates the receive-side input delays (a third
  output of the same MMCM on the ZCU104; a second, cascaded MMCM on the KCU105, whose DDR4
  user clock is not exactly 300 MHz).
* **PHYs**: the Marvell 88E1510 on each port runs in `rgmii-rxid` mode — the PHY adds the receive
  clock delay, the FPGA adds the transmit clock delay.

The MicroBlaze targets are standalone-only: the design has no boot device, so the bitstream and
the echo server ELF are loaded over JTAG (see the docs), and there is no Linux flow for them.

<!-- TODO: block diagram for the Taxi design (docs/source/images/) -->

Important links:

* Datasheets of the [Ethernet FMC] and [Robust Ethernet FMC]
* The user guide for these reference designs is hosted here: [Ethernet FMC Taxi Ethernet docs](https://taxieth.ethernetfmc.com "Ethernet FMC Taxi Ethernet docs")
* The open-source MAC: [Taxi transport library](https://github.com/fpganinja/taxi "Taxi transport library")
* To report a bug: [Report an issue](https://github.com/fpgadeveloper/ethernet-fmc-taxi-eth/issues "Report an issue").
* For technical support: [Contact Opsero](https://opsero.com/contact-us "Contact Opsero").
* To purchase the mezzanine card: [Ethernet FMC order page](https://opsero.com/product/ethernet-fmc "Ethernet FMC order page").

## Requirements

This project is designed for version 2025.2 of the AMD tools (Vivado/Vitis). 
If you are using an older version of the tools, then refer to the 
[release tags](https://github.com/fpgadeveloper/ethernet-fmc-taxi-eth/tags "releases")
to find the version of this repository that matches your version of the tools.

In order to test this design on hardware, you will need the following:

* Vivado 2025.2
* Vitis 2025.2
* A native Linux machine (Ubuntu 22.04 / 24.04) to build the Yocto / EDF Linux image
* [Ethernet FMC] or [Robust Ethernet FMC] (the ZCU104 and KCU105 take the 1.8V versions)
* One of the target platforms listed below

No IP license is required: the MAC is the open-source Taxi core and the rest of the design uses IP
that ships with Vivado.

## Target designs

This repo contains designs that target the supported development boards and their
FMC connectors. The table below lists the target design name, the number of ports supported by the design,
the FMC connector on which to connect the mezzanine card and the software flows built for it.

<!-- updater start -->
### FPGA designs

| Target board          | Target design      | Ports       | FMC Slot(s) | Standalone<br> Echo Server | Yocto | Vivado<br> Edition |
|-----------------------|--------------------|-------------|-------------|-------|-------|-------|
| [KCU105]              | `kcu105`           | 4x          | HPC         | :white_check_mark: | :x:   | Enterprise |

### Zynq UltraScale+ designs

| Target board          | Target design      | Ports       | FMC Slot(s) | Standalone<br> Echo Server | Yocto | Vivado<br> Edition |
|-----------------------|--------------------|-------------|-------------|-------|-------|-------|
| [ZCU104]              | `zcu104`           | 4x          | LPC         | :white_check_mark: | :white_check_mark: | Standard :free: |

[KCU105]: https://www.xilinx.com/kcu105
[ZCU104]: https://www.xilinx.com/zcu104
<!-- updater end -->

Notes:

1. The Vivado Edition column indicates which designs are supported by the Vivado *Standard* Edition, the
   FREE edition which can be used without a license. Vivado *Enterprise* Edition requires
   a license however a 30-day evaluation license is available from the AMD Xilinx Licensing site.

## Software

These reference designs can be driven by a **standalone** (bare-metal) application or from
within an embedded **Linux** environment. The repository includes all the scripts and code
needed to build either one.

| Environment | Build flow   | Available applications |
|-------------|--------------|------------------------|
| Standalone  | Vitis        | lwIP echo server on all four ports (custom lwIP network interface for the Taxi MAC + AXI DMA) |
| Linux       | Yocto / EDF  | `taxi_mac` network driver (one interface per port), `taxi-eth-test` self-test<br>Additional tools: ethtool, iproute2, iperf3, i2c-tools, phytool, pktgen |

The standalone application runs the lwIP echo server on the target with all four Ethernet FMC ports
active at once, each with its own IP address. Under Linux (AMD's Yocto / Embedded Development
Framework, the successor to PetaLinux), the ports come up as ordinary network interfaces through the
out-of-tree `taxi_mac` driver (`Linux/taxi-mac`), which drives the Taxi MAC registers and the paired
AXI DMA through the kernel's dmaengine API. The image also ships `taxi-eth-test`, a self-test that
finds the ports, reports link state and counters, and obtains a DHCP lease and pings the gateway on
every port with a cable.

## Licensing

Everything that Opsero wrote in this repository — the MAC wrapper, block design, constraints, software
and build scripts — is released under the **MIT license** (see `LICENSE`). The Taxi transport library
is brought in as a git submodule (`submodules/taxi`) and is licensed under the **CERN-OHL-S-2.0**
(strongly reciprocal) or, alternatively, a commercial license from FPGA Ninja. CERN-OHL-S has
consequences for products that ship a bitstream built from this design: read
[`submodules/README.md`](submodules/README.md) before you build one.

## Build instructions

Clone the repo **with its submodules** and change into its directory:
```
git clone --recursive https://github.com/fpgadeveloper/ethernet-fmc-taxi-eth.git
cd ethernet-fmc-taxi-eth
```
If you already have a clone without the submodule, run `git submodule update --init` — the
Vivado build cannot find the Taxi sources without it.

### Cross-platform build runner

All builds are driven by `build.py` at the repo root, on both Windows
(git bash) and Linux. The `build.sh` / `build.bat` shim finds a suitable
Python 3 automatically (including the one bundled with the AMD tools).
Pick a target design label from the tables above (or run `./build.sh
list`), then run the build command for the stage(s) you want — each
command builds whatever it depends on automatically and skips anything
already built. On Windows without git bash, run the same commands from
Command Prompt or PowerShell using `build.bat` (e.g. `build.bat xsa
--target <target>`).

You don't need to source the AMD tools first — the build runner finds
Vivado and Vitis automatically in their standard install
locations and sets up the environment each stage needs. If your tools
are installed somewhere non-standard and the runner can't find them,
source the tool settings yourself before running the build.

This repository uses git submodules. Clone it with `--recursive`, or run
`git submodule update --init` in an existing clone, before building —
the Vivado build fails without the submodule sources.

#### Build the Vivado project (bitstream + XSA)

```
./build.sh xsa --target <target>
```

#### Build the standalone application

Builds the Vitis workspace and the baremetal boot files: `BOOT.BIN` for
the Zynq UltraScale+ targets, or the bitstream plus the echo server ELF
(loaded over JTAG) for the MicroBlaze targets:

```
./build.sh standalone --target <target>
```

#### Build Yocto (Linux only)

```
./build.sh yocto --target <target>
```

#### Build everything

Builds all of the above that the target supports, then gathers the boot
images into `bootimages/*.zip`:

```
./build.sh all --target <target>
./build.sh all --target all          # every target in the repo
```

Also available: `status`, `clean`, `project` — see
`./build.sh --help`. On Windows, the Yocto stage requires a Linux machine;
the runner says so and prints the hand-off command.

## Contribute

We strongly encourage community contribution to these projects. Please make a pull request if you
would like to share your work:
* if you've spotted and fixed any issues
* if you've added designs for other target platforms

Thank you to everyone who supports us!

## About us

This project was developed by [Opsero Inc.](https://opsero.com "Opsero Inc."),
a tight-knit team of FPGA experts delivering FPGA products and design services to start-ups and tech companies. 
Follow our blog, [FPGA Developer](https://www.fpgadeveloper.com "FPGA Developer"), for news, tutorials and
updates on the awesome projects we work on.

[Ethernet FMC]: https://docs.opsero.com/op031/datasheet/overview/
[Robust Ethernet FMC]: https://docs.opsero.com/op041/datasheet/overview/
[Taxi]: https://github.com/fpganinja/taxi
