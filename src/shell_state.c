#ifdef _WIN32
#include "shell_state.h"
#include <SDL3/SDL.h>
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define STATE_HEADER "anvil-shell-windows 7\n"
/* Version 6 did not retain the Window ID allocation sequence. */
#define STATE_HEADER_6 "anvil-shell-windows 6\n"
/* Version 5 shared Sidebar visibility across Windows. */
#define STATE_HEADER_5 "anvil-shell-windows 5\n"
/* Version 4 kept only the Selected Project in each Window. */
#define STATE_HEADER_4 "anvil-shell-windows 4\n"
/* Version 3 had no Sidebar layout, and version 2 no Project activity. Their Windows still restore. */
#define STATE_HEADER_3 "anvil-shell-windows 3\n"
#define STATE_HEADER_2 "anvil-shell-windows 2\n"

/* Each Window is one line: `window <id> <x> <y> <w> <h> <maximized> <sidebar hidden> <path bytes> <path>`.
 * Each Project activity is one line: `project <unix seconds> <path bytes> <path>`.
 * Other loaded Projects follow their Window: `loaded <window id> <path bytes> <path>`.
 * The shared Sidebar width is one optional line: `sidebar <points>`.
 * `sequence <last Window id>` prevents reuse of a closed Window's saved folds.
 * The optional line `alt-navigation` turns Alt Navigation on. */
char *anvil_shell_state_encode(const AnvilShellState *state, size_t *size) {
  if (state->count > ANVIL_SHELL_STATE_MAX_WINDOWS) return NULL;
  size_t capacity = sizeof(STATE_HEADER) + 64;
  uint32_t last_window_id = state->last_window_id;
  size_t loaded = 0;
  for (size_t i = 0; i < state->count; i++) {
    size_t length = state->windows[i].path ? strlen(state->windows[i].path) : 0;
    if (length > ANVIL_SHELL_STATE_MAX_PATH) return NULL;
    capacity += length + 96;
    const AnvilShellWindowState *window = &state->windows[i];
    if (window->id > last_window_id) last_window_id = window->id;
    if (window->project_count > ANVIL_SHELL_STATE_MAX_PROJECTS - loaded) return NULL;
    loaded += window->project_count;
    for (size_t j = 0; j < window->project_count; j++) {
      length = window->projects[j] ? strlen(window->projects[j]) : 0;
      if (!length || length > ANVIL_SHELL_STATE_MAX_PATH) return NULL;
      capacity += length + 48;
    }
  }
  if (capacity > ANVIL_SHELL_STATE_MAX_BYTES || last_window_id > INT32_MAX) return NULL;
  /* Project activity is best effort. Entries that do not fit are left out; Windows always fit. */
  size_t projects = 0;
  for (size_t i = 0; i < state->project_count && projects < ANVIL_SHELL_STATE_MAX_PROJECTS; i++, projects++) {
    size_t length = strlen(state->projects[i].path);
    if (length > ANVIL_SHELL_STATE_MAX_PATH || capacity + length + 48 > ANVIL_SHELL_STATE_MAX_BYTES) break;
    capacity += length + 48;
  }
  char *data = malloc(capacity);
  if (!data) return NULL;
  size_t n = (size_t)snprintf(data, capacity, "%s", STATE_HEADER);
  n += (size_t)snprintf(data + n, capacity - n, "sequence %u\n", last_window_id);
  if (state->sidebar_points > 0)
    n += (size_t)snprintf(data + n, capacity - n, "sidebar %d\n", state->sidebar_points);
  if (state->alt_navigation) n += (size_t)snprintf(data + n, capacity - n, "alt-navigation\n");
  for (size_t i = 0; i < state->count; i++) {
    const AnvilShellWindowState *window = &state->windows[i];
    const char *path = window->path ? window->path : "";
    n += (size_t)snprintf(data + n, capacity - n, "window %lu %ld %ld %ld %ld %d %d %zu %s\n",
                          (unsigned long)window->id, (long)window->x, (long)window->y, (long)window->w, (long)window->h, window->maximized ? 1 : 0,
                          window->sidebar_hidden ? 1 : 0, strlen(path), path);
    for (size_t j = 0; j < window->project_count; j++)
      n += (size_t)snprintf(data + n, capacity - n, "loaded %lu %zu %s\n", (unsigned long)window->id,
                            strlen(window->projects[j]), window->projects[j]);
  }
  for (size_t i = 0; i < projects; i++) {
    const AnvilShellProjectActivity *project = &state->projects[i];
    n += (size_t)snprintf(data + n, capacity - n, "project %ld %zu %s\n", (long)project->activity,
                          strlen(project->path), project->path);
  }
  *size = n;
  return data;
}

void anvil_shell_window_state_free(AnvilShellWindowState *window) {
  free(window->path);
  for (size_t i = 0; i < window->project_count; i++) free(window->projects[i]);
  free(window->projects);
  *window = (AnvilShellWindowState){0};
}

void anvil_shell_state_free(AnvilShellState *state) {
  for (size_t i = 0; i < state->count; i++) anvil_shell_window_state_free(&state->windows[i]);
  free(state->windows);
  state->windows = NULL;
  state->count = 0;
  for (size_t i = 0; i < state->project_count; i++) free(state->projects[i].path);
  free(state->projects);
  state->projects = NULL;
  state->project_count = 0;
}

static bool read_long(const char **cursor, const char *end, long *value, char separator) {
  const char *p = *cursor;
  bool negative = p < end && *p == '-';
  if (negative) p++;
  if (p >= end || *p < '0' || *p > '9') return false;
  long long result = 0;
  while (p < end && *p >= '0' && *p <= '9') {
    result = result * 10 + (*p++ - '0');
    if (result > 0x7fffffffLL) return false;
  }
  if (p >= end || *p != separator) return false;
  *value = (long)(negative ? -result : result);
  *cursor = p + 1;
  return true;
}

/* Reads `<path bytes> <path>\n` into a new string. */
static bool read_path(const char **cursor, const char *end, long length, char **path) {
  if (length < 0 || length > ANVIL_SHELL_STATE_MAX_PATH || length >= end - *cursor || (*cursor)[length] != '\n' ||
      memchr(*cursor, '\0', (size_t)length))
    return false;
  *path = NULL;
  if (length) {
    *path = malloc((size_t)length + 1);
    if (!*path) return false;
    memcpy(*path, *cursor, (size_t)length);
    (*path)[length] = 0;
  }
  *cursor += length + 1;
  return true;
}

bool anvil_shell_state_decode(const char *data, size_t size, AnvilShellState *state) {
  *state = (AnvilShellState){0};
  size_t header = strlen(STATE_HEADER);
  bool version_2 = size >= header && !memcmp(data, STATE_HEADER_2, header);
  bool version_3 = size >= header && !memcmp(data, STATE_HEADER_3, header);
  bool version_4 = size >= header && !memcmp(data, STATE_HEADER_4, header);
  bool version_5 = size >= header && !memcmp(data, STATE_HEADER_5, header);
  bool version_6 = size >= header && !memcmp(data, STATE_HEADER_6, header);
  bool shared_visibility = version_2 || version_3 || version_4 || version_5;
  if (size > ANVIL_SHELL_STATE_MAX_BYTES || size < header ||
      (memcmp(data, STATE_HEADER, header) && !shared_visibility && !version_6))
    return false;
  const char *cursor = data + header, *end = data + size;
  state->windows = calloc(ANVIL_SHELL_STATE_MAX_WINDOWS, sizeof(*state->windows));
  state->projects = version_2 ? NULL : calloc(ANVIL_SHELL_STATE_MAX_PROJECTS, sizeof(*state->projects));
  if (!state->windows || (!version_2 && !state->projects)) {
    anvil_shell_state_free(state);
    return false;
  }
  bool complete = true;
  bool sidebar_hidden = false;
  bool sequence_seen = false;
  size_t loaded = 0;
  while (cursor < end) {
    long values[8];
    complete = false;
    if (!shared_visibility && !version_6 && end - cursor >= 9 && !memcmp(cursor, "sequence ", 9)) {
      cursor += 9;
      long id;
      if (sequence_seen || !read_long(&cursor, end, &id, '\n') || id < 0) break;
      if ((uint32_t)id > state->last_window_id) state->last_window_id = (uint32_t)id;
      sequence_seen = complete = true;
      continue;
    }
    if (!shared_visibility && !version_6 && end - cursor >= 15 && !memcmp(cursor, "alt-navigation\n", 15)) {
      if (state->alt_navigation) break;
      cursor += 15;
      state->alt_navigation = complete = true;
      continue;
    }
    if (!version_2 && !version_3 && !version_4 && end - cursor >= 7 && !memcmp(cursor, "loaded ", 7)) {
      cursor += 7;
      long id, length;
      if (loaded >= ANVIL_SHELL_STATE_MAX_PROJECTS || !read_long(&cursor, end, &id, ' ') || id <= 0 ||
          !read_long(&cursor, end, &length, ' ') || length <= 0) break;
      AnvilShellWindowState *window = NULL;
      for (size_t i = 0; i < state->count; i++)
        if (state->windows[i].id == (uint32_t)id) { window = &state->windows[i]; break; }
      if (!window) break;
      char **paths = realloc(window->projects, (window->project_count + 1) * sizeof(*paths));
      if (!paths) break;
      window->projects = paths;
      if (!read_path(&cursor, end, length, &paths[window->project_count])) break;
      window->project_count++;
      loaded++;
      complete = true;
      continue;
    }
    if (!version_2 && !version_3 && end - cursor >= 8 && !memcmp(cursor, "sidebar ", 8)) {
      cursor += 8;
      long points;
      if (state->sidebar_points || !read_long(&cursor, end, &points, shared_visibility ? ' ' : '\n') || points <= 0)
        break;
      state->sidebar_points = (int)points;
      if (shared_visibility) {
        if (end - cursor < 2 || (cursor[0] != '0' && cursor[0] != '1') || cursor[1] != '\n') break;
        sidebar_hidden = cursor[0] == '1';
        cursor += 2;
      }
      complete = true;
      continue;
    }
    if (!version_2 && end - cursor >= 8 && !memcmp(cursor, "project ", 8)) {
      cursor += 8;
      long activity, length;
      AnvilShellProjectActivity *project = &state->projects[state->project_count];
      if (state->project_count >= ANVIL_SHELL_STATE_MAX_PROJECTS || !read_long(&cursor, end, &activity, ' ') ||
          activity <= 0 || !read_long(&cursor, end, &length, ' ') || length == 0 ||
          !read_path(&cursor, end, length, &project->path))
        break;
      project->activity = activity;
      state->project_count++;
      complete = true;
      continue;
    }
    if (state->count >= ANVIL_SHELL_STATE_MAX_WINDOWS || end - cursor < 7 || memcmp(cursor, "window ", 7)) break;
    cursor += 7;
    bool ok = true;
    int fields = shared_visibility ? 7 : 8;
    for (int i = 0; ok && i < fields; i++) ok = read_long(&cursor, end, &values[i], ' ');
    for (size_t i = 0; ok && i < state->count; i++) ok = state->windows[i].id != (uint32_t)values[0];
    AnvilShellWindowState *window = &state->windows[state->count];
    if (!ok || values[0] <= 0 || values[3] <= 0 || values[4] <= 0 || (values[5] != 0 && values[5] != 1) ||
        (!shared_visibility && values[6] != 0 && values[6] != 1) ||
        !read_path(&cursor, end, values[fields - 1], &window->path))
      break;
    window->id = (uint32_t)values[0];
    if (window->id > state->last_window_id) state->last_window_id = window->id;
    window->x = values[1];
    window->y = values[2];
    window->w = values[3];
    window->h = values[4];
    window->maximized = values[5] == 1;
    window->sidebar_hidden = !shared_visibility && values[6] == 1;
    state->count++;
    complete = true;
  }
  /* A partial or malformed file restores nothing. */
  if (complete) {
    /* The old global line can follow its Windows. Preserve their visibility on the first upgrade. */
    if (shared_visibility)
      for (size_t i = 0; i < state->count; i++) state->windows[i].sidebar_hidden = sidebar_hidden;
    return true;
  }
  anvil_shell_state_free(state);
  return false;
}

bool anvil_shell_file_replace(const wchar_t *file, const char *data, size_t size) {
  wchar_t temp[MAX_PATH * 4];
  if (_snwprintf(temp, SDL_arraysize(temp), L"%ls.tmp", file) < 0) return false;
  temp[SDL_arraysize(temp) - 1] = 0;
  HANDLE handle = CreateFileW(temp, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  if (handle == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  bool ok = WriteFile(handle, data, (DWORD)size, &written, NULL) && written == size && FlushFileBuffers(handle);
  CloseHandle(handle);
  ok = ok && MoveFileExW(temp, file, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
  if (!ok) DeleteFileW(temp);
  return ok;
}

char *anvil_shell_file_read(const wchar_t *file, size_t limit, size_t *size) {
  HANDLE handle = CreateFileW(file, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
                              FILE_ATTRIBUTE_NORMAL, NULL);
  if (handle == INVALID_HANDLE_VALUE) return NULL;
  LARGE_INTEGER length;
  char *data = NULL;
  DWORD read = 0;
  bool ok = GetFileSizeEx(handle, &length) && (uint64_t)length.QuadPart <= limit &&
            (data = malloc((size_t)length.QuadPart + 1)) &&
            ReadFile(handle, data, (DWORD)length.QuadPart, &read, NULL) && read == length.QuadPart;
  CloseHandle(handle);
  if (!ok) {
    free(data);
    return NULL;
  }
  data[read] = 0;
  *size = read;
  return data;
}

bool anvil_shell_state_load(const wchar_t *file, AnvilShellState *state) {
  *state = (AnvilShellState){0};
  size_t size = 0;
  char *data = anvil_shell_file_read(file, ANVIL_SHELL_STATE_MAX_BYTES, &size);
  bool ok = data && anvil_shell_state_decode(data, size, state);
  free(data);
  return ok;
}

static struct {
  SDL_Mutex *lock;
  SDL_Condition *wake;
  SDL_Semaphore *done;
  SDL_Thread *thread;
  wchar_t *file;
  char *pending;
  size_t pending_size;
  bool stop;
} writer;

static int SDLCALL writer_thread(void *data) {
  (void)data;
  SDL_LockMutex(writer.lock);
  for (;;) {
    while (!writer.pending && !writer.stop) SDL_WaitCondition(writer.wake, writer.lock);
    char *pending = writer.pending;
    size_t size = writer.pending_size;
    writer.pending = NULL;
    if (!pending) break;
    SDL_UnlockMutex(writer.lock);
    if (!anvil_shell_file_replace(writer.file, pending, size))
      SDL_Log("Shell Window state write failed: Windows error=%lu", (unsigned long)GetLastError());
    else
      SDL_Log("Shell Window state written: bytes=%lu", (unsigned long)size);
    free(pending);
    SDL_LockMutex(writer.lock);
  }
  SDL_UnlockMutex(writer.lock);
  SDL_SignalSemaphore(writer.done);
  return 0;
}

bool anvil_shell_state_writer_start(const wchar_t *file) {
  if (writer.thread) return true;
  writer.file = _wcsdup(file);
  writer.lock = SDL_CreateMutex();
  writer.wake = SDL_CreateCondition();
  writer.done = SDL_CreateSemaphore(0);
  if (!writer.file || !writer.lock || !writer.wake || !writer.done) return false;
  writer.thread = SDL_CreateThread(writer_thread, "anvil-shell-state", NULL);
  return writer.thread != NULL;
}

void anvil_shell_state_submit(char *data, size_t size) {
  if (!writer.thread || !data) { free(data); return; }
  SDL_LockMutex(writer.lock);
  free(writer.pending);
  writer.pending = data;
  writer.pending_size = size;
  SDL_SignalCondition(writer.wake);
  SDL_UnlockMutex(writer.lock);
}

bool anvil_shell_state_writer_stop(uint32_t timeout_ms) {
  if (!writer.thread) return true;
  SDL_LockMutex(writer.lock);
  writer.stop = true;
  SDL_SignalCondition(writer.wake);
  SDL_UnlockMutex(writer.lock);
  if (!SDL_WaitSemaphoreTimeout(writer.done, (Sint32)timeout_ms)) {
    SDL_Log("Shell Window state write exceeded its shutdown deadline");
    SDL_DetachThread(writer.thread);
    writer.thread = NULL;
    return false;
  }
  SDL_WaitThread(writer.thread, NULL);
  writer.thread = NULL;
  return true;
}
#endif
