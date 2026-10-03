#pragma once

/* Native frame behavior for any Anvil top-level HWND. Direct Anvil windows and
 * the shell window share it, so both resize, snap, and drag the same way. */

#if defined(_WIN32)

#include <stdbool.h>
#include <windows.h>

typedef struct {
  int title_height;
  int controls_width;
  int resize_border;      /* <= 0 uses the default border for the window DPI */
  /* Title Bar regions that stay client area, relative to content_x. */
  int client_x, client_width;
  int client2_x, client2_width;
  int content_x;          /* left edge of the app content inside the window */
} Win32FrameHitTest;

/* Adds the native frame styles and DWM attributes, then recomputes the frame. */
void win32_frame_hwnd_apply_style(HWND hwnd, bool no_redirection_bitmap);
void win32_frame_hwnd_update_dwm(HWND hwnd, bool enabled, const COLORREF *frame_color);
LRESULT win32_frame_hwnd_nccalcsize(HWND hwnd, WPARAM wparam, LPARAM lparam);
LRESULT win32_frame_hwnd_hit_test(HWND hwnd, const Win32FrameHitTest *hit, LPARAM lparam);
void win32_frame_hwnd_apply_work_area(HWND hwnd, MINMAXINFO *mmi);
void win32_frame_hwnd_show_system_menu(HWND hwnd, LPARAM lparam);
bool win32_frame_hwnd_is_maximized(HWND hwnd);

#endif
