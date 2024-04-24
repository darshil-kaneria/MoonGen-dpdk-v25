#pragma once
#include <stdbool.h>

/**
 * @brief Gilbert-Elliot (GE) model for packet loss.
 *
 *              -------      p       -------
 *       +---->/       \----------->/       \-----+
 *    1-p|    /  GOOD   \          /   BAD   \    |1-r
 *       |    \  (1-k)  /          \  (1-h)  /    |
 *       +-----\       /<-----------\       /<----+
 *              -------      r       -------
 *
 * @param good the link state, either good (true) or bad (false)
 * @param p the transition probability for good->bad.
 * (0 %) 0 <= p <= RAND_MAX (100 %).
 * @param r the transition probability for bad->good.
 * (0 %) 0 <= r <= RAND_MAX (100 %).
 * @param h_ the probability for loss in the bad state (1-h).
 * (0 %) 0 <= h_ <= RAND_MAX (100 %).
 * @param k_ the probability for loss in the good state (1-k).
 * (0 %) 0 <= k_ <= RAND_MAX (100 %).
 **/
struct ge_model {
     bool good;
     int p;
     int r;
     int h_;
     int k_;
};

/**
 * @brief Should the packet be dropped according to the GE-model?
 *
 * @param m must be a valid ge_model instantiation (not 0)
 *
 * @return true packet should be dropped
 * @return false packet should NOT be dropped
 **/
bool ge_drop(struct ge_model m[static 1]);
