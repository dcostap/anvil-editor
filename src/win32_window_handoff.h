#ifndef WIN32_WINDOW_HANDOFF_H
#define WIN32_WINDOW_HANDOFF_H

#include <stdbool.h>
#include <stdint.h>
#include <SDL3/SDL.h>

/* Returns -1 for normal Anvil startup. Returns an SDL_AppResult value when the
 * temporary Phase 0 manager handled this process. */
int anvil_window_handoff_run_probe_manager(int argc, char **argv);

void anvil_window_handoff_init_child(void);
bool anvil_window_handoff_is_probe_child(void);
bool anvil_window_handoff_project_is_selected(void);
bool anvil_window_handoff_allow_show(SDL_Window *window);
void anvil_window_handoff_register_window(SDL_Window *window);
void anvil_window_handoff_frame_presented(SDL_Window *window);

/* Returns true when the handoff layer handled one native window message. */
bool anvil_window_handoff_handle_message(
  void *native_window,
  unsigned int message,
  uintptr_t wparam,
  intptr_t lparam,
  intptr_t *result
);

#endif
