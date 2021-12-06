#include <stdint.h>
#include <rte_config.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_mempool.h>

#include "device.h"
#include "timestamping.h"

/*
    modfied code from the Moongen crc rate limiting code
*/

static struct rte_mbuf* get_delay_pkt_bad_crc_wire(struct rte_mempool* pool, uint64_t* rem_delay, uint32_t min_pkt_size, uint32_t packet_overhead) {
	// _Thread_local support seems to suck in (older?) gcc versions?
	// this should give us the best compatibility
	static __thread uint64_t remainingDelay = 0;
	uint64_t delay = *rem_delay;

	// add delay
	if (delay < min_pkt_size + packet_overhead) {
        remainingDelay += delay;
		*rem_delay = 0;
		return NULL;
	}

	// calculate the optimimum packet size
	if (delay < 9000) {
		delay = delay;
	} else if (delay > 15000) {
		// 2000 is an arbitrary chosen value as it doesn't really matter
		// we just need to avoid doing something stupid for packet sizes that are just over 1538 bytes
		delay = 9000;
	} else {
		// delay between 9000 and 15000
		delay = delay / 2;
	}

	*rem_delay -= delay;
	struct rte_mbuf* pkt = rte_pktmbuf_alloc(pool);

	// account for preamble, sfd, and ifg (CRC is disabled)
	pkt->data_len = delay - packet_overhead;
	pkt->pkt_len = delay - packet_overhead;

	return pkt;
}

void moongen_send_all_packets_with_delay_bad_crc_wire(uint8_t port_id, uint16_t queue_id, struct rte_mbuf** load_pkts, uint16_t num_pkts, struct rte_mempool* pool, uint32_t min_pkt_size, uint32_t packet_overhead) {
	const int BUF_SIZE = 512;
	struct rte_mbuf* pkts[BUF_SIZE];
	int send_buf_idx = 0;
	uint64_t num_bad_pkts = 0;
	uint64_t num_bad_bytes = 0;
	for (uint16_t i = 0; i < num_pkts; i++) {
		struct rte_mbuf* pkt = load_pkts[i];
		// desired inter-frame spacing is encoded in the timestamp dynfield
		uint64_t delay = get_timestamp_dynfield(pkt);

		// step 1: generate delay-packets
		while (delay > 0) {
			struct rte_mbuf* pkt = get_delay_pkt_bad_crc_wire(pool, &delay, min_pkt_size, packet_overhead);
			if (pkt) {
				num_bad_pkts++;
				// packet size: [MAC, CRC] to be consistent with HW counters
				num_bad_bytes += pkt->pkt_len;
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
	return;
}

uint64_t moongen_send_all_delay_offset_e810(uint8_t port_id, uint16_t queue_id, struct rte_mbuf** load_pkts, uint16_t num_pkts, struct rte_mempool* pool, uint64_t currentByteOffset, uint64_t firstPacketTimestamp, uint64_t delay) {	
	//calculate delay based on the delay value, the receive tiestamp and the current transmit offset
	for (uint16_t i = 0; i < num_pkts; i++) {
		uint64_t current_sending_time = firstPacketTimestamp + (currentByteOffset * 0.08);
		struct rte_mbuf* pkt = load_pkts[i];
		
		uint64_t goal_sending_time = get_timestamp_dynfield(pkt) + delay;

		if(goal_sending_time < current_sending_time){
			set_timestamp_dynfield(pkt, 0);
			printf("delay not possible: sending immediately\n");
		}else{
			uint64_t delayBytes = (goal_sending_time - current_sending_time) / 0.08;
			set_timestamp_dynfield(pkt, delayBytes);
			currentByteOffset += pkt->data_len + 24 + delayBytes;
		}
	}

	// send batch of packets with modified delay values
	moongen_send_all_packets_with_delay_bad_crc_wire(port_id, queue_id, load_pkts, num_pkts, pool, 64, 24);

	return currentByteOffset;
}