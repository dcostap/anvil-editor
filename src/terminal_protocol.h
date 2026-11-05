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
  ANVIL_TERMINAL_ACTIVATE,
  /* A uint32_t token. Reply only after a fresh probe finds no running command. */
  ANVIL_TERMINAL_EDITOR_REQUEST,
  /* The UTF-8 path of the Project that now owns the session, without a terminator. Hosts that write
     movable = true in their record accept it. */
  ANVIL_TERMINAL_PROJECT,
  /* Ends the shell but keeps the record, the screen and the agent report for revival. Older hosts read it as a
     disconnect and keep running. */
  ANVIL_TERMINAL_END,
  /* An AnvilTerminalTake. The keystroke that took control follows as INPUT. Hosts that write shared = true in
     their record accept it. The host refuses an old generation, so two requests cannot both win. */
  ANVIL_TERMINAL_TAKE,
  /* Shell input for an automatic agent resume. Empty input declines agent resume after revival. */
  ANVIL_TERMINAL_RESUME_AGENT,
  ANVIL_TERMINAL_WELCOME = 64, ANVIL_TERMINAL_REPLAY, ANVIL_TERMINAL_REPLAY_END,
  ANVIL_TERMINAL_OUTPUT, ANVIL_TERMINAL_EXITED, ANVIL_TERMINAL_STATUS,
  /* The request token. This reply also reports that the shell is idle. */
  ANVIL_TERMINAL_EDITOR_READY,
  /* An AnvilTerminalRole. It comes before each snapshot, and after a granted TAKE. Older hosts send none,
     and their one client controls. */
  ANVIL_TERMINAL_ROLE,
};
#define ANVIL_TERMINAL_NAME_LENGTH 64
typedef struct { uint16_t cols, rows; uint32_t cell_width, cell_height; } AnvilTerminalSize;
typedef struct { char id[ANVIL_TERMINAL_ID_LENGTH + 1]; AnvilTerminalSize size;
  uint32_t client_pid, replay; } AnvilTerminalHello;
/* Ask for the connection ID in WELCOME. After an older host refuses it, retry with the old HELLO. */
#define ANVIL_TERMINAL_REPLAY_CLIENT_ID 2u
/* Optional after the HELLO: the Client's device name, and ANVIL_TERMINAL_VIEW_ONLY for a Client that never
   controls. A HELLO without it names the host's own PC. */
#define ANVIL_TERMINAL_VIEW_ONLY 1u
typedef struct { char name[ANVIL_TERMINAL_NAME_LENGTH]; uint32_t flags; } AnvilTerminalClientInfo;
typedef struct { uint32_t generation; AnvilTerminalSize size; } AnvilTerminalTake;
/* `clients` counts the attached Clients, this one included. */
typedef struct { uint32_t generation, controller, clients; AnvilTerminalSize size;
  char controller_name[ANVIL_TERMINAL_NAME_LENGTH]; } AnvilTerminalRole;
typedef struct { uint32_t host_pid, shell_pid, state; AnvilTerminalSize size; } AnvilTerminalWelcome;
typedef struct { AnvilTerminalWelcome welcome; uint32_t client_id; } AnvilTerminalWelcomeClient;
typedef struct { uint32_t busy; char agent_app[32], agent_model[257]; char agent_state[16]; } AnvilTerminalStatus;
typedef struct { uint32_t exit_code; } AnvilTerminalExited;
#endif
