# Advanced: project structure and customization

This section is intended for users who want to modify the reference
designs — changing the MAC, adding IP to the block design, changing constraints,
modifying the standalone application, or adding packages or drivers to the
Linux image. It describes how the repository is laid out, how the
build flow works, how the Vitis and Yocto sides are organised, and what has
been modified on top of the stock AMD configuration.

The actual *build* instructions are in [build_instructions](build_instructions);
this section is about understanding the project well enough to modify
it.

## Repository layout

```
.
├── build.py                   <- Cross-platform build runner (the build logic)
├── build.sh / build.bat       <- Shims that invoke build.py (Linux/git bash, Windows)
├── README.md
├── LICENSE                    <- MIT (Opsero's sources)
├── config/                    <- Source-of-truth design metadata and auto-generation
│   ├── data.json
│   └── update.py
├── docs/                      <- This documentation (Sphinx + Read the Docs)
├── submodules/
│   ├── README.md              <- What is used from Taxi and what its license means
│   └── taxi/                  <- The Taxi transport library (git submodule, CERN-OHL-S-2.0)
├── Linux/
│   └── taxi-mac/              <- Out-of-tree Linux network driver for the Taxi MAC (taxi_mac.ko)
├── Vivado/
│   ├── scripts/
│   │   ├── build.tcl          <- Project creation + block design assembly
│   │   ├── taxi_sources.tcl   <- The Taxi source files pulled into the project
│   │   └── xsa.tcl            <- Synthesis, implementation, XSA export
│   ├── sim/                   <- xsim testbench for the MAC block (run_xsim.sh)
│   └── src/
│       ├── bd/
│       │   ├── bd_zynqmp.tcl  <- Block design for Zynq UltraScale+ targets
│       │   └── bd_mb-us.tcl   <- Block design for MicroBlaze UltraScale targets (KCU105)
│       ├── constraints/
│       │   └── <target>.xdc   <- One XDC per target (pin assignments, timing)
│       └── hdl/
│           ├── taxi_rgmii_mac.v       <- Module-reference shell (interface attributes, register map)
│           └── taxi_rgmii_mac_core.sv <- Taxi MAC + MDIO master + AXI-Lite register file
├── Vitis/
│   ├── py/
│   │   ├── args.json          <- Repo-specific Vitis flow configuration
│   │   ├── build-vitis.py     <- Universal Vitis Python build driver
│   │   ├── make-boot.py       <- BOOT.BIN packaging
│   │   └── pre_platform_build.py
│   ├── common/
│   │   └── src/               <- Standalone application source (echo server + Taxi lwIP netif)
│   └── <target>_workspace/    <- Per-target Vitis workspace (generated)
└── Yocto/
    ├── scripts/               <- The universal EDF build scripts (see below)
    ├── common/
    │   └── meta-taxi-eth/     <- Layer shared by every board: taxi-mac and taxi-eth-test recipes
    ├── bsp/
    │   ├── <board>/           <- Board BSP: local.conf.append, meta-user layer, bblayers-extra.txt
    │   └── port-configs/
    │       └── ports-0123/    <- Port-config overlay layer (port-config.dtsi)
    └── <target>/              <- Per-target Yocto workspace (generated)
```

Per-target build outputs are written to `Vivado/<target>/`,
`Vitis/<target>_workspace/`, `Vitis/boot/<target>/` and `Yocto/<target>/`; packaged
boot-image zips are written to `bootimages/`. None of these are
committed.

## Target naming

A *target label* is the canonical handle for a single design and is passed
to every build command via `--target`. It encodes the board and, for
boards with multiple FMC connectors, the connector:

```
<board>[_<connector>]
```

The current targets are `zcu104` (Zynq UltraScale+, LPC connector) and
`kcu105` (Kintex UltraScale with a MicroBlaze soft processor, HPC
connector, baremetal only). The first underscore-delimited token is taken
as the *target board* and is what the build runner uses to select the BSP under
`Yocto/bsp/<board>/` — a baremetal-only target has no BSP there.

The complete list of valid targets comes from `config/data.json`; run
`./build.sh list` (or `./build.sh labels` for one per line) to print it.

## `config/data.json` and `config/update.py`

`config/data.json` is the canonical source of truth for the set of
supported designs and their per-target metadata (board name, processor
family, FMC connector, port lane mapping, port config, which software flows
are built, license). The `build.py` runner reads it directly at runtime, so
the target list is never hand-maintained, and the Sphinx pages of this
documentation are Jinja2 templates rendered against it.

`config/update.py` reads `data.json` and regenerates the auto-managed
content that is *not* read at runtime — each delimited by
`UPDATER START` / `UPDATER END` (or `<!-- updater start/end -->`) comment markers:

* the target design tables in the top-level `README.md`;
* the `target_dict` in `Vivado/scripts/build.tcl` — one line per target,
  `dict set target_dict <label> { <url> <boardname> <bdscript> { <lanes> } }`,
  which selects the board part, the `bd_<bdscript>.tcl` script and the set of
  Ethernet FMC ports to instantiate;
* the per-target build-output directories in `.gitignore`.

When adding or modifying a target, edit `data.json` and re-run
`python3 update.py` from the `config/` directory. Do not hand-edit content
between the markers; it will be overwritten on the next regeneration.

## Build runner

All build stages are driven by the cross-platform `build.py` runner at the
root of the repository, invoked through the `build.sh` shim on Linux / git
bash or `build.bat` on Windows (identical arguments). It reads the target
list and per-target attributes straight from `config/data.json`, builds
whatever a requested stage depends on automatically, skips anything already
built, and locates and sources the AMD tools itself — so there is no need to
source the Vivado / Vitis settings scripts beforehand.

The build is organised into stages, each available as a sub-command:

| Command      | Stage                                                                                          |
|--------------|------------------------------------------------------------------------------------------------|
| `project`    | Create the Vivado project (`.xpr`) and block design.                                           |
| `xsa`        | Synthesise, implement and export the hardware (`.xsa`).                                         |
| `standalone` | Create the Vitis workspace, build the baremetal app, package `BOOT.BIN`.                       |
| `yocto`      | Generate a custom MACHINE from the XSA (`gen-machineconf parse-sdt`), apply the BSP layers, build with bitbake and package. |
| `package`    | Gather the built boot artifacts into `bootimages/*.zip`.                                        |
| `all`        | Build every stage the target supports, then `package`.                                         |

Run `./build.sh list` to see the targets and their attributes, `./build.sh
status --target <t>` for per-stage artifact state, and `./build.sh --help`
for the full command list. There is no `ip` pre-stage in this repository (no
HLS IP) and no `petalinux` stage.

Because each stage builds its prerequisites first, a single
`./build.sh all --target <t>` cascades the whole pipeline:

```
./build.sh all --target t
  -> xsa         : vivado creates the project (build.tcl), then synth/impl/XSA export (xsa.tcl)
  -> standalone  : vitis builds the platform + app, packages BOOT.BIN
  -> yocto       : init-workspace (repo sync) -> configure-build (SDT + gen-machineconf parse-sdt)
                   -> build-image (bitbake edf-linux-disk-image) -> package-output
  -> package     : zip the boot files into bootimages/
```

Build a single stage on its own with `./build.sh <stage> --target <t>`; the
runner still builds any missing prerequisite stages first.

Per-target lock files (`.<target>.lock` at the repository root) prevent two
concurrent builds of the same target from clobbering each other.

## Vivado side

### Block design

There is one block-design script per processor family, selected for each target
by its `bdscript` field in `config/data.json`:

| Script | Targets | Processor |
|--------|---------|-----------|
| `Vivado/src/bd/bd_zynqmp.tcl` | `zcu104` | Zynq UltraScale+ hard PS |
| `Vivado/src/bd/bd_mb-us.tcl` | `kcu105` | MicroBlaze soft processor on UltraScale |

Both build the same per-port logic — one `taxi_rgmii_mac_N` cell and one
`axi_dma_N` per Ethernet FMC port — and differ only in what sits above it: the
MicroBlaze script also instantiates the processor, the DDR4 memory controller
(which supplies the 300 MHz IDELAYCTRL reference clock), an AXI INTC, an AXI
Timer and an AXI UART16550, all of which the hard PS provides on the ZynqMP
targets. The description below follows `bd_zynqmp.tcl`.

The block-design script `Vivado/src/bd/bd_zynqmp.tcl` builds the design for the
Zynq UltraScale+ targets. It is sourced by `scripts/build.tcl`, which provides
`$block_name` (`taxieth`) and `$ports`, the list of Ethernet FMC ports to
instantiate from the target's `lanes` in `data.json`. For each port it creates
a `taxi_rgmii_mac_N` cell (module reference) and an `axi_dma_N`, connects the
streams, clocks, resets and interrupts, exports the `rgmii_port_N`,
`mdio_io_port_N` and `reset_port_N` ports (the same names as in the AXI Ethernet
reference design, so its constraints carry over) and lets the connection
automation attach the AXI-Lite slaves to `M_AXI_HPM0_FPD`. One SmartConnect
collects all the DMA masters into `S_AXI_HP0_FPD`.

After sourcing the BD script, `scripts/build.tcl` runs
`validate_bd_design`, which triggers parameter propagation. The final
implemented design may therefore contain nets that aren't visible in the BD TCL
source — to see the actual netlist as built, inspect the saved `.bd`
file under `Vivado/<target>/<target>.srcs/sources_1/bd/taxieth/` or
use `write_bd_tcl` to export a complete script from an open project.

### The Taxi MAC cell

`taxi_rgmii_mac` is not an IP core — it is an RTL module that Vivado turns into
a block-design cell through the *module reference* mechanism. Two files make it up:

* `Vivado/src/hdl/taxi_rgmii_mac.v` — a Verilog-2001 shell (Vivado needs a
  Verilog top for a module reference) whose port attributes tell the block
  design how to group the pins into AXI-Lite, AXI-Stream, RGMII and MDIO
  interfaces. Its header is the authoritative register map.
* `Vivado/src/hdl/taxi_rgmii_mac_core.sv` — the SystemVerilog implementation:
  the Taxi `taxi_eth_mac_1g_rgmii_fifo` (MAC + RGMII PHY interface + async
  FIFOs), the Taxi `taxi_mdio_master`, and Opsero's AXI-Lite register file.

The Taxi source files themselves are pulled from the submodule by
`Vivado/scripts/taxi_sources.tcl`, which lists every file the project needs
(and the Taxi Vivado timing-constraint scripts for the clock-domain crossings).
Updating the submodule to a newer Taxi commit means checking that list
against the new tree — Taxi is under active development and module
interfaces change.

The parameters set on the cell in `bd_zynqmp.tcl`:

| Parameter | Value | Meaning |
|-----------|-------|---------|
| `AXIS_DATA_W` | 32 | DMA-side AXI-Stream width (matches the AXI DMA stream width) |
| `TX_FIFO_DEPTH` / `RX_FIFO_DEPTH` | 8192 | frame FIFO depths in bytes; in frame mode a whole frame must fit, which caps the usable MTU at 8000 |
| `FAMILY` | `zynquplus` | Taxi device-family string selecting the I/O primitives (IDDR/ODDR/IDELAYE3) |
| `USE_CLK90` | 1 | the FPGA generates the RGMII TX clock from `gtx_clk90` (transmit delay in the FPGA) |
| `RX_IDELAY_PS` | 1100 | IDELAYE3 on `rxd`/`rx_ctl`, in picoseconds (needs the IDELAYCTRL fed from `clk_wiz_0/clk_out3`) |
| `IDELAY_REFCLK_MHZ` | 300 | the IDELAYCTRL reference frequency |

The values above are the ones `bd_zynqmp.tcl` sets for the ZCU104. `FAMILY` and
`RX_IDELAY_PS` are per-target: `FAMILY` follows the device (`kintexu` on the
KCU105), and the receive IDELAY compensates the carrier's FMC trace lengths, so
`bd_mb-us.tcl` carries its own **per-port** list, `rx_idelay_ps`, at the top of
the script — change the delays there rather than in the cell-parameter block.
On the KCU105 all four ports use `RX_IDELAY_PS 1100` (the TIME-mode maximum): at
600 ps every port met setup by about 0.8 ns but missed hold by 0.3 ns, and the full
1100 ps centres the eye with all four receive clocks meeting timing at signoff.
On the KCU105 the IDELAYCTRL reference is the DDR4 controller's 300 MHz `ui`
clock rather than a clocking-wizard output.

#### PHY delay configuration (`rgmii-rxid`)

RGMII needs a ~2 ns skew between the clock and data in each direction, and either end of the link
can add it. This design uses the **`rgmii-rxid`** convention: the FPGA adds the transmit delay
(`USE_CLK90`), the PHY adds the receive delay, and `RX_IDELAY_PS` is a small trim on top. The
software configures the Marvell 88E1510 accordingly (RX delay on, TX delay off) — in the lwIP
netif (`Vitis/common/src/taxi_macif.c`) and through `phy-mode = "rgmii-rxid"` in the Linux device
tree (`port-config.dtsi`), which phylib passes to the Marvell PHY driver. Hardware and software must
agree; if you port the design to a board where the PCB adds delay, change both.

### Simulation

`Vivado/sim/` contains an xsim testbench for the MAC cell (`tb_taxi_rgmii_mac.sv`) and
`run_xsim.sh`, which compiles the Taxi sources, the cell and the testbench and runs the
simulation from the command line (outputs go to `Vivado/sim/xsim_work/`, which is not committed).
Use it to check a register-map or data-path change before a full implementation run.

### Constraints

`Vivado/src/constraints/<target>.xdc` contains pin assignments and any
target-specific timing constraints (the RGMII input clocks and the I/O delays).
Constraints common to all targets are not factored out — each target's XDC is
self-contained. The clock-domain-crossing constraints inside the Taxi modules come with the
modules, from the `.tcl` files listed in `taxi_sources.tcl`.

### Build scripts

* `Vivado/scripts/build.tcl` creates the Vivado project, adds the Taxi sources
  (`taxi_sources.tcl`), the MAC cell sources and the target's XDC, sources
  the target's `bd_<bdscript>.tcl`, and validates the block design. Invoked via
  `./build.sh project --target <t>`.
* `Vivado/scripts/xsa.tcl` opens the existing project, runs synthesis
  and implementation, exports the XSA, and writes the bitstream into
  the implementation run directory. Invoked via `./build.sh xsa --target <t>`.

Both scripts check `XILINX_VIVADO` to confirm the installed Vivado
version matches the `version_required` constant at the top of the
file. Bumping the project to a new Vivado release means changing those
constants and re-testing — the BD TCL APIs are not stable across major
releases.

### Modifying the block design

Edit the target's block-design script (`bd_zynqmp.tcl` or `bd_mb-us.tcl`) directly. Once the
script is edited, delete any existing per-target
Vivado project directory (`rm -rf Vivado/<target>`) and re-run the Vivado build:

```
./build.sh xsa --target <target>
```

This re-creates the project, sources the modified BD script, runs
`validate_bd_design`, synthesises, implements, and re-exports the XSA.
Downstream Vitis / Yocto / boot-image steps will pick up the new
XSA on the next build. To build fewer ports, change the target's `lanes` in `data.json`
and re-run `config/update.py` rather than editing the script — the port loop follows `$ports`.

### Adding or modifying constraints

Edit `Vivado/src/constraints/<target>.xdc` directly. For a new board, the
FPGA Board Repository (<https://boards.fpgadeveloper.com>) generates the Ethernet FMC pin
constraints for any listed carrier.

## Vitis side

The standalone (baremetal) build runs the lwIP echo server on all four ports —
see [echo server](echo_server.md) for what the application does. The application source
is shared across all targets; per-target specialisation is handled by
the build driver, not by per-target source.

### Layout

```
Vitis/
├── py/
│   ├── args.json
│   ├── build-vitis.py        <- Universal Vitis Python build driver
│   ├── make-boot.py          <- BOOT.BIN packaging
│   └── pre_platform_build.py <- Hook run before each platform build (xiltimer tick timer)
├── common/
│   └── src/                  <- Application source (main.c, echo.c, taxi_macif.*, taxi_mac.*)
├── boot/<target>/            <- Per-target packaged boot files (BOOT.BIN)
└── <target>_workspace/       <- Generated Vitis workspace per target
```

### `args.json`

`Vitis/py/args.json` is the repo-specific configuration that drives the
universal `build-vitis.py` driver. The key fields are:

* `bd_name` — block-design name (`taxieth`).
* `app_name` — name of the Vitis application (`echo_server`).
* `app_template` — `empty_application`: the app is populated from `common/src`,
  not scaffolded from a Vitis template (the AMD `lwip_echo_server` template only
  knows AMD MACs).
* `bsp_libs` — BSP libraries to add and configure: `lwip220` (DHCP off, an
  enlarged pbuf pool, 64 TX / 64 RX descriptors) and `xiltimer` with the interval
  timer enabled.
* `src` — application source mapping. `"all": "common/src"` means
  every target uses the same source directory.
* `pre_platform_build_script` — hook invoked before the platform is built.

```{important}
The Taxi MAC has **no checksum offload**, so the lwIP BSP configuration keeps
the software checksum generation and checking enabled (the stock `lwip220`
defaults). Do not turn the `LWIP_*_CSUM` options off in `args.json` unless you
add a checksum-offload block to the data path.
```

### Modifying the standalone application

Edit `Vitis/common/src/*.c` directly. The next `./build.sh standalone
--target <t>` rebuilds the application against the existing platform; if
you've changed the hardware (XSA) you'll need a fresh workspace
(`./build.sh clean --target <t> --stage standalone` first). The per-port
base addresses in `taxi_mac_hw.h` follow the `xparameters.h` names generated
from the XSA, so a renamed block-design cell needs a matching edit there.

### Modifying BSP libraries or build hooks

Adjust the corresponding entry in `Vitis/py/args.json`. Configuration
changes propagate through the next `pre_platform_build` run.

## Linux driver

`Linux/taxi-mac/` holds `taxi_mac.c`, an out-of-tree network driver for the
`taxi_rgmii_mac` block, with its own Makefile (a KDIR-style build that also matches
what Yocto's `module.bbclass` drives) and a README describing the device-tree
binding, the register-map dependency and the design notes. In short: one
network interface per MAC instance; the driver owns the register file and the
port's MDIO bus (the PHY is handled by phylib), and the paired AXI DMA is driven
through the dmaengine API by the upstream `xilinx_dma` driver, so no DMA
register access lives in the driver. It binds to
`compatible = "opsero,taxi-rgmii-mac-1.0"` and checks the ID register (`"TAXI"`) at probe.

The Yocto image builds the module from these sources in place — nothing is copied
into the layer — through the `taxi-mac` recipe in `Yocto/common/meta-taxi-eth`, and
autoloads it at boot. To build it by hand against a kernel build tree:

```
make -C Linux/taxi-mac KDIR=/path/to/kernel/build ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
```

## Yocto / EDF side

The repository builds its Linux images with the AMD
Yocto / Embedded Development Framework (EDF) flow — the successor to
PetaLinux. It lives in the `Yocto/` directory; this section summarises how it is
organised and what is modified on top of stock.

### Yocto scripts

The Yocto / EDF flow is driven by the build runner (`./build.sh yocto`), which
runs the scripts in `Yocto/scripts/` directly:

| Script               | Role                                                                     |
|----------------------|--------------------------------------------------------------------------|
| `init-workspace.sh`  | `repo init` + `repo sync` of the AMD yocto-manifests                     |
| `configure-build.sh` | XSA → System Device Tree (sdtgen) → custom MACHINE via `gen-machineconf parse-sdt`; layers and `local.conf` |
| `build-image.sh`     | `bitbake edf-linux-disk-image`                                           |
| `package-output.sh`  | gather the flashable artifacts into `images/linux/`                      |
| `hostfix.sh`         | host-tool workarounds, sourced by the others                             |

The scripts are **universal** — byte-identical across all of our reference
repos. They take no repo-specific content; the build runner supplies the
per-target values it reads from `config/data.json` — the target list, `BD_NAME`,
and each target's `<template> [<port-config>]` (e.g. `zcu104 → zynqMP ports-0123`).

### parse-sdt: MACHINE generated from the XSA

`configure-build.sh` runs `xsct`/`sdtgen` on the target's XSA to produce a System
Device Tree, then `gen-machineconf parse-sdt` to emit a custom
`MACHINE = taxieth-<target>` plus the per-domain device trees. The PL hardware —
the `taxi_rgmii_mac_N` and `axi_dma_N` nodes — comes from the design's own SDT
(`pl.dtsi`); the Vivado bitstream is embedded into `BOOT.BIN` and the FSBL
programs the PL at boot. There is no pinned AMD MACHINE.

### BSP composition

A Yocto BSP is a set of **layers** over the EDF default config. Each target's build gets:

1. A **board BSP** at `Yocto/bsp/<board>/` — `conf/local.conf.append` (hostname,
   kernel command line: console, `root=/dev/mmcblk0p3`, `cma=512M`) plus a `meta-user/`
   layer (kernel `bsp.cfg`, `system-user.dtsi` / `board-user.dtsi` board fixups, the
   FSBL bbappend, the image bbappend that installs the design's packages). Selected by
   the first token of the target name.
2. The **shared design layer** `Yocto/common/meta-taxi-eth/`, listed in the board's
   `bblayers-extra.txt`: the `taxi-mac` kernel-module recipe (built from `Linux/taxi-mac`)
   and the `taxi-eth-test` recipe.
3. A **port-config overlay layer** at `Yocto/bsp/port-configs/<ports-*>/` —
   selected from the target's `portcfg` in `config/data.json`. It supplies
   `port-config.dtsi`: for every active port, the `taxi_mac` driver's compatible
   string (overriding the generic one sdtgen emits for a module reference), the
   DMA channels (`dmas`/`dma-names`), the fixed MAC address, `phy-mode = "rgmii-rxid"`
   and the PHY on the port's own MDIO bus. A target with fewer ports would use a
   different overlay; the mechanism is a no-op for a target without one.

`system-user.dtsi` and `port-config.dtsi` are added to the **Linux** device
tree via `EXTRA_DT_INCLUDE_FILES`, guarded so they only apply to the Linux-domain
DT — the FSBL/PMU domain DTs don't define the labels they reference.

### Modifications on the stock EDF config

* **Image packages** (`edf-linux-disk-image.bbappend`): `taxi-mac`, `taxi-eth-test`,
  `ethtool`, `iperf3`, `i2c-tools`, `phytool` (the test recipe also pulls in `iproute2`
  and `iputils-ping`, and recommends `kernel-module-pktgen`).
* **Kernel configuration** (`bsp.cfg`): `CONFIG_DMADEVICES` / `CONFIG_XILINX_DMA` (the AXI DMA
  dmaengine driver), `CONFIG_MVMDIO` / `CONFIG_MARVELL_PHY` (the Ethernet FMC PHYs),
  `CONFIG_DP83867_PHY` / `CONFIG_AMD_PHY` / `CONFIG_XILINX_PHY` (the ZCU104's own RJ45),
  `CONFIG_NET_PKTGEN=m`.
* **ZCU104 FSBL VADJ patch** (`recipes-bsp/embeddedsw/`): mandatory, the stock FSBL never
  powers the FMC. Because the 2025.2 `xlnx-embeddedsw.bbclass` copies the sources in *after*
  `do_patch`, the bbappend stages the patch with `apply=no` and applies it in a task inserted
  between `do_copy_shared_src` and `do_configure`.
* **ZCU104 device-tree fixups** (`system-user.dtsi`): pins `uart0` as `ttyPS0` (the console)
  and restores the `sdhci1` properties the ZCU104 level shifter needs. `board-user.dtsi`
  carries the board's PS Ethernet MAC address.
* **Bench-ready image**: an SSH server, DHCP on every wired interface, and the fixed MAC
  addresses, so a board can be exercised over the network without touching it.

### Adding a target

Set the design's `yocto` flag in `config/data.json`, run `config/update.py`, then create
`Yocto/bsp/<board>/` following `zcu104` (a `bblayers-extra.txt` naming
`Yocto/common/meta-taxi-eth` is all that is needed to get the driver and the test). If the
target uses a port count not already covered, add a `Yocto/bsp/port-configs/<ports-XXXX>/`
overlay with the matching `port-config.dtsi`.

## Licensing of modifications

The MAC wrapper, the register file, the driver and everything else outside `submodules/` is
MIT-licensed, so you may change it freely. The Taxi modules are CERN-OHL-S-2.0: if you modify
them (or the wrapper that instantiates them) and ship a product built from the result, the
complete source of the modified design must be made available under the same license on
request — see `submodules/README.md`.

## Where build outputs land

| Path                                | Contents                                                                       |
|-------------------------------------|--------------------------------------------------------------------------------|
| `Vivado/<target>/`                  | Vivado project. `taxieth_wrapper.xsa` is the export.                            |
| `Vivado/<target>/<target>.runs/impl_1/taxieth_wrapper.bit` | Bitstream.                                              |
| `Vivado/logs/`                      | Per-target Vivado build logs (xpr + xsa).                                       |
| `Vivado/sim/xsim_work/`             | Simulation outputs of `run_xsim.sh`.                                            |
| `Vitis/<target>_workspace/`         | Per-target Vitis workspace (platform + application + BSP).                      |
| `Vitis/boot/<target>/`              | Packaged Vitis boot files (`BOOT.BIN`).                                          |
| `Yocto/<target>/`                   | Yocto workspace (`repo` checkout, build directory, sstate).                     |
| `Yocto/<target>/images/linux/`      | `BOOT.BIN`, `Image`, `system.dtb`, `boot.scr`, `rootfs.wic.xz`, `rootfs.tar.gz`, etc. |
| `bootimages/`                       | Per-target zipped boot files (`<prj>_<target>_yocto-<ver>.zip` and `<prj>_<target>_standalone-<ver>.zip`). |

None of these directories are committed to the repository.
