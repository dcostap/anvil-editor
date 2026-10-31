/* The part of SDL's atomic API that the shared C modules use. The Companion does not build SDL. */
#ifndef ANVIL_COMPANION_SDL_ATOMIC_H
#define ANVIL_COMPANION_SDL_ATOMIC_H

#include <stdatomic.h>

typedef struct SDL_AtomicInt {
  atomic_int value;
} SDL_AtomicInt;

/* Returns the value before the change, as SDL does. */
static inline int SDL_AddAtomicInt(SDL_AtomicInt *a, int v) {
  return atomic_fetch_add(&a->value, v);
}

static inline int SDL_SetAtomicInt(SDL_AtomicInt *a, int v) {
  return atomic_exchange(&a->value, v);
}

#endif
