#ifndef ANVIL_TERMINAL_PROTOCOL_H
#define ANVIL_TERMINAL_PROTOCOL_H
#include "ipc_pipe.h"
#define ANVIL_TERMINAL_PROTOCOL_VERSION 3u
#define ANVIL_TERMINAL_MAX_PAYLOAD (64u * 1024u)
#define ANVIL_TERMINAL_ID_LENGTH 32
#define ANVIL_TERMINAL_DRAIN_QUIET_MS 250u
#define ANVIL_TERMINAL_DRAIN_MAX_MS 5000u
enum {
  ANVIL_TERMINAL_HELLO = 1, ANVIL_TERMINAL_INPUT, ANVIL_TERMINAL_RESIZE,
  ANVIL_TERMINAL_CLOSE, ANVIL_TERMINAL_DETACH, ANVIL_TERMINAL_CLEAR,
  ANVIL_TERMINAL_WELCOME = 64, ANVIL_TERMINAL_REPLAY, ANVIL_TERMINAL_REPLAY_END,
  ANVIL_TERMINAL_OUTPUT, ANVIL_TERMINAL_EXITED, ANVIL_TERMINAL_STATUS,
};
typedef struct { uint16_t cols, rows; uint32_t cell_width, cell_height; } AnvilTerminalSize;
typedef struct { char id[ANVIL_TERMINAL_ID_LENGTH + 1]; AnvilTerminalSize size;
  uint32_t client_pid, replay; } AnvilTerminalHello;
typedef struct { uint32_t host_pid, shell_pid, state; AnvilTerminalSize size; } AnvilTerminalWelcome;
typedef struct { uint32_t busy; } AnvilTerminalStatus;
typedef struct { uint32_t exit_code; } AnvilTerminalExited;
#endif
