#include "win32_single_instance.h"

#ifdef _WIN32

#include "custom_events.h"
#include <SDL3/SDL.h>
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define ANVIL_SI_MAGIC      0x414E5651u /* ANVQ */
#define ANVIL_SI_MAX_ARG    (1024u * 1024u)
#define ANVIL_SI_EVENT_NAME "singleinstanceopen"

typedef struct PendingOpen {
  char *path;
  double secondary_elapsed_ms;
  double transport_ms;
  struct PendingOpen *next;
} PendingOpen;

typedef struct ClientThreadParam {
  HANDLE pipe;
} ClientThreadParam;

static char mutex_name[128] = "";
static char pipe_name[128] = "";
static HANDLE primary_mutex = NULL;
static HANDLE server_thread = NULL;
static volatile LONG server_running = 0;
static volatile LONG client_thread_count = 0;
static CRITICAL_SECTION queue_lock;
static bool queue_lock_initialized = false;
static PendingOpen *queue_head = NULL;
static PendingOpen *queue_tail = NULL;

static uint32_t fnv1a_wide(const wchar_t *s) {
  uint32_t h = 2166136261u;
  while (*s) {
    wchar_t ch = *s++;
    h ^= (uint8_t)(ch & 0xffu); h *= 16777619u;
    h ^= (uint8_t)((ch >> 8) & 0xffu); h *= 16777619u;
  }
  return h ? h : 1u;
}

static void init_names(void) {
  if (mutex_name[0]) return;
  wchar_t exe[32768];
  DWORD len = GetModuleFileNameW(NULL, exe, (DWORD)(sizeof(exe) / sizeof(exe[0])));
  exe[len > 0 && len < (DWORD)(sizeof(exe) / sizeof(exe[0])) ? len : 0] = L'\0';
  uint32_t hash = fnv1a_wide(exe);
  snprintf(mutex_name, sizeof(mutex_name), "Local\\AnvilEditorSingleInstanceMutex-%08x", hash);
  snprintf(pipe_name, sizeof(pipe_name), "\\\\.\\pipe\\AnvilEditorSingleInstancePipe-%08x", hash);
}

static bool write_all(HANDLE h, const void *data, DWORD len) {
  const char *p = (const char *)data;
  DWORD total = 0;
  while (total < len) {
    DWORD written = 0;
    if (!WriteFile(h, p + total, len - total, &written, NULL) || written == 0) return false;
    total += written;
  }
  return true;
}

static bool read_all(HANDLE h, void *data, DWORD len) {
  char *p = (char *)data;
  DWORD total = 0;
  while (total < len) {
    DWORD got = 0;
    if (!ReadFile(h, p + total, len - total, &got, NULL) || got == 0) return false;
    total += got;
  }
  return true;
}

static void init_queue_lock(void) {
  if (!queue_lock_initialized) {
    InitializeCriticalSection(&queue_lock);
    queue_lock_initialized = true;
  }
}

static bool utf8_to_wide(const char *s, wchar_t *out, int out_count) {
  if (!s || !out || out_count <= 0) return false;
  int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, out, out_count);
  if (n > 0) return true;
  n = MultiByteToWideChar(CP_ACP, 0, s, -1, out, out_count);
  return n > 0;
}

static char *absolute_regular_file_arg(const char *arg) {
  if (!arg || !*arg) return NULL;
  if (arg[0] == '-') return NULL;

  wchar_t wide[32768];
  if (!utf8_to_wide(arg, wide, (int)(sizeof(wide) / sizeof(wide[0])))) return NULL;

  wchar_t full[32768];
  DWORD full_len = GetFullPathNameW(wide, (DWORD)(sizeof(full) / sizeof(full[0])), full, NULL);
  if (full_len == 0 || full_len >= (DWORD)(sizeof(full) / sizeof(full[0]))) return NULL;

  DWORD attrs = GetFileAttributesW(full);
  if (attrs == INVALID_FILE_ATTRIBUTES || (attrs & FILE_ATTRIBUTE_DIRECTORY)) return NULL;

  int utf8_len = WideCharToMultiByte(CP_UTF8, 0, full, -1, NULL, 0, NULL, NULL);
  if (utf8_len <= 1) return NULL;
  char *out = (char *)SDL_malloc((size_t)utf8_len);
  if (!out) return NULL;
  if (!WideCharToMultiByte(CP_UTF8, 0, full, -1, out, utf8_len, NULL, NULL)) {
    SDL_free(out);
    return NULL;
  }
  return out;
}

static void free_forward_paths(char **paths, int count) {
  if (!paths) return;
  for (int i = 0; i < count; i++) SDL_free(paths[i]);
  SDL_free(paths);
}

static char **collect_simple_absolute_files(int argc, char **argv, int *out_count) {
  if (out_count) *out_count = 0;
  if (argc <= 1 || !out_count) return NULL;

  int count = argc - 1;
  char **paths = (char **)SDL_calloc((size_t)count, sizeof(char *));
  if (!paths) return NULL;

  for (int i = 0; i < count; i++) {
    paths[i] = absolute_regular_file_arg(argv[i + 1]);
    if (!paths[i]) {
      free_forward_paths(paths, count);
      return NULL;
    }
  }

  *out_count = count;
  return paths;
}

static void enqueue_path(const char *path, uint32_t len, double secondary_elapsed_ms, double transport_ms) {
  if (!path || len == 0) return;
  init_queue_lock();
  PendingOpen *node = (PendingOpen *)SDL_calloc(1, sizeof(PendingOpen));
  if (!node) return;
  node->path = (char *)SDL_malloc((size_t)len + 1);
  if (!node->path) {
    SDL_free(node);
    return;
  }
  SDL_memcpy(node->path, path, len);
  node->path[len] = '\0';
  node->secondary_elapsed_ms = secondary_elapsed_ms;
  node->transport_ms = transport_ms;

  EnterCriticalSection(&queue_lock);
  if (queue_tail) queue_tail->next = node; else queue_head = node;
  queue_tail = node;
  LeaveCriticalSection(&queue_lock);
}

static PendingOpen *dequeue_node(void) {
  init_queue_lock();
  EnterCriticalSection(&queue_lock);
  PendingOpen *node = queue_head;
  if (node) {
    queue_head = node->next;
    if (!queue_head) queue_tail = NULL;
  }
  LeaveCriticalSection(&queue_lock);
  return node;
}

static bool queue_has_items(void) {
  init_queue_lock();
  EnterCriticalSection(&queue_lock);
  bool has = queue_head != NULL;
  LeaveCriticalSection(&queue_lock);
  return has;
}

static void push_open_event(void) {
  CustomEvent event;
  SDL_zero(event);
  push_custom_event(ANVIL_SI_EVENT_NAME, &event);
}

static bool forward_args_to_primary(int argc, char **argv, int64_t start_counter) {
  int forward_count = 0;
  char **forward_paths = collect_simple_absolute_files(argc, argv, &forward_count);
  if (!forward_paths || forward_count <= 0) return false;

  HANDLE pipe = INVALID_HANDLE_VALUE;
  DWORD start = GetTickCount();
  while (GetTickCount() - start < 1000) {
    pipe = CreateFileA(pipe_name, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
    if (pipe != INVALID_HANDLE_VALUE) break;
    if (GetLastError() != ERROR_PIPE_BUSY && GetLastError() != ERROR_FILE_NOT_FOUND) {
      free_forward_paths(forward_paths, forward_count);
      return false;
    }
    WaitNamedPipeA(pipe_name, 50);
  }
  if (pipe == INVALID_HANDLE_VALUE) {
    free_forward_paths(forward_paths, forward_count);
    return false;
  }

  LARGE_INTEGER freq_li, send_li;
  QueryPerformanceFrequency(&freq_li);
  QueryPerformanceCounter(&send_li);
  int64_t freq = freq_li.QuadPart;
  int64_t send_counter = send_li.QuadPart;

  uint32_t magic = ANVIL_SI_MAGIC;
  uint32_t count = (uint32_t)forward_count;
  bool ok = write_all(pipe, &magic, sizeof(magic))
         && write_all(pipe, &count, sizeof(count))
         && write_all(pipe, &freq, sizeof(freq))
         && write_all(pipe, &start_counter, sizeof(start_counter))
         && write_all(pipe, &send_counter, sizeof(send_counter));
  for (int i = 0; ok && i < forward_count; i++) {
    uint32_t len = (uint32_t)strlen(forward_paths[i]);
    ok = len > 0 && len <= ANVIL_SI_MAX_ARG
      && write_all(pipe, &len, sizeof(len))
      && write_all(pipe, forward_paths[i], len);
  }

  uint32_t ack = 0;
  if (ok) ok = read_all(pipe, &ack, sizeof(ack)) && ack == ANVIL_SI_MAGIC;
  CloseHandle(pipe);
  free_forward_paths(forward_paths, forward_count);
  return ok;
}

bool anvil_single_instance_forward_or_own(int argc, char **argv) {
  LARGE_INTEGER app_start_li;
  QueryPerformanceCounter(&app_start_li);
  init_names();
  primary_mutex = CreateMutexA(NULL, TRUE, mutex_name);
  if (!primary_mutex) return false;

  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    CloseHandle(primary_mutex);
    primary_mutex = NULL;
    return forward_args_to_primary(argc, argv, app_start_li.QuadPart);
  }

  return false;
}

static void handle_pipe_client(HANDLE pipe) {
  LARGE_INTEGER receive_li;
  QueryPerformanceCounter(&receive_li);

  uint32_t magic = 0;
  uint32_t count = 0;
  int64_t sender_freq = 0, sender_start = 0, sender_send = 0;
  bool ok = read_all(pipe, &magic, sizeof(magic)) && magic == ANVIL_SI_MAGIC
         && read_all(pipe, &count, sizeof(count)) && count < 1024
         && read_all(pipe, &sender_freq, sizeof(sender_freq)) && sender_freq > 0
         && read_all(pipe, &sender_start, sizeof(sender_start))
         && read_all(pipe, &sender_send, sizeof(sender_send));

  double secondary_elapsed_ms = sender_freq > 0 ? ((double)(receive_li.QuadPart - sender_start) * 1000.0 / (double)sender_freq) : -1.0;
  double transport_ms = sender_freq > 0 ? ((double)(receive_li.QuadPart - sender_send) * 1000.0 / (double)sender_freq) : -1.0;

  char **paths = NULL;
  uint32_t *lens = NULL;
  if (ok && count > 0) {
    paths = (char **)SDL_calloc(count, sizeof(char *));
    lens = (uint32_t *)SDL_calloc(count, sizeof(uint32_t));
    if (!paths || !lens) ok = false;
  }

  for (uint32_t i = 0; ok && i < count; i++) {
    uint32_t len = 0;
    ok = read_all(pipe, &len, sizeof(len)) && len > 0 && len <= ANVIL_SI_MAX_ARG;
    if (!ok) break;
    paths[i] = (char *)SDL_malloc((size_t)len + 1);
    if (!paths[i]) { ok = false; break; }
    ok = read_all(pipe, paths[i], len);
    if (ok) {
      paths[i][len] = '\0';
      lens[i] = len;
    }
  }

  uint32_t ack = ok ? ANVIL_SI_MAGIC : 0;
  ok = ok && write_all(pipe, &ack, sizeof(ack));
  FlushFileBuffers(pipe);

  if (ok && InterlockedCompareExchange(&server_running, 1, 1)) {
    for (uint32_t i = 0; i < count; i++) {
      enqueue_path(paths[i], lens[i], secondary_elapsed_ms, transport_ms);
      push_open_event();
    }
  }

  if (paths) {
    for (uint32_t i = 0; i < count; i++) SDL_free(paths[i]);
    SDL_free(paths);
  }
  SDL_free(lens);
}

static DWORD WINAPI pipe_client_proc(LPVOID param) {
  ClientThreadParam *client = (ClientThreadParam *)param;
  if (client && client->pipe != INVALID_HANDLE_VALUE) {
    handle_pipe_client(client->pipe);
    DisconnectNamedPipe(client->pipe);
    CloseHandle(client->pipe);
  }
  SDL_free(client);
  InterlockedDecrement(&client_thread_count);
  return 0;
}

static DWORD WINAPI pipe_server_proc(LPVOID param) {
  (void)param;
  while (InterlockedCompareExchange(&server_running, 1, 1)) {
    HANDLE pipe = CreateNamedPipeA(
      pipe_name,
      PIPE_ACCESS_DUPLEX,
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
      PIPE_UNLIMITED_INSTANCES,
      4096,
      4096,
      0,
      NULL
    );
    if (pipe == INVALID_HANDLE_VALUE) {
      Sleep(30);
      continue;
    }

    BOOL connected = ConnectNamedPipe(pipe, NULL) ? TRUE : (GetLastError() == ERROR_PIPE_CONNECTED);
    if (connected && InterlockedCompareExchange(&server_running, 1, 1)) {
      ClientThreadParam *client = (ClientThreadParam *)SDL_calloc(1, sizeof(ClientThreadParam));
      HANDLE thread = NULL;
      if (client) {
        client->pipe = pipe;
        InterlockedIncrement(&client_thread_count);
        thread = CreateThread(NULL, 0, pipe_client_proc, client, 0, NULL);
        if (!thread) InterlockedDecrement(&client_thread_count);
      }
      if (thread) {
        CloseHandle(thread);
        pipe = INVALID_HANDLE_VALUE;
      } else {
        SDL_free(client);
        DisconnectNamedPipe(pipe);
        CloseHandle(pipe);
      }
    } else {
      DisconnectNamedPipe(pipe);
      CloseHandle(pipe);
    }
  }
  return 0;
}

bool anvil_single_instance_start_server(void) {
  if (!primary_mutex) return false;
  init_names();
  if (!register_custom_event(ANVIL_SI_EVENT_NAME, anvil_single_instance_event_callback)) return false;
  init_queue_lock();
  InterlockedExchange(&server_running, 1);
  server_thread = CreateThread(NULL, 0, pipe_server_proc, NULL, 0, NULL);
  if (!server_thread) {
    InterlockedExchange(&server_running, 0);
    return false;
  }
  return true;
}

void anvil_single_instance_stop(void) {
  InterlockedExchange(&server_running, 0);
  bool stopped = true;
  if (server_thread) {
    CancelSynchronousIo(server_thread);
    HANDLE pipe = CreateFileA(pipe_name, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
    if (pipe != INVALID_HANDLE_VALUE) CloseHandle(pipe);
    stopped = WaitForSingleObject(server_thread, 1000) == WAIT_OBJECT_0;
    if (stopped) {
      CloseHandle(server_thread);
      server_thread = NULL;
    }
  }
  if (primary_mutex && (stopped || !server_thread)) {
    ReleaseMutex(primary_mutex);
    CloseHandle(primary_mutex);
    primary_mutex = NULL;
  }
  while (queue_has_items()) {
    PendingOpen *node = dequeue_node();
    if (node) {
      SDL_free(node->path);
      SDL_free(node);
    }
  }
  DWORD wait_start = GetTickCount();
  while (InterlockedCompareExchange(&client_thread_count, 0, 0) > 0 && GetTickCount() - wait_start < 1000) {
    Sleep(10);
  }
  /* Client-handler threads are detached and a malicious partial client may keep
   * one blocked. server_running is false so late handlers will not enqueue or
   * push events, and the queue lock remains alive for process lifetime. */
}

void anvil_single_instance_set_enabled(bool enabled) {
  if (!enabled) anvil_single_instance_stop();
}

int anvil_single_instance_event_callback(lua_State *L, SDL_Event *event) {
  (void)event;
  PendingOpen *node = dequeue_node();
  if (!node) return 0;
  lua_pushstring(L, ANVIL_SI_EVENT_NAME);
  lua_pushstring(L, node->path);
  lua_pushnumber(L, node->secondary_elapsed_ms);
  lua_pushnumber(L, node->transport_ms);
  SDL_free(node->path);
  SDL_free(node);
  if (queue_has_items()) push_open_event();
  return 4;
}

#endif
