/* SPDX-License-Identifier: MIT
 *
 * taxi_macif.h - lwIP 2.2 netif driver for Taxi RGMII MAC + AXI DMA (SG)
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * Usage (raw API, NO_SYS=1):
 *
 *   static taxi_macif_config cfg = { .port = 0, .mac_base = ..., .dma_base = ...,
 *                                    .hwaddr = {...} };
 *   netif_add(&netif, &ip, &mask, &gw, &cfg, taxi_macif_init, ethernet_input);
 *   netif_set_up(&netif);
 *   ... main loop:
 *   taxi_macif_input(&netif);          -- hand received frames to lwIP
 *   taxi_macif_link_poll(&netif);      -- about once a second
 *
 * Each netif owns one XAxiDma instance (scatter-gather, TX = MM2S, RX =
 * S2MM) with its BD rings in a non-cacheable region, an RX ring pre-filled
 * with PBUF_POOL pbufs, and the two DMA interrupts registered on the GIC via
 * the SDT interrupt wrapper. Completed receive pbufs are queued by the RX
 * interrupt and delivered to netif->input from taxi_macif_input(), like
 * xemacif_input() in the AMD lwIP port.
 */
#ifndef TAXI_MACIF_H
#define TAXI_MACIF_H

#include "lwip/netif.h"
#include "lwip/err.h"
#include "xil_types.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
	u8 port;             /* Ethernet FMC port number, for messages */
	UINTPTR mac_base;    /* taxi_rgmii_mac_N register base */
	UINTPTR dma_base;    /* axi_dma_N register base (XAxiDma_LookupConfig key) */
	u8 hwaddr[6];        /* MAC address for this port */
} taxi_macif_config;

/* netif init callback for netif_add(); netif->state must point at a
 * taxi_macif_config. On return netif->state points at the driver instance. */
err_t taxi_macif_init(struct netif *netif);

/* Deliver every queued received frame to netif->input. Returns the number
 * of frames delivered. Call from the main loop. */
int taxi_macif_input(struct netif *netif);

/* Configure the Marvell 88E1510 (RGMII, RX internal delay only, advertise
 * 10/100/1000 + pause, restart autonegotiation, soft reset). Called by
 * taxi_macif_init(); exposed so it can be re-run. */
int taxi_macif_phy_setup(struct netif *netif);

/* Block until autonegotiation completes or timeout_ms elapses.
 * Returns the negotiated speed in Mbit/s, or 0 on timeout / no link. */
u32 taxi_macif_phy_wait_autoneg(struct netif *netif, u32 timeout_ms);

/* Current PHY link state: returns 1 when the copper link is up and the
 * speed/duplex are resolved, 0 otherwise. All pointers may be NULL:
 * *speed_mbps receives the PHY's resolved speed, *full_duplex 1 for full
 * duplex, *mac_speed_mbps what the MAC sees on the RGMII in-band status. */
int taxi_macif_link_status(struct netif *netif, u32 *speed_mbps, int *full_duplex,
			   u32 *mac_speed_mbps);

/* Poll the link, log changes (speed and duplex), and call
 * netif_set_link_up/down accordingly. Returns 1 if the state changed. */
int taxi_macif_link_poll(struct netif *netif);

/* Frames delivered to netif->input and frames handed to the DMA for
 * transmission since init (either pointer may be NULL). */
void taxi_macif_get_counts(struct netif *netif, u32 *rx_delivered, u32 *tx_sent);

/* Print MAC counters / sticky error flags and driver statistics. */
void taxi_macif_print_stats(struct netif *netif);

#ifdef __cplusplus
}
#endif

#endif /* TAXI_MACIF_H */
