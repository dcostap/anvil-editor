#ifndef ANVIL_CONPTY_H
#define ANVIL_CONPTY_H
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <windows.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct {
  HPCON pseudoconsole;
  HANDLE input_write, output_read, process, process_thread, job;
  uint16_t cols, rows;
} AnvilConPTY;

bool anvil_conpty_start(AnvilConPTY *pty, const char *shell, const char *cwd, DWORD *error);
void anvil_conpty_kill(AnvilConPTY *pty);
void anvil_conpty_close(AnvilConPTY *pty);
#endif
