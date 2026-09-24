# Opsero Electronic Design Inc. Copyright 2026
#
# Block design for Zynq UltraScale+ targets: 4x Taxi RGMII MAC + AXI DMA.
#
# Sourced by scripts/build.tcl, which provides:
#   $block_name   the block design name (taxieth)
#   $ports        list of Ethernet FMC ports to instantiate, e.g. { 0 1 2 3 }
#
# Per port:  axi_dma_N  <-AXI-Stream->  taxi_rgmii_mac_N (module reference)
#            The MAC cell bundles the Taxi 1G RGMII MAC, the Taxi MDIO master
#            and an AXI-Lite register file (see src/hdl/taxi_rgmii_mac.v).
#
# Clocks:    pl_clk0 (100 MHz)          AXI-Lite, AXI DMA and the MAC logic side
#            clk_wiz_0 <- FMC 125 MHz   clk_out1 125 MHz 0deg  (gtx_clk)
#                                       clk_out2 125 MHz 90deg (gtx_clk90, RGMII TX clock)
#                                       clk_out3 300 MHz       (IDELAYCTRL reference)
# Interrupts: axi_dma_N mm2s/s2mm -> xlconcat_0 -> pl_ps_irq0
#*****************************************************************************************

# Check that a project is open
if { [llength [get_projects -quiet]] == 0 } {
  puts "ERROR: bd_zynqmp.tcl requires an open project"
  return
}
if { ![info exists block_name] } { set block_name taxieth }
if { ![info exists ports] } { set ports { 0 1 2 3 } }
# Per-port RGMII receive delay, indexed by port; build.tcl may override.
# IDATAIN: pad -> IDELAYE3 (rx_idelay_ps, calibrated) -> IDDR, in the pin's bit
# slice. The value centres the data eye on the RX clock insertion delay (IBUF ->
# BUFGCE -> IDDR): ~600 ps for the ports whose RXC is on a clock-capable pin
# (0/2), ~1000-1100 ps for the ports whose RXC reaches its BUFGCE over general
# routing (1/3). Tuned per port from the signoff timing together with the BUFGCE
# placement and clock-root constraints in the target XDC.
if { ![info exists rx_delay_src] } { set rx_delay_src { IDATAIN IDATAIN IDATAIN IDATAIN } }
if { ![info exists rx_idelay_ps] } { set rx_idelay_ps { 600 1100 600 1000 } }

create_bd_design $block_name
current_bd_design $block_name
set parentCell [get_bd_cells /]
set parentObj [get_bd_cells $parentCell]
set oldCurInst [current_bd_instance .]
current_bd_instance $parentObj

# ---------------------------------------------------------------------------
# Processing system
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ultra_ps_e_0
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} [get_bd_cells zynq_ultra_ps_e_0]
# HPM0 (control), HP0 (DMA into DDR), IRQ0, TTC0 on EMIO (lwIP tick timer)
set_property -dict [list \
  CONFIG.PSU__USE__M_AXI_GP0 {1} \
  CONFIG.PSU__USE__M_AXI_GP1 {0} \
  CONFIG.PSU__USE__M_AXI_GP2 {0} \
  CONFIG.PSU__USE__S_AXI_GP2 {1} \
  CONFIG.PSU__USE__IRQ0 {1} \
  CONFIG.PSU__USE__IRQ1 {0} \
  CONFIG.PSU__TTC0__PERIPHERAL__ENABLE {1} \
  CONFIG.PSU__TTC0__PERIPHERAL__IO {EMIO} \
] [get_bd_cells zynq_ultra_ps_e_0]

set pl_clk [get_bd_pins zynq_ultra_ps_e_0/pl_clk0]
connect_bd_net $pl_clk [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_fpd_aclk]
connect_bd_net $pl_clk [get_bd_pins zynq_ultra_ps_e_0/saxihp0_fpd_aclk]

# Reset for the pl_clk0 domain
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_ps8_0_100M
connect_bd_net $pl_clk [get_bd_pins rst_ps8_0_100M/slowest_sync_clk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] [get_bd_pins rst_ps8_0_100M/ext_reset_in]
set pl_aresetn [get_bd_pins rst_ps8_0_100M/peripheral_aresetn]

# ---------------------------------------------------------------------------
# Ethernet FMC 125 MHz reference clock -> gtx_clk / gtx_clk90 / IDELAY ref
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_wiz_0
set_property -dict [list \
  CONFIG.PRIM_SOURCE {Differential_clock_capable_pin} \
  CONFIG.PRIM_IN_FREQ {125.000} \
  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {125.000} \
  CONFIG.CLKOUT2_USED {true} \
  CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {125.000} \
  CONFIG.CLKOUT2_REQUESTED_PHASE {90.000} \
  CONFIG.CLKOUT3_USED {true} \
  CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {300.000} \
  CONFIG.USE_LOCKED {true} \
  CONFIG.USE_RESET {false} \
] [get_bd_cells clk_wiz_0]

create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 ref_clk
set_property CONFIG.FREQ_HZ 125000000 [get_bd_intf_ports ref_clk]
connect_bd_intf_net [get_bd_intf_ports ref_clk] [get_bd_intf_pins clk_wiz_0/CLK_IN1_D]

# Ethernet FMC clock generator control: OE=1 enables it, FSEL=1 selects 125 MHz
create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 ref_clk_oe
create_bd_port -dir O -from 0 -to 0 ref_clk_oe
connect_bd_net [get_bd_ports ref_clk_oe] [get_bd_pins ref_clk_oe/dout]
create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 ref_clk_fsel
create_bd_port -dir O -from 0 -to 0 ref_clk_fsel
connect_bd_net [get_bd_ports ref_clk_fsel] [get_bd_pins ref_clk_fsel/dout]

# Reset for the 125 MHz transmit clock domain (held until the MMCM locks)
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_gtx_125M
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins rst_gtx_125M/slowest_sync_clk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] [get_bd_pins rst_gtx_125M/ext_reset_in]
connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins rst_gtx_125M/dcm_locked]
set gtx_aresetn [get_bd_pins rst_gtx_125M/peripheral_aresetn]

# IDELAYCTRL for the RGMII receive-side IDELAYE3s (300 MHz reference)
create_bd_cell -type ip -vlnv xilinx.com:ip:util_idelay_ctrl util_idelay_ctrl_0
connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins util_idelay_ctrl_0/ref_clk]
connect_bd_net [get_bd_pins rst_gtx_125M/peripheral_reset] [get_bd_pins util_idelay_ctrl_0/rst]

# ---------------------------------------------------------------------------
# Interrupt concentrator: 2 per port (DMA MM2S, S2MM) -> pl_ps_irq0 (max 8)
# ---------------------------------------------------------------------------
set num_ints [expr {2 * [llength $ports]}]
if { $num_ints > 8 } {
  puts "ERROR: $num_ints interrupts do not fit pl_ps_irq0"
  return
}
create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 xlconcat_0
set_property CONFIG.NUM_PORTS $num_ints [get_bd_cells xlconcat_0]
connect_bd_net [get_bd_pins xlconcat_0/dout] [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq0]

# ---------------------------------------------------------------------------
# Per-port: Taxi RGMII MAC (module reference) + AXI DMA
# ---------------------------------------------------------------------------
set int_index 0
foreach port $ports {
  set mac taxi_rgmii_mac_$port
  set dma axi_dma_$port

  # MAC: 32-bit AXI-Stream to the DMA. The receive delay compensates the RX
  # clock insertion (pad -> BUFG -> IDDR) so the PHY-centred data stays centred
  # (see rx_delay_src / rx_idelay_ps above and the target XDC).
  create_bd_cell -type module -reference taxi_rgmii_mac $mac
  set idelay_ps [lindex $rx_idelay_ps $port]
  set delay_src [lindex $rx_delay_src $port]
  set_property -dict [list \
    CONFIG.AXIS_DATA_W {32} \
    CONFIG.TX_FIFO_DEPTH {8192} \
    CONFIG.RX_FIFO_DEPTH {8192} \
    CONFIG.FAMILY {zynquplus} \
    CONFIG.USE_CLK90 {1} \
    CONFIG.RX_DELAY_SRC $delay_src \
    CONFIG.RX_IDELAY_PS $idelay_ps \
    CONFIG.IDELAY_REFCLK_MHZ {300} \
  ] [get_bd_cells $mac]

  # AXI DMA: scatter-gather, 32-bit streams, unaligned transfers (lwIP pbufs
  # are not word aligned), no control/status streams (no AXI Ethernet here).
  create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma $dma
  set_property -dict [list \
    CONFIG.c_include_sg {1} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_sg_length_width {16} \
    CONFIG.c_include_mm2s_dre {1} \
    CONFIG.c_include_s2mm_dre {1} \
    CONFIG.c_m_axis_mm2s_tdata_width {32} \
    CONFIG.c_s_axis_s2mm_tdata_width {32} \
    CONFIG.c_mm2s_burst_size {16} \
    CONFIG.c_s2mm_burst_size {16} \
  ] [get_bd_cells $dma]

  # Streams
  connect_bd_intf_net [get_bd_intf_pins $dma/M_AXIS_MM2S] [get_bd_intf_pins $mac/s_axis_tx]
  connect_bd_intf_net [get_bd_intf_pins $mac/m_axis_rx] [get_bd_intf_pins $dma/S_AXIS_S2MM]

  # Clocks and resets
  connect_bd_net $pl_clk [get_bd_pins $dma/s_axi_lite_aclk]
  connect_bd_net $pl_clk [get_bd_pins $dma/m_axi_sg_aclk]
  connect_bd_net $pl_clk [get_bd_pins $dma/m_axi_mm2s_aclk]
  connect_bd_net $pl_clk [get_bd_pins $dma/m_axi_s2mm_aclk]
  connect_bd_net $pl_aresetn [get_bd_pins $dma/axi_resetn]
  connect_bd_net $pl_clk [get_bd_pins $mac/s_axi_aclk]
  connect_bd_net $pl_aresetn [get_bd_pins $mac/s_axi_aresetn]
  connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins $mac/gtx_clk]
  connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_pins $mac/gtx_clk90]
  connect_bd_net $gtx_aresetn [get_bd_pins $mac/gtx_aresetn]

  # External ports (names match the constraint files of the AXI Ethernet design)
  create_bd_intf_port -mode Master -vlnv xilinx.com:interface:rgmii_rtl:1.0 rgmii_port_${port}
  connect_bd_intf_net [get_bd_intf_ports rgmii_port_${port}] [get_bd_intf_pins $mac/rgmii]
  create_bd_port -dir O mdio_io_port_${port}_mdc
  connect_bd_net [get_bd_ports mdio_io_port_${port}_mdc] [get_bd_pins $mac/mdc]
  create_bd_port -dir IO mdio_io_port_${port}_mdio_io
  connect_bd_net [get_bd_ports mdio_io_port_${port}_mdio_io] [get_bd_pins $mac/mdio]
  create_bd_port -dir O -type rst reset_port_${port}
  connect_bd_net [get_bd_ports reset_port_${port}] [get_bd_pins $mac/phy_reset_n]

  # AXI-Lite control: MAC registers and DMA registers on HPM0
  apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} \
    Master {/zynq_ultra_ps_e_0/M_AXI_HPM0_FPD} Slave "/$mac/s_axi" ddr_seg {Auto} intc_ip {Auto} master_apm {0}] \
    [get_bd_intf_pins $mac/s_axi]
  apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} \
    Master {/zynq_ultra_ps_e_0/M_AXI_HPM0_FPD} Slave "/$dma/S_AXI_LITE" ddr_seg {Auto} intc_ip {Auto} master_apm {0}] \
    [get_bd_intf_pins $dma/S_AXI_LITE]

  # Interrupts
  connect_bd_net [get_bd_pins $dma/mm2s_introut] [get_bd_pins xlconcat_0/In$int_index]
  incr int_index
  connect_bd_net [get_bd_pins $dma/s2mm_introut] [get_bd_pins xlconcat_0/In$int_index]
  incr int_index
}

# ---------------------------------------------------------------------------
# One SmartConnect for all the DMA masters into S_AXI_HP0_FPD. Created after
# the AXI-Lite automation above so the automation does not adopt it for HPM0.
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect axi_smc
set_property -dict [list CONFIG.NUM_SI [expr {3 * [llength $ports]}] CONFIG.NUM_MI {1}] [get_bd_cells axi_smc]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI] [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP0_FPD]
connect_bd_net $pl_clk [get_bd_pins axi_smc/aclk]
connect_bd_net $pl_aresetn [get_bd_pins axi_smc/aresetn]
set smc_index 0
foreach port $ports {
  foreach m {M_AXI_SG M_AXI_MM2S M_AXI_S2MM} {
    set si [format "S%02d_AXI" $smc_index]
    connect_bd_intf_net [get_bd_intf_pins axi_dma_$port/$m] [get_bd_intf_pins axi_smc/$si]
    incr smc_index
  }
}

# ---------------------------------------------------------------------------
# Address map: DMA masters see DDR (low + high) and OCM; slaves auto-assigned
# ---------------------------------------------------------------------------
assign_bd_address
foreach port $ports {
  set dma axi_dma_$port
  foreach sp {Data_SG Data_MM2S Data_S2MM} {
    foreach seg [get_bd_addr_segs -quiet -excluded $dma/$sp/SEG_zynq_ultra_ps_e_0_HP0_*] {
      include_bd_addr_seg $seg
    }
  }
}

regenerate_bd_layout
validate_bd_design
save_bd_design
current_bd_instance $oldCurInst
