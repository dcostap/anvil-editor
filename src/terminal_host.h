#ifndef ANVIL_TERMINAL_HOST_H
#define ANVIL_TERMINAL_HOST_H
#ifdef _WIN32
#include "terminal_protocol.h"
int anvil_terminal_host_main(int argc, char **argv);
bool anvil_terminal_host_launch(AnvilIPCPipe *pipe, HANDLE *process,
                                DWORD *host_pid, DWORD *shell_pid,
                                uint64_t *replay_bytes,
                                char id[ANVIL_TERMINAL_ID_LENGTH + 1],
                                const char *userdir, const char *project,
                                const char *shell, const char *cwd,
                                const char *datadir,
                                const char *revive_from,
                                AnvilTerminalSize *size, const size_t *scrollback_lines,
                                DWORD *error);
bool anvil_terminal_id_valid(const char *id);
bool anvil_terminal_host_identity(HANDLE process, DWORD pid, const char *creation_time);
/* Authentication and handshake. This may wait; recurring reconnects use a worker. */
bool anvil_terminal_host_connect(AnvilIPCPipe *pipe, HANDLE process, DWORD host_pid,
                                 DWORD *shell_pid, const char *id, AnvilTerminalSize *size,
                                 DWORD *error);
/* A fresh authenticated control connection needs no snapshot or model resize. */
bool anvil_terminal_host_control(HANDLE process, DWORD host_pid, const char *id,
                                 uint16_t type, DWORD *error);
#endif
#endif
