#include "loss-models.h"
#include <stdlib.h>             /* for rand() */

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
