#include <stdint.h>
#include <assert.h>
#include <stdlib.h>             /* for RAND_MAX */

#include <rte_ethdev.h>		// for rte_eth_rx_burst
#include "lifecycle.h"		// for is_running
#include "device.h"		// for dpdk_send_all_packets

#include "loss-models.h"

#define BATCH_SIZE 64

/* only for moonem.lua */
int get_rand_max() {
     return RAND_MAX;
}

/* To conveniently pass dev_info from Lua to C */
struct moonem_dev {
     uint8_t port_id;
     uint16_t queue_id;
};

void fwd(struct moonem_dev const rx_dev[static 1],
	 struct moonem_dev const tx_dev[static 1]) {
     struct rte_mbuf* bufs[BATCH_SIZE];
     uint16_t n = 0;
  
     while (is_running(0)) {
          if ((n = rte_eth_rx_burst(rx_dev->port_id, rx_dev->queue_id,
				    bufs, BATCH_SIZE)))
               dpdk_send_all_packets(tx_dev->port_id, tx_dev->queue_id,
				     bufs, n);
     }
}

void fwd_ge(struct moonem_dev const rx_dev[static 1],
            struct moonem_dev const tx_dev[static 1],
	    struct ge_model model[static 1]) {
     struct rte_mbuf* rx_bufs[BATCH_SIZE];
     struct rte_mbuf* tx_bufs[BATCH_SIZE];
     uint16_t n = 0;

     while (is_running(0)) {
          if ((n = rte_eth_rx_burst(rx_dev->port_id, rx_dev->queue_id,
				    rx_bufs, BATCH_SIZE))) {
               uint16_t k = 0;
               for (uint16_t i = 0; i < n; ++i) {
                    if (ge_drop(model))
                         rte_pktmbuf_free(rx_bufs[i]);
                    else
                         tx_bufs[k++] = rx_bufs[i];
               }
               dpdk_send_all_packets(tx_dev->port_id, tx_dev->queue_id,
				     tx_bufs, k);
          }
     }
}
