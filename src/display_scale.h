#ifndef ANVIL_DISPLAY_SCALE_H
#define ANVIL_DISPLAY_SCALE_H

#include <SDL3/SDL.h>

static inline float anvil_display_scale(SDL_Window *window, float previous) {
#ifdef _WIN32
  /* Windows client coordinates are pixels. SDL's window scale also includes
   * a size ratio that can become 1/16 for an iconic window during lock/wake.
   * Use the monitor's DPI scale without that transient size ratio. */
  SDL_DisplayID display = SDL_GetDisplayForWindow(window);
  float scale = display ? SDL_GetDisplayContentScale(display) : 0;
#else
  float scale = SDL_GetWindowDisplayScale(window);
#endif
  if (scale >= 0.25f && scale <= 16.0f) return scale;
  return previous >= 0.25f && previous <= 16.0f ? previous : 1.0f;
}

#endif
