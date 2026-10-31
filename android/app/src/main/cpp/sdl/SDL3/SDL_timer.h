/* The part of SDL's timer API that the shared C modules use. The Companion does not build SDL. */
#ifndef ANVIL_COMPANION_SDL_TIMER_H
#define ANVIL_COMPANION_SDL_TIMER_H

#include <stdint.h>
#include <time.h>

static inline uint64_t SDL_GetTicks(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (uint64_t)now.tv_sec * 1000u + (uint64_t)now.tv_nsec / 1000000u;
}

#endif
