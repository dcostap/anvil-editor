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
#include <stdlib.h>
#include <string.h>
#include "d3d11_backend.h"

#ifndef SAFE_RELEASE
#define SAFE_RELEASE(p) do { if (p) { (p)->lpVtbl->Release(p); (p) = NULL; } } while (0)
#endif

typedef struct D3D11RectVertex {
  float x, y;
  float r, g, b, a;
} D3D11RectVertex;

typedef struct D3D11RectConstants {
  float width;
  float height;
  float pad0;
  float pad1;
} D3D11RectConstants;

typedef struct D3D11TextureVertex {
  float x, y;
  float u, v;
  float r, g, b, a;
} D3D11TextureVertex;

typedef struct D3D11TextureConstants {
  float width;
  float height;
  float mode;
  float pad0;
} D3D11TextureConstants;

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
};

typedef struct D3D11State {
  bool attempted_init;
  bool available;
  ID3D11Device *device;
  ID3D11DeviceContext *context;
  IDXGIFactory2 *factory;
  ID3D11VertexShader *rect_vs;
  ID3D11PixelShader *rect_ps;
  ID3D11InputLayout *rect_layout;
  ID3D11Buffer *rect_vbuf;
  ID3D11Buffer *rect_cbuf;
  ID3D11BlendState *rect_blend;
  ID3D11RasterizerState *rect_raster;
  D3D11RectVertex *rect_vertices;
  int rect_vertex_count;
  int rect_vertex_capacity;
  int rect_vbuf_capacity;
  SDL_Window *rect_active_window;
  ID3D11VertexShader *tex_vs;
  ID3D11PixelShader *tex_ps;
  ID3D11InputLayout *tex_layout;
  ID3D11Buffer *tex_vbuf;
  ID3D11Buffer *tex_cbuf;
  ID3D11SamplerState *tex_sampler;
  ID3D11Texture2D *upload_texture;
  ID3D11ShaderResourceView *upload_srv;
  int upload_width;
  int upload_height;
  D3D11CachedTexture *textures;
  uint64_t frame_index;
  D3D11Window *windows;
} D3D11State;

static D3D11State g_d3d11;

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

static const char *rect_shader_source =
  "cbuffer RectConstants : register(b0) { float2 viewport; float2 _pad; };\n"
  "struct VSIn { float2 pos : POSITION; float4 color : COLOR0; };\n"
  "struct VSOut { float4 pos : SV_Position; float4 color : COLOR0; };\n"
  "VSOut vs_main(VSIn input) {\n"
  "  VSOut output;\n"
  "  float2 p = float2((input.pos.x / viewport.x) * 2.0f - 1.0f, 1.0f - (input.pos.y / viewport.y) * 2.0f);\n"
  "  output.pos = float4(p, 0.0f, 1.0f);\n"
  "  output.color = input.color;\n"
  "  return output;\n"
  "}\n"
  "float4 ps_main(VSOut input) : SV_Target { return input.color; }\n";

static const char *texture_shader_source =
  "Texture2D tex0 : register(t0);\n"
  "SamplerState smp0 : register(s0);\n"
  "cbuffer TextureConstants : register(b0) { float2 viewport; float mode; float _pad; };\n"
  "struct VSIn { float2 pos : POSITION; float2 uv : TEXCOORD0; float4 color : COLOR0; };\n"
  "struct VSOut { float4 pos : SV_Position; float2 uv : TEXCOORD0; float4 color : COLOR0; };\n"
  "VSOut vs_main(VSIn input) {\n"
  "  VSOut output;\n"
  "  float2 p = float2((input.pos.x / viewport.x) * 2.0f - 1.0f, 1.0f - (input.pos.y / viewport.y) * 2.0f);\n"
  "  output.pos = float4(p, 0.0f, 1.0f);\n"
  "  output.uv = input.uv;\n"
  "  output.color = input.color;\n"
  "  return output;\n"
  "}\n"
  "float4 ps_main(VSOut input) : SV_Target {\n"
  "  float4 s = tex0.Sample(smp0, input.uv);\n"
  "  if (mode < 0.5f) { return float4(input.color.rgb, input.color.a * s.r); }\n"
  "  if (mode < 1.5f) { float a = max(s.r, max(s.g, s.b)); return float4(input.color.rgb * s.rgb, input.color.a * a); }\n"
  "  return float4(s.rgb * input.color.rgb, s.a * input.color.a);\n"
  "}\n";

bool anvil_d3d11_enabled(void) {
  const char *value = getenv("ANVIL_D3D11");
  if (value && (value[0] == '0' || value[0] == 'n' || value[0] == 'N' || value[0] == 'f' || value[0] == 'F')) {
    return false;
  }
  return true;
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

  HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, flags,
                                 levels, (UINT)(sizeof(levels) / sizeof(levels[0])),
                                 D3D11_SDK_VERSION,
                                 &g_d3d11.device, &selected, &g_d3d11.context);
  if (FAILED(hr)) {
    hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_WARP, NULL, flags,
                           levels, (UINT)(sizeof(levels) / sizeof(levels[0])),
                           D3D11_SDK_VERSION,
                           &g_d3d11.device, &selected, &g_d3d11.context);
  }
  if (FAILED(hr)) return false;

  IDXGIDevice *dxgi_device = NULL;
  IDXGIAdapter *adapter = NULL;
  hr = g_d3d11.device->lpVtbl->QueryInterface(g_d3d11.device, &IID_IDXGIDevice, (void **)&dxgi_device);
  if (SUCCEEDED(hr)) {
    hr = dxgi_device->lpVtbl->GetAdapter(dxgi_device, &adapter);
  }
  if (SUCCEEDED(hr)) {
    hr = adapter->lpVtbl->GetParent(adapter, &IID_IDXGIFactory2, (void **)&g_d3d11.factory);
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

static bool d3d11_ensure_rect_pipeline(void) {
  if (g_d3d11.rect_vs && g_d3d11.rect_ps && g_d3d11.rect_layout &&
      g_d3d11.rect_vbuf && g_d3d11.rect_cbuf && g_d3d11.rect_blend &&
      g_d3d11.rect_raster) {
    return true;
  }

  ID3DBlob *vs_blob = NULL;
  ID3DBlob *ps_blob = NULL;
  ID3DBlob *errors = NULL;
  UINT flags = D3DCOMPILE_ENABLE_STRICTNESS;

  HRESULT hr = D3DCompile(rect_shader_source, strlen(rect_shader_source),
                          "anvil_rect_shader", NULL, NULL, "vs_main", "vs_4_0",
                          flags, 0, &vs_blob, &errors);
  SAFE_RELEASE(errors);
  if (FAILED(hr) || !vs_blob) goto fail;

  hr = D3DCompile(rect_shader_source, strlen(rect_shader_source),
                  "anvil_rect_shader", NULL, NULL, "ps_main", "ps_4_0",
                  flags, 0, &ps_blob, &errors);
  SAFE_RELEASE(errors);
  if (FAILED(hr) || !ps_blob) goto fail;

  hr = g_d3d11.device->lpVtbl->CreateVertexShader(g_d3d11.device,
                                                   vs_blob->lpVtbl->GetBufferPointer(vs_blob),
                                                   vs_blob->lpVtbl->GetBufferSize(vs_blob),
                                                   NULL, &g_d3d11.rect_vs);
  if (FAILED(hr)) goto fail;

  hr = g_d3d11.device->lpVtbl->CreatePixelShader(g_d3d11.device,
                                                  ps_blob->lpVtbl->GetBufferPointer(ps_blob),
                                                  ps_blob->lpVtbl->GetBufferSize(ps_blob),
                                                  NULL, &g_d3d11.rect_ps);
  if (FAILED(hr)) goto fail;

  D3D11_INPUT_ELEMENT_DESC layout[] = {
    { "POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0 },
    { "COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 8, D3D11_INPUT_PER_VERTEX_DATA, 0 },
  };
  hr = g_d3d11.device->lpVtbl->CreateInputLayout(g_d3d11.device, layout, 2,
                                                  vs_blob->lpVtbl->GetBufferPointer(vs_blob),
                                                  vs_blob->lpVtbl->GetBufferSize(vs_blob),
                                                  &g_d3d11.rect_layout);
  if (FAILED(hr)) goto fail;

  g_d3d11.rect_vbuf_capacity = 65536;
  D3D11_BUFFER_DESC vdesc;
  memset(&vdesc, 0, sizeof(vdesc));
  vdesc.ByteWidth = (UINT)(sizeof(D3D11RectVertex) * g_d3d11.rect_vbuf_capacity);
  vdesc.Usage = D3D11_USAGE_DYNAMIC;
  vdesc.BindFlags = D3D11_BIND_VERTEX_BUFFER;
  vdesc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
  hr = g_d3d11.device->lpVtbl->CreateBuffer(g_d3d11.device, &vdesc, NULL, &g_d3d11.rect_vbuf);
  if (FAILED(hr)) goto fail;

  D3D11_BUFFER_DESC cdesc;
  memset(&cdesc, 0, sizeof(cdesc));
  cdesc.ByteWidth = sizeof(D3D11RectConstants);
  cdesc.Usage = D3D11_USAGE_DEFAULT;
  cdesc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
  hr = g_d3d11.device->lpVtbl->CreateBuffer(g_d3d11.device, &cdesc, NULL, &g_d3d11.rect_cbuf);
  if (FAILED(hr)) goto fail;

  D3D11_BLEND_DESC bdesc;
  memset(&bdesc, 0, sizeof(bdesc));
  bdesc.RenderTarget[0].BlendEnable = TRUE;
  bdesc.RenderTarget[0].SrcBlend = D3D11_BLEND_SRC_ALPHA;
  bdesc.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
  bdesc.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
  bdesc.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
  bdesc.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
  bdesc.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
  bdesc.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
  hr = g_d3d11.device->lpVtbl->CreateBlendState(g_d3d11.device, &bdesc, &g_d3d11.rect_blend);
  if (FAILED(hr)) goto fail;

  D3D11_RASTERIZER_DESC rdesc;
  memset(&rdesc, 0, sizeof(rdesc));
  rdesc.FillMode = D3D11_FILL_SOLID;
  rdesc.CullMode = D3D11_CULL_NONE;
  rdesc.ScissorEnable = TRUE;
  rdesc.DepthClipEnable = TRUE;
  hr = g_d3d11.device->lpVtbl->CreateRasterizerState(g_d3d11.device, &rdesc, &g_d3d11.rect_raster);
  if (FAILED(hr)) goto fail;

  SAFE_RELEASE(ps_blob);
  SAFE_RELEASE(vs_blob);
  return true;

fail:
  SAFE_RELEASE(errors);
  SAFE_RELEASE(ps_blob);
  SAFE_RELEASE(vs_blob);
  SAFE_RELEASE(g_d3d11.rect_raster);
  SAFE_RELEASE(g_d3d11.rect_blend);
  SAFE_RELEASE(g_d3d11.rect_cbuf);
  SAFE_RELEASE(g_d3d11.rect_vbuf);
  SAFE_RELEASE(g_d3d11.rect_layout);
  SAFE_RELEASE(g_d3d11.rect_ps);
  SAFE_RELEASE(g_d3d11.rect_vs);
  g_d3d11.rect_vbuf_capacity = 0;
  return false;
}

static bool d3d11_ensure_texture_pipeline(void) {
  if (g_d3d11.tex_vs && g_d3d11.tex_ps && g_d3d11.tex_layout &&
      g_d3d11.tex_vbuf && g_d3d11.tex_cbuf && g_d3d11.tex_sampler) {
    return true;
  }

  ID3DBlob *vs_blob = NULL;
  ID3DBlob *ps_blob = NULL;
  ID3DBlob *errors = NULL;
  UINT flags = D3DCOMPILE_ENABLE_STRICTNESS;

  HRESULT hr = D3DCompile(texture_shader_source, strlen(texture_shader_source),
                          "anvil_texture_shader", NULL, NULL, "vs_main", "vs_4_0",
                          flags, 0, &vs_blob, &errors);
  SAFE_RELEASE(errors);
  if (FAILED(hr) || !vs_blob) goto fail;

  hr = D3DCompile(texture_shader_source, strlen(texture_shader_source),
                  "anvil_texture_shader", NULL, NULL, "ps_main", "ps_4_0",
                  flags, 0, &ps_blob, &errors);
  SAFE_RELEASE(errors);
  if (FAILED(hr) || !ps_blob) goto fail;

  hr = g_d3d11.device->lpVtbl->CreateVertexShader(g_d3d11.device,
                                                   vs_blob->lpVtbl->GetBufferPointer(vs_blob),
                                                   vs_blob->lpVtbl->GetBufferSize(vs_blob),
                                                   NULL, &g_d3d11.tex_vs);
  if (FAILED(hr)) goto fail;

  hr = g_d3d11.device->lpVtbl->CreatePixelShader(g_d3d11.device,
                                                  ps_blob->lpVtbl->GetBufferPointer(ps_blob),
                                                  ps_blob->lpVtbl->GetBufferSize(ps_blob),
                                                  NULL, &g_d3d11.tex_ps);
  if (FAILED(hr)) goto fail;

  D3D11_INPUT_ELEMENT_DESC layout[] = {
    { "POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0 },
    { "TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 8, D3D11_INPUT_PER_VERTEX_DATA, 0 },
    { "COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 16, D3D11_INPUT_PER_VERTEX_DATA, 0 },
  };
  hr = g_d3d11.device->lpVtbl->CreateInputLayout(g_d3d11.device, layout, 3,
                                                  vs_blob->lpVtbl->GetBufferPointer(vs_blob),
                                                  vs_blob->lpVtbl->GetBufferSize(vs_blob),
                                                  &g_d3d11.tex_layout);
  if (FAILED(hr)) goto fail;

  D3D11_BUFFER_DESC vdesc;
  memset(&vdesc, 0, sizeof(vdesc));
  vdesc.ByteWidth = (UINT)(sizeof(D3D11TextureVertex) * 6);
  vdesc.Usage = D3D11_USAGE_DYNAMIC;
  vdesc.BindFlags = D3D11_BIND_VERTEX_BUFFER;
  vdesc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
  hr = g_d3d11.device->lpVtbl->CreateBuffer(g_d3d11.device, &vdesc, NULL, &g_d3d11.tex_vbuf);
  if (FAILED(hr)) goto fail;

  D3D11_BUFFER_DESC cdesc;
  memset(&cdesc, 0, sizeof(cdesc));
  cdesc.ByteWidth = sizeof(D3D11TextureConstants);
  cdesc.Usage = D3D11_USAGE_DEFAULT;
  cdesc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
  hr = g_d3d11.device->lpVtbl->CreateBuffer(g_d3d11.device, &cdesc, NULL, &g_d3d11.tex_cbuf);
  if (FAILED(hr)) goto fail;

  D3D11_SAMPLER_DESC sdesc;
  memset(&sdesc, 0, sizeof(sdesc));
  sdesc.Filter = D3D11_FILTER_MIN_MAG_MIP_POINT;
  sdesc.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
  sdesc.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
  sdesc.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
  sdesc.MaxLOD = D3D11_FLOAT32_MAX;
  hr = g_d3d11.device->lpVtbl->CreateSamplerState(g_d3d11.device, &sdesc, &g_d3d11.tex_sampler);
  if (FAILED(hr)) goto fail;

  SAFE_RELEASE(ps_blob);
  SAFE_RELEASE(vs_blob);
  return true;

fail:
  SAFE_RELEASE(errors);
  SAFE_RELEASE(ps_blob);
  SAFE_RELEASE(vs_blob);
  SAFE_RELEASE(g_d3d11.tex_sampler);
  SAFE_RELEASE(g_d3d11.tex_cbuf);
  SAFE_RELEASE(g_d3d11.tex_vbuf);
  SAFE_RELEASE(g_d3d11.tex_layout);
  SAFE_RELEASE(g_d3d11.tex_ps);
  SAFE_RELEASE(g_d3d11.tex_vs);
  return false;
}

static D3D11Window *d3d11_find_window(SDL_Window *window) {
  for (D3D11Window *w = g_d3d11.windows; w; w = w->next) {
    if (w->window == window) return w;
  }
  return NULL;
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
      continue;
    }
    link = &t->next;
  }
}

static bool d3d11_get_backbuffer(D3D11Window *w) {
  d3d11_release_window_buffers(w);
  HRESULT hr = w->swapchain->lpVtbl->GetBuffer(w->swapchain, 0, &IID_ID3D11Texture2D, (void **)&w->backbuffer);
  if (FAILED(hr) || !w->backbuffer) {
    if (d3d11_device_lost(hr)) d3d11_reset_device();
    return false;
  }
  hr = g_d3d11.device->lpVtbl->CreateRenderTargetView(g_d3d11.device,
                                                       (ID3D11Resource *)w->backbuffer,
                                                       NULL, &w->rtv);
  if (FAILED(hr) || !w->rtv) {
    if (d3d11_device_lost(hr)) d3d11_reset_device();
    return false;
  }
  return true;
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
  desc.Width = (UINT)width;
  desc.Height = (UINT)height;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.Stereo = FALSE;
  desc.SampleDesc.Count = 1;
  desc.SampleDesc.Quality = 0;
  desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
  desc.BufferCount = 2;
  desc.Scaling = DXGI_SCALING_STRETCH;
  desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
  desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;

  HRESULT hr = g_d3d11.factory->lpVtbl->CreateSwapChainForHwnd(
    g_d3d11.factory, (IUnknown *)g_d3d11.device, hwnd, &desc, NULL, NULL, &w->swapchain);
  if (FAILED(hr)) {
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
  if (w->width == width && w->height == height && w->backbuffer) return true;

  d3d11_release_window_buffers(w);
  HRESULT hr = w->swapchain->lpVtbl->ResizeBuffers(w->swapchain, 0, (UINT)width, (UINT)height, DXGI_FORMAT_UNKNOWN, 0);
  if (FAILED(hr)) {
    if (d3d11_device_lost(hr)) d3d11_reset_device();
    return false;
  }

  w->width = width;
  w->height = height;
  return d3d11_get_backbuffer(w);
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

static bool d3d11_reserve_rect_vertices(int extra) {
  int needed = g_d3d11.rect_vertex_count + extra;
  if (needed <= g_d3d11.rect_vertex_capacity) return true;

  int new_capacity = g_d3d11.rect_vertex_capacity ? g_d3d11.rect_vertex_capacity * 2 : 4096;
  while (new_capacity < needed) new_capacity *= 2;
  D3D11RectVertex *new_vertices = (D3D11RectVertex *)realloc(g_d3d11.rect_vertices,
                                                              sizeof(D3D11RectVertex) * (size_t)new_capacity);
  if (!new_vertices) return false;
  g_d3d11.rect_vertices = new_vertices;
  g_d3d11.rect_vertex_capacity = new_capacity;
  return true;
}

static bool d3d11_ensure_vertex_buffer_capacity(int vertex_count) {
  if (vertex_count <= g_d3d11.rect_vbuf_capacity) return true;

  SAFE_RELEASE(g_d3d11.rect_vbuf);
  int new_capacity = g_d3d11.rect_vbuf_capacity ? g_d3d11.rect_vbuf_capacity * 2 : 65536;
  while (new_capacity < vertex_count) new_capacity *= 2;

  D3D11_BUFFER_DESC vdesc;
  memset(&vdesc, 0, sizeof(vdesc));
  vdesc.ByteWidth = (UINT)(sizeof(D3D11RectVertex) * (size_t)new_capacity);
  vdesc.Usage = D3D11_USAGE_DYNAMIC;
  vdesc.BindFlags = D3D11_BIND_VERTEX_BUFFER;
  vdesc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
  HRESULT hr = g_d3d11.device->lpVtbl->CreateBuffer(g_d3d11.device, &vdesc, NULL, &g_d3d11.rect_vbuf);
  if (FAILED(hr)) return false;
  g_d3d11.rect_vbuf_capacity = new_capacity;
  return true;
}

bool anvil_d3d11_begin_frame(SDL_Window *window, int width, int height, RenColor clear_color) {
  if (!anvil_d3d11_enabled() || !window || width <= 0 || height <= 0) return false;
  if (!d3d11_init() || !d3d11_ensure_rect_pipeline()) return false;

  D3D11Window *w = d3d11_get_or_create_window(window, width, height);
  if (!w) return false;
  if (!d3d11_resize_window(w, width, height)) {
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

  D3D11RectConstants constants = { (float)width, (float)height, 0.0f, 0.0f };
  g_d3d11.context->lpVtbl->UpdateSubresource(g_d3d11.context,
                                             (ID3D11Resource *)g_d3d11.rect_cbuf,
                                             0, NULL, &constants, 0, 0);

  g_d3d11.frame_index++;
  if (g_d3d11.frame_index == 0) g_d3d11.frame_index = 1;
  if ((g_d3d11.frame_index % 120u) == 0) {
    d3d11_prune_texture_cache(600u);
  }
  g_d3d11.rect_vertex_count = 0;
  g_d3d11.rect_active_window = window;
  return true;
}

bool anvil_d3d11_push_rect(SDL_Window *window, RenRect rect, RenRect clip, RenColor color) {
  if (window != g_d3d11.rect_active_window || color.a == 0) return false;
  RenRect r = d3d11_intersect_renrect(rect, clip);
  if (r.width <= 0 || r.height <= 0) return true;
  if (!d3d11_reserve_rect_vertices(6)) return false;

  float x0 = (float)r.x;
  float y0 = (float)r.y;
  float x1 = (float)(r.x + r.width);
  float y1 = (float)(r.y + r.height);
  float cr = color.r / 255.0f;
  float cg = color.g / 255.0f;
  float cb = color.b / 255.0f;
  float ca = color.a / 255.0f;

  D3D11RectVertex v[6] = {
    { x0, y0, cr, cg, cb, ca }, { x1, y0, cr, cg, cb, ca }, { x1, y1, cr, cg, cb, ca },
    { x0, y0, cr, cg, cb, ca }, { x1, y1, cr, cg, cb, ca }, { x0, y1, cr, cg, cb, ca },
  };
  memcpy(&g_d3d11.rect_vertices[g_d3d11.rect_vertex_count], v, sizeof(v));
  g_d3d11.rect_vertex_count += 6;
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
  return SUCCEEDED(hr) && t->srv != NULL;
}

static bool d3d11_update_cached_texture(D3D11CachedTexture *t, SDL_Surface *surface, int mode) {
  if (!surface || !surface->pixels || surface->w <= 0 || surface->h <= 0) return false;
  if (!t->texture || t->width != surface->w || t->height != surface->h ||
      t->format != surface->format || t->mode != mode) {
    if (!d3d11_recreate_cached_texture(t, surface, mode)) return false;
  }
  SDL_PropertiesID props = SDL_GetSurfaceProperties(surface);
  Sint64 generation = SDL_GetNumberProperty(props, "anvil_d3d11_generation", -1);
  uint64_t update_key = generation >= 0 ? (uint64_t)generation : g_d3d11.frame_index;
  if (t->last_update_frame == update_key) return true;

  const int width = surface->w;
  const int height = surface->h;
  uint8_t *rgba = (uint8_t *)malloc((size_t)width * (size_t)height * 4u);
  if (!rgba) return false;

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
        dst[0] = bpp > 2 ? p[2] : 255;
        dst[1] = bpp > 1 ? p[1] : 255;
        dst[2] = bpp > 0 ? p[0] : 255;
        dst[3] = bpp > 3 ? p[3] : 255;
      }
    }
  }

  g_d3d11.context->lpVtbl->UpdateSubresource(g_d3d11.context,
                                             (ID3D11Resource *)t->texture,
                                             0, NULL, rgba, (UINT)(width * 4), 0);
  free(rgba);
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

static bool d3d11_flush_rects(void) {
  if (g_d3d11.rect_vertex_count <= 0) return true;
  D3D11Window *w = d3d11_find_window(g_d3d11.rect_active_window);
  if (!w || !w->rtv) return false;
  if (!d3d11_ensure_vertex_buffer_capacity(g_d3d11.rect_vertex_count)) return false;

  g_d3d11.context->lpVtbl->OMSetRenderTargets(g_d3d11.context, 1, &w->rtv, NULL);
  D3D11_VIEWPORT viewport;
  memset(&viewport, 0, sizeof(viewport));
  viewport.TopLeftX = 0.0f;
  viewport.TopLeftY = 0.0f;
  viewport.Width = (FLOAT)w->width;
  viewport.Height = (FLOAT)w->height;
  viewport.MinDepth = 0.0f;
  viewport.MaxDepth = 1.0f;
  g_d3d11.context->lpVtbl->RSSetViewports(g_d3d11.context, 1, &viewport);
  D3D11_RECT scissor = { 0, 0, w->width, w->height };
  g_d3d11.context->lpVtbl->RSSetScissorRects(g_d3d11.context, 1, &scissor);

  D3D11_MAPPED_SUBRESOURCE mapped;
  HRESULT hr = g_d3d11.context->lpVtbl->Map(g_d3d11.context,
                                            (ID3D11Resource *)g_d3d11.rect_vbuf,
                                            0, D3D11_MAP_WRITE_DISCARD, 0, &mapped);
  if (FAILED(hr)) return false;
  memcpy(mapped.pData, g_d3d11.rect_vertices,
         sizeof(D3D11RectVertex) * (size_t)g_d3d11.rect_vertex_count);
  g_d3d11.context->lpVtbl->Unmap(g_d3d11.context, (ID3D11Resource *)g_d3d11.rect_vbuf, 0);

  UINT stride = sizeof(D3D11RectVertex);
  UINT offset = 0;
  FLOAT blend_factor[4] = {0, 0, 0, 0};
  g_d3d11.context->lpVtbl->IASetInputLayout(g_d3d11.context, g_d3d11.rect_layout);
  g_d3d11.context->lpVtbl->IASetPrimitiveTopology(g_d3d11.context, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  g_d3d11.context->lpVtbl->IASetVertexBuffers(g_d3d11.context, 0, 1, &g_d3d11.rect_vbuf, &stride, &offset);
  g_d3d11.context->lpVtbl->VSSetShader(g_d3d11.context, g_d3d11.rect_vs, NULL, 0);
  g_d3d11.context->lpVtbl->VSSetConstantBuffers(g_d3d11.context, 0, 1, &g_d3d11.rect_cbuf);
  g_d3d11.context->lpVtbl->PSSetShader(g_d3d11.context, g_d3d11.rect_ps, NULL, 0);
  g_d3d11.context->lpVtbl->RSSetState(g_d3d11.context, g_d3d11.rect_raster);
  g_d3d11.context->lpVtbl->OMSetBlendState(g_d3d11.context, g_d3d11.rect_blend, blend_factor, 0xffffffffu);
  g_d3d11.context->lpVtbl->Draw(g_d3d11.context, (UINT)g_d3d11.rect_vertex_count, 0);
  g_d3d11.rect_vertex_count = 0;
  return true;
}

bool anvil_d3d11_push_texture(SDL_Window *window, SDL_Surface *surface,
                               RenRect src_px, RenRect dst_px, RenRect clip_px,
                               RenColor color, int mode) {
  if (window != g_d3d11.rect_active_window || !surface || color.a == 0) return false;
  if (!d3d11_ensure_texture_pipeline()) return false;
  if (!d3d11_flush_rects()) return false;

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

  float u0 = (sx0 + (cx0 - dx0) * (sx1 - sx0) / (dx1 - dx0)) / (float)surface->w;
  float v0 = (sy0 + (cy0 - dy0) * (sy1 - sy0) / (dy1 - dy0)) / (float)surface->h;
  float u1 = (sx0 + (cx1 - dx0) * (sx1 - sx0) / (dx1 - dx0)) / (float)surface->w;
  float v1 = (sy0 + (cy1 - dy0) * (sy1 - sy0) / (dy1 - dy0)) / (float)surface->h;

  D3D11CachedTexture *tex = d3d11_get_cached_texture(surface, mode);
  if (!tex || !tex->srv) return false;

  float cr = color.r / 255.0f;
  float cg = color.g / 255.0f;
  float cb = color.b / 255.0f;
  float ca = color.a / 255.0f;
  D3D11TextureVertex verts[6] = {
    { cx0, cy0, u0, v0, cr, cg, cb, ca }, { cx1, cy0, u1, v0, cr, cg, cb, ca }, { cx1, cy1, u1, v1, cr, cg, cb, ca },
    { cx0, cy0, u0, v0, cr, cg, cb, ca }, { cx1, cy1, u1, v1, cr, cg, cb, ca }, { cx0, cy1, u0, v1, cr, cg, cb, ca },
  };

  D3D11_MAPPED_SUBRESOURCE mapped;
  HRESULT hr = g_d3d11.context->lpVtbl->Map(g_d3d11.context,
                                            (ID3D11Resource *)g_d3d11.tex_vbuf,
                                            0, D3D11_MAP_WRITE_DISCARD, 0, &mapped);
  if (FAILED(hr)) return false;
  memcpy(mapped.pData, verts, sizeof(verts));
  g_d3d11.context->lpVtbl->Unmap(g_d3d11.context, (ID3D11Resource *)g_d3d11.tex_vbuf, 0);

  D3D11Window *w = d3d11_find_window(window);
  if (!w || !w->rtv) return false;
  g_d3d11.context->lpVtbl->OMSetRenderTargets(g_d3d11.context, 1, &w->rtv, NULL);

  D3D11TextureConstants constants = { (float)w->width, (float)w->height, (float)mode, 0.0f };
  g_d3d11.context->lpVtbl->UpdateSubresource(g_d3d11.context,
                                             (ID3D11Resource *)g_d3d11.tex_cbuf,
                                             0, NULL, &constants, 0, 0);

  UINT stride = sizeof(D3D11TextureVertex);
  UINT offset = 0;
  FLOAT blend_factor[4] = {0, 0, 0, 0};
  g_d3d11.context->lpVtbl->IASetInputLayout(g_d3d11.context, g_d3d11.tex_layout);
  g_d3d11.context->lpVtbl->IASetPrimitiveTopology(g_d3d11.context, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  g_d3d11.context->lpVtbl->IASetVertexBuffers(g_d3d11.context, 0, 1, &g_d3d11.tex_vbuf, &stride, &offset);
  g_d3d11.context->lpVtbl->VSSetShader(g_d3d11.context, g_d3d11.tex_vs, NULL, 0);
  g_d3d11.context->lpVtbl->VSSetConstantBuffers(g_d3d11.context, 0, 1, &g_d3d11.tex_cbuf);
  g_d3d11.context->lpVtbl->PSSetShader(g_d3d11.context, g_d3d11.tex_ps, NULL, 0);
  g_d3d11.context->lpVtbl->PSSetShaderResources(g_d3d11.context, 0, 1, &tex->srv);
  g_d3d11.context->lpVtbl->PSSetSamplers(g_d3d11.context, 0, 1, &g_d3d11.tex_sampler);
  g_d3d11.context->lpVtbl->RSSetState(g_d3d11.context, g_d3d11.rect_raster);
  g_d3d11.context->lpVtbl->OMSetBlendState(g_d3d11.context, g_d3d11.rect_blend, blend_factor, 0xffffffffu);
  g_d3d11.context->lpVtbl->Draw(g_d3d11.context, 6, 0);

  ID3D11ShaderResourceView *null_srv = NULL;
  g_d3d11.context->lpVtbl->PSSetShaderResources(g_d3d11.context, 0, 1, &null_srv);
  return true;
}

bool anvil_d3d11_push_pixels(SDL_Window *window, const char *bytes, size_t len,
                              int width, int height, int pitch,
                              RenRect dst_px, RenRect clip_px) {
  if (window != g_d3d11.rect_active_window || !bytes || width <= 0 || height <= 0) return false;
  if (pitch < width * 4) return false;
  if (len < (size_t)pitch * (size_t)height) return false;
  if (!d3d11_ensure_texture_pipeline()) return false;
  if (!d3d11_ensure_upload_texture(width, height)) return false;
  if (!d3d11_flush_rects()) return false;

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

  float cr = 1.0f, cg = 1.0f, cb = 1.0f, ca = 1.0f;
  D3D11TextureVertex verts[6] = {
    { cx0, cy0, u0, v0, cr, cg, cb, ca }, { cx1, cy0, u1, v0, cr, cg, cb, ca }, { cx1, cy1, u1, v1, cr, cg, cb, ca },
    { cx0, cy0, u0, v0, cr, cg, cb, ca }, { cx1, cy1, u1, v1, cr, cg, cb, ca }, { cx0, cy1, u0, v1, cr, cg, cb, ca },
  };

  D3D11_MAPPED_SUBRESOURCE mapped;
  HRESULT hr = g_d3d11.context->lpVtbl->Map(g_d3d11.context,
                                            (ID3D11Resource *)g_d3d11.tex_vbuf,
                                            0, D3D11_MAP_WRITE_DISCARD, 0, &mapped);
  if (FAILED(hr)) return false;
  memcpy(mapped.pData, verts, sizeof(verts));
  g_d3d11.context->lpVtbl->Unmap(g_d3d11.context, (ID3D11Resource *)g_d3d11.tex_vbuf, 0);

  D3D11Window *w = d3d11_find_window(window);
  if (!w || !w->rtv) return false;
  g_d3d11.context->lpVtbl->OMSetRenderTargets(g_d3d11.context, 1, &w->rtv, NULL);
  D3D11TextureConstants constants = { (float)w->width, (float)w->height, 2.0f, 0.0f };
  g_d3d11.context->lpVtbl->UpdateSubresource(g_d3d11.context,
                                             (ID3D11Resource *)g_d3d11.tex_cbuf,
                                             0, NULL, &constants, 0, 0);

  UINT stride = sizeof(D3D11TextureVertex);
  UINT offset = 0;
  FLOAT blend_factor[4] = {0, 0, 0, 0};
  g_d3d11.context->lpVtbl->IASetInputLayout(g_d3d11.context, g_d3d11.tex_layout);
  g_d3d11.context->lpVtbl->IASetPrimitiveTopology(g_d3d11.context, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  g_d3d11.context->lpVtbl->IASetVertexBuffers(g_d3d11.context, 0, 1, &g_d3d11.tex_vbuf, &stride, &offset);
  g_d3d11.context->lpVtbl->VSSetShader(g_d3d11.context, g_d3d11.tex_vs, NULL, 0);
  g_d3d11.context->lpVtbl->VSSetConstantBuffers(g_d3d11.context, 0, 1, &g_d3d11.tex_cbuf);
  g_d3d11.context->lpVtbl->PSSetShader(g_d3d11.context, g_d3d11.tex_ps, NULL, 0);
  g_d3d11.context->lpVtbl->PSSetShaderResources(g_d3d11.context, 0, 1, &g_d3d11.upload_srv);
  g_d3d11.context->lpVtbl->PSSetSamplers(g_d3d11.context, 0, 1, &g_d3d11.tex_sampler);
  g_d3d11.context->lpVtbl->RSSetState(g_d3d11.context, g_d3d11.rect_raster);
  g_d3d11.context->lpVtbl->OMSetBlendState(g_d3d11.context, g_d3d11.rect_blend, blend_factor, 0xffffffffu);
  g_d3d11.context->lpVtbl->Draw(g_d3d11.context, 6, 0);

  ID3D11ShaderResourceView *null_srv = NULL;
  g_d3d11.context->lpVtbl->PSSetShaderResources(g_d3d11.context, 0, 1, &null_srv);
  return true;
}

void anvil_d3d11_abort_frame(SDL_Window *window) {
  if (!window || window == g_d3d11.rect_active_window) {
    g_d3d11.rect_active_window = NULL;
    g_d3d11.rect_vertex_count = 0;
  }
}

bool anvil_d3d11_end_frame(SDL_Window *window) {
  if (window != g_d3d11.rect_active_window) return false;
  D3D11Window *w = d3d11_find_window(window);
  if (!w || !w->swapchain || !w->rtv) {
    anvil_d3d11_abort_frame(window);
    return false;
  }

  if (!d3d11_flush_rects()) {
    anvil_d3d11_abort_frame(window);
    return false;
  }

  HRESULT hr = w->swapchain->lpVtbl->Present(w->swapchain, 1, 0);
  anvil_d3d11_abort_frame(window);
  if (FAILED(hr)) {
    if (d3d11_device_lost(hr)) {
      d3d11_reset_device();
    } else {
      anvil_d3d11_forget_window(window);
    }
    return false;
  }
  DwmFlush();
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
  if (!d3d11_resize_window(w, width, height)) {
    anvil_d3d11_forget_window(window);
    return false;
  }

  for (int i = 0; i < rect_count; i++) {
    int x = (int)(rects[i].x * scale_x);
    int y = (int)(rects[i].y * scale_y);
    int rw = (int)(rects[i].width * scale_x);
    int rh = (int)(rects[i].height * scale_y);
    if (rw <= 0 || rh <= 0) continue;
    if (x < 0) { rw += x; x = 0; }
    if (y < 0) { rh += y; y = 0; }
    if (x + rw > width) rw = width - x;
    if (y + rh > height) rh = height - y;
    if (rw <= 0 || rh <= 0) continue;

    D3D11_BOX box;
    box.left = (UINT)x;
    box.top = (UINT)y;
    box.front = 0;
    box.right = (UINT)(x + rw);
    box.bottom = (UINT)(y + rh);
    box.back = 1;

    const uint8_t *pixels = (const uint8_t *)surface->pixels + (size_t)y * (size_t)surface->pitch + (size_t)x * 4u;
    g_d3d11.context->lpVtbl->UpdateSubresource(g_d3d11.context, (ID3D11Resource *)w->backbuffer,
                                               0, &box, pixels, (UINT)surface->pitch, 0);
  }

  HRESULT hr = w->swapchain->lpVtbl->Present(w->swapchain, 1, 0);
  if (FAILED(hr)) {
    if (d3d11_device_lost(hr)) {
      d3d11_reset_device();
    } else {
      anvil_d3d11_forget_window(window);
    }
    return false;
  }
  DwmFlush();
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
  d3d11_release_upload_texture();
  SAFE_RELEASE(g_d3d11.tex_sampler);
  SAFE_RELEASE(g_d3d11.tex_cbuf);
  SAFE_RELEASE(g_d3d11.tex_vbuf);
  SAFE_RELEASE(g_d3d11.tex_layout);
  SAFE_RELEASE(g_d3d11.tex_ps);
  SAFE_RELEASE(g_d3d11.tex_vs);
  SAFE_RELEASE(g_d3d11.rect_raster);
  SAFE_RELEASE(g_d3d11.rect_blend);
  SAFE_RELEASE(g_d3d11.rect_cbuf);
  SAFE_RELEASE(g_d3d11.rect_vbuf);
  SAFE_RELEASE(g_d3d11.rect_layout);
  SAFE_RELEASE(g_d3d11.rect_ps);
  SAFE_RELEASE(g_d3d11.rect_vs);
  free(g_d3d11.rect_vertices);
  g_d3d11.rect_vertices = NULL;
  g_d3d11.rect_vertex_count = 0;
  g_d3d11.rect_vertex_capacity = 0;
  g_d3d11.rect_vbuf_capacity = 0;
  g_d3d11.rect_active_window = NULL;
  SAFE_RELEASE(g_d3d11.factory);
  SAFE_RELEASE(g_d3d11.context);
  SAFE_RELEASE(g_d3d11.device);
  g_d3d11.available = false;
}

#endif
