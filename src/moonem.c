#include <stdint.h>
#include <assert.h>
#include <stdlib.h>             // for RAND_MAX

#include <rte_ethdev.h>		// for rte_eth_rx_burst
#include "lifecycle.h"		// for is_running
#include "device.h"		// for dpdk_send_all_packets

#include "loss-models.h"

#define BATCH_SIZE 64

/**
 * @brief Forward traffic with loss model M from RX to TX.
 **/
#define FWD_LOSS(M, RX, TX)                                               \
struct rte_mbuf* rx_bufs[BATCH_SIZE];                                     \
struct rte_mbuf* tx_bufs[BATCH_SIZE];                                     \
uint16_t n = 0;                                                           \
while (is_running(0)) {                                                   \
     if ((n = rte_eth_rx_burst((RX)->port_id, (RX)->queue_id,             \
                               rx_bufs, BATCH_SIZE))) {                   \
          uint16_t k = 0;                                                 \
          for (uint16_t i = 0; i < n; ++i) {                              \
               if ((M)->drop(M))                                          \
                    rte_pktmbuf_free(rx_bufs[i]);                         \
               else                                                       \
                    tx_bufs[k++] = rx_bufs[i];                            \
          }                                                               \
          dpdk_send_all_packets((TX)->port_id, (TX)->queue_id,            \
                                tx_bufs, k);                              \
     }                                                                    \
}

/**
 * @brief Helper struct to conveniently pass device info from Lua to C
 **/
struct moonem_dev {
     uint8_t const port_id;
     uint16_t const queue_id;
};

/**
 * @brief Forward traffic from RX to TX.
 **/
void fwd(struct moonem_dev const rx[static 1],
	 struct moonem_dev const tx[static 1]) {
     struct rte_mbuf* bufs[BATCH_SIZE];
     uint16_t n = 0;

     while (is_running(0)) {
          if ((n = rte_eth_rx_burst(rx->port_id, rx->queue_id, bufs, BATCH_SIZE)))
               dpdk_send_all_packets(tx->port_id, tx->queue_id, bufs, n);
     }
}

static void fwd_loss_ge(struct ge_model m[static 1],
			struct moonem_dev const rx[static 1],
			struct moonem_dev const tx[static 1]) {
     FWD_LOSS(m, rx, tx);
}

static void fwd_loss_netem(struct netem_model m[static 1],
			   struct moonem_dev const rx[static 1],
			   struct moonem_dev const tx[static 1]) {
     FWD_LOSS(m, rx, tx);
}

/**
 * @brief Forward traffic from RX to TX with packet loss.
 **/
void fwd_loss(struct moonem_dev const rx[static 1],
	      struct moonem_dev const tx[static 1],
	      enum loss_model model_type,
	      size_t const len,
	      double const prob[static len]) {
     switch (model_type) {
     case ge: {
	  struct ge_model* m = ge_init(malloc(sizeof(struct ge_model)), len, prob);
	  assert(m);
	  fwd_loss_ge(m, rx, tx);
	  free(m);
	  break;
     }
     case netem: {
	  struct netem_model* m = netem_init(malloc(sizeof(struct netem_model)), len, prob);
	  assert(m);
	  fwd_loss_netem(m, rx, tx);
	  free(m);
	  break;
     }
     default: perror("Unkown model type."); exit(1);
     }
}
