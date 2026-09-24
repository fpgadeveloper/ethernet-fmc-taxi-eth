# Opsero Electronic Design Inc. Copyright 2026
#
# Constraints for the ZCU104 (Rev 1.0) with the Ethernet FMC on the LPC connector
# ------------------------------------------------------------------------------
# Notes on ZCU104 LPC connector
#
# Ethernet FMC Port 0: LA00, LA02-LA08 -> Bank 67, LA00 on a global clock capable pin
# Ethernet FMC Port 1: LA01, LA06, LA09-LA16 -> Bank 67, LA01 NOT on a global clock capable pin
# Ethernet FMC Port 2: LA17, LA19-LA25 -> Bank 68, LA17 on a global clock capable pin
# Ethernet FMC Port 3: LA18, LA26-LA32 -> Bank 68, LA18 NOT on a global clock capable pin

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
set_property PACKAGE_PIN E15 [get_ports ref_clk_clk_p]
set_property PACKAGE_PIN E14 [get_ports ref_clk_clk_n]
set_property PACKAGE_PIN G15 [get_ports {ref_clk_oe[0]}]
set_property PACKAGE_PIN C13 [get_ports {ref_clk_fsel[0]}]

# Port 0
set_property PACKAGE_PIN F17 [get_ports rgmii_port_0_rxc]
set_property PACKAGE_PIN F16 [get_ports rgmii_port_0_rx_ctl]
set_property PACKAGE_PIN L20 [get_ports {rgmii_port_0_rd[0]}]
set_property PACKAGE_PIN K20 [get_ports {rgmii_port_0_rd[1]}]
set_property PACKAGE_PIN K19 [get_ports {rgmii_port_0_rd[2]}]
set_property PACKAGE_PIN K18 [get_ports {rgmii_port_0_rd[3]}]
set_property PACKAGE_PIN L16 [get_ports rgmii_port_0_txc]
set_property PACKAGE_PIN J15 [get_ports rgmii_port_0_tx_ctl]
set_property PACKAGE_PIN L17 [get_ports {rgmii_port_0_td[0]}]
set_property PACKAGE_PIN E18 [get_ports {rgmii_port_0_td[1]}]
set_property PACKAGE_PIN E17 [get_ports {rgmii_port_0_td[2]}]
set_property PACKAGE_PIN J16 [get_ports {rgmii_port_0_td[3]}]
set_property PACKAGE_PIN K17 [get_ports mdio_io_port_0_mdc]
set_property PACKAGE_PIN G19 [get_ports mdio_io_port_0_mdio_io]
set_property PACKAGE_PIN J17 [get_ports reset_port_0]

# Port 1
set_property PACKAGE_PIN H18 [get_ports rgmii_port_1_rxc]
set_property PACKAGE_PIN H17 [get_ports rgmii_port_1_rx_ctl]
set_property PACKAGE_PIN H19 [get_ports {rgmii_port_1_rd[0]}]
set_property PACKAGE_PIN H16 [get_ports {rgmii_port_1_rd[1]}]
set_property PACKAGE_PIN K15 [get_ports {rgmii_port_1_rd[2]}]
set_property PACKAGE_PIN G16 [get_ports {rgmii_port_1_rd[3]}]
set_property PACKAGE_PIN A12 [get_ports rgmii_port_1_txc]
set_property PACKAGE_PIN D16 [get_ports rgmii_port_1_tx_ctl]
set_property PACKAGE_PIN F18 [get_ports {rgmii_port_1_td[0]}]
set_property PACKAGE_PIN A13 [get_ports {rgmii_port_1_td[1]}]
set_property PACKAGE_PIN D17 [get_ports {rgmii_port_1_td[2]}]
set_property PACKAGE_PIN C17 [get_ports {rgmii_port_1_td[3]}]
set_property PACKAGE_PIN F15 [get_ports mdio_io_port_1_mdc]
set_property PACKAGE_PIN C12 [get_ports mdio_io_port_1_mdio_io]
set_property PACKAGE_PIN C16 [get_ports reset_port_1]

# Port 2
set_property PACKAGE_PIN F11 [get_ports rgmii_port_2_rxc]
set_property PACKAGE_PIN F12 [get_ports rgmii_port_2_rx_ctl]
set_property PACKAGE_PIN E12 [get_ports {rgmii_port_2_rd[0]}]
set_property PACKAGE_PIN D12 [get_ports {rgmii_port_2_rd[1]}]
set_property PACKAGE_PIN B11 [get_ports {rgmii_port_2_rd[2]}]
set_property PACKAGE_PIN A11 [get_ports {rgmii_port_2_rd[3]}]
set_property PACKAGE_PIN B10 [get_ports rgmii_port_2_txc]
set_property PACKAGE_PIN C7 [get_ports rgmii_port_2_tx_ctl]
set_property PACKAGE_PIN C11 [get_ports {rgmii_port_2_td[0]}]
set_property PACKAGE_PIN H13 [get_ports {rgmii_port_2_td[1]}]
set_property PACKAGE_PIN H12 [get_ports {rgmii_port_2_td[2]}]
set_property PACKAGE_PIN A10 [get_ports {rgmii_port_2_td[3]}]
set_property PACKAGE_PIN B6 [get_ports mdio_io_port_2_mdc]
set_property PACKAGE_PIN C6 [get_ports mdio_io_port_2_mdio_io]
set_property PACKAGE_PIN A6 [get_ports reset_port_2]

# Port 3
set_property PACKAGE_PIN D11 [get_ports rgmii_port_3_rxc]
set_property PACKAGE_PIN D10 [get_ports rgmii_port_3_rx_ctl]
set_property PACKAGE_PIN B9 [get_ports {rgmii_port_3_rd[0]}]
set_property PACKAGE_PIN A8 [get_ports {rgmii_port_3_rd[1]}]
set_property PACKAGE_PIN B8 [get_ports {rgmii_port_3_rd[2]}]
set_property PACKAGE_PIN A7 [get_ports {rgmii_port_3_rd[3]}]
set_property PACKAGE_PIN L13 [get_ports rgmii_port_3_txc]
set_property PACKAGE_PIN E9 [get_ports rgmii_port_3_tx_ctl]
set_property PACKAGE_PIN J10 [get_ports {rgmii_port_3_td[0]}]
set_property PACKAGE_PIN M13 [get_ports {rgmii_port_3_td[1]}]
set_property PACKAGE_PIN F7 [get_ports {rgmii_port_3_td[2]}]
set_property PACKAGE_PIN E7 [get_ports {rgmii_port_3_td[3]}]
set_property PACKAGE_PIN D9 [get_ports mdio_io_port_3_mdc]
set_property PACKAGE_PIN F8 [get_ports mdio_io_port_3_mdio_io]
set_property PACKAGE_PIN E8 [get_ports reset_port_3]

# RGMII outputs: fast slew, 12 mA
set_property SLEW FAST [get_ports {rgmii_port_*_td[*] rgmii_port_*_txc rgmii_port_*_tx_ctl}]
set_property DRIVE 12 [get_ports {rgmii_port_*_td[*] rgmii_port_*_txc rgmii_port_*_tx_ctl}]

# The RX clocks of ports 1 and 3 arrive on pins that are not global clock capable:
# allow the (sub-optimal) route from the IBUF to the BUFG.
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_pins -filter {DIRECTION == OUT} -of_objects [get_cells -of_objects [get_nets -of_objects [get_ports rgmii_port_1_rxc]] -filter {REF_NAME =~ IBUF*}]]]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_pins -filter {DIRECTION == OUT} -of_objects [get_cells -of_objects [get_nets -of_objects [get_ports rgmii_port_3_rxc]] -filter {REF_NAME =~ IBUF*}]]]

# BITSLICE0/1 not available during built-in self calibration (BISC) of the byte
# lane used by the IDELAYCTRL: acknowledge, these signals are only needed after
# the PHYs come out of reset.
set_property UNAVAILABLE_DURING_CALIBRATION TRUE [get_ports rgmii_port_2_tx_ctl]
set_property UNAVAILABLE_DURING_CALIBRATION TRUE [get_ports rgmii_port_2_txc]
set_property UNAVAILABLE_DURING_CALIBRATION TRUE [get_ports rgmii_port_1_rxc]
set_property UNAVAILABLE_DURING_CALIBRATION TRUE [get_ports rgmii_port_3_rxc]

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
# data bit is valid from ~1.2 ns after one clock edge (1.6 ns on ports 1/3, whose
# traces are shorter) until ~1.2 ns before the next edge. Written in the AMD
# "centre-aligned DDR source-synchronous input" form: max = half period minus the
# valid-before-edge time, min = valid-after-edge time, for both clock edges.
set_input_delay -clock [get_clocks rgmii_port_0_rx_clk] -max 2.8 [get_ports {rgmii_port_0_rd[*] rgmii_port_0_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_0_rx_clk] -min 1.2 [get_ports {rgmii_port_0_rd[*] rgmii_port_0_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_0_rx_clk] -clock_fall -max 2.8 -add_delay [get_ports {rgmii_port_0_rd[*] rgmii_port_0_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_0_rx_clk] -clock_fall -min 1.2 -add_delay [get_ports {rgmii_port_0_rd[*] rgmii_port_0_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_1_rx_clk] -max 2.8 [get_ports {rgmii_port_1_rd[*] rgmii_port_1_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_1_rx_clk] -min 1.6 [get_ports {rgmii_port_1_rd[*] rgmii_port_1_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_1_rx_clk] -clock_fall -max 2.8 -add_delay [get_ports {rgmii_port_1_rd[*] rgmii_port_1_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_1_rx_clk] -clock_fall -min 1.6 -add_delay [get_ports {rgmii_port_1_rd[*] rgmii_port_1_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_2_rx_clk] -max 2.8 [get_ports {rgmii_port_2_rd[*] rgmii_port_2_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_2_rx_clk] -min 1.2 [get_ports {rgmii_port_2_rd[*] rgmii_port_2_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_2_rx_clk] -clock_fall -max 2.8 -add_delay [get_ports {rgmii_port_2_rd[*] rgmii_port_2_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_2_rx_clk] -clock_fall -min 1.2 -add_delay [get_ports {rgmii_port_2_rd[*] rgmii_port_2_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_3_rx_clk] -max 2.8 [get_ports {rgmii_port_3_rd[*] rgmii_port_3_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_3_rx_clk] -min 1.6 [get_ports {rgmii_port_3_rd[*] rgmii_port_3_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_3_rx_clk] -clock_fall -max 2.8 -add_delay [get_ports {rgmii_port_3_rd[*] rgmii_port_3_rx_ctl}]
set_input_delay -clock [get_clocks rgmii_port_3_rx_clk] -clock_fall -min 1.6 -add_delay [get_ports {rgmii_port_3_rd[*] rgmii_port_3_rx_ctl}]

# RX clock distribution. Each RX clock BUFGCE is LOC'd in the clock region of its
# pin (bank 67 = X2Y4 for ports 0/1, bank 68 = X2Y5 for ports 2/3) and the clock
# root is pinned to that region, so the clock insertion to the capture IDDRs (in
# the pins' bit slices, same region) is short and repeatable. Only some BUFGCE
# sites of a region drive that region's distribution directly (~0.3-0.6 ns to the
# IDDRs); the others detour through the routing track (~1.0-1.7 ns) and with them
# the RX eye cannot be centred at every corner. Sites found by a placement scan in
# the routed design: X2Y4 -> Y96/Y114 (short), Y98/Y102/Y108/Y117 (long);
# X2Y5 -> Y120/Y126/Y132/Y143 (short), Y136/Y140 (long). Ports 0/2 are on
# clock-capable pins (dedicated IBUF->BUFGCE route); ports 1/3 reach their BUFGCE
# over general routing (CLOCK_DEDICATED_ROUTE FALSE above, ~1.2 ns).
set_property LOC BUFGCE_X1Y96 [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_0/*rx_ssio_ddr_inst/clk_bufg}]
set_property LOC BUFGCE_X1Y103 [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_1/*rx_ssio_ddr_inst/clk_bufg}]
set_property LOC BUFGCE_X1Y120 [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_2/*rx_ssio_ddr_inst/clk_bufg}]
set_property LOC BUFGCE_X1Y127 [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_3/*rx_ssio_ddr_inst/clk_bufg}]
# Each RX clock domain is small (~260 loads: the MAC receive path and the RX FIFO
# write side), so CLOCK_LOW_FANOUT keeps all of its loads in the root's clock
# region: the clock tree is then a single-region tree and its delay to the IDDRs
# is the same from run to run (without it the router sometimes enters the
# distribution through a routing track, +0.3 ns fast / +0.5 ns slow, which eats
# the hold margin of the ports on clock-capable pins).
set_property USER_CLOCK_ROOT X2Y4 [get_nets -of_objects [get_pins -filter {REF_PIN_NAME == O} -of_objects [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_0/*rx_ssio_ddr_inst/clk_bufg}]]]
set_property CLOCK_LOW_FANOUT TRUE [get_nets -of_objects [get_pins -filter {REF_PIN_NAME == O} -of_objects [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_0/*rx_ssio_ddr_inst/clk_bufg}]]]
set_property USER_CLOCK_ROOT X2Y4 [get_nets -of_objects [get_pins -filter {REF_PIN_NAME == O} -of_objects [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_1/*rx_ssio_ddr_inst/clk_bufg}]]]
set_property CLOCK_LOW_FANOUT TRUE [get_nets -of_objects [get_pins -filter {REF_PIN_NAME == O} -of_objects [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_1/*rx_ssio_ddr_inst/clk_bufg}]]]
set_property USER_CLOCK_ROOT X2Y5 [get_nets -of_objects [get_pins -filter {REF_PIN_NAME == O} -of_objects [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_2/*rx_ssio_ddr_inst/clk_bufg}]]]
set_property CLOCK_LOW_FANOUT TRUE [get_nets -of_objects [get_pins -filter {REF_PIN_NAME == O} -of_objects [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_2/*rx_ssio_ddr_inst/clk_bufg}]]]
set_property USER_CLOCK_ROOT X2Y5 [get_nets -of_objects [get_pins -filter {REF_PIN_NAME == O} -of_objects [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_3/*rx_ssio_ddr_inst/clk_bufg}]]]
set_property CLOCK_LOW_FANOUT TRUE [get_nets -of_objects [get_pins -filter {REF_PIN_NAME == O} -of_objects [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_3/*rx_ssio_ddr_inst/clk_bufg}]]]

# The MAC configuration registers (enables, IFG, max frame lengths) live in the
# AXI-Lite clock domain and are quasi-static: exclude their crossings into the
# transmit (125 MHz) and receive clock domains from timing.
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_*/inst/core/ctrl_*_reg_reg* || NAME =~ *taxi_rgmii_mac_*/inst/core/tx_ifg_reg_reg* || NAME =~ *taxi_rgmii_mac_*/inst/core/tx_max_len_reg_reg* || NAME =~ *taxi_rgmii_mac_*/inst/core/rx_max_len_reg_reg*}] -to [get_clocks {rgmii_port_0_rx_clk rgmii_port_1_rx_clk rgmii_port_2_rx_clk rgmii_port_3_rx_clk clk_out1_taxieth_clk_wiz_0_0 clk_out2_taxieth_clk_wiz_0_0}]

# The MAC's link_speed (from the RGMII in-band status, 125 MHz gtx_clk domain) is
# resynchronised into the AXI-Lite clock domain by a two-flop synchroniser in
# taxi_eth_mac_1g_rgmii_fifo (link_speed_sync_reg_1/2) that the Taxi constraint
# scripts do not cover: constrain it like Taxi's other synchronisers (ASYNC_REG,
# datapath-only max delay of one source clock period) instead of leaving it as a
# 2 ns related-clock path between the FMC-derived 125 MHz and pl_clk0 (100 MHz).
set_property ASYNC_REG TRUE [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_*/inst/core/mac_inst/link_speed_sync_reg_*_reg[*]}]
set_max_delay -datapath_only -from [get_clocks clk_out1_taxieth_clk_wiz_0_0] -to [get_cells -hierarchical -filter {NAME =~ *taxi_rgmii_mac_*/inst/core/mac_inst/link_speed_sync_reg_1_reg[*]}] 8.000

# The IDELAYCTRL reset comes from the 125 MHz reset synchroniser; it is held for
# many cycles, so its recovery/removal against the 300 MHz reference is a false path.
set_false_path -to [get_pins -hierarchical -filter {NAME =~ *util_idelay_ctrl_0/*dlyctrl*/RST}]

# PHY resets and the FMC clock control lines are static
set_false_path -to [get_ports {reset_port_* ref_clk_oe[0] ref_clk_fsel[0]}]
# MDIO is a slow (2.5 MHz) software-driven bus
set_false_path -to [get_ports {mdio_io_port_*}]
set_false_path -from [get_ports {mdio_io_port_*_mdio_io}]
