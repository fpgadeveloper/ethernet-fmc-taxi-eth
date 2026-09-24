/* SPDX-License-Identifier: MIT
 *
 * taxi_mac.h - register-level driver for the taxi_rgmii_mac block-design cell
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * The cell bundles the Taxi 1G RGMII MAC, the Taxi MDIO master and an
 * AXI4-Lite register file (see Vivado/src/hdl/taxi_rgmii_mac.v for the map).
 * Frames on the AXI-Stream side carry no FCS in either direction: the MAC
 * appends it on transmit (and pads to 60 bytes) and strips it on receive.
 * Bad-FCS and oversize frames are dropped in hardware; there is no address
 * filter and no checksum offload. Link speed is auto-detected from the RGMII
 * in-band status, so nothing has to be programmed after autonegotiation.
 */
#ifndef TAXI_MAC_H
#define TAXI_MAC_H

#include "xil_types.h"
#include "xil_io.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---- register map (byte offsets) ---------------------------------------- */
#define TAXI_MAC_ID            0x00 /* RO 0x54415849 "TAXI" */
#define TAXI_MAC_VERSION       0x04 /* RO */
#define TAXI_MAC_CTRL          0x08 /* RW */
#define TAXI_MAC_STATUS        0x0C /* RO */
#define TAXI_MAC_FLAGS         0x10 /* W1C */
#define TAXI_MAC_TX_IFG        0x14 /* RW [7:0] bytes */
#define TAXI_MAC_TX_MAX_LEN    0x18 /* RW [15:0] wire bytes incl. FCS, minus 1 */
#define TAXI_MAC_RX_MAX_LEN    0x1C /* RW [15:0] wire bytes incl. FCS, minus 1 */
#define TAXI_MAC_RX_GOOD_CNT   0x20 /* RO, write clears */
#define TAXI_MAC_RX_BAD_CNT    0x24
#define TAXI_MAC_TX_GOOD_CNT   0x28
#define TAXI_MAC_TX_BAD_CNT    0x2C
#define TAXI_MAC_RX_OVF_CNT    0x30
#define TAXI_MAC_TX_OVF_CNT    0x34
#define TAXI_MAC_MDIO_CMD      0x40 /* WO, writing issues the frame */
#define TAXI_MAC_MDIO_RDATA    0x44 /* RO [15:0] */
#define TAXI_MAC_MDIO_STATUS   0x48 /* RO */
#define TAXI_MAC_MDIO_DIV      0x4C /* RW [7:0] MDC half period in aclk cycles - 1 */

#define TAXI_MAC_ID_VALUE      0x54415849U

#define TAXI_MAC_CTRL_TX_EN     (1U << 0)
#define TAXI_MAC_CTRL_RX_EN     (1U << 1)
#define TAXI_MAC_CTRL_PHY_RSTN  (1U << 2) /* 0 asserts the PHY reset pin */
#define TAXI_MAC_CTRL_TX_PAD_EN (1U << 3)

#define TAXI_MAC_STATUS_SPEED_MASK 0x3U   /* 0=10M 1=100M 2=1G (RGMII in-band) */
#define TAXI_MAC_STATUS_MDIO_BUSY  (1U << 8)

#define TAXI_MAC_FLAG_TX_UNDERFLOW    (1U << 0)
#define TAXI_MAC_FLAG_TX_FIFO_OVF     (1U << 1)
#define TAXI_MAC_FLAG_TX_FIFO_BAD     (1U << 2)
#define TAXI_MAC_FLAG_RX_FIFO_OVF     (1U << 3)
#define TAXI_MAC_FLAG_RX_FIFO_BAD     (1U << 4)
#define TAXI_MAC_FLAG_RX_BAD_FCS      (1U << 5)
#define TAXI_MAC_FLAG_ALL             0x3FU

#define TAXI_MAC_MDIO_ST         (1U << 30)  /* [31:30] = 01 (Clause 22) */
#define TAXI_MAC_MDIO_OP_WRITE   (1U << 28)  /* [29:28] = 01 */
#define TAXI_MAC_MDIO_OP_READ    (2U << 28)  /* [29:28] = 10 */
#define TAXI_MAC_MDIO_PHY_SHIFT  23          /* [27:23] */
#define TAXI_MAC_MDIO_REG_SHIFT  18          /* [22:18] */
#define TAXI_MAC_MDIO_TA         (2U << 16)  /* [17:16], forced by hardware */

#define TAXI_MAC_MDIO_STATUS_BUSY     (1U << 0) /* command queued or on the wire */
#define TAXI_MAC_MDIO_STATUS_RD_VALID (1U << 1) /* cleared by an MDIO_CMD write */
#define TAXI_MAC_MDIO_STATUS_DROPPED  (1U << 2) /* sticky: CMD written while one was queued */

/* Default frame limits: 1518 wire bytes = 1500 MTU + 14 header + 4 FCS */
#define TAXI_MAC_DEFAULT_MAX_FRAME_LEN 1518

typedef struct {
	UINTPTR base;
} taxi_mac;

typedef struct {
	u32 rx_good;
	u32 rx_bad;
	u32 tx_good;
	u32 tx_bad;
	u32 rx_ovf;
	u32 tx_ovf;
} taxi_mac_counters;

static inline u32 taxi_mac_read(const taxi_mac *mac, u32 reg)
{
	return Xil_In32(mac->base + reg);
}

static inline void taxi_mac_write(const taxi_mac *mac, u32 reg, u32 val)
{
	Xil_Out32(mac->base + reg, val);
}

/* Bind to a MAC, check its ID, clear flags/counters, disable TX and RX.
 * Returns XST_SUCCESS or XST_DEVICE_NOT_FOUND. */
int taxi_mac_init(taxi_mac *mac, UINTPTR base);

/* Enable/disable the transmit and receive paths (PHY reset and padding
 * bits are preserved). */
void taxi_mac_enable(const taxi_mac *mac, int tx_en, int rx_en);

/* Pulse the PHY reset pin (CTRL bit 2) low for reset_us microseconds and
 * then wait settle_us for the PHY to come back up. */
void taxi_mac_phy_reset(const taxi_mac *mac, u32 reset_us, u32 settle_us);

/* Link speed as seen by the MAC on the RGMII in-band status, in Mbit/s
 * (10, 100 or 1000). Meaningful only while the PHY reports link up. */
u32 taxi_mac_link_speed(const taxi_mac *mac);

/* Sticky error flags (TAXI_MAC_FLAG_*); clearing is write-1-to-clear. */
u32 taxi_mac_get_flags(const taxi_mac *mac);
void taxi_mac_clear_flags(const taxi_mac *mac, u32 mask);

/* Frame counters (write clears). */
void taxi_mac_get_counters(const taxi_mac *mac, taxi_mac_counters *c);
void taxi_mac_clear_counters(const taxi_mac *mac);

/* Maximum frame length on the wire, including the FCS, for both directions.
 * Frames longer than this are dropped on receive and truncated/dropped on
 * transmit. */
void taxi_mac_set_max_frame_len(const taxi_mac *mac, u32 wire_bytes);

/* Clause 22 MDIO access through the MAC's MDIO master. Both wait for the
 * bus to be idle before issuing the command and for completion afterwards.
 * Return XST_SUCCESS, or XST_FAILURE on a timeout / dropped command. */
int taxi_mac_mdio_write(const taxi_mac *mac, u32 phy_addr, u32 reg_addr, u16 data);
int taxi_mac_mdio_read(const taxi_mac *mac, u32 phy_addr, u32 reg_addr, u16 *data);

#ifdef __cplusplus
}
#endif

#endif /* TAXI_MAC_H */
