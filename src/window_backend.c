#include "window_backend.h"
#include "renwindow.h"
#include "hosted_surface.h"
#include "win32_frame.h"
#include <SDL3_image/SDL_image.h>
#include <string.h>

bool anvil_window_hosted(RenWindow *ren) {
  return ren && anvil_hosted_surface_is_window(ren->cache.window);
}

SDL_Window *anvil_window_create(const char *title, float width, float height) {
  if (width < 1 || height < 1) {
    const SDL_DisplayMode *mode = SDL_GetCurrentDisplayMode(SDL_GetPrimaryDisplay());
    if (!mode) return NULL;
    if (width < 1) width = mode->w * .8f;
    if (height < 1) height = mode->h * .8f;
  }
  SDL_Window *window = SDL_CreateWindow(title, width, height,
    SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY | SDL_WINDOW_HIDDEN);
  /* Configure the hidden render window before allocating its surface. */
  if (window) anvil_hosted_surface_register_window(window);
  return window;
}

bool anvil_window_show_dialog(RenWindow *ren, uint32_t id, SDL_FileDialogType type, SDL_PropertiesID props, SDL_DialogFileCallback callback, void *userdata) {
  if (anvil_window_hosted(ren)) return anvil_hosted_surface_show_dialog(id, type, props, callback, userdata);
  if (!SDL_SetPointerProperty(props, SDL_PROP_FILE_DIALOG_WINDOW_POINTER, ren->cache.window)) return false;
  SDL_ShowFileDialogWithProperties(type, callback, userdata, props);
  return true;
}
float anvil_window_display_scale(RenWindow *ren) {
  return anvil_window_hosted(ren) ? anvil_hosted_surface_display_scale() : SDL_GetWindowDisplayScale(ren->cache.window);
}

float anvil_window_scale(RenWindow *ren) {
#ifdef ANVIL_USE_SDL_RENDERER
  if (!anvil_window_hosted(ren)) return 1.0f;
#endif
  return anvil_window_display_scale(ren);
}
void anvil_window_initial_display(float *scale, float *refresh) {
  if (!anvil_hosted_surface_active()) return;
  *scale = anvil_hosted_surface_display_scale();
  float hz = anvil_hosted_surface_refresh_rate();
  if (hz > 0) *refresh = hz;
}
float anvil_window_refresh_rate(RenWindow *ren) {
  if (anvil_window_hosted(ren)) return anvil_hosted_surface_refresh_rate();
  SDL_DisplayID display = SDL_GetDisplayForWindow(ren->cache.window);
  const SDL_DisplayMode *mode = display ? SDL_GetCurrentDisplayMode(display) : NULL;
  if (!mode || mode->refresh_rate <= 0) mode = display ? SDL_GetDesktopDisplayMode(display) : NULL;
  return mode && mode->refresh_rate > 0 ? mode->refresh_rate : 0;
}
bool anvil_window_focus(RenWindow *ren) {
  if (anvil_window_hosted(ren)) return anvil_hosted_surface_has_focus();
#ifdef _WIN32
  HWND hwnd = SDL_GetPointerProperty(SDL_GetWindowProperties(ren->cache.window), SDL_PROP_WINDOW_WIN32_HWND_POINTER, NULL);
  if (hwnd) return GetForegroundWindow() == hwnd;
#endif
  return (SDL_GetWindowFlags(ren->cache.window) & SDL_WINDOW_INPUT_FOCUS) != 0;
}
bool anvil_window_should_render(RenWindow *ren) {
  return !anvil_window_hosted(ren) || anvil_hosted_surface_should_render();
}
AnvilSurfaceWindowMode anvil_window_mode(RenWindow *ren) {
  if (anvil_window_hosted(ren)) return anvil_hosted_surface_window_mode();
  SDL_WindowFlags flags = SDL_GetWindowFlags(ren->cache.window);
  if (flags & SDL_WINDOW_FULLSCREEN) return ANVIL_SURFACE_WINDOW_FULLSCREEN;
  if (flags & SDL_WINDOW_MINIMIZED) return ANVIL_SURFACE_WINDOW_MINIMIZED;
  if (flags & SDL_WINDOW_MAXIMIZED) return ANVIL_SURFACE_WINDOW_MAXIMIZED;
  return ANVIL_SURFACE_WINDOW_NORMAL;
}
void anvil_window_bounds(RenWindow *ren, int *x, int *y, int *w, int *h) {
  if (anvil_window_hosted(ren)) { anvil_hosted_surface_window_bounds(x, y, w, h); return; }
#ifdef _WIN32
  if (ren->win32_frame) {
    HWND hwnd = SDL_GetPointerProperty(SDL_GetWindowProperties(ren->cache.window), SDL_PROP_WINDOW_WIN32_HWND_POINTER, NULL);
    RECT rect;
    if (hwnd && GetWindowRect(hwnd, &rect)) {
      *x = rect.left; *y = rect.top; *w = rect.right - rect.left; *h = rect.bottom - rect.top; return;
    }
  }
#endif
  SDL_GetWindowSize(ren->cache.window, w, h);
  SDL_GetWindowPosition(ren->cache.window, x, y);
}
void anvil_window_set_bounds(RenWindow *ren, int x, int y, int w, int h) {
  if (anvil_window_hosted(ren)) { anvil_hosted_surface_set_bounds(x, y, w, h); return; }
#ifdef _WIN32
  if (ren->win32_frame) {
    HWND hwnd = SDL_GetPointerProperty(SDL_GetWindowProperties(ren->cache.window), SDL_PROP_WINDOW_WIN32_HWND_POINTER, NULL);
    if (hwnd) { SetWindowPos(hwnd, NULL, x, y, w, h, SWP_NOZORDER | SWP_NOACTIVATE); ren_resize_window(ren); return; }
  }
#endif
  SDL_SetWindowSize(ren->cache.window, w, h); SDL_SetWindowPosition(ren->cache.window, x, y); ren_resize_window(ren);
}
void anvil_window_title(RenWindow *ren, const char *title) {
  if (anvil_window_hosted(ren)) anvil_hosted_surface_set_title(title);
  else SDL_SetWindowTitle(ren->cache.window, title);
}
void anvil_window_set_mode(RenWindow *ren, AnvilSurfaceWindowMode mode) {
  if (anvil_window_hosted(ren)) { anvil_hosted_surface_set_window_mode(mode); return; }
  SDL_SetWindowFullscreen(ren->cache.window, mode == ANVIL_SURFACE_WINDOW_FULLSCREEN);
  if (mode == ANVIL_SURFACE_WINDOW_NORMAL) SDL_RestoreWindow(ren->cache.window);
  if (mode == ANVIL_SURFACE_WINDOW_MINIMIZED) SDL_MinimizeWindow(ren->cache.window);
  if (mode == ANVIL_SURFACE_WINDOW_MAXIMIZED) SDL_MaximizeWindow(ren->cache.window);
}
void anvil_window_bordered(RenWindow *ren, bool bordered) {
  if (anvil_window_hosted(ren)) { anvil_hosted_surface_set_bordered(bordered); return; }
#ifdef _WIN32
  bool maximized = (SDL_GetWindowFlags(ren->cache.window) & SDL_WINDOW_MAXIMIZED) != 0;
  if (maximized && !bordered) SDL_RestoreWindow(ren->cache.window);
  SDL_SetWindowBordered(ren->cache.window, bordered);
  if (maximized && !bordered) SDL_MaximizeWindow(ren->cache.window);
#else
  SDL_SetWindowBordered(ren->cache.window, bordered);
#endif
}
void anvil_window_visible(RenWindow *ren, bool visible) {
  if (anvil_window_hosted(ren)) { anvil_hosted_surface_set_visible(visible); return; }
  if (visible) SDL_ShowWindow(ren->cache.window); else SDL_HideWindow(ren->cache.window);
}
bool anvil_window_opacity(RenWindow *ren, float opacity) {
  if (anvil_window_hosted(ren)) return anvil_hosted_surface_set_opacity(opacity);
  return SDL_SetWindowOpacity(ren->cache.window, opacity);
}
void anvil_window_raise(RenWindow *ren) {
  if (anvil_window_hosted(ren)) anvil_hosted_surface_raise(); else SDL_RaiseWindow(ren->cache.window);
}
bool anvil_window_flash(RenWindow *ren, SDL_FlashOperation operation) {
  if (anvil_window_hosted(ren)) { anvil_hosted_surface_flash(operation); return true; }
  return SDL_FlashWindow(ren->cache.window, operation);
}
void anvil_window_text_input(RenWindow *ren, bool active) {
  if (anvil_window_hosted(ren)) { anvil_hosted_surface_set_text_input(active); return; }
  if (active) SDL_StartTextInput(ren->cache.window); else SDL_StopTextInput(ren->cache.window);
}
void anvil_window_text_area(RenWindow *ren, const SDL_Rect *rect) {
  if (anvil_window_hosted(ren)) anvil_hosted_surface_set_text_input_area(rect, 0);
  else SDL_SetTextInputArea(ren->cache.window, rect, 0);
}
void anvil_window_clear_ime(RenWindow *ren) {
  if (anvil_window_hosted(ren)) anvil_hosted_surface_clear_ime(); else SDL_ClearComposition(ren->cache.window);
}
void anvil_window_capture(RenWindow *ren, bool active) {
  if (!anvil_window_hosted(ren)) SDL_CaptureMouse(active);
}

static SDL_HitTestResult SDLCALL hit_test(SDL_Window *window, const SDL_Point *pt, void *data) {
  HitTestInfo hit = ((RenWindow *)data)->hit_test_info;
  int w, h; SDL_GetWindowSize(window, &w, &h);
  int border = hit.resize_border;
  if (pt->y < hit.title_height && pt->x > border && pt->x < w - hit.controls_width) {
    if ((hit.titlebar_client_width > 0 && pt->x >= hit.titlebar_client_x && pt->x < hit.titlebar_client_x + hit.titlebar_client_width) ||
        (hit.titlebar_client2_width > 0 && pt->x >= hit.titlebar_client2_x && pt->x < hit.titlebar_client2_x + hit.titlebar_client2_width)) return SDL_HITTEST_NORMAL;
    return SDL_HITTEST_DRAGGABLE;
  }
  if (pt->x < border && pt->y < border) return SDL_HITTEST_RESIZE_TOPLEFT;
  if (pt->x > w - border && pt->y < border) return SDL_HITTEST_RESIZE_TOPRIGHT;
  if (pt->x > w - border && pt->y > h - border) return SDL_HITTEST_RESIZE_BOTTOMRIGHT;
  if (pt->x < border && pt->y > h - border) return SDL_HITTEST_RESIZE_BOTTOMLEFT;
  if (pt->x > border && pt->x < w - border && pt->y > h - border) return SDL_HITTEST_RESIZE_BOTTOM;
  if (pt->x < border && pt->y > border && pt->y < h - border) return SDL_HITTEST_RESIZE_LEFT;
  return SDL_HITTEST_NORMAL;
}
void anvil_window_hit_test(RenWindow *ren, const AnvilSurfaceHitTest *hit) {
  AnvilSurfaceHitTest empty = {0};
  if (anvil_window_hosted(ren)) { anvil_hosted_surface_set_hit_test(hit ? hit : &empty); return; }
  if (!hit) {
    SDL_SetWindowHitTest(ren->cache.window, NULL, NULL);
    win32_frame_set_hit_test(ren, 0, 0, 0, 0, 0, 0, 0); return;
  }
  ren->hit_test_info = (HitTestInfo){
    .title_height = hit->title_height, .controls_width = hit->controls_width, .resize_border = hit->resize_border,
    .titlebar_client_x = hit->client_x, .titlebar_client_width = hit->client_width,
    .titlebar_client2_x = hit->client2_x, .titlebar_client2_width = hit->client2_width,
  };
  win32_frame_set_hit_test(ren, hit->title_height, hit->controls_width, hit->resize_border,
    hit->client_x, hit->client_width, hit->client2_x, hit->client2_width);
#ifdef _WIN32
  if (ren->win32_frame) return;
#endif
  SDL_SetWindowHitTest(ren->cache.window, hit_test, ren);
}
bool anvil_window_native_frame(RenWindow *ren, bool enable) {
  if (anvil_window_hosted(ren)) return enable;
  if (enable) SDL_SetWindowHitTest(ren->cache.window, NULL, NULL);
  return win32_frame_enable(ren, enable);
}
bool anvil_window_frame_metrics(RenWindow *ren, int *button, int *title, int *border) {
  if (anvil_window_hosted(ren)) return anvil_hosted_surface_frame_metrics(button, title, border);
  return win32_frame_get_metrics(ren, button, title, border);
}

static SDL_Cursor *cursor_cache[ANVIL_SURFACE_CURSOR_COUNT];
static SDL_Cursor *grab_cursor(void) {
  static const char svg[] =
    "<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24'>"
    "<path fill='white' stroke='#202020' stroke-width='1.2' stroke-linejoin='round' d='"
    "M8.5 21 C7.5 19 6 17 4.3 14.6 L2.8 12.5 C1.4 10.6 3.5 9.2 4.8 10.6 "
    "L7 12.5 V5 C7 3 10 3 10 5 V10 H10.5 V3.5 C10.5 1.5 13.5 1.5 13.5 3.5 "
    "V10 H14 V5 C14 3 17 3 17 5 V11 H17.5 V7.5 C17.5 5.5 20.5 5.5 20.5 7.5 "
    "V14 C20.5 17 18.5 19.5 18 21 Z'/></svg>";
  SDL_IOStream *stream = SDL_IOFromConstMem(svg, sizeof(svg) - 1);
  if (!stream) return NULL;
  SDL_Surface *surface = IMG_LoadSVG_IO(stream); SDL_CloseIO(stream);
  if (!surface) return NULL;
  stream = SDL_IOFromConstMem(svg, sizeof(svg) - 1);
  if (stream) {
    SDL_Surface *large = IMG_LoadSizedSVG_IO(stream, 48, 48); SDL_CloseIO(stream);
    if (large) { SDL_AddSurfaceAlternateImage(surface, large); SDL_DestroySurface(large); }
  }
  SDL_Cursor *cursor = SDL_CreateColorCursor(surface, 12, 12); SDL_DestroySurface(surface); return cursor;
}
void anvil_window_cursor(AnvilSurfaceCursor cursor) {
  if (anvil_hosted_surface_active()) { anvil_hosted_surface_set_cursor(cursor); return; }
  static const SDL_SystemCursor kinds[] = { SDL_SYSTEM_CURSOR_DEFAULT, SDL_SYSTEM_CURSOR_TEXT, SDL_SYSTEM_CURSOR_EW_RESIZE,
    SDL_SYSTEM_CURSOR_NS_RESIZE, SDL_SYSTEM_CURSOR_POINTER, SDL_SYSTEM_CURSOR_CROSSHAIR, SDL_SYSTEM_CURSOR_MOVE };
  if (!cursor_cache[cursor]) cursor_cache[cursor] = cursor == ANVIL_SURFACE_CURSOR_GRAB ? grab_cursor() : SDL_CreateSystemCursor(kinds[cursor]);
  SDL_SetCursor(cursor_cache[cursor]);
}
