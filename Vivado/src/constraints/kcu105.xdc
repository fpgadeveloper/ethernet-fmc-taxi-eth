# Opsero Electronic Design Inc. Copyright 2026
#
# Constraints for the KCU105 (Rev 1.0) with the Ethernet FMC on the HPC connector
# ------------------------------------------------------------------------------
# Notes on the KCU105 HPC connector
#
# Ethernet FMC Port 0: LA00_CC, LA02-LA08   -> LA00_CC_P is a clock-capable pin
# Ethernet FMC Port 1: LA01_CC, LA06, LA09-LA16 -> LA01_CC_P is a clock-capable pin
# Ethernet FMC Port 2: LA17_CC, LA19-LA25   -> LA17_CC_P is a clock-capable pin
# Ethernet FMC Port 3: LA18_CC, LA26-LA32   -> LA18_CC_P is a clock-capable pin
#
# Unlike the ZCU104 LPC connector, every RGMII receive clock of this board lands
# on a clock-capable pin, so none of them needs CLOCK_DEDICATED_ROUTE FALSE and
# all four start from the same receive delay.

# Enable internal termination resistor on LVDS 125MHz ref_clk
set_property DIFF_TERM_ADV TERM_100 [get_ports ref_clk_clk_p]
set_property DIFF_TERM_ADV TERM_100 [get_ports ref_clk_clk_n]

# I/O standards
set_property IOSTANDARD LVDS [get_ports ref_clk_clk_p]
set_property IOSTANDARD LVDS [get_ports ref_clk_clk_n]
set_property IOSTANDARD LVCMOS18 [get_ports {ref_clk_fsel[0]}]
set_property IOSTANDARD LVCMOS18 [get_ports {ref_clk_oe[0]}]
set_property IOSTANDARD LVCMOS18 [get_ports {rgmii_port_*}]
set_property IOSTANDARD LVCMOS18 [get_ports {mdio_io_port_*}]
set_property IOSTANDARD LVCMOS18 [get_ports {reset_port_*}]

# Pin assignments
set_property PACKAGE_PIN H12 [get_ports ref_clk_clk_p]
set_property PACKAGE_PIN G12 [get_ports ref_clk_clk_n]
set_property PACKAGE_PIN D9 [get_ports {ref_clk_oe[0]}]
set_property PACKAGE_PIN B10 [get_ports {ref_clk_fsel[0]}]

# Port 0
set_property PACKAGE_PIN H11 [get_ports rgmii_port_0_rxc]
set_property PACKAGE_PIN G11 [get_ports rgmii_port_0_rx_ctl]
set_property PACKAGE_PIN K10 [get_ports {rgmii_port_0_rd[0]}]
set_property PACKAGE_PIN J10 [get_ports {rgmii_port_0_rd[1]}]
set_property PACKAGE_PIN A13 [get_ports {rgmii_port_0_rd[2]}]
set_property PACKAGE_PIN A12 [get_ports {rgmii_port_0_rd[3]}]
set_property PACKAGE_PIN K12 [get_ports rgmii_port_0_txc]
set_property PACKAGE_PIN E8 [get_ports rgmii_port_0_tx_ctl]
set_property PACKAGE_PIN L12 [get_ports {rgmii_port_0_td[0]}]
set_property PACKAGE_PIN J8 [get_ports {rgmii_port_0_td[1]}]
set_property PACKAGE_PIN H8 [get_ports {rgmii_port_0_td[2]}]
set_property PACKAGE_PIN F8 [get_ports {rgmii_port_0_td[3]}]
set_property PACKAGE_PIN L13 [get_ports mdio_io_port_0_mdc]
set_property PACKAGE_PIN C13 [get_ports mdio_io_port_0_mdio_io]
set_property PACKAGE_PIN K13 [get_ports reset_port_0]

# Port 1
set_property PACKAGE_PIN G9 [get_ports rgmii_port_1_rxc]
set_property PACKAGE_PIN F9 [get_ports rgmii_port_1_rx_ctl]
set_property PACKAGE_PIN D13 [get_ports {rgmii_port_1_rd[0]}]
set_property PACKAGE_PIN J9 [get_ports {rgmii_port_1_rd[1]}]
set_property PACKAGE_PIN K8 [get_ports {rgmii_port_1_rd[2]}]
set_property PACKAGE_PIN H9 [get_ports {rgmii_port_1_rd[3]}]
set_property PACKAGE_PIN J11 [get_ports rgmii_port_1_txc]
set_property PACKAGE_PIN D8 [get_ports rgmii_port_1_tx_ctl]
set_property PACKAGE_PIN D10 [get_ports {rgmii_port_1_td[0]}]
set_property PACKAGE_PIN K11 [get_ports {rgmii_port_1_td[1]}]
set_property PACKAGE_PIN B9 [get_ports {rgmii_port_1_td[2]}]
set_property PACKAGE_PIN A9 [get_ports {rgmii_port_1_td[3]}]
set_property PACKAGE_PIN C9 [get_ports mdio_io_port_1_mdc]
set_property PACKAGE_PIN A10 [get_ports mdio_io_port_1_mdio_io]
set_property PACKAGE_PIN C8 [get_ports reset_port_1]

# Port 2
set_property PACKAGE_PIN D24 [get_ports rgmii_port_2_rxc]
set_property PACKAGE_PIN B24 [get_ports rgmii_port_2_rx_ctl]
set_property PACKAGE_PIN A24 [get_ports {rgmii_port_2_rd[0]}]
set_property PACKAGE_PIN C21 [get_ports {rgmii_port_2_rd[1]}]
set_property PACKAGE_PIN G22 [get_ports {rgmii_port_2_rd[2]}]
set_property PACKAGE_PIN F22 [get_ports {rgmii_port_2_rd[3]}]
set_property PACKAGE_PIN F23 [get_ports rgmii_port_2_txc]
set_property PACKAGE_PIN D20 [get_ports rgmii_port_2_tx_ctl]
set_property PACKAGE_PIN C22 [get_ports {rgmii_port_2_td[0]}]
set_property PACKAGE_PIN G24 [get_ports {rgmii_port_2_td[1]}]
set_property PACKAGE_PIN F25 [get_ports {rgmii_port_2_td[2]}]
set_property PACKAGE_PIN F24 [get_ports {rgmii_port_2_td[3]}]
set_property PACKAGE_PIN E20 [get_ports mdio_io_port_2_mdc]
set_property PACKAGE_PIN D21 [get_ports mdio_io_port_2_mdio_io]
set_property PACKAGE_PIN E21 [get_ports reset_port_2]

# Port 3
set_property PACKAGE_PIN E22 [get_ports rgmii_port_3_rxc]
set_property PACKAGE_PIN E23 [get_ports rgmii_port_3_rx_ctl]
set_property PACKAGE_PIN G20 [get_ports {rgmii_port_3_rd[0]}]
set_property PACKAGE_PIN H21 [get_ports {rgmii_port_3_rd[1]}]
set_property PACKAGE_PIN F20 [get_ports {rgmii_port_3_rd[2]}]
set_property PACKAGE_PIN G21 [get_ports {rgmii_port_3_rd[3]}]
set_property PACKAGE_PIN B22 [get_ports rgmii_port_3_txc]
set_property PACKAGE_PIN C26 [get_ports rgmii_port_3_tx_ctl]
set_property PACKAGE_PIN A20 [get_ports {rgmii_port_3_td[0]}]
set_property PACKAGE_PIN B21 [get_ports {rgmii_port_3_td[1]}]
set_property PACKAGE_PIN B25 [get_ports {rgmii_port_3_td[2]}]
set_property PACKAGE_PIN A25 [get_ports {rgmii_port_3_td[3]}]
set_property PACKAGE_PIN B26 [get_ports mdio_io_port_3_mdc]
set_property PACKAGE_PIN E26 [get_ports mdio_io_port_3_mdio_io]
set_property PACKAGE_PIN D26 [get_ports reset_port_3]

# RGMII outputs: fast slew, 12 mA
set_property SLEW FAST [get_ports {rgmii_port_*_td[*] rgmii_port_*_txc rgmii_port_*_tx_ctl}]
set_property DRIVE 12 [get_ports {rgmii_port_*_td[*] rgmii_port_*_txc rgmii_port_*_tx_ctl}]

# BITSLICE0/6 of a byte lane undergoing built-in self calibration (BISC) is not
# available during calibration: acknowledge it, these signals are only needed
# after the PHYs come out of reset.
set_property UNAVAILABLE_DURING_CALIBRATION TRUE [get_ports mdio_io_port_3_mdio_io]

# IDELAY group: the util_idelay_ctrl in the block design serves every RGMII receive IDELAYE3
set_property IODELAY_GROUP taxi_rgmii_idelay [get_cells -hierarchical -filter {NAME =~ *util_idelay_ctrl_0/inst/dlyctrl}]
set_property IODELAY_GROUP taxi_rgmii_idelay [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_*/g_rx_idelay* && PRIMITIVE_TYPE =~ I/O.DELAY.IDELAYE3}]

# RGMII receive clocks
create_clock -period 8.000 -name rgmii_port_0_rx_clk -waveform {0.000 4.000} [get_ports rgmii_port_0_rxc]
create_clock -period 8.000 -name rgmii_port_1_rx_clk -waveform {0.000 4.000} [get_ports rgmii_port_1_rxc]
create_clock -period 8.000 -name rgmii_port_2_rx_clk -waveform {0.000 4.000} [get_ports rgmii_port_2_rxc]
create_clock -period 8.000 -name rgmii_port_3_rx_clk -waveform {0.000 4.000} [get_ports rgmii_port_3_rxc]

# RGMII receive data: the PHYs (Marvell 88E1510) apply the RGMII RX clock internal
# delay (~2 ns), so at the pins the data is centre-aligned with the clock: each
# data bit is valid from ~1.2 ns after one clock edge until ~1.2 ns before the
# next edge. Written in the AMD "centre-aligned DDR source-synchronous input"
# form: max = half period minus the valid-before-edge time, min = valid-after-edge
# time, for both clock edges.
set_input_delay -clock [get_clocks rgmii_port_0_rx_clk] -max 2.8 [get_ports {rgmii_port_0_rd[*] rgmii_port_0_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_0_rx_clk] -min 1.2 [get_ports {rgmii_port_0_rd[*] rgmii_port_0_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_0_rx_clk] -clock_fall -max 2.8 -add_delay [get_ports {rgmii_port_0_rd[*] rgmii_port_0_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_0_rx_clk] -clock_fall -min 1.2 -add_delay [get_ports {rgmii_port_0_rd[*] rgmii_port_0_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_1_rx_clk] -max 2.8 [get_ports {rgmii_port_1_rd[*] rgmii_port_1_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_1_rx_clk] -min 1.2 [get_ports {rgmii_port_1_rd[*] rgmii_port_1_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_1_rx_clk] -clock_fall -max 2.8 -add_delay [get_ports {rgmii_port_1_rd[*] rgmii_port_1_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_1_rx_clk] -clock_fall -min 1.2 -add_delay [get_ports {rgmii_port_1_rd[*] rgmii_port_1_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_2_rx_clk] -max 2.8 [get_ports {rgmii_port_2_rd[*] rgmii_port_2_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_2_rx_clk] -min 1.2 [get_ports {rgmii_port_2_rd[*] rgmii_port_2_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_2_rx_clk] -clock_fall -max 2.8 -add_delay [get_ports {rgmii_port_2_rd[*] rgmii_port_2_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_2_rx_clk] -clock_fall -min 1.2 -add_delay [get_ports {rgmii_port_2_rd[*] rgmii_port_2_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_3_rx_clk] -max 2.8 [get_ports {rgmii_port_3_rd[*] rgmii_port_3_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_3_rx_clk] -min 1.2 [get_ports {rgmii_port_3_rd[*] rgmii_port_3_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_3_rx_clk] -clock_fall -max 2.8 -add_delay [get_ports {rgmii_port_3_rd[*] rgmii_port_3_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_3_rx_clk] -clock_fall -min 1.2 -add_delay [get_ports {rgmii_port_3_rd[*] rgmii_port_3_rx_ctl}]

# RX clock distribution. Each RX clock domain is small (~260 loads: the MAC
# receive path and the RX FIFO write side), so CLOCK_LOW_FANOUT keeps all of its
# loads in the root's clock region: the clock tree is then a single-region tree
# and its delay to the capture IDDRs is the same from run to run (without it the
# router sometimes enters the clock distribution through a routing track, which
# eats the hold margin).
#
# The BUFGCE of each RX clock is pinned to the site the router chose in the
# first routed run, and the clock root to the clock region of the port's pins
# (ports 0/1 land in X2Y2, ports 2/3 in X2Y3). All four measured the same
# insertion delay to within 80 ps, so the sites are equivalent here; pinning
# them only keeps the delay -- and with it the RX_IDELAY_PS values tuned against
# it in bd_mb-us.tcl -- identical from run to run.
set_property LOC BUFGCE_X1Y55 [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_0/*rx_ssio_ddr_inst/clk_bufg}]
set_property LOC BUFGCE_X1Y48 [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_1/*rx_ssio_ddr_inst/clk_bufg}]
set_property LOC BUFGCE_X1Y81 [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_2/*rx_ssio_ddr_inst/clk_bufg}]
set_property LOC BUFGCE_X1Y78 [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_3/*rx_ssio_ddr_inst/clk_bufg}]
set_property USER_CLOCK_ROOT X2Y2 [get_nets -of_objects [get_pins -filter {REF_PIN_NAME == O} -of_objects [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_0/*rx_ssio_ddr_inst/clk_bufg}]]]
set_property USER_CLOCK_ROOT X2Y2 [get_nets -of_objects [get_pins -filter {REF_PIN_NAME == O} -of_objects [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_1/*rx_ssio_ddr_inst/clk_bufg}]]]
set_property USER_CLOCK_ROOT X2Y3 [get_nets -of_objects [get_pins -filter {REF_PIN_NAME == O} -of_objects [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_2/*rx_ssio_ddr_inst/clk_bufg}]]]
set_property USER_CLOCK_ROOT X2Y3 [get_nets -of_objects [get_pins -filter {REF_PIN_NAME == O} -of_objects [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_3/*rx_ssio_ddr_inst/clk_bufg}]]]
set_property CLOCK_LOW_FANOUT TRUE [get_nets -of_objects [get_pins -filter {REF_PIN_NAME == O} -of_objects [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_0/*rx_ssio_ddr_inst/clk_bufg}]]]
set_property CLOCK_LOW_FANOUT TRUE [get_nets -of_objects [get_pins -filter {REF_PIN_NAME == O} -of_objects [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_1/*rx_ssio_ddr_inst/clk_bufg}]]]
set_property CLOCK_LOW_FANOUT TRUE [get_nets -of_objects [get_pins -filter {REF_PIN_NAME == O} -of_objects [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_2/*rx_ssio_ddr_inst/clk_bufg}]]]
set_property CLOCK_LOW_FANOUT TRUE [get_nets -of_objects [get_pins -filter {REF_PIN_NAME == O} -of_objects [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_3/*rx_ssio_ddr_inst/clk_bufg}]]]

# The memory controller drives two user clocks out of one MMCM: c0_ddr4_ui_clk
# (300 MHz, the DDR4 AXI slave) and addn_ui_clkout1 (100 MHz, the processor,
# AXI-Lite and the DMAs). The AXI SmartConnect crosses between them with its
# related-clocks (not asynchronous) logic, so those hold checks are at zero
# edge separation and pass only while the two clock trees keep matched insertion
# delay. Put both nets in one clock delay group so the router balances them.
set_property CLOCK_DELAY_GROUP ddr4_ui_clks [get_nets -of_objects [get_pins -filter {REF_PIN_NAME == O} -of_objects [get_cells -hierarchical -filter {NAME =~ *u_ddr4_infrastructure/u_bufg_divClk}]]]
set_property CLOCK_DELAY_GROUP ddr4_ui_clks [get_nets -of_objects [get_pins -filter {REF_PIN_NAME == O} -of_objects [get_cells -hierarchical -filter {NAME =~ *u_ddr4_infrastructure/u_bufg_addn_ui_clk_1}]]]

# The MAC configuration registers (enables, IFG, max frame lengths) live in the
# AXI-Lite clock domain and are quasi-static: exclude their crossings into the
# transmit (125 MHz) and receive clock domains from timing.
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_*/inst/core/ctrl_*_reg_reg* || NAME =~ *taxi_rgmii_mac_*/inst/core/tx_ifg_reg_reg* || NAME =~ *taxi_rgmii_mac_*/inst/core/tx_max_len_reg_reg* || NAME =~ *taxi_rgmii_mac_*/inst/core/rx_max_len_reg_reg*}] -to [get_clocks {rgmii_port_0_rx_clk rgmii_port_1_rx_clk rgmii_port_2_rx_clk rgmii_port_3_rx_clk clk_out1_taxieth_clk_wiz_0_0 clk_out2_taxieth_clk_wiz_0_0}]

# The MAC's link_speed (from the RGMII in-band status, 125 MHz gtx_clk domain) is
# resynchronised into the AXI-Lite clock domain by a two-flop synchroniser in
# taxi_eth_mac_1g_rgmii_fifo (link_speed_sync_reg_1/2) that the Taxi constraint
# scripts do not cover: constrain it like Taxi's other synchronisers (ASYNC_REG,
# datapath-only max delay of one source clock period).
set_property ASYNC_REG TRUE [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_*/inst/core/mac_inst/link_speed_sync_reg_*_reg[*]}]
set_max_delay -datapath_only -from [get_clocks clk_out1_taxieth_clk_wiz_0_0] -to [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_*/inst/core/mac_inst/link_speed_sync_reg_1_reg[*]}] 8.000

# The IDELAYCTRL reset comes from the reset synchroniser of its own 300 MHz
# reference clock; it is held for many cycles, so its recovery/removal against
# that reference is a false path.
set_false_path -to [get_pins -hierarchical -filter {NAME =~ *util_idelay_ctrl_0/*dlyctrl*/RST}]

# PHY resets and the FMC clock control lines are static
set_false_path -to [get_ports {reset_port_* ref_clk_oe[0] ref_clk_fsel[0]}]
# MDIO is a slow (2.5 MHz) software-driven bus
set_false_path -to [get_ports {mdio_io_port_*}]
set_false_path -from [get_ports {mdio_io_port_*_mdio_io}]

# Configuration settings for the KCU105 (boot from the Quad SPI flash)
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property CONFIG_VOLTAGE 1.8 [current_design]
set_property CFGBVS GND [current_design]
set_property BITSTREAM.CONFIG.SPI_32BIT_ADDR YES [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
