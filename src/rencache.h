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
  size_t max_text_bytes;
  double draw_text_ms;
  double draw_text_width_ms;
  int display_packet_replays;
  int display_packet_commands_replayed;
  int display_packet_text_commands_replayed;
  int display_packet_rect_commands_replayed;
  size_t display_packet_source_bytes;
  size_t display_packet_frame_bytes_copied;
  double display_packet_replay_ms;
  int display_packet_frame_allocation_failures;
  bool rencache_frame_failed;
} RenCacheFrameStats;

typedef struct RenCache {
  uint8_t *command_buf;
  size_t command_buf_idx;
  size_t command_buf_size;
  unsigned cells_buf1[RENCACHE_CELLS_X * RENCACHE_CELLS_Y];
  unsigned cells_buf2[RENCACHE_CELLS_X * RENCACHE_CELLS_Y];
  unsigned *cells_prev;
  unsigned *cells;
  RenRect rect_buf[RENCACHE_CELLS_X * RENCACHE_CELLS_Y / 2];
  bool resize_issue;
  bool frame_failed;
  bool frame_active;
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
void  rencache_draw_rounded_rect(RenCache *rc, RenRect rect, float radius, RenColor color);
void  rencache_draw_rect_grid(RenCache *rc, float x, float y, float step_x, float w, float h, int count, RenColor color);
double rencache_draw_text(RenCache *rc, RenFont **font, const char *text, size_t len, double x, double y, RenColor color, RenTab tab);
double rencache_draw_text_known_bounds(RenCache *rc, RenFont **font, const char *text, size_t len, double x, double y, RenRect rect, RenColor color, RenTab tab);
double rencache_draw_text_known_bounds_captured(RenCache *rc, RenFont **font, const char *text, size_t len, double x, double y, RenRect rect, RenColor color, RenTab tab, int tab_size);
RenRect rencache_draw_poly(RenCache *rc, RenPoint *points, int npoints, RenColor color);
void  rencache_draw_canvas(RenCache *ren_cache, RenRect rect, RenCache *canvas);
void  rencache_draw_pixels(RenCache *ren_cache, RenRect rect, const char* bytes, size_t len);
void  rencache_invalidate(RenCache *rc);
void  rencache_begin_frame(RenCache *rc);
void  rencache_end_frame(RenCache *rc);
void  rencache_abandon_frame(RenCache *rc);
bool  rencache_frame_is_failed(const RenCache *rc);
bool  rencache_reserve_command_bytes(RenCache *rc, size_t bytes);
size_t rencache_text_command_storage_size(size_t text_len);
size_t rencache_rect_command_storage_size(void);
size_t rencache_rect_grid_command_storage_size(void);
RenRect rencache_rect_from_floats(double x, double y, double w, double h);
void rencache_record_display_packet_replay(
  RenCache *rc,
  size_t commands,
  size_t text_commands,
  size_t rect_commands,
  size_t source_bytes,
  size_t frame_bytes,
  uint64_t started
);
void rencache_test_fail_next_packet_reserve(void);
RenSurface rencache_get_surface(RenCache *rc);
void rencache_get_size(RenCache *rc, int *w, int *h);
void rencache_update_rects(RenCache *rc, RenRect *rects, int count);
const RenCacheFrameStats *rencache_get_last_frame_stats(void);


#endif
