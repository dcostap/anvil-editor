#ifndef ANVIL_D3D11_BACKEND_H
#define ANVIL_D3D11_BACKEND_H

#include <stdbool.h>
#include <stddef.h>
#include <SDL3/SDL.h>
#include "renderer.h"

#if defined(_WIN32) && defined(ANVIL_USE_SDL_RENDERER)
/* Runtime renderer selection is controlled by ANVIL_RENDERER.
   Default/unset: D3D11 command renderer. Set ANVIL_RENDERER=software
   or ANVIL_RENDERER=sdl to force the SDL/software fallback. */
bool anvil_d3d11_enabled(void);
bool anvil_d3d11_is_present_paced(void);
double anvil_d3d11_last_present_ms(void);
int anvil_d3d11_last_sync_interval(void);
const char *anvil_d3d11_last_frame_path(void);
bool anvil_d3d11_present(SDL_Window *window, SDL_Surface *surface,
                          float scale_x, float scale_y,
                          RenRect *rects, int rect_count);

/* Retained-mode D3D11 command renderer, modeled after RAD's low-level
 * backend. The SDL surface upload bridge remains available as a fallback. */
bool anvil_d3d11_begin_frame(SDL_Window *window, int width, int height, RenColor clear_color);
bool anvil_d3d11_push_rect(SDL_Window *window, RenRect rect, RenRect clip, RenColor color);
bool anvil_d3d11_push_texture(SDL_Window *window, SDL_Surface *surface,
                               RenRect src_px, RenRect dst_px, RenRect clip_px,
                               RenColor color, int mode);
bool anvil_d3d11_push_pixels(SDL_Window *window, const char *bytes, size_t len,
                              int width, int height, int pitch,
                              RenRect dst_px, RenRect clip_px);
bool anvil_d3d11_end_frame(SDL_Window *window);
void anvil_d3d11_abort_frame(SDL_Window *window);
void anvil_d3d11_abort_frame_reason(SDL_Window *window, const char *reason);

void anvil_d3d11_forget_window(SDL_Window *window);
void anvil_d3d11_forget_surface(SDL_Surface *surface);
void anvil_d3d11_shutdown(void);
#else
static inline bool anvil_d3d11_enabled(void) { return false; }
static inline bool anvil_d3d11_is_present_paced(void) { return false; }
static inline double anvil_d3d11_last_present_ms(void) { return 0.0; }
static inline int anvil_d3d11_last_sync_interval(void) { return 0; }
static inline const char *anvil_d3d11_last_frame_path(void) { return "none"; }
static inline bool anvil_d3d11_present(SDL_Window *window, SDL_Surface *surface,
                                        float scale_x, float scale_y,
                                        RenRect *rects, int rect_count) {
  (void)window; (void)surface; (void)scale_x; (void)scale_y; (void)rects; (void)rect_count;
  return false;
}
static inline bool anvil_d3d11_begin_frame(SDL_Window *window, int width, int height, RenColor clear_color) {
  (void)window; (void)width; (void)height; (void)clear_color;
  return false;
}
static inline bool anvil_d3d11_push_rect(SDL_Window *window, RenRect rect, RenRect clip, RenColor color) {
  (void)window; (void)rect; (void)clip; (void)color;
  return false;
}
static inline bool anvil_d3d11_push_texture(SDL_Window *window, SDL_Surface *surface,
                                             RenRect src_px, RenRect dst_px, RenRect clip_px,
                                             RenColor color, int mode) {
  (void)window; (void)surface; (void)src_px; (void)dst_px; (void)clip_px; (void)color; (void)mode;
  return false;
}
static inline bool anvil_d3d11_push_pixels(SDL_Window *window, const char *bytes, size_t len,
                                           int width, int height, int pitch,
                                           RenRect dst_px, RenRect clip_px) {
  (void)window; (void)bytes; (void)len; (void)width; (void)height; (void)pitch; (void)dst_px; (void)clip_px;
  return false;
}
static inline bool anvil_d3d11_end_frame(SDL_Window *window) {
  (void)window;
  return false;
}
static inline void anvil_d3d11_abort_frame(SDL_Window *window) { (void)window; }
static inline void anvil_d3d11_abort_frame_reason(SDL_Window *window, const char *reason) { (void)window; (void)reason; }
static inline void anvil_d3d11_forget_window(SDL_Window *window) { (void)window; }
static inline void anvil_d3d11_forget_surface(SDL_Surface *surface) { (void)surface; }
static inline void anvil_d3d11_shutdown(void) {}
#endif

#endif
