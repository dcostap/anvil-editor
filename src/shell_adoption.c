#include "shell_adoption.h"
#include <SDL3/SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RECORD_HEADER "anvil-adoption 1\n"
#define RECORD_MAX_BYTES (ANVIL_ADOPTION_MAX_PATH + 128)
#define ADOPTION_MAGIC 0x504F4441u /* ADOP */
#define ADOPTION_VERSION 1u
#define ADOPTION_READ_MS 2000

/* One line: `<pid> <created> <window id> <path bytes> <path>`. */
char *anvil_adoption_encode(const AnvilAdoptionRecord *record, size_t *size) {
  size_t length = record->path ? strlen(record->path) : 0;
  if (!record->pid || !length || length > ANVIL_ADOPTION_MAX_PATH) return NULL;
  size_t capacity = sizeof(RECORD_HEADER) + length + 96;
  char *data = malloc(capacity);
  if (!data) return NULL;
  int n = snprintf(data, capacity, "%s%lu %llu %lu %zu %s\n", RECORD_HEADER, (unsigned long)record->pid,
                   (unsigned long long)record->created, (unsigned long)record->window_id, length, record->path);
  if (n < 0 || (size_t)n >= capacity) {
    free(data);
    return NULL;
  }
  *size = (size_t)n;
  return data;
}

static bool read_number(const char **cursor, const char *end, uint64_t limit, uint64_t *value) {
  const char *p = *cursor;
  if (p >= end || *p < '0' || *p > '9') return false;
  uint64_t result = 0;
  while (p < end && *p >= '0' && *p <= '9') {
    unsigned digit = (unsigned)(*p++ - '0');
    if (result > (limit - digit) / 10) return false;
    result = result * 10 + digit;
  }
  if (p >= end || *p != ' ') return false;
  *value = result;
  *cursor = p + 1;
  return true;
}

void anvil_adoption_free(AnvilAdoptionRecord *record) {
  free(record->path);
  memset(record, 0, sizeof(*record));
}

bool anvil_adoption_decode(const char *data, size_t size, AnvilAdoptionRecord *record) {
  memset(record, 0, sizeof(*record));
  size_t header = strlen(RECORD_HEADER);
  if (size > RECORD_MAX_BYTES || size < header || memcmp(data, RECORD_HEADER, header)) return false;
  const char *cursor = data + header, *end = data + size;
  uint64_t pid, created, window, length;
  if (!read_number(&cursor, end, UINT32_MAX, &pid) || !read_number(&cursor, end, UINT64_MAX, &created) ||
      !read_number(&cursor, end, UINT32_MAX, &window) ||
      !read_number(&cursor, end, ANVIL_ADOPTION_MAX_PATH, &length) || !pid || !length ||
      (uint64_t)(end - cursor) != length + 1 || cursor[length] != '\n' || memchr(cursor, 0, (size_t)length))
    return false;
  record->path = malloc((size_t)length + 1);
  if (!record->path) return false;
  memcpy(record->path, cursor, (size_t)length);
  record->path[length] = 0;
  record->pid = (uint32_t)pid;
  record->created = created;
  record->window_id = (uint32_t)window;
  return true;
}

#ifdef _WIN32
#include "shell_launch.h"
#include "shell_state.h"

typedef struct {
  uint32_t magic, version, shell_pid, reserved;
  char pipe[256];
} AdoptionRequest;

typedef struct {
  uint32_t magic, accepted;
} AdoptionReply;

struct AnvilAdoptionOffer {
  HANDLE pipe, event;
  wchar_t record[32768 + 128];
};

static bool adoption_directory(wchar_t *out, size_t capacity) {
  wchar_t userdir[32768];
  if (!anvil_shell_user_directory(userdir, SDL_arraysize(userdir))) return false;
  int n = _snwprintf(out, capacity, L"%ls\\adoption", userdir);
  return n > 0 && (size_t)n < capacity;
}

static void pipe_name(wchar_t *out, size_t capacity, uint32_t pid, uint64_t created) {
  _snwprintf(out, capacity, L"\\\\.\\pipe\\AnvilAdopt-%lu-%016llx", (unsigned long)pid,
             (unsigned long long)created);
  out[capacity - 1] = 0;
}

static uint64_t creation_time(HANDLE process) {
  FILETIME created, exited, kernel, user;
  if (!GetProcessTimes(process, &created, &exited, &kernel, &user)) return 0;
  return ((uint64_t)created.dwHighDateTime << 32) | created.dwLowDateTime;
}

AnvilAdoptionOffer *anvil_adoption_offer_open(const char *project_path, uint32_t window_id) {
  AnvilAdoptionOffer *offer = calloc(1, sizeof(*offer));
  wchar_t directory[32768 + 16], name[128];
  PSECURITY_DESCRIPTOR descriptor = anvil_shell_user_security();
  if (!offer || !descriptor || !adoption_directory(directory, SDL_arraysize(directory))) {
    free(offer);
    return NULL;
  }
  AnvilAdoptionRecord record = {.pid = GetCurrentProcessId(), .created = creation_time(GetCurrentProcess()),
                                .window_id = window_id, .path = (char *)project_path};
  pipe_name(name, SDL_arraysize(name), record.pid, record.created);
  SECURITY_ATTRIBUTES security = {sizeof(security), descriptor, FALSE};
  offer->pipe = CreateNamedPipeW(name, PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
                                 PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1,
                                 4096, 4096, 0, &security);
  offer->event = CreateEventW(NULL, TRUE, FALSE, NULL);
  size_t size = 0;
  char *data = anvil_adoption_encode(&record, &size);
  CreateDirectoryW(directory, NULL);
  bool ok = offer->pipe != INVALID_HANDLE_VALUE && offer->event && data && record.created &&
            _snwprintf(offer->record, SDL_arraysize(offer->record), L"%ls\\%lu-%016llx.record", directory,
                       (unsigned long)record.pid, (unsigned long long)record.created) > 0 &&
            anvil_shell_file_replace(offer->record, data, size);
  free(data);
  if (!ok) {
    SDL_Log("Project adoption offer unavailable: Windows error=%lu", (unsigned long)GetLastError());
    offer->record[0] = 0;
    anvil_adoption_offer_close(offer);
    return NULL;
  }
  SDL_Log("Project adoption offer published: Window=%lu", (unsigned long)window_id);
  return offer;
}

void anvil_adoption_offer_close(AnvilAdoptionOffer *offer) {
  if (!offer) return;
  if (offer->record[0]) DeleteFileW(offer->record);
  if (offer->pipe && offer->pipe != INVALID_HANDLE_VALUE) CloseHandle(offer->pipe);
  if (offer->event) CloseHandle(offer->event);
  free(offer);
}

static DWORD remaining(uint64_t deadline) {
  uint64_t now = GetTickCount64();
  return now < deadline ? (DWORD)SDL_min(deadline - now, 0x7fffffffu) : 0;
}

bool anvil_adoption_offer_accept(AnvilAdoptionOffer *offer, uint64_t deadline, char *shell_pipe, size_t capacity,
                                 DWORD *shell_pid) {
  for (;;) {
    OVERLAPPED overlapped = {.hEvent = offer->event};
    ResetEvent(offer->event);
    bool connected = ConnectNamedPipe(offer->pipe, &overlapped) || GetLastError() == ERROR_PIPE_CONNECTED;
    if (!connected && GetLastError() == ERROR_IO_PENDING) {
      DWORD moved;
      if (WaitForSingleObject(offer->event, remaining(deadline)) == WAIT_OBJECT_0)
        connected = GetOverlappedResult(offer->pipe, &overlapped, &moved, FALSE);
      else {
        CancelIoEx(offer->pipe, &overlapped);
        GetOverlappedResult(offer->pipe, &overlapped, &moved, TRUE);
        return false;
      }
    }
    ULONG client = 0;
    AdoptionRequest request = {0};
    bool valid = connected && GetNamedPipeClientProcessId(offer->pipe, &client) && anvil_shell_same_identity(client) &&
                 anvil_shell_transfer(offer->pipe, false, &request, sizeof(request), ADOPTION_READ_MS, NULL) &&
                 request.magic == ADOPTION_MAGIC && request.version == ADOPTION_VERSION &&
                 request.shell_pid == client && memchr(request.pipe, 0, sizeof(request.pipe)) &&
                 strlen(request.pipe) < capacity;
    AdoptionReply reply = {ADOPTION_MAGIC, valid};
    if (valid && anvil_shell_transfer(offer->pipe, true, &reply, sizeof(reply), ADOPTION_READ_MS, NULL)) {
      /* Wait for the shell to read the reply and close its end. */
      char drain;
      anvil_shell_transfer(offer->pipe, false, &drain, 1, ADOPTION_READ_MS, NULL);
      DisconnectNamedPipe(offer->pipe);
      memcpy(shell_pipe, request.pipe, strlen(request.pipe) + 1);
      *shell_pid = client;
      SDL_Log("Project accepted adoption by shell pid=%lu", (unsigned long)client);
      return true;
    }
    if (connected) SDL_Log("Project refused an adoption request from pid=%lu", (unsigned long)client);
    DisconnectNamedPipe(offer->pipe);
    if (!remaining(deadline)) return false;
  }
}

static bool valid_record(const AnvilAdoptionRecord *record) {
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, record->pid);
  if (!process) return false;
  bool ok = WaitForSingleObject(process, 0) == WAIT_TIMEOUT && creation_time(process) == record->created &&
            anvil_shell_same_identity(record->pid);
  CloseHandle(process);
  return ok;
}

size_t anvil_adoption_scan(AnvilAdoptionRecord *records, size_t capacity) {
  wchar_t directory[32768 + 16], pattern[32768 + 32], file[32768 + 300];
  if (!adoption_directory(directory, SDL_arraysize(directory))) return 0;
  _snwprintf(pattern, SDL_arraysize(pattern), L"%ls\\*.record", directory);
  pattern[SDL_arraysize(pattern) - 1] = 0;
  WIN32_FIND_DATAW found;
  HANDLE search = FindFirstFileW(pattern, &found);
  if (search == INVALID_HANDLE_VALUE) return 0;
  size_t count = 0, examined = 0;
  do {
    if (found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
    if (++examined > ANVIL_ADOPTION_MAX_RECORDS * 4) break;
    _snwprintf(file, SDL_arraysize(file), L"%ls\\%ls", directory, found.cFileName);
    file[SDL_arraysize(file) - 1] = 0;
    size_t size = 0;
    char *data = anvil_shell_file_read(file, RECORD_MAX_BYTES, &size);
    AnvilAdoptionRecord record;
    bool decoded = data && anvil_adoption_decode(data, size, &record);
    free(data);
    if (decoded && count < capacity && valid_record(&record)) {
      SDL_Log("Shell found an adoptable Project: pid=%lu Window=%lu path=%s", (unsigned long)record.pid,
              (unsigned long)record.window_id, record.path);
      records[count++] = record;
      continue;
    }
    SDL_Log("Shell removed a stale adoption record: decoded=%d pid=%lu", decoded,
            decoded ? (unsigned long)record.pid : 0ul);
    if (decoded) anvil_adoption_free(&record);
    DeleteFileW(file);
  } while (FindNextFileW(search, &found));
  FindClose(search);
  return count;
}

bool anvil_adoption_request(const AnvilAdoptionRecord *record, const char *shell_pipe, DWORD timeout_ms) {
  wchar_t name[128];
  pipe_name(name, SDL_arraysize(name), record->pid, record->created);
  uint64_t deadline = GetTickCount64() + timeout_ms;
  HANDLE pipe;
  for (;;) {
    pipe = CreateFileW(name, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING,
                       FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, NULL);
    if (pipe != INVALID_HANDLE_VALUE) break;
    if (GetLastError() != ERROR_PIPE_BUSY || !remaining(deadline)) {
      SDL_Log("Shell could not reach adoptable Project pid=%lu: Windows error=%lu", (unsigned long)record->pid,
              (unsigned long)GetLastError());
      return false;
    }
    WaitNamedPipeW(name, SDL_min(remaining(deadline), 100));
  }
  ULONG server = 0;
  AdoptionRequest request = {ADOPTION_MAGIC, ADOPTION_VERSION, GetCurrentProcessId(), 0, {0}};
  SDL_strlcpy(request.pipe, shell_pipe, sizeof(request.pipe));
  AdoptionReply reply = {0};
  bool ok = GetNamedPipeServerProcessId(pipe, &server) && server == record->pid &&
            anvil_shell_transfer(pipe, true, &request, sizeof(request), remaining(deadline), NULL) &&
            anvil_shell_transfer(pipe, false, &reply, sizeof(reply), remaining(deadline), NULL) &&
            reply.magic == ADOPTION_MAGIC && reply.accepted == 1;
  CloseHandle(pipe);
  if (!ok) SDL_Log("Shell adoption request failed: pid=%lu server=%lu", (unsigned long)record->pid,
                   (unsigned long)server);
  return ok;
}
#endif
