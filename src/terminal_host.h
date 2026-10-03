#ifndef ANVIL_TERMINAL_HOST_H
#define ANVIL_TERMINAL_HOST_H
#ifdef _WIN32
#include "terminal_protocol.h"
int anvil_terminal_host_main(int argc, char **argv);
bool anvil_terminal_host_launch(AnvilIPCPipe *pipe, HANDLE *process,
                                DWORD *host_pid, DWORD *shell_pid,
                                uint64_t *replay_bytes,
                                const char *userdir, const char *shell, const char *cwd,
                                AnvilTerminalSize size, const size_t *scrollback_lines,
                                DWORD *error);
#endif
#endif
