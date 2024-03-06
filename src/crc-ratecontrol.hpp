#include <stdint.h>
#include <rte_config.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_mempool.h>
#include <rte_ring.h>

extern "C" {
    #include "device.h"
    #include "timestamping.h"
}

class RateLimiterCRC{
private:
    struct rte_mempool* invalid_pool;
    uint8_t port_id;
    uint16_t queue_id;
    uint64_t previous_missing_delay;
    
    const int TRANSMIT_BUFFER_SIZE = 64;
    const uint64_t MIN_PACKET_SIZE;
    const uint64_t PACKET_OVERHEAD;

    struct rte_mbuf* get_delay_packet(uint64_t delay);
public:
    RateLimiterCRC(struct rte_mempool* invalid_pool, uint8_t port_id, uint16_t queue_id, uint64_t MIN_PACKET_SIZE, uint64_t PACKET_OVERHEAD);
    void send_packets(struct rte_mbuf** load_pkts, uint16_t num_packets);
    uint64_t send_timestamp_packet(uint16_t num_packets);
    uint64_t empty_delay(uint16_t num_packets);
};