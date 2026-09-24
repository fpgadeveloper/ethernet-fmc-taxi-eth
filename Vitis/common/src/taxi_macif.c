/* SPDX-License-Identifier: MIT
 *
 * taxi_macif.c - lwIP 2.2 netif driver for Taxi RGMII MAC + AXI DMA (SG)
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * Modelled on the AXI Ethernet + AXI DMA adapter of the AMD lwIP port
 * (contrib/ports/xilinx/netif/xaxiemacif_dma.c) but self-contained: no
 * xemac_add / xtopology, no checksum offload, no status/control streams.
 * The received length comes from the S2MM BD status word (the AXI Ethernet
 * adapter reads it from the RX status stream in APP4 instead).
 *
 * Cache handling. Frame buffers are ordinary cached PBUF_POOL pbufs on every
 * architecture: they are flushed before they are handed to the DMA and
 * invalidated after the DMA has written them. PBUF_POOL payloads are 64-byte
 * aligned and PBUF_POOL_BUFSIZE is a multiple of 64 (lwipopts MEM_ALIGNMENT
 * 64), so a flush/invalidate covers whole cache lines and never shares one
 * with the pbuf header or another object -- which matters on MicroBlaze,
 * where Xil_DCacheInvalidateRange() is a discarding 'wdc.clear' when the
 * data cache is write-back.
 *
 * The buffer descriptor rings differ per architecture:
 *   - aarch64 (ZynqMP): the 2 MB bd_space block is remapped Normal
 *     Non-cacheable / inner shareable with Xil_SetTlbAttributes(), and the
 *     AXI DMA driver's XAXIDMA_CACHE_FLUSH/INVALIDATE macros compile to
 *     nothing (xaxidma_bd.h, #ifdef __aarch64__).
 *   - MicroBlaze (and any other non-aarch64 core): there is no MMU to
 *     remap with, so bd_space stays cached and those same driver macros do
 *     the BD cache maintenance inside XAxiDma_BdRingToHw()/FromHw()/Free().
 *     BDs are BD_ALIGNMENT (128 B) apart and 64 B long, so no two BDs share
 *     a cache line. This is the pattern of the AMD port's
 *     xaxiemacif_dma.c.
 */
#include <string.h>

#include "lwip/opt.h"
#include "lwip/def.h"
#include "lwip/mem.h"
#include "lwip/pbuf.h"
#include "lwip/sys.h"
#include "lwip/stats.h"
#include "lwip/snmp.h"
#include "lwip/etharp.h"
#include "netif/ethernet.h"

#include "xaxidma.h"
#include "xinterrupt_wrap.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xstatus.h"
#include "sleep.h"
#if defined(__aarch64__)
#include "xil_mmu.h"     /* Xil_SetTlbAttributes(), NORM_NONCACHE */
#endif
#if !defined(__MICROBLAZE__)
#include "xpseudo_asm.h" /* dsb() */
#endif

#include "taxi_mac.h"
#include "taxi_mac_hw.h"
#include "taxi_macif.h"

/* Data synchronisation barrier: everything the CPU wrote to a BD or to a
 * frame buffer must be visible to the DMA before the BD is committed.
 * MicroBlaze has no dsb(); "mbar 1" is its data-side barrier (the same
 * instruction xil_io.h's DATA_SYNC expands to there) and the "memory"
 * clobber keeps the compiler from moving accesses across it. */
#if defined(__MICROBLAZE__)
#define taxi_dsb() __asm__ __volatile__ ("mbar 1" ::: "memory")
#else
#define taxi_dsb() dsb()
#endif

/* ---- configuration ------------------------------------------------------ */
#define TAXI_MACIF_N_RX_BD      64
#define TAXI_MACIF_N_TX_BD      64
#define TAXI_MACIF_RX_QUEUE_LEN 128           /* power of two, > N_RX_BD */
#define TAXI_MACIF_RX_BUF_LEN   1536          /* >= 1518 - 4 FCS, multiple of 64 */
#define TAXI_MACIF_TX_COALESCE  1
#define TAXI_MACIF_RX_COALESCE  1
#define TAXI_MACIF_IFNAME0      't'
#define TAXI_MACIF_IFNAME1      'x'

/* BD alignment: twice the driver minimum, as in the AMD port */
#define BD_ALIGNMENT (XAXIDMA_BD_MINIMUM_ALIGNMENT * 2)

/* BD area shared by all ports, 64 KB per ring (64 BDs x 128 B = 8 KB
 * actually used). On aarch64 the whole block must be one 2 MB MMU block so
 * that Xil_SetTlbAttributes() can make it non-cacheable, hence the 2 MB
 * alignment. Elsewhere it stays cached and only the BD rings themselves need
 * to be aligned, which is just as well: mb-gcc caps object alignment at
 * 32 KB ("requested alignment exceeds object file maximum"). Every ring
 * starts at a multiple of BD_RING_SPACE from the base, so aligning the base
 * to BD_ALIGNMENT aligns them all. */
#define BD_SPACE_SIZE   0x200000
#define BD_RING_SPACE   0x10000
#if defined(__aarch64__)
#define BD_SPACE_ALIGN  BD_SPACE_SIZE
#else
#define BD_SPACE_ALIGN  BD_ALIGNMENT
#endif
static u8 bd_space[BD_SPACE_SIZE] __attribute__((aligned(BD_SPACE_ALIGN)));
static u32 bd_space_used;
#if defined(__aarch64__)
static int bd_space_mapped;
#endif

#if (PBUF_POOL_BUFSIZE < TAXI_MACIF_RX_BUF_LEN)
#error "lwip220_pbuf_pool_bufsize must be >= TAXI_MACIF_RX_BUF_LEN"
#endif
#if (LWIP_IPV6)
#error "taxi_macif: IPv4 only"
#endif

/* ---- Marvell 88E1510 registers ------------------------------------------ */
#define PHY_REG_CONTROL          0
#define PHY_REG_STATUS           1
#define PHY_REG_ID1              2
#define PHY_REG_ID2              3
#define PHY_REG_AN_ADV           4
#define PHY_REG_1000_ADV         9
#define PHY_REG_COPPER_STATUS1   17   /* page 0 */
#define PHY_REG_MAC_CONTROL      21   /* page 2 */
#define PHY_REG_PAGE             22

#define PHY_CTRL_RESET           0x8000
#define PHY_CTRL_AN_ENABLE       0x1000
#define PHY_CTRL_AN_RESTART      0x0200
#define PHY_STAT_AN_COMPLETE     0x0020
#define PHY_ADV_100FULL          0x0100
#define PHY_ADV_100HALF          0x0080
#define PHY_ADV_10FULL           0x0040
#define PHY_ADV_10HALF           0x0020
#define PHY_ADV_PAUSE            0x0400
#define PHY_ADV_ASYM_PAUSE       0x0800
#define PHY_ADV_1000FULL         0x0200
#define PHY_ADV_1000HALF         0x0100
#define PHY_MAC_CTRL_TX_DELAY    0x0010
#define PHY_MAC_CTRL_RX_DELAY    0x0020
#define PHY_CSTAT1_SPEED_MASK    0xC000   /* 00=10 01=100 10=1000 */
#define PHY_CSTAT1_SPEED_SHIFT   14
#define PHY_CSTAT1_DUPLEX        0x2000
#define PHY_CSTAT1_RESOLVED      0x0800
#define PHY_CSTAT1_LINK          0x0400   /* real-time copper link */
#define PHY_MARVELL_OUI_ID1      0x0141
#define PHY_88E1510_MODEL        0x01D0
#define PHY_MODEL_MASK           0x03F0

/* ---- driver instance ---------------------------------------------------- */
typedef struct {
	taxi_mac mac;
	XAxiDma dma;
	XAxiDma_Config *dma_cfg;
	struct netif *netif;
	const taxi_macif_config *cfg;
	u8 *rx_bdspace;
	u8 *tx_bdspace;

	/* single producer (RX ISR) / single consumer (main loop) queue */
	struct pbuf *rx_q[TAXI_MACIF_RX_QUEUE_LEN];
	volatile u32 rx_q_head;   /* written by ISR */
	volatile u32 rx_q_tail;   /* written by main loop */

	int link_up;
	u32 link_speed;
	int link_fdx;
	int phy_ok;

	/* statistics */
	u32 rx_frames, tx_frames, tx_queued, rx_input_err;
	u32 rx_q_drop, rx_bd_err, rx_nobuf, tx_nobd, rx_dma_err, tx_dma_err;
#ifdef TAXI_ETH_DEBUG
	u32 dbg_dumped;
#endif
} taxi_macif;

static taxi_macif taxi_macif_inst[TAXI_ETH_NUM_PORTS];

static inline taxi_macif *macif_of(struct netif *netif)
{
	return (taxi_macif *)netif->state;
}

/* ========================================================================
 * PHY (Marvell 88E1510)
 * ==================================================================== */
static int phy_read(taxi_macif *m, u32 reg, u16 *val)
{
	return taxi_mac_mdio_read(&m->mac, TAXI_ETH_PHY_ADDR, reg, val);
}

static int phy_write(taxi_macif *m, u32 reg, u16 val)
{
	return taxi_mac_mdio_write(&m->mac, TAXI_ETH_PHY_ADDR, reg, val);
}

static u32 phy_speed_from_cstat1(u16 cstat)
{
	switch ((cstat & PHY_CSTAT1_SPEED_MASK) >> PHY_CSTAT1_SPEED_SHIFT) {
	case 2:
		return 1000;
	case 1:
		return 100;
	default:
		return 10;
	}
}

int taxi_macif_phy_setup(struct netif *netif)
{
	taxi_macif *m = macif_of(netif);
	u16 id1 = 0, id2 = 0, val = 0;
	int t;

	m->phy_ok = 0;
	if (phy_read(m, PHY_REG_ID1, &id1) != XST_SUCCESS ||
	    phy_read(m, PHY_REG_ID2, &id2) != XST_SUCCESS) {
		xil_printf("port %d: MDIO read failed (no PHY?)\r\n", m->cfg->port);
		return XST_FAILURE;
	}
	if (id1 != PHY_MARVELL_OUI_ID1 || (id2 & PHY_MODEL_MASK) != PHY_88E1510_MODEL) {
		xil_printf("port %d: unexpected PHY ID %04x/%04x (want Marvell 88E1510)\r\n",
			   m->cfg->port, id1, id2);
		/* carry on: the register writes below are harmless on other PHYs */
	}

	/* RGMII with only the RX internal delay enabled (page 2, register 21).
	 * See http://ethernetfmc.com/rgmii-interface-timing-considerations/ */
	if (phy_write(m, PHY_REG_PAGE, 2) != XST_SUCCESS ||
	    phy_read(m, PHY_REG_MAC_CONTROL, &val) != XST_SUCCESS) {
		return XST_FAILURE;
	}
	val &= ~PHY_MAC_CTRL_TX_DELAY;
	val |= PHY_MAC_CTRL_RX_DELAY;
	if (phy_write(m, PHY_REG_MAC_CONTROL, val) != XST_SUCCESS ||
	    phy_write(m, PHY_REG_PAGE, 0) != XST_SUCCESS) {
		return XST_FAILURE;
	}

	/* Advertise 10/100 full and half duplex plus pause */
	if (phy_read(m, PHY_REG_AN_ADV, &val) != XST_SUCCESS) {
		return XST_FAILURE;
	}
	val |= PHY_ADV_ASYM_PAUSE | PHY_ADV_PAUSE |
	       PHY_ADV_100FULL | PHY_ADV_100HALF | PHY_ADV_10FULL | PHY_ADV_10HALF;
	if (phy_write(m, PHY_REG_AN_ADV, val) != XST_SUCCESS) {
		return XST_FAILURE;
	}

	/* Advertise 1000BASE-T full and half duplex */
	if (phy_read(m, PHY_REG_1000_ADV, &val) != XST_SUCCESS) {
		return XST_FAILURE;
	}
	val |= PHY_ADV_1000FULL | PHY_ADV_1000HALF;
	if (phy_write(m, PHY_REG_1000_ADV, val) != XST_SUCCESS) {
		return XST_FAILURE;
	}

	/* Enable and restart autonegotiation */
	if (phy_read(m, PHY_REG_CONTROL, &val) != XST_SUCCESS) {
		return XST_FAILURE;
	}
	val |= PHY_CTRL_AN_ENABLE | PHY_CTRL_AN_RESTART;
	if (phy_write(m, PHY_REG_CONTROL, val) != XST_SUCCESS) {
		return XST_FAILURE;
	}

	/* Soft reset so the RGMII delay change takes effect; wait for the
	 * self-clearing reset bit. */
	if (phy_read(m, PHY_REG_CONTROL, &val) != XST_SUCCESS ||
	    phy_write(m, PHY_REG_CONTROL, val | PHY_CTRL_RESET) != XST_SUCCESS) {
		return XST_FAILURE;
	}
	for (t = 0; t < 1000; t++) {
		if (phy_read(m, PHY_REG_CONTROL, &val) != XST_SUCCESS) {
			return XST_FAILURE;
		}
		if ((val & PHY_CTRL_RESET) == 0) {
			break;
		}
		usleep(1000);
	}
	if (val & PHY_CTRL_RESET) {
		xil_printf("port %d: PHY soft reset did not complete\r\n", m->cfg->port);
		return XST_FAILURE;
	}
	m->phy_ok = 1;
	return XST_SUCCESS;
}

u32 taxi_macif_phy_wait_autoneg(struct netif *netif, u32 timeout_ms)
{
	taxi_macif *m = macif_of(netif);
	u16 status = 0, cstat = 0;
	u32 t;

	for (t = 0; t < timeout_ms; t++) {
		if (phy_read(m, PHY_REG_STATUS, &status) != XST_SUCCESS) {
			return 0;
		}
		if (status & PHY_STAT_AN_COMPLETE) {
			if (phy_read(m, PHY_REG_COPPER_STATUS1, &cstat) != XST_SUCCESS) {
				return 0;
			}
			if (cstat & PHY_CSTAT1_RESOLVED) {
				return phy_speed_from_cstat1(cstat);
			}
		}
		usleep(1000);
	}
	return 0;
}

int taxi_macif_link_status(struct netif *netif, u32 *speed_mbps, int *full_duplex,
			   u32 *mac_speed_mbps)
{
	taxi_macif *m = macif_of(netif);
	u16 cstat = 0;
	int up;

	if (phy_read(m, PHY_REG_COPPER_STATUS1, &cstat) != XST_SUCCESS) {
		return 0;
	}
	up = (cstat & PHY_CSTAT1_LINK) && (cstat & PHY_CSTAT1_RESOLVED);
	if (speed_mbps) {
		*speed_mbps = up ? phy_speed_from_cstat1(cstat) : 0;
	}
	if (full_duplex) {
		*full_duplex = up ? ((cstat & PHY_CSTAT1_DUPLEX) != 0) : 0;
	}
	if (mac_speed_mbps) {
		*mac_speed_mbps = taxi_mac_link_speed(&m->mac);
	}
	return up;
}

int taxi_macif_link_poll(struct netif *netif)
{
	taxi_macif *m = macif_of(netif);
	u32 speed = 0, mac_speed = 0;
	int fdx = 0;
	int up = taxi_macif_link_status(netif, &speed, &fdx, &mac_speed);

	if (up == m->link_up && speed == m->link_speed && fdx == m->link_fdx) {
		return 0;
	}
	m->link_up = up;
	m->link_speed = speed;
	m->link_fdx = fdx;
	if (up) {
		xil_printf("Port %d: link up, %d Mbps %s duplex (MAC in-band status: %d Mbps)\r\n",
			   m->cfg->port, speed, fdx ? "full" : "half", mac_speed);
		netif_set_link_up(netif);
	} else {
		xil_printf("Port %d: link down\r\n", m->cfg->port);
		netif_set_link_down(netif);
	}
	return 1;
}

/* ========================================================================
 * DMA rings
 * ==================================================================== */
static void *bd_space_alloc(void)
{
	void *p;

#if defined(__aarch64__)
	if (!bd_space_mapped) {
		/* Normal Non-cacheable, inner shareable, like the AMD port */
		Xil_SetTlbAttributes((UINTPTR)bd_space, NORM_NONCACHE | INNER_SHAREABLE);
		bd_space_mapped = 1;
	}
#endif
	/* No MMU elsewhere: the rings stay cached and the AXI DMA driver's
	 * XAXIDMA_CACHE_FLUSH/INVALIDATE macros keep them coherent. */
	if (bd_space_used + BD_RING_SPACE > BD_SPACE_SIZE) {
		return NULL;
	}
	p = &bd_space[bd_space_used];
	bd_space_used += BD_RING_SPACE;
	return p;
}

/* Fill every free RX BD with a fresh pbuf and hand it to the hardware.
 * Called from init and from the RX interrupt. */
static void setup_rx_bds(taxi_macif *m, XAxiDma_BdRing *rxring)
{
	XAxiDma_Bd *bd;
	struct pbuf *p;
	int n;

	for (n = XAxiDma_BdRingGetFreeCnt(rxring); n > 0; n--) {
		p = pbuf_alloc(PBUF_RAW, TAXI_MACIF_RX_BUF_LEN, PBUF_POOL);
		if (p == NULL) {
			m->rx_nobuf++;
			LINK_STATS_INC(link.memerr);
			return;
		}
		if (p->next != NULL || p->len != TAXI_MACIF_RX_BUF_LEN) {
			/* pool buffers are larger than our frames, so never chained */
			pbuf_free(p);
			m->rx_nobuf++;
			return;
		}
		if (XAxiDma_BdRingAlloc(rxring, 1, &bd) != XST_SUCCESS) {
			pbuf_free(p);
			return;
		}
		XAxiDma_BdSetBufAddr(bd, (UINTPTR)p->payload);
		/* clear status except COMPLETE, which BdRingToHw clears */
		XAxiDma_BdWrite(bd, XAXIDMA_BD_STS_OFFSET,
				XAxiDma_BdGetSts(bd) & XAXIDMA_BD_STS_COMPLETE_MASK);
		XAxiDma_BdSetLength(bd, TAXI_MACIF_RX_BUF_LEN, rxring->MaxTransferLen);
		XAxiDma_BdSetCtrl(bd, 0);
		XAxiDma_BdSetId(bd, p);
		taxi_dsb();
		/* No dirty lines may be written back over the DMA data later.
		 * A flush also invalidates, on aarch64 and on MicroBlaze
		 * alike, so nothing stale is left behind either. The BD
		 * itself is flushed by XAxiDma_BdRingToHw() below (see the
		 * cache note at the top of this file). */
		Xil_DCacheFlushRange((UINTPTR)p->payload, TAXI_MACIF_RX_BUF_LEN);
		if (XAxiDma_BdRingToHw(rxring, 1, bd) != XST_SUCCESS) {
			XAxiDma_BdRingUnAlloc(rxring, 1, bd);
			pbuf_free(p);
			return;
		}
	}
}

/* Reclaim transmitted BDs and release their pbufs. Caller holds the
 * critical section (interrupt context or SYS_ARCH_PROTECT). */
static int process_sent_bds(taxi_macif *m, XAxiDma_BdRing *txring)
{
	XAxiDma_Bd *bdset, *bd;
	struct pbuf *p;
	int n, i;

	n = XAxiDma_BdRingFromHw(txring, XAXIDMA_ALL_BDS, &bdset);
	if (n == 0) {
		return 0;
	}
	for (i = 0, bd = bdset; i < n; i++) {
		/* the pbuf chain is referenced once, on its last BD */
		p = (struct pbuf *)(UINTPTR)XAxiDma_BdGetId(bd);
		if (p != NULL) {
			pbuf_free(p);
			m->tx_frames++;
		}
		bd = (XAxiDma_Bd *)XAxiDma_BdRingNext(txring, bd);
	}
	XAxiDma_BdRingFree(txring, n, bdset);
	return n;
}

static void dma_error_recover(taxi_macif *m, const char *side)
{
	int t;

	xil_printf("port %d: AXI DMA %s error, resetting DMA\r\n", m->cfg->port, side);
	XAxiDma_Reset(&m->dma);
	for (t = 0; t < 10000; t++) {
		if (XAxiDma_ResetIsDone(&m->dma)) {
			break;
		}
	}
	XAxiDma_BdRingIntEnable(XAxiDma_GetTxRing(&m->dma), XAXIDMA_IRQ_ALL_MASK);
	XAxiDma_BdRingIntEnable(XAxiDma_GetRxRing(&m->dma), XAXIDMA_IRQ_ALL_MASK);
	XAxiDma_Resume(&m->dma);
}

/* MM2S (transmit) completion interrupt */
static void taxi_macif_tx_isr(void *arg)
{
	taxi_macif *m = (taxi_macif *)arg;
	XAxiDma_BdRing *txring = XAxiDma_GetTxRing(&m->dma);
	u32 irq;

	XAxiDma_BdRingIntDisable(txring, XAXIDMA_IRQ_ALL_MASK);
	irq = XAxiDma_BdRingGetIrq(txring);
	XAxiDma_BdRingAckIrq(txring, irq);

	if (irq & XAXIDMA_IRQ_ERROR_MASK) {
		m->tx_dma_err++;
		dma_error_recover(m, "MM2S");
		return;
	}
	if (irq & (XAXIDMA_IRQ_DELAY_MASK | XAXIDMA_IRQ_IOC_MASK)) {
		process_sent_bds(m, txring);
	}
	XAxiDma_BdRingIntEnable(txring, XAXIDMA_IRQ_ALL_MASK);
}

/* S2MM (receive) completion interrupt */
static void taxi_macif_rx_isr(void *arg)
{
	taxi_macif *m = (taxi_macif *)arg;
	XAxiDma_BdRing *rxring = XAxiDma_GetRxRing(&m->dma);
	XAxiDma_Bd *bdset, *bd;
	struct pbuf *p;
	u32 irq, sts, len, next;
	int n, i;

	XAxiDma_BdRingIntDisable(rxring, XAXIDMA_IRQ_ALL_MASK);
	irq = XAxiDma_BdRingGetIrq(rxring);
	XAxiDma_BdRingAckIrq(rxring, irq);

	if (irq & XAXIDMA_IRQ_ERROR_MASK) {
		m->rx_dma_err++;
		setup_rx_bds(m, rxring);
		dma_error_recover(m, "S2MM");
		return;
	}
	if (irq & (XAXIDMA_IRQ_DELAY_MASK | XAXIDMA_IRQ_IOC_MASK)) {
		n = XAxiDma_BdRingFromHw(rxring, XAXIDMA_ALL_BDS, &bdset);
		for (i = 0, bd = bdset; i < n; i++) {
			p = (struct pbuf *)(UINTPTR)XAxiDma_BdGetId(bd);
			sts = XAxiDma_BdGetSts(bd);
			len = XAxiDma_BdGetActualLength(bd, rxring->MaxTransferLen);
			/* Drop any line the CPU may hold for this buffer so the
			 * DMA's data is read from memory. The range is whole
			 * cache lines (64-byte aligned payload, length a
			 * multiple of 64), so MicroBlaze's discarding
			 * invalidate cannot throw away a neighbour's dirty
			 * line; the buffer itself has no dirty lines because
			 * setup_rx_bds() flushed it before handing it over. */
			Xil_DCacheInvalidateRange((UINTPTR)p->payload, TAXI_MACIF_RX_BUF_LEN);

			if ((sts & XAXIDMA_BD_STS_ALL_ERR_MASK) ||
			    (sts & (XAXIDMA_BD_STS_RXSOF_MASK | XAXIDMA_BD_STS_RXEOF_MASK)) !=
			    (XAXIDMA_BD_STS_RXSOF_MASK | XAXIDMA_BD_STS_RXEOF_MASK) ||
			    len == 0 || len > TAXI_MACIF_RX_BUF_LEN) {
				/* error, or a frame that did not fit in one buffer */
				m->rx_bd_err++;
				LINK_STATS_INC(link.err);
				pbuf_free(p);
			} else {
				pbuf_realloc(p, (u16_t)len);
				next = (m->rx_q_head + 1) & (TAXI_MACIF_RX_QUEUE_LEN - 1);
				if (next == m->rx_q_tail) {
					m->rx_q_drop++;
					LINK_STATS_INC(link.drop);
					pbuf_free(p);
				} else {
					m->rx_q[m->rx_q_head] = p;
					taxi_dsb();
					m->rx_q_head = next;
				}
			}
			bd = (XAxiDma_Bd *)XAxiDma_BdRingNext(rxring, bd);
		}
		if (n > 0) {
			XAxiDma_BdRingFree(rxring, n, bdset);
		}
		setup_rx_bds(m, rxring);
	}
	XAxiDma_BdRingIntEnable(rxring, XAXIDMA_IRQ_ALL_MASK);
}

static err_t init_dma(taxi_macif *m)
{
	XAxiDma_BdRing *rxring, *txring;
	XAxiDma_Bd bdtemplate;
	int status;

	m->dma_cfg = XAxiDma_LookupConfig(m->cfg->dma_base);
	if (m->dma_cfg == NULL) {
		xil_printf("port %d: no AXI DMA at 0x%08lx in xaxidma_g.c\r\n",
			   m->cfg->port, (unsigned long)m->cfg->dma_base);
		return ERR_IF;
	}
	if (XAxiDma_CfgInitialize(&m->dma, m->dma_cfg) != XST_SUCCESS) {
		return ERR_IF;
	}
	if (!XAxiDma_HasSg(&m->dma)) {
		xil_printf("port %d: AXI DMA is not in scatter-gather mode\r\n", m->cfg->port);
		return ERR_IF;
	}

	m->rx_bdspace = bd_space_alloc();
	m->tx_bdspace = bd_space_alloc();
	if (m->rx_bdspace == NULL || m->tx_bdspace == NULL) {
		xil_printf("port %d: out of BD space\r\n", m->cfg->port);
		return ERR_MEM;
	}

	rxring = XAxiDma_GetRxRing(&m->dma);
	txring = XAxiDma_GetTxRing(&m->dma);

	XAxiDma_BdClear(&bdtemplate);
	status = XAxiDma_BdRingCreate(rxring, (UINTPTR)m->rx_bdspace,
				      (UINTPTR)m->rx_bdspace, BD_ALIGNMENT,
				      TAXI_MACIF_N_RX_BD);
	if (status != XST_SUCCESS || XAxiDma_BdRingClone(rxring, &bdtemplate) != XST_SUCCESS) {
		xil_printf("port %d: RX BD ring setup failed\r\n", m->cfg->port);
		return ERR_IF;
	}
	status = XAxiDma_BdRingCreate(txring, (UINTPTR)m->tx_bdspace,
				      (UINTPTR)m->tx_bdspace, BD_ALIGNMENT,
				      TAXI_MACIF_N_TX_BD);
	if (status != XST_SUCCESS || XAxiDma_BdRingClone(txring, &bdtemplate) != XST_SUCCESS) {
		xil_printf("port %d: TX BD ring setup failed\r\n", m->cfg->port);
		return ERR_IF;
	}

	/* pre-fill the RX ring */
	setup_rx_bds(m, rxring);
	if (XAxiDma_BdRingGetFreeCnt(rxring) != 0) {
		xil_printf("port %d: could not fill the RX ring (pbuf pool too small?)\r\n",
			   m->cfg->port);
		return ERR_MEM;
	}

	XAxiDma_BdRingSetCoalesce(txring, TAXI_MACIF_TX_COALESCE, 1);
	XAxiDma_BdRingSetCoalesce(rxring, TAXI_MACIF_RX_COALESCE, 1);

	if (XAxiDma_BdRingStart(txring) != XST_SUCCESS ||
	    XAxiDma_BdRingStart(rxring) != XST_SUCCESS) {
		xil_printf("port %d: failed to start the DMA rings\r\n", m->cfg->port);
		return ERR_IF;
	}
	XAxiDma_BdRingIntEnable(txring, XAXIDMA_IRQ_ALL_MASK);
	XAxiDma_BdRingIntEnable(rxring, XAXIDMA_IRQ_ALL_MASK);

	/* GIC: IntrId[0] = mm2s_introut, IntrId[1] = s2mm_introut (from the
	 * device tree, trigger type encoded in the upper bits). */
	if (XSetupInterruptSystem(m, taxi_macif_tx_isr, m->dma_cfg->IntrId[0],
				  m->dma_cfg->IntrParent, XINTERRUPT_DEFAULT_PRIORITY) != XST_SUCCESS ||
	    XSetupInterruptSystem(m, taxi_macif_rx_isr, m->dma_cfg->IntrId[1],
				  m->dma_cfg->IntrParent, XINTERRUPT_DEFAULT_PRIORITY) != XST_SUCCESS) {
		xil_printf("port %d: failed to connect the DMA interrupts\r\n", m->cfg->port);
		return ERR_IF;
	}
	return ERR_OK;
}

/* ========================================================================
 * lwIP netif callbacks
 * ==================================================================== */
static err_t low_level_output(struct netif *netif, struct pbuf *p)
{
	taxi_macif *m = macif_of(netif);
	XAxiDma_BdRing *txring = XAxiDma_GetTxRing(&m->dma);
	XAxiDma_Bd *bdset, *bd, *last = NULL;
	struct pbuf *q;
	int n = 0;
	err_t rc = ERR_OK;
	SYS_ARCH_DECL_PROTECT(lev);

	for (q = p; q != NULL; q = q->next) {
		if (q->len > 0) {
			n++;
		}
	}
	if (n == 0) {
		return ERR_OK;
	}

	/* the TX ring is shared with the completion interrupt */
	SYS_ARCH_PROTECT(lev);
	if (XAxiDma_BdRingGetFreeCnt(txring) < n) {
		process_sent_bds(m, txring);
		if (XAxiDma_BdRingGetFreeCnt(txring) < n) {
			m->tx_nobd++;
			LINK_STATS_INC(link.memerr);
			rc = ERR_MEM;
			goto out;
		}
	}
	if (XAxiDma_BdRingAlloc(txring, n, &bdset) != XST_SUCCESS) {
		rc = ERR_MEM;
		goto out;
	}
	for (q = p, bd = bdset; q != NULL; q = q->next) {
		if (q->len == 0) {
			continue;
		}
		XAxiDma_BdSetBufAddr(bd, (UINTPTR)q->payload);
		XAxiDma_BdSetLength(bd, q->len, txring->MaxTransferLen);
		XAxiDma_BdSetCtrl(bd, 0);
		XAxiDma_BdSetId(bd, NULL);
		Xil_DCacheFlushRange((UINTPTR)q->payload, q->len);
		last = bd;
		bd = (XAxiDma_Bd *)XAxiDma_BdRingNext(txring, bd);
	}
	if (n == 1) {
		XAxiDma_BdSetCtrl(bdset, XAXIDMA_BD_CTRL_TXSOF_MASK | XAXIDMA_BD_CTRL_TXEOF_MASK);
	} else {
		XAxiDma_BdSetCtrl(bdset, XAXIDMA_BD_CTRL_TXSOF_MASK);
		XAxiDma_BdSetCtrl(last, XAXIDMA_BD_CTRL_TXEOF_MASK);
	}
	/* keep the whole chain alive until the last BD completes */
	pbuf_ref(p);
	XAxiDma_BdSetId(last, p);
	taxi_dsb();
	if (XAxiDma_BdRingToHw(txring, n, bdset) != XST_SUCCESS) {
		XAxiDma_BdRingUnAlloc(txring, n, bdset);
		pbuf_free(p);
		rc = ERR_IF;
		goto out;
	}
	m->tx_queued++;
	MIB2_STATS_NETIF_ADD(netif, ifoutoctets, p->tot_len);
	LINK_STATS_INC(link.xmit);
out:
	SYS_ARCH_UNPROTECT(lev);
	return rc;
}

#ifdef TAXI_ETH_DEBUG
/* Debug aid: dump the Ethernet header of the first frames of each port */
#define TAXI_ETH_DEBUG_FRAMES 20
static void debug_dump_frame(taxi_macif *m, const struct pbuf *p)
{
	const u8 *d = (const u8 *)p->payload;

	if (m->dbg_dumped >= TAXI_ETH_DEBUG_FRAMES || p->len < 14) {
		return;
	}
	m->dbg_dumped++;
	xil_printf("Port %d: rx[%d] len %d dst %02x:%02x:%02x:%02x:%02x:%02x "
		   "src %02x:%02x:%02x:%02x:%02x:%02x type %02x%02x\r\n",
		   m->cfg->port, m->dbg_dumped, p->tot_len,
		   d[0], d[1], d[2], d[3], d[4], d[5],
		   d[6], d[7], d[8], d[9], d[10], d[11], d[12], d[13]);
}
#endif

int taxi_macif_input(struct netif *netif)
{
	taxi_macif *m = macif_of(netif);
	struct pbuf *p;
	int n = 0;

	while (m->rx_q_tail != m->rx_q_head) {
		p = m->rx_q[m->rx_q_tail];
		taxi_dsb();
		m->rx_q_tail = (m->rx_q_tail + 1) & (TAXI_MACIF_RX_QUEUE_LEN - 1);
		m->rx_frames++;
#ifdef TAXI_ETH_DEBUG
		debug_dump_frame(m, p);
#endif
		MIB2_STATS_NETIF_ADD(netif, ifinoctets, p->tot_len);
		LINK_STATS_INC(link.recv);
		if (netif->input(p, netif) != ERR_OK) {
			LINK_STATS_INC(link.drop);
			m->rx_input_err++;
			pbuf_free(p);
		}
		n++;
	}
	return n;
}

void taxi_macif_get_counts(struct netif *netif, u32 *rx_delivered, u32 *tx_sent)
{
	taxi_macif *m = macif_of(netif);

	if (rx_delivered) {
		*rx_delivered = m->rx_frames;
	}
	if (tx_sent) {
		*tx_sent = m->tx_queued;
	}
}

err_t taxi_macif_init(struct netif *netif)
{
	const taxi_macif_config *cfg = (const taxi_macif_config *)netif->state;
	taxi_macif *m;
	err_t rc;

	LWIP_ASSERT("taxi_macif_init: config", cfg != NULL);
	LWIP_ASSERT("taxi_macif_init: port", cfg->port < TAXI_ETH_NUM_PORTS);

	m = &taxi_macif_inst[cfg->port];
	memset(m, 0, sizeof(*m));
	m->cfg = cfg;
	m->netif = netif;
	netif->state = m;

	if (taxi_mac_init(&m->mac, cfg->mac_base) != XST_SUCCESS) {
		xil_printf("port %d: no Taxi MAC at 0x%08lx (bad ID)\r\n",
			   cfg->port, (unsigned long)cfg->mac_base);
		return ERR_IF;
	}
	/* Hardware reset pulse on the PHY (88E1510: >= 10 ms), then settle */
	taxi_mac_phy_reset(&m->mac, 10000, 50000);

	rc = init_dma(m);
	if (rc != ERR_OK) {
		return rc;
	}
	taxi_mac_enable(&m->mac, 1, 1);

	if (taxi_macif_phy_setup(netif) != XST_SUCCESS) {
		xil_printf("port %d: PHY setup failed\r\n", cfg->port);
		/* the netif still works if a link comes up on its own */
	}

	netif->name[0] = TAXI_MACIF_IFNAME0;
	netif->name[1] = TAXI_MACIF_IFNAME1;
	netif->output = etharp_output;
	netif->linkoutput = low_level_output;
	netif->hwaddr_len = ETHARP_HWADDR_LEN;
	memcpy(netif->hwaddr, cfg->hwaddr, ETHARP_HWADDR_LEN);
	netif->mtu = 1500;
	netif->flags = NETIF_FLAG_BROADCAST | NETIF_FLAG_ETHARP | NETIF_FLAG_ETHERNET;
	MIB2_INIT_NETIF(netif, snmp_ifType_ethernet_csmacd, 1000000000);
	/* link state is driven by taxi_macif_link_poll() */
	return ERR_OK;
}

void taxi_macif_print_stats(struct netif *netif)
{
	taxi_macif *m = macif_of(netif);
	taxi_mac_counters c;

	taxi_mac_get_counters(&m->mac, &c);
	xil_printf("Port %d: rx delivered %u (input err %u) tx queued %u done %u | MAC rx good %u bad %u ovf %u, tx good %u bad %u ovf %u, flags 0x%02x"
		   " | drops: q %u bd %u nobuf %u nobd %u, dma err rx %u tx %u\r\n",
		   m->cfg->port, m->rx_frames, m->rx_input_err, m->tx_queued, m->tx_frames,
		   c.rx_good, c.rx_bad, c.rx_ovf, c.tx_good, c.tx_bad, c.tx_ovf,
		   taxi_mac_get_flags(&m->mac),
		   m->rx_q_drop, m->rx_bd_err, m->rx_nobuf, m->tx_nobd,
		   m->rx_dma_err, m->tx_dma_err);
}

/* ========================================================================
 * Source-based IPv4 routing hook
 *
 * All four ports sit on the same /24, and lwIP's ip4_route(dest) would
 * always pick the first link-up netif on that subnet, so TCP replies would
 * leave through one port whatever port the connection arrived on. The
 * LWIP_HOOK_IP4_ROUTE_SRC hook (added to lwipopts.h by the repo's
 * EmbeddedSw overlay) routes by the source address the PCB is bound to.
 * ==================================================================== */
struct netif *taxi_ip4_route_src(const void *src, const void *dest)
{
	const ip4_addr_t *s = (const ip4_addr_t *)src;
	struct netif *n;

	LWIP_UNUSED_ARG(dest);
	if (s == NULL || ip4_addr_isany(s)) {
		return NULL; /* let ip4_route(dest) decide */
	}
	NETIF_FOREACH(n) {
		if (netif_is_up(n) && netif_is_link_up(n) &&
		    ip4_addr_eq(s, netif_ip4_addr(n))) {
			return n;
		}
	}
	return NULL;
}
