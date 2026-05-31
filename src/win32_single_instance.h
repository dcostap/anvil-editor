#ifndef WIN32_SINGLE_INSTANCE_H
#define WIN32_SINGLE_INSTANCE_H

#include <stdbool.h>
#include <lua.h>
#include <SDL3/SDL_events.h>

#ifdef _WIN32

/* Initializes the native Windows single-instance owner/forwarder.
 *
 * If another Anvil instance already owns the mutex and this process was launched
 * with simple existing regular-file arguments, forwards those absolute file
 * paths to the primary over a named pipe and returns true so the caller can exit
 * successfully before SDL/Lua startup.
 *
 * If this process becomes primary, returns false and keeps the mutex handle for
 * the lifetime of the process.
 */
bool anvil_single_instance_forward_or_own(int argc, char **argv);

/* Starts the named-pipe server for the primary instance. Must be called after
 * SDL and custom events are initialized.
 */
bool anvil_single_instance_start_server(void);

void anvil_single_instance_stop(void);
void anvil_single_instance_set_enabled(bool enabled);

/* Custom-event callback. Pops one pending path and returns:
 *   "singleinstanceopen", path
 */
int anvil_single_instance_event_callback(lua_State *L, SDL_Event *event);

#else

static inline bool anvil_single_instance_forward_or_own(int argc, char **argv) { (void)argc; (void)argv; return false; }
static inline bool anvil_single_instance_start_server(void) { return false; }
static inline void anvil_single_instance_stop(void) {}
static inline void anvil_single_instance_set_enabled(bool enabled) { (void)enabled; }
static inline int anvil_single_instance_event_callback(lua_State *L, SDL_Event *event) { (void)L; (void)event; return 0; }

#endif

#endif
