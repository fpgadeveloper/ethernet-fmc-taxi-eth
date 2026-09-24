# Design notes and lessons learned

This page records the non-obvious findings from bringing up the first target (ZCU104) of
this design. They are the things that cost real time and that anyone porting the design to
another board, extending the block design, or debugging a port is likely to run into again.
The sections follow the build chain: Vivado, RGMII timing, Linux driver, bare-metal software,
Yocto, and the bench.

## Vivado: using an RTL library from a block design

The Taxi MAC is instantiated as a **block-design module reference** (`taxi_rgmii_mac`) rather
than packaged as an IP. That keeps the Taxi sources untouched and visible, but the module
reference flow has rules that are not documented in one place:

* **The referenced top file must be Verilog, not SystemVerilog.** Vivado refuses a
  SystemVerilog top for a module reference (`[filemgmt 56-195] ... type SystemVerilog is not
  allowed as the top file in the reference`). Everything *below* the top may be SystemVerilog,
  which is why the cell is a thin Verilog-2001 shell (`Vivado/src/hdl/taxi_rgmii_mac.v`) over
  the SystemVerilog implementation (`taxi_rgmii_mac_core.sv`) that instantiates Taxi.
* **Module references are synthesized out of context**, and an `inout` port with an *inferred*
  tristate (`assign io = t ? 1'bz : o; assign i = io;`) loses its input side there: only the
  output buffer survives, the input reads as constant 0, and nothing warns you. On the bench
  this showed up as every MDIO read returning `0x0000` while the utilization report listed no
  input buffer for the MDIO pins. The fix is an explicit `IOBUF` primitive inside the module.
* **Vivado does not track the sources of a module reference.** After editing the wrapper,
  `synth_1` reports *Out-of-date* but the cell's own out-of-context run does not, and the next
  implementation silently reuses the old checkpoint. `Vivado/scripts/xsa.tcl` therefore resets
  every out-of-context synthesis run whenever `synth_1` is stale.
* Interface inference works from port names (`s_axi_*`, `s_axis_tx_*`, `m_axis_rx_*`) plus
  `X_INTERFACE_INFO` attributes on the shell; the RGMII pins are grouped into an `rgmii_rtl`
  interface so the external block-design ports get the same names the AXI Ethernet designs
  use (`rgmii_port_N_*`), and the ZCU104 pin constraints of those designs carry over verbatim.
* `apply_bd_automation` for AXI-Lite (`intc_ip {Auto}`) adopts any SmartConnect that already
  exists in the design, including one meant for the DMA masters. The DMA SmartConnect is
  created *after* the AXI-Lite automation for that reason.
* **XDC files do not support `foreach` (or other control flow).** The block is dropped with a
  CRITICAL WARNING and the constraints inside never apply; the first implementation of this
  design ran without any RGMII input delays or clock-route waivers because of that. Unroll the
  constraints, or put them in a `.tcl` constraint file.
* Taxi ships Tcl timing-constraint scripts for its CDC structures (`src/*/syn/vivado/*.tcl`).
  They locate cells by `ORIG_REF_NAME`, so they are added to the constraint set as
  *implementation-only* files and the hierarchy must not be flattened. One synchroniser is
  not covered by them — the `link_speed_sync_reg_1/2` chain in `taxi_eth_mac_1g_rgmii_fifo`
  (125 MHz transmit clock to the AXI clock) — and the target XDC constrains it itself.

## RGMII receive timing on UltraScale+

The receive side is where the design's timing is decided. Taxi's RGMII interface on
UltraScale+ is IBUF → BUFG → IDDRE1 with no delay element of its own, and the Ethernet FMC's
PHYs (Marvell 88E1510) are run with the RGMII **receive**-clock delay enabled (Linux
`phy-mode = "rgmii-rxid"`; the FPGA supplies the transmit delay through the 90° clock). At the
pins the data is therefore centre-aligned with the clock, and the only question is how much
later the clock reaches the IDDR than the data does.

* **Constraint form.** Describe the input in AMD's *centre-aligned DDR source-synchronous*
  form (`set_input_delay -max <half period − valid before edge>` / `-min <valid after edge>`,
  repeated with `-clock_fall -add_delay`). The negative "same-edge" form found in older RGMII
  constraint files makes Vivado run a zero-cycle hold check that can never pass with a
  BUFG-routed clock.
* **The clock insertion delay is the whole problem.** Its variation between the fast and slow
  process corners eats the data-valid window. Three levers close it, in this order:
  1. **Pick the right BUFGCE site.** Only a few BUFGCE sites of a clock region drive that
     region's distribution directly; the others detour through the routing track and add
     1 ns or more, with a matching corner spread. On the ZCU104, region X2Y4 (bank 67) is
     served directly by `BUFGCE_X1Y96` and `X1Y114`, region X2Y5 (bank 68) by `X1Y120`,
     `X1Y126`, `X1Y132` and `X1Y143`. Find them for a new board by comparing the BUFGCE
     output-net delays in a routed checkpoint.
  2. **Pin the clock tree**: `USER_CLOCK_ROOT <region>` and `CLOCK_LOW_FANOUT TRUE` on each
     RX clock net. Without `CLOCK_LOW_FANOUT` the placer built a different tree on every run
     and the margins moved by half a nanosecond between otherwise identical builds.
  3. **One IDELAYE3 per data/control pin** (TIME mode, 300 MHz IDELAYCTRL reference), with
     the delay tuned per port from the signoff report to centre the eye: about 600 ps for
     ports whose RXC is on a clock-capable pin, 1000–1100 ps for ports whose clock reaches its
     BUFGCE over general routing. `RX_IDELAY_PS` on the cell is that value; the maximum is
     1100 ps (`[DRC AVAL-174]`).
* Two tempting alternatives do **not** work: the IDELAYE3 + ODELAYE3 cascade (up to 2.2 ns) is
  not placeable in an input bit slice (`[DRC PDCN-2708]`, the return path cannot be routed),
  and feeding the IDELAY from the fabric (`DELAY_SRC = "DATAIN"`) adds a detour whose delay
  does not track the clock across corners and lands the IDELAY/IDDR in another bank.
* Ports whose RXC pin is not clock-capable (ZCU104 ports 1 and 3, LA01 and LA18) need
  `CLOCK_DEDICATED_ROUTE FALSE` on the IBUF output net; pins that sit on BITSLICE 0/6 of a byte
  the IDELAYCTRL calibrates need `UNAVAILABLE_DURING_CALIBRATION TRUE`. Both are in the
  ZCU104 XDC with comments.
* The MAC configuration registers (enables, IFG, maximum frame lengths) are written from the
  AXI clock domain and consumed in the transmit and receive domains; they are quasi-static
  and false-pathed into those clocks.
* Result on the ZCU104: every port meets setup with at least +0.37 ns and hold with at least
  +0.5 ns at signoff, and the transmit side needs no constraints beyond Taxi's own script
  (the 90° clock centres the eye by construction).

## KCU105 (Kintex UltraScale, MicroBlaze) bring-up notes

- **IDELAYCTRL reference must be exact.** The DDR4 controller's user clock on the
  KCU105 is 300.12 MHz (the MIG quantises the memory period), and IDELAYE3 in
  TIME mode rejects it with `[Timing 38-470]` on every delay element. A second
  MMCM cascaded off the 125 MHz `gtx_clk` makes an exact 300 MHz instead (the
  Kintex UltraScale −2 MMCM cannot reach the 1500 MHz VCO that produced 125/125@90/300
  from one MMCM on the ZCU104).
- **Same RX recipe, different numbers.** All four HPC receive clocks are on
  clock-capable pins, so `CLOCK_DEDICATED_ROUTE FALSE` is not needed; the eye sat
  about 0.5 ns early against the BUFGCE-routed clock, so all four ports use the
  maximum `RX_IDELAY_PS 1100`. BUFGCE sites and clock roots are pinned for
  run-to-run repeatability only.
- **SmartConnect between the MIG's 100 and 300 MHz user clocks** is analysed as a
  related-clock crossing with zero edge separation; hold closure there was
  placement luck until `CLOCK_DELAY_GROUP` on the two MIG BUFGs and a post-route
  `phys_opt_design` hold fix (mb-us only, in `build.tcl`) made it deterministic.
- **MicroBlaze caches are not enabled by the start-up code** in the 2025.2 SDT
  flow (MSR showed `ice=0 dce=0` at the first JTAG halt). With the app in DDR4 the
  xiltimer delay loop then ran ~30x slow and the 5 s autonegotiation wait never
  ended. `main()` enables both caches on `__MICROBLAZE__`; the D-cache is
  write-through, and the DMA descriptor rings stay cached because the AXI DMA
  driver flushes/invalidates each descriptor itself on non-A53 targets.
- **lwIP without a Xilinx MAC.** The lwip220 library refuses to configure when
  the design has no AMD Ethernet IP; the `EmbeddedSw.microblaze` overlay relaxes
  that check (the taxi_rgmii_mac cells are module references with no driver).
- **JTAG only.** `combine_bit_elf` stays false: the app (about 6 MB with the pbuf
  pool and descriptor space) cannot live in the 64 KB local memory, so the
  deliverable is `taxieth.bit` + `echo_server.elf` loaded with `fpga`/`dow`/`con`.
  `hw_server` detaches the `ftdi_sio` kernel driver from the on-board FT232H by itself.

## Linux driver (`taxi_mac`)

* **The AXI DMA soft reset is engine-wide.** The `xilinx_dma` dmaengine driver issues one from
  `terminate_all()`, and it re-enables interrupts only for the channel it is terminating, in
  `alloc_chan_resources()` (its own comment says so). A netdev driver that requests both
  channels once at probe therefore loses the transmit channel's interrupts the first time the
  interface is closed — the symptom is `TX timeout (ring head 63 tail 0)` after an `ip link set
  ... down/up` (or a network-namespace move), with MM2S `DMACR` showing the IRQ-enable bits
  clear. The driver requests and releases its channels on every open/close instead.
* The received length comes from the descriptor status through `dmaengine_result.residue`
  (`buffer length − residue`); the DMA's metadata "app words" only exist with AXI Ethernet.
* **`xlnx,irq-delay` is read as an 8-bit value** by `xilinx_dma` (`of_property_read_u8`). A
  32-bit cell (`<1>`) is silently ignored, the driver's coalescing threshold then equals the
  number of pending descriptors and a receive interrupt only fires per full batch of buffers
  (the bench showed exactly 129 frames delivered = one 128-buffer batch + 1). The overlay
  writes `xlnx,irq-delay = /bits/ 8 <1>;` on every S2MM channel node.
* Receive uses NAPI with GRO; delivering from the dmaengine callback with `netif_rx()` topped
  out around 820 Mb/s with per-CPU backlog drops, NAPI gives 934 Mb/s in and 940 Mb/s out.
* The MAC has no address filter, so the kernel sees every frame on the segment; on a busy
  network `rx_fifo_ovf` in `ethtool -S` is the first thing to watch.
* Testing a Taxi port on a board whose own RJ45 is on the same subnet is ambiguous: Linux
  routes by destination and answers ARP on any interface, so traffic "to eth1" may flow through
  the PS GEM. Put the port in its own network namespace to measure it (see [Yocto](yocto.md)).

## Bare-metal application (lwIP)

* **The lwIP library derives its checksum settings from the AMD MACs it finds in the
  hardware.** In this design the only AMD MAC is the unused PS GEM, which offloads checksums,
  so the generated `lwipopts.h` disabled IP/UDP/TCP checksum *generation* entirely and every
  DHCP discover left the Taxi MAC with a zero IP-header checksum. The
  `EmbeddedSw/.../lwipopts.h.in` overlay forces software checksum generation and checking.
  Any custom MAC used with this library needs the same override.
* `NO_SYS_NO_TIMERS` is on in the AMD port: `sys_check_timeouts()` does not exist, so the
  application drives `tcp_fasttmr/slowtmr` and the DHCP fine/coarse timers from the xiltimer
  tick itself.
* With four ports on one subnet, lwIP's `ip4_route()` ignores the source address and every
  reply would leave through the first netif that is up; the application installs
  `LWIP_HOOK_IP4_ROUTE_SRC` to route replies by the local address the connection was made to.
* The platform FSBL is built from the patched sources in `EmbeddedSw/lib/sw_apps/zynqmp_fsbl/`
  (registered as a local embedded-software repository by the build scripts). On the ZCU104
  that patch is what powers the FMC (VADJ); without it every MDIO read returns all ones.
* The AXI DMA descriptor rings live in a non-cached region (`Xil_SetTlbAttributes`), pbuf
  payloads are flushed before transmit and invalidated after receive; the DMAs are built
  with DRE so unaligned pbuf payloads are fine.

## Yocto / EDF

* The module-reference cells appear in the SDT `pl.dtsi` as generic nodes
  (`compatible = "xlnx,taxi-rgmii-mac-1.0"`); the port-config overlay overrides the
  `compatible`, adds the `dmas`/`phy-handle`/`mdio` properties and the fixed MAC addresses.
* The ZCU104 FSBL VADJ patch is applied to `fsbl-firmware` by a custom task that runs after
  the sources are copied, because the 2025.2 embeddedsw class runs `do_patch` on an empty
  work directory.
* `gen-machineconf parse-sdt` fails ("esw-conf configuration files are missing") when it runs
  in a shell that has the Vitis settings sourced (Vitis puts its own Python first on the
  PATH). The XSA-to-SDT step needs `xsct`, the machine-conf step needs a clean environment;
  if the runner's Yocto stage fails that way on your host, run `Yocto/scripts/configure-build.sh`
  with only the Vitis `bin` directory appended to a clean `PATH`, then re-run the stage.
* The build runner skips a stage whose products exist without checking their age against
  the XSA; after a hardware change delete `Yocto/<target>/images` (and the XSA copy in
  `Yocto/<target>/hw`) to force a rebuild.

## Bench debugging without software

The MAC's register file can be exercised over JTAG while any image runs, which is how the
MDIO and transmit-path problems above were separated from the software: with `xsct`, select
the `PSU` target and use `mrd -force` / `mwr -force` on the MAC registers (ID, STATUS,
counters, `MDIO_CMD`/`MDIO_RDATA`), and drive a scatter-gather descriptor chain in DDR
through the AXI DMA MM2S registers to push frames into a port. A port with a live link shows
`RX_GOOD` climbing on LAN broadcast traffic within seconds; a stalled transmit domain shows
up as descriptors that never complete once more than the transmit FIFO (8 KB) is queued.
