#include "moonem_common.h"

int applyLoss_export(uint16_t rx, struct rte_mbuf** bufs, struct rte_mbuf** bufs_send, uint64_t* loss_state, struct moonem_config config){
   return applyLoss(rx, bufs, bufs_send, loss_state, config);
}
	