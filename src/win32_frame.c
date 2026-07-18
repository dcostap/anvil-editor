#if defined(_WIN32)

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <windowsx.h>
#include <dwmapi.h>
#include <stdlib.h>
#include <SDL3/SDL.h>
#include "renwindow.h"
#include "renderer.h"
#include "d3d11_backend.h"
#include "system_events.h"
#include "resize_diagnostics.h"
#include "win32_frame.h"

void anvil_request_resize_frame(void);
void anvil_request_resize_frame_reason(const char *reason);
void anvil_request_resize_frame_for_window(SDL_Window *window, const char *reason);
void anvil_set_live_resize(bool live_resize);

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif
#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif
#ifndef DWMWCP_DEFAULT
#define DWMWCP_DEFAULT 0
#endif
#ifndef WS_EX_NOREDIRECTIONBITMAP
#define WS_EX_NOREDIRECTIONBITMAP 0x00200000L
#endif

#define ANVIL_WIN32_FRAME_PROP L"AnvilWin32FrameData"

struct Win32FrameData {
  HWND hwnd;
  WNDPROC old_proc;
  RenWindow *ren;
  bool enabled;
  bool live_resize;
  int last_pixel_w;
  int last_pixel_h;
};
typedef struct Win32FrameData Win32FrameData;

static HWND get_hwnd(SDL_Window *window) {
  SDL_PropertiesID props = SDL_GetWindowProperties(window);
  return (HWND) SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WIN32_HWND_POINTER, NULL);
}

static bool env_value_is_false(const char *value) {
  if (!value || !value[0]) return true;
  while (*value == ' ' || *value == '\t') value++;
  if (!value[0]) return true;
  return value[0] == '0' ||
         SDL_strcasecmp(value, "false") == 0 ||
         SDL_strcasecmp(value, "no") == 0 ||
         SDL_strcasecmp(value, "off") == 0;
}

static bool resize_dwm_flush_enabled(void) {
  return !env_value_is_false(getenv("ANVIL_D3D11_RESIZE_DWM_FLUSH"));
}

static bool own_wm_paint_enabled(void) {
  return !env_value_is_false(getenv("ANVIL_WIN32_OWN_WM_PAINT"));
}

static bool own_wm_size_enabled(void) {
  const char *value = getenv("ANVIL_WIN32_OWN_WM_SIZE");
  if (value && value[0]) return !env_value_is_false(value);
  return anvil_d3d11_enabled();
}

static bool no_redirection_bitmap_enabled(void) {
  const char *value = getenv("ANVIL_WIN32_NOREDIRECTIONBITMAP");
  if (value && value[0]) return !env_value_is_false(value);
  /* WS_EX_NOREDIRECTIONBITMAP makes DWM stop keeping a redirection surface
     for the HWND. That can improve exposed-area behavior during live resize,
     but after alt-tab/occlusion DWM may have no retained pixels to show until
     the app presents again, which looks like a transparent/unrendered window.
     Keep it opt-in instead of enabling it for all D3D11 windows. */
  return false;
}

static void get_sdl_window_sizes(Win32FrameData *frame, int *point_w, int *point_h, int *pixel_w, int *pixel_h) {
  if (point_w) *point_w = 0;
  if (point_h) *point_h = 0;
  if (pixel_w) *pixel_w = 0;
  if (pixel_h) *pixel_h = 0;
  if (!frame || !frame->ren || !frame->ren->cache.window) return;
  SDL_GetWindowSize(frame->ren->cache.window, point_w, point_h);
  SDL_GetWindowSizeInPixels(frame->ren->cache.window, pixel_w, pixel_h);
}

static void log_win32_message(Win32FrameData *frame, const char *name, WPARAM wparam, LPARAM lparam) {
  int point_w = 0, point_h = 0, pixel_w = 0, pixel_h = 0;
  get_sdl_window_sizes(frame, &point_w, &point_h, &pixel_w, &pixel_h);

  RECT cr = {0};
  if (frame && frame->hwnd) GetClientRect(frame->hwnd, &cr);

  anvil_resize_diag_log(&(AnvilResizeDiagEvent){
    .category = "win32_msg",
    .name = name,
    .window_id = frame && frame->ren && frame->ren->cache.window ? SDL_GetWindowID(frame->ren->cache.window) : 0,
    .live_resize = frame ? frame->live_resize : anvil_resize_diag_live_resize(),
    .queue_depth = system_pending_event_count(),
    .point_w = point_w,
    .point_h = point_h,
    .pixel_w = pixel_w,
    .pixel_h = pixel_h,
    .client_w = (int)(cr.right - cr.left),
    .client_h = (int)(cr.bottom - cr.top),
    .count_a = (int)wparam,
    .count_b = (int)lparam
  });
}

static void maybe_resize_dwm_flush(Win32FrameData *frame, const char *reason) {
  if (!resize_dwm_flush_enabled()) return;
  uint64_t start_ns = SDL_GetTicksNS();
  HRESULT hr = DwmFlush();
  uint64_t end_ns = SDL_GetTicksNS();
  anvil_resize_diag_log(&(AnvilResizeDiagEvent){
    .category = "win32_resize",
    .name = "resize_dwm_flush",
    .reason = reason,
    .window_id = frame && frame->ren && frame->ren->cache.window ? SDL_GetWindowID(frame->ren->cache.window) : 0,
    .live_resize = frame ? frame->live_resize : anvil_resize_diag_live_resize(),
    .queue_depth = system_pending_event_count(),
    .count_a = (int)hr,
    .ms_a = anvil_resize_diag_ticks_to_ms(start_ns, end_ns)
  });
}

static UINT dpi_for_window(HWND hwnd) {
  UINT dpi = 96;
  HMODULE user32 = GetModuleHandleW(L"user32.dll");
  if (user32) {
    typedef UINT (WINAPI *GetDpiForWindowFn)(HWND);
    GetDpiForWindowFn pGetDpiForWindow = (GetDpiForWindowFn) GetProcAddress(user32, "GetDpiForWindow");
    if (pGetDpiForWindow) dpi = pGetDpiForWindow(hwnd);
  }
  return dpi;
}

static int scale_for_dpi(HWND hwnd, int value) {
  return MulDiv(value, (int)dpi_for_window(hwnd), 96);
}

static int system_metric_for_dpi(HWND hwnd, int metric) {
  HMODULE user32 = GetModuleHandleW(L"user32.dll");
  if (user32) {
    typedef int (WINAPI *GetSystemMetricsForDpiFn)(int, UINT);
    GetSystemMetricsForDpiFn pGetSystemMetricsForDpi = (GetSystemMetricsForDpiFn) GetProcAddress(user32, "GetSystemMetricsForDpi");
    if (pGetSystemMetricsForDpi) return pGetSystemMetricsForDpi(metric, dpi_for_window(hwnd));
  }
  return GetSystemMetrics(metric);
}

static bool is_maximized(HWND hwnd) {
  WINDOWPLACEMENT placement;
  placement.length = sizeof(placement);
  return GetWindowPlacement(hwnd, &placement) && placement.showCmd == SW_MAXIMIZE;
}

static void update_dwm(HWND hwnd, bool enabled) {
  BOOL dark = enabled ? TRUE : FALSE;
  DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof(dark));

  int corner = DWMWCP_DEFAULT;
  DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, sizeof(corner));

  /* A tiny extended frame keeps DWM shadow/composition behavior alive when the
     non-client title area is collapsed into our client area. */
  MARGINS margins = enabled ? (MARGINS){ 1, 1, 1, 1 } : (MARGINS){ 0, 0, 0, 0 };
  DwmExtendFrameIntoClientArea(hwnd, &margins);
}

static void apply_monitor_work_area(HWND hwnd, MINMAXINFO *mmi) {
  HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi;
  mi.cbSize = sizeof(mi);
  if (!GetMonitorInfoW(monitor, &mi)) return;

  RECT work = mi.rcWork;
  RECT monitor_rect = mi.rcMonitor;
  mmi->ptMaxPosition.x = work.left - monitor_rect.left;
  mmi->ptMaxPosition.y = work.top - monitor_rect.top;
  mmi->ptMaxSize.x = work.right - work.left;
  mmi->ptMaxSize.y = work.bottom - work.top;
}

static LRESULT handle_nccalcsize(HWND hwnd, WPARAM wparam, LPARAM lparam) {
  if (!wparam) return 0;

  NCCALCSIZE_PARAMS *params = (NCCALCSIZE_PARAMS *) lparam;

  /* Returning 0 removes the standard caption from the client calculation, but
     when maximized the client rect must be constrained to the monitor work area
     or the app draws under the taskbar. */
  if (is_maximized(hwnd)) {
    /* Use the proposed maximized rect instead of MonitorFromWindow().  During
       restore from minimized, USER32 can still associate the HWND with its
       old normal/iconic location while rgrc[0] already contains the real
       maximized bounds.  MonitorFromWindow() then chooses the old monitor and
       leaves a maximized window with a client area sized for that monitor
       (for example 1920x1080 inside a 2560x1440 maximized frame), so D3D only
       presents into part of the visible window. */
    HMONITOR monitor = MonitorFromRect(&params->rgrc[0], MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi;
    mi.cbSize = sizeof(mi);
    if (GetMonitorInfoW(monitor, &mi)) {
      params->rgrc[0] = mi.rcWork;
    }
  }

  return 0;
}

static LRESULT hit_test(Win32FrameData *frame, HWND hwnd, LPARAM lparam) {
  RenWindow *ren = frame->ren;
  if (!ren) return HTCLIENT;

  POINT pt = { GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam) };
  RECT wr;
  GetWindowRect(hwnd, &wr);

  const int width = wr.right - wr.left;
  const int height = wr.bottom - wr.top;
  const int x = pt.x - wr.left;
  const int y = pt.y - wr.top;

  int resize = ren->hit_test_info.resize_border;
  int title_height = ren->hit_test_info.title_height;
  int controls_width = ren->hit_test_info.controls_width;
  int client_x = ren->hit_test_info.titlebar_client_x;
  int client_width = ren->hit_test_info.titlebar_client_width;
  int client2_x = ren->hit_test_info.titlebar_client2_x;
  int client2_width = ren->hit_test_info.titlebar_client2_width;

  if (resize <= 0) resize = scale_for_dpi(hwnd, 8);

  if (title_height > 0 && y >= 0 && y < title_height &&
      controls_width > 0 && x >= width - controls_width && x < width) {
    /* App-drawn caption buttons must stay client-area controls. Returning
       HTMINBUTTON/HTMAXBUTTON/HTCLOSE lets Windows enter non-client button
       tracking, which briefly flashes the hidden/native caption button and can
       swallow the SDL click events that Lua uses for the real action. */
    return HTCLIENT;
  }

  const bool left = x >= 0 && x < resize;
  const bool right = x < width && x >= width - resize;
  const bool top = y >= 0 && y < resize;
  const bool bottom = y < height && y >= height - resize;

  if (!is_maximized(hwnd)) {
    if (top && left) return HTTOPLEFT;
    if (top && right) return HTTOPRIGHT;
    if (bottom && left) return HTBOTTOMLEFT;
    if (bottom && right) return HTBOTTOMRIGHT;
    if (left) return HTLEFT;
    if (right) return HTRIGHT;
    if (top) return HTTOP;
    if (bottom) return HTBOTTOM;
  }

  if (title_height > 0 && y >= 0 && y < title_height) {
    if ((client_width > 0 && x >= client_x && x < client_x + client_width) ||
        (client2_width > 0 && x >= client2_x && x < client2_x + client2_width)) {
      return HTCLIENT;
    }

    if (x >= resize && x < width - controls_width) {
      return HTCAPTION;
    }
  }

  return HTCLIENT;
}

static void push_sdl_mouse_motion_at(Win32FrameData *frame, float x, float y) {
  if (!frame || !frame->ren || !frame->ren->cache.window) return;

  SDL_Event event;
  SDL_zero(event);
  event.type = SDL_EVENT_MOUSE_MOTION;
  event.motion.windowID = SDL_GetWindowID(frame->ren->cache.window);
  event.motion.x = x;
  event.motion.y = y;
  SDL_PushEvent(&event);
}

static void push_sdl_mouse_motion(Win32FrameData *frame, LPARAM lparam) {
  if (!frame || !frame->ren || !frame->ren->cache.window) return;

  POINT pt = { GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam) };
  ScreenToClient(frame->hwnd, &pt);
  push_sdl_mouse_motion_at(frame, (float) pt.x, (float) pt.y);
}

static void push_sdl_mouse_leave(Win32FrameData *frame) {
  if (!frame || !frame->ren || !frame->ren->cache.window) return;

  /* Some hover state is cleared by mouse-motion routing, while window-leave
     routing only notifies the last overlapping view. Send an explicit outside
     motion first so app-drawn titlebar buttons are cleared even when the
     cursor exits directly from the top/right edge. */
  push_sdl_mouse_motion_at(frame, -1.0f, -1.0f);

  SDL_Event event;
  SDL_zero(event);
  event.type = SDL_EVENT_WINDOW_MOUSE_LEAVE;
  event.window.windowID = SDL_GetWindowID(frame->ren->cache.window);
  SDL_PushEvent(&event);
}

static void push_sdl_resize_event(Win32FrameData *frame) {
  if (!frame || !frame->ren || !frame->ren->cache.window) return;

  SDL_Event event;
  SDL_zero(event);
  event.type = SDL_EVENT_WINDOW_RESIZED;
  event.window.windowID = SDL_GetWindowID(frame->ren->cache.window);
  RECT cr = {0};
  if (GetClientRect(frame->hwnd, &cr)) {
    event.window.data1 = (int)(cr.right - cr.left);
    event.window.data2 = (int)(cr.bottom - cr.top);
  } else {
    SDL_GetWindowSize(frame->ren->cache.window, &event.window.data1, &event.window.data2);
  }
  system_push_event(&event);
}

static void live_resize_frame(Win32FrameData *frame, const char *reason) {
  if (!frame || !frame->enabled || !frame->ren || !frame->ren->cache.window) return;
  uint64_t start_ns = SDL_GetTicksNS();
  int point_w = 0, point_h = 0, pixel_w = 0, pixel_h = 0;
  get_sdl_window_sizes(frame, &point_w, &point_h, &pixel_w, &pixel_h);
  ren_resize_window(frame->ren);
  win32_frame_sync_client_size(frame->ren);
  rencache_invalidate(&frame->ren->cache);
  push_sdl_resize_event(frame);
  uint64_t end_ns = SDL_GetTicksNS();
  anvil_resize_diag_log(&(AnvilResizeDiagEvent){
    .category = "win32_resize",
    .name = "live_resize_frame",
    .reason = reason,
    .window_id = SDL_GetWindowID(frame->ren->cache.window),
    .live_resize = frame->live_resize,
    .queue_depth = system_pending_event_count(),
    .point_w = point_w,
    .point_h = point_h,
    .pixel_w = pixel_w,
    .pixel_h = pixel_h,
    .count_a = (pixel_w == frame->last_pixel_w && pixel_h == frame->last_pixel_h) ? 1 : 0,
    .ms_a = anvil_resize_diag_ticks_to_ms(start_ns, end_ns)
  });
  frame->last_pixel_w = pixel_w;
  frame->last_pixel_h = pixel_h;
  anvil_request_resize_frame_for_window(frame->ren->cache.window, reason ? reason : "win32_resize");
  maybe_resize_dwm_flush(frame, reason ? reason : "win32_resize");
}

static void toggle_maximize(HWND hwnd) {
  if (is_maximized(hwnd)) {
    ShowWindow(hwnd, SW_RESTORE);
  } else {
    ShowWindow(hwnd, SW_MAXIMIZE);
  }
}

static void show_system_menu(HWND hwnd, LPARAM lparam) {
  HMENU menu = GetSystemMenu(hwnd, FALSE);
  if (!menu) return;

  const bool maximized = is_maximized(hwnd);
  EnableMenuItem(menu, SC_RESTORE, MF_BYCOMMAND | (maximized ? MF_ENABLED : MF_GRAYED));
  EnableMenuItem(menu, SC_MOVE, MF_BYCOMMAND | (maximized ? MF_GRAYED : MF_ENABLED));
  EnableMenuItem(menu, SC_SIZE, MF_BYCOMMAND | (maximized ? MF_GRAYED : MF_ENABLED));
  EnableMenuItem(menu, SC_MAXIMIZE, MF_BYCOMMAND | (maximized ? MF_GRAYED : MF_ENABLED));

  int command = TrackPopupMenu(menu,
    TPM_RETURNCMD | TPM_RIGHTBUTTON,
    GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam), 0, hwnd, NULL);
  if (command) PostMessageW(hwnd, WM_SYSCOMMAND, command, 0);
}

static LRESULT CALLBACK frame_wndproc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
  Win32FrameData *frame = (Win32FrameData *) GetPropW(hwnd, ANVIL_WIN32_FRAME_PROP);
  if (!frame) return DefWindowProcW(hwnd, msg, wparam, lparam);

  switch (msg) {
    case WM_ENTERSIZEMOVE:
      if (frame->enabled) {
        frame->live_resize = true;
        anvil_resize_diag_set_live_resize(true);
        anvil_set_live_resize(true);
        log_win32_message(frame, "WM_ENTERSIZEMOVE", wparam, lparam);
      }
      break;

    case WM_EXITSIZEMOVE:
      if (frame->enabled) {
        log_win32_message(frame, "WM_EXITSIZEMOVE", wparam, lparam);
        frame->live_resize = false;
        anvil_resize_diag_set_live_resize(false);
        anvil_set_live_resize(false);
        if (frame->ren && frame->ren->cache.window) {
          anvil_request_resize_frame_for_window(frame->ren->cache.window, "exit_sizemove");
          maybe_resize_dwm_flush(frame, "exit_sizemove");
        }
      }
      break;

    case WM_SIZE:
      if (frame->enabled) {
        log_win32_message(frame, "WM_SIZE", wparam, lparam);
        if (own_wm_size_enabled()) {
          /* Let SDL's window proc ingest the new size first, so SDL_GetWindowSize*
             sees the just-grown client area when our immediate D3D frame runs.
             We still return handled: the important "owned" part is that Anvil
             presents synchronously from WM_SIZE rather than waiting for SDL's
             normal event-loop resize path. */
          CallWindowProcW(frame->old_proc, hwnd, msg, wparam, lparam);
          if (wparam != SIZE_MINIMIZED) live_resize_frame(frame, "wm_size_owned");
          ValidateRect(hwnd, NULL);
          return 0;
        }
        LRESULT result = CallWindowProcW(frame->old_proc, hwnd, msg, wparam, lparam);
        if (wparam != SIZE_MINIMIZED) live_resize_frame(frame, "wm_size");
        return result;
      }
      break;

    case WM_PAINT:
      if (frame->enabled) {
        log_win32_message(frame, "WM_PAINT", wparam, lparam);
        if (own_wm_paint_enabled()) {
          PAINTSTRUCT ps;
          BeginPaint(hwnd, &ps);
          live_resize_frame(frame, "wm_paint_owned");
          EndPaint(hwnd, &ps);
          return 0;
        }
        LRESULT result = CallWindowProcW(frame->old_proc, hwnd, msg, wparam, lparam);
        live_resize_frame(frame, "wm_paint");
        return result;
      }
      break;

    case WM_NCCALCSIZE:
      if (frame->enabled) return handle_nccalcsize(hwnd, wparam, lparam);
      break;

    case WM_GETMINMAXINFO:
      if (frame->enabled) {
        apply_monitor_work_area(hwnd, (MINMAXINFO *) lparam);
        return 0;
      }
      break;

    case WM_NCHITTEST:
      if (frame->enabled) {
        /* Do not delegate hit-testing to DwmDefWindowProc here. With our
           collapsed non-client caption it can still report native caption
           button hits near the top-right corner, causing the invisible OS
           buttons to flash and interfere with our Lua-drawn controls. */
        return hit_test(frame, hwnd, lparam);
      }
      break;

    case WM_NCACTIVATE:
      if (frame->enabled) {
        /* Let SDL's window proc see activation changes so it can update its
           internal keyboard focus state.  If we swallow this message, Win32
           still focuses the HWND and keydown events arrive, but SDL keeps
           SDL_WINDOW_INPUT_FOCUS / SDL_GetKeyboardFocus() false; then SDL's
           WM_CHAR path refuses to emit SDL_EVENT_TEXT_INPUT, so text fields
           appear focused but cannot type. */
        CallWindowProcW(frame->old_proc, hwnd, msg, wparam, lparam);
        return TRUE;
      }
      break;

    case WM_MOUSEMOVE:
      if (frame->enabled) {
        TRACKMOUSEEVENT tme;
        tme.cbSize = sizeof(tme);
        tme.dwFlags = TME_LEAVE;
        tme.hwndTrack = hwnd;
        tme.dwHoverTime = HOVER_DEFAULT;
        TrackMouseEvent(&tme);
      }
      break;

    case WM_MOUSELEAVE:
      if (frame->enabled) {
        push_sdl_mouse_leave(frame);
      }
      break;

    case WM_NCMOUSEMOVE:
      if (frame->enabled) {
        push_sdl_mouse_motion(frame, lparam);
        TRACKMOUSEEVENT tme;
        tme.cbSize = sizeof(tme);
        tme.dwFlags = TME_LEAVE | TME_NONCLIENT;
        tme.hwndTrack = hwnd;
        tme.dwHoverTime = HOVER_DEFAULT;
        TrackMouseEvent(&tme);
      }
      break;

    case WM_NCMOUSELEAVE:
      if (frame->enabled) {
        push_sdl_mouse_leave(frame);
      }
      break;

    case WM_NCLBUTTONUP:
      if (frame->enabled) {
        switch (wparam) {
          case HTMINBUTTON:
            ShowWindow(hwnd, SW_MINIMIZE);
            return 0;
          case HTMAXBUTTON:
            toggle_maximize(hwnd);
            return 0;
          case HTCLOSE:
            PostMessageW(hwnd, WM_CLOSE, 0, 0);
            return 0;
        }
      }
      break;

    case WM_NCRBUTTONUP:
      if (frame->enabled && wparam == HTCAPTION) {
        show_system_menu(hwnd, lparam);
        return 0;
      }
      break;

    case WM_DPICHANGED:
    case WM_SETTINGCHANGE:
    case WM_THEMECHANGED:
      if (frame->enabled) update_dwm(hwnd, true);
      break;

    case WM_DESTROY: {
      WNDPROC old_proc = frame->old_proc;
      win32_frame_destroy(frame->ren);
      return CallWindowProcW(old_proc, hwnd, msg, wparam, lparam);
    }
  }

  return CallWindowProcW(frame->old_proc, hwnd, msg, wparam, lparam);
}

bool win32_frame_enable(RenWindow *ren, bool enable) {
  if (!ren || !ren->cache.window) return false;

  HWND hwnd = get_hwnd(ren->cache.window);
  if (!hwnd) return false;

  Win32FrameData *frame = ren->win32_frame;
  if (!frame) {
    frame = SDL_calloc(1, sizeof(*frame));
    if (!frame) return false;
    frame->hwnd = hwnd;
    frame->ren = ren;
    SetPropW(hwnd, ANVIL_WIN32_FRAME_PROP, frame);
    SetLastError(0);
    frame->old_proc = (WNDPROC) SetWindowLongPtrW(hwnd, GWLP_WNDPROC, (LONG_PTR) frame_wndproc);
    if (!frame->old_proc && GetLastError() != 0) {
      RemovePropW(hwnd, ANVIL_WIN32_FRAME_PROP);
      SDL_free(frame);
      return false;
    }
    ren->win32_frame = frame;
  }

  frame->enabled = enable;

  LONG_PTR style = GetWindowLongPtrW(hwnd, GWL_STYLE);
  if (enable) {
    style |= WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU;
    SetWindowLongPtrW(hwnd, GWL_STYLE, style);
  }

  LONG_PTR exstyle = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
  if (enable && no_redirection_bitmap_enabled()) {
    exstyle |= WS_EX_NOREDIRECTIONBITMAP;
  } else {
    exstyle &= ~WS_EX_NOREDIRECTIONBITMAP;
  }
  SetWindowLongPtrW(hwnd, GWL_EXSTYLE, exstyle);
  update_dwm(hwnd, enable);

  SetWindowPos(hwnd, NULL, 0, 0, 0, 0,
    SWP_NOZORDER | SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  return true;
}

bool win32_frame_get_metrics(RenWindow *ren, int *button_width, int *title_height, int *resize_border) {
  if (!ren || !ren->cache.window) return false;

  HWND hwnd = get_hwnd(ren->cache.window);
  if (!hwnd) return false;

  if (button_width) *button_width = system_metric_for_dpi(hwnd, SM_CXSIZE);
  if (title_height) *title_height = system_metric_for_dpi(hwnd, SM_CYSIZE);
  if (resize_border) {
    *resize_border = system_metric_for_dpi(hwnd, SM_CXSIZEFRAME)
                   + system_metric_for_dpi(hwnd, SM_CXPADDEDBORDER);
  }
  return true;
}

bool win32_frame_sync_client_size(RenWindow *ren) {
  if (!ren || !ren->cache.window) return false;
  HWND hwnd = get_hwnd(ren->cache.window);
  if (!hwnd) return false;

  RECT cr = {0};
  if (!GetClientRect(hwnd, &cr)) return false;
  int client_w = (int)(cr.right - cr.left);
  int client_h = (int)(cr.bottom - cr.top);
  if (client_w <= 0 || client_h <= 0) return false;

  /* During Win32's modal sizing loop SDL's cached window size can trail the
     real HWND client rect by a message, especially on fast outward drags.  With
     WS_EX_NOREDIRECTIONBITMAP that trailing frame is visible as black exposed
     area.  For the owned D3D resize path, make the render cache authoritative
     from GetClientRect() so the swapchain is grown to the pixels Windows just
     exposed. */
  ren->cache.window_width = client_w;
  ren->cache.window_height = client_h;
  ren->cache.window_pixel_width = client_w;
  ren->cache.window_pixel_height = client_h;
  return true;
}

void win32_frame_set_hit_test(RenWindow *ren, int title_height, int controls_width, int resize_border, int client_x, int client_width, int client2_x, int client2_width) {
  if (!ren) return;
  ren->hit_test_info.title_height = title_height;
  ren->hit_test_info.controls_width = controls_width;
  ren->hit_test_info.resize_border = resize_border;
  ren->hit_test_info.titlebar_client_x = client_x;
  ren->hit_test_info.titlebar_client_width = client_width;
  ren->hit_test_info.titlebar_client2_x = client2_x;
  ren->hit_test_info.titlebar_client2_width = client2_width;
}

void win32_frame_destroy(RenWindow *ren) {
  if (!ren || !ren->win32_frame) return;

  Win32FrameData *frame = ren->win32_frame;
  HWND hwnd = frame->hwnd;

  if (IsWindow(hwnd)) {
    RemovePropW(hwnd, ANVIL_WIN32_FRAME_PROP);
    if (frame->old_proc) {
      SetWindowLongPtrW(hwnd, GWLP_WNDPROC, (LONG_PTR) frame->old_proc);
    }
  }

  ren->win32_frame = NULL;
  SDL_free(frame);
}

#endif
