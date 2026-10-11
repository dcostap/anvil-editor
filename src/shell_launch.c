#ifdef _WIN32
#include "shell_launch.h"
#include "cli_args.h"
#include "surface_protocol.h"
#include <SDL3/SDL.h>
#include <sddl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LAUNCH_MAGIC 0x53564E41u /* ANVS */
#define LAUNCH_VERSION 1u
#define LAUNCH_FLAG_FOREGROUND 1u
#define LAUNCH_MAX_ARGS 64u
#define LAUNCH_MAX_TEXT 32768u
#define LAUNCH_MAX_BYTES (512u * 1024u)
#define LAUNCH_MAX_CLIENTS 16
/* The launcher's whole budget, including retries while a shell starts or ends. */
#define LAUNCH_FORWARD_MS 15000
/* The shell's budget for one request's resolution and startup. It is below the launcher's. */
#define LAUNCH_REPLY_MS 10000
#define LAUNCH_READ_MS 2000

struct AnvilShellLaunchRequest {
  LONG references;
  HANDLE done;
  LONG status;
  DWORD client_pid;
  bool foreground;
  char *cwd;
  int argc;
  char **argv;
};

static wchar_t mutex_name[96], pipe_name[128], user_dir[32768];
static HANDLE owner_mutex, stop_event, server_thread;
static PSECURITY_DESCRIPTOR pipe_security;
static volatile LONG client_count;
static bool (*notify_request)(AnvilShellLaunchRequest *);

static bool path_exists(const wchar_t *path) {
  DWORD attrs = GetFileAttributesW(path);
  return attrs != INVALID_FILE_ATTRIBUTES;
}

/* Mirrors USERDIR in data/core/start.lua. Each user directory has its own shell. */
static bool user_directory(const wchar_t *exe, wchar_t *out, DWORD size) {
  wchar_t candidate[MAX_PATH * 4], value[MAX_PATH * 4];
  const wchar_t *slash = wcsrchr(exe, L'\\');
  candidate[0] = 0;
  if (slash && _snwprintf(candidate, SDL_arraysize(candidate), L"%.*ls\\user", (int)(slash - exe), exe) > 0 &&
      path_exists(candidate)) {
  } else if (GetEnvironmentVariableW(L"ANVIL_USERDIR", value, SDL_arraysize(value)) - 1 < SDL_arraysize(value) - 1) {
    wcscpy(candidate, value);
  } else if (GetEnvironmentVariableW(L"XDG_CONFIG_HOME", value, SDL_arraysize(value)) - 1 < SDL_arraysize(value) - 1) {
    _snwprintf(candidate, SDL_arraysize(candidate), L"%ls\\anvil", value);
  } else if (GetEnvironmentVariableW(L"USERPROFILE", value, SDL_arraysize(value)) - 1 < SDL_arraysize(value) - 1) {
    _snwprintf(candidate, SDL_arraysize(candidate), L"%ls\\.config\\anvil", value);
  } else {
    return false;
  }
  candidate[SDL_arraysize(candidate) - 1] = 0;
  DWORD n = GetFullPathNameW(candidate, size, out, NULL);
  return n && n < size;
}

static uint32_t hash_text(uint32_t hash, const wchar_t *text) {
  for (; *text; text++) {
    wchar_t ch = (wchar_t)(uintptr_t)CharLowerW((LPWSTR)(uintptr_t)*text);
    if (ch == L'/') ch = L'\\';
    hash = (hash ^ (ch & 0xff)) * 16777619u;
    hash = (hash ^ (ch >> 8)) * 16777619u;
  }
  return hash;
}

bool anvil_shell_user_directory(wchar_t *out, DWORD size) {
  wchar_t exe[32768];
  DWORD length = GetModuleFileNameW(NULL, exe, SDL_arraysize(exe));
  if (!length || length >= SDL_arraysize(exe) || !user_directory(exe, out, size)) {
    if (size) out[0] = 0;
    return false;
  }
  size_t end = wcslen(out);
  while (end > 3 && (out[end - 1] == L'\\' || out[end - 1] == L'/')) out[--end] = 0;
  return true;
}

static bool init_names(void) {
  if (mutex_name[0]) return true;
  wchar_t exe[32768], *userdir = user_dir;
  DWORD length = GetModuleFileNameW(NULL, exe, SDL_arraysize(exe));
  if (!length || length >= SDL_arraysize(exe) || !anvil_shell_user_directory(userdir, SDL_arraysize(user_dir)))
    return false;
  uint32_t hash = hash_text(hash_text(2166136261u, exe), L"\n");
  hash = hash_text(hash, userdir);
  DWORD session = 0;
  ProcessIdToSessionId(GetCurrentProcessId(), &session);
  _snwprintf(mutex_name, SDL_arraysize(mutex_name), L"Local\\AnvilShell-%08x", hash);
  _snwprintf(pipe_name, SDL_arraysize(pipe_name), L"\\\\.\\pipe\\AnvilShell-%lu-%08x", (unsigned long)session, hash);
  SDL_Log("Shell launch key=%08x session=%lu", hash, (unsigned long)session);
  return true;
}

static PSID current_user(void) {
  HANDLE token;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return NULL;
  static union { TOKEN_USER user; BYTE bytes[256]; } info;
  DWORD size = 0;
  bool ok = GetTokenInformation(token, TokenUser, &info, sizeof(info), &size);
  CloseHandle(token);
  return ok ? info.user.User.Sid : NULL;
}

/* Both ends run the same executable as the same user in the same session. */
bool anvil_shell_same_identity(DWORD pid) {
  wchar_t own[32768], other[32768];
  DWORD own_size = GetModuleFileNameW(NULL, own, SDL_arraysize(own)), other_size = SDL_arraysize(other);
  DWORD own_session = 0, other_session = 1;
  if (!pid || !own_size || !ProcessIdToSessionId(GetCurrentProcessId(), &own_session) ||
      !ProcessIdToSessionId(pid, &other_session) || own_session != other_session)
    return false;
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process) return false;
  bool ok = QueryFullProcessImageNameW(process, 0, other, &other_size) &&
            CompareStringOrdinal(own, -1, other, -1, TRUE) == CSTR_EQUAL;
  HANDLE token = NULL;
  union { TOKEN_USER user; BYTE bytes[256]; } info;
  DWORD size = 0;
  PSID self = current_user();
  ok = ok && self && OpenProcessToken(process, TOKEN_QUERY, &token) &&
       GetTokenInformation(token, TokenUser, &info, sizeof(info), &size) && EqualSid(self, info.user.User.Sid);
  if (token) CloseHandle(token);
  CloseHandle(process);
  return ok;
}

/* Completes one overlapped transfer, bounded by `timeout` and the optional stop event. */
bool anvil_shell_transfer(HANDLE pipe, bool write, void *data, DWORD size, DWORD timeout, HANDLE stop) {
  HANDLE event = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (!event) return false;
  ULONGLONG deadline = GetTickCount64() + timeout;
  bool ok = true;
  for (DWORD done = 0; ok && done < size;) {
    OVERLAPPED overlapped = {.hEvent = event};
    DWORD moved = 0;
    BOOL immediate = write ? WriteFile(pipe, (char *)data + done, size - done, NULL, &overlapped)
                           : ReadFile(pipe, (char *)data + done, size - done, NULL, &overlapped);
    if (!immediate && GetLastError() != ERROR_IO_PENDING) { ok = false; break; }
    ULONGLONG now = GetTickCount64();
    HANDLE waits[2] = {event, stop};
    DWORD wait = WaitForMultipleObjects(stop ? 2 : 1, waits, FALSE, now < deadline ? (DWORD)(deadline - now) : 0);
    if (wait != WAIT_OBJECT_0) {
      CancelIoEx(pipe, &overlapped);
      GetOverlappedResult(pipe, &overlapped, &moved, TRUE);
      ok = false;
      break;
    }
    ok = GetOverlappedResult(pipe, &overlapped, &moved, FALSE) && moved;
    done += moved;
  }
  CloseHandle(event);
  return ok;
}

static char *wide_to_utf8(const wchar_t *text) {
  int bytes = WideCharToMultiByte(CP_UTF8, 0, text, -1, NULL, 0, NULL, NULL);
  char *out = bytes > 0 ? malloc(bytes) : NULL;
  if (out && !WideCharToMultiByte(CP_UTF8, 0, text, -1, out, bytes, NULL, NULL)) { free(out); out = NULL; }
  return out;
}

/* Path arguments become absolute, because the shell resolves them in its own working directory. */
static char *absolute_argument(const char *arg) {
  int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, arg, -1, NULL, 0);
  wchar_t *wide = count > 0 ? malloc(count * sizeof(*wide)) : NULL;
  static wchar_t full[32768];
  if (!wide || !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, arg, -1, wide, count)) { free(wide); return NULL; }
  DWORD n = GetFullPathNameW(wide, SDL_arraysize(full), full, NULL);
  free(wide);
  return n && n < SDL_arraysize(full) ? wide_to_utf8(full) : NULL;
}

static bool append(char **buffer, size_t *size, const void *data, size_t length) {
  if (*size + length > LAUNCH_MAX_BYTES) return false;
  char *grown = realloc(*buffer, *size + length);
  if (!grown) return false;
  memcpy(grown + *size, data, length);
  *buffer = grown;
  *size += length;
  return true;
}
static bool append_text(char **buffer, size_t *size, const char *text) {
  uint32_t length = (uint32_t)strlen(text);
  return length <= LAUNCH_MAX_TEXT && append(buffer, size, &length, sizeof(length)) && append(buffer, size, text, length);
}

static char *encode_request(int argc, char **argv, bool foreground, size_t *size) {
  char *buffer = NULL, *cwd = SDL_GetCurrentDirectory();
  uint32_t header[3] = {LAUNCH_MAGIC, LAUNCH_VERSION, foreground ? LAUNCH_FLAG_FOREGROUND : 0};
  uint32_t count = argc > 2 ? (uint32_t)(argc - 2) : 0;
  bool ok = cwd && count <= LAUNCH_MAX_ARGS && append(&buffer, size, header, sizeof(header)) &&
            append_text(&buffer, size, cwd) && append(&buffer, size, &count, sizeof(count));
  SDL_free(cwd);
  bool option_value = false;
  for (int i = 2; ok && i < argc; i++) {
    bool path = !option_value && argv[i][0] != '-';
    option_value = !option_value && argv[i][0] == '-' && anvil_cli_option_value(argv[i]);
    char *absolute = path ? absolute_argument(argv[i]) : NULL;
    ok = (!path || absolute) && append_text(&buffer, size, absolute ? absolute : argv[i]);
    free(absolute);
  }
  if (!ok) { free(buffer); return NULL; }
  return buffer;
}

static bool try_own(void) {
  if (!owner_mutex) owner_mutex = CreateMutexW(NULL, FALSE, mutex_name);
  if (!owner_mutex) return false;
  DWORD wait = WaitForSingleObject(owner_mutex, 0);
  if (wait == WAIT_ABANDONED) SDL_Log("Shell launch took ownership from an ended shell");
  return wait == WAIT_OBJECT_0 || wait == WAIT_ABANDONED;
}

/* Returns 0 when no shell answered, so the caller may retry. */
static AnvilShellLaunchStatus send_request(const char *request, size_t size, ULONGLONG deadline) {
  HANDLE pipe = CreateFileW(pipe_name, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING,
                            FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, NULL);
  if (pipe == INVALID_HANDLE_VALUE) {
    if (GetLastError() == ERROR_PIPE_BUSY) WaitNamedPipeW(pipe_name, 100);
    return 0;
  }
  ULONG server = 0;
  AnvilShellLaunchStatus status = 0;
  if (!GetNamedPipeServerProcessId(pipe, &server) || !anvil_shell_same_identity(server)) {
    SDL_Log("Shell launch refused a pipe server that is not this user's Anvil shell");
  } else {
    /* The shell raises the Project's Window. Windows lets it take the foreground only with this grant. */
    bool granted = AllowSetForegroundWindow(server) != 0;
    SDL_Log("Shell launch foreground grant to pid=%lu allowed=%d", (unsigned long)server, granted);
    ((uint32_t *)request)[2] = granted ? LAUNCH_FLAG_FOREGROUND : 0;
    ULONGLONG now = GetTickCount64();
    uint32_t reply[2] = {0, 0};
    if (now < deadline && anvil_shell_transfer(pipe, true, (void *)request, (DWORD)size, (DWORD)(deadline - now), NULL) &&
        (now = GetTickCount64()) < deadline &&
        anvil_shell_transfer(pipe, false, reply, sizeof(reply), (DWORD)(deadline - now), NULL) && reply[0] == LAUNCH_MAGIC &&
        reply[1] >= ANVIL_SHELL_LAUNCH_ACCEPTED && reply[1] <= ANVIL_SHELL_LAUNCH_BUSY)
      status = reply[1];
  }
  CloseHandle(pipe);
  return status;
}

AnvilShellLaunchResult anvil_shell_launch_own_or_forward(int argc, char **argv) {
  if (!init_names()) {
    SDL_Log("Shell launch key unavailable; run this shell alone");
    return ANVIL_SHELL_LAUNCH_OWN;
  }
  size_t size = 0;
  char *request = encode_request(argc, argv, false, &size);
  ULONGLONG deadline = GetTickCount64() + LAUNCH_FORWARD_MS;
  AnvilShellLaunchResult result = ANVIL_SHELL_LAUNCH_FAILED;
  for (;;) {
    if (try_own()) { result = ANVIL_SHELL_LAUNCH_OWN; break; }
    if (!request) { SDL_Log("Shell launch request is too large or invalid"); break; }
    AnvilShellLaunchStatus status = send_request(request, size, deadline);
    if (status == ANVIL_SHELL_LAUNCH_ACCEPTED) { result = ANVIL_SHELL_LAUNCH_FORWARDED; break; }
    if (status == ANVIL_SHELL_LAUNCH_REJECTED) { SDL_Log("Running shell rejected the launch"); break; }
    if (GetTickCount64() >= deadline) { SDL_Log("Running shell did not accept the launch in time"); break; }
    Sleep(50);
  }
  free(request);
  if (result != ANVIL_SHELL_LAUNCH_OWN && owner_mutex) {
    CloseHandle(owner_mutex);
    owner_mutex = NULL;
  }
  SDL_Log("Shell launch result=%s", result == ANVIL_SHELL_LAUNCH_OWN ? "own" :
          result == ANVIL_SHELL_LAUNCH_FORWARDED ? "forwarded" : "failed");
  return result;
}

static void release_request(AnvilShellLaunchRequest *request) {
  if (InterlockedDecrement(&request->references)) return;
  for (int i = 0; i < request->argc; i++) free(request->argv[i]);
  free(request->argv);
  free(request->cwd);
  if (request->done) CloseHandle(request->done);
  free(request);
}

static char *read_text(HANDLE pipe, size_t *total) {
  uint32_t length = 0;
  if (!anvil_shell_transfer(pipe, false, &length, sizeof(length), LAUNCH_READ_MS, stop_event) || length > LAUNCH_MAX_TEXT ||
      (*total += sizeof(length) + length) > LAUNCH_MAX_BYTES)
    return NULL;
  char *text = malloc(length + 1);
  if (!text || (length && !anvil_shell_transfer(pipe, false, text, length, LAUNCH_READ_MS, stop_event))) { free(text); return NULL; }
  text[length] = 0;
  return text;
}

static AnvilShellLaunchRequest *read_request(HANDLE pipe, DWORD client) {
  uint32_t header[3];
  size_t total = sizeof(header);
  if (!anvil_shell_transfer(pipe, false, header, sizeof(header), LAUNCH_READ_MS, stop_event) || header[0] != LAUNCH_MAGIC ||
      header[1] != LAUNCH_VERSION)
    return NULL;
  AnvilShellLaunchRequest *request = calloc(1, sizeof(*request));
  uint32_t count = 0;
  bool ok = request && (request->cwd = read_text(pipe, &total)) &&
            anvil_shell_transfer(pipe, false, &count, sizeof(count), LAUNCH_READ_MS, stop_event) && count <= LAUNCH_MAX_ARGS &&
            (request->argv = calloc(count + 2, sizeof(*request->argv))) &&
            (request->argv[0] = _strdup("anvil")) && (request->argv[1] = _strdup(ANVIL_SHELL_ARG));
  if (request) request->argc = request->argv ? 2 : 0;
  for (uint32_t i = 0; ok && i < count; i++) {
    ok = (request->argv[request->argc] = read_text(pipe, &total)) != NULL;
    if (ok) request->argc++;
  }
  if (request) {
    request->references = 1;
    request->client_pid = client;
    request->foreground = (header[2] & LAUNCH_FLAG_FOREGROUND) != 0;
  }
  if (!ok || !(request->done = CreateEventW(NULL, TRUE, FALSE, NULL))) {
    if (request) release_request(request);
    return NULL;
  }
  return request;
}

static DWORD WINAPI client_proc(void *data) {
  HANDLE pipe = data;
  ULONG client = 0;
  GetNamedPipeClientProcessId(pipe, &client);
  AnvilShellLaunchRequest *request = read_request(pipe, client);
  LONG status = ANVIL_SHELL_LAUNCH_BUSY;
  if (!request) {
    SDL_Log("Shell launch discarded an invalid request from pid=%lu", (unsigned long)client);
  } else {
    request->references = 2;
    if (!notify_request(request)) {
      release_request(request);
    } else {
      HANDLE waits[2] = {request->done, stop_event};
      if (WaitForMultipleObjects(2, waits, FALSE, LAUNCH_REPLY_MS) == WAIT_OBJECT_0)
        status = request->status;
      else
        SDL_Log("Shell launch reply deadline expired: pid=%lu", (unsigned long)client);
    }
    uint32_t reply[2] = {LAUNCH_MAGIC, (uint32_t)status};
    anvil_shell_transfer(pipe, true, reply, sizeof(reply), LAUNCH_READ_MS, NULL);
    FlushFileBuffers(pipe);
    release_request(request);
  }
  DisconnectNamedPipe(pipe);
  CloseHandle(pipe);
  InterlockedDecrement(&client_count);
  return 0;
}

static DWORD WINAPI server_proc(void *data) {
  (void)data;
  SECURITY_ATTRIBUTES security = {sizeof(security), pipe_security, FALSE};
  HANDLE event = CreateEventW(NULL, TRUE, FALSE, NULL);
  for (bool first = true; event;) {
    HANDLE pipe = CreateNamedPipeW(pipe_name,
                                   PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | (first ? FILE_FLAG_FIRST_PIPE_INSTANCE : 0),
                                   PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                                   PIPE_UNLIMITED_INSTANCES, 4096, 4096, 0, &security);
    if (pipe == INVALID_HANDLE_VALUE) {
      /* Another process holds this name. The shell keeps running without external launches. */
      SDL_Log("Shell launch server cannot create its pipe: error=%lu", (unsigned long)GetLastError());
      break;
    }
    first = false;
    OVERLAPPED overlapped = {.hEvent = event};
    ResetEvent(event);
    bool connected = ConnectNamedPipe(pipe, &overlapped) || GetLastError() == ERROR_PIPE_CONNECTED;
    if (!connected && GetLastError() == ERROR_IO_PENDING) {
      HANDLE waits[2] = {event, stop_event};
      DWORD moved;
      if (WaitForMultipleObjects(2, waits, FALSE, INFINITE) == WAIT_OBJECT_0)
        connected = GetOverlappedResult(pipe, &overlapped, &moved, FALSE);
      else {
        CancelIoEx(pipe, &overlapped);
        GetOverlappedResult(pipe, &overlapped, &moved, TRUE);
      }
    }
    if (WaitForSingleObject(stop_event, 0) == WAIT_OBJECT_0) { CloseHandle(pipe); break; }
    ULONG client = 0;
    HANDLE thread = NULL;
    if (connected && GetNamedPipeClientProcessId(pipe, &client) && anvil_shell_same_identity(client) &&
        InterlockedIncrement(&client_count) <= LAUNCH_MAX_CLIENTS) {
      thread = CreateThread(NULL, 0, client_proc, pipe, 0, NULL);
      if (!thread) InterlockedDecrement(&client_count);
    } else if (connected && client && anvil_shell_same_identity(client)) {
      InterlockedDecrement(&client_count);
      SDL_Log("Shell launch refused pid=%lu: too many pending launches", (unsigned long)client);
    } else if (connected) {
      SDL_Log("Shell launch refused pid=%lu: it ended, or it is not this user's Anvil", (unsigned long)client);
    }
    if (thread) CloseHandle(thread);
    else { DisconnectNamedPipe(pipe); CloseHandle(pipe); }
  }
  if (event) CloseHandle(event);
  return 0;
}

PSECURITY_DESCRIPTOR anvil_shell_user_security(void) {
  static PSECURITY_DESCRIPTOR security;
  if (security) return security;
  PSID self = current_user();
  wchar_t *sid = NULL, sddl[256];
  /* Only this user may connect. Remote clients are rejected separately. */
  if (!self || !ConvertSidToStringSidW(self, &sid)) return NULL;
  _snwprintf(sddl, SDL_arraysize(sddl), L"D:P(A;;GA;;;%ls)", sid);
  LocalFree(sid);
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, SDDL_REVISION_1, &security, NULL)) return NULL;
  return security;
}

bool anvil_shell_launch_start(bool (*notify)(AnvilShellLaunchRequest *request)) {
  if (!owner_mutex || server_thread) return false;
  if (!(pipe_security = anvil_shell_user_security())) return false;
  notify_request = notify;
  stop_event = CreateEventW(NULL, TRUE, FALSE, NULL);
  server_thread = stop_event ? CreateThread(NULL, 0, server_proc, NULL, 0, NULL) : NULL;
  if (!server_thread) return false;
  SDL_Log("Shell launch server started");
  return true;
}

void anvil_shell_launch_stop(void) {
  if (stop_event) SetEvent(stop_event);
  if (server_thread && WaitForSingleObject(server_thread, 1000) == WAIT_OBJECT_0) {
    CloseHandle(server_thread);
    server_thread = NULL;
  }
  /* Client threads answer Busy once they see the stop event. Launchers then retry and can own a new shell. */
  for (ULONGLONG end = GetTickCount64() + 1000; client_count > 0 && GetTickCount64() < end;) Sleep(10);
  if (owner_mutex) {
    ReleaseMutex(owner_mutex);
    CloseHandle(owner_mutex);
    owner_mutex = NULL;
    SDL_Log("Shell launch ownership released");
  }
  /* A blocked client thread may still use these, so they stay for the process lifetime. */
}

const wchar_t *anvil_shell_launch_user_directory(void) { return mutex_name[0] ? user_dir : NULL; }
int anvil_shell_launch_argc(const AnvilShellLaunchRequest *request) { return request->argc; }
char **anvil_shell_launch_argv(const AnvilShellLaunchRequest *request) { return request->argv; }
const char *anvil_shell_launch_cwd(const AnvilShellLaunchRequest *request) { return request->cwd; }
DWORD anvil_shell_launch_client_pid(const AnvilShellLaunchRequest *request) { return request->client_pid; }
bool anvil_shell_launch_foreground_granted(const AnvilShellLaunchRequest *request) { return request->foreground; }

void anvil_shell_launch_finish(AnvilShellLaunchRequest *request, AnvilShellLaunchStatus status) {
  InterlockedExchange(&request->status, status);
  SetEvent(request->done);
  release_request(request);
}
#endif
