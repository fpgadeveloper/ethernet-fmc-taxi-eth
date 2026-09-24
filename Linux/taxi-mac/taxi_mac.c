// SPDX-License-Identifier: MIT
/*
 * Network driver for the Opsero taxi_rgmii_mac block: a Taxi 1G RGMII MAC,
 * a Taxi MDIO master and an AXI4-Lite register file, paired with a Xilinx
 * AXI DMA (scatter-gather) that is driven through the dmaengine API.
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * Hardware facts this driver relies on (see Vivado/src/hdl/taxi_rgmii_mac.v):
 *  - the AXI-Stream data path carries Ethernet frames without FCS in both
 *    directions: the MAC appends the FCS on transmit and strips it on receive;
 *  - bad-FCS and oversize frames are dropped in hardware; there is no address
 *    filter (the MAC is effectively promiscuous) and no checksum offload;
 *  - link speed is taken from the RGMII in-band status, so no MAC register
 *    needs updating when the PHY renegotiates;
 *  - the received length of every frame is the S2MM descriptor status, which
 *    xilinx_dma reports as the completion residue.
 *
 * Receive completions are handed from the dmaengine callback to a NAPI poll
 * routine, which delivers frames with GRO and re-arms the ring.
 */

#include <linux/bitfield.h>
#include <linux/circ_buf.h>
#include <linux/delay.h>
#include <linux/dma-mapping.h>
#include <linux/dmaengine.h>
#include <linux/etherdevice.h>
#include <linux/ethtool.h>
#include <linux/if_vlan.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/jiffies.h>
#include <linux/llist.h>
#include <linux/module.h>
#include <linux/netdevice.h>
#include <linux/of.h>
#include <linux/of_mdio.h>
#include <linux/of_net.h>
#include <linux/phy.h>
#include <linux/platform_device.h>
#include <linux/scatterlist.h>
#include <linux/skbuff.h>
#include <linux/spinlock.h>
#include <linux/u64_stats_sync.h>

#define TAXI_DRV_NAME		"taxi_mac"

/* Register map */
#define TAXI_ID			0x00
#define TAXI_ID_MAGIC		0x54415849	/* "TAXI" */
#define TAXI_VERSION		0x04
#define TAXI_CTRL		0x08
#define TAXI_CTRL_TX_EN		BIT(0)
#define TAXI_CTRL_RX_EN		BIT(1)
#define TAXI_CTRL_PHY_RSTN	BIT(2)
#define TAXI_CTRL_TX_PAD_EN	BIT(3)
#define TAXI_STATUS		0x0c
#define TAXI_STATUS_SPEED	GENMASK(1, 0)
#define TAXI_FLAGS		0x10
#define TAXI_FLAGS_MASK		GENMASK(5, 0)
#define TAXI_TX_IFG		0x14
#define TAXI_TX_MAX_LEN		0x18
#define TAXI_RX_MAX_LEN		0x1c
#define TAXI_RX_GOOD_CNT	0x20
#define TAXI_RX_BAD_CNT		0x24
#define TAXI_TX_GOOD_CNT	0x28
#define TAXI_TX_BAD_CNT		0x2c
#define TAXI_RX_OVF_CNT		0x30
#define TAXI_TX_OVF_CNT		0x34
#define TAXI_MDIO_CMD		0x40
#define TAXI_MDIO_CMD_ST	GENMASK(31, 30)
#define TAXI_MDIO_CMD_OP	GENMASK(29, 28)
#define TAXI_MDIO_OP_WRITE	1
#define TAXI_MDIO_OP_READ	2
#define TAXI_MDIO_CMD_PHY	GENMASK(27, 23)
#define TAXI_MDIO_CMD_REG	GENMASK(22, 18)
#define TAXI_MDIO_CMD_DATA	GENMASK(15, 0)
#define TAXI_MDIO_RDATA		0x44
#define TAXI_MDIO_STATUS	0x48
#define TAXI_MDIO_STATUS_BUSY	BIT(0)
#define TAXI_MDIO_STATUS_RDV	BIT(1)
#define TAXI_MDIO_DIV		0x4c

/* MDC = s_axi_aclk / (2 * (DIV + 1)); 100 MHz / 40 = 2.5 MHz */
#define TAXI_MDIO_DIV_2M5	19
#define TAXI_MDIO_TIMEOUT_US	10000

/* Marvell 88E1510: hold reset >= 10 ms, wait >= 50 ms before MDIO access */
#define TAXI_PHY_RESET_MS	20
#define TAXI_PHY_POST_RESET_MS	60

#define TAXI_TX_RING		64
#define TAXI_TX_WAKE_THRESH	(TAXI_TX_RING / 4)
#define TAXI_RX_RING		128

/*
 * Both frame FIFOs are 8 KiB and a frame must fit in one entirely (the MAC
 * drops oversize frames), so the wire frame including VLAN tag and FCS must
 * stay well below 8192 bytes: 8000 + 14 + 4 + 4 = 8022.
 */
#define TAXI_MAX_MTU		8000
#define TAXI_FRAME_OVERHEAD	(ETH_HLEN + VLAN_HLEN + ETH_FCS_LEN)

#define TAXI_TX_DRAIN_MS	500
#define TAXI_RX_QUIESCE_MS	20

struct taxi_priv;

struct taxi_tx_buf {
	struct sk_buff *skb;
	dma_addr_t dma;
	unsigned int len;
};

struct taxi_rx_buf {
	struct taxi_priv *priv;
	struct sk_buff *skb;
	dma_addr_t dma;
	struct llist_node node;	/* on rx_done once the DMA has completed */
	unsigned int len;
	bool error;
};

struct taxi_priv {
	struct net_device *ndev;
	struct device *dev;
	void __iomem *regs;
	struct mii_bus *mii;
	phy_interface_t phy_mode;

	struct dma_chan *tx_chan;
	struct dma_chan *rx_chan;

	/* TX ring: head advanced by start_xmit, tail by the DMA callback */
	struct taxi_tx_buf tx_ring[TAXI_TX_RING];
	unsigned int tx_head;
	unsigned int tx_tail;
	spinlock_t tx_lock;

	/*
	 * RX buffers: each is one outstanding DEV_TO_MEM transaction. The DMA
	 * callback pushes completed buffers onto rx_done and schedules NAPI;
	 * the poll routine drains them in order through rx_pending.
	 */
	struct taxi_rx_buf rx_ring[TAXI_RX_RING];
	unsigned int rx_buf_len;
	bool rx_running;
	spinlock_t rx_lock;
	struct napi_struct napi;
	struct llist_head rx_done;
	struct llist_node *rx_pending;

	struct u64_stats_sync tx_syncp;
	u64 tx_packets;
	u64 tx_bytes;
	u64 tx_errors;
	u64 tx_dropped;

	struct u64_stats_sync rx_syncp;
	u64 rx_packets;
	u64 rx_bytes;
	u64 rx_errors;
	u64 rx_dropped;

	/* Accumulated hardware counters (ethtool -S, rtnl protected) */
	u64 hw_counters[6];
	u64 hw_flags[6];
};

static const struct {
	char name[ETH_GSTRING_LEN];
	u32 reg;
} taxi_hw_counters[] = {
	{ "rx_good",	TAXI_RX_GOOD_CNT },
	{ "rx_bad",	TAXI_RX_BAD_CNT },
	{ "tx_good",	TAXI_TX_GOOD_CNT },
	{ "tx_bad",	TAXI_TX_BAD_CNT },
	{ "rx_fifo_ovf", TAXI_RX_OVF_CNT },
	{ "tx_fifo_ovf", TAXI_TX_OVF_CNT },
};

static const char taxi_hw_flags[][ETH_GSTRING_LEN] = {
	"flag_tx_underflow",
	"flag_tx_fifo_overflow",
	"flag_tx_fifo_bad_frame",
	"flag_rx_fifo_overflow",
	"flag_rx_fifo_bad_frame",
	"flag_rx_bad_fcs",
};

static const char taxi_link_speed_stat[] = "mac_link_speed";

#define TAXI_N_STATS	(ARRAY_SIZE(taxi_hw_counters) + \
			 ARRAY_SIZE(taxi_hw_flags) + 1)

static inline u32 taxi_read(struct taxi_priv *priv, u32 reg)
{
	return readl(priv->regs + reg);
}

static inline void taxi_write(struct taxi_priv *priv, u32 reg, u32 val)
{
	writel(val, priv->regs + reg);
}

static inline struct device *taxi_dma_dev(struct dma_chan *chan)
{
	return chan->device->dev;
}

/* -------------------------------------------------------------------------
 * MDIO bus
 */

static int taxi_mdio_wait_idle(struct taxi_priv *priv)
{
	u32 st;

	return readl_poll_timeout(priv->regs + TAXI_MDIO_STATUS, st,
				  !(st & TAXI_MDIO_STATUS_BUSY), 5,
				  TAXI_MDIO_TIMEOUT_US);
}

static int taxi_mdio_read(struct mii_bus *bus, int phy, int reg)
{
	struct taxi_priv *priv = bus->priv;
	u32 st;
	int ret;

	ret = taxi_mdio_wait_idle(priv);
	if (ret)
		return ret;

	taxi_write(priv, TAXI_MDIO_CMD,
		   FIELD_PREP(TAXI_MDIO_CMD_ST, 1) |
		   FIELD_PREP(TAXI_MDIO_CMD_OP, TAXI_MDIO_OP_READ) |
		   FIELD_PREP(TAXI_MDIO_CMD_PHY, phy) |
		   FIELD_PREP(TAXI_MDIO_CMD_REG, reg));

	ret = readl_poll_timeout(priv->regs + TAXI_MDIO_STATUS, st,
				 (st & (TAXI_MDIO_STATUS_BUSY |
					TAXI_MDIO_STATUS_RDV)) ==
				 TAXI_MDIO_STATUS_RDV,
				 5, TAXI_MDIO_TIMEOUT_US);
	if (ret)
		return ret;

	return FIELD_GET(TAXI_MDIO_CMD_DATA, taxi_read(priv, TAXI_MDIO_RDATA));
}

static int taxi_mdio_write(struct mii_bus *bus, int phy, int reg, u16 val)
{
	struct taxi_priv *priv = bus->priv;
	int ret;

	ret = taxi_mdio_wait_idle(priv);
	if (ret)
		return ret;

	taxi_write(priv, TAXI_MDIO_CMD,
		   FIELD_PREP(TAXI_MDIO_CMD_ST, 1) |
		   FIELD_PREP(TAXI_MDIO_CMD_OP, TAXI_MDIO_OP_WRITE) |
		   FIELD_PREP(TAXI_MDIO_CMD_PHY, phy) |
		   FIELD_PREP(TAXI_MDIO_CMD_REG, reg) |
		   FIELD_PREP(TAXI_MDIO_CMD_DATA, val));

	return taxi_mdio_wait_idle(priv);
}

static int taxi_mdio_init(struct taxi_priv *priv)
{
	struct device *dev = priv->dev;
	struct device_node *mdio_np;
	struct mii_bus *bus;
	int ret;

	bus = devm_mdiobus_alloc(dev);
	if (!bus)
		return -ENOMEM;

	bus->name = "taxi-mdio";
	snprintf(bus->id, MII_BUS_ID_SIZE, "%s", dev_name(dev));
	bus->read = taxi_mdio_read;
	bus->write = taxi_mdio_write;
	bus->parent = dev;
	bus->priv = priv;

	taxi_write(priv, TAXI_MDIO_DIV, TAXI_MDIO_DIV_2M5);

	mdio_np = of_get_child_by_name(dev->of_node, "mdio");
	ret = devm_of_mdiobus_register(dev, bus, mdio_np);
	of_node_put(mdio_np);
	if (ret)
		return dev_err_probe(dev, ret, "failed to register MDIO bus\n");

	priv->mii = bus;
	return 0;
}

/* -------------------------------------------------------------------------
 * MAC control
 */

static void taxi_mac_set_max_len(struct taxi_priv *priv)
{
	u32 max_len = priv->ndev->mtu + TAXI_FRAME_OVERHEAD - 1;

	taxi_write(priv, TAXI_TX_MAX_LEN, max_len);
	taxi_write(priv, TAXI_RX_MAX_LEN, max_len);
}

static void taxi_mac_enable(struct taxi_priv *priv, u32 mask, bool enable)
{
	u32 ctrl = taxi_read(priv, TAXI_CTRL);

	if (enable)
		ctrl |= mask;
	else
		ctrl &= ~mask;
	taxi_write(priv, TAXI_CTRL, ctrl);
}

static void taxi_mac_reset(struct taxi_priv *priv)
{
	unsigned int i;

	/* TX/RX disabled until open; put the PHY through a clean reset */
	taxi_write(priv, TAXI_CTRL, TAXI_CTRL_TX_PAD_EN);
	msleep(TAXI_PHY_RESET_MS);
	taxi_write(priv, TAXI_CTRL, TAXI_CTRL_TX_PAD_EN | TAXI_CTRL_PHY_RSTN);
	msleep(TAXI_PHY_POST_RESET_MS);

	taxi_write(priv, TAXI_FLAGS, TAXI_FLAGS_MASK);
	for (i = 0; i < ARRAY_SIZE(taxi_hw_counters); i++)
		taxi_write(priv, taxi_hw_counters[i].reg, 0);
}

/* -------------------------------------------------------------------------
 * Receive path
 */

static void taxi_rx_complete(void *param, const struct dmaengine_result *result);

static int taxi_rx_submit(struct taxi_priv *priv, struct taxi_rx_buf *buf,
			  struct sk_buff *skb)
{
	struct device *dma_dev = taxi_dma_dev(priv->rx_chan);
	struct dma_async_tx_descriptor *desc;
	struct scatterlist sg;
	dma_cookie_t cookie;
	dma_addr_t dma;

	dma = dma_map_single(dma_dev, skb->data, priv->rx_buf_len,
			     DMA_FROM_DEVICE);
	if (dma_mapping_error(dma_dev, dma))
		return -ENOMEM;

	sg_init_table(&sg, 1);
	sg_dma_address(&sg) = dma;
	sg_dma_len(&sg) = priv->rx_buf_len;

	desc = dmaengine_prep_slave_sg(priv->rx_chan, &sg, 1, DMA_DEV_TO_MEM,
				       DMA_PREP_INTERRUPT | DMA_CTRL_ACK);
	if (!desc) {
		dma_unmap_single(dma_dev, dma, priv->rx_buf_len,
				 DMA_FROM_DEVICE);
		return -EBUSY;
	}

	buf->skb = skb;
	buf->dma = dma;
	desc->callback_result = taxi_rx_complete;
	desc->callback_param = buf;

	cookie = dmaengine_submit(desc);
	if (dma_submit_error(cookie)) {
		buf->skb = NULL;
		dma_unmap_single(dma_dev, dma, priv->rx_buf_len,
				 DMA_FROM_DEVICE);
		return cookie;
	}

	return 0;
}

static void taxi_rx_complete(void *param, const struct dmaengine_result *result)
{
	struct taxi_rx_buf *buf = param;
	struct taxi_priv *priv = buf->priv;

	buf->error = result->result != DMA_TRANS_NOERROR ||
		     result->residue > priv->rx_buf_len;
	buf->len = buf->error ? 0 : priv->rx_buf_len - result->residue;

	llist_add(&buf->node, &priv->rx_done);
	napi_schedule(&priv->napi);
}

/* Deliver one completed buffer to the stack and re-arm its ring slot */
static void taxi_rx_process(struct taxi_priv *priv, struct taxi_rx_buf *buf)
{
	struct net_device *ndev = priv->ndev;
	struct sk_buff *skb = buf->skb;
	struct sk_buff *new_skb;
	int ret;

	dma_unmap_single(taxi_dma_dev(priv->rx_chan), buf->dma,
			 priv->rx_buf_len, DMA_FROM_DEVICE);
	buf->skb = NULL;

	if (buf->error || buf->len < ETH_HLEN) {
		u64_stats_update_begin(&priv->rx_syncp);
		priv->rx_errors++;
		u64_stats_update_end(&priv->rx_syncp);
		new_skb = skb;
		goto resubmit;
	}

	new_skb = netdev_alloc_skb_ip_align(ndev, priv->rx_buf_len);
	if (!new_skb) {
		/* Drop this frame and keep its buffer in the ring */
		u64_stats_update_begin(&priv->rx_syncp);
		priv->rx_dropped++;
		u64_stats_update_end(&priv->rx_syncp);
		new_skb = skb;
		goto resubmit;
	}

	skb_put(skb, buf->len);
	skb->protocol = eth_type_trans(skb, ndev);
	skb->ip_summed = CHECKSUM_NONE;

	u64_stats_update_begin(&priv->rx_syncp);
	priv->rx_packets++;
	priv->rx_bytes += buf->len;
	u64_stats_update_end(&priv->rx_syncp);

	napi_gro_receive(&priv->napi, skb);

resubmit:
	spin_lock(&priv->rx_lock);
	if (priv->rx_running)
		ret = taxi_rx_submit(priv, buf, new_skb);
	else
		ret = -ENODEV;
	spin_unlock(&priv->rx_lock);

	if (ret) {
		dev_kfree_skb_any(new_skb);
		if (ret != -ENODEV && net_ratelimit())
			netdev_err(ndev, "RX buffer resubmit failed (%d)\n", ret);
	}
}

static int taxi_rx_poll(struct napi_struct *napi, int budget)
{
	struct taxi_priv *priv = container_of(napi, struct taxi_priv, napi);
	struct llist_node *node;
	int done = 0;

	while (done < budget) {
		if (!priv->rx_pending) {
			node = llist_del_all(&priv->rx_done);
			if (!node)
				break;
			priv->rx_pending = llist_reverse_order(node);
		}

		node = priv->rx_pending;
		priv->rx_pending = node->next;
		taxi_rx_process(priv,
				llist_entry(node, struct taxi_rx_buf, node));
		done++;
	}

	if (done)
		dma_async_issue_pending(priv->rx_chan);

	if (done < budget) {
		napi_complete_done(napi, done);
		/* A completion may have arrived after the list was drained */
		if (!llist_empty(&priv->rx_done))
			napi_schedule(napi);
	}

	return done;
}

static void taxi_rx_ring_stop(struct taxi_priv *priv)
{
	struct device *dma_dev = taxi_dma_dev(priv->rx_chan);
	unsigned int i;

	spin_lock_bh(&priv->rx_lock);
	priv->rx_running = false;
	spin_unlock_bh(&priv->rx_lock);

	dmaengine_terminate_sync(priv->rx_chan);
	napi_disable(&priv->napi);

	/* Every buffer still owning an skb is mapped, completed or not */
	llist_del_all(&priv->rx_done);
	priv->rx_pending = NULL;
	for (i = 0; i < TAXI_RX_RING; i++) {
		struct taxi_rx_buf *buf = &priv->rx_ring[i];

		if (!buf->skb)
			continue;
		dma_unmap_single(dma_dev, buf->dma, priv->rx_buf_len,
				 DMA_FROM_DEVICE);
		dev_kfree_skb(buf->skb);
		buf->skb = NULL;
	}
}

static int taxi_rx_ring_start(struct taxi_priv *priv)
{
	struct net_device *ndev = priv->ndev;
	unsigned int i;
	int ret;

	priv->rx_buf_len = ndev->mtu + TAXI_FRAME_OVERHEAD;
	priv->rx_running = true;
	napi_enable(&priv->napi);

	for (i = 0; i < TAXI_RX_RING; i++) {
		struct taxi_rx_buf *buf = &priv->rx_ring[i];
		struct sk_buff *skb;

		buf->priv = priv;
		skb = netdev_alloc_skb_ip_align(ndev, priv->rx_buf_len);
		if (!skb) {
			ret = -ENOMEM;
			goto err;
		}

		ret = taxi_rx_submit(priv, buf, skb);
		if (ret) {
			dev_kfree_skb(skb);
			goto err;
		}
	}

	dma_async_issue_pending(priv->rx_chan);
	return 0;

err:
	netdev_err(ndev, "failed to fill RX ring (%d)\n", ret);
	taxi_rx_ring_stop(priv);
	return ret;
}

/* -------------------------------------------------------------------------
 * Transmit path
 */

static void taxi_tx_complete(void *param, const struct dmaengine_result *result)
{
	struct taxi_priv *priv = param;
	struct net_device *ndev = priv->ndev;
	struct taxi_tx_buf *buf;
	struct sk_buff *skb;
	unsigned long flags;

	spin_lock_irqsave(&priv->tx_lock, flags);
	if (priv->tx_tail == priv->tx_head) {
		spin_unlock_irqrestore(&priv->tx_lock, flags);
		return;
	}

	buf = &priv->tx_ring[priv->tx_tail % TAXI_TX_RING];
	skb = buf->skb;
	buf->skb = NULL;
	dma_unmap_single(taxi_dma_dev(priv->tx_chan), buf->dma, buf->len,
			 DMA_TO_DEVICE);

	u64_stats_update_begin(&priv->tx_syncp);
	if (result->result == DMA_TRANS_NOERROR) {
		priv->tx_packets++;
		priv->tx_bytes += buf->len;
	} else {
		priv->tx_errors++;
	}
	u64_stats_update_end(&priv->tx_syncp);

	priv->tx_tail++;
	if (netif_queue_stopped(ndev) &&
	    CIRC_SPACE(priv->tx_head, priv->tx_tail, TAXI_TX_RING) >=
	    TAXI_TX_WAKE_THRESH)
		netif_wake_queue(ndev);
	spin_unlock_irqrestore(&priv->tx_lock, flags);

	dev_consume_skb_any(skb);
}

static netdev_tx_t taxi_start_xmit(struct sk_buff *skb, struct net_device *ndev)
{
	struct taxi_priv *priv = netdev_priv(ndev);
	struct device *dma_dev = taxi_dma_dev(priv->tx_chan);
	struct dma_async_tx_descriptor *desc;
	struct taxi_tx_buf *buf;
	struct scatterlist sg;
	dma_cookie_t cookie;
	unsigned long flags;
	unsigned int len;
	dma_addr_t dma;

	/*
	 * tx_tail only ever grows, so a snapshot is a conservative space check
	 * and no descriptor is prepared for a slot we do not have.
	 */
	if (!CIRC_SPACE(priv->tx_head, READ_ONCE(priv->tx_tail),
			TAXI_TX_RING)) {
		netif_stop_queue(ndev);
		return NETDEV_TX_BUSY;
	}

	if (skb_linearize(skb))
		goto drop;

	len = skb->len;
	dma = dma_map_single(dma_dev, skb->data, len, DMA_TO_DEVICE);
	if (dma_mapping_error(dma_dev, dma))
		goto drop;

	sg_init_table(&sg, 1);
	sg_dma_address(&sg) = dma;
	sg_dma_len(&sg) = len;

	desc = dmaengine_prep_slave_sg(priv->tx_chan, &sg, 1, DMA_MEM_TO_DEV,
				       DMA_PREP_INTERRUPT | DMA_CTRL_ACK);
	if (!desc)
		goto unmap_drop;

	desc->callback_result = taxi_tx_complete;
	desc->callback_param = priv;

	spin_lock_irqsave(&priv->tx_lock, flags);
	buf = &priv->tx_ring[priv->tx_head % TAXI_TX_RING];
	buf->skb = skb;
	buf->dma = dma;
	buf->len = len;

	cookie = dmaengine_submit(desc);
	if (dma_submit_error(cookie)) {
		buf->skb = NULL;
		spin_unlock_irqrestore(&priv->tx_lock, flags);
		goto unmap_drop;
	}

	priv->tx_head++;
	if (!CIRC_SPACE(priv->tx_head, priv->tx_tail, TAXI_TX_RING))
		netif_stop_queue(ndev);
	spin_unlock_irqrestore(&priv->tx_lock, flags);

	skb_tx_timestamp(skb);
	dma_async_issue_pending(priv->tx_chan);
	return NETDEV_TX_OK;

unmap_drop:
	dma_unmap_single(dma_dev, dma, len, DMA_TO_DEVICE);
drop:
	u64_stats_update_begin(&priv->tx_syncp);
	priv->tx_dropped++;
	u64_stats_update_end(&priv->tx_syncp);
	dev_kfree_skb_any(skb);
	return NETDEV_TX_OK;
}

/* Wait for the in-flight TX ring to be transmitted (queue already stopped) */
static void taxi_tx_drain(struct taxi_priv *priv)
{
	unsigned long timeout = jiffies + msecs_to_jiffies(TAXI_TX_DRAIN_MS);

	while (READ_ONCE(priv->tx_tail) != READ_ONCE(priv->tx_head)) {
		if (time_after(jiffies, timeout)) {
			netdev_warn(priv->ndev, "TX ring did not drain\n");
			break;
		}
		usleep_range(1000, 2000);
	}
}

static void taxi_tx_ring_stop(struct taxi_priv *priv)
{
	struct device *dma_dev = taxi_dma_dev(priv->tx_chan);

	dmaengine_terminate_sync(priv->tx_chan);

	spin_lock_bh(&priv->tx_lock);
	while (priv->tx_tail != priv->tx_head) {
		struct taxi_tx_buf *buf =
			&priv->tx_ring[priv->tx_tail % TAXI_TX_RING];

		dma_unmap_single(dma_dev, buf->dma, buf->len, DMA_TO_DEVICE);
		dev_kfree_skb(buf->skb);
		buf->skb = NULL;
		priv->tx_tail++;
	}
	priv->tx_head = 0;
	priv->tx_tail = 0;
	spin_unlock_bh(&priv->tx_lock);
}

/* -------------------------------------------------------------------------
 * Data path start / stop (used by open, stop and change_mtu)
 */

static void taxi_release_dma(struct taxi_priv *priv)
{
	dma_release_channel(priv->rx_chan);
	dma_release_channel(priv->tx_chan);
	priv->rx_chan = NULL;
	priv->tx_chan = NULL;
}

static int taxi_request_dma(struct taxi_priv *priv)
{
	struct device *dev = priv->dev;

	priv->tx_chan = dma_request_chan(dev, "tx");
	if (IS_ERR(priv->tx_chan))
		return dev_err_probe(dev, PTR_ERR(priv->tx_chan),
				     "failed to request TX DMA channel\n");

	priv->rx_chan = dma_request_chan(dev, "rx");
	if (IS_ERR(priv->rx_chan)) {
		dma_release_channel(priv->tx_chan);
		return dev_err_probe(dev, PTR_ERR(priv->rx_chan),
				     "failed to request RX DMA channel\n");
	}

	return 0;
}

/*
 * The DMA channels are requested here and released in taxi_datapath_stop()
 * rather than held for the lifetime of the driver: an AXI DMA soft reset
 * (which xilinx_dma issues from terminate_all) resets both channels of the
 * engine, and the only point at which xilinx_dma re-enables a channel's
 * interrupts is alloc_chan_resources(), i.e. dma_request_chan().
 */
static int taxi_datapath_start(struct taxi_priv *priv)
{
	int ret;

	ret = taxi_request_dma(priv);
	if (ret)
		return ret;

	taxi_mac_set_max_len(priv);

	ret = taxi_rx_ring_start(priv);
	if (ret) {
		taxi_release_dma(priv);
		return ret;
	}

	taxi_mac_enable(priv, TAXI_CTRL_TX_EN | TAXI_CTRL_RX_EN, true);
	return 0;
}

static void taxi_datapath_stop(struct taxi_priv *priv)
{
	/*
	 * Stop accepting frames, then give a frame already in progress time
	 * to finish and drain through the RX FIFO into the ring so that the
	 * DMA is not reset in the middle of a frame.
	 */
	taxi_mac_enable(priv, TAXI_CTRL_RX_EN, false);
	msleep(TAXI_RX_QUIESCE_MS);

	taxi_tx_drain(priv);
	taxi_mac_enable(priv, TAXI_CTRL_TX_EN, false);

	taxi_tx_ring_stop(priv);
	taxi_rx_ring_stop(priv);
	taxi_release_dma(priv);
}

/* -------------------------------------------------------------------------
 * net_device_ops
 */

static void taxi_adjust_link(struct net_device *ndev)
{
	/* The MAC follows the RGMII in-band speed; nothing to program */
	phy_print_status(ndev->phydev);
}

static int taxi_open(struct net_device *ndev)
{
	struct taxi_priv *priv = netdev_priv(ndev);
	struct phy_device *phydev;
	int ret;

	ret = taxi_datapath_start(priv);
	if (ret)
		return ret;

	phydev = of_phy_get_and_connect(ndev, priv->dev->of_node,
					taxi_adjust_link);
	if (!phydev) {
		netdev_err(ndev, "failed to connect to PHY\n");
		ret = -ENODEV;
		goto err_datapath;
	}

	phy_start(phydev);
	netif_start_queue(ndev);
	return 0;

err_datapath:
	taxi_datapath_stop(priv);
	return ret;
}

static int taxi_stop(struct net_device *ndev)
{
	struct taxi_priv *priv = netdev_priv(ndev);

	netif_tx_disable(ndev);

	phy_stop(ndev->phydev);
	phy_disconnect(ndev->phydev);

	taxi_datapath_stop(priv);
	return 0;
}

static int taxi_change_mtu(struct net_device *ndev, int new_mtu)
{
	struct taxi_priv *priv = netdev_priv(ndev);
	int ret;

	if (!netif_running(ndev)) {
		WRITE_ONCE(ndev->mtu, new_mtu);
		return 0;
	}

	/* RX buffers are sized from the MTU: re-arm the data path */
	netif_tx_disable(ndev);
	taxi_datapath_stop(priv);

	WRITE_ONCE(ndev->mtu, new_mtu);

	ret = taxi_datapath_start(priv);
	if (ret) {
		netdev_err(ndev, "failed to restart after MTU change (%d)\n",
			   ret);
		return ret;
	}

	netif_wake_queue(ndev);
	return 0;
}

static void taxi_tx_timeout(struct net_device *ndev, unsigned int txqueue)
{
	struct taxi_priv *priv = netdev_priv(ndev);

	netdev_warn(ndev, "TX timeout (ring head %u tail %u)\n",
		    priv->tx_head, priv->tx_tail);

	u64_stats_update_begin(&priv->tx_syncp);
	priv->tx_errors++;
	u64_stats_update_end(&priv->tx_syncp);
}

static void taxi_get_stats64(struct net_device *ndev,
			     struct rtnl_link_stats64 *stats)
{
	struct taxi_priv *priv = netdev_priv(ndev);
	unsigned int start;

	do {
		start = u64_stats_fetch_begin(&priv->tx_syncp);
		stats->tx_packets = priv->tx_packets;
		stats->tx_bytes = priv->tx_bytes;
		stats->tx_errors = priv->tx_errors;
		stats->tx_dropped = priv->tx_dropped;
	} while (u64_stats_fetch_retry(&priv->tx_syncp, start));

	do {
		start = u64_stats_fetch_begin(&priv->rx_syncp);
		stats->rx_packets = priv->rx_packets;
		stats->rx_bytes = priv->rx_bytes;
		stats->rx_errors = priv->rx_errors;
		stats->rx_dropped = priv->rx_dropped;
	} while (u64_stats_fetch_retry(&priv->rx_syncp, start));
}

static const struct net_device_ops taxi_netdev_ops = {
	.ndo_open		= taxi_open,
	.ndo_stop		= taxi_stop,
	.ndo_start_xmit		= taxi_start_xmit,
	.ndo_set_mac_address	= eth_mac_addr,
	.ndo_validate_addr	= eth_validate_addr,
	.ndo_change_mtu		= taxi_change_mtu,
	.ndo_tx_timeout		= taxi_tx_timeout,
	.ndo_get_stats64	= taxi_get_stats64,
	.ndo_eth_ioctl		= phy_do_ioctl_running,
};

/* -------------------------------------------------------------------------
 * ethtool
 */

static void taxi_get_drvinfo(struct net_device *ndev,
			     struct ethtool_drvinfo *info)
{
	struct taxi_priv *priv = netdev_priv(ndev);

	strscpy(info->driver, TAXI_DRV_NAME, sizeof(info->driver));
	strscpy(info->bus_info, dev_name(priv->dev), sizeof(info->bus_info));
}

static void taxi_get_strings(struct net_device *ndev, u32 stringset, u8 *data)
{
	unsigned int i;

	if (stringset != ETH_SS_STATS)
		return;

	for (i = 0; i < ARRAY_SIZE(taxi_hw_counters); i++)
		ethtool_puts(&data, taxi_hw_counters[i].name);
	for (i = 0; i < ARRAY_SIZE(taxi_hw_flags); i++)
		ethtool_puts(&data, taxi_hw_flags[i]);
	ethtool_puts(&data, taxi_link_speed_stat);
}

static int taxi_get_sset_count(struct net_device *ndev, int sset)
{
	return sset == ETH_SS_STATS ? TAXI_N_STATS : -EOPNOTSUPP;
}

static void taxi_get_ethtool_stats(struct net_device *ndev,
				   struct ethtool_stats *stats, u64 *data)
{
	struct taxi_priv *priv = netdev_priv(ndev);
	static const u16 speeds[] = { 10, 100, 1000, 0 };
	unsigned int i, n = 0;
	u32 flags;

	/* Counters are read-and-clear; accumulate them into 64-bit totals */
	for (i = 0; i < ARRAY_SIZE(taxi_hw_counters); i++) {
		priv->hw_counters[i] += taxi_read(priv, taxi_hw_counters[i].reg);
		taxi_write(priv, taxi_hw_counters[i].reg, 0);
		data[n++] = priv->hw_counters[i];
	}

	/* Sticky flags (W1C): count how often each was found set */
	flags = taxi_read(priv, TAXI_FLAGS) & TAXI_FLAGS_MASK;
	taxi_write(priv, TAXI_FLAGS, flags);
	for (i = 0; i < ARRAY_SIZE(taxi_hw_flags); i++) {
		if (flags & BIT(i))
			priv->hw_flags[i]++;
		data[n++] = priv->hw_flags[i];
	}

	data[n++] = speeds[FIELD_GET(TAXI_STATUS_SPEED,
				     taxi_read(priv, TAXI_STATUS))];
}

static const struct ethtool_ops taxi_ethtool_ops = {
	.get_drvinfo		= taxi_get_drvinfo,
	.get_link		= ethtool_op_get_link,
	.get_link_ksettings	= phy_ethtool_get_link_ksettings,
	.set_link_ksettings	= phy_ethtool_set_link_ksettings,
	.nway_reset		= phy_ethtool_nway_reset,
	.get_strings		= taxi_get_strings,
	.get_sset_count		= taxi_get_sset_count,
	.get_ethtool_stats	= taxi_get_ethtool_stats,
};

/* -------------------------------------------------------------------------
 * Probe / remove
 */

/*
 * xilinx_dma sets the S2MM interrupt-coalescing threshold to the number of
 * descriptors pending when the channel (re)starts, so with a full RX ring
 * the completion interrupt would wait for the whole ring unless the
 * channel's delay-timer interrupt (xlnx,irq-delay on the S2MM channel child
 * node) is enabled. xilinx_dma reads that property with
 * of_property_read_u8(), so it must be an 8-bit value ('/bits/ 8 <1>'); a
 * plain 32-bit cell is silently ignored by the DMA driver.
 */
static void taxi_check_irq_delay(struct taxi_priv *priv)
{
	struct device_node *dma_np = taxi_dma_dev(priv->rx_chan)->of_node;
	struct device_node *child;
	const u8 *prop;
	int len;

	if (!dma_np)
		return;

	for_each_child_of_node(dma_np, child) {
		if (!of_device_is_compatible(child, "xlnx,axi-dma-s2mm-channel"))
			continue;

		prop = of_get_property(child, "xlnx,irq-delay", &len);
		if (!prop)
			dev_warn(priv->dev,
				 "%pOF has no xlnx,irq-delay; receive latency will be poor\n",
				 child);
		else if (len != 1)
			dev_warn(priv->dev,
				 "%pOF: xlnx,irq-delay is %d bytes, xilinx_dma needs an 8-bit value ('/bits/ 8 <1>'); receive latency will be poor\n",
				 child, len);
		else if (!*prop)
			dev_warn(priv->dev,
				 "%pOF: xlnx,irq-delay is 0; receive latency will be poor\n",
				 child);
		of_node_put(child);
		return;
	}

	dev_warn(priv->dev, "no S2MM channel node under %pOF\n", dma_np);
}

static int taxi_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct device_node *np = dev->of_node;
	struct net_device *ndev;
	struct taxi_priv *priv;
	u32 id, version;
	int ret;

	ndev = devm_alloc_etherdev(dev, sizeof(*priv));
	if (!ndev)
		return -ENOMEM;

	SET_NETDEV_DEV(ndev, dev);
	platform_set_drvdata(pdev, ndev);

	priv = netdev_priv(ndev);
	priv->ndev = ndev;
	priv->dev = dev;
	spin_lock_init(&priv->tx_lock);
	spin_lock_init(&priv->rx_lock);
	init_llist_head(&priv->rx_done);
	u64_stats_init(&priv->tx_syncp);
	u64_stats_init(&priv->rx_syncp);

	priv->regs = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(priv->regs))
		return PTR_ERR(priv->regs);

	id = taxi_read(priv, TAXI_ID);
	if (id != TAXI_ID_MAGIC)
		return dev_err_probe(dev, -ENODEV,
				     "unexpected ID register 0x%08x\n", id);
	version = taxi_read(priv, TAXI_VERSION);

	ret = of_get_phy_mode(np, &priv->phy_mode);
	if (ret)
		return dev_err_probe(dev, ret, "missing phy-mode\n");
	if (!phy_interface_mode_is_rgmii(priv->phy_mode))
		return dev_err_probe(dev, -EINVAL,
				     "phy-mode %s is not an RGMII mode\n",
				     phy_modes(priv->phy_mode));

	/* Validate the DMA channels now; they are held only while open */
	ret = taxi_request_dma(priv);
	if (ret)
		return ret;
	taxi_check_irq_delay(priv);
	taxi_release_dma(priv);

	taxi_mac_reset(priv);

	ret = taxi_mdio_init(priv);
	if (ret)
		return ret;

	ret = of_get_ethdev_address(np, ndev);
	if (ret) {
		eth_hw_addr_random(ndev);
		dev_info(dev, "using random MAC address %pM\n", ndev->dev_addr);
	}

	ndev->netdev_ops = &taxi_netdev_ops;
	ndev->ethtool_ops = &taxi_ethtool_ops;
	netif_napi_add(ndev, &priv->napi, taxi_rx_poll);
	ndev->min_mtu = ETH_MIN_MTU;
	ndev->max_mtu = TAXI_MAX_MTU;
	ndev->watchdog_timeo = 5 * HZ;

	ret = register_netdev(ndev);
	if (ret)
		return dev_err_probe(dev, ret, "failed to register netdev\n");

	dev_info(dev, "TAXI RGMII MAC v%u.%u, %s\n", version >> 16,
		 version & 0xffff, phy_modes(priv->phy_mode));
	return 0;
}

static void taxi_remove(struct platform_device *pdev)
{
	struct net_device *ndev = platform_get_drvdata(pdev);

	unregister_netdev(ndev);
}

static const struct of_device_id taxi_of_match[] = {
	{ .compatible = "opsero,taxi-rgmii-mac-1.0" },
	{ }
};
MODULE_DEVICE_TABLE(of, taxi_of_match);

static struct platform_driver taxi_driver = {
	.probe	= taxi_probe,
	.remove	= taxi_remove,
	.driver	= {
		.name		= TAXI_DRV_NAME,
		.of_match_table	= taxi_of_match,
	},
};
module_platform_driver(taxi_driver);

MODULE_AUTHOR("Opsero Electronic Design Inc.");
MODULE_DESCRIPTION("Opsero Taxi RGMII MAC network driver");
MODULE_LICENSE("Dual MIT/GPL");
