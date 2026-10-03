#ifndef ANVIL_SHELL_H
#define ANVIL_SHELL_H

#include <SDL3/SDL.h>

/* Native shell mode: `anvil --shell [args]`.
 *
 * The shell owns the visible window and runs no Lua. It starts one hosted
 * Anvil process with the remaining arguments, forwards input to it, and
 * composites the frames it publishes beside a sidebar strip. The shell exits
 * when the hosted process exits. */

SDL_AppResult anvil_shell_init(void **appstate, int argc, char **argv);
SDL_AppResult anvil_shell_event(void *appstate, SDL_Event *event);
SDL_AppResult anvil_shell_iterate(void *appstate);
void anvil_shell_quit(void *appstate, SDL_AppResult result);

#endif
