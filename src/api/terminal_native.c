#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <windows.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <ghostty/vt.h>

#include "api.h"

#define TERMINAL_READ_BUDGET (128u * 1024u)
#define TERMINAL_READ_QUEUE_CAPACITY (4u * 1024u * 1024u)

typedef struct {
  HPCON pseudoconsole;
  HANDLE input_write;
  HANDLE output_read;
  HANDLE process;
  HANDLE process_thread;
  HANDLE job;
  HANDLE reader_thread;
  CRITICAL_SECTION read_lock;
  CONDITION_VARIABLE read_ready;
  uint8_t *read_queue;
  size_t read_queue_head;
  size_t read_queue_count;
  volatile LONG closing;
  bool read_lock_initialized;
  GhosttyTerminal terminal;
  GhosttyRenderState render_state;
  GhosttyRenderStateRowIterator row_iterator;
  GhosttyRenderStateRowCells row_cells;
  GhosttyKeyEncoder key_encoder;
  GhosttyKeyEvent key_event;
  uint16_t cols;
  uint16_t rows;
  uint32_t cell_width;
  uint32_t cell_height;
  bool closed;
  bool running;
} TerminalSession;

static DWORD WINAPI terminal_reader_main(void *userdata) {
  TerminalSession *session = (TerminalSession *)userdata;
  uint8_t buffer[65536];

  while (InterlockedCompareExchange(&session->closing, 0, 0) == 0) {
    DWORD available = 0;
    if (!PeekNamedPipe(session->output_read, NULL, 0, NULL, &available, NULL)) break;
    if (available == 0) {
      Sleep(2);
      continue;
    }
    DWORD read = 0;
    DWORD wanted = available > sizeof(buffer) ? sizeof(buffer) : available;
    if (!ReadFile(session->output_read, buffer, wanted, &read, NULL) || read == 0) break;

    size_t offset = 0;
    EnterCriticalSection(&session->read_lock);
    while (offset < read && InterlockedCompareExchange(&session->closing, 0, 0) == 0) {
      while (session->read_queue_count == TERMINAL_READ_QUEUE_CAPACITY &&
             InterlockedCompareExchange(&session->closing, 0, 0) == 0) {
        SleepConditionVariableCS(&session->read_ready, &session->read_lock, INFINITE);
      }
      if (InterlockedCompareExchange(&session->closing, 0, 0) != 0) break;

      size_t tail = (session->read_queue_head + session->read_queue_count) %
        TERMINAL_READ_QUEUE_CAPACITY;
      size_t available = TERMINAL_READ_QUEUE_CAPACITY - session->read_queue_count;
      size_t contiguous = TERMINAL_READ_QUEUE_CAPACITY - tail;
      size_t amount = read - offset;
      if (amount > available) amount = available;
      if (amount > contiguous) amount = contiguous;
      memcpy(session->read_queue + tail, buffer + offset, amount);
      session->read_queue_count += amount;
      offset += amount;
    }
    LeaveCriticalSection(&session->read_lock);
  }
  return 0;
}

static bool start_terminal_reader(TerminalSession *session) {
  session->read_queue = (uint8_t *)HeapAlloc(
    GetProcessHeap(), 0, TERMINAL_READ_QUEUE_CAPACITY
  );
  if (!session->read_queue) return false;
  InitializeCriticalSection(&session->read_lock);
  session->read_lock_initialized = true;
  InitializeConditionVariable(&session->read_ready);
  session->reader_thread = CreateThread(NULL, 0, terminal_reader_main, session, 0, NULL);
  return session->reader_thread != NULL;
}

static TerminalSession *check_session(lua_State *L, int index) {
  return (TerminalSession *)luaL_checkudata(L, index, API_TYPE_TERMINAL_SESSION);
}

static void close_handle(HANDLE *handle) {
  if (*handle && *handle != INVALID_HANDLE_VALUE) {
    CloseHandle(*handle);
    *handle = NULL;
  }
}

static wchar_t *utf8_to_wide(const char *text) {
  if (!text) return NULL;
  int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
  if (count <= 0) return NULL;
  wchar_t *wide = (wchar_t *)HeapAlloc(GetProcessHeap(), 0, (size_t)count * sizeof(wchar_t));
  if (!wide) return NULL;
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, wide, count)) {
    HeapFree(GetProcessHeap(), 0, wide);
    return NULL;
  }
  return wide;
}

static void push_windows_error(lua_State *L, const char *prefix, DWORD code) {
  char *message = NULL;
  FormatMessageA(
    FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
      FORMAT_MESSAGE_IGNORE_INSERTS,
    NULL, code, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
    (char *)&message, 0, NULL
  );
  if (message) {
    size_t length = strlen(message);
    while (length > 0 && (message[length - 1] == '\r' || message[length - 1] == '\n')) {
      message[--length] = '\0';
    }
    lua_pushfstring(L, "%s: %s", prefix, message);
    LocalFree(message);
  } else {
    lua_pushfstring(L, "%s: Windows error %d", prefix, (int)code);
  }
}

static bool write_all(TerminalSession *session, const uint8_t *data, size_t length) {
  if (!session || session->closed || !session->input_write) return false;
  while (length > 0) {
    DWORD chunk = length > UINT32_MAX ? UINT32_MAX : (DWORD)length;
    DWORD written = 0;
    if (!WriteFile(session->input_write, data, chunk, &written, NULL) || written == 0) {
      return false;
    }
    data += written;
    length -= written;
  }
  return true;
}

static void terminal_write_pty(
  GhosttyTerminal terminal, void *userdata, const uint8_t *data, size_t length
) {
  (void)terminal;
  write_all((TerminalSession *)userdata, data, length);
}

static bool terminal_size(
  GhosttyTerminal terminal, void *userdata, GhosttySizeReportSize *out_size
) {
  (void)terminal;
  TerminalSession *session = (TerminalSession *)userdata;
  if (!session || !out_size) return false;
  out_size->rows = session->rows;
  out_size->columns = session->cols;
  out_size->cell_width = session->cell_width;
  out_size->cell_height = session->cell_height;
  return true;
}

static GhosttyString terminal_version(GhosttyTerminal terminal, void *userdata) {
  (void)terminal;
  (void)userdata;
  static const uint8_t version[] = "Anvil Terminal";
  return (GhosttyString){ .ptr = version, .len = sizeof(version) - 1 };
}

static bool terminal_device_attributes(
  GhosttyTerminal terminal, void *userdata, GhosttyDeviceAttributes *out_attributes
) {
  (void)terminal;
  (void)userdata;
  if (!out_attributes) return false;
  out_attributes->primary.conformance_level = GHOSTTY_DA_CONFORMANCE_VT220;
  out_attributes->primary.features[0] = GHOSTTY_DA_FEATURE_COLUMNS_132;
  out_attributes->primary.features[1] = GHOSTTY_DA_FEATURE_SELECTIVE_ERASE;
  out_attributes->primary.features[2] = GHOSTTY_DA_FEATURE_ANSI_COLOR;
  out_attributes->primary.num_features = 3;
  out_attributes->secondary.device_type = GHOSTTY_DA_DEVICE_TYPE_VT220;
  out_attributes->secondary.firmware_version = 1;
  out_attributes->secondary.rom_cartridge = 0;
  out_attributes->tertiary.unit_id = 0;
  return true;
}

static void free_terminal_objects(TerminalSession *session) {
  if (session->key_event) {
    ghostty_key_event_free(session->key_event);
    session->key_event = NULL;
  }
  if (session->key_encoder) {
    ghostty_key_encoder_free(session->key_encoder);
    session->key_encoder = NULL;
  }
  if (session->row_cells) {
    ghostty_render_state_row_cells_free(session->row_cells);
    session->row_cells = NULL;
  }
  if (session->row_iterator) {
    ghostty_render_state_row_iterator_free(session->row_iterator);
    session->row_iterator = NULL;
  }
  if (session->render_state) {
    ghostty_render_state_free(session->render_state);
    session->render_state = NULL;
  }
  if (session->terminal) {
    ghostty_terminal_free(session->terminal);
    session->terminal = NULL;
  }
}

static void close_session(TerminalSession *session) {
  if (!session || session->closed) return;
  session->closed = true;
  session->running = false;
  InterlockedExchange(&session->closing, 1);

  close_handle(&session->input_write);
  if (session->reader_thread) CancelSynchronousIo(session->reader_thread);
  close_handle(&session->output_read);
  if (session->read_lock_initialized) {
    EnterCriticalSection(&session->read_lock);
    WakeAllConditionVariable(&session->read_ready);
    LeaveCriticalSection(&session->read_lock);
  }
  if (session->reader_thread) {
    WaitForSingleObject(session->reader_thread, INFINITE);
    close_handle(&session->reader_thread);
  }

  if (session->pseudoconsole) {
    ClosePseudoConsole(session->pseudoconsole);
    session->pseudoconsole = NULL;
  }

  if (session->job) {
    close_handle(&session->job);
  } else if (session->process) {
    DWORD exit_code = 0;
    if (GetExitCodeProcess(session->process, &exit_code) && exit_code == STILL_ACTIVE) {
      TerminateProcess(session->process, 1);
    }
  }

  close_handle(&session->process_thread);
  close_handle(&session->process);
  free_terminal_objects(session);
  if (session->read_lock_initialized) {
    DeleteCriticalSection(&session->read_lock);
    session->read_lock_initialized = false;
  }
  if (session->read_queue) {
    HeapFree(GetProcessHeap(), 0, session->read_queue);
    session->read_queue = NULL;
  }
}

static bool initialize_terminal(TerminalSession *session) {
  if (ghostty_terminal_new(NULL, &session->terminal, session->cols, session->rows) != GHOSTTY_SUCCESS) {
    return false;
  }
  if (ghostty_render_state_new(NULL, &session->render_state) != GHOSTTY_SUCCESS) return false;
  if (ghostty_render_state_row_iterator_new(NULL, &session->row_iterator) != GHOSTTY_SUCCESS) return false;
  if (ghostty_render_state_row_cells_new(NULL, &session->row_cells) != GHOSTTY_SUCCESS) return false;
  if (ghostty_key_encoder_new(NULL, &session->key_encoder) != GHOSTTY_SUCCESS) return false;
  if (ghostty_key_event_new(NULL, &session->key_event) != GHOSTTY_SUCCESS) return false;

  ghostty_terminal_set(session->terminal, GHOSTTY_TERMINAL_OPT_USERDATA, session);
  ghostty_terminal_set(
    session->terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, (const void *)terminal_write_pty
  );
  ghostty_terminal_set(
    session->terminal, GHOSTTY_TERMINAL_OPT_SIZE, (const void *)terminal_size
  );
  ghostty_terminal_set(
    session->terminal, GHOSTTY_TERMINAL_OPT_XTVERSION, (const void *)terminal_version
  );
  ghostty_terminal_set(
    session->terminal, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES,
    (const void *)terminal_device_attributes
  );
  ghostty_terminal_resize(
    session->terminal, session->cols, session->rows,
    session->cell_width, session->cell_height
  );
  return ghostty_render_state_update(session->render_state, session->terminal) == GHOSTTY_SUCCESS;
}

static bool create_kill_job(TerminalSession *session) {
  session->job = CreateJobObjectW(NULL, NULL);
  if (!session->job) return false;

  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
  memset(&limits, 0, sizeof(limits));
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(
    session->job, JobObjectExtendedLimitInformation, &limits, sizeof(limits)
  )) {
    close_handle(&session->job);
    return false;
  }
  if (!AssignProcessToJobObject(session->job, session->process)) {
    close_handle(&session->job);
    return false;
  }
  return true;
}

static bool create_shell_process(
  TerminalSession *session, const char *command_utf8, const char *cwd_utf8, DWORD *error_out
) {
  wchar_t *command = utf8_to_wide(command_utf8);
  wchar_t *cwd = cwd_utf8 && cwd_utf8[0] ? utf8_to_wide(cwd_utf8) : NULL;
  if (!command || (cwd_utf8 && cwd_utf8[0] && !cwd)) {
    if (command) HeapFree(GetProcessHeap(), 0, command);
    if (cwd) HeapFree(GetProcessHeap(), 0, cwd);
    *error_out = ERROR_NOT_ENOUGH_MEMORY;
    return false;
  }

  SIZE_T attribute_size = 0;
  InitializeProcThreadAttributeList(NULL, 1, 0, &attribute_size);
  PPROC_THREAD_ATTRIBUTE_LIST attributes =
    (PPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(GetProcessHeap(), 0, attribute_size);
  if (!attributes) {
    HeapFree(GetProcessHeap(), 0, command);
    if (cwd) HeapFree(GetProcessHeap(), 0, cwd);
    *error_out = ERROR_NOT_ENOUGH_MEMORY;
    return false;
  }

  bool initialized = InitializeProcThreadAttributeList(attributes, 1, 0, &attribute_size) != FALSE;
  bool updated = initialized && UpdateProcThreadAttribute(
    attributes, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
    session->pseudoconsole, sizeof(session->pseudoconsole), NULL, NULL
  ) != FALSE;

  STARTUPINFOEXW startup;
  PROCESS_INFORMATION process;
  memset(&startup, 0, sizeof(startup));
  memset(&process, 0, sizeof(process));
  startup.StartupInfo.cb = sizeof(startup);
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  startup.lpAttributeList = attributes;

  bool created = updated && CreateProcessW(
    NULL, command, NULL, NULL, FALSE,
    EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
    NULL, cwd, &startup.StartupInfo, &process
  ) != FALSE;
  *error_out = created ? ERROR_SUCCESS : GetLastError();

  if (initialized) DeleteProcThreadAttributeList(attributes);
  HeapFree(GetProcessHeap(), 0, attributes);
  HeapFree(GetProcessHeap(), 0, command);
  if (cwd) HeapFree(GetProcessHeap(), 0, cwd);

  if (!created) return false;
  session->process = process.hProcess;
  session->process_thread = process.hThread;
  session->running = true;
  create_kill_job(session);
  return true;
}

static bool create_pseudoconsole(
  TerminalSession *session, const char *shell, const char *cwd, DWORD *error_out
) {
  HANDLE input_read = NULL;
  HANDLE output_write = NULL;
  SECURITY_ATTRIBUTES security = {
    .nLength = sizeof(SECURITY_ATTRIBUTES),
    .lpSecurityDescriptor = NULL,
    .bInheritHandle = TRUE,
  };

  if (!CreatePipe(&input_read, &session->input_write, &security, 0) ||
      !CreatePipe(&session->output_read, &output_write, &security, 0)) {
    *error_out = GetLastError();
    close_handle(&input_read);
    close_handle(&output_write);
    return false;
  }
  SetHandleInformation(session->input_write, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(session->output_read, HANDLE_FLAG_INHERIT, 0);

  COORD size = { (SHORT)session->cols, (SHORT)session->rows };
  HRESULT result = CreatePseudoConsole(size, input_read, output_write, 0, &session->pseudoconsole);
  if (FAILED(result)) {
    close_handle(&input_read);
    close_handle(&output_write);
    *error_out = HRESULT_CODE(result);
    return false;
  }

  bool created = false;
  if (shell && shell[0]) {
    created = create_shell_process(session, shell, cwd, error_out);
  } else if (create_shell_process(session, "pwsh.exe -NoLogo", cwd, error_out)) {
    created = true;
  } else {
    created = create_shell_process(session, "powershell.exe -NoLogo", cwd, error_out);
  }
  close_handle(&input_read);
  close_handle(&output_write);
  return created;
}

static int f_terminal_new(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  TerminalSession *session = (TerminalSession *)lua_newuserdata(L, sizeof(*session));
  memset(session, 0, sizeof(*session));
  luaL_setmetatable(L, API_TYPE_TERMINAL_SESSION);

  lua_getfield(L, 1, "cols");
  session->cols = (uint16_t)luaL_optinteger(L, -1, 80);
  lua_pop(L, 1);
  lua_getfield(L, 1, "rows");
  session->rows = (uint16_t)luaL_optinteger(L, -1, 24);
  lua_pop(L, 1);
  lua_getfield(L, 1, "cell_width");
  session->cell_width = (uint32_t)luaL_optinteger(L, -1, 8);
  lua_pop(L, 1);
  lua_getfield(L, 1, "cell_height");
  session->cell_height = (uint32_t)luaL_optinteger(L, -1, 16);
  lua_pop(L, 1);
  if (session->cols == 0) session->cols = 1;
  if (session->rows == 0) session->rows = 1;
  if (session->cell_width == 0) session->cell_width = 1;
  if (session->cell_height == 0) session->cell_height = 1;

  lua_getfield(L, 1, "cwd");
  const char *cwd = lua_isstring(L, -1) ? lua_tostring(L, -1) : NULL;
  lua_getfield(L, 1, "shell");
  const char *shell = lua_isstring(L, -1) ? lua_tostring(L, -1) : NULL;

  DWORD error = ERROR_SUCCESS;
  if (!create_pseudoconsole(session, shell, cwd, &error)) {
    lua_pop(L, 2);
    close_session(session);
    lua_pop(L, 1);
    lua_pushnil(L);
    push_windows_error(L, "Could not start ConPTY", error);
    return 2;
  }
  lua_pop(L, 2);

  if (!start_terminal_reader(session)) {
    close_session(session);
    lua_pop(L, 1);
    lua_pushnil(L);
    lua_pushliteral(L, "Could not start the ConPTY reader");
    return 2;
  }

  if (!initialize_terminal(session)) {
    close_session(session);
    lua_pop(L, 1);
    lua_pushnil(L);
    lua_pushliteral(L, "Could not initialize libghostty-vt");
    return 2;
  }
  return 1;
}

static bool process_running(TerminalSession *session) {
  if (!session->process || session->closed) return false;
  DWORD exit_code = 0;
  if (!GetExitCodeProcess(session->process, &exit_code)) return false;
  return exit_code == STILL_ACTIVE;
}

static int f_terminal_update(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  if (session->closed) {
    lua_pushboolean(L, false);
    lua_pushboolean(L, false);
    return 2;
  }

  uint8_t buffer[65536];
  size_t total = 0;
  bool changed = false;
  while (total < TERMINAL_READ_BUDGET) {
    size_t amount = 0;
    EnterCriticalSection(&session->read_lock);
    if (session->read_queue_count > 0) {
      amount = session->read_queue_count;
      if (amount > sizeof(buffer)) amount = sizeof(buffer);
      if (amount > TERMINAL_READ_BUDGET - total) amount = TERMINAL_READ_BUDGET - total;
      size_t contiguous = TERMINAL_READ_QUEUE_CAPACITY - session->read_queue_head;
      if (amount > contiguous) amount = contiguous;
      memcpy(buffer, session->read_queue + session->read_queue_head, amount);
      session->read_queue_head = (session->read_queue_head + amount) %
        TERMINAL_READ_QUEUE_CAPACITY;
      session->read_queue_count -= amount;
      WakeConditionVariable(&session->read_ready);
    }
    LeaveCriticalSection(&session->read_lock);
    if (amount == 0) break;
    ghostty_terminal_vt_write(session->terminal, buffer, amount);
    total += amount;
    changed = true;
  }

  if (changed) {
    if (ghostty_render_state_update(session->render_state, session->terminal) != GHOSTTY_SUCCESS) {
      changed = false;
    }
  }
  session->running = process_running(session);
  lua_pushboolean(L, changed);
  lua_pushboolean(L, session->running);
  return 2;
}

static int f_terminal_write(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  size_t length = 0;
  const char *text = luaL_checklstring(L, 2, &length);
  lua_pushboolean(L, write_all(session, (const uint8_t *)text, length));
  return 1;
}

static int f_terminal_resize(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  uint16_t cols = (uint16_t)luaL_checkinteger(L, 2);
  uint16_t rows = (uint16_t)luaL_checkinteger(L, 3);
  uint32_t cell_width = (uint32_t)luaL_checkinteger(L, 4);
  uint32_t cell_height = (uint32_t)luaL_checkinteger(L, 5);
  if (session->closed || cols == 0 || rows == 0 || cell_width == 0 || cell_height == 0) {
    lua_pushboolean(L, false);
    return 1;
  }

  COORD size = { (SHORT)cols, (SHORT)rows };
  if (FAILED(ResizePseudoConsole(session->pseudoconsole, size))) {
    lua_pushboolean(L, false);
    return 1;
  }
  if (ghostty_terminal_resize(
    session->terminal, cols, rows, cell_width, cell_height
  ) != GHOSTTY_SUCCESS) {
    lua_pushboolean(L, false);
    return 1;
  }
  session->cols = cols;
  session->rows = rows;
  session->cell_width = cell_width;
  session->cell_height = cell_height;
  ghostty_render_state_update(session->render_state, session->terminal);
  lua_pushboolean(L, true);
  return 1;
}

static GhosttyKey key_from_name(const char *name, uint32_t *codepoint, bool *printable) {
  *codepoint = 0;
  *printable = false;
  if (!name || !name[0]) return GHOSTTY_KEY_UNIDENTIFIED;
  if (name[1] == '\0' && name[0] >= 'a' && name[0] <= 'z') {
    *codepoint = (uint32_t)name[0];
    *printable = true;
    return (GhosttyKey)(GHOSTTY_KEY_A + (name[0] - 'a'));
  }
  if (name[1] == '\0' && name[0] >= '0' && name[0] <= '9') {
    *codepoint = (uint32_t)name[0];
    *printable = true;
    return (GhosttyKey)(GHOSTTY_KEY_DIGIT_0 + (name[0] - '0'));
  }
  if (name[0] == 'f' && name[1] >= '1' && name[1] <= '9') {
    char *end = NULL;
    long number = strtol(name + 1, &end, 10);
    if (end && *end == '\0' && number >= 1 && number <= 25) {
      return (GhosttyKey)(GHOSTTY_KEY_F1 + number - 1);
    }
  }

  struct KeyName { const char *name; GhosttyKey key; uint32_t codepoint; bool printable; };
  static const struct KeyName names[] = {
    { "return", GHOSTTY_KEY_ENTER, 0, false },
    { "enter", GHOSTTY_KEY_ENTER, 0, false },
    { "backspace", GHOSTTY_KEY_BACKSPACE, 0, false },
    { "delete", GHOSTTY_KEY_DELETE, 0, false },
    { "escape", GHOSTTY_KEY_ESCAPE, 0, false },
    { "tab", GHOSTTY_KEY_TAB, 0, false },
    { "left", GHOSTTY_KEY_ARROW_LEFT, 0, false },
    { "right", GHOSTTY_KEY_ARROW_RIGHT, 0, false },
    { "up", GHOSTTY_KEY_ARROW_UP, 0, false },
    { "down", GHOSTTY_KEY_ARROW_DOWN, 0, false },
    { "home", GHOSTTY_KEY_HOME, 0, false },
    { "end", GHOSTTY_KEY_END, 0, false },
    { "pageup", GHOSTTY_KEY_PAGE_UP, 0, false },
    { "pagedown", GHOSTTY_KEY_PAGE_DOWN, 0, false },
    { "insert", GHOSTTY_KEY_INSERT, 0, false },
    { "space", GHOSTTY_KEY_SPACE, ' ', true },
    { "-", GHOSTTY_KEY_MINUS, '-', true },
    { "=", GHOSTTY_KEY_EQUAL, '=', true },
    { "[", GHOSTTY_KEY_BRACKET_LEFT, '[', true },
    { "]", GHOSTTY_KEY_BRACKET_RIGHT, ']', true },
    { "\\", GHOSTTY_KEY_BACKSLASH, '\\', true },
    { ";", GHOSTTY_KEY_SEMICOLON, ';', true },
    { "'", GHOSTTY_KEY_QUOTE, '\'', true },
    { ",", GHOSTTY_KEY_COMMA, ',', true },
    { ".", GHOSTTY_KEY_PERIOD, '.', true },
    { "/", GHOSTTY_KEY_SLASH, '/', true },
    { "`", GHOSTTY_KEY_BACKQUOTE, '`', true },
  };
  for (size_t index = 0; index < sizeof(names) / sizeof(names[0]); index++) {
    if (strcmp(name, names[index].name) == 0) {
      *codepoint = names[index].codepoint;
      *printable = names[index].printable;
      return names[index].key;
    }
  }
  return GHOSTTY_KEY_UNIDENTIFIED;
}

static bool table_bool(lua_State *L, int index, const char *name) {
  lua_getfield(L, index, name);
  bool value = lua_toboolean(L, -1) != 0;
  lua_pop(L, 1);
  return value;
}

static int f_terminal_key(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  const char *name = luaL_checkstring(L, 2);
  luaL_checktype(L, 3, LUA_TTABLE);
  if (session->closed) {
    lua_pushboolean(L, false);
    return 1;
  }

  GhosttyMods mods = 0;
  if (table_bool(L, 3, "shift")) mods |= GHOSTTY_MODS_SHIFT;
  if (table_bool(L, 3, "ctrl")) mods |= GHOSTTY_MODS_CTRL;
  if (table_bool(L, 3, "alt")) mods |= GHOSTTY_MODS_ALT;
  if (table_bool(L, 3, "super")) mods |= GHOSTTY_MODS_SUPER;

  uint32_t codepoint = 0;
  bool printable = false;
  GhosttyKey key = key_from_name(name, &codepoint, &printable);
  if (key == GHOSTTY_KEY_UNIDENTIFIED || (printable && mods == 0)) {
    lua_pushboolean(L, false);
    return 1;
  }

  ghostty_key_encoder_setopt_from_terminal(session->key_encoder, session->terminal);
  ghostty_key_event_set_action(session->key_event, GHOSTTY_KEY_ACTION_PRESS);
  ghostty_key_event_set_key(session->key_event, key);
  ghostty_key_event_set_mods(session->key_event, mods);
  ghostty_key_event_set_consumed_mods(session->key_event, 0);
  ghostty_key_event_set_composing(session->key_event, false);
  ghostty_key_event_set_utf8(session->key_event, NULL, 0);
  ghostty_key_event_set_unshifted_codepoint(session->key_event, codepoint);

  char encoded[128];
  size_t written = 0;
  GhosttyResult result = ghostty_key_encoder_encode(
    session->key_encoder, session->key_event, encoded, sizeof(encoded), &written
  );
  bool ok = result == GHOSTTY_SUCCESS && written > 0 &&
    write_all(session, (const uint8_t *)encoded, written);
  lua_pushboolean(L, ok);
  return 1;
}

static int f_terminal_scroll(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  intptr_t delta = (intptr_t)luaL_checkinteger(L, 2);
  GhosttyTerminalScrollViewport viewport = {
    .tag = GHOSTTY_SCROLL_VIEWPORT_DELTA,
    .value = { .delta = delta },
  };
  ghostty_terminal_scroll_viewport(session->terminal, viewport);
  ghostty_render_state_update(session->render_state, session->terminal);
  lua_pushboolean(L, true);
  return 1;
}

static uint32_t color_value(GhosttyColorRgb color) {
  return ((uint32_t)color.r << 16) | ((uint32_t)color.g << 8) | color.b;
}

static void set_integer_field(lua_State *L, const char *name, lua_Integer value) {
  lua_pushinteger(L, value);
  lua_setfield(L, -2, name);
}

static void set_boolean_field(lua_State *L, const char *name, bool value) {
  lua_pushboolean(L, value);
  lua_setfield(L, -2, name);
}

static void push_cursor(lua_State *L, TerminalSession *session, GhosttyRenderStateColors *colors) {
  bool visible = false;
  bool in_viewport = false;
  uint16_t x = 0;
  uint16_t y = 0;
  GhosttyRenderStateCursorVisualStyle style = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
  ghostty_render_state_get(session->render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &visible);
  ghostty_render_state_get(
    session->render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &in_viewport
  );
  if (in_viewport) {
    ghostty_render_state_get(session->render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &x);
    ghostty_render_state_get(session->render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &y);
  }
  ghostty_render_state_get(
    session->render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &style
  );

  lua_createtable(L, 0, 5);
  set_boolean_field(L, "visible", visible && in_viewport);
  set_integer_field(L, "x", x);
  set_integer_field(L, "y", y);
  set_integer_field(L, "color", color_value(colors->cursor_has_value ? colors->cursor : colors->foreground));
  const char *style_name = "block";
  if (style == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR) style_name = "bar";
  else if (style == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE) style_name = "underline";
  else if (style == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW) style_name = "hollow";
  lua_pushstring(L, style_name);
  lua_setfield(L, -2, "style");
}

static void push_cell(
  lua_State *L, TerminalSession *session, GhosttyRenderStateColors *colors
) {
  uint8_t utf8[128];
  GhosttyBuffer grapheme = { .ptr = utf8, .cap = sizeof(utf8), .len = 0 };
  GhosttyColorRgb foreground = colors->foreground;
  GhosttyColorRgb background = colors->background;
  GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);

  GhosttyResult text_result = ghostty_render_state_row_cells_get(
    session->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &grapheme
  );
  GhosttyResult fg_result = ghostty_render_state_row_cells_get(
    session->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &foreground
  );
  GhosttyResult bg_result = ghostty_render_state_row_cells_get(
    session->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &background
  );
  ghostty_render_state_row_cells_get(
    session->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style
  );

  bool has_text = text_result == GHOSTTY_SUCCESS && grapheme.len > 0;
  bool has_background = bg_result == GHOSTTY_SUCCESS;
  if (!has_text && !has_background) {
    lua_pushboolean(L, false);
    return;
  }
  if (fg_result != GHOSTTY_SUCCESS) foreground = colors->foreground;
  if (bg_result != GHOSTTY_SUCCESS) background = colors->background;
  if (style.inverse) {
    GhosttyColorRgb swap = foreground;
    foreground = background;
    background = swap;
    has_background = true;
  }

  lua_createtable(L, 0, 9);
  if (has_text) {
    lua_pushlstring(L, (const char *)utf8, grapheme.len);
    lua_setfield(L, -2, "text");
  }
  set_integer_field(L, "fg", color_value(foreground));
  if (has_background) set_integer_field(L, "bg", color_value(background));
  if (style.bold) set_boolean_field(L, "bold", true);
  if (style.italic) set_boolean_field(L, "italic", true);
  if (style.invisible) set_boolean_field(L, "invisible", true);
  if (style.strikethrough) set_boolean_field(L, "strikethrough", true);
  if (style.underline) set_integer_field(L, "underline", style.underline);
}

static int f_terminal_snapshot(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  if (!session->render_state) {
    lua_pushnil(L);
    return 1;
  }

  GhosttyRenderStateColors colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
  if (ghostty_render_state_colors_get(session->render_state, &colors) != GHOSTTY_SUCCESS) {
    lua_pushnil(L);
    return 1;
  }

  lua_createtable(L, 0, 8);
  set_integer_field(L, "cols", session->cols);
  set_integer_field(L, "row_count", session->rows);
  set_integer_field(L, "foreground", color_value(colors.foreground));
  set_integer_field(L, "background", color_value(colors.background));
  set_boolean_field(L, "running", session->running);

  GhosttyString title = {0};
  if (ghostty_terminal_get(
    session->terminal, GHOSTTY_TERMINAL_DATA_TITLE, &title
  ) == GHOSTTY_SUCCESS && title.ptr && title.len > 0) {
    lua_pushlstring(L, (const char *)title.ptr, title.len);
    lua_setfield(L, -2, "title");
  }

  push_cursor(L, session, &colors);
  lua_setfield(L, -2, "cursor");

  lua_createtable(L, session->rows, 0);
  if (ghostty_render_state_get(
    session->render_state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
    &session->row_iterator
  ) == GHOSTTY_SUCCESS) {
    int row_index = 1;
    while (ghostty_render_state_row_iterator_next(session->row_iterator)) {
      lua_createtable(L, session->cols, 0);
      if (ghostty_render_state_row_get(
        session->row_iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
        &session->row_cells
      ) == GHOSTTY_SUCCESS) {
        int col_index = 1;
        while (ghostty_render_state_row_cells_next(session->row_cells)) {
          push_cell(L, session, &colors);
          lua_rawseti(L, -2, col_index++);
        }
      }
      lua_rawseti(L, -2, row_index++);
    }
  }
  lua_setfield(L, -2, "rows");
  return 1;
}

static int f_terminal_close(lua_State *L) {
  close_session(check_session(L, 1));
  return 0;
}

static int f_terminal_gc(lua_State *L) {
  close_session(check_session(L, 1));
  return 0;
}

static const luaL_Reg terminal_methods[] = {
  { "update", f_terminal_update },
  { "write", f_terminal_write },
  { "resize", f_terminal_resize },
  { "key", f_terminal_key },
  { "scroll", f_terminal_scroll },
  { "snapshot", f_terminal_snapshot },
  { "close", f_terminal_close },
  { "__gc", f_terminal_gc },
  { NULL, NULL },
};

static const luaL_Reg terminal_module[] = {
  { "new", f_terminal_new },
  { NULL, NULL },
};

int luaopen_terminal_native(lua_State *L) {
  luaL_newmetatable(L, API_TYPE_TERMINAL_SESSION);
  luaL_setfuncs(L, terminal_methods, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);

  luaL_newlib(L, terminal_module);
  return 1;
}
