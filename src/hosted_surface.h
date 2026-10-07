#ifndef ANVIL_HOSTED_SURFACE_H
#define ANVIL_HOSTED_SURFACE_H

#include <stdbool.h>
#include <SDL3/SDL.h>
#include "surface_protocol.h"

/* Hosted mode: a native shell owns the visible window and this process
 * renders its first Anvil window offscreen. The SDL window stays hidden and
 * keeps the existing size and event paths working. Window-bound requests are
 * sent to the shell instead of the hidden window. */

/* Removes the hosted pipe argument from argv. Returns true in hosted mode. */
bool anvil_hosted_surface_parse_args(int *argc, char **argv);
/* Connects to the shell, waits for its first CONFIGURE, and starts the input
 * reader. Needs the SDL event subsystem. */
bool anvil_hosted_surface_connect(void);
bool anvil_hosted_surface_active(void);
/* Consume shell packets on the UI thread in pipe order. */
bool anvil_hosted_surface_dispatch(const SDL_Event *event);
/* Apply the next packet only after the UI consumes previous events. */
void anvil_hosted_surface_poll(void);
bool anvil_hosted_surface_configuration_event(Uint32 type);
uint32_t anvil_hosted_surface_shell_pid(void);
void anvil_hosted_surface_controls(int *x, int *y, int *w, int *h);
bool anvil_hosted_surface_restarted(void);
bool anvil_hosted_surface_parse_valid(void);
bool anvil_hosted_surface_loss_event(Uint32 type);
void anvil_hosted_surface_exit_intent(const char *restart_path);
void anvil_hosted_surface_close_decision(AnvilSurfaceCloseDecision decision);
void anvil_hosted_surface_dialog_result_failed(void);
void anvil_hosted_surface_test_packet(bool stale);
void anvil_hosted_surface_test_memory_release_failure(void);
void anvil_hosted_surface_render_failed(const char *cause);
bool anvil_hosted_surface_show_dialog(uint32_t id, SDL_FileDialogType type, SDL_PropertiesID props, SDL_DialogFileCallback callback, void *userdata);

/* The first window created in hosted mode becomes the hosted surface. */
void anvil_hosted_surface_register_window(SDL_Window *window);
bool anvil_hosted_surface_is_window(SDL_Window *window);

void anvil_hosted_surface_publish_d3d11(SDL_Window *window, const char *name, int width, int height);
bool anvil_hosted_surface_publish_software(SDL_Window *window, SDL_Surface *surface,
                                           const SDL_Rect *rects, int count);

bool anvil_hosted_surface_has_focus(void);
float anvil_hosted_surface_display_scale(void);
float anvil_hosted_surface_refresh_rate(void);
AnvilSurfaceWindowMode anvil_hosted_surface_window_mode(void);
void anvil_hosted_surface_window_bounds(int *x, int *y, int *w, int *h);

void anvil_hosted_surface_set_cursor(AnvilSurfaceCursor cursor);
void anvil_hosted_surface_set_text_input(bool active);
void anvil_hosted_surface_set_text_input_area(const SDL_Rect *rect, int cursor);
void anvil_hosted_surface_clear_ime(void);
void anvil_hosted_surface_set_window_mode(AnvilSurfaceWindowMode mode);
void anvil_hosted_surface_set_title(const char *title);
void anvil_hosted_surface_set_hit_test(const AnvilSurfaceHitTest *hit_test);
void anvil_hosted_surface_set_bordered(bool bordered);
void anvil_hosted_surface_set_bounds(int x, int y, int w, int h);
void anvil_hosted_surface_raise(void);
void anvil_hosted_surface_flash(int operation);
void anvil_hosted_surface_set_visible(bool visible);
bool anvil_hosted_surface_set_opacity(float opacity);
bool anvil_hosted_surface_frame_metrics(int *button, int *title, int *border);

#endif
