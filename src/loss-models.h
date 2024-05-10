#pragma once
#include <stdlib.h>		// for size_t
#include <stdbool.h>

enum loss_model { ge, netem };

/**
 * @brief Gilbert-Elliot (GE) model for packet loss.
 *
 * C.t. E. O. Elliott, “A Model of the Switched Telephone Network for Data
 * Communications”, The Bell System Technical Journal, vol. 44, no. 1, pp.
 * 89–109, 1965.
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
     bool (*drop)(struct ge_model* m);
};

/**
 * @brief Initialize a ge_model.
 *
 * @param m ge_model object to initialize. If 0, nothing is done.
 * @param len length of the array with model probabilities
 * @param prob array with the probabilities for the ge_model:
 * [p [r [(1-h) [(1-k)]]]]
 **/ 
struct ge_model* ge_init(struct ge_model* m,
			 size_t const len,
			 double const prob[static len]);

/**
 * @brief Should the packet be dropped according to the GE-model?
 *
 * @param m must be a valid ge_model instantiation (not 0)
 *
 * @return true packet should be dropped
 * @return false packet should NOT be dropped
 **/
bool ge_drop(struct ge_model m[static 1]);


enum netem_model_state { q1, q2, q3, q4, q_num };
enum netem_model_state_prob { p_stay, p_keep_link_state, p_num };

/**
 * @brief NetEm model for packet loss.
 *
 * C.t. S. Salsano, F. Ludovici, A. Ordine, and D. Giannuzzi, “Definition of a
 * general and intuitive loss model for packet networks and its implementation
 * in the NetEm module in the Linux kernel”
 *
 *                     1-p13-p14       1-p31-p32
 *                       +---+           +---+
 *                       |   V           |   V
 *      -------    1    -------   p13   -------   p32   -------
 *     /       \------>/       \------>/       \------>/       \----+
 *    /   q4    \     /   q1    \     /   q3    \     /   q2    \   | 1-p23
 *    \  Loss   /     \   OK    /     \  Loss   /     \   OK    /   |
 *     \       /<------\       /<------\       /<------\       /<---+
 *      -------   p14   -------   p31   -------   p23   -------
 *
 *   |---------------------------|   |---------------------------|
 *          GOOD link state                 BAD link state
 *
 * @param state the current state the model is in: q1|q2|q3|q4.
 * @param p probabilities for each state: probability to stay in the same state
 * and probability to switch state, but stay in the same link state (good/bad).
 * @param drop drop-function, which indicates whether a packet should be dropped
 * according to the current model state and a generated random number
 **/
struct netem_model {
     enum netem_model_state state;
     int p[q_num][p_num];
     bool (*drop)(struct netem_model* m);
};

/**
 * @brief Initialize a netem_model.
 *
 * @param m netem_model object to initialize. If 0, nothing is done.
 * @param len length of the array with model probabilities.
 * @param prob array with the probabilities for the netem_model.
 **/
struct netem_model* netem_init(struct netem_model* m,
			       size_t const len,
			       double const prob[static len]);

/**
 * @brief Should the packet be dropped according to the NetEm model?
 *
 * @param m: must be a valid netem_model instantiation (not 0)
 *
 * @return true: packet should be dropped
 * @return false: packet should NOT be dropped
 **/
bool netem_drop(struct netem_model m[static 1]);
