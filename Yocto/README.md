# Yocto / EDF builds

This folder builds Linux images for the Ethernet FMC Taxi Ethernet reference
design using the AMD Yocto / Embedded Development Framework (EDF) flow — the
announced successor to PetaLinux Tools. This repo has **no PetaLinux flow**: EDF
is the only embedded-Linux flow.

The design puts one **Taxi RGMII MAC** (`taxi_rgmii_mac_N`, a Vivado module
reference: the Taxi 1G RGMII MAC + MDIO master + an AXI-Lite register file)
paired with a **Xilinx AXI DMA** (`axi_dma_N`, MM2S = tx, S2MM = rx) on each
Ethernet FMC port. Linux drives the ports with the repo's own out-of-tree
driver, `Linux/taxi-mac` (`taxi_mac.ko`, compatible
`opsero,taxi-rgmii-mac-1.0`), which this flow builds into the image.

## How it works: the parse-sdt flow

The build generates a **custom Yocto MACHINE directly from the Vivado XSA** —
there is no dependency on an AMD-provided machine config. A customer can change
the PS in Vivado and have it flow through automatically:

```
XSA  --sdtgen-->  System Device Tree  --gen-machineconf parse-sdt-->  MACHINE + DTS
```

`scripts/configure-build.sh` runs `xsct`/`sdtgen` on the XSA to produce a System
Device Tree (which includes `pl.dtsi`, the PL hardware extracted from the
design), then runs `gen-machineconf parse-sdt` to emit
`conf/machine/taxieth-<target>.conf` plus the lopper-generated per-domain device
trees. The PL **`taxi_rgmii_mac_N` and `axi_dma_N` nodes** therefore come from
the design's own SDT — no hand-curated PL device tree. Because no PL overlay is
requested, the Vivado bitstream is embedded into `BOOT.BIN` (the FSBL programs
the PL at boot).

What the XSA does *not* carry — the external Ethernet FMC PHYs, which driver
binds each MAC, and a few SoC-side board quirks — is layered on top of the
generated tree by two small hand-written device-tree files and one shared Yocto
layer:

* **`bsp/<board>/…/system-user.dtsi`** + **`board-user.dtsi`** — SoC-side
  board fixups and the board's own RJ45 (see "Per-board fixups").
* **`bsp/port-configs/<ports-*>/…/port-config.dtsi`** — the per-target Taxi
  port wiring (see "Port-config overlays").
* **`common/meta-taxi-eth/`** — the `taxi-mac` driver recipe and the
  `taxi-eth-test` self-test app (see "The taxi-mac module" and "The test app").

## Prerequisites

Host packages on Ubuntu 22.04 / 24.04:

```
sudo apt-get install repo gawk wget git diffstat unzip texinfo gcc \
    build-essential chrpath socat cpio python3 python3-pip python3-pexpect \
    xz-utils debianutils iputils-ping python3-git python3-jinja2 \
    python3-subunit zstd liblz4-tool file locales libacl1 bmap-tools
```

Plus Vivado 2025.2 (used to produce the XSA this flow consumes) and Vitis
2025.2 — `sdtgen`/`xsct` (used to turn the XSA into a System Device Tree)
ship with Vitis, not Vivado, in 2025.2. The build runner locates and sources
the Vitis environment itself; sourcing it manually is only needed when
running the `scripts/` engine by hand:

```
source <xilinx-install>/2025.2/Vivado/settings64.sh
source <xilinx-install>/2025.2/Vitis/settings64.sh
```

## Build

Yocto images are built with the cross-platform build runner at the repo root
(this stage requires a native Linux machine; on Windows the runner refuses
it up front and prints the hand-off command):

```
./build.sh yocto --target zcu104        # or any target from `./build.sh list`
```

The runner builds the Vivado XSA first if one isn't already present, then
sequences the four scripts in `scripts/` — the engine of the flow
(init-workspace, configure-build, build-image, package-output).

The first build for a target:

1. Builds the Vivado project and exports the XSA if one isn't already
   present.
2. Initializes a manifest workspace under `Yocto/<TARGET>/` with
   `repo init -u https://github.com/Xilinx/yocto-manifests.git -b rel-v2025.2 -m default-edf.xml`
   and `repo sync` (≈5 GB of git history).
3. Sources `edf-init-build-env` to set up the bitbake environment.
4. Generates the System Device Tree from the XSA and runs
   `gen-machineconf parse-sdt` to create `MACHINE = "taxieth-<target>"`.
5. Layers `bsp/<board>/conf/local.conf.append` (hostname, kernel cmdline) and
   `bsp/<board>/meta-user/` (kernel config, `system-user.dtsi` /
   `board-user.dtsi` board fixups, FSBL patch, image bbappend) over the EDF
   default config, plus the `bsp/port-configs/<ports-*>/meta-user/` overlay
   layer selected by the target's `portcfg` in `config/data.json`, plus the
   extra layers listed in `bsp/<board>/bblayers-extra.txt` (here
   `common/meta-taxi-eth`).
6. Runs `bitbake edf-linux-disk-image`.
7. Gathers `BOOT.BIN` (with the PL bitstream embedded), `Image`,
   `system.dtb`, `boot.scr`, `rootfs.tar.gz`, `rootfs.wic.xz`, and
   `rootfs.wic.bmap` into `Yocto/<TARGET>/images/linux/`.

Subsequent builds skip `repo sync`. To force a re-config (e.g. after editing
`bsp/<board>/conf/local.conf.append`), remove `Yocto/<TARGET>/configdone.txt`.

`./build.sh yocto --target all` builds every target; `./build.sh status --target all`
reports which are built.

## Port-config overlays (`port-config.dtsi`)

The external Ethernet-FMC PHYs are board knowledge the XSA does not carry, and
so is the driver binding of the MAC module reference (sdtgen emits a generic
`xlnx,taxi-rgmii-mac-1.0` compatible for a module reference). The wiring is
factored into a per-config overlay **layer** rather than into the board BSP, so
a board BSP can be shared across targets that differ only in active ports:

```
bsp/port-configs/
  ports-0123/meta-user/   four-port designs  (taxi_rgmii_mac_0..3)
```

The overlay is a small Yocto layer whose `device-tree.bbappend` adds its
`port-config.dtsi` to the Linux device tree via `EXTRA_DT_INCLUDE_FILES`. Which
overlay applies is selected per target by the **`portcfg`** field of the design
in `config/data.json` (e.g. `"portcfg": "ports-0123"`): `configure-build.sh`
adds `bsp/port-configs/<portcfg>/meta-user` to `bblayers.conf` alongside the
board layer.

`port-config.dtsi` sets, for each active port, on the `&taxi_rgmii_mac_N` node
(the node itself comes from the SDT's `pl.dtsi`):

```
&taxi_rgmii_mac_0 {
	compatible = "opsero,taxi-rgmii-mac-1.0";   /* bind the taxi_mac driver */
	dmas = <&axi_dma_0 0>, <&axi_dma_0 1>;      /* MM2S = tx, S2MM = rx    */
	dma-names = "tx", "rx";
	phy-mode = "rgmii-rxid";                    /* MAC drives TX clock 90 deg late; PHY adds the RX delay */
	phy-handle = <&extphy0>;
	local-mac-address = [00 0a 35 06 21 05];    /* board MAC + 1..4 */
	mdio { #address-cells = <1>; #size-cells = <0>;
	       extphy0: ethernet-phy@0 { reg = <0>; }; };   /* 88E1510 on the port's own MDIO */
};
```

It also sets `xlnx,irq-delay = /bits/ 8 <1>` (the DMA driver reads an 8-bit value) on each port's AXI DMA **S2MM (rx)
channel** node (`&dma_channel_<addr+0x30>`, generated by sdtgen as a child of
`axi_dma_N`): the driver keeps 128 receive buffers queued, and without the
delay timer the `xilinx_dma` engine would only raise the RX interrupt once all
128 had completed.

## Per-board fixups (`system-user.dtsi`, `board-user.dtsi`)

Each board's `bsp/<board>/meta-user/recipes-bsp/device-tree/files/` holds two
files layered onto the generated Linux device tree (via
`EXTRA_DT_INCLUDE_FILES`, guarded so they only apply to the Linux domain DT —
the FSBL/PMU domain DTs don't define the SoC peripheral labels). They contain
only SoC-side board knowledge, not PL hardware or FMC PHY wiring (that's the
port-config overlay):

* **`system-user.dtsi`** (`zcu104`): the 2025.2 flow leaves `port-number = <0>`
  on both `uart0` and `uart1`, so the `ttyPS0`/`ttyPS1` mapping is left to probe
  order — the port numbers and serial aliases are pinned so the console (cabled
  to UART0) is deterministic. The XSA also exports a minimal `sdhci1` node;
  without the `no-1-8-v` / `broken-cd` / caps-mask properties of the stock
  ZCU104 BSP the SD card times out (`error -110`).
* **`board-user.dtsi`** (`zcu104`): the board's own RJ45 is PS **GEM3** with a
  TI **DP83867** PHY at MDIO address `0xc`. The SDT flow does not describe the
  PHY, so without this node Linux uses the Generic PHY driver, the RGMII delays
  are never programmed and the link passes no packets. It also gives GEM3 the
  fixed MAC `00:0a:35:06:21:04` so the board is reachable over SSH at a known
  address; the four FMC ports take the next four addresses (`…:05` – `…:08`).

**FSBL VADJ patch** (`bsp/zcu104/meta-user/recipes-bsp/embeddedsw/`): the
2025.2 FSBL reads the FMC VADJ record from the wrong EEPROM (the board's own
instead of the FMC's) and reads too few bytes to reach it, so it never enables
VADJ and the Ethernet FMC stays unpowered. The bbappend applies the patch in a
custom task after `do_copy_shared_src` (the 2025.2 `xlnx-embeddedsw.bbclass`
runs `do_patch` on an empty workdir, so an ordinary `SRC_URI` patch cannot
apply). Mandatory on the ZCU104.

Kernel config fragments live in
`bsp/<board>/meta-user/recipes-kernel/linux/linux-xlnx/bsp.cfg`:
`CONFIG_XILINX_DMA` (the AXI DMA dmaengine driver the `taxi_mac` driver uses
for its data path), `CONFIG_MARVELL_PHY` / `CONFIG_MVMDIO` (the FMC's 88E1510
PHYs), `CONFIG_DP83867_PHY` (the ZCU104's own PHY) and `CONFIG_NET_PKTGEN=m`
(bench traffic generator).

## The taxi-mac module (`common/meta-taxi-eth`)

`common/meta-taxi-eth` is a board-independent layer shared by every board BSP
(each `bsp/<board>/bblayers-extra.txt` lists it). Its
`recipes-kernel/taxi-mac/taxi-mac_1.0.bb` builds the out-of-tree driver as a
kernel module straight from the repo's **`Linux/taxi-mac/`** sources
(`taxi_mac.c` + `Makefile`; nothing is copied into the layer — the layer's
`layer.conf` resolves `TAXI_ETH_LINUX_DIR` relative to itself). The module is
packaged as `kernel-module-taxi-mac`, installed by the image bbappend and
auto-loaded at boot (`KERNEL_MODULE_AUTOLOAD`). It binds to the
`opsero,taxi-rgmii-mac-1.0` nodes from `port-config.dtsi` and creates one
netdev per port (`eth1`–`eth4` in the order the ports probe; `eth0` is the
board's GEM3). See `Linux/taxi-mac/README.md` for the driver itself.

## The test app (`taxi-eth-test`)

`recipes-apps/taxi-eth-test` installs `/usr/bin/taxi-eth-test`, the bench
self-test. Fixture: Ethernet FMC port 0 cabled to the LAN router (DHCP), ports
1–3 may be left unconnected. As root:

```
taxi-eth-test              # PASS if >= 1 port has link + DHCP lease + gateway ping
taxi-eth-test --all-ports  # additionally require carrier on all four ports
```

It finds the ports bound to the `taxi_mac` driver (via
`/sys/class/net/*/device/driver`), brings them up, reports link state /
speed per port (`ethtool`), waits for a DHCP lease on every port with carrier
(systemd-networkd runs DHCP on all wired ports in the EDF image), pings that
port's gateway 5 times requiring at least 4 replies, dumps each port's driver
counters (`ethtool -S`), and prints `VERDICT: PASS` (exit 0) or
`VERDICT: FAIL` (exit 1). The image also ships `ethtool`, `iperf3`,
`i2c-tools`, `phytool` and the `pktgen` module for further bench work.

## Flashing to SD card

The build produces a full wic disk image (`rootfs.wic.xz`). Flash it to the SD
card's raw device; per-partition file copies do **not** work because the boot
script boots from the device it finds itself on.

The EDF wks uses a 4-partition layout (`esp` (vfat), `boot` (ext4), `root`
(ext4), `storage` (vfat)). It leaves the `esp` partition empty and installs
`BOOT.BIN` onto the ext4 `boot` partition (which the BootROM cannot read). The
BootROM reads `BOOT.BIN` from the first FAT partition (`esp`), so after flashing
you must drop `BOOT.BIN` onto `esp` (partition 1) by hand.

### 1. Identify the SD card device — carefully

`dd`-style writes to a block device cannot be undone. With the SD card
**un**plugged, run `lsblk -o NAME,SIZE,RM,TYPE,MOUNTPOINT`; insert the card and
re-run it. The new entry (typically `/dev/sdX`, `RM=1`, size matching your card)
is your target. Confirm with
`udevadm info --query=property --name=/dev/sdX | grep -E "ID_BUS|ID_MODEL"`
(`ID_BUS=usb`). **Do not proceed until you are certain `/dev/sdX` is your SD card
and not an internal disk.**

### 2. Unmount any auto-mounted partitions

```
for p in /dev/sdX?*; do sudo umount "$p" 2>/dev/null; done
```

### 3. Flash the wic image to the raw device

```
sudo bmaptool copy \
    --bmap Yocto/<TARGET>/images/linux/rootfs.wic.bmap \
          Yocto/<TARGET>/images/linux/rootfs.wic.xz \
          /dev/sdX
```

Fallback (slower): `xzcat …/rootfs.wic.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync`.

### 4. Install BOOT.BIN on the esp partition (p1)

```
sudo partprobe /dev/sdX
sudo mkdir -p /mnt/sd_esp
sudo mount /dev/sdX1 /mnt/sd_esp
sudo cp Yocto/<TARGET>/images/linux/BOOT.BIN /mnt/sd_esp/BOOT.BIN
sync
sudo umount /mnt/sd_esp && sudo rmdir /mnt/sd_esp
```

### 5. Eject and boot

Eject the card cleanly (`sudo eject /dev/sdX`) so pending writes flush. Insert it
into the board, set the boot-mode switches to SD (ZCU104 SW6: `1=ON 2=OFF
3=OFF 4=OFF`), power-cycle, and attach a UART terminal at 115200 8N1.

Log in as **`amd-edf`** (the EDF image's default user; it has `sudo`, ships
with no password and asks you to set one at first login) — the hostname is
`zcu104-taxieth-2025-2`. The board's RJ45 (`eth0`) gets a DHCP
lease with the fixed MAC above, so you can also `ssh amd-edf@<address>`.

## Offline / faster builds

Place the absolute path to a directory containing an extracted AMD sstate-cache
mirror in `Yocto/offline.txt` — `configure-build.sh` auto-detects which
architecture subdirs exist under it and wires one `SSTATE_MIRRORS` entry per
arch (plus `SOURCE_MIRROR_URL` if a `downloads/` dir is present).

Expected layout under that path:

```
<sstate root>/
  aarch64/      (Zynq UltraScale+ Linux)
  arm/          (Zynq-7000 Linux)
  microblaze/   (the ZynqMP PMU firmware multiconfig)
  downloads/    (optional — the source-mirror tarballs)
```

The sstate-cache and downloads archives are available behind login at the AMD
Embedded Design Tools download page under "sstate-cache & Downloads - 2025.2".

## Layout

```
Yocto/
  README.md                 this file
  offline.txt               (optional, gitignored) path to an extracted sstate mirror
  scripts/
    init-workspace.sh       repo init + sync
    configure-build.sh      sdtgen + gen-machineconf parse-sdt + apply BSP (+ overlays) + sstate
    build-image.sh          bitbake the image recipe
    package-output.sh       gather deploy artifacts into images/linux/
    hostfix.sh              host-tool workarounds
  bsp/
    <board>/                one per board
      conf/local.conf.append   board overrides (hostname, kernel cmdline)
      bblayers-extra.txt       extra layers for this board (common/meta-taxi-eth)
      meta-user/               Yocto layer: kernel cfg, system-user.dtsi + board-user.dtsi,
                               FSBL VADJ patch, image bbappend
    port-configs/
      ports-0123/             per-target Taxi port overlay layer (port-config.dtsi)
  common/
    meta-taxi-eth/          shared layer: taxi-mac driver recipe + taxi-eth-test app
  <TARGET>/                 (gitignored) per-target workspace built by build.sh
```

## Architectural notes

* **The four scripts are universal** — identical across all of our
  reference repos. The per-repo data (target list, `BD_NAME`, each target's
  template and optional port config) lives in `config/data.json`, which
  `build.py` reads at runtime — nothing is generated into this folder.

* **The MACHINE is generated from the XSA** by `gen-machineconf parse-sdt` (the
  flow AMD recommends; `parse-xsa` is deprecated). There is no pinned
  AMD-validated MACHINE and no per-target flow selection. The custom machine is
  named `${BD_NAME}-<target>` (i.e. `taxieth-<target>`); `configure-build.sh`
  takes `BD_NAME` as an argument so the script stays repo-agnostic.

* **The bitstream lives in BOOT.BIN**, not loaded at runtime via FPGA manager.
  Because no PL overlay is requested, the bitstream `sdtgen` extracted from the
  XSA is embedded into `BOOT.BIN` and the FSBL programs the PL during boot.

* **The dtsi files are scoped to the Linux device tree** (via a guard on
  `CONFIG_DTFILE`). The FSBL and PMU domain device-trees don't define the SoC
  peripheral / `taxi_rgmii_mac` labels the overrides reference, so including
  them there makes `dtc` fail with "Label or path … not found".

* **The driver is built from `Linux/taxi-mac`, not vendored into the layer**,
  so a driver change is picked up by the next `./build.sh yocto` with no copy
  step. The same sources build on the target against the running kernel with
  the driver's own `Makefile` (`make KDIR=/lib/modules/$(uname -r)/build`).

* **Adding a target**: set `"yocto": true` and the `"portcfg"` for the design in
  `config/data.json`, then create `bsp/<board>/` following `zcu104` (keep the
  `bblayers-extra.txt` so the common layer is pulled in; the FSBL VADJ patch is
  ZCU104-specific). If the target uses a port count not already covered, add a
  `bsp/port-configs/<ports-XXXX>/` overlay.
