// SPDX-License-Identifier: MIT
//
// taxi_rgmii_mac — block-design module reference for one Ethernet FMC port:
// Taxi 1G RGMII MAC + Taxi MDIO master + AXI4-Lite register file.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// This is a Verilog-2001 shell (Vivado requires a Verilog top file for a
// block-design module reference); the implementation is the SystemVerilog
// module taxi_rgmii_mac_core (taxi_rgmii_mac_core.sv), which instantiates the
// Taxi library modules from submodules/taxi (CERN-OHL-S-2.0, see
// submodules/README.md). The attributes below tell the block design how to
// group the pins into AXI-Lite / AXI-Stream / RGMII / MDIO interfaces.
//
// Register map (byte offsets, 32-bit registers)
//   0x00 ID          RO  0x54415849 ("TAXI")
//   0x04 VERSION     RO  0x00010000
//   0x08 CTRL        RW  [0] tx_enable=1 [1] rx_enable=1 [2] phy_reset_n=1 [3] tx_pad_en=1
//   0x0C STATUS      RO  [1:0] link_speed (00=10M 01=100M 10=1G)  [8] mdio busy
//   0x10 FLAGS       W1C [0] tx_underflow [1] tx_fifo_overflow [2] tx_fifo_bad_frame
//                        [3] rx_fifo_overflow [4] rx_fifo_bad_frame [5] rx_bad_fcs
//   0x14 TX_IFG      RW  [7:0] inter-frame gap in bytes (12)
//   0x18 TX_MAX_LEN  RW  [15:0] max TX frame length on the wire, incl. FCS, minus 1 (1517)
//   0x1C RX_MAX_LEN  RW  [15:0] max RX frame length on the wire, incl. FCS, minus 1 (1517)
//   0x20 RX_GOOD_CNT RO/WC good frames delivered from the RX FIFO (write clears)
//   0x24 RX_BAD_CNT  RO/WC frames dropped by the RX FIFO as bad
//   0x28 TX_GOOD_CNT RO/WC frames transmitted
//   0x2C TX_BAD_CNT  RO/WC frames dropped by the TX FIFO as bad
//   0x30 RX_OVF_CNT  RO/WC RX FIFO overflow events
//   0x34 TX_OVF_CNT  RO/WC TX FIFO overflow events
//   0x40 MDIO_CMD    WO  [31:30]=01 [29:28] op (01 write, 10 read) [27:23] phy addr
//                        [22:18] reg addr [15:0] write data — writing issues the frame
//   0x44 MDIO_RDATA  RO  [15:0] data of the last completed read
//   0x48 MDIO_STATUS RO  [0] busy (command pending or on the wire) [1] read data valid
//                        (cleared by MDIO_CMD write) [2] command dropped (MDIO_CMD written
//                        while one was already queued; sticky until the next accepted write)
//                        One command is queued while the bus is busy; poll busy==0
//                        before reading MDIO_RDATA.
//   0x4C MDIO_DIV    RW  [7:0] MDC half-period in s_axi_aclk cycles minus 1 (19)
//
// Data path: AXI-Stream frames are Ethernet frames without FCS on both sides
// (the MAC appends the FCS on transmit and strips it on receive). Bad-FCS and
// oversize frames are dropped in hardware. There is no address filter.

`timescale 1ns / 1ps

module taxi_rgmii_mac #(
    parameter AXIS_DATA_W        = 32,          // DMA-side AXI-Stream width (multiple of 8)
    parameter TX_FIFO_DEPTH      = 8192,        // bytes
    parameter RX_FIFO_DEPTH      = 8192,        // bytes
    parameter FAMILY             = "zynquplus", // Taxi device family string
    parameter USE_CLK90          = 1,           // 1: FPGA-side RGMII TX clock delay (gtx_clk90)
    parameter RX_DELAY_SRC       = "NONE",      // NONE | IDATAIN (pad->IDELAY) | DATAIN (pad->fabric->IDELAY)
    parameter RX_IDELAY_PS       = 0,           // IDELAYE3 delay on rxd/rx_ctl, 0..1100 ps
    parameter IDELAY_REFCLK_MHZ  = 300,         // IDELAYCTRL reference clock
    parameter C_S_AXI_ADDR_WIDTH = 8
) (
    // ---- AXI-Lite / DMA clock domain ----------------------------------------
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi:s_axis_tx:m_axis_rx, ASSOCIATED_RESET s_axi_aresetn" *)
    input  wire                          s_axi_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                          s_axi_aresetn,

    // AXI4-Lite slave
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWADDR" *)
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWPROT" *)
    input  wire [2:0]                    s_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWVALID" *)
    input  wire                          s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWREADY" *)
    output wire                          s_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WDATA" *)
    input  wire [31:0]                   s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WSTRB" *)
    input  wire [3:0]                    s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WVALID" *)
    input  wire                          s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WREADY" *)
    output wire                          s_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BRESP" *)
    output wire [1:0]                    s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BVALID" *)
    output wire                          s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BREADY" *)
    input  wire                          s_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARADDR" *)
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARPROT" *)
    input  wire [2:0]                    s_axi_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARVALID" *)
    input  wire                          s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARREADY" *)
    output wire                          s_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RDATA" *)
    output wire [31:0]                   s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RRESP" *)
    output wire [1:0]                    s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RVALID" *)
    output wire                          s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RREADY" *)
    input  wire                          s_axi_rready,

    // AXI4-Stream slave: frames to transmit (from AXI DMA MM2S)
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx TDATA" *)
    input  wire [AXIS_DATA_W-1:0]        s_axis_tx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx TKEEP" *)
    input  wire [AXIS_DATA_W/8-1:0]      s_axis_tx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx TVALID" *)
    input  wire                          s_axis_tx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx TREADY" *)
    output wire                          s_axis_tx_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx TLAST" *)
    input  wire                          s_axis_tx_tlast,

    // AXI4-Stream master: received frames (to AXI DMA S2MM)
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx TDATA" *)
    output wire [AXIS_DATA_W-1:0]        m_axis_rx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx TKEEP" *)
    output wire [AXIS_DATA_W/8-1:0]      m_axis_rx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx TVALID" *)
    output wire                          m_axis_rx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx TREADY" *)
    input  wire                          m_axis_rx_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx TLAST" *)
    output wire                          m_axis_rx_tlast,

    // ---- RGMII transmit clock domain ----------------------------------------
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 gtx_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_RESET gtx_aresetn, FREQ_HZ 125000000" *)
    input  wire                          gtx_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 gtx_clk90 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 125000000" *)
    input  wire                          gtx_clk90,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 gtx_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                          gtx_aresetn,

    // ---- PHY pins --------------------------------------------------------------
    (* X_INTERFACE_INFO = "xilinx.com:interface:rgmii:1.0 rgmii RXC" *)
    input  wire                          rgmii_rx_clk,
    (* X_INTERFACE_INFO = "xilinx.com:interface:rgmii:1.0 rgmii RD" *)
    input  wire [3:0]                    rgmii_rxd,
    (* X_INTERFACE_INFO = "xilinx.com:interface:rgmii:1.0 rgmii RX_CTL" *)
    input  wire                          rgmii_rx_ctl,
    (* X_INTERFACE_INFO = "xilinx.com:interface:rgmii:1.0 rgmii TXC" *)
    output wire                          rgmii_tx_clk,
    (* X_INTERFACE_INFO = "xilinx.com:interface:rgmii:1.0 rgmii TD" *)
    output wire [3:0]                    rgmii_txd,
    (* X_INTERFACE_INFO = "xilinx.com:interface:rgmii:1.0 rgmii TX_CTL" *)
    output wire                          rgmii_tx_ctl,
    // MDIO: plain pins (Vivado drops an inout mapped into an mdio_rtl interface
    // on a module reference), wired to plain block-design ports.
    output wire                          mdc,
    inout  wire                          mdio,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 phy_reset_n RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    output wire                          phy_reset_n,

    // ---- Status (for LEDs / debug) --------------------------------------------
    output wire [1:0]                    link_speed
);

taxi_rgmii_mac_core #(
    .AXIS_DATA_W(AXIS_DATA_W),
    .TX_FIFO_DEPTH(TX_FIFO_DEPTH),
    .RX_FIFO_DEPTH(RX_FIFO_DEPTH),
    .FAMILY(FAMILY),
    .USE_CLK90(USE_CLK90),
    .RX_DELAY_SRC(RX_DELAY_SRC),
    .RX_IDELAY_PS(RX_IDELAY_PS),
    .IDELAY_REFCLK_MHZ(IDELAY_REFCLK_MHZ),
    .C_S_AXI_ADDR_WIDTH(C_S_AXI_ADDR_WIDTH)
) core (
    .s_axi_aclk(s_axi_aclk),
    .s_axi_aresetn(s_axi_aresetn),
    .s_axi_awaddr(s_axi_awaddr),
    .s_axi_awprot(s_axi_awprot),
    .s_axi_awvalid(s_axi_awvalid),
    .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata),
    .s_axi_wstrb(s_axi_wstrb),
    .s_axi_wvalid(s_axi_wvalid),
    .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp),
    .s_axi_bvalid(s_axi_bvalid),
    .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr),
    .s_axi_arprot(s_axi_arprot),
    .s_axi_arvalid(s_axi_arvalid),
    .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata),
    .s_axi_rresp(s_axi_rresp),
    .s_axi_rvalid(s_axi_rvalid),
    .s_axi_rready(s_axi_rready),
    .s_axis_tx_tdata(s_axis_tx_tdata),
    .s_axis_tx_tkeep(s_axis_tx_tkeep),
    .s_axis_tx_tvalid(s_axis_tx_tvalid),
    .s_axis_tx_tready(s_axis_tx_tready),
    .s_axis_tx_tlast(s_axis_tx_tlast),
    .m_axis_rx_tdata(m_axis_rx_tdata),
    .m_axis_rx_tkeep(m_axis_rx_tkeep),
    .m_axis_rx_tvalid(m_axis_rx_tvalid),
    .m_axis_rx_tready(m_axis_rx_tready),
    .m_axis_rx_tlast(m_axis_rx_tlast),
    .gtx_clk(gtx_clk),
    .gtx_clk90(gtx_clk90),
    .gtx_aresetn(gtx_aresetn),
    .rgmii_rx_clk(rgmii_rx_clk),
    .rgmii_rxd(rgmii_rxd),
    .rgmii_rx_ctl(rgmii_rx_ctl),
    .rgmii_tx_clk(rgmii_tx_clk),
    .rgmii_txd(rgmii_txd),
    .rgmii_tx_ctl(rgmii_tx_ctl),
    .mdc(mdc),
    .mdio(mdio),
    .phy_reset_n(phy_reset_n),
    .link_speed(link_speed)
);

endmodule
