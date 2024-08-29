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
	if (delay <= invalid_packet_size) {
		delay = delay;
	} else if (delay > (2*invalid_packet_size)-100) {
		// (2*invalid_packet_size)-100 is an arbitrary chosen value as it doesn't really matter
		// we just need to avoid doing something stupid for packet sizes that are just over invalid_packet_size bytes
		delay = invalid_packet_size;
	} else {
		// delay between invalid_packet_size and ((2*invalid_packet_size)-100)
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
    alloc_mbufs(this->invalid_pool, invalid_packets, num_packets, invalid_packet_size);
    dpdk_send_all_packets(port_id, queue_id, invalid_packets, num_packets);
    return num_packets * (invalid_packet_size + PACKET_OVERHEAD);
}

uint64_t RateLimiterCRC::send_timestamp_packet(uint16_t num_packets){
    struct rte_mbuf* invalid_packets[1024];
    alloc_mbufs(this->invalid_pool, invalid_packets, num_packets, invalid_packet_size);
    invalid_packets[0]->ol_flags |= RTE_MBUF_F_TX_IEEE1588_TMST;
    dpdk_send_all_packets(port_id, queue_id, invalid_packets, num_packets);
    return num_packets * (invalid_packet_size + PACKET_OVERHEAD);
}

void RateLimiterCRC::set_invalid_packet_size(uint64_t invalid_packet_size){
	this->invalid_packet_size = invalid_packet_size;
}

RateLimiterCRC::RateLimiterCRC(struct rte_mempool* invalid_pool, uint8_t port_id, uint16_t queue_id, uint64_t MIN_PACKET_SIZE, uint64_t PACKET_OVERHEAD, uint64_t invalid_packet_size):
	 invalid_pool{invalid_pool}, port_id{port_id}, queue_id{queue_id}, previous_missing_delay{0}, invalid_packet_size{invalid_packet_size}, MIN_PACKET_SIZE{MIN_PACKET_SIZE}, PACKET_OVERHEAD{PACKET_OVERHEAD}
	 {}


extern "C"{
	RateLimiterCRC* mg_ratelimiter_crc_create(struct rte_mempool* invalid_pool, uint8_t port_id, uint16_t queue_id, uint64_t MIN_PACKET_SIZE, uint64_t PACKET_OVERHEAD, uint64_t invalid_packet_size) {
		return new RateLimiterCRC(invalid_pool, port_id, queue_id, MIN_PACKET_SIZE, PACKET_OVERHEAD, invalid_packet_size);
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

	void mg_ratelimiter_crc_set_invalid_packet_size(RateLimiterCRC* ratelimiter, uint64_t invalid_packet_size){
		return ratelimiter->set_invalid_packet_size(invalid_packet_size);
	}

	uint64_t moongen_get_bad_pkts_sent(uint8_t port_id) {
		return __sync_fetch_and_add(&bad_pkts_sent[port_id], 0);
	}

	uint64_t moongen_get_bad_bytes_sent(uint8_t port_id) {
		return __sync_fetch_and_add(&bad_bytes_sent[port_id], 0);
	}
}