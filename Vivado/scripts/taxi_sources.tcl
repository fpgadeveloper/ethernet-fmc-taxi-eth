# Source list for the Taxi transport library modules used by this design.
# Paths are relative to submodules/taxi (the pinned git submodule). Every file
# listed here is licensed under CERN-OHL-S-2.0 unless marked MIT; see
# submodules/README.md for the licensing summary.
#
# Usage: set taxi_dir <repo>/submodules/taxi ; source taxi_sources.tcl
#   -> $taxi_rtl  : SystemVerilog sources to add to sources_1
#   -> $taxi_xdc  : Tcl constraint scripts to add to constrs_1 (implementation only)

set taxi_rtl_rel {
    src/axis/rtl/taxi_axis_if.sv
    src/axis/rtl/taxi_axis_null_src.sv
    src/axis/rtl/taxi_axis_tie.sv
    src/axis/rtl/taxi_axis_adapter.sv
    src/axis/rtl/taxi_axis_arb_mux.sv
    src/axis/rtl/taxi_axis_async_fifo.sv
    src/axis/rtl/taxi_axis_async_fifo_adapter.sv
    src/axis/rtl/taxi_axis_pad.sv
    src/eth/rtl/taxi_axis_gmii_rx.sv
    src/eth/rtl/taxi_axis_gmii_tx.sv
    src/eth/rtl/taxi_eth_mac_1g.sv
    src/eth/rtl/taxi_eth_mac_1g_rgmii.sv
    src/eth/rtl/taxi_eth_mac_1g_rgmii_fifo.sv
    src/eth/rtl/taxi_eth_mac_stats.sv
    src/eth/rtl/taxi_mac_ctrl_rx.sv
    src/eth/rtl/taxi_mac_ctrl_tx.sv
    src/eth/rtl/taxi_mac_pause_ctrl_rx.sv
    src/eth/rtl/taxi_mac_pause_ctrl_tx.sv
    src/eth/rtl/taxi_rgmii_phy_if.sv
    src/io/rtl/taxi_iddr.sv
    src/io/rtl/taxi_oddr.sv
    src/io/rtl/taxi_ssio_ddr_in.sv
    src/lfsr/rtl/taxi_lfsr.sv
    src/lss/rtl/taxi_mdio_master.sv
    src/prim/rtl/taxi_arbiter.sv
    src/prim/rtl/taxi_penc.sv
    src/stats/rtl/taxi_stats_collect.sv
    src/sync/rtl/taxi_sync_reset.sv
    src/sync/rtl/taxi_sync_signal.sv
}

set taxi_xdc_rel {
    src/axis/syn/vivado/taxi_axis_async_fifo.tcl
    src/eth/syn/vivado/taxi_eth_mac_fifo.tcl
    src/eth/syn/vivado/taxi_rgmii_phy_if.tcl
    src/sync/syn/vivado/taxi_sync_reset.tcl
    src/sync/syn/vivado/taxi_sync_signal.tcl
}

set taxi_rtl {}
foreach f $taxi_rtl_rel { lappend taxi_rtl [file normalize "$taxi_dir/$f"] }
set taxi_xdc {}
foreach f $taxi_xdc_rel { lappend taxi_xdc [file normalize "$taxi_dir/$f"] }
