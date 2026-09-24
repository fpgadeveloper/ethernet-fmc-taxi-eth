/* SPDX-License-Identifier: MIT
 *
 * taxi_mac.c - register-level driver for the taxi_rgmii_mac block-design cell
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 */
#include "taxi_mac.h"
#include "xstatus.h"
#include "sleep.h"

/* An MDIO frame is 64 MDC cycles; with the default MDIO_DIV (19) at a
 * 100 MHz AXI clock MDC runs at 2.5 MHz, so a frame takes ~26 us. Poll in
 * 1 us steps for up to 20 ms before giving up. */
#define TAXI_MAC_MDIO_TIMEOUT_US 20000

int taxi_mac_init(taxi_mac *mac, UINTPTR base)
{
	mac->base = base;
	if (taxi_mac_read(mac, TAXI_MAC_ID) != TAXI_MAC_ID_VALUE) {
		return XST_DEVICE_NOT_FOUND;
	}
	/* Quiet until the netif driver has its DMA rings ready. Keep the PHY
	 * out of reset and TX padding on. */
	taxi_mac_write(mac, TAXI_MAC_CTRL,
		       TAXI_MAC_CTRL_PHY_RSTN | TAXI_MAC_CTRL_TX_PAD_EN);
	taxi_mac_set_max_frame_len(mac, TAXI_MAC_DEFAULT_MAX_FRAME_LEN);
	taxi_mac_clear_flags(mac, TAXI_MAC_FLAG_ALL);
	taxi_mac_clear_counters(mac);
	return XST_SUCCESS;
}

void taxi_mac_enable(const taxi_mac *mac, int tx_en, int rx_en)
{
	u32 ctrl = taxi_mac_read(mac, TAXI_MAC_CTRL);

	ctrl &= ~(TAXI_MAC_CTRL_TX_EN | TAXI_MAC_CTRL_RX_EN);
	if (tx_en) {
		ctrl |= TAXI_MAC_CTRL_TX_EN;
	}
	if (rx_en) {
		ctrl |= TAXI_MAC_CTRL_RX_EN;
	}
	taxi_mac_write(mac, TAXI_MAC_CTRL, ctrl);
}

void taxi_mac_phy_reset(const taxi_mac *mac, u32 reset_us, u32 settle_us)
{
	u32 ctrl = taxi_mac_read(mac, TAXI_MAC_CTRL);

	taxi_mac_write(mac, TAXI_MAC_CTRL, ctrl & ~TAXI_MAC_CTRL_PHY_RSTN);
	usleep(reset_us);
	taxi_mac_write(mac, TAXI_MAC_CTRL, ctrl | TAXI_MAC_CTRL_PHY_RSTN);
	usleep(settle_us);
}

u32 taxi_mac_link_speed(const taxi_mac *mac)
{
	switch (taxi_mac_read(mac, TAXI_MAC_STATUS) & TAXI_MAC_STATUS_SPEED_MASK) {
	case 0:
		return 10;
	case 1:
		return 100;
	default:
		return 1000;
	}
}

u32 taxi_mac_get_flags(const taxi_mac *mac)
{
	return taxi_mac_read(mac, TAXI_MAC_FLAGS) & TAXI_MAC_FLAG_ALL;
}

void taxi_mac_clear_flags(const taxi_mac *mac, u32 mask)
{
	taxi_mac_write(mac, TAXI_MAC_FLAGS, mask & TAXI_MAC_FLAG_ALL);
}

void taxi_mac_get_counters(const taxi_mac *mac, taxi_mac_counters *c)
{
	c->rx_good = taxi_mac_read(mac, TAXI_MAC_RX_GOOD_CNT);
	c->rx_bad  = taxi_mac_read(mac, TAXI_MAC_RX_BAD_CNT);
	c->tx_good = taxi_mac_read(mac, TAXI_MAC_TX_GOOD_CNT);
	c->tx_bad  = taxi_mac_read(mac, TAXI_MAC_TX_BAD_CNT);
	c->rx_ovf  = taxi_mac_read(mac, TAXI_MAC_RX_OVF_CNT);
	c->tx_ovf  = taxi_mac_read(mac, TAXI_MAC_TX_OVF_CNT);
}

void taxi_mac_clear_counters(const taxi_mac *mac)
{
	taxi_mac_write(mac, TAXI_MAC_RX_GOOD_CNT, 0);
	taxi_mac_write(mac, TAXI_MAC_RX_BAD_CNT, 0);
	taxi_mac_write(mac, TAXI_MAC_TX_GOOD_CNT, 0);
	taxi_mac_write(mac, TAXI_MAC_TX_BAD_CNT, 0);
	taxi_mac_write(mac, TAXI_MAC_RX_OVF_CNT, 0);
	taxi_mac_write(mac, TAXI_MAC_TX_OVF_CNT, 0);
}

void taxi_mac_set_max_frame_len(const taxi_mac *mac, u32 wire_bytes)
{
	u32 val = (wire_bytes - 1) & 0xFFFFU;

	taxi_mac_write(mac, TAXI_MAC_TX_MAX_LEN, val);
	taxi_mac_write(mac, TAXI_MAC_RX_MAX_LEN, val);
}

/* Wait until no MDIO command is queued or on the wire. */
static int taxi_mac_mdio_wait_idle(const taxi_mac *mac)
{
	u32 t;

	for (t = 0; t < TAXI_MAC_MDIO_TIMEOUT_US; t++) {
		if ((taxi_mac_read(mac, TAXI_MAC_MDIO_STATUS) &
		     TAXI_MAC_MDIO_STATUS_BUSY) == 0) {
			return XST_SUCCESS;
		}
		usleep(1);
	}
	return XST_FAILURE;
}

static int taxi_mac_mdio_cmd(const taxi_mac *mac, u32 cmd)
{
	if (taxi_mac_mdio_wait_idle(mac) != XST_SUCCESS) {
		return XST_FAILURE;
	}
	taxi_mac_write(mac, TAXI_MAC_MDIO_CMD, cmd);
	if (taxi_mac_mdio_wait_idle(mac) != XST_SUCCESS) {
		return XST_FAILURE;
	}
	if (taxi_mac_read(mac, TAXI_MAC_MDIO_STATUS) & TAXI_MAC_MDIO_STATUS_DROPPED) {
		return XST_FAILURE;
	}
	return XST_SUCCESS;
}

int taxi_mac_mdio_write(const taxi_mac *mac, u32 phy_addr, u32 reg_addr, u16 data)
{
	u32 cmd = TAXI_MAC_MDIO_ST | TAXI_MAC_MDIO_OP_WRITE |
		  ((phy_addr & 0x1FU) << TAXI_MAC_MDIO_PHY_SHIFT) |
		  ((reg_addr & 0x1FU) << TAXI_MAC_MDIO_REG_SHIFT) |
		  TAXI_MAC_MDIO_TA | data;

	return taxi_mac_mdio_cmd(mac, cmd);
}

int taxi_mac_mdio_read(const taxi_mac *mac, u32 phy_addr, u32 reg_addr, u16 *data)
{
	u32 cmd = TAXI_MAC_MDIO_ST | TAXI_MAC_MDIO_OP_READ |
		  ((phy_addr & 0x1FU) << TAXI_MAC_MDIO_PHY_SHIFT) |
		  ((reg_addr & 0x1FU) << TAXI_MAC_MDIO_REG_SHIFT) |
		  TAXI_MAC_MDIO_TA;

	if (taxi_mac_mdio_cmd(mac, cmd) != XST_SUCCESS) {
		return XST_FAILURE;
	}
	if ((taxi_mac_read(mac, TAXI_MAC_MDIO_STATUS) &
	     TAXI_MAC_MDIO_STATUS_RD_VALID) == 0) {
		return XST_FAILURE;
	}
	*data = (u16)(taxi_mac_read(mac, TAXI_MAC_MDIO_RDATA) & 0xFFFFU);
	return XST_SUCCESS;
}
