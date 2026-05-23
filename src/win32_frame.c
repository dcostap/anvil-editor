#if defined(_WIN32)

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <windowsx.h>
#include <dwmapi.h>
#include <SDL3/SDL.h>
#include "renwindow.h"
#include "win32_frame.h"

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif
#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif
#ifndef DWMWCP_DEFAULT
#define DWMWCP_DEFAULT 0
#endif

#define ANVIL_WIN32_FRAME_PROP L"AnvilWin32FrameData"

struct Win32FrameData {
  HWND hwnd;
  WNDPROC old_proc;
  RenWindow *ren;
  bool enabled;
};
typedef struct Win32FrameData Win32FrameData;

static HWND get_hwnd(SDL_Window *window) {
  SDL_PropertiesID props = SDL_GetWindowProperties(window);
  return (HWND) SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WIN32_HWND_POINTER, NULL);
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
    HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
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
    if (client_width > 0 && x >= client_x && x < client_x + client_width) {
      return HTCLIENT;
    }

    if (x >= resize && x < width - controls_width) {
      return HTCAPTION;
    }
  }

  return HTCLIENT;
}

static void push_sdl_mouse_motion(Win32FrameData *frame, LPARAM lparam) {
  if (!frame || !frame->ren || !frame->ren->cache.window) return;

  POINT pt = { GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam) };
  ScreenToClient(frame->hwnd, &pt);

  SDL_Event event;
  SDL_zero(event);
  event.type = SDL_EVENT_MOUSE_MOTION;
  event.motion.windowID = SDL_GetWindowID(frame->ren->cache.window);
  event.motion.x = (float) pt.x;
  event.motion.y = (float) pt.y;
  SDL_PushEvent(&event);
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
      if (frame->enabled) return TRUE;
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
        SDL_Event event;
        SDL_zero(event);
        event.type = SDL_EVENT_WINDOW_MOUSE_LEAVE;
        event.window.windowID = SDL_GetWindowID(frame->ren->cache.window);
        SDL_PushEvent(&event);
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

void win32_frame_set_hit_test(RenWindow *ren, int title_height, int controls_width, int resize_border, int client_x, int client_width) {
  if (!ren) return;
  ren->hit_test_info.title_height = title_height;
  ren->hit_test_info.controls_width = controls_width;
  ren->hit_test_info.resize_border = resize_border;
  ren->hit_test_info.titlebar_client_x = client_x;
  ren->hit_test_info.titlebar_client_width = client_width;
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
