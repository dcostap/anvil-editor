#include <assert.h>
#include "renwindow.h"
#include "win32_frame.h"
#include "d3d11_backend.h"
#include "resize_diagnostics.h"
#include "system_events.h"

#ifdef ANVIL_USE_SDL_RENDERER
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#endif

#ifdef ANVIL_USE_SDL_RENDERER
static void query_surface_scale(RenWindow *ren, float* scale_x, float* scale_y) {
  int w_pixels, h_pixels;
  int w_points, h_points;
  SDL_GetWindowSizeInPixels(ren->cache.window, &w_pixels, &h_pixels);
  SDL_GetWindowSize(ren->cache.window, &w_points, &h_points);
  float scaleX = (float) w_pixels / (float) w_points;
  float scaleY = (float) h_pixels / (float) h_points;
  if(scale_x)
    *scale_x = round(scaleX * 100) / 100;
  if(scale_y)
    *scale_y = round(scaleY * 100) / 100;
}

static void setup_renderer(RenWindow *ren, int w, int h) {
  /* Note that w and h here should always be in pixels and obtained from
     a call to SDL_GetWindowSizeInPixels(). */
  query_surface_scale(ren, &ren->cache.rensurface.scale_x, &ren->cache.rensurface.scale_y);

  /* When Anvil's custom D3D11 path is enabled, do not create SDL_Renderer.
     SDL's renderer owns its own swapchain for this HWND; creating our custom
     swapchain on the same window as SDL's swapchain causes broken/flickering
     presentation. The SDL renderer is only the fallback path. */
  if (anvil_d3d11_enabled()) {
    if (ren->cache.texture) {
      SDL_DestroyTexture(ren->cache.texture);
      ren->cache.texture = NULL;
    }
    if (ren->cache.renderer) {
      SDL_DestroyRenderer(ren->cache.renderer);
      ren->cache.renderer = NULL;
    }
    return;
  }

  if (!ren->cache.renderer) {
    ren->cache.renderer = SDL_CreateRenderer(ren->cache.window, NULL);
    if (ren->cache.renderer) {
      SDL_SetRenderVSync(ren->cache.renderer, 1);
    }
  }
  if (ren->cache.texture) {
    SDL_DestroyTexture(ren->cache.texture);
  }
  ren->cache.texture = SDL_CreateTexture(
    ren->cache.renderer, ren->cache.rensurface.surface->format,
    SDL_TEXTUREACCESS_STREAMING, w, h
  );
}
#endif


static void init_surface(RenWindow *ren) {
  ren->scale_x = ren->scale_y = 1;
#ifdef ANVIL_USE_SDL_RENDERER
  uint64_t total_start_ns = SDL_GetTicksNS();
  uint64_t destroy_start_ns = 0, destroy_end_ns = 0;
  uint64_t query_start_ns = 0, query_end_ns = 0;
  uint64_t create_start_ns = 0, create_end_ns = 0;
  uint64_t setup_start_ns = 0, setup_end_ns = 0;
  int old_w = ren->cache.rensurface.surface ? ren->cache.rensurface.surface->w : 0;
  int old_h = ren->cache.rensurface.surface ? ren->cache.rensurface.surface->h : 0;

  if (ren->cache.rensurface.surface) {
    destroy_start_ns = SDL_GetTicksNS();
    anvil_d3d11_forget_surface(ren->cache.rensurface.surface);
    SDL_DestroySurface(ren->cache.rensurface.surface);
    destroy_end_ns = SDL_GetTicksNS();
  }
  int w, h;
  query_start_ns = SDL_GetTicksNS();
  SDL_GetWindowSizeInPixels(ren->cache.window, &w, &h);
  SDL_PixelFormat format = SDL_GetWindowPixelFormat(ren->cache.window);
  query_end_ns = SDL_GetTicksNS();
  create_start_ns = SDL_GetTicksNS();
  ren->cache.rensurface.surface = SDL_CreateSurface(
    w, h, format == SDL_PIXELFORMAT_UNKNOWN ? SDL_PIXELFORMAT_BGRA32 : format
  );
  create_end_ns = SDL_GetTicksNS();
  if (!ren->cache.rensurface.surface) {
    fprintf(stderr, "Error creating surface: %s", SDL_GetError());
    exit(1);
  }
  setup_start_ns = SDL_GetTicksNS();
  setup_renderer(ren, w, h);
  setup_end_ns = SDL_GetTicksNS();

  anvil_resize_diag_log(&(AnvilResizeDiagEvent){
    .category = "surface",
    .name = "init_surface",
    .window_id = SDL_GetWindowID(ren->cache.window),
    .live_resize = anvil_resize_diag_live_resize(),
    .queue_depth = system_pending_event_count(),
    .pixel_w = w,
    .pixel_h = h,
    .count_a = old_w,
    .count_b = old_h,
    .ms_a = anvil_resize_diag_ticks_to_ms(total_start_ns, SDL_GetTicksNS()),
    .ms_b = anvil_resize_diag_ticks_to_ms(create_start_ns, create_end_ns),
    .ms_c = anvil_resize_diag_ticks_to_ms(setup_start_ns, setup_end_ns),
    .detail = anvil_d3d11_enabled() ? "d3d11 destroy_ms/query_ms/create_ms/setup_ms" : "software destroy_ms/query_ms/create_ms/setup_ms"
  });
  anvil_resize_diag_log(&(AnvilResizeDiagEvent){
    .category = "surface",
    .name = "init_surface_parts",
    .window_id = SDL_GetWindowID(ren->cache.window),
    .live_resize = anvil_resize_diag_live_resize(),
    .queue_depth = system_pending_event_count(),
    .pixel_w = w,
    .pixel_h = h,
    .ms_a = anvil_resize_diag_ticks_to_ms(destroy_start_ns, destroy_end_ns),
    .ms_b = anvil_resize_diag_ticks_to_ms(query_start_ns, query_end_ns),
    .ms_c = anvil_resize_diag_ticks_to_ms(create_start_ns, create_end_ns)
  });
#endif
}


RenWindow* renwin_create(SDL_Window *win) {
  assert(win);
  RenWindow* window_renderer = SDL_calloc(1, sizeof(RenWindow));

  rencache_init(&window_renderer->cache);
  window_renderer->cache.window = win;
  init_surface(window_renderer);
  renwin_clip_to_surface(window_renderer);

  return window_renderer;
}


void renwin_clip_to_surface(RenWindow *ren) {
  SDL_SetSurfaceClipRect(rencache_get_surface(&ren->cache).surface, NULL);
}


static RenRect scaled_rect(const RenRect rect, const RenSurface *rs) {
#ifdef ANVIL_USE_SDL_RENDERER
  float scale_x = rs->scale_x;
  float scale_y = rs->scale_y;
#else
  int scale_x = 1;
  int scale_y = 1;
#endif
  return (RenRect) {
    rect.x * scale_x,
    rect.y * scale_y,
    rect.width * scale_x,
    rect.height * scale_y
  };
}

void renwin_set_clip_rect(RenWindow *ren, RenRect rect) {
  RenSurface rs = rencache_get_surface(&ren->cache);
  RenRect sr = scaled_rect(rect, &rs);
  SDL_SetSurfaceClipRect(rs.surface, &(SDL_Rect){.x = sr.x, .y = sr.y, .w = sr.width, .h = sr.height});
}


void renwin_resize_surface(UNUSED RenWindow *ren) {
#ifdef ANVIL_USE_SDL_RENDERER
  uint64_t start_ns = SDL_GetTicksNS();
  int new_w, new_h;
  float new_scale;
  int old_w = ren->cache.rensurface.surface ? ren->cache.rensurface.surface->w : 0;
  int old_h = ren->cache.rensurface.surface ? ren->cache.rensurface.surface->h : 0;
  float old_scale = ren->cache.rensurface.scale_x;
  SDL_GetWindowSizeInPixels(ren->cache.window, &new_w, &new_h);
  query_surface_scale(ren, &new_scale, NULL);
  bool recreated = false;
  /* Note that (w, h) may differ from (new_w, new_h) on retina displays. */
  if (new_scale != ren->cache.rensurface.scale_x ||
      new_w != ren->cache.rensurface.surface->w ||
      new_h != ren->cache.rensurface.surface->h) {
    recreated = true;
    init_surface(ren);
    renwin_clip_to_surface(ren);
  }
  anvil_resize_diag_log(&(AnvilResizeDiagEvent){
    .category = "surface",
    .name = "resize_surface",
    .window_id = SDL_GetWindowID(ren->cache.window),
    .live_resize = anvil_resize_diag_live_resize(),
    .queue_depth = system_pending_event_count(),
    .pixel_w = new_w,
    .pixel_h = new_h,
    .count_a = recreated ? 1 : 0,
    .count_b = anvil_d3d11_enabled() ? 1 : 0,
    .ms_a = anvil_resize_diag_ticks_to_ms(start_ns, SDL_GetTicksNS()),
    .ms_b = old_scale,
    .ms_c = new_scale,
    .detail = recreated ? "recreated" : "same_size"
  });
  (void)old_w;
  (void)old_h;
#endif
}

void renwin_update_scale(RenWindow *ren) {
#ifndef ANVIL_USE_SDL_RENDERER
  SDL_Surface *surface = SDL_GetWindowSurface(ren->cache.window);
  int window_w = surface->w, window_h = surface->h;
  SDL_GetWindowSize(ren->cache.window, &window_w, &window_h);
  ren->scale_x = (float)surface->w / window_w;
  ren->scale_y = (float)surface->h / window_h;
#endif
}

void renwin_show_window(RenWindow *ren) {
  SDL_ShowWindow(ren->cache.window);
}

void renwin_free(RenWindow *ren) {
  win32_frame_destroy(ren);
  anvil_d3d11_forget_window(ren->cache.window);
#ifdef ANVIL_USE_SDL_RENDERER
  SDL_DestroyTexture(ren->cache.texture);
  SDL_DestroyRenderer(ren->cache.renderer);
  anvil_d3d11_forget_surface(ren->cache.rensurface.surface);
  SDL_DestroySurface(ren->cache.rensurface.surface);
#endif
  SDL_DestroyWindow(ren->cache.window);
  ren->cache.window = NULL;
  rencache_uninit(&ren->cache);
  SDL_free(ren);
}
