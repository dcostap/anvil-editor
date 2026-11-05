/* The Terminal link carries the framed records of one Terminal connection between a pipe and Lua
   (`terminal_link.h`). The Machine server opens one to a Terminal host for each remote Client
   (`terminal_link.connect`). A remote session on a Client gets one end of an in-process pipe pair
   (`session:attach_remote`), so its normal reader and writer threads read and write that pipe.
   Lua never waits for a link: its threads connect, read and write. */
#include "../terminal_link.h"
#include "../terminal_host.h"
#include "../ipc_pipe.h"
#include <lauxlib.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define API_TYPE_TERMINAL_LINK "TerminalLink"
/* Records from the pipe wait here for Lua. A full buffer stops the reader, so the host's queue for this Client
   fills. The host then drops a Viewer, or waits for a Controller. */
#define LINK_OUT_LIMIT (8u * 1024u * 1024u)
/* Records from Lua wait here for the pipe. */
#define LINK_IN_LIMIT (2u * 1024u * 1024u)
#define LINK_READ_DEFAULT (1024u * 1024u)
#define LINK_CHUNK (sizeof(AnvilIPCHeader) + ANVIL_TERMINAL_MAX_PAYLOAD)

typedef enum { LINK_CONNECTING, LINK_OPEN, LINK_CLOSED } LinkState;

typedef struct { uint8_t *bytes; size_t offset, length, capacity; } LinkBuffer;

struct AnvilTerminalLink {
  CRITICAL_SECTION lock;
  CONDITION_VARIABLE changed;
  volatile LONG references;
  LinkState state;
  /* Lua closed the link. The writer sends the records that Lua wrote before, then ends the pipe. */
  bool closing, pipe_ready;
  /* The server end of a remote session's pipe (`anvil_terminal_link_pair`). Lua can write any record type. */
  bool pair;
  AnvilIPCPipe pipe;
  HANDLE process;
  DWORD host_pid, shell_pid, error;
  char id[ANVIL_TERMINAL_ID_LENGTH + 1];
  AnvilTerminalSize size;
  AnvilTerminalClientInfo info;
  /* One bit for each record type that Lua may write, unless `pair`. */
  uint64_t allowed;
  uint16_t final_type;
  LinkBuffer out, in;
  /* A link that starts a new host (`terminal_link.launch`). The host writes its record in `userdir`. */
  struct { char *userdir, *project, *shell, *cwd, *datadir; wchar_t *environment; size_t scrollback_lines; } *launch;
};

typedef struct { AnvilTerminalLink *link; } LinkHandle;

static size_t pending(const LinkBuffer *buffer) { return buffer->length - buffer->offset; }

static bool append(LinkBuffer *buffer, const void *data, size_t length) {
  if (buffer->offset && buffer->length + length > buffer->capacity) {
    memmove(buffer->bytes, buffer->bytes + buffer->offset, pending(buffer));
    buffer->length -= buffer->offset; buffer->offset = 0;
  }
  if (buffer->length + length > buffer->capacity) {
    size_t capacity = buffer->capacity ? buffer->capacity : 65536;
    while (capacity < buffer->length + length) capacity *= 2;
    uint8_t *next = realloc(buffer->bytes, capacity);
    if (!next) return false;
    buffer->bytes = next; buffer->capacity = capacity;
  }
  memcpy(buffer->bytes + buffer->length, data, length);
  buffer->length += length;
  if (buffer->offset == buffer->length) buffer->offset = buffer->length = 0;
  return true;
}

/* The length of the whole records at the start, up to `max` bytes but at least one record. */
static size_t whole_records(const uint8_t *bytes, size_t length, size_t max) {
  size_t used = 0;
  while (length - used >= sizeof(AnvilIPCHeader)) {
    AnvilIPCHeader header; memcpy(&header, bytes + used, sizeof(header));
    size_t record = sizeof(header) + header.size;
    if (record > length - used || (used && used + record > max)) break;
    used += record;
  }
  return used;
}

void anvil_terminal_link_release(AnvilTerminalLink *link) {
  if (!link || InterlockedDecrement(&link->references) != 0) return;
  anvil_ipc_pipe_close(&link->pipe);
  if (link->process) CloseHandle(link->process);
  free(link->out.bytes); free(link->in.bytes);
  if (link->launch) {
    free(link->launch->userdir); free(link->launch->project); free(link->launch->shell);
    free(link->launch->cwd); free(link->launch->datadir);
    if (link->launch->environment) FreeEnvironmentStringsW(link->launch->environment);
    free(link->launch);
  }
  DeleteCriticalSection(&link->lock);
  free(link);
}

static AnvilTerminalLink *new_link(void) {
  AnvilTerminalLink *link = calloc(1, sizeof(*link));
  if (!link) return NULL;
  InitializeCriticalSection(&link->lock);
  InitializeConditionVariable(&link->changed);
  link->references = 1;
  return link;
}

static void close_link(AnvilTerminalLink *link, DWORD error) {
  EnterCriticalSection(&link->lock);
  if (link->final_type) {
    AnvilIPCHeader header = { 0, link->final_type, ANVIL_TERMINAL_PROTOCOL_VERSION };
    append(&link->out, &header, sizeof(header));
    link->final_type = 0;
  }
  link->state = LINK_CLOSED;
  if (!link->error) link->error = error ? error : ERROR_BROKEN_PIPE;
  WakeAllConditionVariable(&link->changed);
  LeaveCriticalSection(&link->lock);
  anvil_ipc_pipe_cancel(&link->pipe);
  /* The session keeps a reference, so the handle stays open. A disconnect ends the session's end at once, and
     the session attaches again. */
  if (link->pair) DisconnectNamedPipe(link->pipe.handle);
}

static DWORD WINAPI link_writer(void *userdata) {
  AnvilTerminalLink *link = userdata;
  uint8_t *chunk = malloc(LINK_CHUNK);
  DWORD error = chunk ? ERROR_SUCCESS : ERROR_NOT_ENOUGH_MEMORY;
  while (chunk) {
    EnterCriticalSection(&link->lock);
    while (link->state == LINK_OPEN && !pending(&link->in) && !link->closing)
      SleepConditionVariableCS(&link->changed, &link->lock, INFINITE);
    size_t length = link->state == LINK_OPEN
      ? whole_records(link->in.bytes + link->in.offset, pending(&link->in), LINK_CHUNK) : 0;
    if (length) {
      memcpy(chunk, link->in.bytes + link->in.offset, length);
      link->in.offset += length;
      if (link->in.offset == link->in.length) link->in.offset = link->in.length = 0;
    }
    LeaveCriticalSection(&link->lock);
    if (!length) break;
    if (!anvil_ipc_pipe_write_records(&link->pipe, chunk, (uint32_t)length)) { error = GetLastError(); break; }
  }
  free(chunk);
  /* A closed link ends its pipe only after its last records. */
  close_link(link, error);
  anvil_terminal_link_release(link);
  return 0;
}

static bool start_writer(AnvilTerminalLink *link) {
  InterlockedIncrement(&link->references);
  HANDLE thread = CreateThread(NULL, 0, link_writer, link, 0, NULL);
  if (!thread) { InterlockedDecrement(&link->references); return false; }
  CloseHandle(thread);
  return true;
}

static DWORD WINAPI link_reader(void *userdata) {
  AnvilTerminalLink *link = userdata;
  DWORD error = ERROR_SUCCESS;
  if (!link->pipe_ready) {
    AnvilIPCPipe pipe = {0};
    AnvilTerminalSize size = link->size;
    DWORD shell_pid = 0;
    char id[ANVIL_TERMINAL_ID_LENGTH + 1] = {0};
    bool ok;
    if (link->launch) {
      HANDLE process = NULL; DWORD host_pid = 0; uint64_t replay_bytes = 0;
      ok = anvil_terminal_host_launch(&pipe, &process, &host_pid, &shell_pid, &replay_bytes, id,
        link->launch->userdir, link->launch->project, link->launch->shell, link->launch->cwd, link->launch->datadir,
        NULL, link->launch->environment, false, &size, &link->launch->scrollback_lines, &link->info, NULL, &error);
      if (!ok && process) {
        TerminateProcess(process, 1);
        /* A new host can write its record before it answers. Nothing can revive its shell. */
        if (WaitForSingleObject(process, 5000) == WAIT_OBJECT_0) anvil_terminal_host_discard(link->launch->userdir, id);
      }
      link->process = process; link->host_pid = host_pid;
    } else {
      memcpy(id, link->id, sizeof(id));
      ok = anvil_terminal_host_connect_as(&pipe, link->process, link->host_pid, &shell_pid, id, &size, &link->info,
        &error);
    }
    EnterCriticalSection(&link->lock);
    /* No Client takes a new shell that Lua closed during its start. */
    if (ok && link->closing && link->launch) anvil_ipc_pipe_write(&pipe, ANVIL_TERMINAL_CLOSE, NULL, 0, NULL, 0);
    ok = ok && !link->closing;
    memcpy(link->id, id, sizeof(id));
    if (ok) {
      link->pipe = pipe; link->pipe_ready = true;
      link->shell_pid = shell_pid; link->size = size;
      link->state = LINK_OPEN;
      ok = start_writer(link);
      if (!ok) error = ERROR_NOT_ENOUGH_MEMORY;
    }
    WakeAllConditionVariable(&link->changed);
    LeaveCriticalSection(&link->lock);
    if (!ok) {
      if (!link->pipe_ready) anvil_ipc_pipe_close(&pipe);
      close_link(link, error ? error : ERROR_OPERATION_ABORTED);
      anvil_terminal_link_release(link);
      return 0;
    }
  }
  uint8_t *record = malloc(LINK_CHUNK);
  if (!record) error = ERROR_NOT_ENOUGH_MEMORY;
  while (record) {
    AnvilIPCHeader header;
    if (!anvil_ipc_pipe_read(&link->pipe, &header, record + sizeof(header), ANVIL_TERMINAL_MAX_PAYLOAD)) {
      error = GetLastError();
      break;
    }
    memcpy(record, &header, sizeof(header));
    size_t length = sizeof(header) + header.size;
    EnterCriticalSection(&link->lock);
    while (!link->closing && pending(&link->out) + length > LINK_OUT_LIMIT)
      SleepConditionVariableCS(&link->changed, &link->lock, INFINITE);
    /* Lua does not read a closed link. */
    bool ok = link->closing || append(&link->out, record, length);
    LeaveCriticalSection(&link->lock);
    if (!ok) { error = ERROR_NOT_ENOUGH_MEMORY; break; }
  }
  free(record);
  close_link(link, error);
  anvil_terminal_link_release(link);
  return 0;
}

static bool start_reader(AnvilTerminalLink *link) {
  InterlockedIncrement(&link->references);
  HANDLE thread = CreateThread(NULL, 0, link_reader, link, 0, NULL);
  if (!thread) { InterlockedDecrement(&link->references); return false; }
  CloseHandle(thread);
  return true;
}

AnvilTerminalLink *anvil_terminal_link_pair(HANDLE *client_end, DWORD *error) {
  static volatile LONG counter;
  wchar_t name[128];
  LARGE_INTEGER now; QueryPerformanceCounter(&now);
  swprintf(name, sizeof(name) / sizeof(name[0]), L"\\\\.\\pipe\\anvil-link-%lu-%ld-%llx",
    (unsigned long)GetCurrentProcessId(), (long)InterlockedIncrement(&counter), (unsigned long long)now.QuadPart);
  /* One instance only, and this process connects to it at once. */
  HANDLE server = CreateNamedPipeW(name, PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
    PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, 65536, 65536, 0, NULL);
  if (server == INVALID_HANDLE_VALUE) { *error = GetLastError(); return NULL; }
  HANDLE client = CreateFileW(name, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, NULL);
  if (client == INVALID_HANDLE_VALUE) { *error = GetLastError(); CloseHandle(server); return NULL; }
  AnvilTerminalLink *link = new_link();
  if (!link || !anvil_ipc_pipe_init(&link->pipe, server, ANVIL_TERMINAL_PROTOCOL_VERSION, ANVIL_TERMINAL_MAX_PAYLOAD)) {
    *error = link ? GetLastError() : ERROR_NOT_ENOUGH_MEMORY;
    if (link) anvil_terminal_link_release(link); else CloseHandle(server);
    CloseHandle(client);
    return NULL;
  }
  link->pipe_ready = link->pair = true;
  link->state = LINK_OPEN;
  if (!start_reader(link) || !start_writer(link)) {
    *error = ERROR_NOT_ENOUGH_MEMORY;
    close_link(link, ERROR_NOT_ENOUGH_MEMORY);
    anvil_terminal_link_release(link);
    CloseHandle(client);
    return NULL;
  }
  *client_end = client;
  return link;
}

void anvil_terminal_link_finish(AnvilTerminalLink *link, uint16_t type) {
  if (!link) return;
  EnterCriticalSection(&link->lock);
  if (link->state == LINK_CLOSED) {
    AnvilIPCHeader header = { 0, type, ANVIL_TERMINAL_PROTOCOL_VERSION };
    append(&link->out, &header, sizeof(header));
  } else link->final_type = type;
  LeaveCriticalSection(&link->lock);
}

void anvil_terminal_link_push(lua_State *L, AnvilTerminalLink *link) {
  LinkHandle *handle = lua_newuserdata(L, sizeof(*handle));
  handle->link = link;
  InterlockedIncrement(&link->references);
  luaL_setmetatable(L, API_TYPE_TERMINAL_LINK);
}

static AnvilTerminalLink *check_link(lua_State *L) {
  LinkHandle *handle = luaL_checkudata(L, 1, API_TYPE_TERMINAL_LINK);
  luaL_argcheck(L, handle->link != NULL, 1, "the Terminal link is closed");
  return handle->link;
}

static lua_Integer field_integer(lua_State *L, const char *name, lua_Integer low, lua_Integer high) {
  lua_getfield(L, 1, name);
  lua_Integer value = luaL_checkinteger(L, -1);
  lua_pop(L, 1);
  if (value < low || value > high) luaL_error(L, "%s is out of range", name);
  return value;
}

static void allow(AnvilTerminalLink *link, uint16_t type) { link->allowed |= (uint64_t)1 << type; }

/* A new link for the options table at index 1: the Client's size, its device `name`, and `full` control. */
static AnvilTerminalLink *options_link(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  AnvilTerminalSize size = {
    (uint16_t)field_integer(L, "cols", 1, 32767), (uint16_t)field_integer(L, "rows", 1, 32767),
    (uint32_t)field_integer(L, "cell_width", 1, 65535), (uint32_t)field_integer(L, "cell_height", 1, 65535),
  };
  lua_getfield(L, 1, "name");
  size_t name_length = 0;
  const char *name = luaL_optlstring(L, -1, "", &name_length);
  lua_getfield(L, 1, "full");
  bool full = lua_toboolean(L, -1);
  AnvilTerminalLink *link = new_link();
  if (!link) luaL_error(L, "Could not allocate a Terminal link");
  link->size = size;
  memcpy(link->info.name, name, name_length < sizeof(link->info.name) ? name_length : sizeof(link->info.name) - 1);
  lua_pop(L, 2);
  link->info.flags = full ? 0 : ANVIL_TERMINAL_VIEW_ONLY;
  allow(link, ANVIL_TERMINAL_DETACH);
  if (full) {
    allow(link, ANVIL_TERMINAL_INPUT); allow(link, ANVIL_TERMINAL_RESIZE); allow(link, ANVIL_TERMINAL_TAKE);
    allow(link, ANVIL_TERMINAL_CLEAR); allow(link, ANVIL_TERMINAL_CLOSE); allow(link, ANVIL_TERMINAL_END);
  }
  link->state = LINK_CONNECTING;
  return link;
}

static int push_started(lua_State *L, AnvilTerminalLink *link) {
  if (!start_reader(link)) {
    anvil_terminal_link_release(link);
    return luaL_error(L, "Could not start a Terminal link");
  }
  anvil_terminal_link_push(L, link);
  anvil_terminal_link_release(link);
  return 1;
}

/* `terminal_link.connect {session_id, host_pid, host_creation_time, cols, rows, cell_width, cell_height, name,
   full}` connects to a Terminal host as a Client on another device. Only `full` devices can type, take control
   and close the session. Returns the link, or nil and an error. */
static int f_link_connect(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_getfield(L, 1, "session_id");
  const char *id = luaL_checkstring(L, -1);
  lua_getfield(L, 1, "host_creation_time");
  const char *created = luaL_checkstring(L, -1);
  DWORD pid = (DWORD)field_integer(L, "host_pid", 1, UINT32_MAX);
  if (!anvil_terminal_id_valid(id)) luaL_argerror(L, 1, "invalid Terminal Session ID");
  AnvilTerminalLink *link = options_link(L);
  HANDLE process = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!anvil_terminal_host_identity(process, pid, created)) {
    if (process) CloseHandle(process);
    anvil_terminal_link_release(link);
    lua_pushnil(L);
    lua_pushliteral(L, "The Terminal Session has ended");
    return 2;
  }
  link->process = process; link->host_pid = pid;
  memcpy(link->id, id, sizeof(link->id));
  return push_started(L, link);
}

static char *string_field(lua_State *L, const char *name) {
  lua_getfield(L, 1, name);
  char *copy = _strdup(lua_tostring(L, -1));
  lua_pop(L, 1);
  return copy;
}

/* `terminal_link.launch {project, cwd, shell, scrollback_lines, cols, rows, cell_width, cell_height, name}` starts
   a new host for a Client with Full control, and connects that Client. The status then gives the `session_id`. */
static int f_link_launch(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_pushboolean(L, 1);
  lua_setfield(L, 1, "full");
  size_t scrollback_lines = (size_t)field_integer(L, "scrollback_lines", 0, 100000000);
  const char *fields[] = { "project", "cwd", "shell" };
  for (int i = 0; i < 3; i++) { lua_getfield(L, 1, fields[i]); luaL_checkstring(L, -1); lua_pop(L, 1); }
  AnvilTerminalLink *link = options_link(L);
  link->launch = calloc(1, sizeof(*link->launch));
  if (link->launch) {
    link->launch->project = string_field(L, "project");
    link->launch->cwd = string_field(L, "cwd");
    link->launch->shell = string_field(L, "shell");
    lua_getglobal(L, "USERDIR");
    link->launch->userdir = _strdup(luaL_checkstring(L, -1));
    lua_getglobal(L, "DATADIR");
    link->launch->datadir = _strdup(luaL_checkstring(L, -1));
    lua_pop(L, 2);
    link->launch->environment = GetEnvironmentStringsW();
    link->launch->scrollback_lines = scrollback_lines;
  }
  if (!link->launch || !link->launch->project || !link->launch->cwd || !link->launch->shell ||
      !link->launch->userdir || !link->launch->datadir || !link->launch->environment) {
    anvil_terminal_link_release(link);
    return luaL_error(L, "Could not allocate a Terminal link");
  }
  return push_started(L, link);
}

/* Returns "connecting", "open" or "closed", and a table with the `session_id`, the shell's `shell_pid` and the
   session's size once the host answered. A closed link's table has the Windows `error`. */
static int f_link_status(lua_State *L) {
  AnvilTerminalLink *link = check_link(L);
  EnterCriticalSection(&link->lock);
  LinkState state = link->state;
  DWORD shell_pid = link->shell_pid, error = link->error;
  AnvilTerminalSize size = link->size;
  char id[ANVIL_TERMINAL_ID_LENGTH + 1];
  memcpy(id, link->id, sizeof(id));
  LeaveCriticalSection(&link->lock);
  lua_pushstring(L, state == LINK_CONNECTING ? "connecting" : state == LINK_OPEN ? "open" : "closed");
  lua_createtable(L, 0, 6);
  if (shell_pid) {
    lua_pushstring(L, id); lua_setfield(L, -2, "session_id");
    lua_pushinteger(L, shell_pid); lua_setfield(L, -2, "shell_pid");
    lua_pushinteger(L, size.cols); lua_setfield(L, -2, "cols");
    lua_pushinteger(L, size.rows); lua_setfield(L, -2, "rows");
    lua_pushinteger(L, size.cell_width); lua_setfield(L, -2, "cell_width");
    lua_pushinteger(L, size.cell_height); lua_setfield(L, -2, "cell_height");
  }
  if (state == LINK_CLOSED) { lua_pushinteger(L, error); lua_setfield(L, -2, "error"); }
  return 2;
}

/* Returns whole records, up to `max` bytes but at least one record: "" while none waits, nil after the end. */
static int f_link_read(lua_State *L) {
  AnvilTerminalLink *link = check_link(L);
  lua_Integer max = luaL_optinteger(L, 2, LINK_READ_DEFAULT);
  if (max < 1) max = 1;
  EnterCriticalSection(&link->lock);
  size_t available = pending(&link->out);
  size_t length = whole_records(link->out.bytes + link->out.offset, available, (size_t)max);
  if (!available && link->state == LINK_CLOSED) lua_pushnil(L);
  else lua_pushlstring(L, (const char *)link->out.bytes + link->out.offset, length);
  link->out.offset += length;
  if (link->out.offset == link->out.length) link->out.offset = link->out.length = 0;
  if (length) WakeAllConditionVariable(&link->changed);
  LeaveCriticalSection(&link->lock);
  return 1;
}

/* Queues whole records for the pipe. Returns true, or false and "invalid", "full" or "closed". The link
   refuses the whole write when one record has a type that this link does not allow. */
static int f_link_write(lua_State *L) {
  AnvilTerminalLink *link = check_link(L);
  size_t length = 0;
  const uint8_t *bytes = (const uint8_t *)luaL_checklstring(L, 2, &length);
  size_t used = 0;
  while (used < length) {
    AnvilIPCHeader header;
    if (length - used < sizeof(header)) break;
    memcpy(&header, bytes + used, sizeof(header));
    if (header.size > ANVIL_TERMINAL_MAX_PAYLOAD || header.version != ANVIL_TERMINAL_PROTOCOL_VERSION ||
        header.size > length - used - sizeof(header) ||
        (!link->pair && (header.type >= 64 || !(link->allowed & ((uint64_t)1 << header.type))))) break;
    used += sizeof(header) + header.size;
  }
  const char *refused = used != length ? "invalid" : NULL;
  if (!refused) {
    EnterCriticalSection(&link->lock);
    if (link->closing || link->state == LINK_CLOSED) refused = "closed";
    else if (pending(&link->in) + length > LINK_IN_LIMIT) refused = "full";
    else if (!append(&link->in, bytes, length)) refused = "full";
    else WakeAllConditionVariable(&link->changed);
    LeaveCriticalSection(&link->lock);
  }
  lua_pushboolean(L, refused == NULL);
  if (!refused) return 1;
  lua_pushstring(L, refused);
  return 2;
}

/* `link:close(end_shell)` sends the records that Lua wrote, then ends the connection. It does not wait.
   With `end_shell`, the host then ends its shell. */
static int f_link_close(lua_State *L) {
  LinkHandle *handle = luaL_checkudata(L, 1, API_TYPE_TERMINAL_LINK);
  AnvilTerminalLink *link = handle->link;
  bool end_shell = lua_toboolean(L, 2);
  if (!link) return 0;
  handle->link = NULL;
  EnterCriticalSection(&link->lock);
  /* The writer sends CLOSE after the records before it. A new shell that is still starting gets it too. */
  if (end_shell && link->state == LINK_OPEN && !link->pair) {
    AnvilIPCHeader header = { 0, ANVIL_TERMINAL_CLOSE, ANVIL_TERMINAL_PROTOCOL_VERSION };
    append(&link->in, &header, sizeof(header));
  }
  link->closing = true;
  bool idle = link->state != LINK_OPEN;
  WakeAllConditionVariable(&link->changed);
  LeaveCriticalSection(&link->lock);
  /* A connecting link ends after its connect. An open link's writer ends the pipe. */
  if (idle) anvil_ipc_pipe_cancel(&link->pipe);
  anvil_terminal_link_release(link);
  return 0;
}

static const luaL_Reg link_methods[] = {
  { "status", f_link_status },
  { "read", f_link_read },
  { "write", f_link_write },
  { "close", f_link_close },
  { "__gc", f_link_close },
  { NULL, NULL },
};

/* `terminal_link.host_alive(host_pid, host_creation_time)` is true while that host runs. */
static int f_link_host_alive(lua_State *L) {
  lua_Integer pid = luaL_checkinteger(L, 1);
  const char *created = luaL_checkstring(L, 2);
  HANDLE process = pid > 0 && pid <= UINT32_MAX
    ? OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD)pid) : NULL;
  lua_pushboolean(L, anvil_terminal_host_identity(process, (DWORD)pid, created));
  if (process) CloseHandle(process);
  return 1;
}

static const luaL_Reg link_functions[] = {
  { "connect", f_link_connect },
  { "launch", f_link_launch },
  { "host_alive", f_link_host_alive },
  { NULL, NULL },
};

int luaopen_terminal_link(lua_State *L) {
  luaL_newmetatable(L, API_TYPE_TERMINAL_LINK);
  luaL_setfuncs(L, link_methods, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
  luaL_newlib(L, link_functions);
  return 1;
}
