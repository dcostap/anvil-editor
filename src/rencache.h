#ifndef RENCACHE_H
#define RENCACHE_H

#include <stdbool.h>
#include "renderer.h"

/* These values represent the maximum size that can be tracked by rencache
   7680x4320 = 8k resolution, we use a common divisor for the size of regions
   that will be dirty checked.
*/
#define RENCACHE_CELL_SIZE 60 /* common divisor of width and height */
/* 128 X cells */
#define RENCACHE_CELLS_X (7680 / RENCACHE_CELL_SIZE)
/* 72 Y cells with additional 1 cell padding to prevent hash crash */
#define RENCACHE_CELLS_Y ((4320 + RENCACHE_CELL_SIZE) / RENCACHE_CELL_SIZE)

typedef struct {
  int commands;
  int set_clip_commands;
  int rect_commands;
  int text_commands;
  int canvas_commands;
  int pixels_commands;
  int poly_commands;
  size_t command_bytes;
  size_t text_bytes;
  double draw_text_ms;
  double draw_text_width_ms;
} RenCacheFrameStats;

typedef struct {
  uint8_t *command_buf;
  size_t command_buf_idx;
  size_t command_buf_size;
  unsigned cells_buf1[RENCACHE_CELLS_X * RENCACHE_CELLS_Y];
  unsigned cells_buf2[RENCACHE_CELLS_X * RENCACHE_CELLS_Y];
  unsigned *cells_prev;
  unsigned *cells;
  RenRect rect_buf[RENCACHE_CELLS_X * RENCACHE_CELLS_Y / 2];
  bool resize_issue;
  RenRect screen_rect;
  RenRect last_clip_rect;
  SDL_Window *window;   /* The cache can be used for both a window or surface */
  bool window_shown;
  RenSurface rensurface;
#ifdef ANVIL_USE_SDL_RENDERER
  int window_width;
  int window_height;
  int window_pixel_width;
  int window_pixel_height;
  SDL_Renderer *renderer;
  SDL_Texture *texture;
#endif
} RenCache;

void rencache_init(RenCache *rc);
void rencache_uninit(RenCache *rc);
void  rencache_show_debug(bool enable);
void  rencache_set_clip_rect(RenCache *rc, RenRect rect);
void  rencache_draw_rect(RenCache *rc, RenRect rect, RenColor color, bool replace);
double rencache_draw_text(RenCache *rc, RenFont **font, const char *text, size_t len, double x, double y, RenColor color, RenTab tab);
RenRect rencache_draw_poly(RenCache *rc, RenPoint *points, int npoints, RenColor color);
void  rencache_draw_canvas(RenCache *ren_cache, RenRect rect, RenCache *canvas);
void  rencache_draw_pixels(RenCache *ren_cache, RenRect rect, const char* bytes, size_t len);
void  rencache_invalidate(RenCache *rc);
void  rencache_begin_frame(RenCache *rc);
void  rencache_end_frame(RenCache *rc);
RenSurface rencache_get_surface(RenCache *rc);
void rencache_get_size(RenCache *rc, int *w, int *h);
void rencache_update_rects(RenCache *rc, RenRect *rects, int count);
const RenCacheFrameStats *rencache_get_last_frame_stats(void);


#endif
