#ifndef ANVIL_WINDOW_BACKEND_H
#define ANVIL_WINDOW_BACKEND_H
#include "surface_protocol.h"
typedef struct RenWindow RenWindow;

bool anvil_window_hosted(RenWindow *ren);
SDL_Window *anvil_window_create(const char *title, float width, float height);
SDL_Window *anvil_window_dialog_parent(RenWindow *ren);
float anvil_window_scale(RenWindow *ren);
float anvil_window_display_scale(RenWindow *ren);
void anvil_window_initial_display(float *scale, float *refresh);
float anvil_window_refresh_rate(RenWindow *ren);
bool anvil_window_focus(RenWindow *ren);
AnvilSurfaceWindowMode anvil_window_mode(RenWindow *ren);
void anvil_window_bounds(RenWindow *ren, int *x, int *y, int *w, int *h);
void anvil_window_set_bounds(RenWindow *ren, int x, int y, int w, int h);
void anvil_window_title(RenWindow *ren, const char *title);
void anvil_window_set_mode(RenWindow *ren, AnvilSurfaceWindowMode mode);
void anvil_window_bordered(RenWindow *ren, bool bordered);
void anvil_window_visible(RenWindow *ren, bool visible);
bool anvil_window_opacity(RenWindow *ren, float opacity);
void anvil_window_raise(RenWindow *ren);
bool anvil_window_flash(RenWindow *ren, SDL_FlashOperation operation);
void anvil_window_text_input(RenWindow *ren, bool active);
void anvil_window_text_area(RenWindow *ren, const SDL_Rect *rect);
void anvil_window_clear_ime(RenWindow *ren);
void anvil_window_capture(RenWindow *ren, bool active);
void anvil_window_cursor(AnvilSurfaceCursor cursor);
void anvil_window_hit_test(RenWindow *ren, const AnvilSurfaceHitTest *hit);
bool anvil_window_native_frame(RenWindow *ren, bool enable);
bool anvil_window_frame_metrics(RenWindow *ren, int *button, int *title, int *border);
#endif
