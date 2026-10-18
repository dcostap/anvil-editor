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
bool anvil_hosted_surface_sidebar(void);
/* Consume shell packets on the UI thread in pipe order. */
bool anvil_hosted_surface_dispatch(const SDL_Event *event);
/* Apply the next packet only after the UI consumes previous events. */
void anvil_hosted_surface_poll(void);
/* Waits up to seconds for a shell message. False without one or outside a hosted Project. */
bool anvil_hosted_surface_wait_inbound(double seconds);
bool anvil_hosted_surface_take_sidebar_query_needed(void);
bool anvil_hosted_surface_configuration_event(Uint32 type);
uint32_t anvil_hosted_surface_shell_pid(void);
void anvil_hosted_surface_controls(int *x, int *y, int *w, int *h);
bool anvil_hosted_surface_restarted(void);
bool anvil_hosted_surface_parse_valid(void);
bool anvil_hosted_surface_loss_event(Uint32 type);
/* After shell loss, a Project waits for the next shell to adopt it. `await_adoption` reports that its save
 * finished and returns false when this process cannot be adopted; it then exits as before. */
bool anvil_hosted_surface_await_adoption(void);
bool anvil_hosted_surface_adopted_event(Uint32 type);
bool anvil_hosted_surface_gone_event(Uint32 type);
/* Applies the adopting shell's configuration on the UI thread and sends it this Project's window state. */
void anvil_hosted_surface_finish_adoption(void);
void anvil_hosted_surface_exit_intent(const char *restart_path);
void anvil_hosted_surface_close_decision(AnvilSurfaceCloseDecision decision);
void anvil_hosted_surface_dialog_result_failed(void);
void anvil_hosted_surface_test_packet(bool stale);
void anvil_hosted_surface_test_memory_release_failure(void);
void anvil_hosted_surface_render_failed(const char *cause);
bool anvil_hosted_surface_show_dialog(uint32_t id, SDL_FileDialogType type, SDL_PropertiesID props, SDL_DialogFileCallback callback, void *userdata);

/* The first window created in hosted mode becomes the hosted surface. */
void anvil_hosted_surface_register_window(SDL_Window *window);
void anvil_hosted_surface_unregister_window(SDL_Window *window);
size_t anvil_hosted_surface_sidebar_views(uint32_t *ids, bool *removed, size_t capacity);
bool anvil_hosted_surface_sidebar_activate(uint32_t id);
bool anvil_hosted_surface_move_project(uint32_t project_id, uint32_t target_window_id);
bool anvil_hosted_surface_is_window(SDL_Window *window);

void anvil_hosted_surface_publish_d3d11(SDL_Window *window, const char *name, int width, int height);
/* Records the background of the frame being published, R | G << 8 | B << 16 | A << 24. */
void anvil_hosted_surface_set_background(SDL_Window *window, uint32_t background);
/* Records the modal overlay dim of the frame being published, or zero, and up to ANVIL_SURFACE_RAISED_MAX areas
 * shown above the Sidebar. */
void anvil_hosted_surface_set_overlay(SDL_Window *window, uint32_t overlay, const AnvilSurfaceArea *raised,
                                      int count);
/* The left edge of the Project UI inside the full-window surface; zero when not hosted. */
int anvil_hosted_surface_content_x(void);
bool anvil_hosted_surface_publish_software(SDL_Window *window, SDL_Surface *surface,
                                           const SDL_Rect *rects, int count);

bool anvil_hosted_surface_has_focus(void);
bool anvil_hosted_surface_should_render(void);
bool anvil_hosted_surface_select_project(const char *path);
bool anvil_hosted_surface_new_window(void);
uint32_t anvil_hosted_surface_window_id(void);
bool anvil_hosted_surface_open_project_window(const char *path);
bool anvil_hosted_surface_open_project_picker(void);
/* Sends a Color Theme preview for the Sidebar to draw, or "" to draw the saved Color Theme again. */
bool anvil_hosted_surface_preview_color_theme(const char *preview);
bool anvil_hosted_surface_unload_project(const char *path);
/* id is a Terminal Session id, or empty when the active view shows none. The shell keeps it across adoption. */
bool anvil_hosted_surface_focused_terminal(const char *id);
/* The Sidebar asks the shell to select a Project and focus one of its Terminal Sessions. */
bool anvil_hosted_surface_select_terminal(const char *path, const char *id);
/* The Sidebar asks the shell for a row's Project actions menu at a point in Sidebar surface pixels. */
bool anvil_hosted_surface_project_menu(uint32_t row_id, int x, int y);
/* Asks the shell to hide the Project Sidebar in every Window, or to show it again. */
bool anvil_hosted_surface_toggle_sidebar(void);
/* Tells the shell that this Project saved a Color Theme, so other processes reload it. */
bool anvil_hosted_surface_color_theme_saved(void);
/* The shell draws this Project's Window controls in these colours while the Project is selected. */
bool anvil_hosted_surface_set_shell_colors(const AnvilSurfaceShellColors *colors);
bool anvil_hosted_surface_sidebar_source(const char *userdir, const char *recents);
bool anvil_hosted_surface_sidebar_query(int offset, bool refresh);
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
