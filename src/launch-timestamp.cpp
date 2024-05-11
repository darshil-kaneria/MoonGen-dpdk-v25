#include "launch-timestamp.hpp"

void DelayEmulator::send_batch(struct rte_mbuf** load_pkts, uint16_t num_pkts){
    //calculate delay based on the desired transmit time and the current transmit offset
	for (uint16_t i = 0; i < num_pkts; i++) {
		struct rte_mbuf* pkt = load_pkts[i];

		uint64_t current_sending_time = first_timestamp + (current_byte_offset * NANOSECONDS_PER_BYTE);
		uint64_t goal_sending_time = get_timestamp_dynfield(pkt);

		int64_t sending_time_diff = goal_sending_time - current_sending_time;
		if(sending_time_diff < 0){
			// if the packet is signigicantly late -> drop it
			if(sending_time_diff < -100000){
				rte_pktmbuf_free(pkt);
				load_pkts[i] = NULL;
				continue;
			}

			// for packets which are slightly to late (e.g. due to measurement error) -> send without delay
			set_timestamp_dynfield(pkt, 0);
			current_byte_offset += pkt->pkt_len + PACKET_OVERHEAD;
			continue;
		}

        // set delay in the timestamp dynfield
		uint64_t delay_bytes = sending_time_diff / NANOSECONDS_PER_BYTE;
        set_timestamp_dynfield(pkt, delay_bytes);
        current_byte_offset += pkt->pkt_len + PACKET_OVERHEAD + delay_bytes;
	}

	ratelimiter->send_packets(load_pkts, num_pkts);
}

void DelayEmulator::transmit_loop(){
	ratelimiter->set_invalid_packet_size(1500);
	rte_delay_ms(500);

	// warmup
	for(int i = 0; i < 100; i++){
		ratelimiter->empty_delay(64);
	}

	// send timestamp packet
	current_byte_offset = ratelimiter->send_timestamp_packet(64);
	
	// wait for timestamped packet to be transmitted
	for(int i = 0; i < 100; i++){
		current_byte_offset += ratelimiter->empty_delay(64);
	}

	// read timestamp
	struct timespec timestamp = {0, 0};
	rte_eth_timesync_read_tx_timestamp(port_id, &timestamp);
	first_timestamp = timestamp.tv_sec * 1000000000ull + timestamp.tv_nsec;

	// transmit delay packets
	struct rte_mbuf* transmit_pkts[TRANSMIT_BUFFER_SIZE];
	while(libmoon::is_running(0)){
		uint64_t rx = rte_ring_sc_dequeue_burst(packet_ring, (void**)transmit_pkts, TRANSMIT_BUFFER_SIZE, NULL);
		if(rx>0){
			ratelimiter->set_invalid_packet_size(9000);
			send_batch(transmit_pkts, rx);
		}else{
			ratelimiter->set_invalid_packet_size(1500);
			current_byte_offset += ratelimiter->empty_delay(64);
		}
	}
}

DelayEmulator::DelayEmulator(RateLimiterCRC* ratelimiter, struct rte_ring* packet_ring, uint8_t port_id, uint64_t LINE_RATE, uint64_t PACKET_OVERHEAD)
	: ratelimiter{ratelimiter}, packet_ring{packet_ring}, port_id{port_id}, NANOSECONDS_PER_BYTE{0.08d * (100000.0d / LINE_RATE)}, PACKET_OVERHEAD{PACKET_OVERHEAD} 
{}

extern "C"{
	DelayEmulator* mg_launchtimer_create(RateLimiterCRC* ratelimiter, struct rte_ring* packet_ring, uint8_t port_id, uint64_t LINE_RATE, uint64_t PACKET_OVERHEAD) {
		return new DelayEmulator(ratelimiter, packet_ring, port_id, LINE_RATE, PACKET_OVERHEAD);
	}

    void mg_launchtimer_transmit_loop(DelayEmulator* launchtimer){
		launchtimer->transmit_loop();
	}
}