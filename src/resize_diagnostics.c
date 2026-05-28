#include "resize_diagnostics.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <SDL3/SDL.h>

#ifdef _WIN32
  #define WIN32_LEAN_AND_MEAN
  #include <windows.h>
#endif

typedef struct ResizeDiagState {
  bool initialized;
  bool enabled;
  bool flush_each_line;
  bool live_resize;
  FILE *file;
  uint64_t start_ns;
  uint64_t sequence;
  int lines_since_flush;
} ResizeDiagState;

static ResizeDiagState g_resize_diag;

static bool env_value_is_false(const char *value) {
  if (!value || !value[0]) return true;
  while (*value == ' ' || *value == '\t') value++;
  if (!value[0]) return true;
  if (value[0] == '0') return true;
  if (SDL_strcasecmp(value, "false") == 0) return true;
  if (SDL_strcasecmp(value, "no") == 0) return true;
  if (SDL_strcasecmp(value, "off") == 0) return true;
  return false;
}

static bool env_truthy(const char *name) {
  return !env_value_is_false(getenv(name));
}

static void csv_write_field(FILE *file, const char *value) {
  if (!value) value = "";
  fputc('"', file);
  for (const char *p = value; *p; p++) {
    if (*p == '"') fputc('"', file);
    fputc(*p, file);
  }
  fputc('"', file);
}

static const char *default_stats_path(char *buf, size_t buf_size) {
  const char *path = getenv("ANVIL_RESIZE_STATS_FILE");
  if (path && path[0]) return path;

#ifdef _WIN32
  DWORD len = GetTempPathA((DWORD)buf_size, buf);
  if (len > 0 && len < buf_size) {
    strncat(buf, "anvil_resize_stats.csv", buf_size - strlen(buf) - 1);
    return buf;
  }
#endif

  return "anvil_resize_stats.csv";
}

static void resize_diag_init(void) {
  if (g_resize_diag.initialized) return;
  g_resize_diag.initialized = true;
  if (!env_truthy("ANVIL_RESIZE_STATS") && !env_truthy("ANVIL_LIVE_RESIZE_STATS")) return;

  char path_buf[1024] = {0};
  const char *path = default_stats_path(path_buf, sizeof(path_buf));
  g_resize_diag.file = fopen(path, "wb");
  if (!g_resize_diag.file) return;

  g_resize_diag.enabled = true;
  g_resize_diag.flush_each_line = env_truthy("ANVIL_RESIZE_STATS_FLUSH") ||
                                  env_truthy("ANVIL_LIVE_RESIZE_STATS_FLUSH");
  g_resize_diag.start_ns = SDL_GetTicksNS();
  fprintf(g_resize_diag.file,
          "time_ms,seq,category,name,reason,window_id,live_resize,in_run_step,queue_depth,point_w,point_h,pixel_w,pixel_h,client_w,client_h,count_a,count_b,ms_a,ms_b,ms_c,detail\n");
  fflush(g_resize_diag.file);
}

bool anvil_resize_diag_enabled(void) {
  resize_diag_init();
  return g_resize_diag.enabled;
}

void anvil_resize_diag_set_live_resize(bool live_resize) {
  g_resize_diag.live_resize = live_resize;
}

bool anvil_resize_diag_live_resize(void) {
  return g_resize_diag.live_resize;
}

double anvil_resize_diag_ticks_to_ms(uint64_t start_ns, uint64_t end_ns) {
  if (end_ns < start_ns) return 0.0;
  return (double)(end_ns - start_ns) / 1000000.0;
}

const char *anvil_resize_diag_event_reason(uint32_t sdl_event_type) {
  switch (sdl_event_type) {
    case SDL_EVENT_WINDOW_RESIZED: return "sdl_resized";
    case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED: return "sdl_pixel_size";
    case SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED: return "sdl_scale";
    case SDL_EVENT_WINDOW_EXPOSED: return "sdl_exposed";
    case SDL_EVENT_WINDOW_FOCUS_GAINED: return "sdl_focus_gained";
    case SDL_EVENT_WINDOW_RESTORED: return "sdl_restored";
    default: return "sdl_other";
  }
}

void anvil_resize_diag_log(const AnvilResizeDiagEvent *event) {
  if (!event || !anvil_resize_diag_enabled() || !g_resize_diag.file) return;

  uint64_t now_ns = SDL_GetTicksNS();
  double t_ms = anvil_resize_diag_ticks_to_ms(g_resize_diag.start_ns, now_ns);
  fprintf(g_resize_diag.file,
          "%.3f,%llu,",
          t_ms,
          (unsigned long long)++g_resize_diag.sequence);
  csv_write_field(g_resize_diag.file, event->category);
  fputc(',', g_resize_diag.file);
  csv_write_field(g_resize_diag.file, event->name);
  fputc(',', g_resize_diag.file);
  csv_write_field(g_resize_diag.file, event->reason);
  fprintf(g_resize_diag.file,
          ",%u,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%.3f,%.3f,%.3f,",
          event->window_id,
          event->live_resize ? 1 : 0,
          event->in_run_step ? 1 : 0,
          event->queue_depth,
          event->point_w,
          event->point_h,
          event->pixel_w,
          event->pixel_h,
          event->client_w,
          event->client_h,
          event->count_a,
          event->count_b,
          event->ms_a,
          event->ms_b,
          event->ms_c);
  csv_write_field(g_resize_diag.file, event->detail);
  fputc('\n', g_resize_diag.file);

  if (g_resize_diag.flush_each_line || ++g_resize_diag.lines_since_flush >= 64) {
    fflush(g_resize_diag.file);
    g_resize_diag.lines_since_flush = 0;
  }
}
