# Third-party submodules and their licenses

This reference design is published by Opsero under the **MIT license** (see
`../LICENSE`). It depends on one third-party component, brought in as a git
submodule so that the boundary between Opsero's MIT-licensed sources and the
third-party sources is unambiguous:

| submodule | upstream | license |
|-----------|----------|---------|
| `submodules/taxi` | https://github.com/fpganinja/taxi (FPGA Ninja, LLC) | **CERN-OHL-S-2.0** (dual-licensed: CERN Open Hardware Licence v2 Strongly Reciprocal, or a paid commercial license from FPGA Ninja) — a few files are MIT, see below |

Nothing under `submodules/` is modified. Everything outside `submodules/` is
Opsero's and is MIT-licensed, including the wrapper that instantiates the Taxi
modules (`Vivado/src/hdl/taxi_rgmii_mac.v` and `taxi_rgmii_mac_core.sv`), the block design, constraints,
software and build scripts.

## What this design uses from Taxi

The Ethernet MAC of every port is built from the Taxi transport library instead
of the AMD AXI 1G/2.5G Ethernet Subsystem. The exact source files pulled into
the Vivado project are enumerated in `../Vivado/scripts/taxi_sources.tcl`;
they are, by function:

| function | Taxi module(s) | files | license |
|----------|----------------|-------|---------|
| 1G MAC + RGMII PHY interface + async FIFOs (the per-port MAC) | `taxi_eth_mac_1g_rgmii_fifo`, `taxi_eth_mac_1g_rgmii`, `taxi_eth_mac_1g`, `taxi_axis_gmii_rx/tx`, `taxi_rgmii_phy_if`, `taxi_ssio_ddr_in`, `taxi_iddr`, `taxi_oddr` | `src/eth/rtl/`, `src/io/rtl/` | CERN-OHL-S-2.0 |
| MAC control / pause / statistics (compiled in, disabled by parameter) | `taxi_mac_ctrl_rx/tx`, `taxi_mac_pause_ctrl_rx/tx`, `taxi_eth_mac_stats`, `taxi_stats_collect`, `taxi_axis_arb_mux`, `taxi_arbiter`, `taxi_penc`, `taxi_lfsr` | `src/eth/rtl/`, `src/stats/rtl/`, `src/prim/rtl/`, `src/lfsr/rtl/` | CERN-OHL-S-2.0 |
| AXI-Stream FIFOs and width adapters between the MAC and the AXI DMA | `taxi_axis_async_fifo`, `taxi_axis_async_fifo_adapter`, `taxi_axis_adapter`, `taxi_axis_pad` | `src/axis/rtl/` | CERN-OHL-S-2.0 |
| Reset / signal synchronisers | `taxi_sync_reset`, `taxi_sync_signal` | `src/sync/rtl/` | CERN-OHL-S-2.0 |
| MDIO (Clause 22) master for the PHY management bus | `taxi_mdio_master` | `src/lss/rtl/` | CERN-OHL-S-2.0 |
| AXI-Stream SystemVerilog interface definition and tie-off helpers | `taxi_axis_if`, `taxi_axis_null_src`, `taxi_axis_tie` | `src/axis/rtl/` | MIT |
| Vivado timing-constraint scripts for the CDC paths of the modules above | — | `src/axis/syn/vivado/taxi_axis_async_fifo.tcl`, `src/eth/syn/vivado/taxi_eth_mac_fifo.tcl`, `src/eth/syn/vivado/taxi_rgmii_phy_if.tcl`, `src/sync/syn/vivado/taxi_sync_reset.tcl`, `src/sync/syn/vivado/taxi_sync_signal.tcl` | CERN-OHL-S-2.0 |

Every file carries an SPDX header stating its own license; the table above was
compiled from those headers at the pinned commit.

## What the CERN-OHL-S-2.0 means for you

CERN-OHL-S is *strongly reciprocal*: if you distribute a product (including a
bitstream) that contains the Taxi sources or a design derived from them, you
must make the complete source of that design available under the same license
on request, including your modifications. The MIT-licensed parts of this
repository do not change that obligation for the Taxi-derived part of the
design. If that is not acceptable for your product, FPGA Ninja offers a
commercial license for Taxi (info@fpga.ninja) — see the upstream README.

The AMD IP used alongside Taxi in the block design (Zynq UltraScale+ PS, AXI
DMA, AXI interconnect, clocking wizard, processor system reset) is provided by
AMD under the Vivado tool license and needs no additional IP license.

## Pinned version

The submodule is pinned to a specific Taxi commit (recorded in this
repository's git tree; `git submodule status` prints it). Update it
deliberately — Taxi is under active development and module interfaces change.

```
git submodule update --init --recursive
```
