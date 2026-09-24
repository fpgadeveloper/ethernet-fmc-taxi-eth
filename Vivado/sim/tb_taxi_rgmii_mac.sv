// SPDX-License-Identifier: MIT
//
// tb_taxi_rgmii_mac — self-checking testbench for the taxi_rgmii_mac wrapper
// (Vivado xsim). Run with Vivado/sim/run_xsim.sh.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// What it exercises
//   * AXI-Lite register file: ID/VERSION/CTRL defaults, R/W registers, W1C
//     flags, write-to-clear counters, STATUS link speed and MDIO busy.
//   * MDIO: Clause-22 write and read through the Taxi MDIO master against a
//     behavioural PHY slave model (32-entry register file on a pulled-up MDIO
//     wire). The model samples on the MDC rising edge and, during a read,
//     drives its data shortly AFTER the MDC rising edge as IEEE 802.3
//     22.3.4 / Fig 22-13 requires; the Taxi master samples MDIO one clock
//     before the MDC falling edge, so a PHY that only updated on the falling
//     edge would be read one bit late.
//   * Ethernet data path: RGMII TX looped back to RGMII RX (USE_CLK90 puts
//     the TX clock in the centre of the data eye). Frames are pushed into
//     s_axis_tx (32-bit, tkeep on the last beat) and collected from
//     m_axis_rx; every received frame is compared byte for byte with the
//     sent frame. A wire-level RGMII sniffer reassembles each transmitted
//     frame and verifies the FCS the MAC appended with a CRC-32 function.
//   * Oversize drop: RX_MAX_LEN lowered, oversize frame sent, expect no RX
//     frame, RX_BAD_CNT increment and the rx_fifo_bad_frame flag.
//
// FCS finding: the Taxi RX MAC (taxi_axis_gmii_rx) STRIPS the FCS — the
// received AXI-Stream frame equals the sent frame (no trailing 4 bytes).

`timescale 1ns / 1ps
`default_nettype none

module tb_taxi_rgmii_mac;

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
localparam integer AXIS_DATA_W = 32;
localparam         FAMILY      = "zynquplus";
localparam logic   USE_CLK90   = 1'b1;
localparam integer C_ADDR_W    = 8;

localparam logic [4:0] PHY_ADDR = 5'd3;
localparam time        PHY_DLY  = 10ns;     // PHY MDIO output delay after MDC rising edge
localparam integer     MAXF     = 2048;     // max frame bytes handled by the TB buffers

// register map
localparam [7:0] R_ID = 8'h00, R_VERSION = 8'h04, R_CTRL = 8'h08, R_STATUS = 8'h0C,
                 R_FLAGS = 8'h10, R_TX_IFG = 8'h14, R_TX_MAX_LEN = 8'h18, R_RX_MAX_LEN = 8'h1C,
                 R_RX_GOOD_CNT = 8'h20, R_RX_BAD_CNT = 8'h24, R_TX_GOOD_CNT = 8'h28,
                 R_TX_BAD_CNT = 8'h2C, R_RX_OVF_CNT = 8'h30, R_TX_OVF_CNT = 8'h34,
                 R_MDIO_CMD = 8'h40, R_MDIO_RDATA = 8'h44, R_MDIO_STATUS = 8'h48, R_MDIO_DIV = 8'h4C;

// ---------------------------------------------------------------------------
// Clocks and resets
// ---------------------------------------------------------------------------
logic s_axi_aclk = 1'b0;
logic gtx_clk    = 1'b0;
logic gtx_clk90  = 1'b0;
logic s_axi_aresetn = 1'b0;
logic gtx_aresetn   = 1'b0;

always #5.0 s_axi_aclk = ~s_axi_aclk;          // 100 MHz
always #4.0 gtx_clk    = ~gtx_clk;             // 125 MHz
always @(gtx_clk) gtx_clk90 <= #2.0 gtx_clk;   // 90 degrees = 2 ns

initial begin
    repeat (20) @(posedge s_axi_aclk);
    s_axi_aresetn <= 1'b1;
end
initial begin
    repeat (20) @(posedge gtx_clk);
    gtx_aresetn <= 1'b1;
end

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
logic [C_ADDR_W-1:0] s_axi_awaddr = '0;
logic                s_axi_awvalid = 1'b0;
wire                 s_axi_awready;
logic [31:0]         s_axi_wdata = '0;
logic [3:0]          s_axi_wstrb = '0;
logic                s_axi_wvalid = 1'b0;
wire                 s_axi_wready;
wire  [1:0]          s_axi_bresp;
wire                 s_axi_bvalid;
logic                s_axi_bready = 1'b0;
logic [C_ADDR_W-1:0] s_axi_araddr = '0;
logic                s_axi_arvalid = 1'b0;
wire                 s_axi_arready;
wire  [31:0]         s_axi_rdata;
wire  [1:0]          s_axi_rresp;
wire                 s_axi_rvalid;
logic                s_axi_rready = 1'b0;

logic [AXIS_DATA_W-1:0]   s_axis_tx_tdata = '0;
logic [AXIS_DATA_W/8-1:0] s_axis_tx_tkeep = '0;
logic                     s_axis_tx_tvalid = 1'b0;
wire                      s_axis_tx_tready;
logic                     s_axis_tx_tlast = 1'b0;

wire  [AXIS_DATA_W-1:0]   m_axis_rx_tdata;
wire  [AXIS_DATA_W/8-1:0] m_axis_rx_tkeep;
wire                      m_axis_rx_tvalid;
logic                     m_axis_rx_tready = 1'b1;
wire                      m_axis_rx_tlast;

// RGMII loopback wires (TX -> RX)
wire        rgmii_clk;
wire [3:0]  rgmii_d;
wire        rgmii_ctl;

wire        mdc;
wire        mdio;
wire        phy_reset_n;
wire [1:0]  link_speed;

pullup (mdio);

// ---------------------------------------------------------------------------
// DUT
// ---------------------------------------------------------------------------
taxi_rgmii_mac #(
    .AXIS_DATA_W(AXIS_DATA_W),
    .FAMILY(FAMILY),
    .USE_CLK90(USE_CLK90),
    .C_S_AXI_ADDR_WIDTH(C_ADDR_W)
) dut (
    .s_axi_aclk(s_axi_aclk),
    .s_axi_aresetn(s_axi_aresetn),
    .s_axi_awaddr(s_axi_awaddr), .s_axi_awprot(3'b000), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr), .s_axi_arprot(3'b000), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
    .s_axis_tx_tdata(s_axis_tx_tdata), .s_axis_tx_tkeep(s_axis_tx_tkeep), .s_axis_tx_tvalid(s_axis_tx_tvalid),
    .s_axis_tx_tready(s_axis_tx_tready), .s_axis_tx_tlast(s_axis_tx_tlast),
    .m_axis_rx_tdata(m_axis_rx_tdata), .m_axis_rx_tkeep(m_axis_rx_tkeep), .m_axis_rx_tvalid(m_axis_rx_tvalid),
    .m_axis_rx_tready(m_axis_rx_tready), .m_axis_rx_tlast(m_axis_rx_tlast),
    .gtx_clk(gtx_clk), .gtx_clk90(gtx_clk90), .gtx_aresetn(gtx_aresetn),
    .rgmii_rx_clk(rgmii_clk), .rgmii_rxd(rgmii_d), .rgmii_rx_ctl(rgmii_ctl),
    .rgmii_tx_clk(rgmii_clk), .rgmii_txd(rgmii_d), .rgmii_tx_ctl(rgmii_ctl),
    .mdc(mdc), .mdio(mdio), .phy_reset_n(phy_reset_n),
    .link_speed(link_speed)
);

// ---------------------------------------------------------------------------
// Scoreboard helpers
// ---------------------------------------------------------------------------
int n_err = 0;
int n_pass = 0;

task automatic check(input string name, input logic [31:0] got, input logic [31:0] exp);
    if (got === exp) begin
        n_pass++;
        $display("PASS [%0t] %s = 0x%08x", $time, name, got);
    end else begin
        n_err++;
        $display("FAIL [%0t] %s = 0x%08x, expected 0x%08x", $time, name, got, exp);
    end
endtask

// ---------------------------------------------------------------------------
// AXI-Lite master tasks
// ---------------------------------------------------------------------------
task automatic axil_write(input logic [7:0] addr, input logic [31:0] data);
    bit aw_done = 0, w_done = 0, b_done = 0;
    @(posedge s_axi_aclk);
    s_axi_awaddr  <= addr[C_ADDR_W-1:0];
    s_axi_awvalid <= 1'b1;
    s_axi_wdata   <= data;
    s_axi_wstrb   <= 4'hF;
    s_axi_wvalid  <= 1'b1;
    s_axi_bready  <= 1'b1;
    while (!(aw_done && w_done && b_done)) begin
        @(posedge s_axi_aclk);
        if (!aw_done && s_axi_awready) begin aw_done = 1; s_axi_awvalid <= 1'b0; end
        if (!w_done  && s_axi_wready)  begin w_done  = 1; s_axi_wvalid  <= 1'b0; end
        if (!b_done  && s_axi_bvalid)  begin b_done  = 1; s_axi_bready  <= 1'b0; end
    end
endtask

task automatic axil_read(input logic [7:0] addr, output logic [31:0] data);
    bit ar_done = 0, r_done = 0;
    @(posedge s_axi_aclk);
    s_axi_araddr  <= addr[C_ADDR_W-1:0];
    s_axi_arvalid <= 1'b1;
    s_axi_rready  <= 1'b1;
    while (!(ar_done && r_done)) begin
        @(posedge s_axi_aclk);
        if (!ar_done && s_axi_arready) begin ar_done = 1; s_axi_arvalid <= 1'b0; end
        if (!r_done  && s_axi_rvalid)  begin r_done  = 1; data = s_axi_rdata; s_axi_rready <= 1'b0; end
    end
endtask

task automatic axil_check(input string name, input logic [7:0] addr, input logic [31:0] exp);
    logic [31:0] v;
    axil_read(addr, v);
    check(name, v, exp);
endtask

// ---------------------------------------------------------------------------
// MDIO Clause-22 PHY slave model
//   Samples MDIO on the MDC rising edge. Frame: >=32 preamble ones, ST=01,
//   OP (01 write / 10 read), PHYAD[4:0], REGAD[4:0], TA, DATA[15:0].
//   On a read it drives TA0=0 and the 16 data bits, each PHY_DLY after the
//   MDC rising edge that precedes the bit period (802.3 22.3.4).
// ---------------------------------------------------------------------------
logic [15:0] phy_regs [0:31];
logic        phy_mdio_oe = 1'b0;
logic        phy_mdio_o  = 1'b0;
assign mdio = phy_mdio_oe ? phy_mdio_o : 1'bz;

int          phy_ones   = 0;
int          phy_state  = 0;      // 0 = preamble hunt, 1 = in frame
int          phy_bit    = 0;      // 1-based bit index within the 32-bit frame
logic [12:0] phy_hdr    = '0;     // ST0, OP[1:0], PHYAD[4:0], REGAD[4:0]
logic [15:0] phy_wdata  = '0;
logic [15:0] phy_rdata  = '0;
logic        phy_is_rd  = 1'b0;
logic        phy_is_wr  = 1'b0;
int          phy_n_wr   = 0;
int          phy_n_rd   = 0;

initial begin
    for (int i = 0; i < 32; i++) phy_regs[i] = '0;
    phy_regs[2] = 16'h0141;   // PHY ID1 (Marvell OUI) — pre-loaded, read without prior write
    phy_regs[3] = 16'h0DD0;
end

always @(posedge mdc) begin
    case (phy_state)
        0: begin
            if (mdio === 1'b1) begin
                phy_ones++;
            end else begin
                if (phy_ones >= 32 && mdio === 1'b0) begin
                    phy_state = 1;      // this bit is ST[1] = 0
                    phy_bit   = 1;
                    phy_hdr   = '0;
                    phy_is_rd = 1'b0;
                    phy_is_wr = 1'b0;
                end
                phy_ones = 0;
            end
        end
        1: begin
            phy_bit++;
            if (phy_bit <= 14) begin
                phy_hdr = {phy_hdr[11:0], mdio};       // bits 2..14
            end
            if (phy_bit == 14) begin
                // phy_hdr = {ST0, OP[1:0], PHYAD[4:0], REGAD[4:0]}
                if (phy_hdr[12] !== 1'b1) $display("PHY model: bad ST0 at %0t", $time);
                phy_is_rd = (phy_hdr[11:10] == 2'b10) && (phy_hdr[9:5] == PHY_ADDR);
                phy_is_wr = (phy_hdr[11:10] == 2'b01) && (phy_hdr[9:5] == PHY_ADDR);
                phy_rdata = phy_regs[phy_hdr[4:0]];
                $display("PHY model: %s phyad=%0d regad=%0d", phy_hdr[11:10] == 2'b10 ? "READ " : "WRITE",
                         phy_hdr[9:5], phy_hdr[4:0]);
            end
            if (phy_bit == 15) begin
                // TA1 sampled (master released the bus); drive TA0 = 0 for a read
                if (phy_is_rd) begin
                    phy_mdio_oe <= #PHY_DLY 1'b1;
                    phy_mdio_o  <= #PHY_DLY 1'b0;
                end
            end else if (phy_bit >= 16 && phy_bit <= 31) begin
                // after edge 16 drive D15 ... after edge 31 drive D0
                if (phy_is_rd) phy_mdio_o <= #PHY_DLY phy_rdata[31 - phy_bit];
            end
            if (phy_bit >= 17) begin
                phy_wdata = {phy_wdata[14:0], mdio};   // bits 17..32 = D15..D0
            end
            if (phy_bit == 32) begin
                if (phy_is_rd) begin
                    phy_mdio_oe <= #PHY_DLY 1'b0;
                    phy_n_rd++;
                end else if (phy_is_wr) begin
                    phy_regs[phy_hdr[4:0]] = phy_wdata;
                    phy_n_wr++;
                    $display("PHY model: reg %0d <= 0x%04x", phy_hdr[4:0], phy_wdata);
                end
                phy_state = 0;
                phy_ones  = 0;
            end
        end
    endcase
end

// wrapper MDIO helpers
function automatic logic [31:0] mdio_cmd(input logic [1:0] op, input logic [4:0] phyad,
                                         input logic [4:0] regad, input logic [15:0] data);
    return {2'b01, op, phyad, regad, 2'b10, data};
endfunction

task automatic mdio_wait_idle(input string name);
    logic [31:0] v;
    int n = 0;
    do begin
        axil_read(R_MDIO_STATUS, v);
        n++;
    end while (v[0] && n < 20000);
    check({name, " MDIO_STATUS.busy==0"}, v[0], 1'b0);
endtask

task automatic mdio_wait_rd_valid(input string name);
    logic [31:0] v;
    int n = 0;
    do begin
        axil_read(R_MDIO_STATUS, v);
        n++;
    end while (!v[1] && n < 20000);
    check({name, " MDIO_STATUS.rd_valid==1"}, v[1], 1'b1);
    // NOTE: rd_valid is set when the Taxi master captures the 16th data bit,
    // about one MDC period BEFORE busy drops (the master still emits its
    // final MDC pulse). A MDIO_CMD write while busy is silently ignored by the
    // wrapper, so a driver must poll busy==0 before issuing the next command.
    mdio_wait_idle({name, " (drain)"});
endtask

// ---------------------------------------------------------------------------
// CRC-32 (IEEE 802.3, reflected, init/final 0xFFFFFFFF)
// ---------------------------------------------------------------------------
function automatic logic [31:0] crc32_bytes(input logic [7:0] buf_ [0:MAXF-1], input int len);
    logic [31:0] c = 32'hFFFFFFFF;
    for (int i = 0; i < len; i++) begin
        c = c ^ {24'd0, buf_[i]};
        for (int b = 0; b < 8; b++) c = c[0] ? (c >> 1) ^ 32'hEDB88320 : (c >> 1);
    end
    return ~c;
endfunction

// ---------------------------------------------------------------------------
// Frame generation / expected list
// ---------------------------------------------------------------------------
logic [7:0] tx_frame [0:MAXF-1];
int         tx_len = 0;
int         tx_seq = 0;

localparam integer MAX_EXP = 32;
logic [7:0] exp_buf [0:MAX_EXP-1][0:MAXF-1];
int         exp_len [0:MAX_EXP-1];
int         exp_wr = 0;
int         sent_lens [0:MAX_EXP-1];   // bytes handed to s_axis_tx per frame
int         wire_lens [0:MAX_EXP-1];   // bytes seen on the RGMII wire after SFD (incl. FCS)

task automatic build_frame(input logic [47:0] dst, input logic [47:0] src, input logic [15:0] etype,
                           input int payload_len);
    tx_len = 14 + payload_len;
    for (int i = 0; i < 6; i++) tx_frame[i]     = dst[8*(5-i) +: 8];
    for (int i = 0; i < 6; i++) tx_frame[6 + i] = src[8*(5-i) +: 8];
    tx_frame[12] = etype[15:8];
    tx_frame[13] = etype[7:0];
    for (int i = 0; i < payload_len; i++) tx_frame[14 + i] = 8'((i + 7 * tx_seq) & 8'hFF) ^ 8'(tx_seq);
    tx_seq++;
endtask

task automatic add_expected();
    exp_len[exp_wr] = tx_len;
    for (int i = 0; i < tx_len; i++) exp_buf[exp_wr][i] = tx_frame[i];
    exp_wr++;
endtask

// AXI-Stream sender (32-bit, tkeep on last beat, honours tready)
task automatic axis_send();
    int i = 0;
    @(posedge s_axi_aclk);      // align: the task may be entered mid-cycle
    while (i < tx_len) begin
        logic [AXIS_DATA_W-1:0]   d = '0;
        logic [AXIS_DATA_W/8-1:0] k = '0;
        for (int b = 0; b < AXIS_DATA_W/8; b++) begin
            if (i + b < tx_len) begin
                d[8*b +: 8] = tx_frame[i + b];
                k[b] = 1'b1;
            end
        end
        s_axis_tx_tdata  <= d;
        s_axis_tx_tkeep  <= k;
        s_axis_tx_tvalid <= 1'b1;
        s_axis_tx_tlast  <= (i + AXIS_DATA_W/8 >= tx_len);
        do @(posedge s_axi_aclk); while (!s_axis_tx_tready);
        i += AXIS_DATA_W/8;
    end
    s_axis_tx_tvalid <= 1'b0;
    s_axis_tx_tlast  <= 1'b0;
    s_axis_tx_tkeep  <= '0;
endtask

task automatic send_frame(input int payload_len, input bit expect_rx);
    build_frame(48'h02_00_5E_00_00_01, 48'h02_00_5E_00_00_02, 16'h88B5, payload_len);
    if (expect_rx) add_expected();
    if (tx_seq - 1 < MAX_EXP) sent_lens[tx_seq - 1] = tx_len;
    $display("TB  [%0t] sending frame #%0d, %0d bytes (payload %0d)%s", $time, tx_seq - 1, tx_len,
             payload_len, expect_rx ? "" : " (expect drop)");
    axis_send();
endtask

// ---------------------------------------------------------------------------
// AXI-Stream RX monitor + comparator
// ---------------------------------------------------------------------------
logic [7:0] rx_buf [0:MAXF-1];
int         rx_len = 0;
int         rx_frames = 0;       // frames received
int         rx_beats_stalled = 0; // beats seen with tready low (proves back-pressure exercised)
bit         rx_tready_random = 1'b0;

always @(posedge s_axi_aclk) begin
    m_axis_rx_tready <= rx_tready_random ? ($urandom % 2) : 1'b1;
end

always @(posedge s_axi_aclk) begin
    if (m_axis_rx_tvalid && !m_axis_rx_tready) rx_beats_stalled++;
    if (m_axis_rx_tvalid && m_axis_rx_tready) begin
        for (int b = 0; b < AXIS_DATA_W/8; b++) begin
            if (m_axis_rx_tkeep[b]) begin
                if (rx_len < MAXF) rx_buf[rx_len] = m_axis_rx_tdata[8*b +: 8];
                rx_len++;
            end
        end
        if (m_axis_rx_tlast) begin
            if (rx_frames < exp_wr) begin
                int bad = 0;
                int first_bad = -1;
                if (rx_len != exp_len[rx_frames]) bad = 1;
                for (int i = 0; i < rx_len && i < exp_len[rx_frames]; i++)
                    if (rx_buf[i] !== exp_buf[rx_frames][i]) begin bad++; if (first_bad < 0) first_bad = i; end
                if (bad == 0) begin
                    n_pass++;
                    $display("PASS [%0t] rx frame #%0d: %0d bytes match sent frame", $time, rx_frames, rx_len);
                end else begin
                    n_err++;
                    $display("FAIL [%0t] rx frame #%0d: got %0d bytes, expected %0d, first mismatch at byte %0d",
                             $time, rx_frames, rx_len, exp_len[rx_frames], first_bad);
                end
            end else begin
                n_err++;
                $display("FAIL [%0t] unexpected rx frame #%0d (%0d bytes)", $time, rx_frames, rx_len);
            end
            rx_frames++;
            rx_len = 0;
        end
    end
end

task automatic wait_rx_frames(input int n, input time timeout);
    time t0 = $time;
    while (rx_frames < n && ($time - t0) < timeout) #100ns;
    if (rx_frames < n) begin
        n_err++;
        $display("FAIL [%0t] timeout waiting for %0d rx frames (have %0d)", $time, n, rx_frames);
    end
endtask

// ---------------------------------------------------------------------------
// RGMII wire sniffer: reassembles what the MAC put on the wire and checks the
// appended FCS with the CRC-32 function above.
// ---------------------------------------------------------------------------
logic [7:0] wire_buf [0:MAXF-1];
int         wire_len = 0;
bit         wire_active = 1'b0;
logic [3:0] wire_lo = '0;
int         wire_frames = 0;
int         wire_fcs_ok = 0;
int         wire_last_len = 0;    // bytes after SFD, incl. FCS

always @(posedge rgmii_clk) begin
    if (rgmii_ctl === 1'b1) begin
        wire_lo = rgmii_d;
        wire_active = 1'b1;
    end else if (wire_active) begin
        // end of frame: strip preamble/SFD, check FCS
        int sfd = -1;
        for (int i = 0; i < wire_len && sfd < 0; i++) if (wire_buf[i] == 8'hD5) sfd = i;
        if (sfd >= 0 && wire_len - sfd - 1 >= 4) begin
            logic [7:0]  fbuf [0:MAXF-1];
            int          flen = wire_len - sfd - 1;      // frame + FCS
            logic [31:0] crc, fcs;
            for (int i = 0; i < flen; i++) fbuf[i] = wire_buf[sfd + 1 + i];
            crc = crc32_bytes(fbuf, flen - 4);
            fcs = {fbuf[flen-1], fbuf[flen-2], fbuf[flen-3], fbuf[flen-4]};
            wire_last_len = flen;
            if (wire_frames < MAX_EXP) wire_lens[wire_frames] = flen;
            if (crc == fcs) wire_fcs_ok++;
            else $display("FAIL [%0t] wire frame #%0d: FCS 0x%08x, computed 0x%08x (len %0d)",
                          $time, wire_frames, fcs, crc, flen);
        end else begin
            $display("FAIL [%0t] wire frame #%0d: no SFD / too short (%0d nibble-bytes)", $time, wire_frames, wire_len);
        end
        wire_frames++;
        wire_len = 0;
        wire_active = 1'b0;
    end
end

always @(negedge rgmii_clk) begin
    if (wire_active) begin
        if (wire_len < MAXF) wire_buf[wire_len] = {rgmii_d, wire_lo};
        wire_len++;
    end
end

// ---------------------------------------------------------------------------
// Test sequence
// ---------------------------------------------------------------------------
logic [31:0] v;
int          wire_frames_before;
int          rx_frames_before;

initial begin
    $display("TB: taxi_rgmii_mac testbench start (AXIS_DATA_W=%0d, FAMILY=%s, USE_CLK90=%0d)",
             AXIS_DATA_W, FAMILY, USE_CLK90);

    wait (s_axi_aresetn && gtx_aresetn);
    // Let the RGMII loopback clock run so the PHY-if speed detector settles.
    // taxi_rgmii_phy_if counts rx_clk/8 toggles against gtx_clk: 4 toggles
    // (32 rx clocks) before 128 gtx clocks -> 1G. Resets to 2'b10 anyway.
    #5us;

    // ---- register file -----------------------------------------------------
    $display("TB: --- register file ---");
    axil_check("ID",            R_ID,       32'h54415849);
    axil_check("VERSION",       R_VERSION,  32'h00010000);
    axil_check("CTRL reset",    R_CTRL,     32'h0000000F);
    axil_check("TX_IFG reset",  R_TX_IFG,   32'd12);
    axil_check("TX_MAX_LEN reset", R_TX_MAX_LEN, 32'd1517);
    axil_check("RX_MAX_LEN reset", R_RX_MAX_LEN, 32'd1517);
    axil_check("MDIO_DIV reset", R_MDIO_DIV, 32'd19);
    axil_write(R_TX_MAX_LEN, 32'd9000);
    axil_check("TX_MAX_LEN readback", R_TX_MAX_LEN, 32'd9000);
    axil_read(R_STATUS, v);
    check("STATUS.link_speed (1G)", v[1:0], 2'b10);
    check("STATUS.mdio_busy idle", v[8], 1'b0);
    check("link_speed port (1G)", link_speed, 2'b10);
    check("phy_reset_n port", phy_reset_n, 1'b1);
    axil_check("MDIO_STATUS idle", R_MDIO_STATUS, 32'h0);

    // ---- MDIO --------------------------------------------------------------
    $display("TB: --- MDIO ---");
    axil_write(R_MDIO_DIV, 32'd4);
    axil_check("MDIO_DIV readback", R_MDIO_DIV, 32'd4);

    axil_write(R_MDIO_CMD, mdio_cmd(2'b01, PHY_ADDR, 5'h10, 16'hBEEF));
    axil_read(R_MDIO_STATUS, v);
    check("MDIO write: busy right after CMD", v[0], 1'b1);
    axil_read(R_STATUS, v);
    check("STATUS.mdio_busy during write", v[8], 1'b1);
    mdio_wait_idle("MDIO write:");
    check("PHY model reg 0x10 after write", phy_regs[5'h10], 16'hBEEF);
    check("PHY model write count", phy_n_wr, 1);

    axil_write(R_MDIO_CMD, mdio_cmd(2'b10, PHY_ADDR, 5'h10, 16'h0000));
    axil_read(R_MDIO_STATUS, v);
    check("MDIO read: rd_valid cleared by CMD", v[1], 1'b0);
    mdio_wait_rd_valid("MDIO read 0x10:");
    axil_check("MDIO_RDATA reg 0x10", R_MDIO_RDATA, 32'h0000BEEF);

    axil_write(R_MDIO_CMD, mdio_cmd(2'b10, PHY_ADDR, 5'd2, 16'h0000));
    mdio_wait_rd_valid("MDIO read reg 2:");
    axil_check("MDIO_RDATA reg 2 (PHY ID1, preloaded)", R_MDIO_RDATA, 32'h00000141);
    check("PHY model read count", phy_n_rd, 2);

    // ---- Ethernet traffic --------------------------------------------------
    $display("TB: --- Ethernet loopback traffic ---");
    axil_check("FLAGS clean before traffic", R_FLAGS, 32'h0);

    send_frame(46, 1);                     // 60-byte minimum frame
    wait_rx_frames(1, 50us);
    send_frame(186, 1);                    // 200-byte frame
    wait_rx_frames(2, 50us);

    rx_tready_random = 1'b1;               // back-pressure phase
    send_frame(1500, 1);                   // 1514-byte frame (1500 payload)
    wait_rx_frames(3, 100us);
    for (int i = 0; i < 5; i++) send_frame(286, 1);   // 5 x 300 bytes back-to-back
    wait_rx_frames(8, 200us);
    rx_tready_random = 1'b0;
    #1us;
    check("rx tready back-pressure exercised (stalled beats > 0)", rx_beats_stalled > 0, 1'b1);
    check("rx frames received", rx_frames, 8);

    axil_check("RX_GOOD_CNT == 8", R_RX_GOOD_CNT, 32'd8);
    axil_check("TX_GOOD_CNT == 8", R_TX_GOOD_CNT, 32'd8);
    axil_check("RX_BAD_CNT == 0",  R_RX_BAD_CNT,  32'd0);
    axil_check("TX_BAD_CNT == 0",  R_TX_BAD_CNT,  32'd0);
    axil_check("RX_OVF_CNT == 0",  R_RX_OVF_CNT,  32'd0);
    axil_check("TX_OVF_CNT == 0",  R_TX_OVF_CNT,  32'd0);
    axil_check("FLAGS == 0 after traffic", R_FLAGS, 32'h0);
    axil_write(R_FLAGS, 32'h3F);
    axil_check("FLAGS after W1C", R_FLAGS, 32'h0);
    axil_write(R_RX_GOOD_CNT, 32'h1);
    axil_check("RX_GOOD_CNT after clear", R_RX_GOOD_CNT, 32'd0);
    axil_write(R_TX_GOOD_CNT, 32'h1);
    axil_check("TX_GOOD_CNT after clear", R_TX_GOOD_CNT, 32'd0);

    // ---- oversize drop -----------------------------------------------------
    $display("TB: --- oversize drop ---");
    axil_write(R_RX_MAX_LEN, 32'd299);
    axil_check("RX_MAX_LEN = 299", R_RX_MAX_LEN, 32'd299);
    rx_frames_before   = rx_frames;
    wire_frames_before = wire_frames;
    send_frame(386, 0);                    // 400-byte frame, must be dropped
    #20us;
    check("oversize: no rx frame delivered", rx_frames, rx_frames_before);
    check("oversize: frame was transmitted on the wire", wire_frames, wire_frames_before + 1);
    check("oversize: wire length incl. FCS = 404", wire_last_len, 404);
    axil_check("oversize: RX_BAD_CNT == 1", R_RX_BAD_CNT, 32'd1);
    axil_check("oversize: TX_GOOD_CNT == 1", R_TX_GOOD_CNT, 32'd1);
    axil_check("oversize: RX_GOOD_CNT == 0", R_RX_GOOD_CNT, 32'd0);
    axil_read(R_FLAGS, v);
    check("oversize: FLAGS.rx_fifo_bad_frame set", v[4], 1'b1);
    check("oversize: FLAGS.rx_bad_fcs clear", v[5], 1'b0);
    axil_write(R_FLAGS, 32'h3F);
    axil_check("oversize: FLAGS cleared", R_FLAGS, 32'h0);
    axil_write(R_RX_BAD_CNT, 32'h1);
    axil_check("oversize: RX_BAD_CNT cleared", R_RX_BAD_CNT, 32'd0);
    axil_write(R_RX_MAX_LEN, 32'd1517);
    axil_check("RX_MAX_LEN restored", R_RX_MAX_LEN, 32'd1517);

    // recovery: a normal frame gets through again
    send_frame(286, 1);
    wait_rx_frames(9, 50us);
    #1us;
    axil_check("recovery: RX_GOOD_CNT == 1", R_RX_GOOD_CNT, 32'd1);
    axil_check("recovery: RX_BAD_CNT == 0",  R_RX_BAD_CNT,  32'd0);

    // ---- final status --------------------------------------------------------
    axil_read(R_STATUS, v);
    check("STATUS.link_speed still 1G", v[1:0], 2'b10);
    check("link_speed port still 1G", link_speed, 2'b10);
    check("wire frames seen", wire_frames, 10);
    check("wire frames with good FCS", wire_fcs_ok, 10);
    for (int i = 0; i < 10; i++) begin
        check($sformatf("wire frame #%0d length == sent + 4 (FCS)", i), wire_lens[i], sent_lens[i] + 4);
    end
    axil_check("FLAGS clean at end", R_FLAGS, 32'h0);

    $display("TB: %0d checks passed, %0d errors, simulated time %0t", n_pass, n_err, $time);
    if (n_err == 0) $display("TB RESULT: PASS");
    else            $display("TB RESULT: FAIL (%0d errors)", n_err);
    $finish;
end

// global watchdog
initial begin
    #1500us;
    $display("FAIL: watchdog timeout");
    $display("TB RESULT: FAIL (%0d errors)", n_err + 1);
    $finish;
end

endmodule

`default_nettype wire
