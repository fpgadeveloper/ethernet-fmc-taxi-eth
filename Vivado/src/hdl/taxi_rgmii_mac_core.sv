// SPDX-License-Identifier: MIT
//
// taxi_rgmii_mac_core — plain-port wrapper around the Taxi 1G RGMII MAC.
// Instantiated by taxi_rgmii_mac.v, the Verilog-2001 shell that the Vivado
// block design references (Vivado requires a Verilog top for module references;
// everything below it may be SystemVerilog). The register map is documented
// in taxi_rgmii_mac.v.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// This file is part of the Opsero ethernet-fmc-taxi-eth reference design and is
// licensed under the MIT license (see LICENSE at the repo root). It instantiates
// modules from the Taxi transport library (submodules/taxi), which is licensed
// separately under CERN-OHL-S-2.0 — see submodules/README.md.
//
// One instance per Ethernet FMC port. It bundles:
//   * taxi_eth_mac_1g_rgmii_fifo  — MAC + RGMII PHY interface + async FIFOs
//   * taxi_mdio_master            — MDIO (Clause 22) serialiser for the port's PHY
//   * an AXI4-Lite register file (this file) — control, status, counters, MDIO
//
// Clocks / resets
//   s_axi_aclk / s_axi_aresetn : AXI-Lite + AXI-Stream (DMA) domain, any frequency
//   gtx_clk / gtx_clk90        : 125 MHz, 0° and 90° (shared by all ports)
//   gtx_aresetn                : active-low reset synchronous to gtx_clk
//   rgmii_rx_clk               : per-port receive clock from the PHY
//
// Register map (byte offsets)
//   0x00 ID          RO  0x54415849 ("TAXI")
//   0x04 VERSION     RO  0x00010000
//   0x08 CTRL        RW  [0] tx_enable=1 [1] rx_enable=1 [2] phy_reset_n=1 [3] tx_pad_en=1
//   0x0C STATUS      RO  [1:0] link_speed (00=10M 01=100M 10=1G)  [8] mdio busy
//   0x10 FLAGS       W1C [0] tx_underflow [1] tx_fifo_overflow [2] tx_fifo_bad_frame
//                        [3] rx_fifo_overflow [4] rx_fifo_bad_frame [5] rx_bad_fcs
//   0x14 TX_IFG      RW  [7:0] inter-frame gap in bytes (12)
//   0x18 TX_MAX_LEN  RW  [15:0] max TX frame length minus 1 (1517)
//   0x1C RX_MAX_LEN  RW  [15:0] max RX frame length minus 1 (1517)
//   0x20 RX_GOOD_CNT RO/WC good frames delivered from the RX FIFO (write clears)
//   0x24 RX_BAD_CNT  RO/WC frames dropped by the RX FIFO as bad
//   0x28 TX_GOOD_CNT RO/WC frames transmitted
//   0x2C TX_BAD_CNT  RO/WC frames dropped by the TX FIFO as bad
//   0x30 RX_OVF_CNT  RO/WC RX FIFO overflow events
//   0x34 TX_OVF_CNT  RO/WC TX FIFO overflow events
//   0x40 MDIO_CMD    WO  [31:30]=01 [29:28] op (01 write, 10 read) [27:23] phy addr
//                        [22:18] reg addr [15:0] write data — writing issues the frame
//   0x44 MDIO_RDATA  RO  [15:0] data of the last completed read
//   0x48 MDIO_STATUS RO  [0] busy (a command is pending or on the wire)
//                        [1] read data valid (cleared by MDIO_CMD write)
//                        [2] command dropped: MDIO_CMD was written while a
//                            previous command was still pending (sticky, cleared
//                            by the next accepted MDIO_CMD write)
//                        One command is queued while the bus is busy; software
//                        must poll busy==0 before reading MDIO_RDATA.
//   0x4C MDIO_DIV    RW  [7:0] MDC half-period in s_axi_aclk cycles minus 1 (19)

`resetall
`timescale 1ns / 1ps
`default_nettype none

module taxi_rgmii_mac_core #(
    parameter integer AXIS_DATA_W    = 32,      // DMA-side AXI-Stream width (multiple of 8)
    parameter integer TX_FIFO_DEPTH  = 8192,    // bytes
    parameter integer RX_FIFO_DEPTH  = 8192,    // bytes
    parameter         FAMILY         = "zynquplus",
    parameter logic   USE_CLK90      = 1'b1,    // FPGA-side TX clock delay (PHY TX delay off)
    parameter         RX_DELAY_SRC   = "NONE",  // NONE | IDATAIN | DATAIN (see the generate block)
    parameter integer RX_IDELAY_PS   = 0,       // IDELAYE3 delay 0..1100 ps (needs an IDELAYCTRL)
    parameter integer IDELAY_REFCLK_MHZ = 300,  // IDELAYCTRL reference clock (REFCLK_FREQUENCY)
    parameter integer C_S_AXI_ADDR_WIDTH = 8
) (
    // ---- AXI-Lite / DMA clock domain ----------------------------------------
    input  wire logic                        s_axi_aclk,
    input  wire logic                        s_axi_aresetn,

    // AXI4-Lite slave
    input  wire logic [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    input  wire logic [2:0]                  s_axi_awprot,
    input  wire logic                        s_axi_awvalid,
    output wire logic                        s_axi_awready,
    input  wire logic [31:0]                 s_axi_wdata,
    input  wire logic [3:0]                  s_axi_wstrb,
    input  wire logic                        s_axi_wvalid,
    output wire logic                        s_axi_wready,
    output wire logic [1:0]                  s_axi_bresp,
    output wire logic                        s_axi_bvalid,
    input  wire logic                        s_axi_bready,
    input  wire logic [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    input  wire logic [2:0]                  s_axi_arprot,
    input  wire logic                        s_axi_arvalid,
    output wire logic                        s_axi_arready,
    output wire logic [31:0]                 s_axi_rdata,
    output wire logic [1:0]                  s_axi_rresp,
    output wire logic                        s_axi_rvalid,
    input  wire logic                        s_axi_rready,

    // AXI4-Stream slave: frames to transmit (from AXI DMA MM2S)
    input  wire logic [AXIS_DATA_W-1:0]      s_axis_tx_tdata,
    input  wire logic [AXIS_DATA_W/8-1:0]    s_axis_tx_tkeep,
    input  wire logic                        s_axis_tx_tvalid,
    output wire logic                        s_axis_tx_tready,
    input  wire logic                        s_axis_tx_tlast,

    // AXI4-Stream master: received frames (to AXI DMA S2MM)
    output wire logic [AXIS_DATA_W-1:0]      m_axis_rx_tdata,
    output wire logic [AXIS_DATA_W/8-1:0]    m_axis_rx_tkeep,
    output wire logic                        m_axis_rx_tvalid,
    input  wire logic                        m_axis_rx_tready,
    output wire logic                        m_axis_rx_tlast,

    // ---- RGMII transmit clock domain ----------------------------------------
    input  wire logic                        gtx_clk,
    input  wire logic                        gtx_clk90,
    input  wire logic                        gtx_aresetn,

    // ---- PHY pins --------------------------------------------------------------
    input  wire logic                        rgmii_rx_clk,
    input  wire logic [3:0]                  rgmii_rxd,
    input  wire logic                        rgmii_rx_ctl,
    output wire logic                        rgmii_tx_clk,
    output wire logic [3:0]                  rgmii_txd,
    output wire logic                        rgmii_tx_ctl,
    output wire logic                        mdc,
    inout  wire logic                        mdio,
    output wire logic                        phy_reset_n,

    // ---- Status (for LEDs / debug) --------------------------------------------
    output wire logic [1:0]                  link_speed
);

// ---------------------------------------------------------------------------
// Resets: Taxi wants active-high
// ---------------------------------------------------------------------------
wire logic logic_rst = ~s_axi_aresetn;
wire logic gtx_rst   = ~gtx_aresetn;

// ---------------------------------------------------------------------------
// Register file
// ---------------------------------------------------------------------------
logic        ctrl_tx_en_reg   = 1'b1;
logic        ctrl_rx_en_reg   = 1'b1;
logic        ctrl_phy_rstn_reg= 1'b1;
logic        ctrl_pad_en_reg  = 1'b1;
logic [5:0]  flags_reg        = '0;
logic [7:0]  tx_ifg_reg       = 8'd12;
logic [15:0] tx_max_len_reg   = 16'd1518-1;
logic [15:0] rx_max_len_reg   = 16'd1518-1;
logic [31:0] rx_good_cnt_reg  = '0;
logic [31:0] rx_bad_cnt_reg   = '0;
logic [31:0] tx_good_cnt_reg  = '0;
logic [31:0] tx_bad_cnt_reg   = '0;
logic [31:0] rx_ovf_cnt_reg   = '0;
logic [31:0] tx_ovf_cnt_reg   = '0;
logic [7:0]  mdio_div_reg     = 8'd19;
logic [31:0] mdio_cmd_reg     = '0;
logic        mdio_cmd_valid_reg = 1'b0;
logic [15:0] mdio_rdata_reg   = '0;
logic        mdio_rd_valid_reg= 1'b0;
logic        mdio_cmd_drop_reg = 1'b0;

// MAC status (all already in the s_axi_aclk / logic_clk domain)
wire logic tx_error_underflow, tx_fifo_overflow, tx_fifo_bad_frame, tx_fifo_good_frame;
wire logic rx_error_bad_fcs, rx_fifo_overflow, rx_fifo_bad_frame, rx_fifo_good_frame;
wire logic [1:0] link_speed_int;
wire logic mdio_busy;
wire logic mdio_cmd_ready;
wire logic [15:0] mdio_rd_tdata;
wire logic mdio_rd_tvalid;

// ---- AXI-Lite handshake (single outstanding, no wait states) ----
logic aw_ready_reg = 1'b0, w_ready_reg = 1'b0, b_valid_reg = 1'b0;
logic ar_ready_reg = 1'b0, r_valid_reg = 1'b0, ar_got_reg = 1'b0;
logic [31:0] r_data_reg = '0;
logic [C_S_AXI_ADDR_WIDTH-1:0] aw_addr_reg = '0;
logic aw_got_reg = 1'b0, w_got_reg = 1'b0;
logic [31:0] w_data_reg = '0;
logic [3:0]  w_strb_reg = '0;

assign s_axi_awready = aw_ready_reg;
assign s_axi_wready  = w_ready_reg;
assign s_axi_bresp   = 2'b00;
assign s_axi_bvalid  = b_valid_reg;
assign s_axi_arready = ar_ready_reg;
assign s_axi_rdata   = r_data_reg;
assign s_axi_rresp   = 2'b00;
assign s_axi_rvalid  = r_valid_reg;

wire logic do_write = aw_got_reg && w_got_reg && !b_valid_reg;
wire logic [7:0] waddr = 8'(aw_addr_reg[C_S_AXI_ADDR_WIDTH-1:2]) << 2;
logic [C_S_AXI_ADDR_WIDTH-1:0] ar_addr_reg = '0;
wire logic [7:0] raddr = 8'(ar_addr_reg[C_S_AXI_ADDR_WIDTH-1:2]) << 2;

function automatic logic [31:0] merge(input logic [31:0] old, input logic [31:0] nw, input logic [3:0] strb);
    for (int i = 0; i < 4; i++) merge[8*i +: 8] = strb[i] ? nw[8*i +: 8] : old[8*i +: 8];
endfunction

always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
        aw_ready_reg <= 1'b0; w_ready_reg <= 1'b0; b_valid_reg <= 1'b0;
        ar_ready_reg <= 1'b0; r_valid_reg <= 1'b0; ar_got_reg <= 1'b0;
        aw_got_reg <= 1'b0; w_got_reg <= 1'b0;
        ctrl_tx_en_reg <= 1'b1; ctrl_rx_en_reg <= 1'b1; ctrl_phy_rstn_reg <= 1'b1; ctrl_pad_en_reg <= 1'b1;
        flags_reg <= '0;
        tx_ifg_reg <= 8'd12; tx_max_len_reg <= 16'd1518-1; rx_max_len_reg <= 16'd1518-1;
        rx_good_cnt_reg <= '0; rx_bad_cnt_reg <= '0; tx_good_cnt_reg <= '0; tx_bad_cnt_reg <= '0;
        rx_ovf_cnt_reg <= '0; tx_ovf_cnt_reg <= '0;
        mdio_div_reg <= 8'd19; mdio_cmd_reg <= '0; mdio_cmd_valid_reg <= 1'b0;
        mdio_rdata_reg <= '0; mdio_rd_valid_reg <= 1'b0; mdio_cmd_drop_reg <= 1'b0;
    end else begin
        // ---- write address / data capture ----
        aw_ready_reg <= 1'b0;
        w_ready_reg  <= 1'b0;
        if (s_axi_awvalid && !aw_got_reg && !aw_ready_reg) begin
            aw_ready_reg <= 1'b1;
            aw_addr_reg  <= s_axi_awaddr;
            aw_got_reg   <= 1'b1;
        end
        if (s_axi_wvalid && !w_got_reg && !w_ready_reg) begin
            w_ready_reg <= 1'b1;
            w_data_reg  <= s_axi_wdata;
            w_strb_reg  <= s_axi_wstrb;
            w_got_reg   <= 1'b1;
        end
        if (s_axi_bvalid && s_axi_bready) begin
            b_valid_reg <= 1'b0;
        end

        // ---- sticky flags + counters (before writes so W1C wins) ----
        flags_reg <= flags_reg | {rx_error_bad_fcs, rx_fifo_bad_frame, rx_fifo_overflow,
                                  tx_fifo_bad_frame, tx_fifo_overflow, tx_error_underflow};
        if (rx_fifo_good_frame) rx_good_cnt_reg <= rx_good_cnt_reg + 1;
        if (rx_fifo_bad_frame)  rx_bad_cnt_reg  <= rx_bad_cnt_reg + 1;
        if (tx_fifo_good_frame) tx_good_cnt_reg <= tx_good_cnt_reg + 1;
        if (tx_fifo_bad_frame)  tx_bad_cnt_reg  <= tx_bad_cnt_reg + 1;
        if (rx_fifo_overflow)   rx_ovf_cnt_reg  <= rx_ovf_cnt_reg + 1;
        if (tx_fifo_overflow)   tx_ovf_cnt_reg  <= tx_ovf_cnt_reg + 1;

        // ---- MDIO command hand-off ----
        if (mdio_cmd_valid_reg && mdio_cmd_ready) begin
            mdio_cmd_valid_reg <= 1'b0;
        end
        if (mdio_rd_tvalid) begin
            mdio_rdata_reg    <= mdio_rd_tdata;
            mdio_rd_valid_reg <= 1'b1;
        end

        // ---- register write ----
        if (do_write) begin
            aw_got_reg  <= 1'b0;
            w_got_reg   <= 1'b0;
            b_valid_reg <= 1'b1;
            case (waddr)
                8'h08: begin
                    if (w_strb_reg[0]) begin
                        ctrl_tx_en_reg    <= w_data_reg[0];
                        ctrl_rx_en_reg    <= w_data_reg[1];
                        ctrl_phy_rstn_reg <= w_data_reg[2];
                        ctrl_pad_en_reg   <= w_data_reg[3];
                    end
                end
                8'h10: flags_reg <= (flags_reg & ~w_data_reg[5:0]) |
                                    {rx_error_bad_fcs, rx_fifo_bad_frame, rx_fifo_overflow,
                                     tx_fifo_bad_frame, tx_fifo_overflow, tx_error_underflow};
                8'h14: tx_ifg_reg     <= merge({24'd0, tx_ifg_reg}, w_data_reg, w_strb_reg);
                8'h18: tx_max_len_reg <= merge({16'd0, tx_max_len_reg}, w_data_reg, w_strb_reg);
                8'h1C: rx_max_len_reg <= merge({16'd0, rx_max_len_reg}, w_data_reg, w_strb_reg);
                8'h20: rx_good_cnt_reg <= '0;
                8'h24: rx_bad_cnt_reg  <= '0;
                8'h28: tx_good_cnt_reg <= '0;
                8'h2C: tx_bad_cnt_reg  <= '0;
                8'h30: rx_ovf_cnt_reg  <= '0;
                8'h34: tx_ovf_cnt_reg  <= '0;
                8'h40: begin
                    // The Taxi master only takes a command when idle, so one
                    // command can be queued while the bus is busy.
                    if (!mdio_cmd_valid_reg || mdio_cmd_ready) begin
                        mdio_cmd_reg       <= {w_data_reg[31:18], 2'b10, w_data_reg[15:0]};
                        mdio_cmd_valid_reg <= 1'b1;
                        mdio_rd_valid_reg  <= 1'b0;
                        mdio_cmd_drop_reg  <= 1'b0;
                    end else begin
                        mdio_cmd_drop_reg  <= 1'b1;
                    end
                end
                8'h4C: mdio_div_reg <= merge({24'd0, mdio_div_reg}, w_data_reg, w_strb_reg);
                default: ;
            endcase
        end

        // ---- register read ----
        // AR handshake (ar_ready pulse), then RVALID the following cycle.
        ar_ready_reg <= 1'b0;
        if (s_axi_rvalid && s_axi_rready) begin
            r_valid_reg <= 1'b0;
        end
        if (s_axi_arvalid && !ar_ready_reg && !ar_got_reg && !r_valid_reg) begin
            ar_ready_reg <= 1'b1;
            ar_got_reg   <= 1'b1;
            ar_addr_reg  <= s_axi_araddr;
        end
        if (ar_got_reg) begin
            ar_got_reg  <= 1'b0;
            r_valid_reg <= 1'b1;
            case (raddr)
                8'h00: r_data_reg <= 32'h54415849;
                8'h04: r_data_reg <= 32'h00010000;
                8'h08: r_data_reg <= {28'd0, ctrl_pad_en_reg, ctrl_phy_rstn_reg, ctrl_rx_en_reg, ctrl_tx_en_reg};
                8'h0C: r_data_reg <= {23'd0, mdio_busy, 6'd0, link_speed_int};
                8'h10: r_data_reg <= {26'd0, flags_reg};
                8'h14: r_data_reg <= {24'd0, tx_ifg_reg};
                8'h18: r_data_reg <= {16'd0, tx_max_len_reg};
                8'h1C: r_data_reg <= {16'd0, rx_max_len_reg};
                8'h20: r_data_reg <= rx_good_cnt_reg;
                8'h24: r_data_reg <= rx_bad_cnt_reg;
                8'h28: r_data_reg <= tx_good_cnt_reg;
                8'h2C: r_data_reg <= tx_bad_cnt_reg;
                8'h30: r_data_reg <= rx_ovf_cnt_reg;
                8'h34: r_data_reg <= tx_ovf_cnt_reg;
                8'h40: r_data_reg <= mdio_cmd_reg;
                8'h44: r_data_reg <= {16'd0, mdio_rdata_reg};
                8'h48: r_data_reg <= {29'd0, mdio_cmd_drop_reg, mdio_rd_valid_reg, mdio_busy | mdio_cmd_valid_reg};
                8'h4C: r_data_reg <= {24'd0, mdio_div_reg};
                default: r_data_reg <= 32'd0;
            endcase
        end
    end
end

assign phy_reset_n = ctrl_phy_rstn_reg;
assign link_speed  = link_speed_int;

// ---------------------------------------------------------------------------
// MDIO master (Taxi)
// ---------------------------------------------------------------------------
taxi_axis_if #(.DATA_W(32)) axis_mdio_cmd();
taxi_axis_if #(.DATA_W(16)) axis_mdio_rd();

assign axis_mdio_cmd.tdata  = mdio_cmd_reg;
assign axis_mdio_cmd.tkeep  = '1;
assign axis_mdio_cmd.tstrb  = '1;
assign axis_mdio_cmd.tvalid = mdio_cmd_valid_reg;
assign axis_mdio_cmd.tlast  = 1'b1;
assign axis_mdio_cmd.tid    = '0;
assign axis_mdio_cmd.tdest  = '0;
assign axis_mdio_cmd.tuser  = '0;
assign mdio_cmd_ready       = axis_mdio_cmd.tready;

assign mdio_rd_tdata  = axis_mdio_rd.tdata;
assign mdio_rd_tvalid = axis_mdio_rd.tvalid;
assign axis_mdio_rd.tready = 1'b1;

wire logic mdio_i, mdio_o, mdio_t;
// Explicit bidirectional buffer: this module is synthesized out of context as
// a block-design module reference, and an inferred tristate on an inout port
// loses its input side there (Vivado keeps only the OBUFT, mdio_i reads 0).
IOBUF mdio_iobuf (
    .IO(mdio),
    .I(mdio_o),
    .O(mdio_i),
    .T(mdio_t)
);

taxi_mdio_master mdio_master_inst (
    .clk(s_axi_aclk),
    .rst(logic_rst),
    .s_axis_cmd(axis_mdio_cmd),
    .m_axis_rd_data(axis_mdio_rd),
    .mdc_o(mdc),
    .mdio_i(mdio_i),
    .mdio_o(mdio_o),
    .mdio_t(mdio_t),
    .busy(mdio_busy),
    .prescale(mdio_div_reg)
);

// ---------------------------------------------------------------------------
// Optional receive-side input delay (UltraScale+ IDELAYE3, fixed, TIME mode).
// The Ethernet FMC PHYs are run with RGMII RX-clock internal delay; the delay
// here centres the data eye against the BUFG-routed RX clock. Requires one
// IDELAYCTRL in the design (util_idelay_ctrl in the block design) sharing the
// IODELAY_GROUP set in the target constraints.
// ---------------------------------------------------------------------------
// IDELAYE3's SIM_DEVICE attribute names the silicon generation and Vivado
// rejects the wrong one: "ULTRASCALE" for UltraScale (kintexu, virtexu),
// "ULTRASCALE_PLUS" for UltraScale+ (zynquplus, kintexuplus, virtexuplus, ...).
// Derive it from FAMILY so one wrapper serves both generations.
localparam string FAMILY_STR = FAMILY;
localparam string IDELAY_SIM_DEVICE =
    (FAMILY_STR == "kintexu" || FAMILY_STR == "virtexu") ? "ULTRASCALE" : "ULTRASCALE_PLUS";

wire logic [3:0] rgmii_rxd_int;
wire logic       rgmii_rx_ctl_int;

generate
if (RX_IDELAY_PS >= 0 && RX_DELAY_SRC != "NONE") begin : g_rx_idelay
    // RX_DELAY_SRC = "IDATAIN": pad -> IDELAYE3 -> IDDR (fixed delay, up to 1100 ps).
    // RX_DELAY_SRC = "DATAIN" : pad -> IBUF -> fabric -> IDELAYE3 -> IDDR. The
    //   fabric detour adds ~2 ns that scales with process like the general-routed
    //   RX clock of a non-clock-capable pin, so the eye stays centred at every
    //   corner; the router adjusts it for setup/hold. Use it for ports whose RXC
    //   is not on a clock-capable pin.
    wire logic [4:0] rx_in  = {rgmii_rx_ctl, rgmii_rxd};
    wire logic [4:0] rx_dly;
    for (genvar i = 0; i < 5; i++) begin : g_dly
        IDELAYE3 #(
            .CASCADE("NONE"),
            .DELAY_FORMAT("TIME"),
            .DELAY_SRC(RX_DELAY_SRC),
            .DELAY_TYPE("FIXED"),
            .DELAY_VALUE(RX_IDELAY_PS),
            .IS_CLK_INVERTED(1'b0),
            .IS_RST_INVERTED(1'b0),
            .REFCLK_FREQUENCY(IDELAY_REFCLK_MHZ * 1.0),
            .SIM_DEVICE(IDELAY_SIM_DEVICE),
            .UPDATE_MODE("ASYNC")
        ) idelay_inst (
            .CASC_OUT(),
            .CNTVALUEOUT(),
            .DATAOUT(rx_dly[i]),
            .CASC_IN(1'b0),
            .CASC_RETURN(1'b0),
            .CE(1'b0),
            .CLK(1'b0),
            .CNTVALUEIN(9'd0),
            .DATAIN(RX_DELAY_SRC == "DATAIN" ? rx_in[i] : 1'b0),
            .EN_VTC(1'b1),
            .IDATAIN(RX_DELAY_SRC == "IDATAIN" ? rx_in[i] : 1'b0),
            .INC(1'b0),
            .LOAD(1'b0),
            .RST(1'b0)
        );
    end
    assign rgmii_rxd_int    = rx_dly[3:0];
    assign rgmii_rx_ctl_int = rx_dly[4];
end else begin : g_no_rx_idelay
    assign rgmii_rxd_int    = rgmii_rxd;
    assign rgmii_rx_ctl_int = rgmii_rx_ctl;
end
endgenerate

// ---------------------------------------------------------------------------
// MAC (Taxi)
// ---------------------------------------------------------------------------
localparam integer TX_TAG_W = 8;

taxi_axis_if #(.DATA_W(AXIS_DATA_W), .USER_EN(1), .USER_W(1), .ID_EN(1), .ID_W(TX_TAG_W)) axis_tx();
taxi_axis_if #(.DATA_W(96), .KEEP_W(1), .ID_EN(1), .ID_W(TX_TAG_W)) axis_tx_cpl();
taxi_axis_if #(.DATA_W(AXIS_DATA_W), .USER_EN(1), .USER_W(1)) axis_rx();
taxi_axis_if #(.DATA_W(16), .KEEP_W(1), .KEEP_EN(0), .LAST_EN(0), .USER_EN(1), .USER_W(1), .ID_EN(1), .ID_W(8)) axis_stat();

assign axis_tx.tdata  = s_axis_tx_tdata;
assign axis_tx.tkeep  = s_axis_tx_tkeep;
assign axis_tx.tstrb  = s_axis_tx_tkeep;
assign axis_tx.tvalid = s_axis_tx_tvalid;
assign axis_tx.tlast  = s_axis_tx_tlast;
assign axis_tx.tuser  = '0;
assign axis_tx.tid    = '0;
assign axis_tx.tdest  = '0;
assign s_axis_tx_tready = axis_tx.tready;

assign m_axis_rx_tdata  = axis_rx.tdata;
assign m_axis_rx_tkeep  = axis_rx.tkeep;
assign m_axis_rx_tvalid = axis_rx.tvalid;
assign m_axis_rx_tlast  = axis_rx.tlast;
assign axis_rx.tready   = m_axis_rx_tready;

assign axis_tx_cpl.tready = 1'b1;
assign axis_stat.tready   = 1'b1;

taxi_eth_mac_1g_rgmii_fifo #(
    .SIM(1'b0),
    .VENDOR("XILINX"),
    .FAMILY(FAMILY),
    .USE_CLK90(USE_CLK90),
    .STAT_EN(1'b0),
    .TX_FIFO_DEPTH(TX_FIFO_DEPTH),
    .TX_FRAME_FIFO(1'b1),
    .TX_DROP_WHEN_FULL(1'b0),
    .RX_FIFO_DEPTH(RX_FIFO_DEPTH),
    .RX_FRAME_FIFO(1'b1),
    .RX_DROP_OVERSIZE_FRAME(1'b1),
    .RX_DROP_BAD_FRAME(1'b1),
    .RX_DROP_WHEN_FULL(1'b1)
) mac_inst (
    .gtx_clk(gtx_clk),
    .gtx_clk90(gtx_clk90),
    .gtx_rst(gtx_rst),
    .logic_clk(s_axi_aclk),
    .logic_rst(logic_rst),

    .s_axis_tx(axis_tx),
    .m_axis_tx_cpl(axis_tx_cpl),
    .m_axis_rx(axis_rx),

    .rgmii_rx_clk(rgmii_rx_clk),
    .rgmii_rxd(rgmii_rxd_int),
    .rgmii_rx_ctl(rgmii_rx_ctl_int),
    .rgmii_tx_clk(rgmii_tx_clk),
    .rgmii_txd(rgmii_txd),
    .rgmii_tx_ctl(rgmii_tx_ctl),

    .stat_clk(s_axi_aclk),
    .stat_rst(logic_rst),
    .m_axis_stat(axis_stat),

    .tx_error_underflow(tx_error_underflow),
    .tx_fifo_overflow(tx_fifo_overflow),
    .tx_fifo_bad_frame(tx_fifo_bad_frame),
    .tx_fifo_good_frame(tx_fifo_good_frame),
    .rx_error_bad_frame(),
    .rx_error_bad_fcs(rx_error_bad_fcs),
    .rx_fifo_overflow(rx_fifo_overflow),
    .rx_fifo_bad_frame(rx_fifo_bad_frame),
    .rx_fifo_good_frame(rx_fifo_good_frame),
    .link_speed(link_speed_int),

    .cfg_tx_pad_en(ctrl_pad_en_reg),
    .cfg_tx_min_pkt_len(8'd59),
    .cfg_tx_max_pkt_len(tx_max_len_reg),
    .cfg_tx_ifg(tx_ifg_reg),
    .cfg_tx_enable(ctrl_tx_en_reg),
    .cfg_rx_max_pkt_len(rx_max_len_reg),
    .cfg_rx_enable(ctrl_rx_en_reg)
);

endmodule

`resetall
