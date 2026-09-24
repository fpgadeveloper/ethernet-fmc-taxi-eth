# Opsero Electronic Design Inc. Copyright 2026
#
# Block design for MicroBlaze UltraScale targets (KCU105): 4x Taxi RGMII MAC +
# AXI DMA, a MicroBlaze soft processor and a DDR4 memory controller.
#
# Sourced by scripts/build.tcl, which provides:
#   $block_name   the block design name (taxieth)
#   $ports        list of Ethernet FMC ports to instantiate, e.g. { 0 1 2 3 }
#   $target       the target label (kcu105)
#
# Per port:  axi_dma_N  <-AXI-Stream->  taxi_rgmii_mac_N (module reference)
#            The MAC cell bundles the Taxi 1G RGMII MAC, the Taxi MDIO master
#            and an AXI-Lite register file (see src/hdl/taxi_rgmii_mac.v).
#
# Clocks:    ddr4_0/addn_ui_clkout1 (100 MHz)  MicroBlaze, AXI-Lite, AXI DMA and
#                                       the MAC logic side (s_axi_aclk)
#            ddr4_0/c0_ddr4_ui_clk (300.12 MHz) DDR4 user interface
#            clk_wiz_0 <- FMC 125 MHz   clk_out1 125 MHz 0deg  (gtx_clk)
#                                       clk_out2 125 MHz 90deg (gtx_clk90, RGMII TX clock)
#            clk_wiz_1 <- clk_wiz_0     clk_out1 300 MHz (IDELAYCTRL reference)
#
# Unlike the Zynq UltraScale+ design the IDELAYCTRL reference cannot be a third
# output of clk_wiz_0: one MMCM cannot produce 125 MHz, 125 MHz at 90 deg and
# 300 MHz with integer output dividers below a 1500 MHz VCO, and 1500 MHz is
# above the MMCM limit of the Kintex UltraScale -2 speed grade. The memory
# controller's user clock is not usable either: the MIG quantises the memory
# period to 833 ps, so its user clock is 300.12 MHz, and an IDELAYE3 in TIME
# mode requires REFCLK_FREQUENCY to match its IDELAYCTRL's reference exactly
# ([Timing 38-470]). A second MMCM cascaded off the 125 MHz transmit clock
# gives exactly 300.000 MHz instead.
#
# Interrupts: axi_dma_N mm2s/s2mm + uart + timer -> microblaze_0_xlconcat -> AXI INTC
#*****************************************************************************************

# Check that a project is open
if { [llength [get_projects -quiet]] == 0 } {
  puts "ERROR: bd_mb-us.tcl requires an open project"
  return
}
if { ![info exists block_name] } { set block_name taxieth }
if { ![info exists ports] } { set ports { 0 1 2 3 } }
if { ![info exists target] } { set target kcu105 }

# Per-port RGMII receive delay, indexed by port.
# IDATAIN: pad -> IDELAYE3 (rx_idelay_ps, calibrated) -> IDDR, in the pin's bit
# slice. The value centres the data eye on the RX clock insertion delay (IBUF ->
# BUFGCE -> IDDR). All four Ethernet FMC RX clocks land on clock-capable (CC)
# pins of the KCU105 HPC connector (LA00_CC, LA01_CC, LA17_CC, LA18_CC), so
# every port has the short dedicated IBUF -> BUFGCE route and they all take the
# same value. Tuned from the signoff timing: at 600 ps every port met setup with
# ~0.78 ns to spare but missed hold by 0.27-0.35 ns, i.e. the whole receive eye
# sat ~0.5 ns too early against the BUFGCE-routed clock. 1100 ps (the IDELAYE3
# maximum in TIME mode, [DRC AVAL-174]) moves it back and leaves both checks
# positive on all four ports.
if { ![info exists rx_delay_src] } { set rx_delay_src { IDATAIN IDATAIN IDATAIN IDATAIN } }
if { ![info exists rx_idelay_ps] } { set rx_idelay_ps { 1100 1100 1100 1100 } }

# Connect a pin only if it is not already driven (the board / MicroBlaze
# automations connect some of these themselves, and the connection they make
# depends on the Vivado release).
proc ensure_net { src dst } {
  if { [llength [get_bd_nets -quiet -of_objects $dst]] == 0 } {
    connect_bd_net $src $dst
  }
}

create_bd_design $block_name
current_bd_design $block_name
set parentCell [get_bd_cells /]
set parentObj [get_bd_cells $parentCell]
set oldCurInst [current_bd_instance .]
current_bd_instance $parentObj

# ---------------------------------------------------------------------------
# DDR4 memory controller (MIG)
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:ddr4 ddr4_0
apply_bd_automation -rule xilinx.com:bd_rule:board \
  -config { Board_Interface {default_sysclk_300 ( 300 MHz System differential clock ) } Manual_Source {Auto}} \
  [get_bd_intf_pins ddr4_0/C0_SYS_CLK]
apply_bd_automation -rule xilinx.com:bd_rule:board \
  -config { Board_Interface {ddr4_sdram_062 ( DDR4 SDRAM ) } Manual_Source {Auto}} \
  [get_bd_intf_pins ddr4_0/C0_DDR4]
# Additional user clock: 100 MHz for the processor, AXI-Lite and the DMAs
set_property -dict [list CONFIG.ADDN_UI_CLKOUT1_FREQ_HZ {100}] [get_bd_cells ddr4_0]

# Board FPGA reset -> external port "reset" (active high)
apply_bd_automation -rule xilinx.com:bd_rule:board \
  -config { Board_Interface {reset ( FPGA Reset ) } Manual_Source {New External Port (ACTIVE_HIGH)}} \
  [get_bd_pins ddr4_0/sys_rst]

# ---------------------------------------------------------------------------
# MicroBlaze: 64 KB caches, 64 KB local memory, AXI INTC, MDM
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:microblaze microblaze_0
apply_bd_automation -rule xilinx.com:bd_rule:microblaze \
  -config { axi_intc {1} axi_periph {Enabled} cache {64KB} clk {/ddr4_0/addn_ui_clkout1 (100 MHz)} \
            cores {1} debug_module {Debug Only} ecc {None} local_mem {64KB} preset {None}} \
  [get_bd_cells microblaze_0]
# Cached instruction/data ports into the DDR4 controller, through a SmartConnect
# that will also carry the DMA masters (see below)
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
  -config { Clk_master {/ddr4_0/addn_ui_clkout1 (100 MHz)} Clk_slave {/ddr4_0/c0_ddr4_ui_clk (300 MHz)} \
            Clk_xbar {Auto} Master {/microblaze_0 (Cached)} Slave {/ddr4_0/C0_DDR4_S_AXI} \
            ddr_seg {Auto} intc_ip {New AXI SmartConnect} master_apm {0}} \
  [get_bd_intf_pins ddr4_0/C0_DDR4_S_AXI]

# Bare-metal processor: no MMU, but keep the barrel shifter, divider, hardware
# multiplier and the exception handling the AMD standalone BSP expects.
set_property -dict [list \
  CONFIG.G_USE_EXCEPTIONS {1} \
  CONFIG.C_USE_MSR_INSTR {1} \
  CONFIG.C_USE_PCMP_INSTR {1} \
  CONFIG.C_USE_BARREL {1} \
  CONFIG.C_USE_DIV {1} \
  CONFIG.C_USE_HW_MUL {2} \
  CONFIG.C_UNALIGNED_EXCEPTIONS {1} \
  CONFIG.C_ILL_OPCODE_EXCEPTION {1} \
  CONFIG.C_M_AXI_I_BUS_EXCEPTION {1} \
  CONFIG.C_M_AXI_D_BUS_EXCEPTION {1} \
  CONFIG.C_DIV_ZERO_EXCEPTION {1} \
  CONFIG.C_PVR {2} \
  CONFIG.C_OPCODE_0x0_ILLEGAL {1} \
  CONFIG.C_ICACHE_LINE_LEN {8} \
  CONFIG.C_ICACHE_VICTIMS {8} \
  CONFIG.C_ICACHE_STREAMS {1} \
  CONFIG.C_DCACHE_VICTIMS {8} \
  CONFIG.C_USE_MMU {0} \
] [get_bd_cells microblaze_0]

# The board reset drives the 100 MHz processor system reset
ensure_net [get_bd_ports reset] [get_bd_pins rst_ddr4_0_100M/ext_reset_in]

set sys_clk [get_bd_pins ddr4_0/addn_ui_clkout1]
set ui_clk  [get_bd_pins ddr4_0/c0_ddr4_ui_clk]
set sys_aresetn [get_bd_pins rst_ddr4_0_100M/peripheral_aresetn]

# ---------------------------------------------------------------------------
# Ethernet FMC 125 MHz reference clock -> gtx_clk / gtx_clk90
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_wiz_0
set_property -dict [list \
  CONFIG.PRIM_SOURCE {Differential_clock_capable_pin} \
  CONFIG.PRIM_IN_FREQ {125.000} \
  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {125.000} \
  CONFIG.CLKOUT2_USED {true} \
  CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {125.000} \
  CONFIG.CLKOUT2_REQUESTED_PHASE {90.000} \
  CONFIG.CLKOUT3_USED {false} \
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
connect_bd_net [get_bd_ports reset] [get_bd_pins rst_gtx_125M/ext_reset_in]
connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins rst_gtx_125M/dcm_locked]
set gtx_aresetn [get_bd_pins rst_gtx_125M/peripheral_aresetn]

# Exactly 300.000 MHz for the RGMII receive-side IDELAYE3s, from a second MMCM
# cascaded off the 125 MHz transmit clock (see the note at the top of this file
# on why neither clk_wiz_0 nor the memory controller can supply it).
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_wiz_1
set_property -dict [list \
  CONFIG.PRIM_SOURCE {No_buffer} \
  CONFIG.PRIM_IN_FREQ {125.000} \
  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {300.000} \
  CONFIG.USE_LOCKED {true} \
  CONFIG.USE_RESET {false} \
] [get_bd_cells clk_wiz_1]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins clk_wiz_1/clk_in1]

# IDELAYCTRL for the RGMII receive-side IDELAYE3s; its reset is synchronised to
# the reference clock and released once that MMCM has locked.
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_idelay_300M
connect_bd_net [get_bd_pins clk_wiz_1/clk_out1] [get_bd_pins rst_idelay_300M/slowest_sync_clk]
connect_bd_net [get_bd_ports reset] [get_bd_pins rst_idelay_300M/ext_reset_in]
connect_bd_net [get_bd_pins clk_wiz_1/locked] [get_bd_pins rst_idelay_300M/dcm_locked]
create_bd_cell -type ip -vlnv xilinx.com:ip:util_idelay_ctrl util_idelay_ctrl_0
connect_bd_net [get_bd_pins clk_wiz_1/clk_out1] [get_bd_pins util_idelay_ctrl_0/ref_clk]
connect_bd_net [get_bd_pins rst_idelay_300M/peripheral_reset] [get_bd_pins util_idelay_ctrl_0/rst]

# ---------------------------------------------------------------------------
# One SmartConnect carries the MicroBlaze cached ports (S00/S01, created by the
# automation above) and every DMA master into the DDR4 controller. Two clocks:
# the 300 MHz user interface on the master side, 100 MHz on the slave side.
# ---------------------------------------------------------------------------
set num_si [expr {2 + 3 * [llength $ports]}]
set_property -dict [list CONFIG.NUM_MI {1} CONFIG.NUM_SI $num_si CONFIG.NUM_CLKS {2}] [get_bd_cells axi_smc]
ensure_net $ui_clk  [get_bd_pins axi_smc/aclk]
ensure_net $sys_clk [get_bd_pins axi_smc/aclk1]
ensure_net $sys_aresetn [get_bd_pins axi_smc/aresetn]

# ---------------------------------------------------------------------------
# Per-port: Taxi RGMII MAC (module reference) + AXI DMA
# ---------------------------------------------------------------------------
set ints {}
set smc_index 2
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
    CONFIG.FAMILY {kintexu} \
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

  # Clocks and resets: everything on the logic side runs at 100 MHz
  connect_bd_net $sys_clk [get_bd_pins $dma/s_axi_lite_aclk]
  connect_bd_net $sys_clk [get_bd_pins $dma/m_axi_sg_aclk]
  connect_bd_net $sys_clk [get_bd_pins $dma/m_axi_mm2s_aclk]
  connect_bd_net $sys_clk [get_bd_pins $dma/m_axi_s2mm_aclk]
  connect_bd_net $sys_aresetn [get_bd_pins $dma/axi_resetn]
  connect_bd_net $sys_clk [get_bd_pins $mac/s_axi_aclk]
  connect_bd_net $sys_aresetn [get_bd_pins $mac/s_axi_aresetn]
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

  # AXI-Lite control: MAC registers and DMA registers on the MicroBlaze
  # peripheral interconnect (named explicitly so the automation cannot adopt
  # the DMA SmartConnect instead).
  apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} \
    Master {/microblaze_0 (Periph)} Slave "/$mac/s_axi" ddr_seg {Auto} intc_ip {/microblaze_0_axi_periph} master_apm {0}] \
    [get_bd_intf_pins $mac/s_axi]
  apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} \
    Master {/microblaze_0 (Periph)} Slave "/$dma/S_AXI_LITE" ddr_seg {Auto} intc_ip {/microblaze_0_axi_periph} master_apm {0}] \
    [get_bd_intf_pins $dma/S_AXI_LITE]

  # DMA masters into the DDR4 controller
  foreach m {M_AXI_SG M_AXI_MM2S M_AXI_S2MM} {
    set si [format "S%02d_AXI" $smc_index]
    connect_bd_intf_net [get_bd_intf_pins $dma/$m] [get_bd_intf_pins axi_smc/$si]
    incr smc_index
  }

  # Interrupts
  append ints "$dma/mm2s_introut "
  append ints "$dma/s2mm_introut "
}

# ---------------------------------------------------------------------------
# UART (console for the bare-metal application) and timer (xiltimer tick)
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_uart16550 axi_uart16550_0
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
  -config { Clk_master {/ddr4_0/addn_ui_clkout1 (100 MHz)} Clk_slave {Auto} \
            Clk_xbar {/ddr4_0/addn_ui_clkout1 (100 MHz)} Master {/microblaze_0 (Periph)} \
            Slave {/axi_uart16550_0/S_AXI} ddr_seg {Auto} intc_ip {/microblaze_0_axi_periph} master_apm {0}} \
  [get_bd_intf_pins axi_uart16550_0/S_AXI]
apply_bd_automation -rule xilinx.com:bd_rule:board \
  -config { Board_Interface {rs232_uart ( UART ) } Manual_Source {Auto}} \
  [get_bd_intf_pins axi_uart16550_0/UART]
append ints "axi_uart16550_0/ip2intc_irpt "

# The cell must keep this name: the standalone xiltimer hook selects it by name.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_timer axi_timer_0
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
  -config { Clk_master {/ddr4_0/addn_ui_clkout1 (100 MHz)} Clk_slave {Auto} \
            Clk_xbar {/ddr4_0/addn_ui_clkout1 (100 MHz)} Master {/microblaze_0 (Periph)} \
            Slave {/axi_timer_0/S_AXI} ddr_seg {Auto} intc_ip {/microblaze_0_axi_periph} master_apm {0}} \
  [get_bd_intf_pins axi_timer_0/S_AXI]
append ints "axi_timer_0/interrupt "

# ---------------------------------------------------------------------------
# Interrupt concentrator into the AXI INTC
# ---------------------------------------------------------------------------
set num_ints [llength $ints]
set_property -dict [list CONFIG.NUM_PORTS $num_ints] [get_bd_cells microblaze_0_xlconcat]
set input_index -1
foreach interrupt_pin $ints {
  incr input_index
  connect_bd_net [get_bd_pins $interrupt_pin] [get_bd_pins microblaze_0_xlconcat/In${input_index}]
}

# ---------------------------------------------------------------------------
# Address map
# ---------------------------------------------------------------------------
# The MAC register files are a block-design module reference, not an IP, so no
# XPAR_* macros are generated for them and the bare-metal driver uses
# compiled-in base addresses. Pin them (and the DMA register files, for the same
# reason of reproducibility) to a deterministic, contiguous block instead of
# leaving them where the AXI-Lite automation happened to put them.
#   taxi_rgmii_mac_N  0x4000_0000 + N * 0x1000   (4 KB apart)
#   axi_dma_N         0x41E0_0000 + N * 0x10000  (64 KB apart)
foreach port $ports {
  assign_bd_address -offset [format 0x%08X [expr {0x40000000 + $port * 0x1000}]] -range 4K \
    -target_address_space /microblaze_0/Data [get_bd_addr_segs taxi_rgmii_mac_$port/s_axi/reg0] -force
  assign_bd_address -offset [format 0x%08X [expr {0x41E00000 + $port * 0x10000}]] -range 64K \
    -target_address_space /microblaze_0/Data [get_bd_addr_segs axi_dma_$port/S_AXI_LITE/Reg] -force
}

# Every DMA master sees the whole DDR4 address block
foreach port $ports {
  foreach sp {Data_SG Data_MM2S Data_S2MM} {
    assign_bd_address -target_address_space /axi_dma_$port/$sp \
      [get_bd_addr_segs ddr4_0/C0_DDR4_MEMORY_MAP/C0_DDR4_ADDRESS_BLOCK] -force
  }
}
assign_bd_address -quiet

regenerate_bd_layout
validate_bd_design
save_bd_design
current_bd_instance $oldCurInst
