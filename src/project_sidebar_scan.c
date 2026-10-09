#include "project_sidebar_scan.h"
#ifdef _WIN32
#include "api/api.h"
#ifdef LUA_JIT
#include <luajit.h>
#endif
#include "terminal_host.h"
#include <windows.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>

struct AnvilSidebarScan {
  SDL_Thread *thread;
  SDL_AtomicInt done, stop;
  bool success, limited, delay;
  char *userdir, *recents;
  char *known[ANVIL_SIDEBAR_PROJECT_LIMIT];
  size_t known_count;
  wchar_t *(*resolve)(const char *);
  AnvilSidebarModel result;
};
static wchar_t *wide(const char *value) {
  int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, NULL, 0);
  wchar_t *result = size ? malloc(size * sizeof(*result)) : NULL;
  if (result)
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, result, size);
  return result;
}
static char *normalized(AnvilSidebarScan *job, const char *path) {
  wchar_t *identity = job->resolve(path);
  if (!identity)
    return strdup(path);
  char *text = SDL_iconv_string("UTF-8", "UTF-16LE", (char *)identity,
                                (wcslen(identity) + 1) * sizeof(*identity));
  free(identity);
  char *result = text ? strdup(text) : NULL;
  SDL_free(text);
  return result;
}
typedef struct {
  size_t bytes;
} ScanMemory;
static void *bounded_alloc(void *data, void *pointer, size_t old_size, size_t size) {
  ScanMemory *memory = data;
  if (!pointer)
    old_size = 0;
  if (!size) {
    free(pointer);
    memory->bytes -= old_size;
    return NULL;
  }
  if (size > 8u * 1024u * 1024u || memory->bytes - old_size > 8u * 1024u * 1024u - size)
    return NULL;
  void *result = realloc(pointer, size);
  if (result)
    memory->bytes = memory->bytes - old_size + size;
  return result;
}
static void instruction_limit(lua_State *L, lua_Debug *debug) {
  (void)debug;
  luaL_error(L, "Sidebar record instruction limit");
}
static bool decode(lua_State *L, const char *text, size_t size) {
  lua_settop(L, 0);
  lua_gc(L, LUA_GCCOLLECT, 0);
  lua_sethook(L, instruction_limit, LUA_MASKCOUNT, 10000);
  if (luaL_loadbuffer(L, text, size, "=Sidebar source"))
    return false;
  lua_newtable(L);
#if LUA_VERSION_NUM < 502
  lua_setfenv(L, -2);
#else
  lua_setupvalue(L, -2, 1);
#endif
  bool ok = !lua_pcall(L, 0, 1, 0) && lua_istable(L, -1);
  void *memory = NULL;
  lua_getallocf(L, &memory);
  return ok && ((ScanMemory *)memory)->bytes <= 4u * 1024u * 1024u;
}
static const char *string_field(lua_State *L, const char *key) {
  lua_getfield(L, 1, key);
  size_t length = 0;
  const char *text = lua_type(L, -1) == LUA_TSTRING ? lua_tolstring(L, -1, &length) : NULL;
  if (!text || length >= 32768 || memchr(text, 0, length))
    text = NULL;
  lua_pop(L, 1);
  return text;
}
static bool boolean_field(lua_State *L, const char *key, bool *value) {
  lua_getfield(L, 1, key);
  bool valid = lua_isboolean(L, -1);
  *value = lua_toboolean(L, -1);
  lua_pop(L, 1);
  return valid;
}
static bool recent_paths(AnvilSidebarScan *job, lua_State *L) {
  size_t source_size = strlen(job->recents);
  char *source = malloc(source_size + 8);
  if (!source)
    return false;
  snprintf(source, source_size + 8, "return %s", job->recents);
  bool decoded = decode(L, source, strlen(source));
  free(source);
  if (!decoded)
    return false;
  size_t count = lua_rawlen(L, 1);
  count = SDL_min(count, ANVIL_SIDEBAR_PROJECT_LIMIT);
  char *paths[ANVIL_SIDEBAR_PROJECT_LIMIT] = {0};
  bool ok = true;
  for (size_t i = 0; i < count; i++) {
    lua_rawgeti(L, 1, (int)i + 1);
    size_t length = 0;
    const char *path = lua_type(L, -1) == LUA_TSTRING ? lua_tolstring(L, -1, &length) : NULL;
    if (!path || !length || length >= 32768 || memchr(path, 0, length) ||
        !(paths[i] = normalized(job, path)))
      ok = false;
    lua_pop(L, 1);
    if (!ok || SDL_GetAtomicInt(&job->stop))
      break;
  }
  if (ok && !SDL_GetAtomicInt(&job->stop))
    ok = anvil_sidebar_merge_recents(&job->result, (const char *const *)paths, count);
  else
    ok = false;
  for (size_t i = 0; i < count; i++)
    free(paths[i]);
  /* Known runtime paths stay listed even when another source omits them. */
  if (ok) {
    bool seeded = job->result.seeded;
    job->result.seeded = false;
    for (size_t i = 0; i < job->known_count; i++) {
      AnvilSidebarProject *known_row = anvil_sidebar_find(&job->result, job->known[i]);
      if (known_row) {
        known_row->state = ANVIL_SIDEBAR_STARTING;
        continue;
      }
      const char *path = job->known[i];
      if (!anvil_sidebar_merge_recents(&job->result, &path, 1)) {
        ok = false;
        break;
      }
      anvil_sidebar_find(&job->result, path)->state = ANVIL_SIDEBAR_STARTING;
    }
    job->result.seeded = seeded;
  }
  for (size_t i = 0; ok && i < job->result.count; i++) {
    wchar_t *path = wide(job->result.projects[i]->path);
    DWORD attributes = path ? GetFileAttributesW(path) : INVALID_FILE_ATTRIBUTES;
    job->result.projects[i]->exists =
        attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY);
    free(path);
  }
  return ok;
}
static char *read_record(const wchar_t *path, size_t *length, size_t *budget) {
  HANDLE file =
      CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                  OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  if (file == INVALID_HANDLE_VALUE)
    return NULL;
  LARGE_INTEGER size;
  char *text = NULL;
  if (GetFileSizeEx(file, &size) && size.QuadPart > 0 && size.QuadPart <= 1024 * 1024 &&
      (size_t)size.QuadPart <= *budget) {
    *budget -= (size_t)size.QuadPart;
    text = malloc((size_t)size.QuadPart + 1);
    DWORD read;
    if (!text || !ReadFile(file, text, (DWORD)size.QuadPart, &read, NULL) ||
        read != size.QuadPart) {
      free(text);
      text = NULL;
    } else {
      *length = read;
      text[read] = 0;
    }
  }
  CloseHandle(file);
  return text;
}
static int session_order(const void *left, const void *right) {
  return strcmp(((const AnvilSidebarTerminal *)left)->id,
                ((const AnvilSidebarTerminal *)right)->id);
}
static void terminal_records(AnvilSidebarScan *job, lua_State *L) {
  char *directory = malloc(32768);
  if (!directory) {
    job->limited = true;
    return;
  }
  int length = snprintf(directory, 32768, "%s/terminal-sessions/", job->userdir);
  if (length < 0 || length + 40 >= 32768) {
    free(directory);
    job->limited = true;
    return;
  }
  strcat(directory, "*.lua");
  wchar_t *pattern = wide(directory);
  WIN32_FIND_DATAW entry;
  HANDLE search = pattern ? FindFirstFileW(pattern, &entry) : INVALID_HANDLE_VALUE;
  free(pattern);
  if (search == INVALID_HANDLE_VALUE) {
    DWORD error = GetLastError();
    job->limited = error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND;
    free(directory);
    return;
  }
  size_t files = 0, budget = 8u * 1024u * 1024u;
  do {
    if (SDL_GetAtomicInt(&job->stop)) {
      job->limited = true;
      break;
    }
    if (++files > 512 || !budget) {
      job->limited = true;
      break;
    }
    if (wcslen(entry.cFileName) != 36 || wcscmp(entry.cFileName + 32, L".lua"))
      continue;
    char id[33];
    bool valid_name = true;
    for (size_t i = 0; i < 32; i++) {
      if (entry.cFileName[i] > 127)
        valid_name = false;
      id[i] = (char)entry.cFileName[i];
    }
    id[32] = 0;
    if (!valid_name || !anvil_terminal_id_valid(id))
      continue;
    snprintf(directory + length, 32768 - length, "%s.lua", id);
    wchar_t *path = wide(directory);
    size_t bytes = 0;
    char *text = path ? read_record(path, &bytes, &budget) : NULL;
    free(path);
    bool decoded = text && decode(L, text, bytes);
    free(text);
    if (!decoded) {
      job->limited = true;
      continue;
    }
    const char *record_id = string_field(L, "session_id");
    const char *project_path = string_field(L, "project_path");
    const char *created = string_field(L, "host_creation_time");
    const char *status = string_field(L, "status");
    lua_getfield(L, 1, "version");
    bool version = lua_isnumber(L, -1) && lua_tonumber(L, -1) == 1;
    lua_pop(L, 1);
    if (!version || !record_id || strcmp(record_id, id) || !project_path || !created ||
        strlen(created) != 16 || strspn(created, "0123456789abcdef") != 16 || !status ||
        (strcmp(status, "running") && strcmp(status, "exited"))) {
      job->limited = true;
      continue;
    }
    char *canonical = normalized(job, project_path);
    AnvilSidebarProject *project = canonical ? anvil_sidebar_find(&job->result, canonical) : NULL;
    free(canonical);
    if (!project)
      continue;
    if (project->terminal_count == ANVIL_SIDEBAR_TERMINAL_LIMIT) {
      job->limited = true;
      continue;
    }
    lua_getfield(L, 1, "host_pid");
    double pid = lua_isnumber(L, -1) ? lua_tonumber(L, -1) : 0;
    lua_pop(L, 1);
    if (!isfinite(pid) || pid <= 0 || pid > UINT32_MAX || pid != (uint32_t)pid) {
      job->limited = true;
      continue;
    }
    AnvilSidebarTerminal terminal = {.host_pid = (uint32_t)pid, .busy = -1, .bell = -1};
    memcpy(terminal.id, id, sizeof(id));
    bool busy = true;
    if (boolean_field(L, "busy", &busy))
      terminal.busy = busy;
    boolean_field(L, "attached", &terminal.attached);
    terminal.state =
        !strcmp(status, "exited") ? ANVIL_SIDEBAR_TERMINAL_EXITED : ANVIL_SIDEBAR_TERMINAL_RUNNING;
    if (terminal.state == ANVIL_SIDEBAR_TERMINAL_RUNNING) {
      HANDLE process =
          OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, terminal.host_pid);
      if (process) {
        DWORD waited = WaitForSingleObject(process, 0);
        SetLastError(ERROR_SUCCESS);
        if (waited == WAIT_OBJECT_0)
          terminal.state = ANVIL_SIDEBAR_TERMINAL_LOST;
        else if (!anvil_terminal_host_identity(process, terminal.host_pid, created)) {
          if (waited == WAIT_TIMEOUT && GetLastError() == ERROR_SUCCESS)
            terminal.state = ANVIL_SIDEBAR_TERMINAL_LOST;
          else
            terminal.busy = -1;
        }
        CloseHandle(process);
      } else if (GetLastError() == ERROR_INVALID_PARAMETER)
        terminal.state = ANVIL_SIDEBAR_TERMINAL_LOST;
      else
        terminal.busy = -1;
    }
    if (terminal.state != ANVIL_SIDEBAR_TERMINAL_RUNNING) {
      terminal.attached = false;
      terminal.busy = -1;
    }
    const char *cwd = string_field(L, "cwd"), *title = string_field(L, "shell");
    /* Cwd is a path, not an arbitrary control payload. */
    if (cwd)
      for (const unsigned char *p = (const unsigned char *)cwd; *p; p++)
        if (*p < 32) {
          cwd = NULL;
          break;
        }
    terminal.cwd = strdup(cwd ? cwd : "");
    size_t title_size = title ? SDL_min(strlen(title), 256) : 0;
    if (title && title_size < strlen(title))
      while (title_size && ((unsigned char)title[title_size] & 0xc0) == 0x80)
        title_size--;
    terminal.title = malloc(title_size + 1);
    if (terminal.title) {
      memcpy(terminal.title, title ? title : "", title_size);
      terminal.title[title_size] = 0;
    }
    AnvilSidebarTerminal *sessions =
        realloc(project->terminals, (project->terminal_count + 1) * sizeof(*sessions));
    if (!terminal.title || !terminal.cwd || !sessions) {
      if (sessions)
        project->terminals = sessions;
      free(terminal.title);
      free(terminal.cwd);
      job->limited = true;
      continue;
    }
    project->terminals = sessions;
    project->terminals[project->terminal_count++] = terminal;
  } while (FindNextFileW(search, &entry));
  FindClose(search);
  free(directory);
  for (size_t i = 0; i < job->result.count; i++) {
    AnvilSidebarProject *project = job->result.projects[i];
    if (project->terminal_count)
      qsort(project->terminals, project->terminal_count, sizeof(*project->terminals),
            session_order);
  }
}
static int SDLCALL scan_thread(void *data) {
  AnvilSidebarScan *job = data;
  if (job->delay) {
    SDL_Log("Shell paused the owned Sidebar status worker");
    Uint64 until = SDL_GetTicks() + 7000;
    while (SDL_GetTicks() < until && !SDL_GetAtomicInt(&job->stop))
      SDL_Delay(10);
  }
  ScanMemory memory = {0};
  lua_State *L = lua_newstate(bounded_alloc, &memory);
#ifdef LUA_JIT
  if (L)
    luaJIT_setmode(L, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_OFF);
#endif
  job->success = L && !SDL_GetAtomicInt(&job->stop) && recent_paths(job, L);
  if (job->success)
    terminal_records(job, L);
  if (L)
    lua_close(L);
  SDL_SetAtomicInt(&job->done, 1);
  return 0;
}
AnvilSidebarScan *anvil_sidebar_scan_start(const char *userdir, const char *recents,
                                           const AnvilSidebarModel *known,
                                           wchar_t *(*resolve)(const char *), bool delay) {
  AnvilSidebarScan *job = calloc(1, sizeof(*job));
  if (!job)
    return NULL;
  job->userdir = strdup(userdir);
  job->recents = strdup(recents);
  job->resolve = resolve;
  job->delay = delay;
  if (!job->userdir || !job->recents)
    goto failed;
  for (size_t i = 0; i < known->count; i++) {
    if (known->projects[i]->state == ANVIL_SIDEBAR_DORMANT)
      continue;
    job->known[job->known_count] = strdup(known->projects[i]->path);
    if (!job->known[job->known_count++])
      goto failed;
  }
  job->thread = SDL_CreateThread(scan_thread, "anvil-sidebar-status", job);
  if (job->thread)
    return job;
failed:
  anvil_sidebar_scan_free(job);
  return NULL;
}
bool anvil_sidebar_scan_done(AnvilSidebarScan *job) { return SDL_GetAtomicInt(&job->done) != 0; }
const AnvilSidebarModel *anvil_sidebar_scan_result(AnvilSidebarScan *job, bool *limited) {
  if (!anvil_sidebar_scan_done(job))
    return NULL;
  *limited = job->limited;
  return job->success ? &job->result : NULL;
}
bool anvil_sidebar_scan_stop(AnvilSidebarScan *job, Uint64 deadline) {
  SDL_SetAtomicInt(&job->stop, 1);
  while (!anvil_sidebar_scan_done(job)) {
    if (SDL_GetTicks() >= deadline)
      return false;
    SDL_Delay(1);
  }
  return true;
}
void anvil_sidebar_scan_free(AnvilSidebarScan *job) {
  if (job->thread)
    SDL_WaitThread(job->thread, NULL);
  anvil_sidebar_destroy(&job->result);
  for (size_t i = 0; i < job->known_count; i++)
    free(job->known[i]);
  free(job->userdir);
  free(job->recents);
  free(job);
}
#endif
