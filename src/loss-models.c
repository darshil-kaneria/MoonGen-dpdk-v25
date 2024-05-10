#include "loss-models.h"
#include <assert.h>
#include <stdlib.h>             /* for rand() */


#define PROB_MIN 0.0
#define PROB_MAX 1.0

/**
 * @brief Norm probability to [0, RAND_MAX]
 *
 * @param d double representing a probability in [0,1].
 * @return integer representing the probability of d in [0, RAND_MAX]
 **/ 
static int norm_to_rand_max(double const d) {
     return (int) (RAND_MAX * d);
}

struct ge_model* ge_init(struct ge_model* m,
			 size_t const len,
			 double const prob[static len]) {
     if (!m) return m;
     
     // check that passed probabilities are within valid range
     for (size_t i = 0; i < len; ++i)
	  assert(prob[i] >= PROB_MIN && prob[i] <= PROB_MAX);

     // assign default probabilities if not provided
     double const p  = len < 1 ? 0.0     : prob[0];
     double const r  = len < 2 ? 1.0 - p : prob[1];
     double const h_ = len < 3 ? 1.0     : prob[2];
     double const k_ = len < 4 ? 0.0     : prob[3];

     // Norm and assign probabilities to the model
     m->p  = norm_to_rand_max(p);
     m->r  = norm_to_rand_max(r);
     m->h_ = norm_to_rand_max(h_);
     m->k_ = norm_to_rand_max(k_);

     m->good = true;
     m->drop = ge_drop;
     
     return m;
}

bool ge_drop(struct ge_model m[static 1]) {
     int const x = rand();
     if ((m->good && x < m->p)
         || (!m->good && x >= m->r)) {
          m->good = false;
          return rand() < m->h_;
     } else {
          m->good = true;
          return rand() < m->k_;
     }
}

struct netem_model* netem_init(struct netem_model* m,
			       size_t const len,
			       double const p[static len]) {
     if (!m) return m;
     
     enum netem_p { p13, p14, p23, p31, p32 };
     
     // No defaults implemented => current version requires all 4 netem_p
     assert(len >= 4);
     for (size_t i = 0; i < len; ++i)
	  assert(p[i] >= PROB_MIN && p[i] <= PROB_MAX);
     assert(p[p13] + p[p14] <= 1.0);
     assert(p[p31] + p[p32] <= 1.0);

     // Norm and assign probabilities to the model
     m->p[q1][p_stay] = norm_to_rand_max(1.0 - p[p13] - p[p14]);
     m->p[q1][p_keep_link_state] = norm_to_rand_max(p[p14]);
     
     m->p[q2][p_stay] = norm_to_rand_max(1.0 - p[p23]);
     m->p[q2][p_keep_link_state] = norm_to_rand_max(p[p23]);
     
     m->p[q3][p_stay] = norm_to_rand_max(1.0 - p[p31] - p[p32]);
     m->p[q3][p_keep_link_state] = norm_to_rand_max(p[p32]);

     m->p[q4][p_stay] = norm_to_rand_max(0.0);
     m->p[q4][p_keep_link_state] = norm_to_rand_max(1.0);
     
     m->state = q1;
     m->drop = netem_drop;
     
     return m;     
}

bool netem_drop(struct netem_model m[static 1]) {
     bool const drop12_keep34 = m->state < q3;
     int const x = rand();
     int const stay = m->p[m->state][p_stay];
     
     if (x < stay)		// stay in current state
	  return !drop12_keep34; // drop packet if in state q3 or q4

     if (x < stay + m->p[m->state][p_keep_link_state]) // change state, but stay in same link state
	  m->state ^= 3; 	// q1 <--> q4, q2 <--> q3
     else			// change state and link state (only relevant for q1, q3)
	  m->state ^= 2;	// q1 <--> q3

     return drop12_keep34;	// drop packet if old state was 1 or 2
}
