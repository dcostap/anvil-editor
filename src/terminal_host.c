#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include "terminal_host.h"
#include "conpty.h"
#include "terminal_model.h"
#include "terminal_snapshot.h"
#include <tlhelp32.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <time.h>

#define CLIENT_QUEUE_LIMIT (8u * 1024u * 1024u)
#define CLIENT_STALL_TIMEOUT_MS 10000u
#define ORPHAN_GRACE_MS (10u * 60u * 1000u)
/* The longest agent status text the registry keeps, in bytes. Program status messages can be 2048 bytes. */
#define ANVIL_TERMINAL_AGENT_TEXT_MAX 256
#define AGENT_MESSAGE_MAX 2048

typedef struct HostRecord {
  struct HostRecord *next;
  uint32_t length;
  uint16_t type;
  uint8_t bytes[];
} HostRecord;

/* One program status record (OSC 7501). An empty state means no record. */
typedef struct {
  char state[8], kind[16], message[ANVIL_TERMINAL_AGENT_TEXT_MAX + 1];
  int64_t since;
} AgentRecord;

typedef struct {
  AnvilConPTY pty;
  AnvilIPCPipe pipe;
  GhosttyTerminal model;
  AnvilTerminalSize size;
  CRITICAL_SECTION lock;
  CONDITION_VARIABLE ready, space;
  HostRecord *head, *tail;
  size_t queued;
  volatile LONG attached;
  bool replaying;
  bool busy, status_pending;
  uint64_t writer_progress;
  volatile LONG backpressured, client_stop;
  volatile LONG stop, reader_stop, reader_done;
  volatile LONG64 last_output, exit_sent_ms, last_input;
  HANDLE reader, writer, client, console_close;
  const char *id, *pipe_name, *project, *shell, *cwd;
  char log_path[32768], record_path[32768], snapshot_path[32768];
  char last_cwd[32768], interrupted_command[16384], agent_report_path[32768];
  /* The busy child that interrupted_command came from. An agent report names it. */
  DWORD interrupted_pid;
  /* The last older process that named the shell's reused ID as its parent. It is logged once. */
  DWORD ignored_child_pid;
  bool explicit_close, shell_ended;
  /* The live title the Project Sidebar shows, and the last activity in Unix seconds. */
  char title[1024];
  int64_t activity;
  uint64_t snapshot_at, snapshot_revision;
  volatile LONG64 model_revision;
  /* Shell integration: the nonce that authenticates the shell's OSC 133 marks,
     whether a command runs between its C and D marks, and the reader's OSC scanner. */
  char nonce[33];
  volatile LONG command_running;
  int mark_state;
  size_t mark_length;
  bool mark_overflow;
  char mark[4096];
  /* An agent's program status: the root record and the "step" child record that Anvil's Pi extension sends.
     The reader thread changes them under lock; the monitor writes them to the registry. */
  AgentRecord agent, step;
  volatile LONG agent_revision;
} TerminalHost;

static wchar_t *wide_string(const char *text) {
  int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
  wchar_t *wide = count > 0 ? malloc(count * sizeof(wchar_t)) : NULL;
  if (wide) MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, wide, count);
  return wide;
}

static void host_log(TerminalHost *host, const char *format, ...) {
  char text[1024];
  va_list args; va_start(args, format); vsnprintf(text, sizeof(text), format, args); va_end(args);
  wchar_t *path = wide_string(host->log_path);
  FILE *file = path ? _wfopen(path, L"ab") : NULL;
  free(path);
  if (!file) return;
  SYSTEMTIME time; GetLocalTime(&time);
  fprintf(file, "%04u-%02u-%02u %02u:%02u:%02u.%03u pid=%lu %s\n",
    time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute, time.wSecond,
    time.wMilliseconds, (unsigned long)GetCurrentProcessId(), text);
  fclose(file);
}

static bool creation_time(HANDLE process, char out[17]) {
  FILETIME created, exited, kernel, user;
  if (!GetProcessTimes(process, &created, &exited, &kernel, &user)) return false;
  uint64_t value = ((uint64_t)created.dwHighDateTime << 32) | created.dwLowDateTime;
  snprintf(out, 17, "%016llx", (unsigned long long)value);
  return true;
}

static bool random_bytes(uint8_t *bytes, ULONG count) {
  typedef BOOLEAN (WINAPI *RandomFunction)(void *, ULONG);
  HMODULE library = LoadLibraryW(L"advapi32.dll");
  RandomFunction random_function = library ? (RandomFunction)GetProcAddress(library, "SystemFunction036") : NULL;
  bool ok = random_function && random_function(bytes, count);
  if (library) FreeLibrary(library);
  return ok;
}

bool anvil_terminal_id_valid(const char *id) {
  if (!id || strlen(id) != ANVIL_TERMINAL_ID_LENGTH) return false;
  for (size_t i = 0; i < ANVIL_TERMINAL_ID_LENGTH; i++)
    if (!((id[i] >= '0' && id[i] <= '9') || (id[i] >= 'a' && id[i] <= 'f'))) return false;
  return true;
}

bool anvil_terminal_host_identity(HANDLE process, DWORD pid, const char *time) {
  char actual[17];
  return process && time && GetProcessId(process) == pid &&
    WaitForSingleObject(process, 0) == WAIT_TIMEOUT && creation_time(process, actual) &&
    strcmp(actual, time) == 0;
}

/* Registry strings use Lua decimal escapes, including quotes and backslashes. */
static void registry_string(FILE *file, const char *key, const char *text) {
  fprintf(file, "  %s = \"", key);
  for (const unsigned char *p = (const unsigned char *)text; *p; p++) {
    if (*p < 32 || *p == 127 || *p == '"' || *p == '\\') fprintf(file, "\\%03u", *p);
    else fputc(*p, file);
  }
  fputs("\",\n", file);
}

static HANDLE registry_lock(const char *id) {
  char name[96]; snprintf(name, sizeof(name), "Local\\AnvilTerminalRecord-%s", id);
  HANDLE mutex = CreateMutexA(NULL, FALSE, name);
  DWORD waited = mutex ? WaitForSingleObject(mutex, 5000) : WAIT_FAILED;
  if (waited == WAIT_OBJECT_0 || waited == WAIT_ABANDONED) return mutex;
  if (mutex) CloseHandle(mutex);
  return NULL;
}

static bool registry_host_live(TerminalHost *host) {
  wchar_t *path = wide_string(host->record_path);
  FILE *file = path ? _wfopen(path, L"rb") : NULL; free(path);
  if (!file) return false;
  char text[65536]; size_t count = fread(text, 1, sizeof(text) - 1, file); fclose(file); text[count] = 0;
  char *pid_field = strstr(text, "host_pid = "), *time_field = strstr(text, "host_creation_time = \"");
  unsigned long pid = 0; unsigned long long expected = 0;
  if (!pid_field || !time_field || sscanf(pid_field, "host_pid = %lu", &pid) != 1 ||
      sscanf(time_field, "host_creation_time = \"%llx", &expected) != 1) return true;
  HANDLE process = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process) return GetLastError() != ERROR_INVALID_PARAMETER;
  char created[17], wanted[17]; snprintf(wanted, sizeof(wanted), "%016llx", expected);
  bool live = WaitForSingleObject(process, 0) != WAIT_OBJECT_0 &&
    (!creation_time(process, created) || !strcmp(created, wanted));
  CloseHandle(process);
  return live;
}

static bool write_registry(TerminalHost *host) {
  char temporary[32772], created[17];
  if (!creation_time(GetCurrentProcess(), created)) return false;
  HANDLE mutex = registry_lock(host->id);
  if (!mutex) return false;
  snprintf(temporary, sizeof(temporary), "%s.tmp", host->record_path);
  wchar_t *path = wide_string(host->record_path), *temp = wide_string(temporary);
  FILE *file = temp ? _wfopen(temp, L"wb") : NULL;
  bool ok = path && file;
  if (ok) {
    /* A detach is complete only after disconnect_client saved the screen. The
       client thread clears attached first, and a title or busy write before the
       disconnect would otherwise report a detach whose snapshot is still old. */
    bool attached = host->attached || host->client || host->writer;
    fprintf(file, "return {\n  version = 1,\n  host_pid = %lu,\n  attached = %s,\n",
      (unsigned long)GetCurrentProcessId(), attached ? "true" : "false");
    fprintf(file, "  busy = %s,\n", host->busy ? "true" : "false");
    registry_string(file, "session_id", host->id);
    registry_string(file, "host_creation_time", created);
    registry_string(file, "pipe_name", host->pipe_name);
    registry_string(file, "project_path", host->project);
    registry_string(file, "shell", host->shell);
    registry_string(file, "cwd", host->last_cwd);
    registry_string(file, "title", host->title);
    fprintf(file, "  activity = %lld,\n", (long long)host->activity);
    registry_string(file, "status", host->shell_ended ? "exited" : "running");
    registry_string(file, "snapshot_path", host->snapshot_path);
    registry_string(file, "interrupted_command", host->interrupted_command);
    fprintf(file, "  interrupted_pid = %lu,\n", (unsigned long)host->interrupted_pid);
    EnterCriticalSection(&host->lock);
    AgentRecord agent = host->agent, step = host->step;
    LeaveCriticalSection(&host->lock);
    if (agent.state[0]) {
      registry_string(file, "agent_state", agent.state);
      registry_string(file, "agent_kind", agent.kind);
      registry_string(file, "agent_message", agent.message);
      fprintf(file, "  agent_since = %lld,\n", (long long)agent.since);
    }
    if (step.state[0]) {
      registry_string(file, "agent_step", step.message);
      fprintf(file, "  agent_step_since = %lld,\n", (long long)step.since);
    }
    fputs("}\n", file);
    ok = !ferror(file);
  }
  if (file && fclose(file) != 0) ok = false;
  if (ok) {
    /* Antivirus scanners open the record right after each write. A replace during
       that scan is denied, and the caller does not repeat a lost change. */
    static const DWORD retry_delays_ms[] = { 5, 10, 20, 40, 75, 100 };
    ok = MoveFileExW(temp, path, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != FALSE;
    for (size_t i = 0; !ok && i < sizeof(retry_delays_ms) / sizeof(retry_delays_ms[0]); i++) {
      DWORD error = GetLastError();
      if (error != ERROR_ACCESS_DENIED && error != ERROR_SHARING_VIOLATION && error != ERROR_LOCK_VIOLATION) break;
      Sleep(retry_delays_ms[i]);
      ok = MoveFileExW(temp, path, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != FALSE;
    }
  }
  if (!ok && temp) DeleteFileW(temp);
  free(path); free(temp);
  if (!ok) host_log(host, "failure: registry write Windows error=%lu", (unsigned long)GetLastError());
  ReleaseMutex(mutex); CloseHandle(mutex);
  return ok;
}

static void delete_registry(TerminalHost *host) {
  HANDLE mutex = registry_lock(host->id);
  if (!mutex) return;
  wchar_t *path = wide_string(host->record_path);
  if (path) DeleteFileW(path);
  free(path);
  path = wide_string(host->snapshot_path);
  if (path) DeleteFileW(path);
  free(path);
  path = wide_string(host->agent_report_path);
  if (path) DeleteFileW(path);
  free(path);
  ReleaseMutex(mutex); CloseHandle(mutex);
}

/* Transport failure is a detach, never a shell failure. Caller may hold lock. */
static void stop_client(TerminalHost *host) {
  EnterCriticalSection(&host->lock);
  host->attached = false;
  InterlockedExchange(&host->client_stop, 1);
  WakeAllConditionVariable(&host->ready);
  WakeAllConditionVariable(&host->space);
  LeaveCriticalSection(&host->lock);
  anvil_ipc_pipe_cancel(&host->pipe);
}

static void stop_host(TerminalHost *host) {
  InterlockedExchange(&host->stop, 1);
  stop_client(host);
}

/* Caller holds lock. Accounting includes the record being written. */
static bool queue_record(TerminalHost *host, uint16_t type, const void *bytes, uint32_t length) {
  uint64_t progress = host->writer_progress, stalled_since = GetTickCount64();
  bool waited = false;
  while (sizeof(HostRecord) + length > CLIENT_QUEUE_LIMIT - host->queued) {
    if (!waited) {
      host_log(host, "client queue full; wait for writer progress");
      waited = true; InterlockedExchange(&host->backpressured, 1);
    }
    if (host->writer_progress != progress) {
      progress = host->writer_progress; stalled_since = GetTickCount64();
    }
    if (!host->attached || host->stop || (type == ANVIL_TERMINAL_OUTPUT && host->reader_stop)) break;
    uint64_t elapsed = GetTickCount64() - stalled_since;
    if (elapsed >= CLIENT_STALL_TIMEOUT_MS) {
      host_log(host, "client writer made no progress; detach, keep shell");
      stop_client(host); break;
    }
    SleepConditionVariableCS(&host->space, &host->lock, (DWORD)(CLIENT_STALL_TIMEOUT_MS - elapsed));
  }
  InterlockedExchange(&host->backpressured, 0);
  if (!host->attached || host->stop || (type == ANVIL_TERMINAL_OUTPUT && host->reader_stop)) return false;
  if (waited) host_log(host, "client writer resumed; continue output");
  HostRecord *record = malloc(sizeof(*record) + length);
  if (!record) { stop_client(host); return false; }
  record->next = NULL; record->type = type; record->length = length;
  if (length) memcpy(record->bytes, bytes, length);
  if (host->tail) host->tail->next = record; else host->head = record;
  host->tail = record; host->queued += sizeof(*record) + length;
  WakeConditionVariable(&host->ready);
  return true;
}

/* Standard base64 with optional padding. Returns the decoded length, or -1. */
static int base64_decode(const char *text, size_t length, char *out, size_t capacity) {
  uint32_t bits = 0; int count = 0; size_t used = 0;
  for (size_t i = 0; i < length; i++) {
    char ch = text[i]; int value;
    if (ch >= 'A' && ch <= 'Z') value = ch - 'A';
    else if (ch >= 'a' && ch <= 'z') value = ch - 'a' + 26;
    else if (ch >= '0' && ch <= '9') value = ch - '0' + 52;
    else if (ch == '+') value = 62;
    else if (ch == '/') value = 63;
    else if (ch == '=') break;
    else return -1;
    bits = (bits << 6) | (uint32_t)value; count += 6;
    if (count >= 8) {
      count -= 8;
      if (used >= capacity) return -1;
      out[used++] = (char)((bits >> count) & 0xff);
    }
  }
  return (int)used;
}

/* Agent records end when the program that sent them ends. Caller holds lock. */
static void clear_agent(TerminalHost *host) {
  if (!host->agent.state[0] && !host->step.state[0]) return;
  host->agent = (AgentRecord){0}; host->step = (AgentRecord){0};
  InterlockedIncrement(&host->agent_revision);
}

/* Applies one Program Status Protocol report (OSC 7501): key=value pairs joined by ':'. A malformed report
   changes nothing. Pi reports the root record; Anvil's Pi extension reports the "step" record. */
static void apply_status(TerminalHost *host, const char *pairs) {
  char state[8] = "", kind[16] = "", id[33] = "", message[ANVIL_TERMINAL_AGENT_TEXT_MAX + 1] = "";
  for (const char *pair = pairs; *pair;) {
    size_t length = strcspn(pair, ":");
    const char *equals = memchr(pair, '=', length);
    if (equals) {
      size_t key = (size_t)(equals - pair), size = length - key - 1;
      const char *value = equals + 1;
      if (size > (AGENT_MESSAGE_MAX + 2) / 3 * 4) return;
      for (size_t i = 0; i < size; i++)
        if (!strchr("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.,+/=-", value[i])) return;
      if (key == 5 && !memcmp(pair, "state", 5) && size < sizeof(state)) {
        memcpy(state, value, size); state[size] = 0;
      } else if (key == 4 && !memcmp(pair, "kind", 4) && size < sizeof(kind)) {
        memcpy(kind, value, size); kind[size] = 0;
      } else if (key == 2 && !memcmp(pair, "id", 2)) {
        if (size >= sizeof(id)) return;
        memcpy(id, value, size); id[size] = 0;
      } else if (key == 3 && !memcmp(pair, "msg", 3)) {
        char decoded[AGENT_MESSAGE_MAX + 3];
        int count = base64_decode(value, size, decoded, sizeof(decoded));
        if (count < 0) return;
        /* One line of text: no C0 or C1 controls. */
        for (int i = 0; i < count; i++) {
          unsigned char ch = (unsigned char)decoded[i];
          if (ch < 32 || ch == 127 || (ch == 0xc2 && i + 1 < count && (unsigned char)decoded[i + 1] < 0xa0)) return;
        }
        size_t keep = (size_t)count < ANVIL_TERMINAL_AGENT_TEXT_MAX ? (size_t)count : ANVIL_TERMINAL_AGENT_TEXT_MAX;
        while (keep < (size_t)count && keep && ((unsigned char)decoded[keep] & 0xc0) == 0x80) keep--;
        memcpy(message, decoded, keep); message[keep] = 0;
      }
    }
    pair += length;
    if (*pair == ':') pair++;
  }
  bool root = !id[0], step = !strcmp(id, "step"), clear = !strcmp(state, "clear");
  if (!clear && strcmp(state, "idle") && strcmp(state, "working") && strcmp(state, "done") &&
      strcmp(state, "blocked") && strcmp(state, "error")) return;
  if (!root && !step) return;
  EnterCriticalSection(&host->lock);
  if (clear && root) clear_agent(host);
  else {
    AgentRecord *record = root ? &host->agent : &host->step, next = {0};
    if (!clear) {
      snprintf(next.state, sizeof(next.state), "%s", state);
      if (!strcmp(state, "blocked")) snprintf(next.kind, sizeof(next.kind), "%s", kind);
      snprintf(next.message, sizeof(next.message), "%s", message);
      /* A repeated state keeps its start time. A step starts again when its text changes. */
      bool same = !strcmp(record->state, next.state) && (root || !strcmp(record->message, next.message));
      next.since = same ? record->since : (int64_t)time(NULL);
    }
    if (strcmp(record->state, next.state) || strcmp(record->kind, next.kind) ||
        strcmp(record->message, next.message) || record->since != next.since) {
      *record = next;
      InterlockedIncrement(&host->agent_revision);
    }
    /* A step belongs to a run. It ends when the agent rests, even if the agent did not clear it. */
    if (root && host->step.state[0] && (!strcmp(state, "idle") || !strcmp(state, "done") || !strcmp(state, "error"))) {
      host->step = (AgentRecord){0};
      InterlockedIncrement(&host->agent_revision);
    }
  }
  LeaveCriticalSection(&host->lock);
}

/* A trusted prompt mark ends a working or blocked program, but its result stays. Caller holds lock. */
static void end_running_agent(TerminalHost *host) {
  AgentRecord *records[] = { &host->agent, &host->step };
  for (size_t i = 0; i < 2; i++)
    if (!strcmp(records[i]->state, "working") || !strcmp(records[i]->state, "blocked")) {
      *records[i] = (AgentRecord){0};
      InterlockedIncrement(&host->agent_revision);
    }
}

/* Only marks that carry this session's nonce count. A nested shell or a TUI
   cannot fake the integrated shell's prompt and hide a running command. */
static void apply_mark(TerminalHost *host) {
  const char *text = host->mark;
  if (host->mark_overflow) return;
  if (!strncmp(text, "7501;", 5)) {
    if (text[5] != '?') apply_status(host, text + 5);
    return;
  }
  if (!host->pty.shell_integration || strncmp(text, "133;", 4) || !strchr("ABCD", text[4]) || !text[4] ||
      (text[5] && text[5] != ';')) return;
  char tag[48]; int tag_length = snprintf(tag, sizeof(tag), "anvil=%s", host->nonce);
  bool trusted = false;
  for (const char *field = text + 5; *field == ';' && !trusted;) {
    field++;
    size_t length = strcspn(field, ";");
    trusted = length == (size_t)tag_length && !memcmp(field, tag, length);
    field += length;
  }
  if (!trusted) return;
  if (text[4] == 'A') {
    EnterCriticalSection(&host->lock);
    end_running_agent(host);
    LeaveCriticalSection(&host->lock);
  }
  LONG running = text[4] == 'C';
  if (InterlockedExchange(&host->command_running, running) != running)
    host_log(host, running ? "shell integration: command started" : "shell integration: command finished");
}

/* Finds OSC strings across split reads. ESC \ or BEL ends one; CAN or SUB cancels it. */
static void scan_marks(TerminalHost *host, const uint8_t *bytes, DWORD count) {
  enum { TEXT, ESCAPE, OSC, OSC_ESCAPE };
  for (DWORD i = 0; i < count; i++) {
    uint8_t ch = bytes[i];
    if (host->mark_state == OSC_ESCAPE) {
      if (ch == '\\') { host->mark[host->mark_length] = 0; apply_mark(host); host->mark_state = TEXT; continue; }
      host->mark_state = ESCAPE;
    }
    if (host->mark_state == TEXT) { if (ch == 0x1b) host->mark_state = ESCAPE; }
    else if (host->mark_state == ESCAPE) {
      if (ch == ']') { host->mark_state = OSC; host->mark_length = 0; host->mark_overflow = false; }
      else if (ch != 0x1b) host->mark_state = TEXT;
    } else if (ch == 7) { host->mark[host->mark_length] = 0; apply_mark(host); host->mark_state = TEXT; }
    else if (ch == 0x1b) host->mark_state = OSC_ESCAPE;
    else if (ch == 0x18 || ch == 0x1a) host->mark_state = TEXT;
    else if (host->mark_length + 1 < sizeof(host->mark)) host->mark[host->mark_length++] = (char)ch;
    else host->mark_overflow = true;
  }
}

static DWORD WINAPI host_reader(void *userdata) {
  TerminalHost *host = userdata;
  uint8_t bytes[65536];
  while (!InterlockedCompareExchange(&host->reader_stop, 0, 0)) {
    DWORD read = 0;
    if (!ReadFile(host->pty.output_read, bytes, sizeof(bytes), &read, NULL) || !read) break;
    scan_marks(host, bytes, read);
    EnterCriticalSection(&host->lock);
    while (host->replaying && !host->stop && !host->reader_stop)
      SleepConditionVariableCS(&host->space, &host->lock, INFINITE);
    if (host->reader_stop) { LeaveCriticalSection(&host->lock); break; }
    /* Only the editor answers terminal queries. Detached queries go unanswered.
       ConPTY itself answers cursor-position DSR requests. */
    ghostty_terminal_vt_write(host->model, bytes, read);
    InterlockedIncrement64(&host->model_revision);
    if (host->attached && !host->stop) queue_record(host, ANVIL_TERMINAL_OUTPUT, bytes, read);
    InterlockedExchange64(&host->last_output, GetTickCount64());
    LeaveCriticalSection(&host->lock);
  }
  InterlockedExchange(&host->reader_done, 1);
  return 0;
}

static DWORD WINAPI host_writer(void *userdata) {
  TerminalHost *host = userdata;
  while (!InterlockedCompareExchange(&host->client_stop, 0, 0)) {
    EnterCriticalSection(&host->lock);
    while (!host->head && !host->client_stop)
      SleepConditionVariableCS(&host->ready, &host->lock, INFINITE);
    HostRecord *record = host->head;
    if (record) { host->head = record->next; if (!host->head) host->tail = NULL; }
    LeaveCriticalSection(&host->lock);
    if (!record) continue;
    bool ok = anvil_ipc_pipe_write(&host->pipe, record->type, record->bytes, record->length, NULL, 0);
    EnterCriticalSection(&host->lock);
    host->queued -= sizeof(*record) + record->length;
    if (ok) {
      host->writer_progress++;
      if (record->type == ANVIL_TERMINAL_EXITED) InterlockedExchange64(&host->exit_sent_ms, GetTickCount64());
    }
    WakeAllConditionVariable(&host->space);
    LeaveCriticalSection(&host->lock);
    free(record);
    if (!ok) { stop_client(host); break; }
  }
  return 0;
}

static bool apply_size(TerminalHost *host, AnvilTerminalSize size) {
  if (!size.cols || !size.rows || size.cols > 32767 || size.rows > 32767 ||
      !size.cell_width || !size.cell_height) return false;
  if ((size.cols != host->size.cols || size.rows != host->size.rows) &&
      FAILED(anvil_conpty_resize(host->pty.pseudoconsole, (COORD){size.cols, size.rows}))) return false;
  if (ghostty_terminal_resize(host->model, size.cols, size.rows,
      size.cell_width, size.cell_height) != GHOSTTY_SUCCESS) return false;
  host->size = size;
  InterlockedIncrement64(&host->model_revision);
  return true;
}

static DWORD WINAPI host_client(void *userdata) {
  TerminalHost *host = userdata;
  AnvilIPCHeader header; uint8_t bytes[ANVIL_TERMINAL_MAX_PAYLOAD];
  while (anvil_ipc_pipe_read(&host->pipe, &header, bytes, sizeof(bytes))) {
    if (header.type == ANVIL_TERMINAL_INPUT && header.size) {
      InterlockedExchange64(&host->last_input, GetTickCount64());
      DWORD offset = 0;
      while (offset < header.size && !host->client_stop) {
        DWORD written = 0;
        if (!WriteFile(host->pty.input_write, bytes + offset, header.size - offset, &written, NULL) || !written) {
          stop_client(host); break;
        }
        offset += written;
      }
    } else if (header.type == ANVIL_TERMINAL_RESIZE && header.size == sizeof(AnvilTerminalSize)) {
      AnvilTerminalSize size; memcpy(&size, bytes, sizeof(size));
      EnterCriticalSection(&host->lock); bool ok = apply_size(host, size); LeaveCriticalSection(&host->lock);
      if (!ok) break;
    } else if (header.type == ANVIL_TERMINAL_CLOSE && !header.size) {
      host->explicit_close = true;
      host_log(host, "close requested"); stop_host(host); return 0;
    } else if (header.type == ANVIL_TERMINAL_CLEAR && !header.size) {
      static const uint8_t clear[] = "\033[2J\033[3J\033[H";
      EnterCriticalSection(&host->lock);
      while (host->replaying && !host->client_stop && !host->stop)
        SleepConditionVariableCS(&host->space, &host->lock, INFINITE);
      if (host->attached && !host->stop) {
        ghostty_terminal_vt_write(host->model, clear, sizeof(clear) - 1);
        InterlockedIncrement64(&host->model_revision);
        queue_record(host, ANVIL_TERMINAL_OUTPUT, clear, sizeof(clear) - 1);
      }
      LeaveCriticalSection(&host->lock);
    } else if (header.type == ANVIL_TERMINAL_DETACH && !header.size) {
      host_log(host, "detach requested"); break;
    } else break;
  }
  stop_client(host);
  return 0;
}

static void join_thread(HANDLE *thread) {
  if (!*thread) return;
  do { CancelSynchronousIo(*thread); } while (WaitForSingleObject(*thread, 10) == WAIT_TIMEOUT);
  CloseHandle(*thread); *thread = NULL;
}

static bool save_snapshot(TerminalHost *host, bool final);

static void disconnect_client(TerminalHost *host) {
  stop_client(host);
  join_thread(&host->client); join_thread(&host->writer);
  EnterCriticalSection(&host->lock);
  while (host->head) { HostRecord *next = host->head->next; free(host->head); host->head = next; }
  host->tail = NULL; host->queued = 0;
  host->replaying = false;
  WakeAllConditionVariable(&host->space);
  LeaveCriticalSection(&host->lock);
  DisconnectNamedPipe(host->pipe.handle);
  ResetEvent(host->pipe.stop_event);
  InterlockedExchange(&host->client_stop, 0);
  host_log(host, host->stop ? "client closed; end host" : "detached; shell remains live");
  if (!host->stop && host->model) save_snapshot(host, false);
}

static bool attach_client(TerminalHost *host) {
  ULONG actual_pid = 0;
  AnvilIPCHeader header; AnvilTerminalHello hello;
  host->pipe.timeout_ms = 5000;
  if (!GetNamedPipeClientProcessId(host->pipe.handle, &actual_pid) ||
      !anvil_ipc_pipe_read(&host->pipe, &header, &hello, sizeof(hello)) ||
      header.type != ANVIL_TERMINAL_HELLO || header.size != sizeof(hello) ||
      memcmp(hello.id, host->id, ANVIL_TERMINAL_ID_LENGTH + 1) != 0 || hello.client_pid != actual_pid ||
      hello.replay > 1) {
    host_log(host, "rejected client: HELLO identity or protocol mismatch"); return false;
  }
  if (!hello.replay) {
    /* A close must work even when snapshot encoding is unavailable. */
    AnvilTerminalWelcome welcome = { GetCurrentProcessId(), GetProcessId(host->pty.process), 1, host->size };
    if (anvil_ipc_pipe_write(&host->pipe, ANVIL_TERMINAL_WELCOME, &welcome, sizeof(welcome), NULL, 0) &&
        anvil_ipc_pipe_read(&host->pipe, &header, NULL, 0) && !header.size) {
      if (header.type == ANVIL_TERMINAL_CLOSE) {
        host->explicit_close = true;
        host_log(host, "close requested through control connection"); stop_host(host);
      } else if (header.type == ANVIL_TERMINAL_DETACH) host_log(host, "detach requested through control connection");
    }
    return false;
  }
  host->pipe.timeout_ms = INFINITE;
  uint8_t *snapshot = NULL; size_t length = 0;
  EnterCriticalSection(&host->lock);
  AnvilTerminalSize size = hello.size;
  /* A restored View has no layout yet. Keep the live grid, not a temporary 80x24
     grid that makes ConPTY repaint its old physical screen over a cleared model. */
  if (!size.cols && !size.rows) { size.cols = host->size.cols; size.rows = host->size.rows; }
  bool ok = apply_size(host, size) && anvil_terminal_snapshot_encode(host->model, &snapshot, &length);
  host->attached = ok; host->replaying = ok;
  if (ok) {
    host->writer = CreateThread(NULL, 0, host_writer, host, 0, NULL);
    host->client = CreateThread(NULL, 0, host_client, host, 0, NULL);
    ok = host->writer && host->client;
  }
  if (ok) {
    AnvilTerminalWelcome welcome = { GetCurrentProcessId(), GetProcessId(host->pty.process), 1, host->size };
    ok = queue_record(host, ANVIL_TERMINAL_WELCOME, &welcome, sizeof(welcome));
    /* The checkpoint stays immutable while queue waits release the model lock. */
    for (size_t offset = 0; ok && offset < length;) {
      size_t count = length - offset;
      if (count > ANVIL_TERMINAL_MAX_PAYLOAD) count = ANVIL_TERMINAL_MAX_PAYLOAD;
      ok = queue_record(host, ANVIL_TERMINAL_REPLAY, snapshot + offset, (uint32_t)count);
      offset += count;
    }
    ok = ok && queue_record(host, ANVIL_TERMINAL_REPLAY_END, NULL, 0);
    AnvilTerminalStatus status = { host->busy };
    ok = ok && queue_record(host, ANVIL_TERMINAL_STATUS, &status, sizeof(status));
    host->status_pending = false;
  }
  host->replaying = false;
  WakeAllConditionVariable(&host->space);
  LeaveCriticalSection(&host->lock);
  free(snapshot);
  if (!ok) { host_log(host, "attach failed; keep shell"); stop_client(host); return false; }
  write_registry(host);
  host_log(host, "attach client=%lu shell=%lu snapshot=%zu", (unsigned long)actual_pid,
    (unsigned long)GetProcessId(host->pty.process), length);
  return true;
}

static DWORD WINAPI close_console(void *userdata) {
  TerminalHost *host = userdata;
  anvil_conpty_close_console(host->pty.pseudoconsole);
  return 0;
}

static void join_reader(TerminalHost *host) {
  EnterCriticalSection(&host->lock);
  InterlockedExchange(&host->reader_stop, 1); WakeAllConditionVariable(&host->space);
  LeaveCriticalSection(&host->lock);
  join_thread(&host->reader);
}

/* Unknown process state is busy: do not end a shell on a failed probe. */
static bool shell_busy(TerminalHost *host, char *command, size_t capacity, DWORD *command_pid) {
  command[0] = 0; *command_pid = 0;
  DWORD pid = GetProcessId(host->pty.process);
  FILETIME shell_created, unused;
  bool shell_time = GetProcessTimes(host->pty.process, &shell_created, &unused, &unused, &unused) != FALSE;
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return true;
  PROCESSENTRY32W entry = { .dwSize = sizeof(entry) };
  bool busy = false;
  if (!Process32FirstW(snapshot, &entry)) busy = true;
  else do { if (entry.th32ParentProcessID == pid) {
      HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, entry.th32ProcessID);
      /* Windows reuses process IDs. A process whose parent ended before the shell
         started can name the shell's ID as its parent. A child is never older. */
      FILETIME created;
      if (process && shell_time && GetProcessTimes(process, &created, &unused, &unused, &unused) &&
          CompareFileTime(&created, &shell_created) < 0) {
        if (host->ignored_child_pid != entry.th32ProcessID) {
          host->ignored_child_pid = entry.th32ProcessID;
          host_log(host, "ignored process %lu: it predates the shell whose reused ID it names as parent",
            (unsigned long)entry.th32ProcessID);
        }
        CloseHandle(process);
        continue;
      }
      busy = true;
      /* A prompt helper is a child, but not a command worth offering again.
         Keep scanning: another child can hold the interrupted command. */
      if (!_wcsicmp(entry.szExeFile, L"oh-my-posh.exe") || !_wcsicmp(entry.szExeFile, L"starship.exe")) {
        if (process) CloseHandle(process);
        continue;
      }
      *command_pid = entry.th32ProcessID;
      typedef LONG (WINAPI *QueryProcess)(HANDLE, ULONG, void *, ULONG, ULONG *);
      QueryProcess query = (QueryProcess)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtQueryInformationProcess");
      ULONG needed = 0;
      if (process && query) query(process, 60 /* ProcessCommandLineInformation */, NULL, 0, &needed);
      uint8_t *buffer = needed && needed <= 32768 ? malloc(needed) : NULL;
      if (buffer && query(process, 60, buffer, needed, &needed) >= 0) {
        struct { USHORT length, maximum; wchar_t *buffer; } *text = (void *)buffer;
        uintptr_t start = (uintptr_t)buffer, ptr = (uintptr_t)text->buffer;
        if (ptr >= start && ptr - start <= needed && text->length <= needed - (ptr - start)) {
          int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text->buffer, text->length / 2,
            command, (int)capacity - 1, NULL, NULL);
          if (count > 0) command[count] = 0;
        }
      }
      free(buffer);
      if (process) CloseHandle(process);
      break;
    } }
    while (Process32NextW(snapshot, &entry));
  if (!busy && GetLastError() != ERROR_NO_MORE_FILES) busy = true;
  CloseHandle(snapshot);
  return busy;
}

static void capture_cwd(TerminalHost *host, GhosttyTerminal snapshot) {
  GhosttyString pwd = {0};
  if (ghostty_terminal_get(snapshot, GHOSTTY_TERMINAL_DATA_PWD, &pwd) != GHOSTTY_SUCCESS ||
      !pwd.ptr || !pwd.len || pwd.len >= sizeof(host->last_cwd)) return;
  char text[32768]; memcpy(text, pwd.ptr, pwd.len); text[pwd.len] = 0;
  char *path = text;
  if (!strncmp(path, "file://localhost/", 17)) path += 16;
  else if (!strncmp(path, "file:///", 8)) path += 7;
  if (path[0] == '/' && path[1] && path[2] == ':') path++;
  char decoded[32768]; size_t count = 0;
  for (; *path; path++) {
    unsigned ch = (unsigned char)*path;
    if (ch == '%' && path[1] && path[2]) {
      unsigned hex = 0;
      if (sscanf(path + 1, "%2x", &hex) != 1) return;
      ch = hex; path += 2;
    }
    if (ch < 32 || ch == 127) return;
    decoded[count++] = (char)ch;
  }
  decoded[count] = 0;
  if (!(count > 2 && decoded[1] == ':') && strncmp(decoded, "\\\\", 2)) return;
  wchar_t *wide = wide_string(decoded);
  DWORD attrs = wide ? GetFileAttributesW(wide) : INVALID_FILE_ATTRIBUTES;
  free(wide);
  if (attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY)) strcpy(host->last_cwd, decoded);
}

/* Runs in the host, never in the editor's UI thread. */
static bool save_snapshot(TerminalHost *host, bool final) {
  uint8_t *bytes = NULL; size_t length = 0;
  EnterCriticalSection(&host->lock);
  uint64_t started = GetTickCount64();
  uint64_t revision = InterlockedCompareExchange64(&host->model_revision, 0, 0);
  /* Capture once. Decode, trim, validate metadata, and publish after unlock. */
  bool ok = anvil_terminal_snapshot_encode(host->model, &bytes, &length);
  uint64_t capture_ms = GetTickCount64() - started;
  LeaveCriticalSection(&host->lock);
  size_t captured = length;
  GhosttyTerminal copy = NULL;
  if (ok) ok = anvil_terminal_disk_snapshot_prepare(&bytes, &length, &copy);
  if (ok) capture_cwd(host, copy);
  if (copy) ghostty_terminal_free(copy);
  DWORD error = ERROR_INVALID_DATA;
  if (ok) ok = anvil_terminal_snapshot_store(host->snapshot_path, host->project, host->id, bytes, length, final, &error);
  free(bytes);
  host->snapshot_at = GetTickCount64();
  if (ok) { host->snapshot_revision = revision; write_registry(host); }
  host_log(host, "disk snapshot %s: captured=%zu bytes=%zu capture_ms=%llu total_ms=%llu final=%d Windows error=%lu",
    ok ? "saved" : "failed", captured, length, (unsigned long long)capture_ms,
    (unsigned long long)(GetTickCount64() - started), final, (unsigned long)error);
  return ok;
}

static bool prepare_revival(GhosttyTerminal model, uint16_t rows) {
  uint8_t *alternate = NULL; size_t length = 0;
  GhosttyTerminalScreen screen;
  if (ghostty_terminal_get(model, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen) != GHOSTTY_SUCCESS) return false;
  if (screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE) {
    GhosttyFormatter formatter = NULL;
    GhosttyFormatterTerminalOptions options = {
      .size = sizeof(options), .emit = GHOSTTY_FORMATTER_FORMAT_VT, .trim = true,
    };
    /* Ghostty's NULL default allocator crashes the host; use the allocator that owns the model. */
    bool ok = ghostty_formatter_terminal_new(&terminal_allocator, &formatter, model, options) == GHOSTTY_SUCCESS &&
      ghostty_formatter_format_buf(formatter, NULL, 0, &length) == GHOSTTY_OUT_OF_SPACE &&
      length <= ANVIL_TERMINAL_DISK_SNAPSHOT_LIMIT;
    if (ok) alternate = malloc(length ? length : 1);
    ok = ok && alternate && ghostty_formatter_format_buf(formatter, alternate, length, &length) == GHOSTTY_SUCCESS;
    ghostty_formatter_free(formatter);
    if (!ok) { free(alternate); return false; }
  }
  /* Reset parser and app modes. Keep primary history. Do not replay binary bytes as VT. */
  char reset[256];
  int n = snprintf(reset, sizeof(reset), "\030\033\\\033[?2026l\033[?1049l\033[!p"
    "\033[?1000;1002;1003;1004;1005;1006;1015;2004l\033[>0u\033[0m\033[r\033[%u;1H\r\n", rows);
  ghostty_terminal_vt_write(model, (const uint8_t *)reset, n);
  if (alternate) {
    for (unsigned i = 0; i < rows; i++) ghostty_terminal_vt_write(model, (const uint8_t *)"\r\n", 2);
    /* Copy the last visible alternate screen into primary history before the marker. */
    ghostty_terminal_vt_write(model, alternate, length);
    ghostty_terminal_vt_write(model, (const uint8_t *)"\r\n", 2);
    free(alternate);
  }
  const char *marker = "--- Restored session; the previous shell ended ---\r\n";
  ghostty_terminal_vt_write(model, (const uint8_t *)marker, strlen(marker));
  for (unsigned i = 0; i < rows; i++) ghostty_terminal_vt_write(model, (const uint8_t *)"\r\n", 2);
  /* The new ConPTY starts with its cursor at the top left of a blank screen.
     The model must agree, or the shell's cursor moves land on other rows. */
  ghostty_terminal_vt_write(model, (const uint8_t *)"\033[H", 3);
  return true;
}

/* The option goes first. An Anvil that a Terminal Session started inherits that session's preload, and the
   runtime runs preloads in order. The first preload claims Pi, so this Anvil's own preload must run first. */
static void prepend_environment_option(const wchar_t *name, const wchar_t *option) {
  static wchar_t current[32768], value[32768];
  DWORD length = GetEnvironmentVariableW(name, current, 32768);
  if (length >= 32768) return;
  if (!length) current[0] = 0;
  if (wcsstr(current, option)) return;
  int count = _snwprintf(value, 32768, current[0] ? L"%ls %ls" : L"%ls%ls", option, current);
  if (count > 0 && count < 32768) SetEnvironmentVariableW(name, value);
}

/* Node and Bun load Anvil's agent preload into each program the shell starts.
   In Pi, it reports the session file Pi writes, so revival can resume that Agent Session. */
static void set_agent_environment(TerminalHost *host, const char *datadir) {
  static wchar_t option[32800], short_path[32768];
  char script[32768];
  /* Pi sends program status (OSC 7501) only to a terminal that answers its query, and only the editor answers
     queries. The host reads the reports, so Pi may send them without asking. A value the user set stays. */
  if (!GetEnvironmentVariableW(L"PI_PROGRAM_STATUS", NULL, 0)) SetEnvironmentVariableW(L"PI_PROGRAM_STATUS", L"1");
  snprintf(script, sizeof(script), "%s/tools/agent-sessions/pi.cjs", datadir);
  wchar_t *report = wide_string(host->agent_report_path), *path = wide_string(script);
  DWORD attrs = path ? GetFileAttributesW(path) : INVALID_FILE_ATTRIBUTES;
  if (!report || attrs == INVALID_FILE_ATTRIBUTES || (attrs & FILE_ATTRIBUTE_DIRECTORY)) {
    host_log(host, "agent preload: unavailable at %s", script);
  } else {
    SetEnvironmentVariableW(L"ANVIL_TERMINAL_AGENT_REPORT", report);
    /* A Pi that started Anvil is not the Pi of this terminal. */
    SetEnvironmentVariableW(L"ANVIL_TERMINAL_AGENT_OWNER", NULL);
    /* Both option parsers treat a backslash as an escape. Both runtimes accept forward slashes. */
    DWORD length = GetShortPathNameW(path, short_path, 32768);
    for (wchar_t *p = path; *p; p++) if (*p == L'\\') *p = L'/';
    for (wchar_t *p = short_path; length && length < 32768 && *p; p++) if (*p == L'\\') *p = L'/';
    if (_snwprintf(option, 32800, L"--require \"%ls\"", path) > 0) prepend_environment_option(L"NODE_OPTIONS", option);
    /* Bun splits BUN_OPTIONS at spaces and has no quoting, so it gets the short path. */
    if (length && length < 32768 && !wcschr(short_path, L' ') &&
        _snwprintf(option, 32800, L"--preload %ls", short_path) > 0) prepend_environment_option(L"BUN_OPTIONS", option);
    else host_log(host, "agent preload: no path without spaces; Bun agents are not tracked");
  }
  free(report); free(path);
}

int anvil_terminal_host_main(int argc, char **argv) {
  if ((argc != 14 && argc != 16) || !anvil_terminal_id_valid(argv[2]) || strlen(argv[4]) > 32000 ||
      (argc == 16 && strcmp(argv[14], "--revive-from"))) return 1;
  char expected_pipe[128]; snprintf(expected_pipe, sizeof(expected_pipe), "\\\\.\\pipe\\anvil-terminal-%s", argv[2]);
  if (strcmp(argv[3], expected_pipe) != 0) return 1;
  TerminalHost host = { .busy = true, .id = argv[2], .pipe_name = argv[3], .shell = argv[5],
    .cwd = argv[6], .project = argv[12], .activity = (int64_t)time(NULL) };
  InitializeCriticalSection(&host.lock);
  InitializeConditionVariable(&host.ready); InitializeConditionVariable(&host.space);
  const char *directories[] = { "logs", "terminal-sessions" };
  for (size_t i = 0; i < 2; i++) {
    char dir[32768]; snprintf(dir, sizeof(dir), "%s/%s", argv[4], directories[i]);
    wchar_t *wide = wide_string(dir);
    if (wide) CreateDirectoryW(wide, NULL);
    free(wide);
  }
  snprintf(host.log_path, sizeof(host.log_path), "%s/logs/terminal-session-%s.log", argv[4], argv[2]);
  snprintf(host.record_path, sizeof(host.record_path), "%s/terminal-sessions/%s.lua", argv[4], argv[2]);
  snprintf(host.snapshot_path, sizeof(host.snapshot_path), "%s/terminal-sessions/%s.snapshot", argv[4], argv[2]);
  snprintf(host.agent_report_path, sizeof(host.agent_report_path), "%s/terminal-sessions/%s.agent", argv[4], argv[2]);
  snprintf(host.last_cwd, sizeof(host.last_cwd), "%s", host.cwd);
  uint8_t nonce[16];
  if (random_bytes(nonce, sizeof(nonce)))
    for (size_t i = 0; i < sizeof(nonce); i++) snprintf(host.nonce + i * 2, 3, "%02x", nonce[i]);
  host_log(&host, "start");
  host_log(&host, "ConPTY runtime: %s/conpty", argv[13]);
  set_agent_environment(&host, argv[13]);
  BOOL in_job = FALSE;
  if (IsProcessInJob(GetCurrentProcess(), NULL, &in_job) && in_job)
    host_log(&host, "breakaway unavailable: host remains in parent job");
  AnvilTerminalSize size = { (uint16_t)atoi(argv[7]), (uint16_t)atoi(argv[8]),
    (uint32_t)strtoul(argv[9], NULL, 10), (uint32_t)strtoul(argv[10], NULL, 10) };
  host.size = size;
  size_t lines = (size_t)strtoull(argv[11], NULL, 10);
  DWORD error = 0, exit_code = 1;
  HANDLE revival_lock = NULL;
  bool ever_running = false;
  HANDLE handle = CreateNamedPipeA(argv[3], PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED |
    FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT |
    PIPE_REJECT_REMOTE_CLIENTS, 1, 65536, 65536, 0, NULL);
  OVERLAPPED accept = {0}; bool accepting = false, connected = false;
  accept.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (handle == INVALID_HANDLE_VALUE || !accept.hEvent) goto cleanup;
  if (!anvil_ipc_pipe_init(&host.pipe, handle, ANVIL_TERMINAL_PROTOCOL_VERSION,
                          ANVIL_TERMINAL_MAX_PAYLOAD)) { handle = INVALID_HANDLE_VALUE; goto cleanup; }
  handle = INVALID_HANDLE_VALUE;
  if (argc == 16) {
    revival_lock = registry_lock(host.id);
    if (!revival_lock || registry_host_live(&host)) { error = ERROR_PIPE_BUSY; goto cleanup; }
    /* The path is derived from the validated session ID, never from a record's arbitrary path. */
    if (strcmp(argv[15], host.snapshot_path) ||
        !anvil_terminal_snapshot_load(host.snapshot_path, host.project, host.id, &host.model, &error)) goto cleanup;
    uint16_t cols = 0, rows = 0;
    ghostty_terminal_get(host.model, GHOSTTY_TERMINAL_DATA_COLS, &cols);
    ghostty_terminal_get(host.model, GHOSTTY_TERMINAL_DATA_ROWS, &rows);
    if (!cols || !rows) goto cleanup;
    size.cols = cols; size.rows = rows; host.size = size;
    if (!anvil_terminal_model_options(host.model, strcmp(argv[11], "-1") == 0 ? NULL : &lines)) goto cleanup;
    if (!prepare_revival(host.model, rows)) { error = ERROR_INVALID_DATA; goto cleanup; }
    host_log(&host, "revival: restored disk screen; start new shell");
  } else if (!anvil_terminal_model_new(&host.model, size.cols, size.rows, size.cell_width,
        size.cell_height, strcmp(argv[11], "-1") == 0 ? NULL : &lines)) goto cleanup;
  /* A revived shell starts at the restored screen size, which client resizes compare against. */
  host.pty.cols = size.cols; host.pty.rows = size.rows;
  if (!size.cols || !size.rows || size.cols > 32767 || size.rows > 32767 || !size.cell_width || !size.cell_height ||
      !anvil_conpty_start(&host.pty, argv[5], argv[6], argv[13], host.nonce, &error) || !write_registry(&host)) goto cleanup;
  if (revival_lock) { ReleaseMutex(revival_lock); CloseHandle(revival_lock); revival_lock = NULL; }
  host_log(&host, "shell integration: %s", host.pty.shell_integration ? "on" : "off");
  host.reader = CreateThread(NULL, 0, host_reader, &host, 0, NULL);
  if (!host.reader) goto cleanup;
  ever_running = true;
  exit_code = 0;
  uint64_t exited_at = 0, drain_started = 0, idle_since = GetTickCount64(), busy_probe_at = 0;
  /* Title changes reach the record at most once a second, and typing at most once a minute. */
  uint64_t title_probe_at = 0, title_written_at = 0, input_seen = 0;
  int64_t activity_written = host.activity;
  bool title_pending = false;
  /* Agent status reaches the record at most every 200 ms. */
  LONG agent_written = 0;
  uint64_t agent_written_at = 0;
  char agent_logged[sizeof(host.agent.state)] = "";
  bool exit_queued = false, final_snapshot_saved = false;
  while (!host.stop) {
    uint64_t now = GetTickCount64();
    if ((host.client || host.writer) && host.client_stop) {
      disconnect_client(&host); write_registry(&host); idle_since = now;
    }
    if (!host.client && !host.writer && !accepting && !connected && !exited_at) {
      ResetEvent(accept.hEvent);
      BOOL ok = ConnectNamedPipe(host.pipe.handle, &accept);
      DWORD connect_error = ok ? ERROR_SUCCESS : GetLastError();
      accepting = !ok && connect_error == ERROR_IO_PENDING;
      connected = ok || connect_error == ERROR_PIPE_CONNECTED;
      if (!accepting && !connected) break;
    }
    if (accepting && WaitForSingleObject(accept.hEvent, 0) == WAIT_OBJECT_0) {
      DWORD done = 0;
      connected = GetOverlappedResult(host.pipe.handle, &accept, &done, FALSE) != FALSE;
      accepting = false;
      if (!connected) break;
    }
    if (connected) {
      connected = false;
      if (!attach_client(&host)) { disconnect_client(&host); write_registry(&host); }
      else idle_since = 0;
    }
    if (!exited_at && WaitForSingleObject(host.pty.process, 0) == WAIT_OBJECT_0) {
      host.shell_ended = true;
      exited_at = now; GetExitCodeProcess(host.pty.process, &exit_code); drain_started = now;
      host.console_close = CreateThread(NULL, 0, close_console, &host, 0, NULL);
      host_log(&host, "shell exit code=%lu; drain", (unsigned long)exit_code);
    }
    if (!exited_at && host.reader_done) {
      host_log(&host, "failure: ConPTY output ended while shell was running"); break;
    }
    if (exited_at && !exit_queued) {
      uint64_t last = InterlockedCompareExchange64(&host.last_output, 0, 0);
      bool backpressured = host.backpressured != 0;
      if (backpressured) drain_started = now;
      if ((now - exited_at >= ANVIL_TERMINAL_DRAIN_QUIET_MS &&
           now - last >= ANVIL_TERMINAL_DRAIN_QUIET_MS && host.reader_done) ||
          (!backpressured && now - drain_started >= ANVIL_TERMINAL_DRAIN_MAX_MS)) {
        join_reader(&host);
        if (!host.explicit_close) final_snapshot_saved = save_snapshot(&host, true);
        AnvilTerminalExited exited = { exit_code };
        EnterCriticalSection(&host.lock);
        bool queued = queue_record(&host, ANVIL_TERMINAL_EXITED, &exited, sizeof(exited));
        LeaveCriticalSection(&host.lock);
        exit_queued = true;
        if (!queued) break;
      }
    }
    uint64_t sent_at = InterlockedCompareExchange64(&host.exit_sent_ms, 0, 0);
    if (exit_queued && (!host.attached || (sent_at && now - sent_at > 3000))) break;
    if (!exited_at && now >= busy_probe_at) {
      busy_probe_at = now + (host.attached ? 500 : 2000);
      char command[16384];
      DWORD command_pid = 0;
      /* A child process covers any shell. The integrated shell's marks also cover
         commands that run inside the shell, such as PowerShell's Start-Sleep. */
      bool busy = shell_busy(&host, command, sizeof(command), &command_pid);
      busy = busy || InterlockedCompareExchange(&host.command_running, 0, 0);
      bool command_changed = strcmp(command, host.interrupted_command) != 0 || command_pid != host.interrupted_pid;
      if (command_changed) { strcpy(host.interrupted_command, command); host.interrupted_pid = command_pid; }
      EnterCriticalSection(&host.lock);
      bool busy_changed = host.busy != busy;
      if (busy_changed) {
        host.busy = busy;
        host.status_pending = true;
      }
      /* The agent's records end with the program, as at a prompt. Pi clears them when it quits normally. */
      if (!busy) clear_agent(&host);
      LeaveCriticalSection(&host.lock);
      if (busy_changed) host.activity = (int64_t)time(NULL);
      if (command_changed || busy_changed) {
        write_registry(&host);
        activity_written = host.activity;
      }
      if (host.attached || busy) idle_since = 0;
      else if (!idle_since) idle_since = now;
      uint64_t last = InterlockedCompareExchange64(&host.last_output, 0, 0);
      if (idle_since && now - idle_since >= ORPHAN_GRACE_MS && now >= last && now - last >= ORPHAN_GRACE_MS) {
        host_log(&host, "idle orphan grace expired"); break;
      }
    }
    EnterCriticalSection(&host.lock);
    /* Never block the monitor on a full client queue. Send the latest status later. */
    if (host.attached && !host.replaying && !host.client_stop && host.status_pending &&
        host.queued + sizeof(HostRecord) + sizeof(AnvilTerminalStatus) <= CLIENT_QUEUE_LIMIT) {
      AnvilTerminalStatus status = { host.busy };
      if (queue_record(&host, ANVIL_TERMINAL_STATUS, &status, sizeof(status))) host.status_pending = false;
    }
    LeaveCriticalSection(&host.lock);
    if (!exited_at && now >= title_probe_at) {
      title_probe_at = now + 250;
      char title[sizeof(host.title)] = "";
      EnterCriticalSection(&host.lock);
      GhosttyString text = {0};
      if (ghostty_terminal_get(host.model, GHOSTTY_TERMINAL_DATA_TITLE, &text) == GHOSTTY_SUCCESS && text.ptr) {
        size_t length = text.len < sizeof(title) ? text.len : sizeof(title) - 1;
        memcpy(title, text.ptr, length);
        title[length] = 0;
      }
      LeaveCriticalSection(&host.lock);
      if (strcmp(title, host.title)) {
        strcpy(host.title, title);
        host.activity = (int64_t)time(NULL);
        title_pending = true;
      }
      uint64_t input = (uint64_t)InterlockedCompareExchange64(&host.last_input, 0, 0);
      if (input != input_seen) {
        input_seen = input;
        host.activity = (int64_t)time(NULL);
      }
      if ((title_pending && now - title_written_at >= 1000) || host.activity - activity_written >= 60) {
        write_registry(&host);
        title_pending = false;
        title_written_at = now;
        activity_written = host.activity;
      }
    }
    LONG agent_revision = InterlockedCompareExchange(&host.agent_revision, 0, 0);
    if (agent_revision != agent_written && now - agent_written_at >= 200) {
      agent_written = agent_revision;
      agent_written_at = now;
      write_registry(&host);
      EnterCriticalSection(&host.lock);
      char state[sizeof(host.agent.state)]; strcpy(state, host.agent.state);
      LeaveCriticalSection(&host.lock);
      if (strcmp(state, agent_logged)) {
        host_log(&host, "agent status: %s", state[0] ? state : "none");
        strcpy(agent_logged, state);
      }
    }
    uint64_t revision = InterlockedCompareExchange64(&host.model_revision, 0, 0);
    if (host.model && revision != host.snapshot_revision && now - host.snapshot_at >= 20000) save_snapshot(&host, false);
    Sleep(10);
  }
cleanup:
  if (revival_lock) { ReleaseMutex(revival_lock); CloseHandle(revival_lock); }
  host_log(&host, "exit Windows error=%lu", (unsigned long)error);
  stop_host(&host);
  if (accepting) {
    CancelIoEx(host.pipe.handle, &accept);
    DWORD done; GetOverlappedResult(host.pipe.handle, &accept, &done, TRUE);
  }
  if (accept.hEvent) CloseHandle(accept.hEvent);
  if (host.explicit_close) delete_registry(&host);
  /* Keep draining until ClosePseudoConsole releases its output sink. */
  anvil_conpty_kill(&host.pty);
  if (host.pty.pseudoconsole && !host.console_close)
    host.console_close = CreateThread(NULL, 0, close_console, &host, 0, NULL);
  if (host.console_close && WaitForSingleObject(host.console_close, 5000) == WAIT_TIMEOUT) {
    host_log(&host, "failure: ConPTY close timeout; end host"); ExitProcess(1);
  }
  join_reader(&host);
  if (!host.explicit_close && ever_running && (!final_snapshot_saved ||
      host.snapshot_revision != (uint64_t)InterlockedCompareExchange64(&host.model_revision, 0, 0)))
    save_snapshot(&host, true);
  join_thread(&host.client); join_thread(&host.writer);
  if (host.console_close) { CloseHandle(host.console_close); host.pty.pseudoconsole = NULL; }
  anvil_conpty_close(&host.pty); anvil_ipc_pipe_close(&host.pipe);
  if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
  while (host.head) { HostRecord *next = host.head->next; free(host.head); host.head = next; }
  if (host.model) ghostty_terminal_free(host.model);
  DeleteCriticalSection(&host.lock);
  return (int)exit_code;
}

/* Windows argv quoting, including quotes and trailing backslashes. */
static size_t quote_arg(wchar_t *out, const wchar_t *arg) {
  size_t n = 0; out[n++] = L'"';
  while (*arg) {
    size_t slashes = 0; while (*arg == L'\\') { slashes++; arg++; }
    size_t count = (*arg == L'"' || !*arg) ? slashes * 2 : slashes;
    while (count--) out[n++] = L'\\';
    if (*arg == L'"') out[n++] = L'\\';
    if (*arg) out[n++] = *arg++;
  }
  out[n++] = L'"'; return n;
}

static bool host_connect(AnvilIPCPipe *pipe, HANDLE process, DWORD host_pid,
                         DWORD *shell_pid, const char *id, AnvilTerminalSize *size,
                         bool replay, DWORD *error) {
  if (!anvil_terminal_id_valid(id)) { *error = ERROR_INVALID_DATA; return false; }
  char name[128]; snprintf(name, sizeof(name), "\\\\.\\pipe\\anvil-terminal-%s", id);
  uint64_t deadline = GetTickCount64() + 5000;
  HANDLE handle = INVALID_HANDLE_VALUE;
  *error = ERROR_PIPE_NOT_CONNECTED;
  while (GetTickCount64() < deadline && WaitForSingleObject(process, 0) == WAIT_TIMEOUT) {
    handle = CreateFileA(name, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING,
      FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, NULL);
    if (handle != INVALID_HANDLE_VALUE) break;
    *error = GetLastError();
    if (*error != ERROR_PIPE_BUSY && *error != ERROR_FILE_NOT_FOUND) return false;
    WaitNamedPipeA(name, 20); Sleep(1);
  }
  if (handle == INVALID_HANDLE_VALUE) return false;
  ULONG server = 0;
  if (!GetNamedPipeServerProcessId(handle, &server) || server != host_pid ||
      WaitForSingleObject(process, 0) != WAIT_TIMEOUT) {
    CloseHandle(handle); *error = ERROR_ACCESS_DENIED; return false;
  }
  if (!anvil_ipc_pipe_init(pipe, handle, ANVIL_TERMINAL_PROTOCOL_VERSION, ANVIL_TERMINAL_MAX_PAYLOAD)) {
    *error = ERROR_NOT_ENOUGH_MEMORY; return false;
  }
  pipe->timeout_ms = 5000;
  AnvilTerminalHello hello = { .size = *size, .client_pid = GetCurrentProcessId(), .replay = replay };
  memcpy(hello.id, id, sizeof(hello.id));
  if (!anvil_ipc_pipe_write(pipe, ANVIL_TERMINAL_HELLO, &hello, sizeof(hello), NULL, 0)) {
    *error = GetLastError(); return false;
  }
  AnvilIPCHeader header; AnvilTerminalWelcome welcome;
  if (!anvil_ipc_pipe_read(pipe, &header, &welcome, sizeof(welcome))) {
    *error = GetLastError();
    if (!*error) *error = ERROR_PIPE_NOT_CONNECTED;
    return false;
  }
  if (header.type != ANVIL_TERMINAL_WELCOME || header.size != sizeof(welcome) ||
      welcome.host_pid != host_pid || !welcome.shell_pid || welcome.state != 1 ||
      !welcome.size.cols || !welcome.size.rows || welcome.size.cols > 32767 || welcome.size.rows > 32767 ||
      !welcome.size.cell_width || !welcome.size.cell_height) {
    *error = ERROR_INVALID_DATA; return false;
  }
  *shell_pid = welcome.shell_pid; pipe->timeout_ms = INFINITE;
  *size = welcome.size;
  *error = ERROR_SUCCESS; return true;
}

bool anvil_terminal_host_connect(AnvilIPCPipe *pipe, HANDLE process, DWORD host_pid,
                                 DWORD *shell_pid, const char *id, AnvilTerminalSize *size, DWORD *error) {
  return host_connect(pipe, process, host_pid, shell_pid, id, size, true, error);
}

bool anvil_terminal_host_control(HANDLE process, DWORD host_pid, const char *id,
                                 uint16_t type, DWORD *error) {
  AnvilIPCPipe pipe = {0}; DWORD shell_pid; AnvilTerminalSize size = {0};
  bool ok = host_connect(&pipe, process, host_pid, &shell_pid, id, &size, false, error);
  if (ok) {
    pipe.timeout_ms = 5000;
    ok = anvil_ipc_pipe_write(&pipe, type, NULL, 0, NULL, 0);
    if (!ok) *error = GetLastError();
  }
  anvil_ipc_pipe_close(&pipe);
  return ok;
}

bool anvil_terminal_host_launch(AnvilIPCPipe *pipe, HANDLE *process,
                                DWORD *host_pid, DWORD *shell_pid, uint64_t *replay_bytes,
                                char id[ANVIL_TERMINAL_ID_LENGTH + 1],
                                const char *userdir, const char *project, const char *shell, const char *cwd,
                                const char *datadir,
                                const char *revive_from,
                                AnvilTerminalSize *size, const size_t *scrollback_lines, DWORD *error) {
  uint8_t random[16]; char name[128];
  bool random_ok = revive_from ? anvil_terminal_id_valid(id) : random_bytes(random, sizeof(random));
  if (!random_ok) { *error = ERROR_GEN_FAILURE; return false; }
  if (!revive_from) for (size_t i = 0; i < sizeof(random); i++) snprintf(id + i * 2, 3, "%02x", random[i]);
  snprintf(name, sizeof(name), "\\\\.\\pipe\\anvil-terminal-%s", id);
  wchar_t exe[32768]; DWORD exe_len = GetModuleFileNameW(NULL, exe, 32768);
  if (!exe_len || exe_len * 2 + 3 >= 32768) { *error = ERROR_FILENAME_EXCED_RANGE; return false; }
  char cols[16], rows[16], cw[16], ch[16], lines[32];
  snprintf(cols, sizeof(cols), "%u", size->cols); snprintf(rows, sizeof(rows), "%u", size->rows);
  snprintf(cw, sizeof(cw), "%u", size->cell_width); snprintf(ch, sizeof(ch), "%u", size->cell_height);
  if (scrollback_lines) snprintf(lines, sizeof(lines), "%zu", *scrollback_lines); else strcpy(lines, "-1");
  const char *args[] = { "--terminal-session", id, name, userdir, shell ? shell : "",
    cwd ? cwd : "", cols, rows, cw, ch, lines, project ? project : "", datadir, "--revive-from", revive_from };
  wchar_t *command = calloc(32768, sizeof(wchar_t));
  if (!command) { *error = ERROR_NOT_ENOUGH_MEMORY; return false; }
  size_t n = quote_arg(command, exe);
  bool valid = true;
  size_t arg_count = revive_from ? sizeof(args) / sizeof(args[0]) : sizeof(args) / sizeof(args[0]) - 2;
  for (size_t i = 0; i < arg_count; i++) {
    wchar_t *arg = wide_string(args[i]);
    if (!arg || n + wcslen(arg) * 2 + 4 >= 32768) { free(arg); valid = false; break; }
    command[n++] = L' '; n += quote_arg(command + n, arg); free(arg);
  }
  STARTUPINFOW startup = { .cb = sizeof(startup) }; PROCESS_INFORMATION info = {0};
  DWORD flags = CREATE_BREAKAWAY_FROM_JOB | CREATE_NO_WINDOW;
  wchar_t *first_command = _wcsdup(command);
  BOOL created = valid && first_command && CreateProcessW(exe, first_command, NULL, NULL, FALSE, flags,
    NULL, NULL, &startup, &info);
  DWORD launch_error = GetLastError(); free(first_command);
  if (!created && valid && launch_error == ERROR_ACCESS_DENIED) {
    created = CreateProcessW(exe, command, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &startup, &info);
    launch_error = GetLastError();
  }
  *error = valid ? launch_error : ERROR_INVALID_PARAMETER; free(command);
  if (!created) return false;
  CloseHandle(info.hThread); *process = info.hProcess; *host_pid = info.dwProcessId;
  *replay_bytes = 0;
  if (revive_from) { size->cols = 0; size->rows = 0; }
  return anvil_terminal_host_connect(pipe, *process, *host_pid, shell_pid, id, size, error);
}
