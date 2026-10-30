#ifndef ANVIL_SHELL_STATE_H
#define ANVIL_SHELL_STATE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <wchar.h>

/* The shell's App State for Anvil Windows. The shell alone writes this file. Lua never reads or writes it. */
#define ANVIL_SHELL_STATE_FILE L"shell-windows.state"
#define ANVIL_SHELL_STATE_MAX_WINDOWS 64
#define ANVIL_SHELL_STATE_MAX_PROJECTS 256
#define ANVIL_SHELL_STATE_MAX_PATH 32768
#define ANVIL_SHELL_STATE_MAX_BYTES (256 * 1024)

typedef struct {
  /* The Window's persistent id. Adopted Projects and saved Sidebar folds name it. */
  uint32_t id;
  /* Normal (restored) bounds in Windows workspace coordinates, as `GetWindowPlacement` reports them. */
  int32_t x, y, w, h;
  bool maximized;
  /* The Selected Project's path, or NULL for an empty Window. */
  char *path;
  /* Other loaded Projects in this Window. The Selected Project is already in `path`. */
  char **projects;
  size_t project_count;
  /* This Window's Project Sidebar visibility. Width remains shared. */
  bool sidebar_hidden;
} AnvilShellWindowState;

/* The last time the user worked in a Project, in Unix seconds. The Project Sidebar groups Projects by it. */
typedef struct {
  char *path;
  int64_t activity;
} AnvilShellProjectActivity;

typedef struct {
  /* Front to back. */
  AnvilShellWindowState *windows;
  size_t count;
  AnvilShellProjectActivity *projects;
  size_t project_count;
  /* The Project Sidebar's width in points, shared by every Window. 0 means the default. */
  int sidebar_points;
  /* Highest allocated Window id, including Windows that closed. Never reuse their folding state. */
  uint32_t last_window_id;
  /* Alt Navigation is on. */
  bool alt_navigation;
} AnvilShellState;

/* Encodes `state`. Returns NULL when it exceeds the bounds above. */
char *anvil_shell_state_encode(const AnvilShellState *state, size_t *size);
/* Decodes a complete file. Returns false for an unknown version, malformed data, or exceeded bounds. */
bool anvil_shell_state_decode(const char *data, size_t size, AnvilShellState *state);
void anvil_shell_state_free(AnvilShellState *state);
/* Frees the owned paths in one Window snapshot. */
void anvil_shell_window_state_free(AnvilShellWindowState *window);

/* Replaces `file` atomically through a temporary file beside it. */
bool anvil_shell_file_replace(const wchar_t *file, const char *data, size_t size);
/* Reads at most `limit` bytes. Returns NULL when `file` is missing, unreadable, or larger. */
char *anvil_shell_file_read(const wchar_t *file, size_t limit, size_t *size);

/* Reads `file`. Returns false when it is missing or invalid. */
bool anvil_shell_state_load(const wchar_t *file, AnvilShellState *state);

/* A worker thread replaces `file` atomically. The latest submitted state wins. */
bool anvil_shell_state_writer_start(const wchar_t *file);
/* Takes ownership of `data`, which `anvil_shell_state_encode` returned. */
void anvil_shell_state_submit(char *data, size_t size);
/* Writes any pending state, then stops. Returns false when that write did not finish within `timeout_ms`. */
bool anvil_shell_state_writer_stop(uint32_t timeout_ms);
#endif
