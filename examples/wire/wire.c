#include <stdint.h>
#include <rte_config.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_mempool.h>
#include <rte_ring.h>

#include "device.h"
#include "timestamping.h"

uint64_t ice_read_current_timer(int port);

/*
    modfied code from the Moongen crc rate limiting code
*/

static uint64_t INV_SIZE = 9000;
static uint64_t DELAY_BATCH_SIZE = 128;
static uint64_t RECV_BATCH_SIZE = 512;
static uint64_t MIN_PACKET_SIZE = 64;
static uint64_t PACKET_OVERHEAD = 24;

// for 100G
static double NANOSECONDS_PER_BYTE = 0.08;

void setOtherRate(uint64_t rate){
	// special parameters for 10G links
	// other link speeds (other than 100G) were not tested
	if(rate == 10000){
		INV_SIZE = 1500;
		DELAY_BATCH_SIZE = 64;
		RECV_BATCH_SIZE = 64;
	}
	NANOSECONDS_PER_BYTE *= (100000.0/rate);
}

static struct rte_mbuf* get_delay_pkt_bad_crc_wire(struct rte_mempool* pool, uint64_t delay) {
	// calculate the optimimum packet size
	if (delay <= 9000) {
		delay = delay;
	} else if (delay > 15000) {
		// 15000 is an arbitrary chosen value as it doesn't really matter
		// we just need to avoid doing something stupid for packet sizes that are just over 9000 bytes
		delay = 9000;
	} else {
		// delay between 9000 and 15000
		delay = delay / 2;
	}

	struct rte_mbuf* pkt = rte_pktmbuf_alloc(pool);
	pkt->data_len = delay - PACKET_OVERHEAD;
	pkt->pkt_len = delay - PACKET_OVERHEAD;
	return pkt;
}

void moongen_send_all_packets_with_delay_bad_crc_wire(uint8_t port_id, uint16_t queue_id, struct rte_mbuf** load_pkts, uint16_t num_pkts, struct rte_mempool* pool) {
	const int BUF_SIZE = 128;
	struct rte_mbuf* pkts[BUF_SIZE];
	int send_buf_idx = 0;
	for (uint16_t i = 0; i < num_pkts; i++) {
		struct rte_mbuf* pkt = load_pkts[i];

		// skip deleted packets
		if(pkt == NULL)continue;

		// desired inter-frame spacing is encoded in the timestamp dynfield
		uint64_t delay = get_timestamp_dynfield(pkt);

		// step 1: generate delay-packets
		while (delay >= MIN_PACKET_SIZE + PACKET_OVERHEAD) {
			struct rte_mbuf* pkt = get_delay_pkt_bad_crc_wire(pool, delay);
			if (pkt) {
				delay -= pkt->pkt_len + PACKET_OVERHEAD;
				pkts[send_buf_idx++] = pkt;
			}
			if (send_buf_idx >= BUF_SIZE) {
				dpdk_send_all_packets(port_id, queue_id, pkts, send_buf_idx);
				send_buf_idx = 0;
			}
		}
		// step 2: send the packet
		pkts[send_buf_idx++] = pkt;
		if (send_buf_idx >= BUF_SIZE || i + 1 == num_pkts) { // don't forget to send the last batch
			dpdk_send_all_packets(port_id, queue_id, pkts, send_buf_idx);
			send_buf_idx = 0;
		}
	}
}

uint64_t moongen_send_all_delay_offset_e810(uint8_t port_id, uint16_t queue_id, struct rte_mbuf** load_pkts, uint16_t num_pkts, struct rte_mempool* pool, uint64_t currentByteOffset, uint64_t firstPacketTimestamp, uint64_t delay) {	
	//calculate delay based on the delay value, the receive tiestamp and the current transmit offset
	for (uint16_t i = 0; i < num_pkts; i++) {
		struct rte_mbuf* pkt = load_pkts[i];

		uint64_t current_sending_time = firstPacketTimestamp + (currentByteOffset * NANOSECONDS_PER_BYTE);
		uint64_t goal_sending_time = get_timestamp_dynfield(pkt) + delay;

		int64_t sending_time_diff = goal_sending_time - current_sending_time;
		if(sending_time_diff < 0){
			// if the packet is signigicantly late -> drop it
			if(sending_time_diff < -10000){
				rte_pktmbuf_free(pkt);
				load_pkts[i] = NULL;
				continue;
			}

			// for packets which are slightly to late (e.g. due to measurement error) -> send without delay
			set_timestamp_dynfield(pkt, 0);
			currentByteOffset += pkt->pkt_len + PACKET_OVERHEAD;
			continue;
		}

		currentByteOffset += pkt->pkt_len + PACKET_OVERHEAD;
		
		uint64_t delayBytes = (goal_sending_time - current_sending_time) / NANOSECONDS_PER_BYTE;
		if(delayBytes < MIN_PACKET_SIZE + PACKET_OVERHEAD){
			// delay bytes not possible => send packet immediately
			set_timestamp_dynfield(pkt, 0);
		}else{
			set_timestamp_dynfield(pkt, delayBytes);
			currentByteOffset += delayBytes;
		}
	}

	// send batch of packets with modified delay values
	moongen_send_all_packets_with_delay_bad_crc_wire(port_id, queue_id, load_pkts, num_pkts, pool);

	return currentByteOffset;
}

void alloc_mbufs(struct rte_mempool* mp, struct rte_mbuf* bufs[], uint32_t len, uint16_t pkt_len);

void transmitter_loop(uint8_t port_id, uint16_t queue_id, struct rte_ring* packet_ring, struct rte_mempool* pool, uint64_t currentByteOffset, uint64_t firstPacketTimestamp, uint64_t delay, bool fast, int64_t offset){
	if(fast){
		currentByteOffset = 0;
		firstPacketTimestamp = ice_read_current_timer(port_id) + offset;
	}
	
	struct rte_mbuf* load_pkts[64];
	while(1){
		uint64_t rx = rte_ring_sc_dequeue_burst(packet_ring, (void**)load_pkts, 64, NULL);
		if(rx>0){
			currentByteOffset = moongen_send_all_delay_offset_e810(port_id, queue_id, load_pkts, rx, pool, currentByteOffset, firstPacketTimestamp, delay);
		}else{
			struct rte_mbuf* invalid_packets[DELAY_BATCH_SIZE];
			alloc_mbufs(pool, invalid_packets, DELAY_BATCH_SIZE, INV_SIZE);
			dpdk_send_all_packets(port_id, queue_id, invalid_packets, DELAY_BATCH_SIZE);
			currentByteOffset += DELAY_BATCH_SIZE * (INV_SIZE + 24);
		}
	}
}

void receiver_loop(uint8_t port_id, uint16_t queue_id, struct rte_ring* packet_ring){
	struct rte_mbuf* rx_pkts[RECV_BATCH_SIZE];
	while(1) {
		uint16_t rx = rte_eth_rx_burst(port_id, queue_id, rx_pkts, RECV_BATCH_SIZE);
		if(rx>0){
			rte_ring_sp_enqueue_bulk(packet_ring, (void**)rx_pkts, rx, NULL);
		}
	}
}