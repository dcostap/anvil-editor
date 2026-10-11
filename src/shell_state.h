#ifndef ANVIL_SHELL_STATE_H
#define ANVIL_SHELL_STATE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <wchar.h>

/* The shell's App State for Anvil Windows. The shell alone writes this file. Lua never reads or writes it. */
#define ANVIL_SHELL_STATE_FILE L"shell-windows.state"
#define ANVIL_SHELL_STATE_MAX_WINDOWS 64
#define ANVIL_SHELL_STATE_MAX_PATH 32768
#define ANVIL_SHELL_STATE_MAX_BYTES (256 * 1024)

typedef struct {
  /* Normal (restored) bounds in Windows workspace coordinates, as `GetWindowPlacement` reports them. */
  int32_t x, y, w, h;
  bool maximized;
  /* The Selected Project's path, or NULL for an empty Window. */
  char *path;
} AnvilShellWindowState;

typedef struct {
  /* Front to back. */
  AnvilShellWindowState *windows;
  size_t count;
} AnvilShellState;

/* Encodes `state`. Returns NULL when it exceeds the bounds above. */
char *anvil_shell_state_encode(const AnvilShellState *state, size_t *size);
/* Decodes a complete file. Returns false for an unknown version, malformed data, or exceeded bounds. */
bool anvil_shell_state_decode(const char *data, size_t size, AnvilShellState *state);
void anvil_shell_state_free(AnvilShellState *state);

/* Reads `file`. Returns false when it is missing or invalid. */
bool anvil_shell_state_load(const wchar_t *file, AnvilShellState *state);

/* A worker thread replaces `file` atomically. The latest submitted state wins. */
bool anvil_shell_state_writer_start(const wchar_t *file);
/* Takes ownership of `data`, which `anvil_shell_state_encode` returned. */
void anvil_shell_state_submit(char *data, size_t size);
/* Writes any pending state, then stops. Returns false when that write did not finish within `timeout_ms`. */
bool anvil_shell_state_writer_stop(uint32_t timeout_ms);
#endif
