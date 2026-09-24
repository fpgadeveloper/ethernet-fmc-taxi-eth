# Yocto

The Linux image for these reference designs is built with the AMD Yocto / EDF flow (Embedded
Development Framework, the successor to PetaLinux) using the cross-platform `build.py` runner at
the root of the repository. There is no PetaLinux flow in this repository.

The Linux flow exists for the hard-processor targets only: a **MicroBlaze target (the KCU105) is
baremetal only** — it has no Yocto image and no `taxi_mac` driver, and runs the
[standalone echo server](echo_server.md) instead. The table in the
[build instructions](build_instructions.md#target-designs) shows which flows each target supports.

The image brings the four Taxi MAC ports of the [Ethernet FMC] up as ordinary Linux network
interfaces through the out-of-tree **`taxi_mac`** driver (`Linux/taxi-mac`, built and installed by
the `Yocto/common/meta-taxi-eth` layer) and ships **`taxi-eth-test`**, a self-test script that
checks every port, together with the usual diagnostic tools (`ethtool`, `iproute2`, `iperf3`,
`i2c-tools`, `phytool` and the kernel `pktgen` module).

## Requirements

To build the Yocto projects you will need a physical or virtual machine running one of the
[supported Linux distributions] (Ubuntu 22.04 / 24.04 are what we use), with the Vitis Core
Development Kit installed — the flow uses `xsct`/`sdtgen` (which ship with Vitis) to generate a
System Device Tree from the Vivado XSA. You also need [Google's repo tool](https://gerrit.googlesource.com/git-repo/)
on your `PATH` and the usual Yocto host packages:

```
sudo apt-get install repo gawk wget git diffstat unzip texinfo gcc \
    build-essential chrpath socat cpio python3 python3-pip python3-pexpect \
    xz-utils debianutils iputils-ping python3-git python3-jinja2 \
    python3-subunit zstd liblz4-tool file locales libacl1 bmap-tools
```

```{attention}
You cannot build the Yocto projects in the Windows operating system. Windows users
are advised to use a Linux virtual machine to build the Yocto projects.
```

## How to build

The build runner locates and sources the Vivado and Vitis settings itself, so there is no
need to source them by hand; you only need [Google's repo tool](https://gerrit.googlesource.com/git-repo/)
on your `PATH` (see Requirements above).

1. From a command terminal, clone the Git repository (with its submodules) and `cd` into it:
   ```
   git clone --recursive https://github.com/fpgadeveloper/ethernet-fmc-taxi-eth.git
   cd ethernet-fmc-taxi-eth
   ```
2. Build the Yocto image for your target by running the following command, replacing
   `<target>` with one of the target design labels listed in the
   [build instructions](build_instructions.md#build-yocto):
   ```
   ./build.sh yocto --target <target>
   ```

This command launches the corresponding Vivado build if that project has not already been
built and its hardware exported. The first build of a target downloads several GB of sources
(`repo sync`) and runs bitbake from scratch, so it takes a while; subsequent builds are
incremental. The output products are gathered into `Yocto/<target>/images/linux/`:

| File | Description |
| --- | --- |
| `BOOT.BIN` | Boot image (FSBL with the ZCU104 VADJ patch + PMU firmware + bitstream + ATF + U-Boot) |
| `boot.scr` | U-Boot boot script |
| `Image` | Linux kernel |
| `system.dtb` | Linux device tree |
| `rootfs.wic.xz` | Full SD-card disk image — this is what you flash |
| `rootfs.wic.bmap` | Block map for `bmaptool` (fast flashing) |
| `rootfs.tar.gz` | Root filesystem tarball |

## Boot from SD card

The Yocto flow produces a **full SD-card disk image** (`rootfs.wic.xz`) that already contains all
partitions. You flash that image to the SD card's raw device, then copy `BOOT.BIN` onto the first
FAT partition.

### Prepare the SD card

```{warning}
Flashing writes directly to a raw block device and cannot be undone. Be absolutely
certain you have identified the SD card's device node before running the commands below — if you
use the wrong device you risk destroying data on one of your hard drives.
```

1. Identify the SD card device. With the card **un**plugged, run `lsblk -o NAME,SIZE,RM,TYPE`,
   insert the card, and run it again. The new entry — typically `/dev/sdX`, with `RM=1`
   (removable) and a size matching your card — is your target. Replace `sdX` with that device,
   and `<target>` with your board, below.
2. Unmount any partitions the desktop auto-mounted:
   ```
   for p in /dev/sdX?*; do sudo umount "$p" 2>/dev/null; done
   ```
3. Flash the wic image to the raw device. With `bmaptool` (fast — only writes used blocks):
   ```
   sudo bmaptool copy --bmap Yocto/<target>/images/linux/rootfs.wic.bmap \
                            Yocto/<target>/images/linux/rootfs.wic.xz \
                            /dev/sdX
   ```
   Or, as a fallback with `dd`:
   ```
   xzcat Yocto/<target>/images/linux/rootfs.wic.xz \
       | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
   ```
4. **Install `BOOT.BIN` on the `esp` partition.** The EDF wic leaves the first FAT partition
   (`esp`) empty and installs `BOOT.BIN` onto the ext4 `boot` partition, which the BootROM cannot
   read. Since the BootROM loads `BOOT.BIN` from the first FAT partition, copy it onto `esp` by
   hand:
   ```
   sudo partprobe /dev/sdX
   sudo mkdir -p /mnt/sd_esp
   sudo mount /dev/sdX1 /mnt/sd_esp
   sudo cp Yocto/<target>/images/linux/BOOT.BIN /mnt/sd_esp/BOOT.BIN
   sync
   sudo umount /mnt/sd_esp && sudo rmdir /mnt/sd_esp
   ```
   (If your desktop auto-mounts the partitions, you can instead copy `BOOT.BIN` straight onto the
   `esp` mountpoint.)
5. Eject the card cleanly so pending writes flush: `sudo eject /dev/sdX`.

### Boot

1. Plug the SD card into the target board and set it to boot from SD card:
   * **ZCU104:** DIP switch SW6 must be set to 1000 (1=ON, 2=OFF, 3=OFF, 4=OFF)
2. Connect the [Ethernet FMC] to the FMC connector of the target board.
3. Connect the USB-UART to your PC and open a terminal emulator at 115200 baud (8N1) — see
   [UART terminal](#uart-terminal).
4. Optionally connect the board's own RJ45 to your LAN: the image runs an SSH server and the PS
   Ethernet port obtains an address by DHCP, so you can log in over the network instead of the
   UART.
5. Connect and power your hardware.

The image boots to a login prompt; log in as user **`amd-edf`**. The hostname is
`<board>-taxieth-2025-2` (for example `zcu104-taxieth-2025-2`). The commands below that touch
the interfaces need root, so prefix them with `sudo`.

## UART terminal

You will need to setup a terminal emulator to use the Linux command line over the USB-UART connection.
Connect with a baud rate of 115200.

### In Windows

You will need to find the comport for the USB-UART in Windows Device Manager. As a terminal emulator, you
can use the open source and free [Putty](https://www.putty.org/).

### In Linux

In Linux, you can find the USB-UART device by running `dmesg | grep tty`. Typically, the device will be
`/dev/ttyUSB0` or it could be followed by a different number (the ZCU104 enumerates several; the
console is normally the second one, `/dev/ttyUSB1`). To open a terminal emulator, you can use
the following command:

```
sudo screen /dev/ttyUSB1 115200
```

## The Ethernet FMC ports under Linux

Each port of the Ethernet FMC is one `taxi_rgmii_mac_N` + `axi_dma_N` pair in the design. The
`taxi_mac` driver creates one network interface per MAC; it owns the MAC register file and the
port's MDIO bus (the Marvell 88E1510 PHY is managed by the kernel's phylib) and moves frames
through the paired AXI DMA with the kernel's dmaengine API (the upstream `xilinx_dma` driver).
The board's own RJ45 (PS GEM) is a separate interface driven by the stock `macb` driver.

### Identifying the ports

The EDF root filesystem uses the systemd predictable-naming scheme, so the interfaces are named
`end<N>`; the number does **not** track the FMC port number, and the PS Ethernet port takes one
of the names too. Identify an Ethernet FMC port by its MAC address or by its driver:

| Ethernet FMC port | MAC address         | Driver     |
|-------------------|---------------------|------------|
| Port 0            | `00:0a:35:06:21:05` | `taxi_mac` |
| Port 1            | `00:0a:35:06:21:06` | `taxi_mac` |
| Port 2            | `00:0a:35:06:21:07` | `taxi_mac` |
| Port 3            | `00:0a:35:06:21:08` | `taxi_mac` |
| Board RJ45 (PS GEM3) | `00:0a:35:06:21:04` (ZCU104) | `macb` |

The MAC addresses come from the `port-config.dtsi` overlay (`Yocto/bsp/port-configs/ports-0123/`)
and the board `board-user.dtsi`; the port banner printed by `taxi-eth-test` lists the mapping, and
`ethtool -i eth1` shows the driver of an interface.

### Self-test: `taxi-eth-test`

`taxi-eth-test` is installed in every image. Run it as root with Ethernet FMC port 0 cabled to a
router with a DHCP server (the other ports may be left unconnected):

```
sudo taxi-eth-test
```

It finds the interfaces bound to the `taxi_mac` driver, brings them up, reports the link state,
negotiated speed and MAC of every port, waits for a DHCP lease and pings the gateway on every port
that has a cable, and prints the driver's `ethtool -S` counters. It ends with `VERDICT: PASS`
(exit code 0) when at least one port linked up, got a lease and answered the pings, otherwise
`VERDICT: FAIL` (exit code 1). With `--all-ports` every port must have a link — cable all four to
a switch with DHCP for that. Run `taxi-eth-test --help` for the timeouts and other options.

### Example usage

Substitute the `end<N>` name of the port you cabled in the commands below.

#### Enable port with a fixed IP address

```
sudo ip link set eth1 up
sudo ip addr add 192.168.3.30/24 dev eth1
```

Multiple ports that are managed under Linux must be assigned to **different subnets** (for
example eth1 = 192.168.1.10, eth2 = 192.168.2.10, ...), or the routing table cannot tell which
port to send through.

#### Enable port using DHCP

The EDF image runs `systemd-networkd` with DHCP enabled on every wired interface, so a port that
is brought up while cabled to a router obtains a lease by itself:

```
sudo ip link set eth1 up
ip -4 addr show eth1
```

#### Check port status

```
ip -s link show eth1          # up/down, MAC, packet and error counters
sudo ethtool eth1             # PHY link settings: speed, duplex, autonegotiation
sudo ethtool -S eth1          # the Taxi MAC hardware counters (rx_good, tx_good, FIFO overflows, ...)
```

The `ethtool -S` counters are read from the MAC's register file and accumulated by the driver;
the `flag_*` entries count how often a sticky error flag (TX underflow, FIFO overflow, bad FCS...)
was found set. `mac_link_speed` is the speed the MAC decodes from the RGMII in-band status.

#### Ping link partner using a specific port

```
ping -I eth1 192.168.3.1
```

#### Jumbo frames

The MTU can be raised to 8000 (the MAC's frame FIFOs are 8 kB and a whole frame must fit):

```
sudo ip link set eth1 mtu 8000
```

## Patches and known issues

The per-board fixups applied in the Yocto flow live under `Yocto/bsp/`, and the design-specific
recipes under `Yocto/common/meta-taxi-eth/`. See [advanced](advanced.md#yocto--edf-side) for the
full list. The notable ones:

* **ZCU104 FSBL VADJ patch (mandatory).** The stock 2025.2 Zynq UltraScale+ FSBL reads the FMC
  VADJ record from the wrong EEPROM and too few bytes of it, so it never powers the FMC and the
  PHYs stay dark. `Yocto/bsp/zcu104/meta-user/recipes-bsp/embeddedsw/` patches the FSBL sources
  before they are built.
* **Taxi MAC PHY wiring (`port-config.dtsi`).** The external Ethernet FMC PHYs are not described
  by the XSA, so the `ports-0123` overlay adds, for each port, the `taxi_mac` driver's compatible
  string, the DMA channels, the MAC address, the PHY handle and MDIO bus, and `phy-mode =
  "rgmii-rxid"`.
* **Kernel configuration (`bsp.cfg`).** `CONFIG_XILINX_DMA` (the AXI DMA dmaengine driver the
  `taxi_mac` driver depends on), the Marvell PHY drivers, the TI DP83867 driver for the ZCU104's
  own RJ45, and `CONFIG_NET_PKTGEN=m`.
* **ZCU104 SD card.** The generated device tree's `sdhci1` node lacks the properties the ZCU104's
  level shifter needs; `system-user.dtsi` restores them (without them the SD card times out at
  boot with `error -110`).
* **No hardware offloads.** The Taxi MAC has no checksum, segmentation or VLAN offload and no
  address filter (every frame on the wire crosses the DMA and is filtered by the kernel), so
  expect higher CPU load per packet than with a hardware-filtering MAC.

[Ethernet FMC]: https://docs.opsero.com/op031/datasheet/overview/
[supported Linux distributions]: https://docs.amd.com/r/en-US/ug1144-petalinux-tools-reference-guide/Setting-Up-Your-Environment
