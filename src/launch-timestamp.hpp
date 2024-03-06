#include <stdint.h>
#include <rte_config.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_mempool.h>
#include <rte_ring.h>
#include <atomic>

#include "crc-ratecontrol.hpp"
#include "lifecycle.hpp"

class DelayEmulator{
private:
    RateLimiterCRC* ratelimiter;
    struct rte_ring* packet_ring;
    uint8_t port_id;

    uint64_t first_timestamp;
    uint64_t current_byte_offset;

    const int TRANSMIT_BUFFER_SIZE = 64;
    const double NANOSECONDS_PER_BYTE;
    const uint64_t PACKET_OVERHEAD;

    void send_batch(struct rte_mbuf** load_pkts, uint16_t num_pkts);
public:
    DelayEmulator(RateLimiterCRC* ratelimiter, struct rte_ring* packet_ring, uint8_t port_id, uint64_t LINE_RATE, uint64_t PACKET_OVERHEAD);

    void transmit_loop();
};