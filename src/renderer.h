#ifndef RENDERER_H
#define RENDERER_H

#include <SDL3/SDL.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __GNUC__
#define UNUSED __attribute__((__unused__))
#else
#define UNUSED
#endif

#ifdef ANVIL_USE_SDL_RENDERER
#define RECT_TYPE double
#else
#define RECT_TYPE int
#endif

#define FONT_FALLBACK_MAX 10
#define MAX_POLY_POINTS 0xFFFF
typedef struct RenFont RenFont;
typedef enum { FONT_HINTING_NONE, FONT_HINTING_SLIGHT, FONT_HINTING_FULL } ERenFontHinting;
typedef enum { FONT_ANTIALIASING_NONE, FONT_ANTIALIASING_GRAYSCALE, FONT_ANTIALIASING_SUBPIXEL } ERenFontAntialiasing;
typedef enum { FONT_STYLE_BOLD = 1, FONT_STYLE_ITALIC = 2, FONT_STYLE_UNDERLINE = 4, FONT_STYLE_SMOOTH = 8, FONT_STYLE_STRIKETHROUGH = 16 } ERenFontStyle;
typedef enum { FONT_FAMILY, FONT_SUBFAMILY, FONT_ID, FONT_FULLNAME, FONT_VERSION, FONT_PSNAME, FONT_TFAMILY, FONT_TSUBFAMILY, FONT_WWSFAMILY, FONT_WWSSUBFAMILY, FONT_SAMPLETEXT } EFontMetaTag;
typedef enum { POLY_CONTROL_CONIC = 0, POLY_CONTROL_CUBIC = 0b10, POLY_NORMAL = 0b01 } ERenBezierPointType;
typedef struct { uint8_t b, g, r, a; } RenColor;
typedef struct { int x, y; ERenBezierPointType tag; } RenPoint;
typedef struct { RECT_TYPE x, y, width, height; } RenRect;
typedef struct { double offset; } RenTab;
typedef struct { SDL_Surface *surface; float scale_x, scale_y; } RenSurface;
typedef struct { EFontMetaTag tag; char *value; size_t len; } FontMetaData;

typedef struct {
  uint64_t width_calls;
  uint64_t width_bytes;
  uint64_t width_chars;
  uint64_t width_shaped_runs;
  uint64_t width_unshaped_runs;
  uint64_t width_shape_probe_bytes;
  uint64_t width_hb_shapes;
  uint64_t width_shaped_cache_hits;
  uint64_t width_shaped_cache_misses;
  double width_hb_shape_ms;
  uint64_t render_calls;
  uint64_t render_bytes;
  uint64_t render_chars;
  uint64_t render_shaped_runs;
  uint64_t render_unshaped_runs;
  uint64_t render_shape_probe_bytes;
  uint64_t render_hb_shapes;
  uint64_t render_glyphs;
  uint64_t render_whitespace_chars;
  uint64_t render_chars_after_clip;
  uint64_t render_top_clip_breaks;
  double render_hb_shape_ms;
} RenTextFrameStats;

struct RenWindow;
typedef struct RenWindow RenWindow;

RenFont* ren_font_load(const char *filename, float size, ERenFontAntialiasing antialiasing, ERenFontHinting hinting, unsigned char style, bool ligatures);
RenFont* ren_font_copy(RenFont* font, float size, ERenFontAntialiasing antialiasing, ERenFontHinting hinting, int style, int ligatures);
const char* ren_font_get_path(RenFont *font);
void ren_font_free(RenFont *font);
int ren_font_get_metadata(const char *path, FontMetaData **data, int *count, bool *monospaced);
int ren_font_group_get_tab_size(RenFont **font);
int ren_font_group_get_height(RenFont **font);
float ren_font_group_get_size(RenFont **font);
void ren_font_group_set_size(RenFont **font, float size, float surface_scale);
#ifdef ANVIL_USE_SDL_RENDERER
void update_font_scale(RenWindow *window_renderer, RenFont **fonts);
#endif
void ren_font_group_set_tab_size(RenFont **font, int n);
double ren_font_group_get_width(RenFont **font, const char *text, size_t len, RenTab tab, int *x_offset);
double ren_draw_text(RenSurface *rs, RenFont **font, const char *text, size_t len, float x, float y, RenColor color, RenTab tab);
bool ren_draw_text_d3d11(SDL_Window *window, RenRect clip, RenFont **font, const char *text, size_t len, float x, float y, RenColor color, RenTab tab);
void ren_text_stats_begin_frame(void);
void ren_text_stats_end_frame(void);
const RenTextFrameStats *ren_text_get_last_frame_stats(void);

void ren_draw_rect(RenSurface *rs, RenRect rect, RenColor color, bool replace);

void ren_draw_canvas(RenSurface *rs, SDL_Surface *surface, int x, int y);

void ren_draw_pixels(RenSurface *rs, RenRect rect, const char* bytes, size_t len);

// function to draw polygons and curves
int ren_poly_cbox(RenPoint *points, int npoints, RenRect *cbox);
void ren_draw_poly(RenSurface *rs, RenPoint *points, unsigned short npoints, RenColor color);

int video_init(void);
int ren_init(void);
void ren_free(void);
RenWindow* ren_create(SDL_Window *win);
void ren_destroy(RenWindow* window_renderer);
void ren_resize_window(RenWindow *window_renderer);
void ren_set_clip_rect(RenSurface *rs, RenRect rect);
void ren_get_size(RenSurface *rs, int *x, int *y); /* Reports the size in points. */
size_t ren_get_window_list(RenWindow ***window_list_dest);
RenWindow* ren_find_window(SDL_Window *window);
RenWindow* ren_find_window_from_id(uint32_t id);
RenWindow* ren_get_target_window(void);
void ren_set_target_window(RenWindow *window);

#endif
