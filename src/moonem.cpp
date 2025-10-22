#include <stdint.h>
#include <rte_config.h>
#include <rte_ethdev.h>

#include <rte_mempool.h>
#include <rte_malloc.h>
#include <rte_mbuf_dyn.h>
#include <rte_ip.h>
#include <algorithm>
#include <stdlib.h>
#include <limits.h>
extern "C" {
	#include "lifecycle.h"
	#include "timestamping.h"
	#include "device.h"
}
#include "moonem_common.h"

extern "C" void receiver_loop_delay(int port_id, int queue_id, struct rte_ring* packet_ring, struct moonem_config config){
	rte_delay_ms(1000);
	struct rte_mbuf* rx_pkts[BURST_SIZE];
	struct rte_mbuf* rx_pkts_loss[BURST_SIZE];
	uint64_t loss_state[2];
	loss_state[0] = config.loss_seed;
	loss_state[1] = 0;
	while (is_running(0)) {
		uint16_t rx = rte_eth_rx_burst(port_id, queue_id, rx_pkts, BURST_SIZE);
		for (int i = 0; i < rx; i++) {
			uint64_t ts = get_timestamp_dynfield(rx_pkts[i]);
			uint64_t send_time = ts + config.delay;
			set_timestamp_dynfield(rx_pkts[i], send_time);
		}
		if(rx > 0){
			if(config.loss_type != NONE){
				uint16_t rx_loss = applyLoss(rx, rx_pkts, rx_pkts_loss, loss_state, config);
				rte_ring_sp_enqueue_bulk(packet_ring, (void**)rx_pkts_loss, rx_loss, NULL);
			}else{
				rte_ring_sp_enqueue_bulk(packet_ring, (void**)rx_pkts, rx, NULL);
			}
		}
	}
}

extern "C" void receiver_loop_rate_leaky_bucket(int port_id, int queue_id, struct rte_ring* packet_ring, struct moonem_config config){
	const double B_P_NS_TARGET = config.rate / 1000.0d;
	const double BACKLOG_BOUND = config.capacity / (B_P_NS_TARGET / 8);

	rte_delay_ms(1000);
	struct rte_mbuf* bufs[BURST_SIZE];
	struct rte_mbuf* bufs_accept[BURST_SIZE];
	struct rte_mbuf* bufs_send[BURST_SIZE];
	uint64_t loss_state[2];
	loss_state[0] = config.loss_seed;
	loss_state[1] = 0;
	double next_at = 0;

	while (is_running(0)) {
		int accept_index = 0;
		uint16_t rx = rte_eth_rx_burst(port_id, queue_id, bufs, BURST_SIZE);
		for (int i = 0; i < rx; i++) {
			uint64_t send_time = get_timestamp_dynfield(bufs[i]) + config.delay;
			double real_send_time = MAX(send_time, next_at);
			double backlog = real_send_time - send_time;

			if(backlog > BACKLOG_BOUND){
				rte_pktmbuf_free(bufs[i]);
			}else{
				set_timestamp_dynfield(bufs[i], real_send_time);
				bufs_accept[accept_index++] = bufs[i];
				next_at = real_send_time + (((bufs[i]->pkt_len + 24) * 8 ) / B_P_NS_TARGET);
			}
		}
		if(accept_index > 0){
			if(config.loss_type != NONE){
				uint16_t rx_loss = applyLoss(accept_index, bufs_accept, bufs_send, loss_state, config);
				rte_ring_sp_enqueue_bulk(packet_ring, (void**)bufs_send, rx_loss, NULL);
			}else{
				rte_ring_sp_enqueue_bulk(packet_ring, (void**)bufs_accept, accept_index, NULL);
			}
		}
	}
}

extern "C" void receiver_loop_rate_token_bucket_fwd(int port_id_rx, int queue_id_rx, int port_id_tx, int queue_id_tx, struct moonem_config config){
	const double TOKEN_RATE = config.rate / 8000.0d;

	rte_delay_ms(1000);
	struct rte_mbuf* bufs[BURST_SIZE];
	struct rte_mbuf* bufs_accept[BURST_SIZE];
	struct rte_mbuf* bufs_send[BURST_SIZE];
	uint64_t loss_state[2];
	loss_state[0] = config.loss_seed;
	loss_state[1] = 0;
	double previous_timestamp = 0;
	double previous_tokens = 0;

	while (is_running(0)) {
		int accept_index = 0;
		uint16_t rx = rte_eth_rx_burst(port_id_rx, queue_id_rx, bufs, BURST_SIZE);
		for (int i = 0; i < rx; i++) {
			uint64_t recv_time = get_timestamp_dynfield(bufs[i]);
			double current_tokens = MIN(previous_tokens + (recv_time - previous_timestamp) * TOKEN_RATE, config.capacity);

			if(current_tokens > (bufs[i]->pkt_len+24)){
				previous_timestamp = recv_time;
				previous_tokens = current_tokens - (bufs[i]->pkt_len+24);
				bufs_accept[accept_index++] = bufs[i];
			}else{
				rte_pktmbuf_free(bufs[i]);
			}
		}
		if(accept_index > 0){
			if(config.loss_type != NONE){
				uint16_t rx_loss = applyLoss(accept_index, bufs_accept, bufs_send, loss_state, config);
				dpdk_send_all_packets(port_id_tx, queue_id_tx, bufs_send, rx_loss);
			}else{
				dpdk_send_all_packets(port_id_tx, queue_id_tx, bufs_accept, accept_index);
			}
		}
	}
}

extern "C" void receiver_loop_rate_token_bucket(int port_id, int queue_id, struct rte_ring* packet_ring, struct moonem_config config){
	const double TOKEN_RATE = config.rate / 8000.0d;

	rte_delay_ms(1000);
	struct rte_mbuf* bufs[BURST_SIZE];
	struct rte_mbuf* bufs_accept[BURST_SIZE];
	struct rte_mbuf* bufs_send[BURST_SIZE];
	uint64_t loss_state[2];
	loss_state[0] = config.loss_seed;
	loss_state[1] = 0;
	double previous_timestamp = 0;
	double previous_tokens = 0;

	while (is_running(0)) {
		int accept_index = 0;
		uint16_t rx = rte_eth_rx_burst(port_id, queue_id, bufs, BURST_SIZE);
		for (int i = 0; i < rx; i++) {
			uint64_t recv_time = get_timestamp_dynfield(bufs[i]);
			double current_tokens = MIN(previous_tokens + (recv_time - previous_timestamp) * TOKEN_RATE, config.capacity);

			if(current_tokens > (bufs[i]->pkt_len+24)){
				previous_timestamp = recv_time;
				previous_tokens = current_tokens - (bufs[i]->pkt_len+24);

				set_timestamp_dynfield(bufs[i], recv_time + config.delay);
				bufs_accept[accept_index++] = bufs[i];
			}else{
				rte_pktmbuf_free(bufs[i]);
			}
		}
		if(accept_index > 0){
			if(config.loss_type != NONE){
				uint16_t rx_loss = applyLoss(accept_index, bufs_accept, bufs_send, loss_state, config);
				rte_ring_sp_enqueue_bulk(packet_ring, (void**)bufs_send, rx_loss, NULL);
			}else{
				rte_ring_sp_enqueue_bulk(packet_ring, (void**)bufs_accept, accept_index, NULL);
			}
		}
	}
}