#include <SDL3/SDL.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>

/* Fake the platform boundary: Windows can report a tiny iconic client size
 * while the monitor's content scale stays unchanged. */
static float window_scale, content_scale;
static SDL_DisplayID display_id;
static inline float window_display_scale(SDL_Window *window) { (void)window; return window_scale; }
static inline SDL_DisplayID display_for_window(SDL_Window *window) { (void)window; return display_id; }
static inline float display_content_scale(SDL_DisplayID display) { (void)display; return content_scale; }
#define SDL_GetWindowDisplayScale window_display_scale
#define SDL_GetDisplayForWindow display_for_window
#define SDL_GetDisplayContentScale display_content_scale
#include "display_scale.h"

int main(void) {
  display_id = 1;
  content_scale = 1.5f;
  window_scale = 1.5f;
  assert(anvil_display_scale(NULL, 1) == 1.5f);
#ifdef _WIN32
  window_scale = 1.0f / 16;
  assert(anvil_display_scale(NULL, 1.5f) == 1.5f);
  content_scale = 2;
  assert(anvil_display_scale(NULL, 1.5f) == 2);
  display_id = 0;
  assert(anvil_display_scale(NULL, 2) == 2);
  display_id = 1;
#else
  content_scale = 1;
  window_scale = 2;
  assert(anvil_display_scale(NULL, 1) == 2);
#endif
  const float invalid[] = {0, -1, 1.0f / 16, INFINITY, NAN};
  for (size_t i = 0; i < SDL_arraysize(invalid); ++i) {
    content_scale = window_scale = invalid[i];
    assert(anvil_display_scale(NULL, 2) == 2);
    assert(anvil_display_scale(NULL, 0) == 1);
  }
  puts("display scale tests passed");
  return 0;
}
