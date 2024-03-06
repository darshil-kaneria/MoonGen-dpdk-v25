#include "crc-ratecontrol.hpp"

extern "C"{
	void alloc_mbufs(struct rte_mempool* mp, struct rte_mbuf* bufs[], uint32_t len, uint16_t pkt_len);
	static uint64_t bad_pkts_sent[RTE_MAX_ETHPORTS];
	static uint64_t bad_bytes_sent[RTE_MAX_ETHPORTS];
} 

void RateLimiterCRC::send_packets(struct rte_mbuf** load_pkts, uint16_t num_packets){
	uint32_t num_bad_pkts = 0;
	uint32_t num_bad_bytes = 0;
    
	struct rte_mbuf* pkts[TRANSMIT_BUFFER_SIZE];
	int send_buf_idx = 0;
	for (uint16_t i = 0; i < num_packets; i++) {
		struct rte_mbuf* pkt = load_pkts[i];

		// skip deleted packets
		if(pkt == NULL)continue;

		// desired inter-frame spacing is encoded in the timestamp dynfield
		uint64_t delay = get_timestamp_dynfield(pkt) + previous_missing_delay;

		// step 1: generate delay-packets
		while (delay >= MIN_PACKET_SIZE + PACKET_OVERHEAD) {
			struct rte_mbuf* pkt = get_delay_packet(delay);
			if (pkt) {
				delay -= pkt->pkt_len + PACKET_OVERHEAD;
				pkts[send_buf_idx++] = pkt;
				num_bad_pkts++;
				num_bad_bytes += pkt->pkt_len + PACKET_OVERHEAD - 20;
			}
			if (send_buf_idx >= TRANSMIT_BUFFER_SIZE) {
				dpdk_send_all_packets(port_id, queue_id, pkts, send_buf_idx);
				send_buf_idx = 0;
			}
		}

		// step 2: send the packet
        previous_missing_delay = delay;
		pkts[send_buf_idx++] = pkt;
		// don't forget to send the last batch
		if (send_buf_idx >= TRANSMIT_BUFFER_SIZE || i + 1 == num_packets) {
			dpdk_send_all_packets(port_id, queue_id, pkts, send_buf_idx);
			send_buf_idx = 0;
		}
	}

	// atomic as multiple threads may use the same stats register from multiple queues
	__sync_fetch_and_add(&bad_pkts_sent[port_id], num_bad_pkts);
	__sync_fetch_and_add(&bad_bytes_sent[port_id], num_bad_bytes);
}

struct rte_mbuf* RateLimiterCRC::get_delay_packet(uint64_t delay){
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

	struct rte_mbuf* pkt = rte_pktmbuf_alloc(this->invalid_pool);
	pkt->data_len = delay - PACKET_OVERHEAD;
	pkt->pkt_len = delay - PACKET_OVERHEAD;
	pkt->ol_flags |= RTE_MBUF_F_TX_NO_CRC_CSUM;
	return pkt;
}

uint64_t RateLimiterCRC::empty_delay(uint16_t num_packets){
    struct rte_mbuf* invalid_packets[1024];
    alloc_mbufs(this->invalid_pool, invalid_packets, num_packets, 9000);
    dpdk_send_all_packets(port_id, queue_id, invalid_packets, num_packets);
    return num_packets * 9024;
}

uint64_t RateLimiterCRC::send_timestamp_packet(uint16_t num_packets){
    struct rte_mbuf* invalid_packets[1024];
    alloc_mbufs(this->invalid_pool, invalid_packets, num_packets, 9000);
    invalid_packets[0]->ol_flags |= RTE_MBUF_F_TX_IEEE1588_TMST;
    dpdk_send_all_packets(port_id, queue_id, invalid_packets, num_packets);
    return num_packets * 9024;
}

RateLimiterCRC::RateLimiterCRC(struct rte_mempool* invalid_pool, uint8_t port_id, uint16_t queue_id, uint64_t MIN_PACKET_SIZE, uint64_t PACKET_OVERHEAD):
	 invalid_pool{invalid_pool}, port_id{port_id}, queue_id{queue_id}, previous_missing_delay{0}, MIN_PACKET_SIZE{MIN_PACKET_SIZE}, PACKET_OVERHEAD{PACKET_OVERHEAD}
	 {}


extern "C"{
	RateLimiterCRC* mg_ratelimiter_crc_create(struct rte_mempool* invalid_pool, uint8_t port_id, uint16_t queue_id, uint64_t MIN_PACKET_SIZE, uint64_t PACKET_OVERHEAD) {
		return new RateLimiterCRC(invalid_pool, port_id, queue_id, MIN_PACKET_SIZE, PACKET_OVERHEAD);
	}

	void mg_ratelimiter_crc_send_packets(RateLimiterCRC* ratelimiter, struct rte_mbuf** load_pkts, uint16_t num_packets){
		ratelimiter->send_packets(load_pkts, num_packets);
	}

    uint64_t mg_ratelimiter_crc_send_timestamp_packet(RateLimiterCRC* ratelimiter, uint16_t num_packets){
		return ratelimiter->send_timestamp_packet(num_packets);
	}

    uint64_t mg_ratelimiter_crc_empty_delay(RateLimiterCRC* ratelimiter, uint16_t num_packets){
		return ratelimiter->empty_delay(num_packets);
	}

	uint64_t moongen_get_bad_pkts_sent(uint8_t port_id) {
		return __sync_fetch_and_add(&bad_pkts_sent[port_id], 0);
	}

	uint64_t moongen_get_bad_bytes_sent(uint8_t port_id) {
		return __sync_fetch_and_add(&bad_bytes_sent[port_id], 0);
	}
}