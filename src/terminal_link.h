#ifndef ANVIL_TERMINAL_LINK_H
#define ANVIL_TERMINAL_LINK_H
#ifdef _WIN32
#include "terminal_protocol.h"
#include <lua.h>

/* Carries the framed records of one Terminal connection between a pipe and Lua. Lua moves the bytes to and
   from the Machine connection. */
typedef struct AnvilTerminalLink AnvilTerminalLink;

/* A remote session's end: an in-process pipe pair. `client_end` gets the other end of the pipe, for the
   session's own reader and writer threads. */
AnvilTerminalLink *anvil_terminal_link_pair(HANDLE *client_end, DWORD *error);
/* After the session's pipe end closes, the link gives Lua one more record of this type, such as CLOSE. */
void anvil_terminal_link_finish(AnvilTerminalLink *link, uint16_t type);
void anvil_terminal_link_release(AnvilTerminalLink *link);
/* Pushes a Lua object that holds its own reference. */
void anvil_terminal_link_push(lua_State *L, AnvilTerminalLink *link);
#endif
#endif
