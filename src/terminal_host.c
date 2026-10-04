#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include "terminal_host.h"
#include "conpty.h"
#include "terminal_model.h"
#include <tlhelp32.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#define CLIENT_QUEUE_LIMIT (8u * 1024u * 1024u)
#define CLIENT_STALL_TIMEOUT_MS 10000u
#define ORPHAN_GRACE_MS (10u * 60u * 1000u)

typedef struct HostRecord {
  struct HostRecord *next;
  uint32_t length;
  uint16_t type;
  uint8_t bytes[];
} HostRecord;

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
  uint64_t writer_progress;
  volatile LONG backpressured, client_stop;
  volatile LONG stop, reader_stop, reader_done;
  volatile LONG64 last_output, exit_sent_ms;
  HANDLE reader, writer, client, console_close;
  const char *id, *pipe_name, *project, *shell, *cwd;
  char log_path[32768], record_path[32768];
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

static bool write_registry(TerminalHost *host) {
  char temporary[32772], created[17], snapshot[32768];
  if (!creation_time(GetCurrentProcess(), created)) return false;
  snprintf(temporary, sizeof(temporary), "%s.tmp", host->record_path);
  snprintf(snapshot, sizeof(snapshot), "%.*s.snapshot",
    (int)(strlen(host->record_path) - 4), host->record_path);
  wchar_t *path = wide_string(host->record_path), *temp = wide_string(temporary);
  FILE *file = temp ? _wfopen(temp, L"wb") : NULL;
  bool ok = path && file;
  if (ok) {
    fprintf(file, "return {\n  version = 1,\n  host_pid = %lu,\n  attached = %s,\n",
      (unsigned long)GetCurrentProcessId(), host->attached ? "true" : "false");
    registry_string(file, "session_id", host->id);
    registry_string(file, "host_creation_time", created);
    registry_string(file, "pipe_name", host->pipe_name);
    registry_string(file, "project_path", host->project);
    registry_string(file, "shell", host->shell);
    registry_string(file, "cwd", host->cwd);
    registry_string(file, "status", "running");
    registry_string(file, "snapshot_path", snapshot);
    fputs("}\n", file);
    ok = !ferror(file);
  }
  if (file && fclose(file) != 0) ok = false;
  if (ok) ok = MoveFileExW(temp, path, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != FALSE;
  if (!ok && temp) DeleteFileW(temp);
  free(path); free(temp);
  if (!ok) host_log(host, "failure: registry write Windows error=%lu", (unsigned long)GetLastError());
  return ok;
}

static void delete_registry(TerminalHost *host) {
  wchar_t *path = wide_string(host->record_path);
  if (path) DeleteFileW(path);
  free(path);
  char snapshot[32768];
  snprintf(snapshot, sizeof(snapshot), "%.*s.snapshot",
    (int)(strlen(host->record_path) - 4), host->record_path);
  path = wide_string(snapshot);
  if (path) DeleteFileW(path);
  free(path);
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

static DWORD WINAPI host_reader(void *userdata) {
  TerminalHost *host = userdata;
  uint8_t bytes[65536];
  while (!InterlockedCompareExchange(&host->reader_stop, 0, 0)) {
    DWORD read = 0;
    if (!ReadFile(host->pty.output_read, bytes, sizeof(bytes), &read, NULL) || !read) break;
    EnterCriticalSection(&host->lock);
    while (host->replaying && !host->stop && !host->reader_stop)
      SleepConditionVariableCS(&host->space, &host->lock, INFINITE);
    if (host->reader_stop) { LeaveCriticalSection(&host->lock); break; }
    /* Only the editor answers terminal queries. Detached queries go unanswered.
       ConPTY itself answers cursor-position DSR requests. */
    ghostty_terminal_vt_write(host->model, bytes, read);
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
      FAILED(ResizePseudoConsole(host->pty.pseudoconsole, (COORD){size.cols, size.rows}))) return false;
  if (ghostty_terminal_resize(host->model, size.cols, size.rows,
      size.cell_width, size.cell_height) != GHOSTTY_SUCCESS) return false;
  host->size = size;
  return true;
}

static DWORD WINAPI host_client(void *userdata) {
  TerminalHost *host = userdata;
  AnvilIPCHeader header; uint8_t bytes[ANVIL_TERMINAL_MAX_PAYLOAD];
  while (anvil_ipc_pipe_read(&host->pipe, &header, bytes, sizeof(bytes))) {
    if (header.type == ANVIL_TERMINAL_INPUT && header.size) {
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
      host_log(host, "close requested"); stop_host(host); return 0;
    } else if (header.type == ANVIL_TERMINAL_CLEAR && !header.size) {
      static const uint8_t clear[] = "\033[2J\033[3J\033[H";
      EnterCriticalSection(&host->lock);
      while (host->replaying && !host->client_stop && !host->stop)
        SleepConditionVariableCS(&host->space, &host->lock, INFINITE);
      if (host->attached && !host->stop) {
        ghostty_terminal_vt_write(host->model, clear, sizeof(clear) - 1);
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
  ClosePseudoConsole(host->pty.pseudoconsole);
  return 0;
}

static void join_reader(TerminalHost *host) {
  EnterCriticalSection(&host->lock);
  InterlockedExchange(&host->reader_stop, 1); WakeAllConditionVariable(&host->space);
  LeaveCriticalSection(&host->lock);
  join_thread(&host->reader);
}

/* Unknown process state is busy: do not end a shell on a failed probe. */
static bool shell_busy(DWORD pid) {
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return true;
  PROCESSENTRY32W entry = { .dwSize = sizeof(entry) };
  bool busy = false;
  if (!Process32FirstW(snapshot, &entry)) busy = true;
  else do { if (entry.th32ParentProcessID == pid) { busy = true; break; } }
    while (Process32NextW(snapshot, &entry));
  if (!busy && GetLastError() != ERROR_NO_MORE_FILES) busy = true;
  CloseHandle(snapshot);
  return busy;
}

int anvil_terminal_host_main(int argc, char **argv) {
  if (argc != 13 || !anvil_terminal_id_valid(argv[2]) || strlen(argv[4]) > 32000) return 1;
  char expected_pipe[128]; snprintf(expected_pipe, sizeof(expected_pipe), "\\\\.\\pipe\\anvil-terminal-%s", argv[2]);
  if (strcmp(argv[3], expected_pipe) != 0) return 1;
  TerminalHost host = { .id = argv[2], .pipe_name = argv[3], .shell = argv[5],
    .cwd = argv[6], .project = argv[12] };
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
  host_log(&host, "start");
  BOOL in_job = FALSE;
  if (IsProcessInJob(GetCurrentProcess(), NULL, &in_job) && in_job)
    host_log(&host, "breakaway unavailable: host remains in parent job");
  AnvilTerminalSize size = { (uint16_t)atoi(argv[7]), (uint16_t)atoi(argv[8]),
    (uint32_t)strtoul(argv[9], NULL, 10), (uint32_t)strtoul(argv[10], NULL, 10) };
  host.size = size;
  size_t lines = (size_t)strtoull(argv[11], NULL, 10);
  DWORD error = 0, exit_code = 1;
  HANDLE handle = CreateNamedPipeA(argv[3], PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED |
    FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT |
    PIPE_REJECT_REMOTE_CLIENTS, 1, 65536, 65536, 0, NULL);
  OVERLAPPED accept = {0}; bool accepting = false, connected = false;
  accept.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (handle == INVALID_HANDLE_VALUE || !accept.hEvent) goto cleanup;
  if (!anvil_ipc_pipe_init(&host.pipe, handle, ANVIL_TERMINAL_PROTOCOL_VERSION,
                          ANVIL_TERMINAL_MAX_PAYLOAD)) { handle = INVALID_HANDLE_VALUE; goto cleanup; }
  handle = INVALID_HANDLE_VALUE;
  host.pty.cols = size.cols; host.pty.rows = size.rows;
  if (!size.cols || !size.rows || size.cols > 32767 || size.rows > 32767 ||
      !size.cell_width || !size.cell_height ||
      !anvil_terminal_model_new(&host.model, size.cols, size.rows, size.cell_width,
        size.cell_height, strcmp(argv[11], "-1") == 0 ? NULL : &lines) ||
      !anvil_conpty_start(&host.pty, argv[5], argv[6], &error) || !write_registry(&host)) goto cleanup;
  host.reader = CreateThread(NULL, 0, host_reader, &host, 0, NULL);
  if (!host.reader) goto cleanup;
  exit_code = 0;
  uint64_t exited_at = 0, drain_started = 0, idle_since = GetTickCount64(), busy_probe_at = 0;
  bool exit_queued = false;
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
    if (!host.attached && !exited_at && now >= busy_probe_at) {
      busy_probe_at = now + 500;
      if (shell_busy(GetProcessId(host.pty.process))) idle_since = 0;
      else if (!idle_since) idle_since = now;
      uint64_t last = InterlockedCompareExchange64(&host.last_output, 0, 0);
      if (idle_since && now - idle_since >= ORPHAN_GRACE_MS && now >= last && now - last >= ORPHAN_GRACE_MS) {
        host_log(&host, "idle orphan grace expired"); break;
      }
    }
    Sleep(10);
  }
cleanup:
  host_log(&host, "exit Windows error=%lu", (unsigned long)error);
  stop_host(&host);
  if (accepting) {
    CancelIoEx(host.pipe.handle, &accept);
    DWORD done; GetOverlappedResult(host.pipe.handle, &accept, &done, TRUE);
  }
  if (accept.hEvent) CloseHandle(accept.hEvent);
  delete_registry(&host);
  /* Keep draining until ClosePseudoConsole releases its output sink. */
  anvil_conpty_kill(&host.pty);
  if (host.pty.pseudoconsole && !host.console_close)
    host.console_close = CreateThread(NULL, 0, close_console, &host, 0, NULL);
  if (host.console_close && WaitForSingleObject(host.console_close, 5000) == WAIT_TIMEOUT) {
    host_log(&host, "failure: ConPTY close timeout; end host"); ExitProcess(1);
  }
  join_reader(&host);
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
                                AnvilTerminalSize size, const size_t *scrollback_lines, DWORD *error) {
  uint8_t random[16]; char name[128];
  typedef BOOLEAN (WINAPI *RandomFunction)(void *, ULONG);
  HMODULE library = LoadLibraryW(L"advapi32.dll");
  RandomFunction random_function = library ? (RandomFunction)GetProcAddress(library, "SystemFunction036") : NULL;
  bool random_ok = random_function && random_function(random, sizeof(random));
  if (library) FreeLibrary(library);
  if (!random_ok) { *error = ERROR_GEN_FAILURE; return false; }
  for (size_t i = 0; i < sizeof(random); i++) snprintf(id + i * 2, 3, "%02x", random[i]);
  snprintf(name, sizeof(name), "\\\\.\\pipe\\anvil-terminal-%s", id);
  wchar_t exe[32768]; DWORD exe_len = GetModuleFileNameW(NULL, exe, 32768);
  if (!exe_len || exe_len * 2 + 3 >= 32768) { *error = ERROR_FILENAME_EXCED_RANGE; return false; }
  char cols[16], rows[16], cw[16], ch[16], lines[32];
  snprintf(cols, sizeof(cols), "%u", size.cols); snprintf(rows, sizeof(rows), "%u", size.rows);
  snprintf(cw, sizeof(cw), "%u", size.cell_width); snprintf(ch, sizeof(ch), "%u", size.cell_height);
  if (scrollback_lines) snprintf(lines, sizeof(lines), "%zu", *scrollback_lines); else strcpy(lines, "-1");
  const char *args[] = { "--terminal-session", id, name, userdir, shell ? shell : "",
    cwd ? cwd : "", cols, rows, cw, ch, lines, project ? project : "" };
  wchar_t *command = calloc(32768, sizeof(wchar_t));
  if (!command) { *error = ERROR_NOT_ENOUGH_MEMORY; return false; }
  size_t n = quote_arg(command, exe);
  bool valid = true;
  for (size_t i = 0; i < sizeof(args) / sizeof(args[0]); i++) {
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
  return anvil_terminal_host_connect(pipe, *process, *host_pid, shell_pid, id, &size, error);
}
