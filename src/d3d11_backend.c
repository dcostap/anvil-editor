#if defined(_WIN32) && defined(ANVIL_USE_SDL_RENDERER)

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dwmapi.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi1_2.h>
#include <stdbool.h>
#include <stdint.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "d3d11_backend.h"
#include "resize_diagnostics.h"

#ifndef SAFE_RELEASE
#define SAFE_RELEASE(p) do { if (p) { (p)->lpVtbl->Release(p); (p) = NULL; } } while (0)
#endif

typedef struct D3D11QuadInstance {
  float x0, y0, x1, y1;
  float u0, v0, u1, v1;
  float r, g, b, a;
  float mode, pad0, pad1, pad2;
} D3D11QuadInstance;

typedef struct D3D11QuadConstants {
  float width;
  float height;
  float pad0;
  float pad1;
} D3D11QuadConstants;

typedef struct D3D11QuadBatch {
  ID3D11ShaderResourceView *srv;
  int start;
  int count;
  bool has_texture_dependent;
} D3D11QuadBatch;

typedef struct D3D11CachedTexture D3D11CachedTexture;
struct D3D11CachedTexture {
  D3D11CachedTexture *next;
  SDL_Surface *surface;
  ID3D11Texture2D *texture;
  ID3D11ShaderResourceView *srv;
  int width;
  int height;
  SDL_PixelFormat format;
  int mode;
  uint64_t last_update_frame;
  uint64_t last_used_frame;
};

typedef struct D3D11Window D3D11Window;
struct D3D11Window {
  D3D11Window *next;
  SDL_Window *window;
  HWND hwnd;
  IDXGISwapChain1 *swapchain;
  ID3D11Texture2D *backbuffer;
  ID3D11RenderTargetView *rtv;
  int width;
  int height;
  int buffer_count;
  DXGI_SWAP_EFFECT swap_effect;
};

typedef struct D3D11FrameStats {
  const char *path;
  int width;
  int height;
  int rect_pushes;
  int rect_flushes;
  int rect_draws;
  int rect_vertices;
  int texture_quads;
  int texture_draws;
  int texture_batch_breaks;
  int quad_batches;
  int unique_batch_srvs;
  int repeated_batch_srvs;
  int pixel_quads;
  int draw_calls;
  int quad_draws;
  int quad_instances;
  int quad_vertices;
  int maps;
  int texture_uploads;
  size_t texture_upload_bytes;
  int texture_recreates;
  int texture_prunes;
  double present_ms;
  double dwm_flush_ms;
  bool live_resize;
  bool resize_done;
  int resize_old_w;
  int resize_old_h;
  int resize_new_w;
  int resize_new_h;
  double resize_release_ms;
  double resize_buffers_ms;
  double resize_get_buffer_ms;
  double resize_create_rtv_ms;
  double resize_flush_ms;
  double clear_state_ms;
  double target_refresh_hz;
  int sync_interval;
  int buffer_count;
  const char *swap_effect;
  HRESULT resize_hr;
  const char *fail_reason;
  LARGE_INTEGER start_counter;
  double glyph_push_ms;
  double flush_quads_ms;
} D3D11FrameStats;

typedef struct D3D11Stats {
  bool initialized;
  bool enabled;
  bool active;
  FILE *file;
  LARGE_INTEGER freq;
  uint64_t frame_index;
  int lines_since_flush;
  D3D11FrameStats frame;
} D3D11Stats;

typedef struct D3D11State {
  bool attempted_init;
  bool available;
  bool device_is_warp;
  D3D_FEATURE_LEVEL feature_level;
  char adapter_name[128];
  ID3D11Device *device;
  ID3D11DeviceContext *context;
  IDXGIFactory2 *factory;
  ID3D11BlendState *blend;
  ID3D11RasterizerState *raster;
  SDL_Window *active_window;
  ID3D11VertexShader *quad_vs;
  ID3D11PixelShader *quad_ps;
  ID3D11InputLayout *quad_layout;
  ID3D11Buffer *quad_vbuf;
  ID3D11Buffer *quad_cbuf;
  ID3D11SamplerState *quad_sampler;
  D3D11QuadInstance *quad_instances;
  int quad_instance_count;
  int quad_instance_capacity;
  int quad_instance_buffer_capacity;
  D3D11QuadBatch *quad_batches;
  int quad_batch_count;
  int quad_batch_capacity;
  ID3D11Texture2D *white_texture;
  ID3D11ShaderResourceView *white_srv;
  ID3D11Texture2D *upload_texture;
  ID3D11ShaderResourceView *upload_srv;
  int upload_width;
  int upload_height;
  uint8_t *texture_upload_scratch;
  size_t texture_upload_scratch_capacity;
  D3D11CachedTexture *textures;
  uint64_t frame_index;
  D3D11Window *windows;
  D3D11Stats stats;
  double last_present_ms;
  int last_sync_interval;
  const char *last_frame_path;
} D3D11State;

static D3D11State g_d3d11;

static char d3d11_ascii_lower(char c) {
  return (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : c;
}

static bool d3d11_ascii_equals_ci(const char *a, const char *b) {
  if (!a || !b) return false;
  while (*a == ' ' || *a == '\t') a++;
  while (*b) {
    if (d3d11_ascii_lower(*a++) != d3d11_ascii_lower(*b++)) return false;
  }
  while (*a == ' ' || *a == '\t') a++;
  return *a == 0;
}

static bool d3d11_env_value_is_false(const char *value) {
  if (!value || !value[0]) return true;
  while (*value == ' ' || *value == '\t') value++;
  if (!value[0]) return true;
  return value[0] == '0' ||
         d3d11_ascii_equals_ci(value, "false") ||
         d3d11_ascii_equals_ci(value, "no") ||
         d3d11_ascii_equals_ci(value, "off");
}

static bool d3d11_renderer_value_is_software(const char *value) {
  if (d3d11_env_value_is_false(value)) return true;
  return d3d11_ascii_equals_ci(value, "software") ||
         d3d11_ascii_equals_ci(value, "soft") ||
         d3d11_ascii_equals_ci(value, "sdl") ||
         d3d11_ascii_equals_ci(value, "cpu");
}

static bool d3d11_env_truthy(const char *name) {
  return !d3d11_env_value_is_false(getenv(name));
}

static bool d3d11_should_dwm_flush(void) {
  return d3d11_env_truthy("ANVIL_D3D11_DWM_FLUSH");
}

static bool d3d11_should_clear_state_after_present(void) {
  const char *value = getenv("ANVIL_D3D11_CLEAR_STATE_AFTER_PRESENT");
  return !value || !value[0] || !d3d11_env_value_is_false(value);
}

static bool d3d11_should_resize_flush(void) {
  return d3d11_env_truthy("ANVIL_D3D11_RESIZE_FLUSH");
}

static bool d3d11_should_infer_swapchain_size(void) {
  return d3d11_env_truthy("ANVIL_D3D11_INFER_SWAPCHAIN_SIZE");
}

static bool d3d11_should_present_zero_live_resize(void) {
  const char *value = getenv("ANVIL_D3D11_PRESENT0_LIVE_RESIZE");
  return !value || !value[0] || !d3d11_env_value_is_false(value);
}

static UINT d3d11_present_sync_interval(void) {
  const char *value = getenv("ANVIL_D3D11_PRESENT_SYNC_INTERVAL");
  if (!value || !value[0]) return 1;
  int n = atoi(value);
  return n <= 0 ? 0u : 1u;
}

static UINT d3d11_max_frame_latency(void) {
  const char *value = getenv("ANVIL_D3D11_MAX_FRAME_LATENCY");
  int n = value && value[0] ? atoi(value) : 2;
  if (n < 1) n = 1;
  if (n > 16) n = 16;
  return (UINT)n;
}

static UINT d3d11_swapchain_buffer_count(void) {
  const char *value = getenv("ANVIL_D3D11_BUFFER_COUNT");
  int n = value && value[0] ? atoi(value) : 2;
  if (n < 2) n = 2;
  if (n > 3) n = 3;
  return (UINT)n;
}

static bool d3d11_should_use_flip_sequential(void) {
  return d3d11_env_truthy("ANVIL_D3D11_FLIP_SEQUENTIAL");
}

static bool d3d11_should_use_legacy_discard(void) {
  return d3d11_env_truthy("ANVIL_D3D11_LEGACY_DISCARD");
}

static bool d3d11_should_flush_stats_each_frame(void) {
  return d3d11_env_truthy("ANVIL_D3D11_STATS_FLUSH") ||
         d3d11_env_truthy("ANVIL_D3D11_STATS_FLUSH_EVERY_FRAME");
}

static void d3d11_sanitize_csv_field(char *s) {
  if (!s) return;
  for (; *s; s++) {
    if (*s == ',' || *s == '\n' || *s == '\r') *s = ' ';
  }
}

static const char *d3d11_feature_level_string(D3D_FEATURE_LEVEL level) {
  switch (level) {
    case D3D_FEATURE_LEVEL_11_1: return "11_1";
    case D3D_FEATURE_LEVEL_11_0: return "11_0";
    case D3D_FEATURE_LEVEL_10_1: return "10_1";
    case D3D_FEATURE_LEVEL_10_0: return "10_0";
    default: return "unknown";
  }
}

static double d3d11_ms_between(LARGE_INTEGER a, LARGE_INTEGER b) {
  if (g_d3d11.stats.freq.QuadPart == 0) {
    QueryPerformanceFrequency(&g_d3d11.stats.freq);
  }
  if (g_d3d11.stats.freq.QuadPart == 0) return 0.0;
  return ((double)(b.QuadPart - a.QuadPart) * 1000.0) / (double)g_d3d11.stats.freq.QuadPart;
}

static const char *d3d11_swap_effect_string(DXGI_SWAP_EFFECT effect) {
  switch (effect) {
    case DXGI_SWAP_EFFECT_DISCARD: return "discard";
    case DXGI_SWAP_EFFECT_SEQUENTIAL: return "sequential";
    case DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL: return "flip_sequential";
    case DXGI_SWAP_EFFECT_FLIP_DISCARD: return "flip_discard";
    default: return "unknown";
  }
}

static double d3d11_window_refresh_rate(SDL_Window *window) {
  if (!window) return 0.0;
  SDL_DisplayID display = SDL_GetDisplayForWindow(window);
  if (!display) return 0.0;
  const SDL_DisplayMode *mode = SDL_GetCurrentDisplayMode(display);
  if (mode && mode->refresh_rate > 0) return mode->refresh_rate;
  mode = SDL_GetDesktopDisplayMode(display);
  if (mode && mode->refresh_rate > 0) return mode->refresh_rate;
  return 0.0;
}

static int d3d11_cached_texture_count(void) {
  int count = 0;
  for (D3D11CachedTexture *t = g_d3d11.textures; t; t = t->next) count++;
  return count;
}

static void d3d11_stats_init(void) {
  if (g_d3d11.stats.initialized) return;
  g_d3d11.stats.initialized = true;
  if (!d3d11_env_truthy("ANVIL_D3D11_STATS")) return;

  QueryPerformanceFrequency(&g_d3d11.stats.freq);

  const char *path = getenv("ANVIL_D3D11_STATS_FILE");
  char temp_path[MAX_PATH];
  if (!path || !path[0]) {
    DWORD len = GetTempPathA((DWORD)sizeof(temp_path), temp_path);
    if (len > 0 && len < sizeof(temp_path)) {
      strncat(temp_path, "anvil_d3d11_stats.csv", sizeof(temp_path) - strlen(temp_path) - 1);
      path = temp_path;
    } else {
      path = "anvil_d3d11_stats.csv";
    }
  }

  g_d3d11.stats.file = fopen(path, "wb");
  if (!g_d3d11.stats.file) return;
  g_d3d11.stats.enabled = true;
  fprintf(g_d3d11.stats.file,
          "frame,path,success,width,height,device,adapter,feature_level,cpu_ms,present_ms,dwm_flush_ms,live_resize,resize_done,resize_old_w,resize_old_h,resize_new_w,resize_new_h,resize_release_ms,resize_buffers_ms,resize_get_buffer_ms,resize_create_rtv_ms,resize_flush_ms,clear_state_ms,target_refresh_hz,sync_interval,buffer_count,swap_effect,resize_hr,draw_calls,quad_draws,quad_instances,quad_vertices,rect_pushes,rect_flushes,rect_draws,rect_vertices,texture_quads,texture_draws,texture_batch_breaks,quad_batches,unique_batch_srvs,repeated_batch_srvs,pixel_quads,maps,texture_uploads,texture_upload_bytes,texture_recreates,texture_prunes,texture_cache_entries,hr,fail_reason\n");
  fflush(g_d3d11.stats.file);
}

static void d3d11_stats_begin(const char *path, SDL_Window *window, D3D11Window *d3d_window, int width, int height) {
  g_d3d11.last_frame_path = path;
  d3d11_stats_init();
  memset(&g_d3d11.stats.frame, 0, sizeof(g_d3d11.stats.frame));
  g_d3d11.stats.active = g_d3d11.stats.enabled;
  g_d3d11.stats.frame.path = path;
  g_d3d11.stats.frame.width = width;
  g_d3d11.stats.frame.height = height;
  g_d3d11.stats.frame.live_resize = anvil_resize_diag_live_resize();
  g_d3d11.stats.frame.target_refresh_hz = d3d11_window_refresh_rate(window);
  g_d3d11.stats.frame.sync_interval = 1;
  g_d3d11.stats.frame.resize_hr = S_OK;
  if (d3d_window) {
    g_d3d11.stats.frame.buffer_count = d3d_window->buffer_count;
    g_d3d11.stats.frame.swap_effect = d3d11_swap_effect_string(d3d_window->swap_effect);
  }
  QueryPerformanceCounter(&g_d3d11.stats.frame.start_counter);
}

static void d3d11_stats_end(bool success, HRESULT hr) {
  if (!g_d3d11.stats.enabled || !g_d3d11.stats.active || !g_d3d11.stats.file) return;
  LARGE_INTEGER end_counter;
  QueryPerformanceCounter(&end_counter);
  D3D11FrameStats *s = &g_d3d11.stats.frame;
  double cpu_ms = d3d11_ms_between(s->start_counter, end_counter);
  fprintf(g_d3d11.stats.file,
          "%llu,%s,%d,%d,%d,%s,%s,%s,%.3f,%.3f,%.3f,%d,%d,%d,%d,%d,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%d,%s,0x%08lx,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%llu,%d,%d,%d,0x%08lx,%s\n",
          (unsigned long long)++g_d3d11.stats.frame_index,
          s->path ? s->path : "unknown",
          success ? 1 : 0,
          s->width,
          s->height,
          g_d3d11.device_is_warp ? "warp" : "hardware",
          g_d3d11.adapter_name[0] ? g_d3d11.adapter_name : "unknown",
          d3d11_feature_level_string(g_d3d11.feature_level),
          cpu_ms,
          s->present_ms,
          s->dwm_flush_ms,
          s->live_resize ? 1 : 0,
          s->resize_done ? 1 : 0,
          s->resize_old_w,
          s->resize_old_h,
          s->resize_new_w,
          s->resize_new_h,
          s->resize_release_ms,
          s->resize_buffers_ms,
          s->resize_get_buffer_ms,
          s->resize_create_rtv_ms,
          s->resize_flush_ms,
          s->clear_state_ms,
          s->target_refresh_hz,
          s->sync_interval,
          s->buffer_count,
          s->swap_effect ? s->swap_effect : "unknown",
          (unsigned long)s->resize_hr,
          s->draw_calls,
          s->quad_draws,
          s->quad_instances,
          s->quad_vertices,
          s->rect_pushes,
          s->rect_flushes,
          s->rect_draws,
          s->rect_vertices,
          s->texture_quads,
          s->texture_draws,
          s->texture_batch_breaks,
          s->quad_batches,
          s->unique_batch_srvs,
          s->repeated_batch_srvs,
          s->pixel_quads,
          s->maps,
          s->texture_uploads,
          (unsigned long long)s->texture_upload_bytes,
          s->texture_recreates,
          s->texture_prunes,
          d3d11_cached_texture_count(),
          (unsigned long)hr,
          s->fail_reason ? s->fail_reason : "");
  g_d3d11.stats.active = false;
  if (d3d11_should_flush_stats_each_frame() || ++g_d3d11.stats.lines_since_flush >= 60 || !success) {
    fflush(g_d3d11.stats.file);
    g_d3d11.stats.lines_since_flush = 0;
  }
}

static void d3d11_stats_abort_reason(const char *reason) {
  if (g_d3d11.stats.enabled && g_d3d11.stats.active) {
    g_d3d11.stats.frame.fail_reason = reason;
    d3d11_stats_end(false, E_ABORT);
  }
}

static bool d3d11_device_lost(HRESULT hr) {
  return hr == DXGI_ERROR_DEVICE_REMOVED ||
         hr == DXGI_ERROR_DEVICE_RESET ||
         hr == DXGI_ERROR_DEVICE_HUNG ||
         hr == DXGI_ERROR_DRIVER_INTERNAL_ERROR;
}

static void d3d11_reset_device(void) {
  anvil_d3d11_shutdown();
  g_d3d11.attempted_init = false;
}

static const char *quad_shader_source =
  "Texture2D tex0 : register(t0);\n"
  "SamplerState smp0 : register(s0);\n"
  "cbuffer QuadConstants : register(b0) { float2 viewport; float2 _pad; };\n"
  "struct VSIn { float4 dst : POSITION; float4 uvrect : TEXCOORD0; float4 color : COLOR0; float4 style : TEXCOORD1; uint vertex_id : SV_VertexID; };\n"
  "struct VSOut { float4 pos : SV_Position; float2 uv : TEXCOORD0; float4 color : COLOR0; float mode : TEXCOORD1; };\n"
  "struct PSOut { float4 color : SV_Target0; float4 coverage : SV_Target1; };\n"
  "VSOut vs_main(VSIn input) {\n"
  "  VSOut output;\n"
  "  float2 positions[4] = {\n"
  "    float2(input.dst.x, input.dst.w),\n"
  "    float2(input.dst.x, input.dst.y),\n"
  "    float2(input.dst.z, input.dst.w),\n"
  "    float2(input.dst.z, input.dst.y)\n"
  "  };\n"
  "  float2 uvs[4] = {\n"
  "    float2(input.uvrect.x, input.uvrect.w),\n"
  "    float2(input.uvrect.x, input.uvrect.y),\n"
  "    float2(input.uvrect.z, input.uvrect.w),\n"
  "    float2(input.uvrect.z, input.uvrect.y)\n"
  "  };\n"
  "  uint vid = input.vertex_id & 3;\n"
  "  float2 p = float2((positions[vid].x / viewport.x) * 2.0f - 1.0f, 1.0f - (positions[vid].y / viewport.y) * 2.0f);\n"
  "  output.pos = float4(p, 0.0f, 1.0f);\n"
  "  output.uv = uvs[vid];\n"
  "  output.color = input.color;\n"
  "  output.mode = input.style.x;\n"
  "  return output;\n"
  "}\n"
  "PSOut ps_main(VSOut input) {\n"
  "  PSOut output;\n"
  "  if (input.mode > 2.5f) {\n"
  "    float a = input.color.a;\n"
  "    output.color = float4(input.color.rgb * a, a);\n"
  "    output.coverage = float4(a, a, a, a);\n"
  "    return output;\n"
  "  }\n"
  "  float4 s = tex0.Sample(smp0, input.uv);\n"
  "  if (input.mode < 0.5f) {\n"
  "    float a = input.color.a * s.r;\n"
  "    output.color = float4(input.color.rgb * a, a);\n"
  "    output.coverage = float4(a, a, a, a);\n"
  "    return output;\n"
  "  }\n"
  "  if (input.mode < 1.5f) {\n"
  "    float3 coverage = input.color.a * s.rgb;\n"
  "    float a = max(coverage.r, max(coverage.g, coverage.b));\n"
  "    output.color = float4(input.color.rgb * coverage, a);\n"
  "    output.coverage = float4(coverage, a);\n"
  "    return output;\n"
  "  }\n"
  "  float a = s.a * input.color.a;\n"
  "  output.color = float4(s.rgb * a, a);\n"
  "  output.coverage = float4(a, a, a, a);\n"
  "  return output;\n"
  "}\n";


bool anvil_d3d11_enabled(void) {
  /* One runtime renderer switch:
     - unset / "d3d11" / "auto" / "1" => D3D11 command renderer
     - "software" / "sdl" / "0" / "off" => SDL/software fallback

     ANVIL_D3D11 is kept only as a legacy alias so old test scripts can still
     disable D3D; ANVIL_D3D11_COMMANDS is intentionally ignored now. */
  const char *renderer = getenv("ANVIL_RENDERER");
  if (renderer && renderer[0]) {
    return !d3d11_renderer_value_is_software(renderer);
  }

  const char *legacy = getenv("ANVIL_D3D11");
  if (legacy && legacy[0]) {
    return !d3d11_env_value_is_false(legacy);
  }

  return true;
}

bool anvil_d3d11_is_present_paced(void) {
  if (!anvil_d3d11_enabled()) return false;
  if (d3d11_present_sync_interval() == 0) return false;
  return !(anvil_resize_diag_live_resize() && d3d11_should_present_zero_live_resize());
}

double anvil_d3d11_last_present_ms(void) {
  return g_d3d11.last_present_ms;
}

int anvil_d3d11_last_sync_interval(void) {
  return g_d3d11.last_sync_interval;
}

const char *anvil_d3d11_last_frame_path(void) {
  return g_d3d11.last_frame_path ? g_d3d11.last_frame_path : "none";
}

int anvil_d3d11_last_draw_calls(void) {
  return g_d3d11.stats.frame.draw_calls;
}

int anvil_d3d11_last_quad_instances(void) {
  return g_d3d11.stats.frame.quad_instances;
}

int anvil_d3d11_last_texture_quads(void) {
  return g_d3d11.stats.frame.texture_quads;
}

int anvil_d3d11_last_texture_uploads(void) {
  return g_d3d11.stats.frame.texture_uploads;
}

size_t anvil_d3d11_last_texture_upload_bytes(void) {
  return g_d3d11.stats.frame.texture_upload_bytes;
}

double anvil_d3d11_last_glyph_push_ms(void) {
  return g_d3d11.stats.frame.glyph_push_ms;
}

double anvil_d3d11_last_flush_quads_ms(void) {
  return g_d3d11.stats.frame.flush_quads_ms;
}

double anvil_d3d11_last_dwm_flush_ms(void) {
  return g_d3d11.stats.frame.dwm_flush_ms;
}

double anvil_d3d11_last_clear_state_ms(void) {
  return g_d3d11.stats.frame.clear_state_ms;
}

static HWND hwnd_from_sdl_window(SDL_Window *window) {
  SDL_PropertiesID props = SDL_GetWindowProperties(window);
  return (HWND) SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WIN32_HWND_POINTER, NULL);
}

static bool d3d11_init(void) {
  if (g_d3d11.attempted_init) return g_d3d11.available;
  g_d3d11.attempted_init = true;

  D3D_FEATURE_LEVEL levels[] = {
    D3D_FEATURE_LEVEL_11_1,
    D3D_FEATURE_LEVEL_11_0,
    D3D_FEATURE_LEVEL_10_1,
    D3D_FEATURE_LEVEL_10_0,
  };
  D3D_FEATURE_LEVEL selected = 0;
  UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
  bool used_warp = false;

  HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, flags,
                                 levels, (UINT)(sizeof(levels) / sizeof(levels[0])),
                                 D3D11_SDK_VERSION,
                                 &g_d3d11.device, &selected, &g_d3d11.context);
  if (FAILED(hr)) {
    used_warp = true;
    hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_WARP, NULL, flags,
                           levels, (UINT)(sizeof(levels) / sizeof(levels[0])),
                           D3D11_SDK_VERSION,
                           &g_d3d11.device, &selected, &g_d3d11.context);
  }
  if (FAILED(hr)) return false;
  g_d3d11.device_is_warp = used_warp;
  g_d3d11.feature_level = selected;

  IDXGIDevice *dxgi_device = NULL;
  IDXGIAdapter *adapter = NULL;
  hr = g_d3d11.device->lpVtbl->QueryInterface(g_d3d11.device, &IID_IDXGIDevice, (void **)&dxgi_device);
  if (SUCCEEDED(hr)) {
    hr = dxgi_device->lpVtbl->GetAdapter(dxgi_device, &adapter);
  }
  if (SUCCEEDED(hr)) {
    DXGI_ADAPTER_DESC desc;
    memset(&desc, 0, sizeof(desc));
    if (SUCCEEDED(adapter->lpVtbl->GetDesc(adapter, &desc))) {
      WideCharToMultiByte(CP_UTF8, 0, desc.Description, -1,
                          g_d3d11.adapter_name, (int)sizeof(g_d3d11.adapter_name),
                          NULL, NULL);
      d3d11_sanitize_csv_field(g_d3d11.adapter_name);
    }
    hr = adapter->lpVtbl->GetParent(adapter, &IID_IDXGIFactory2, (void **)&g_d3d11.factory);
  }
  if (SUCCEEDED(hr)) {
    IDXGIDevice1 *dxgi_device1 = NULL;
    if (SUCCEEDED(g_d3d11.device->lpVtbl->QueryInterface(g_d3d11.device, &IID_IDXGIDevice1, (void **)&dxgi_device1))) {
      dxgi_device1->lpVtbl->SetMaximumFrameLatency(dxgi_device1, d3d11_max_frame_latency());
      SAFE_RELEASE(dxgi_device1);
    }
  }
  SAFE_RELEASE(adapter);
  SAFE_RELEASE(dxgi_device);

  if (FAILED(hr) || !g_d3d11.factory) {
    anvil_d3d11_shutdown();
    return false;
  }

  g_d3d11.available = true;
  return true;
}

static bool d3d11_ensure_common_pipeline(void) {
  if (g_d3d11.blend && g_d3d11.raster) return true;

  D3D11_BLEND_DESC bdesc;
  memset(&bdesc, 0, sizeof(bdesc));
  bdesc.RenderTarget[0].BlendEnable = TRUE;
  bdesc.RenderTarget[0].SrcBlend = D3D11_BLEND_ONE;
  bdesc.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC1_COLOR;
  bdesc.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
  bdesc.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
  bdesc.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
  bdesc.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
  bdesc.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
  HRESULT hr = g_d3d11.device->lpVtbl->CreateBlendState(g_d3d11.device, &bdesc, &g_d3d11.blend);
  if (FAILED(hr)) goto fail;

  D3D11_RASTERIZER_DESC rdesc;
  memset(&rdesc, 0, sizeof(rdesc));
  rdesc.FillMode = D3D11_FILL_SOLID;
  rdesc.CullMode = D3D11_CULL_NONE;
  rdesc.ScissorEnable = TRUE;
  rdesc.DepthClipEnable = TRUE;
  hr = g_d3d11.device->lpVtbl->CreateRasterizerState(g_d3d11.device, &rdesc, &g_d3d11.raster);
  if (FAILED(hr)) goto fail;

  return true;

fail:
  SAFE_RELEASE(g_d3d11.raster);
  SAFE_RELEASE(g_d3d11.blend);
  return false;
}

static bool d3d11_ensure_quad_pipeline(void) {
  if (g_d3d11.quad_vs && g_d3d11.quad_ps && g_d3d11.quad_layout &&
      g_d3d11.quad_vbuf && g_d3d11.quad_cbuf && g_d3d11.quad_sampler) {
    return true;
  }

  ID3DBlob *vs_blob = NULL;
  ID3DBlob *ps_blob = NULL;
  ID3DBlob *errors = NULL;
  UINT flags = D3DCOMPILE_ENABLE_STRICTNESS;

  HRESULT hr = D3DCompile(quad_shader_source, strlen(quad_shader_source),
                          "anvil_quad_shader", NULL, NULL, "vs_main", "vs_4_0",
                          flags, 0, &vs_blob, &errors);
  SAFE_RELEASE(errors);
  if (FAILED(hr) || !vs_blob) goto fail;

  hr = D3DCompile(quad_shader_source, strlen(quad_shader_source),
                  "anvil_quad_shader", NULL, NULL, "ps_main", "ps_4_0",
                  flags, 0, &ps_blob, &errors);
  SAFE_RELEASE(errors);
  if (FAILED(hr) || !ps_blob) goto fail;

  hr = g_d3d11.device->lpVtbl->CreateVertexShader(g_d3d11.device,
                                                   vs_blob->lpVtbl->GetBufferPointer(vs_blob),
                                                   vs_blob->lpVtbl->GetBufferSize(vs_blob),
                                                   NULL, &g_d3d11.quad_vs);
  if (FAILED(hr)) goto fail;

  hr = g_d3d11.device->lpVtbl->CreatePixelShader(g_d3d11.device,
                                                  ps_blob->lpVtbl->GetBufferPointer(ps_blob),
                                                  ps_blob->lpVtbl->GetBufferSize(ps_blob),
                                                  NULL, &g_d3d11.quad_ps);
  if (FAILED(hr)) goto fail;

  D3D11_INPUT_ELEMENT_DESC layout[] = {
    { "POSITION", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 0, D3D11_INPUT_PER_INSTANCE_DATA, 1 },
    { "TEXCOORD", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 16, D3D11_INPUT_PER_INSTANCE_DATA, 1 },
    { "COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 32, D3D11_INPUT_PER_INSTANCE_DATA, 1 },
    { "TEXCOORD", 1, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 48, D3D11_INPUT_PER_INSTANCE_DATA, 1 },
  };
  hr = g_d3d11.device->lpVtbl->CreateInputLayout(g_d3d11.device, layout, 4,
                                                  vs_blob->lpVtbl->GetBufferPointer(vs_blob),
                                                  vs_blob->lpVtbl->GetBufferSize(vs_blob),
                                                  &g_d3d11.quad_layout);
  if (FAILED(hr)) goto fail;

  g_d3d11.quad_instance_buffer_capacity = 65536;
  D3D11_BUFFER_DESC vdesc;
  memset(&vdesc, 0, sizeof(vdesc));
  vdesc.ByteWidth = (UINT)(sizeof(D3D11QuadInstance) * g_d3d11.quad_instance_buffer_capacity);
  vdesc.Usage = D3D11_USAGE_DYNAMIC;
  vdesc.BindFlags = D3D11_BIND_VERTEX_BUFFER;
  vdesc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
  hr = g_d3d11.device->lpVtbl->CreateBuffer(g_d3d11.device, &vdesc, NULL, &g_d3d11.quad_vbuf);
  if (FAILED(hr)) goto fail;

  D3D11_BUFFER_DESC cdesc;
  memset(&cdesc, 0, sizeof(cdesc));
  cdesc.ByteWidth = sizeof(D3D11QuadConstants);
  cdesc.Usage = D3D11_USAGE_DEFAULT;
  cdesc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
  hr = g_d3d11.device->lpVtbl->CreateBuffer(g_d3d11.device, &cdesc, NULL, &g_d3d11.quad_cbuf);
  if (FAILED(hr)) goto fail;

  D3D11_SAMPLER_DESC sdesc;
  memset(&sdesc, 0, sizeof(sdesc));
  sdesc.Filter = D3D11_FILTER_MIN_MAG_MIP_POINT;
  sdesc.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
  sdesc.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
  sdesc.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
  sdesc.MaxLOD = D3D11_FLOAT32_MAX;
  hr = g_d3d11.device->lpVtbl->CreateSamplerState(g_d3d11.device, &sdesc, &g_d3d11.quad_sampler);
  if (FAILED(hr)) goto fail;

  SAFE_RELEASE(ps_blob);
  SAFE_RELEASE(vs_blob);
  return true;

fail:
  SAFE_RELEASE(errors);
  SAFE_RELEASE(ps_blob);
  SAFE_RELEASE(vs_blob);
  SAFE_RELEASE(g_d3d11.quad_sampler);
  SAFE_RELEASE(g_d3d11.quad_cbuf);
  SAFE_RELEASE(g_d3d11.quad_vbuf);
  g_d3d11.quad_instance_buffer_capacity = 0;
  SAFE_RELEASE(g_d3d11.quad_layout);
  SAFE_RELEASE(g_d3d11.quad_ps);
  SAFE_RELEASE(g_d3d11.quad_vs);
  return false;
}

static D3D11Window *d3d11_find_window(SDL_Window *window) {
  for (D3D11Window *w = g_d3d11.windows; w; w = w->next) {
    if (w->window == window) return w;
  }
  return NULL;
}

static void d3d11_unbind_resize_references(void) {
  if (!g_d3d11.context) return;
  ID3D11RenderTargetView *null_rtv = NULL;
  ID3D11ShaderResourceView *null_srv = NULL;
  g_d3d11.context->lpVtbl->OMSetRenderTargets(g_d3d11.context, 0, NULL, NULL);
  g_d3d11.context->lpVtbl->PSSetShaderResources(g_d3d11.context, 0, 1, &null_srv);
  (void)null_rtv;
}

static void d3d11_release_window_buffers(D3D11Window *w) {
  if (!w) return;
  SAFE_RELEASE(w->rtv);
  SAFE_RELEASE(w->backbuffer);
}

static void d3d11_destroy_window(D3D11Window *w) {
  if (!w) return;
  d3d11_release_window_buffers(w);
  SAFE_RELEASE(w->swapchain);
  free(w);
}

static void d3d11_release_cached_texture(D3D11CachedTexture *t);

void anvil_d3d11_forget_window(SDL_Window *window) {
  D3D11Window **link = &g_d3d11.windows;
  while (*link) {
    D3D11Window *w = *link;
    if (w->window == window) {
      *link = w->next;
      d3d11_destroy_window(w);
      return;
    }
    link = &w->next;
  }
}

void anvil_d3d11_forget_surface(SDL_Surface *surface) {
  if (!surface) return;
  D3D11CachedTexture **link = &g_d3d11.textures;
  while (*link) {
    D3D11CachedTexture *t = *link;
    if (t->surface == surface) {
      *link = t->next;
      d3d11_release_cached_texture(t);
      free(t);
      continue;
    }
    link = &t->next;
  }
}

static void d3d11_prune_texture_cache(uint64_t max_age_frames) {
  D3D11CachedTexture **link = &g_d3d11.textures;
  while (*link) {
    D3D11CachedTexture *t = *link;
    uint64_t age = g_d3d11.frame_index >= t->last_used_frame
      ? g_d3d11.frame_index - t->last_used_frame
      : 0;
    if (age > max_age_frames) {
      *link = t->next;
      d3d11_release_cached_texture(t);
      free(t);
      g_d3d11.stats.frame.texture_prunes++;
      continue;
    }
    link = &t->next;
  }
}

static bool d3d11_get_backbuffer_timed(D3D11Window *w, double *get_buffer_ms, double *create_rtv_ms, HRESULT *out_hr) {
  if (get_buffer_ms) *get_buffer_ms = 0.0;
  if (create_rtv_ms) *create_rtv_ms = 0.0;
  if (out_hr) *out_hr = S_OK;

  d3d11_release_window_buffers(w);
  LARGE_INTEGER start, end;
  QueryPerformanceCounter(&start);
  HRESULT hr = w->swapchain->lpVtbl->GetBuffer(w->swapchain, 0, &IID_ID3D11Texture2D, (void **)&w->backbuffer);
  QueryPerformanceCounter(&end);
  if (get_buffer_ms) *get_buffer_ms = d3d11_ms_between(start, end);
  if (FAILED(hr) || !w->backbuffer) {
    if (out_hr) *out_hr = hr;
    if (d3d11_device_lost(hr)) d3d11_reset_device();
    return false;
  }

  QueryPerformanceCounter(&start);
  hr = g_d3d11.device->lpVtbl->CreateRenderTargetView(g_d3d11.device,
                                                       (ID3D11Resource *)w->backbuffer,
                                                       NULL, &w->rtv);
  QueryPerformanceCounter(&end);
  if (create_rtv_ms) *create_rtv_ms = d3d11_ms_between(start, end);
  if (FAILED(hr) || !w->rtv) {
    if (out_hr) *out_hr = hr;
    if (d3d11_device_lost(hr)) d3d11_reset_device();
    return false;
  }
  return true;
}

static bool d3d11_get_backbuffer(D3D11Window *w) {
  return d3d11_get_backbuffer_timed(w, NULL, NULL, NULL);
}

static void d3d11_set_swapchain_background(D3D11Window *w, RenColor color) {
  if (!w || !w->swapchain) return;
  DXGI_RGBA bg = {
    color.r / 255.0f,
    color.g / 255.0f,
    color.b / 255.0f,
    color.a / 255.0f,
  };
  w->swapchain->lpVtbl->SetBackgroundColor(w->swapchain, &bg);
}

static D3D11Window *d3d11_get_or_create_window(SDL_Window *window, int width, int height) {
  D3D11Window *w = d3d11_find_window(window);
  if (w) return w;

  HWND hwnd = hwnd_from_sdl_window(window);
  if (!hwnd) return NULL;

  w = (D3D11Window *)calloc(1, sizeof(*w));
  if (!w) return NULL;
  w->window = window;
  w->hwnd = hwnd;

  DXGI_SWAP_CHAIN_DESC1 desc;
  memset(&desc, 0, sizeof(desc));
  desc.Width = d3d11_should_infer_swapchain_size() ? 0 : (UINT)width;
  desc.Height = d3d11_should_infer_swapchain_size() ? 0 : (UINT)height;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.Stereo = FALSE;
  desc.SampleDesc.Count = 1;
  desc.SampleDesc.Quality = 0;
  desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
  desc.BufferCount = d3d11_swapchain_buffer_count();
  desc.Scaling = DXGI_SCALING_NONE;
  desc.SwapEffect = d3d11_should_use_flip_sequential()
    ? DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL
    : DXGI_SWAP_EFFECT_FLIP_DISCARD;
  desc.AlphaMode = DXGI_ALPHA_MODE_UNSPECIFIED;
  if (d3d11_should_use_legacy_discard()) {
    desc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    desc.BufferCount = 1;
  }

  HRESULT hr = g_d3d11.factory->lpVtbl->CreateSwapChainForHwnd(
    g_d3d11.factory, (IUnknown *)g_d3d11.device, hwnd, &desc, NULL, NULL, &w->swapchain);
  if (FAILED(hr) && desc.SwapEffect != DXGI_SWAP_EFFECT_DISCARD) {
    desc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    desc.BufferCount = 1;
    hr = g_d3d11.factory->lpVtbl->CreateSwapChainForHwnd(
      g_d3d11.factory, (IUnknown *)g_d3d11.device, hwnd, &desc, NULL, NULL, &w->swapchain);
  }
  if (FAILED(hr) || !w->swapchain) {
    d3d11_destroy_window(w);
    return NULL;
  }

  g_d3d11.factory->lpVtbl->MakeWindowAssociation(g_d3d11.factory, hwnd, DXGI_MWA_NO_ALT_ENTER);
  w->width = width;
  w->height = height;
  w->buffer_count = (int)desc.BufferCount;
  w->swap_effect = desc.SwapEffect;
  if (!d3d11_get_backbuffer(w)) {
    d3d11_destroy_window(w);
    return NULL;
  }

  w->next = g_d3d11.windows;
  g_d3d11.windows = w;
  return w;
}

static bool d3d11_resize_window(D3D11Window *w, int width, int height) {
  if (!w || !w->swapchain) return false;
  if (g_d3d11.stats.enabled && g_d3d11.stats.active) {
    g_d3d11.stats.frame.resize_hr = S_OK;
  }
  if (w->width == width && w->height == height && w->backbuffer) return true;

  if (g_d3d11.stats.enabled && g_d3d11.stats.active) {
    g_d3d11.stats.frame.resize_done = true;
    g_d3d11.stats.frame.resize_old_w = w->width;
    g_d3d11.stats.frame.resize_old_h = w->height;
    g_d3d11.stats.frame.resize_new_w = width;
    g_d3d11.stats.frame.resize_new_h = height;
  }

  LARGE_INTEGER start, end;
  QueryPerformanceCounter(&start);
  d3d11_unbind_resize_references();
  d3d11_release_window_buffers(w);
  QueryPerformanceCounter(&end);
  if (g_d3d11.stats.enabled && g_d3d11.stats.active) {
    g_d3d11.stats.frame.resize_release_ms = d3d11_ms_between(start, end);
  }

  QueryPerformanceCounter(&start);
  UINT resize_width = d3d11_should_infer_swapchain_size() ? 0 : (UINT)width;
  UINT resize_height = d3d11_should_infer_swapchain_size() ? 0 : (UINT)height;
  HRESULT hr = w->swapchain->lpVtbl->ResizeBuffers(w->swapchain, 0, resize_width, resize_height, DXGI_FORMAT_UNKNOWN, 0);
  QueryPerformanceCounter(&end);
  if (g_d3d11.stats.enabled && g_d3d11.stats.active) {
    g_d3d11.stats.frame.resize_buffers_ms = d3d11_ms_between(start, end);
    g_d3d11.stats.frame.resize_hr = hr;
  }
  if (FAILED(hr)) {
    if (d3d11_device_lost(hr)) d3d11_reset_device();
    return false;
  }

  w->width = width;
  w->height = height;
  double get_ms = 0.0;
  double rtv_ms = 0.0;
  HRESULT backbuffer_hr = S_OK;
  bool ok = d3d11_get_backbuffer_timed(w, &get_ms, &rtv_ms, &backbuffer_hr);
  if (g_d3d11.stats.enabled && g_d3d11.stats.active) {
    g_d3d11.stats.frame.resize_get_buffer_ms = get_ms;
    g_d3d11.stats.frame.resize_create_rtv_ms = rtv_ms;
    if (FAILED(backbuffer_hr)) g_d3d11.stats.frame.resize_hr = backbuffer_hr;
  }
  if (ok && d3d11_should_resize_flush()) {
    QueryPerformanceCounter(&start);
    g_d3d11.context->lpVtbl->Flush(g_d3d11.context);
    QueryPerformanceCounter(&end);
    if (g_d3d11.stats.enabled && g_d3d11.stats.active) {
      g_d3d11.stats.frame.resize_flush_ms = d3d11_ms_between(start, end);
    }
  }
  return ok;
}

static RenRect d3d11_intersect_renrect(RenRect a, RenRect b) {
  int ax1 = (int)floor((double)a.x);
  int ay1 = (int)floor((double)a.y);
  int ax2 = (int)ceil((double)(a.x + a.width));
  int ay2 = (int)ceil((double)(a.y + a.height));
  int bx1 = (int)floor((double)b.x);
  int by1 = (int)floor((double)b.y);
  int bx2 = (int)ceil((double)(b.x + b.width));
  int by2 = (int)ceil((double)(b.y + b.height));
  int x1 = ax1 > bx1 ? ax1 : bx1;
  int y1 = ay1 > by1 ? ay1 : by1;
  int x2 = ax2 < bx2 ? ax2 : bx2;
  int y2 = ay2 < by2 ? ay2 : by2;
  return (RenRect){ x1, y1, x2 > x1 ? x2 - x1 : 0, y2 > y1 ? y2 - y1 : 0 };
}

static bool d3d11_reserve_quad_instances(int extra) {
  int needed = g_d3d11.quad_instance_count + extra;
  if (needed <= g_d3d11.quad_instance_capacity) return true;

  int new_capacity = g_d3d11.quad_instance_capacity ? g_d3d11.quad_instance_capacity * 2 : 4096;
  while (new_capacity < needed) new_capacity *= 2;
  D3D11QuadInstance *new_vertices = (D3D11QuadInstance *)realloc(g_d3d11.quad_instances,
                                                                    sizeof(D3D11QuadInstance) * (size_t)new_capacity);
  if (!new_vertices) return false;
  g_d3d11.quad_instances = new_vertices;
  g_d3d11.quad_instance_capacity = new_capacity;
  return true;
}

static bool d3d11_ensure_quad_instance_buffer_capacity(int vertex_count) {
  if (vertex_count <= g_d3d11.quad_instance_buffer_capacity) return true;

  SAFE_RELEASE(g_d3d11.quad_vbuf);
  int new_capacity = g_d3d11.quad_instance_buffer_capacity ? g_d3d11.quad_instance_buffer_capacity * 2 : 65536;
  while (new_capacity < vertex_count) new_capacity *= 2;

  D3D11_BUFFER_DESC vdesc;
  memset(&vdesc, 0, sizeof(vdesc));
  vdesc.ByteWidth = (UINT)(sizeof(D3D11QuadInstance) * (size_t)new_capacity);
  vdesc.Usage = D3D11_USAGE_DYNAMIC;
  vdesc.BindFlags = D3D11_BIND_VERTEX_BUFFER;
  vdesc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
  HRESULT hr = g_d3d11.device->lpVtbl->CreateBuffer(g_d3d11.device, &vdesc, NULL, &g_d3d11.quad_vbuf);
  if (FAILED(hr)) return false;
  g_d3d11.quad_instance_buffer_capacity = new_capacity;
  return true;
}

static bool d3d11_reserve_quad_batches(int extra) {
  int needed = g_d3d11.quad_batch_count + extra;
  if (needed <= g_d3d11.quad_batch_capacity) return true;

  int new_capacity = g_d3d11.quad_batch_capacity ? g_d3d11.quad_batch_capacity * 2 : 256;
  while (new_capacity < needed) new_capacity *= 2;
  D3D11QuadBatch *new_batches = (D3D11QuadBatch *)realloc(g_d3d11.quad_batches,
                                                          sizeof(D3D11QuadBatch) * (size_t)new_capacity);
  if (!new_batches) return false;
  g_d3d11.quad_batches = new_batches;
  g_d3d11.quad_batch_capacity = new_capacity;
  return true;
}

static bool d3d11_flush_quads(void);
static bool d3d11_ensure_white_texture(void);
static bool d3d11_queue_quad(ID3D11ShaderResourceView *srv,
                             const D3D11QuadInstance *inst,
                             bool texture_dependent);

bool anvil_d3d11_begin_frame(SDL_Window *window, int width, int height, RenColor clear_color) {
  if (!anvil_d3d11_enabled() || !window || width <= 0 || height <= 0) return false;
  if (!d3d11_init() || !d3d11_ensure_common_pipeline() || !d3d11_ensure_quad_pipeline()) return false;

  D3D11Window *w = d3d11_get_or_create_window(window, width, height);
  if (!w) return false;
  d3d11_stats_begin("commands", window, w, width, height);
  d3d11_set_swapchain_background(w, clear_color);
  if (!d3d11_resize_window(w, width, height)) {
    g_d3d11.stats.frame.fail_reason = "resize";
    d3d11_stats_end(false, g_d3d11.stats.frame.resize_hr);
    anvil_d3d11_forget_window(window);
    return false;
  }

  FLOAT clear[4] = {
    clear_color.r / 255.0f,
    clear_color.g / 255.0f,
    clear_color.b / 255.0f,
    clear_color.a / 255.0f,
  };
  g_d3d11.context->lpVtbl->OMSetRenderTargets(g_d3d11.context, 1, &w->rtv, NULL);
  g_d3d11.context->lpVtbl->ClearRenderTargetView(g_d3d11.context, w->rtv, clear);

  D3D11_VIEWPORT viewport;
  memset(&viewport, 0, sizeof(viewport));
  viewport.TopLeftX = 0.0f;
  viewport.TopLeftY = 0.0f;
  viewport.Width = (FLOAT)width;
  viewport.Height = (FLOAT)height;
  viewport.MinDepth = 0.0f;
  viewport.MaxDepth = 1.0f;
  g_d3d11.context->lpVtbl->RSSetViewports(g_d3d11.context, 1, &viewport);

  D3D11_RECT scissor = { 0, 0, width, height };
  g_d3d11.context->lpVtbl->RSSetScissorRects(g_d3d11.context, 1, &scissor);


  g_d3d11.frame_index++;
  if (g_d3d11.frame_index == 0) g_d3d11.frame_index = 1;
  if ((g_d3d11.frame_index % 120u) == 0) {
    d3d11_prune_texture_cache(600u);
  }
  g_d3d11.quad_instance_count = 0;
  g_d3d11.quad_batch_count = 0;
  g_d3d11.active_window = window;
  return true;
}

bool anvil_d3d11_push_rect(SDL_Window *window, RenRect rect, RenRect clip, RenColor color) {
  if (window != g_d3d11.active_window) return false;
  if (color.a == 0) return true;
  if (!d3d11_ensure_quad_pipeline() || !d3d11_ensure_white_texture()) return false;
  g_d3d11.stats.frame.rect_pushes++;
  RenRect r = d3d11_intersect_renrect(rect, clip);
  if (r.width <= 0 || r.height <= 0) return true;

  float x0 = (float)r.x;
  float y0 = (float)r.y;
  float x1 = (float)(r.x + r.width);
  float y1 = (float)(r.y + r.height);
  float cr = color.r / 255.0f;
  float cg = color.g / 255.0f;
  float cb = color.b / 255.0f;
  float ca = color.a / 255.0f;

  D3D11QuadInstance inst = { x0, y0, x1, y1, 0, 0, 1, 1, cr, cg, cb, ca, 3.0f, 0, 0, 0 };
  return d3d11_queue_quad(g_d3d11.white_srv, &inst, false);
}

static inline RenRect d3d11_float_rect_to_grid(float x, float y, float w, float h) {
  int x1 = (int)(x + 0.5f), y1 = (int)(y + 0.5f);
  int x2 = (int)(x + w + 0.5f), y2 = (int)(y + h + 0.5f);
  return (RenRect){ x1, y1, x2 - x1, y2 - y1 };
}

bool anvil_d3d11_push_rect_grid(SDL_Window *window, float x, float y, float step_x, float w, float h, int count, RenRect clip, RenColor color) {
  if (window != g_d3d11.active_window) return false;
  if (color.a == 0 || count <= 0 || step_x <= 0.0f || w <= 0.0f || h <= 0.0f) return true;
  if (!d3d11_ensure_quad_pipeline() || !d3d11_ensure_white_texture()) return false;

  float clip_x0 = (float)clip.x;
  float clip_y0 = (float)clip.y;
  float clip_x1 = (float)(clip.x + clip.width);
  float clip_y1 = (float)(clip.y + clip.height);
  if (y + h <= clip_y0 || y >= clip_y1) return true;

  int first = (int)floorf((clip_x0 - w - x) / step_x) - 1;
  int last = (int)ceilf((clip_x1 - x) / step_x) + 1;
  if (first < 0) first = 0;
  if (last > count - 1) last = count - 1;
  if (last < first) return true;
  g_d3d11.stats.frame.rect_pushes += last - first + 1;

  float cr = color.r / 255.0f;
  float cg = color.g / 255.0f;
  float cb = color.b / 255.0f;
  float ca = color.a / 255.0f;
  for (int i = first; i <= last; i++) {
    RenRect r = d3d11_intersect_renrect(d3d11_float_rect_to_grid(x + step_x * (float)i, y, w, h), clip);
    if (r.width <= 0 || r.height <= 0) continue;
    float x0 = (float)r.x;
    float y0 = (float)r.y;
    float x1 = (float)(r.x + r.width);
    float y1 = (float)(r.y + r.height);
    D3D11QuadInstance inst = { x0, y0, x1, y1, 0, 0, 1, 1, cr, cg, cb, ca, 3.0f, 0, 0, 0 };
    if (!d3d11_queue_quad(g_d3d11.white_srv, &inst, false)) return false;
  }
  return true;
}

static D3D11CachedTexture *d3d11_find_cached_texture(SDL_Surface *surface, int mode) {
  for (D3D11CachedTexture *t = g_d3d11.textures; t; t = t->next) {
    if (t->surface == surface && t->mode == mode) return t;
  }
  return NULL;
}

static void d3d11_release_cached_texture(D3D11CachedTexture *t) {
  if (!t) return;
  SAFE_RELEASE(t->srv);
  SAFE_RELEASE(t->texture);
}

static bool d3d11_recreate_cached_texture(D3D11CachedTexture *t, SDL_Surface *surface, int mode) {
  d3d11_release_cached_texture(t);
  t->surface = surface;
  t->width = surface->w;
  t->height = surface->h;
  t->format = surface->format;
  t->mode = mode;
  t->last_update_frame = 0;
  g_d3d11.stats.frame.texture_recreates++;

  D3D11_TEXTURE2D_DESC desc;
  memset(&desc, 0, sizeof(desc));
  desc.Width = (UINT)t->width;
  desc.Height = (UINT)t->height;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
  HRESULT hr = g_d3d11.device->lpVtbl->CreateTexture2D(g_d3d11.device, &desc, NULL, &t->texture);
  if (FAILED(hr)) return false;

  D3D11_SHADER_RESOURCE_VIEW_DESC sdesc;
  memset(&sdesc, 0, sizeof(sdesc));
  sdesc.Format = desc.Format;
  sdesc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
  sdesc.Texture2D.MipLevels = 1;
  hr = g_d3d11.device->lpVtbl->CreateShaderResourceView(g_d3d11.device,
                                                         (ID3D11Resource *)t->texture,
                                                         &sdesc, &t->srv);
  if (FAILED(hr) || !t->srv) {
    d3d11_release_cached_texture(t);
    return false;
  }
  return true;
}

static bool d3d11_ensure_texture_upload_scratch(size_t size) {
  if (size <= g_d3d11.texture_upload_scratch_capacity) return true;
  uint8_t *scratch = (uint8_t *)realloc(g_d3d11.texture_upload_scratch, size);
  if (!scratch) return false;
  g_d3d11.texture_upload_scratch = scratch;
  g_d3d11.texture_upload_scratch_capacity = size;
  return true;
}

static bool d3d11_update_cached_texture(D3D11CachedTexture *t, SDL_Surface *surface, int mode) {
  if (!surface || !surface->pixels || surface->w <= 0 || surface->h <= 0) return false;
  if (!t->texture || !t->srv || t->width != surface->w || t->height != surface->h ||
      t->format != surface->format || t->mode != mode) {
    if (!d3d11_recreate_cached_texture(t, surface, mode)) return false;
  }
  SDL_PropertiesID props = SDL_GetSurfaceProperties(surface);
  Sint64 generation = SDL_GetNumberProperty(props, "anvil_d3d11_generation", -1);
  uint64_t update_key = generation >= 0 ? (uint64_t)generation : g_d3d11.frame_index;
  if (t->last_update_frame == update_key) return true;

  const int width = surface->w;
  const int height = surface->h;
  size_t rgba_size = (size_t)width * (size_t)height * 4u;
  if (!d3d11_ensure_texture_upload_scratch(rgba_size)) return false;
  uint8_t *rgba = g_d3d11.texture_upload_scratch;

  const int bpp = SDL_BYTESPERPIXEL(surface->format);
  for (int y = 0; y < height; y++) {
    const uint8_t *src = (const uint8_t *)surface->pixels + (size_t)y * (size_t)surface->pitch;
    uint8_t *dst = rgba + (size_t)y * (size_t)width * 4u;
    for (int x = 0; x < width; x++, dst += 4) {
      if (mode == 0) {
        uint8_t c = src[x * bpp];
        dst[0] = c; dst[1] = c; dst[2] = c; dst[3] = c;
      } else if (mode == 1) {
        const uint8_t *p = src + x * bpp;
        dst[0] = bpp > 0 ? p[0] : 0;
        dst[1] = bpp > 1 ? p[1] : dst[0];
        dst[2] = bpp > 2 ? p[2] : dst[0];
        dst[3] = 255;
      } else {
        const uint8_t *p = src + x * bpp;
        if (surface->format == SDL_PIXELFORMAT_BGRA32 || surface->format == SDL_PIXELFORMAT_BGR24) {
          dst[0] = bpp > 2 ? p[2] : 255;
          dst[1] = bpp > 1 ? p[1] : 255;
          dst[2] = bpp > 0 ? p[0] : 255;
          dst[3] = bpp > 3 ? p[3] : 255;
        } else {
          dst[0] = bpp > 0 ? p[0] : 255;
          dst[1] = bpp > 1 ? p[1] : 255;
          dst[2] = bpp > 2 ? p[2] : 255;
          dst[3] = bpp > 3 ? p[3] : 255;
        }
      }
    }
  }

  g_d3d11.context->lpVtbl->UpdateSubresource(g_d3d11.context,
                                             (ID3D11Resource *)t->texture,
                                             0, NULL, rgba, (UINT)(width * 4), 0);
  g_d3d11.stats.frame.texture_uploads++;
  g_d3d11.stats.frame.texture_upload_bytes += rgba_size;
  t->last_update_frame = update_key;
  return true;
}

static D3D11CachedTexture *d3d11_get_cached_texture(SDL_Surface *surface, int mode) {
  D3D11CachedTexture *t = d3d11_find_cached_texture(surface, mode);
  if (!t) {
    t = (D3D11CachedTexture *)calloc(1, sizeof(*t));
    if (!t) return NULL;
    t->next = g_d3d11.textures;
    g_d3d11.textures = t;
  }
  if (!d3d11_update_cached_texture(t, surface, mode)) return NULL;
  t->last_used_frame = g_d3d11.frame_index;
  return t;
}

static void d3d11_release_upload_texture(void) {
  SAFE_RELEASE(g_d3d11.upload_srv);
  SAFE_RELEASE(g_d3d11.upload_texture);
  g_d3d11.upload_width = 0;
  g_d3d11.upload_height = 0;
}

static void d3d11_release_white_texture(void) {
  SAFE_RELEASE(g_d3d11.white_srv);
  SAFE_RELEASE(g_d3d11.white_texture);
}

static bool d3d11_ensure_white_texture(void) {
  if (g_d3d11.white_texture && g_d3d11.white_srv) return true;

  uint32_t white = 0xffffffffu;
  D3D11_TEXTURE2D_DESC desc;
  memset(&desc, 0, sizeof(desc));
  desc.Width = 1;
  desc.Height = 1;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_IMMUTABLE;
  desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;

  D3D11_SUBRESOURCE_DATA data;
  memset(&data, 0, sizeof(data));
  data.pSysMem = &white;
  data.SysMemPitch = sizeof(white);

  HRESULT hr = g_d3d11.device->lpVtbl->CreateTexture2D(g_d3d11.device, &desc, &data, &g_d3d11.white_texture);
  if (FAILED(hr) || !g_d3d11.white_texture) return false;

  D3D11_SHADER_RESOURCE_VIEW_DESC sdesc;
  memset(&sdesc, 0, sizeof(sdesc));
  sdesc.Format = desc.Format;
  sdesc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
  sdesc.Texture2D.MipLevels = 1;
  hr = g_d3d11.device->lpVtbl->CreateShaderResourceView(g_d3d11.device,
                                                        (ID3D11Resource *)g_d3d11.white_texture,
                                                        &sdesc, &g_d3d11.white_srv);
  if (FAILED(hr) || !g_d3d11.white_srv) {
    d3d11_release_white_texture();
    return false;
  }
  return true;
}

static bool d3d11_ensure_upload_texture(int width, int height) {
  if (g_d3d11.upload_texture && g_d3d11.upload_srv &&
      g_d3d11.upload_width == width && g_d3d11.upload_height == height) {
    return true;
  }

  d3d11_release_upload_texture();

  D3D11_TEXTURE2D_DESC desc;
  memset(&desc, 0, sizeof(desc));
  desc.Width = (UINT)width;
  desc.Height = (UINT)height;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;

  HRESULT hr = g_d3d11.device->lpVtbl->CreateTexture2D(g_d3d11.device, &desc, NULL, &g_d3d11.upload_texture);
  if (FAILED(hr) || !g_d3d11.upload_texture) return false;

  D3D11_SHADER_RESOURCE_VIEW_DESC sdesc;
  memset(&sdesc, 0, sizeof(sdesc));
  sdesc.Format = desc.Format;
  sdesc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
  sdesc.Texture2D.MipLevels = 1;
  hr = g_d3d11.device->lpVtbl->CreateShaderResourceView(g_d3d11.device,
                                                         (ID3D11Resource *)g_d3d11.upload_texture,
                                                         &sdesc, &g_d3d11.upload_srv);
  if (FAILED(hr) || !g_d3d11.upload_srv) {
    d3d11_release_upload_texture();
    return false;
  }

  g_d3d11.upload_width = width;
  g_d3d11.upload_height = height;
  return true;
}

static bool d3d11_flush_quads(void) {
  if (g_d3d11.quad_instance_count <= 0) return true;
  if (g_d3d11.quad_batch_count <= 0) return false;
  if (!d3d11_ensure_quad_instance_buffer_capacity(g_d3d11.quad_instance_count)) return false;

  LARGE_INTEGER t0, t1;
  QueryPerformanceCounter(&t0);

  D3D11_MAPPED_SUBRESOURCE mapped;
  HRESULT hr = g_d3d11.context->lpVtbl->Map(g_d3d11.context,
                                            (ID3D11Resource *)g_d3d11.quad_vbuf,
                                            0, D3D11_MAP_WRITE_DISCARD, 0, &mapped);
  if (FAILED(hr)) return false;
  g_d3d11.stats.frame.maps++;
  memcpy(mapped.pData, g_d3d11.quad_instances,
         sizeof(D3D11QuadInstance) * (size_t)g_d3d11.quad_instance_count);
  g_d3d11.context->lpVtbl->Unmap(g_d3d11.context, (ID3D11Resource *)g_d3d11.quad_vbuf, 0);

  D3D11Window *w = d3d11_find_window(g_d3d11.active_window);
  if (!w || !w->rtv) return false;
  g_d3d11.context->lpVtbl->OMSetRenderTargets(g_d3d11.context, 1, &w->rtv, NULL);

  D3D11QuadConstants constants = { (float)w->width, (float)w->height, 0.0f, 0.0f };
  g_d3d11.context->lpVtbl->UpdateSubresource(g_d3d11.context,
                                             (ID3D11Resource *)g_d3d11.quad_cbuf,
                                             0, NULL, &constants, 0, 0);

  UINT stride = sizeof(D3D11QuadInstance);
  UINT offset = 0;
  FLOAT blend_factor[4] = {0, 0, 0, 0};
  g_d3d11.context->lpVtbl->IASetInputLayout(g_d3d11.context, g_d3d11.quad_layout);
  g_d3d11.context->lpVtbl->IASetPrimitiveTopology(g_d3d11.context, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
  g_d3d11.context->lpVtbl->IASetVertexBuffers(g_d3d11.context, 0, 1, &g_d3d11.quad_vbuf, &stride, &offset);
  g_d3d11.context->lpVtbl->VSSetShader(g_d3d11.context, g_d3d11.quad_vs, NULL, 0);
  g_d3d11.context->lpVtbl->VSSetConstantBuffers(g_d3d11.context, 0, 1, &g_d3d11.quad_cbuf);
  g_d3d11.context->lpVtbl->PSSetShader(g_d3d11.context, g_d3d11.quad_ps, NULL, 0);
  g_d3d11.context->lpVtbl->PSSetSamplers(g_d3d11.context, 0, 1, &g_d3d11.quad_sampler);
  g_d3d11.context->lpVtbl->RSSetState(g_d3d11.context, g_d3d11.raster);
  g_d3d11.context->lpVtbl->OMSetBlendState(g_d3d11.context, g_d3d11.blend, blend_factor, 0xffffffffu);

  int submitted_instances = 0;
  int unique_srvs = 0;
  for (int i = 0; i < g_d3d11.quad_batch_count; i++) {
    bool seen_srv = false;
    for (int j = 0; j < i; j++) {
      if (g_d3d11.quad_batches[j].srv == g_d3d11.quad_batches[i].srv) {
        seen_srv = true;
        break;
      }
    }
    if (!seen_srv) unique_srvs++;
    D3D11QuadBatch *batch = &g_d3d11.quad_batches[i];
    if (!batch->srv || batch->count <= 0) continue;
    g_d3d11.context->lpVtbl->PSSetShaderResources(g_d3d11.context, 0, 1, &batch->srv);
    g_d3d11.context->lpVtbl->DrawInstanced(g_d3d11.context, 4, (UINT)batch->count, 0, (UINT)batch->start);
    g_d3d11.stats.frame.draw_calls++;
    g_d3d11.stats.frame.quad_draws++;
    g_d3d11.stats.frame.texture_draws++;
    submitted_instances += batch->count;
  }

  g_d3d11.stats.frame.quad_instances += submitted_instances;
  g_d3d11.stats.frame.quad_vertices += submitted_instances * 4;
  g_d3d11.stats.frame.quad_batches += g_d3d11.quad_batch_count;
  g_d3d11.stats.frame.unique_batch_srvs += unique_srvs;
  g_d3d11.stats.frame.repeated_batch_srvs += g_d3d11.quad_batch_count - unique_srvs;

  ID3D11ShaderResourceView *null_srv = NULL;
  g_d3d11.context->lpVtbl->PSSetShaderResources(g_d3d11.context, 0, 1, &null_srv);
  g_d3d11.quad_instance_count = 0;
  g_d3d11.quad_batch_count = 0;
  QueryPerformanceCounter(&t1);
  g_d3d11.stats.frame.flush_quads_ms += d3d11_ms_between(t0, t1);
  return true;
}

static bool d3d11_queue_quad(ID3D11ShaderResourceView *srv,
                             const D3D11QuadInstance *inst,
                             bool texture_dependent) {
  if (!srv || !inst) return false;

  D3D11QuadBatch *batch = g_d3d11.quad_batch_count > 0
    ? &g_d3d11.quad_batches[g_d3d11.quad_batch_count - 1]
    : NULL;
  if (batch && texture_dependent && batch->has_texture_dependent && batch->srv != srv) {
    g_d3d11.stats.frame.texture_batch_breaks++;
    batch = NULL;
  }
  if (!batch) {
    if (!d3d11_reserve_quad_batches(1)) return false;
    batch = &g_d3d11.quad_batches[g_d3d11.quad_batch_count++];
    batch->srv = srv;
    batch->start = g_d3d11.quad_instance_count;
    batch->count = 0;
    batch->has_texture_dependent = texture_dependent;
  } else if (texture_dependent && !batch->has_texture_dependent) {
    batch->srv = srv;
    batch->has_texture_dependent = true;
  }

  if (!d3d11_reserve_quad_instances(1)) return false;
  g_d3d11.quad_instances[g_d3d11.quad_instance_count++] = *inst;
  batch->count++;
  return true;
}

bool anvil_d3d11_push_texture(SDL_Window *window, SDL_Surface *surface,
                               RenRect src_px, RenRect dst_px, RenRect clip_px,
                               RenColor color, int mode) {
  if (window != g_d3d11.active_window || !surface) return false;
  if (color.a == 0) return true;
  if (!d3d11_ensure_quad_pipeline()) return false;

  LARGE_INTEGER t0, t1;
  QueryPerformanceCounter(&t0);

  RenRect clipped = d3d11_intersect_renrect(dst_px, clip_px);
  if (clipped.width <= 0 || clipped.height <= 0) { QueryPerformanceCounter(&t1); g_d3d11.stats.frame.glyph_push_ms += d3d11_ms_between(t0, t1); return true; }

  float dx0 = (float)dst_px.x;
  float dy0 = (float)dst_px.y;
  float dx1 = (float)(dst_px.x + dst_px.width);
  float dy1 = (float)(dst_px.y + dst_px.height);
  if (dx1 == dx0 || dy1 == dy0) { QueryPerformanceCounter(&t1); g_d3d11.stats.frame.glyph_push_ms += d3d11_ms_between(t0, t1); return true; }

  float sx0 = (float)src_px.x;
  float sy0 = (float)src_px.y;
  float sx1 = (float)(src_px.x + src_px.width);
  float sy1 = (float)(src_px.y + src_px.height);

  float cx0 = (float)clipped.x;
  float cy0 = (float)clipped.y;
  float cx1 = (float)(clipped.x + clipped.width);
  float cy1 = (float)(clipped.y + clipped.height);

  float u0 = (sx0 + (cx0 - dx0) * (sx1 - sx0) / (dx1 - dx0)) / (float)surface->w;
  float v0 = (sy0 + (cy0 - dy0) * (sy1 - sy0) / (dy1 - dy0)) / (float)surface->h;
  float u1 = (sx0 + (cx1 - dx0) * (sx1 - sx0) / (dx1 - dx0)) / (float)surface->w;
  float v1 = (sy0 + (cy1 - dy0) * (sy1 - sy0) / (dy1 - dy0)) / (float)surface->h;

  D3D11CachedTexture *tex = d3d11_get_cached_texture(surface, mode);
  if (!tex || !tex->srv) { QueryPerformanceCounter(&t1); g_d3d11.stats.frame.glyph_push_ms += d3d11_ms_between(t0, t1); return false; }
  g_d3d11.stats.frame.texture_quads++;

  float cr = color.r / 255.0f;
  float cg = color.g / 255.0f;
  float cb = color.b / 255.0f;
  float ca = color.a / 255.0f;
  D3D11QuadInstance inst = { cx0, cy0, cx1, cy1, u0, v0, u1, v1, cr, cg, cb, ca, (float)mode, 0, 0, 0 };

  bool result = d3d11_queue_quad(tex->srv, &inst, true);
  QueryPerformanceCounter(&t1);
  g_d3d11.stats.frame.glyph_push_ms += d3d11_ms_between(t0, t1);
  return result;
}

bool anvil_d3d11_push_pixels(SDL_Window *window, const char *bytes, size_t len,
                              int width, int height, int pitch,
                              RenRect dst_px, RenRect clip_px) {
  if (window != g_d3d11.active_window || !bytes || width <= 0 || height <= 0) return false;
  if (pitch < width * 4) return false;
  if (len < (size_t)pitch * (size_t)height) return false;
  if (!d3d11_ensure_quad_pipeline()) return false;
  if (!d3d11_ensure_upload_texture(width, height)) return false;
  if (!d3d11_flush_quads()) return false;

  RenRect src_px = { 0, 0, width, height };
  RenRect clipped = d3d11_intersect_renrect(dst_px, clip_px);
  if (clipped.width <= 0 || clipped.height <= 0) return true;

  float dx0 = (float)dst_px.x;
  float dy0 = (float)dst_px.y;
  float dx1 = (float)(dst_px.x + dst_px.width);
  float dy1 = (float)(dst_px.y + dst_px.height);
  if (dx1 == dx0 || dy1 == dy0) return true;

  float sx0 = (float)src_px.x;
  float sy0 = (float)src_px.y;
  float sx1 = (float)(src_px.x + src_px.width);
  float sy1 = (float)(src_px.y + src_px.height);

  float cx0 = (float)clipped.x;
  float cy0 = (float)clipped.y;
  float cx1 = (float)(clipped.x + clipped.width);
  float cy1 = (float)(clipped.y + clipped.height);

  float u0 = (sx0 + (cx0 - dx0) * (sx1 - sx0) / (dx1 - dx0)) / (float)width;
  float v0 = (sy0 + (cy0 - dy0) * (sy1 - sy0) / (dy1 - dy0)) / (float)height;
  float u1 = (sx0 + (cx1 - dx0) * (sx1 - sx0) / (dx1 - dx0)) / (float)width;
  float v1 = (sy0 + (cy1 - dy0) * (sy1 - sy0) / (dy1 - dy0)) / (float)height;

  g_d3d11.context->lpVtbl->UpdateSubresource(g_d3d11.context,
                                             (ID3D11Resource *)g_d3d11.upload_texture,
                                             0, NULL, bytes, (UINT)pitch, 0);
  g_d3d11.stats.frame.texture_uploads++;
  g_d3d11.stats.frame.texture_upload_bytes += (size_t)pitch * (size_t)height;
  g_d3d11.stats.frame.pixel_quads++;

  float cr = 1.0f, cg = 1.0f, cb = 1.0f, ca = 1.0f;
  D3D11QuadInstance inst = { cx0, cy0, cx1, cy1, u0, v0, u1, v1, cr, cg, cb, ca, 2.0f, 0, 0, 0 };

  if (!d3d11_queue_quad(g_d3d11.upload_srv, &inst, true)) return false;
  return d3d11_flush_quads();
}

void anvil_d3d11_abort_frame_reason(SDL_Window *window, const char *reason) {
  if (!window || window == g_d3d11.active_window) {
    g_d3d11.active_window = NULL;
    g_d3d11.quad_instance_count = 0;
    g_d3d11.quad_batch_count = 0;
    d3d11_stats_abort_reason(reason ? reason : "abort");
  }
}

void anvil_d3d11_abort_frame(SDL_Window *window) {
  anvil_d3d11_abort_frame_reason(window, "abort");
}

bool anvil_d3d11_end_frame(SDL_Window *window) {
  if (window != g_d3d11.active_window) return false;
  D3D11Window *w = d3d11_find_window(window);
  if (!w || !w->swapchain || !w->rtv) {
    anvil_d3d11_abort_frame_reason(window, "end_frame_no_window");
    return false;
  }

  if (!d3d11_flush_quads()) {
    anvil_d3d11_abort_frame_reason(window, "end_frame_flush_quads");
    return false;
  }

  LARGE_INTEGER present_start, present_end, dwm_start, dwm_end;
  UINT sync_interval = d3d11_present_sync_interval();
  if (anvil_resize_diag_live_resize() && d3d11_should_present_zero_live_resize()) sync_interval = 0;
  g_d3d11.stats.frame.sync_interval = (int)sync_interval;
  QueryPerformanceCounter(&present_start);
  HRESULT hr = w->swapchain->lpVtbl->Present(w->swapchain, sync_interval, 0);
  QueryPerformanceCounter(&present_end);
  g_d3d11.stats.frame.present_ms = d3d11_ms_between(present_start, present_end);
  g_d3d11.last_present_ms = g_d3d11.stats.frame.present_ms;
  g_d3d11.last_sync_interval = (int)sync_interval;
  g_d3d11.active_window = NULL;
  g_d3d11.quad_instance_count = 0;
  g_d3d11.quad_batch_count = 0;
  if (FAILED(hr)) {
    g_d3d11.stats.frame.fail_reason = "present";
    d3d11_stats_end(false, hr);
    if (d3d11_device_lost(hr)) {
      d3d11_reset_device();
    } else {
      anvil_d3d11_forget_window(window);
    }
    return false;
  }
  if (d3d11_should_dwm_flush()) {
    QueryPerformanceCounter(&dwm_start);
    DwmFlush();
    QueryPerformanceCounter(&dwm_end);
    g_d3d11.stats.frame.dwm_flush_ms = d3d11_ms_between(dwm_start, dwm_end);
  } else {
    g_d3d11.stats.frame.dwm_flush_ms = 0.0;
  }
  if (d3d11_should_clear_state_after_present()) {
    LARGE_INTEGER clear_start, clear_end;
    QueryPerformanceCounter(&clear_start);
    g_d3d11.context->lpVtbl->ClearState(g_d3d11.context);
    QueryPerformanceCounter(&clear_end);
    g_d3d11.stats.frame.clear_state_ms = d3d11_ms_between(clear_start, clear_end);
  }
  d3d11_stats_end(true, hr);
  return true;
}

bool anvil_d3d11_present(SDL_Window *window, SDL_Surface *surface,
                         float scale_x, float scale_y,
                         RenRect *rects, int rect_count) {
  if (!anvil_d3d11_enabled() || !window || !surface || !surface->pixels || rect_count <= 0) {
    return false;
  }
  if (!d3d11_init()) return false;

  int bpp = SDL_BYTESPERPIXEL(surface->format);
  if (bpp != 4) return false;

  int width = surface->w;
  int height = surface->h;
  if (width <= 0 || height <= 0) return false;

  D3D11Window *w = d3d11_get_or_create_window(window, width, height);
  if (!w) return false;
  d3d11_stats_begin("surface_upload", window, w, width, height);
  if (!d3d11_resize_window(w, width, height)) {
    g_d3d11.stats.frame.fail_reason = "surface_resize";
    d3d11_stats_end(false, g_d3d11.stats.frame.resize_hr);
    anvil_d3d11_forget_window(window);
    return false;
  }

  (void)scale_x;
  (void)scale_y;
  (void)rects;

  /* The swapchain uses flip-discard, so previous backbuffer contents are not
     preserved across presents. Upload the complete cached software surface for
     this bridge path; dirty-rect-only updates leave undefined regions. */
  g_d3d11.context->lpVtbl->UpdateSubresource(g_d3d11.context,
                                             (ID3D11Resource *)w->backbuffer,
                                             0, NULL, surface->pixels,
                                             (UINT)surface->pitch, 0);
  g_d3d11.stats.frame.texture_uploads++;
  g_d3d11.stats.frame.texture_upload_bytes += (size_t)surface->pitch * (size_t)height;

  LARGE_INTEGER present_start, present_end, dwm_start, dwm_end;
  QueryPerformanceCounter(&present_start);
  HRESULT hr = w->swapchain->lpVtbl->Present(w->swapchain, 1, 0);
  QueryPerformanceCounter(&present_end);
  g_d3d11.stats.frame.present_ms = d3d11_ms_between(present_start, present_end);
  g_d3d11.last_present_ms = g_d3d11.stats.frame.present_ms;
  g_d3d11.last_sync_interval = 1;
  if (FAILED(hr)) {
    g_d3d11.stats.frame.fail_reason = "surface_present";
    d3d11_stats_end(false, hr);
    if (d3d11_device_lost(hr)) {
      d3d11_reset_device();
    } else {
      anvil_d3d11_forget_window(window);
    }
    return false;
  }
  if (d3d11_should_dwm_flush()) {
    QueryPerformanceCounter(&dwm_start);
    DwmFlush();
    QueryPerformanceCounter(&dwm_end);
    g_d3d11.stats.frame.dwm_flush_ms = d3d11_ms_between(dwm_start, dwm_end);
  } else {
    g_d3d11.stats.frame.dwm_flush_ms = 0.0;
  }
  if (d3d11_should_clear_state_after_present()) {
    LARGE_INTEGER clear_start, clear_end;
    QueryPerformanceCounter(&clear_start);
    g_d3d11.context->lpVtbl->ClearState(g_d3d11.context);
    QueryPerformanceCounter(&clear_end);
    g_d3d11.stats.frame.clear_state_ms = d3d11_ms_between(clear_start, clear_end);
  }
  d3d11_stats_end(true, hr);
  return true;
}

void anvil_d3d11_shutdown(void) {
  D3D11Window *w = g_d3d11.windows;
  while (w) {
    D3D11Window *next = w->next;
    d3d11_destroy_window(w);
    w = next;
  }
  g_d3d11.windows = NULL;
  D3D11CachedTexture *tex = g_d3d11.textures;
  while (tex) {
    D3D11CachedTexture *next = tex->next;
    d3d11_release_cached_texture(tex);
    free(tex);
    tex = next;
  }
  g_d3d11.textures = NULL;
  d3d11_release_white_texture();
  d3d11_release_upload_texture();
  free(g_d3d11.texture_upload_scratch);
  g_d3d11.texture_upload_scratch = NULL;
  g_d3d11.texture_upload_scratch_capacity = 0;
  SAFE_RELEASE(g_d3d11.quad_sampler);
  SAFE_RELEASE(g_d3d11.quad_cbuf);
  SAFE_RELEASE(g_d3d11.quad_vbuf);
  g_d3d11.quad_instance_buffer_capacity = 0;
  SAFE_RELEASE(g_d3d11.quad_layout);
  SAFE_RELEASE(g_d3d11.quad_ps);
  SAFE_RELEASE(g_d3d11.quad_vs);
  SAFE_RELEASE(g_d3d11.raster);
  SAFE_RELEASE(g_d3d11.blend);
  free(g_d3d11.quad_instances);
  g_d3d11.quad_instances = NULL;
  g_d3d11.quad_instance_count = 0;
  g_d3d11.quad_instance_capacity = 0;
  g_d3d11.quad_instance_buffer_capacity = 0;
  free(g_d3d11.quad_batches);
  g_d3d11.quad_batches = NULL;
  g_d3d11.quad_batch_count = 0;
  g_d3d11.quad_batch_capacity = 0;
  g_d3d11.active_window = NULL;
  SAFE_RELEASE(g_d3d11.factory);
  SAFE_RELEASE(g_d3d11.context);
  SAFE_RELEASE(g_d3d11.device);
  g_d3d11.adapter_name[0] = 0;
  g_d3d11.feature_level = 0;
  g_d3d11.device_is_warp = false;
  g_d3d11.available = false;
}

#endif
