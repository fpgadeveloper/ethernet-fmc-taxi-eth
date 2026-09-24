/* SPDX-License-Identifier: MIT
 *
 * main.c - lwIP TCP echo server on all four Ethernet FMC ports
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * Each Ethernet FMC port is a Taxi RGMII MAC + AXI DMA pair driven by the
 * taxi_macif netif driver. One TCP echo server (port 7, echo.c from the AMD
 * lwip_echo_server template) is bound to IP_ANY_TYPE, so it accepts on every
 * netif.
 *
 * Addressing: DHCP by default (like the ethernet-fmc-axi-eth echo server).
 * A port starts its DHCP client when its link comes up; if no lease arrives
 * within DHCP_TIMEOUT_MS it falls back to the static address
 * 192.168.1.(10+N)/24. Build with -DTAXI_ETH_FORCE_STATIC=1 (or set it
 * below) to skip DHCP and use the static addresses from the start.
 *
 * Timers: the AMD lwIP port is built with NO_SYS_NO_TIMERS=1
 * (lwip220_no_sys_no_timers, default on), which compiles out
 * sys_check_timeouts(), so like the template we drive tcp_fasttmr() /
 * tcp_slowtmr() and dhcp_fine_tmr() / dhcp_coarse_tmr() from a 50 ms
 * xiltimer tick.
 */
#include <stdio.h>
#include <string.h>

#include "xparameters.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "xiltimer.h"
#include "xinterrupt_wrap.h"
#include "sleep.h"

#include "lwip/init.h"
#include "lwip/netif.h"
#include "lwip/tcp.h"
#include "lwip/priv/tcp_priv.h"   /* tcp_fasttmr / tcp_slowtmr */
#include "lwip/ip4_addr.h"
#include "netif/ethernet.h"
#if LWIP_DHCP
#include "lwip/dhcp.h"
#endif

#include "taxi_mac_hw.h"
#include "taxi_macif.h"

/* Compile-time switch: 1 = static addresses only, no DHCP */
#ifndef TAXI_ETH_FORCE_STATIC
#define TAXI_ETH_FORCE_STATIC 0
#endif
#if LWIP_DHCP && !TAXI_ETH_FORCE_STATIC
#define USE_DHCP 1
#else
#define USE_DHCP 0
#endif

/* Static addressing (fallback): 192.168.1.10 + port, /24, gateway .1 */
#define STATIC_IP_LAST_OCTET   10
#define DHCP_TIMEOUT_MS        10000

/* xiltimer tick: 50 ms; tcp_fasttmr every 250 ms, tcp_slowtmr every 500 ms,
 * link/DHCP poll every second */
#define TICK_MS              50
#define TCP_FAST_TICKS       (250 / TICK_MS)
#define TCP_SLOW_TICKS       (500 / TICK_MS)
#define POLL_TICKS           (1000 / TICK_MS)
#if USE_DHCP
#define DHCP_FINE_TICKS      (DHCP_FINE_TIMER_MSECS / TICK_MS)
#define DHCP_COARSE_TICKS    (DHCP_COARSE_TIMER_MSECS / TICK_MS)
#endif
#define DHCP_TIMEOUT_TICKS   (DHCP_TIMEOUT_MS / TICK_MS)
#define AUTONEG_WAIT_MS      5000

/* from echo.c */
void print_app_header(void);
int start_application(void);
int transfer_data(void);

/* per-port address state */
enum addr_state {
	ADDR_NONE = 0,     /* no address yet (waiting for link / DHCP) */
	ADDR_DHCP_WAIT,    /* DHCP client running, no lease yet */
	ADDR_DHCP,         /* DHCP lease in use */
	ADDR_STATIC        /* static address in use */
};

static struct netif netifs[TAXI_ETH_NUM_PORTS];
static taxi_macif_config port_cfg[TAXI_ETH_NUM_PORTS] = {
	{ 0, TAXI_MAC_0_BASEADDR, TAXI_DMA_0_BASEADDR, { 0x00, 0x0a, 0x35, 0x06, 0x21, 0x05 } },
	{ 1, TAXI_MAC_1_BASEADDR, TAXI_DMA_1_BASEADDR, { 0x00, 0x0a, 0x35, 0x06, 0x21, 0x06 } },
	{ 2, TAXI_MAC_2_BASEADDR, TAXI_DMA_2_BASEADDR, { 0x00, 0x0a, 0x35, 0x06, 0x21, 0x07 } },
	{ 3, TAXI_MAC_3_BASEADDR, TAXI_DMA_3_BASEADDR, { 0x00, 0x0a, 0x35, 0x06, 0x21, 0x08 } },
};
static int port_ok[TAXI_ETH_NUM_PORTS];
static enum addr_state addr_state[TAXI_ETH_NUM_PORTS];
static u32 dhcp_start_tick[TAXI_ETH_NUM_PORTS];

static volatile u32 ticks;
static volatile int tcp_fast_flag;
static volatile int tcp_slow_flag;
static volatile int poll_flag;
#if USE_DHCP
static volatile int dhcp_fine_flag;
static volatile int dhcp_coarse_flag;
#endif

static void tick_handler(void *ref, u32 event)
{
	(void)ref;
	(void)event;
	ticks++;
	if (ticks % TCP_FAST_TICKS == 0) {
		tcp_fast_flag = 1;
	}
	if (ticks % TCP_SLOW_TICKS == 0) {
		tcp_slow_flag = 1;
	}
	if (ticks % POLL_TICKS == 0) {
		poll_flag = 1;
	}
#if USE_DHCP
	if (ticks % DHCP_FINE_TICKS == 0) {
		dhcp_fine_flag = 1;
	}
	if (ticks % DHCP_COARSE_TICKS == 0) {
		dhcp_coarse_flag = 1;
	}
#endif
}

static void print_ip(const char *msg, const ip4_addr_t *ip)
{
	xil_printf("%s%d.%d.%d.%d", msg, ip4_addr1(ip), ip4_addr2(ip),
		   ip4_addr3(ip), ip4_addr4(ip));
}

static void print_mac(int i)
{
	const u8 *a = port_cfg[i].hwaddr;

	xil_printf("Port %d: MAC %02x:%02x:%02x:%02x:%02x:%02x\r\n", i,
		   a[0], a[1], a[2], a[3], a[4], a[5]);
}

/* "Port N: IP a.b.c.d mask m.m.m.m gw g.g.g.g (DHCP|static)" */
static void print_port_address(int i, const char *how)
{
	struct netif *n = &netifs[i];

	xil_printf("Port %d: ", i);
	print_ip("IP ", netif_ip4_addr(n));
	print_ip(" mask ", netif_ip4_netmask(n));
	print_ip(" gw ", netif_ip4_gw(n));
	xil_printf(" (%s)\r\n", how);
}

static void set_static_address(int i)
{
	ip4_addr_t ip, mask, gw;

	IP4_ADDR(&ip, 192, 168, 1, STATIC_IP_LAST_OCTET + i);
	IP4_ADDR(&mask, 255, 255, 255, 0);
	IP4_ADDR(&gw, 192, 168, 1, 1);
	netif_set_addr(&netifs[i], &ip, &mask, &gw);
	addr_state[i] = ADDR_STATIC;
	print_port_address(i, "static");
}

/* Once a second: link state (logged by the driver on change) and the
 * per-port address state machine. */
static u32 last_rx[TAXI_ETH_NUM_PORTS], last_tx[TAXI_ETH_NUM_PORTS];

static void poll_port(int i)
{
	struct netif *n = &netifs[i];
	int changed = taxi_macif_link_poll(n);
	int link = netif_is_link_up(n);
	u32 rx = 0, tx = 0;

	/* self-check: frames delivered to lwIP / queued to the DMA */
	taxi_macif_get_counts(n, &rx, &tx);
	if (rx != last_rx[i] || tx != last_tx[i]) {
		xil_printf("Port %d: rx delivered %u, tx sent %u\r\n", i, rx, tx);
		last_rx[i] = rx;
		last_tx[i] = tx;
	}

#if USE_DHCP
	switch (addr_state[i]) {
	case ADDR_NONE:
		if (link) {
			if (dhcp_start(n) == ERR_OK) {
				addr_state[i] = ADDR_DHCP_WAIT;
				dhcp_start_tick[i] = ticks;
				xil_printf("Port %d: DHCP started\r\n", i);
			} else {
				xil_printf("Port %d: dhcp_start failed, using static address\r\n", i);
				set_static_address(i);
			}
		}
		break;
	case ADDR_DHCP_WAIT:
		if (dhcp_supplied_address(n)) {
			addr_state[i] = ADDR_DHCP;
			print_port_address(i, "DHCP");
		} else if ((u32)(ticks - dhcp_start_tick[i]) >= DHCP_TIMEOUT_TICKS) {
			xil_printf("Port %d: no DHCP lease after %d s, falling back to static\r\n",
				   i, DHCP_TIMEOUT_MS / 1000);
			dhcp_release_and_stop(n);
			set_static_address(i);
		} else if (changed && link) {
			/* link bounced while discovering: kick the client */
			dhcp_network_changed_link_up(n);
		}
		break;
	case ADDR_DHCP:
		if (changed && link) {
			dhcp_network_changed_link_up(n);
		}
		break;
	case ADDR_STATIC:
	default:
		break;
	}
#else
	(void)changed;
	(void)link;
#endif
}

int main(void)
{
	ip4_addr_t ip, mask, gw;
	int i, n_up;
	u32 t;

#ifdef __MICROBLAZE__
	/* The MicroBlaze start-up code leaves the caches off; enable them (as
	 * the AMD lwIP template's platform_mb.c does) or every instruction is
	 * fetched from DDR4 and the delay loops run ~30x slow. The D-cache is
	 * kept coherent with the DMA by the explicit flush/invalidate calls in
	 * taxi_macif.c and the AXI DMA driver. */
	Xil_ICacheEnable();
	Xil_DCacheEnable();
#endif

	xil_printf("\r\n\r\n----- Ethernet FMC Taxi MAC lwIP echo server (%d ports) -----\r\n",
		   TAXI_ETH_NUM_PORTS);
	xil_printf("MAC: Taxi 1G RGMII (taxi_rgmii_mac) + AXI DMA SG, PHY: Marvell 88E1510\r\n");
	xil_printf("Addressing: %s\r\n", USE_DHCP ?
		   "DHCP per port, static 192.168.1.10+N fallback after 10 s" :
		   "static 192.168.1.10+N/24");
	for (i = 0; i < TAXI_ETH_NUM_PORTS; i++) {
		print_mac(i);
	}

	lwip_init();

	/* Bring up the netifs: MAC, PHY reset + config, DMA rings, interrupts */
	for (i = 0; i < TAXI_ETH_NUM_PORTS; i++) {
		if (USE_DHCP) {
			ip4_addr_set_zero(&ip);
			ip4_addr_set_zero(&mask);
			ip4_addr_set_zero(&gw);
		} else {
			IP4_ADDR(&ip, 192, 168, 1, STATIC_IP_LAST_OCTET + i);
			IP4_ADDR(&mask, 255, 255, 255, 0);
			IP4_ADDR(&gw, 192, 168, 1, 1);
		}
		if (netif_add(&netifs[i], &ip, &mask, &gw, &port_cfg[i],
			      taxi_macif_init, ethernet_input) == NULL) {
			xil_printf("Port %d: netif_add failed, port disabled\r\n", i);
			port_ok[i] = 0;
			continue;
		}
		port_ok[i] = 1;
		addr_state[i] = USE_DHCP ? ADDR_NONE : ADDR_STATIC;
		netif_set_up(&netifs[i]);
	}
	netif_set_default(&netifs[0]);

	/* Wait (bounded) for autonegotiation on the ports that have a cable;
	 * ports that come up later are picked up by the poll. */
	xil_printf("Waiting up to %d ms for autonegotiation...\r\n", AUTONEG_WAIT_MS);
	for (t = 0; t < AUTONEG_WAIT_MS; t += 100) {
		n_up = 0;
		for (i = 0; i < TAXI_ETH_NUM_PORTS; i++) {
			if (port_ok[i] && taxi_macif_link_status(&netifs[i], NULL, NULL, NULL)) {
				n_up++;
			}
		}
		if (n_up == TAXI_ETH_NUM_PORTS) {
			break;
		}
		usleep(100000);
	}

	/* 50 ms tick for the lwIP timers and the poll (TTC0 / AXI timer via xiltimer,
	 * XILTIMER_tick_timer set by py/pre_platform_build.py) */
	XTimer_SetInterval(TICK_MS);
	XTimer_SetHandler(tick_handler, NULL, XINTERRUPT_DEFAULT_PRIORITY);

	/* Initial link report and address setup (starts DHCP on linked ports) */
	for (i = 0; i < TAXI_ETH_NUM_PORTS; i++) {
		if (port_ok[i]) {
			poll_port(i);
			if (!USE_DHCP) {
				print_port_address(i, "static");
			}
		}
	}
	xil_printf("\r\n");

	print_app_header();
	if (start_application() != 0) {
		xil_printf("Failed to start the echo server\r\n");
		return -1;
	}

	while (1) {
		if (tcp_fast_flag) {
			tcp_fast_flag = 0;
			tcp_fasttmr();
		}
		if (tcp_slow_flag) {
			tcp_slow_flag = 0;
			tcp_slowtmr();
		}
#if USE_DHCP
		if (dhcp_fine_flag) {
			dhcp_fine_flag = 0;
			dhcp_fine_tmr();
		}
		if (dhcp_coarse_flag) {
			dhcp_coarse_flag = 0;
			dhcp_coarse_tmr();
		}
#endif
		for (i = 0; i < TAXI_ETH_NUM_PORTS; i++) {
			if (port_ok[i]) {
				taxi_macif_input(&netifs[i]);
			}
		}
		if (poll_flag) {
			poll_flag = 0;
			for (i = 0; i < TAXI_ETH_NUM_PORTS; i++) {
				if (port_ok[i]) {
					poll_port(i);
				}
			}
		}
		transfer_data();
	}

	/* not reached */
	return 0;
}
