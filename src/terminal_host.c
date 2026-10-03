#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include "terminal_host.h"
#include "conpty.h"
#include "terminal_model.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#define CLIENT_QUEUE_LIMIT (8u * 1024u * 1024u)
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
  AnvilTerminalReplay replay;
  CRITICAL_SECTION lock;
  CONDITION_VARIABLE ready;
  HostRecord *head, *tail;
  size_t queued;
  bool attached;
  volatile LONG stop, reader_stop, reader_done;
  volatile LONG64 last_output;
  HANDLE reader, writer, client, console_close;
  char log_path[32768];
} TerminalHost;

static wchar_t *wide_string(const char *text);

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

static void stop_host(TerminalHost *host) {
  EnterCriticalSection(&host->lock);
  InterlockedExchange(&host->stop, 1);
  WakeAllConditionVariable(&host->ready);
  LeaveCriticalSection(&host->lock);
  anvil_ipc_pipe_cancel(&host->pipe);
}

/* Caller holds lock. Never let a slow client block ConPTY output. */
static bool queue_record(TerminalHost *host, uint16_t type, const void *bytes, uint32_t length) {
  if (sizeof(HostRecord) + length > CLIENT_QUEUE_LIMIT - host->queued) {
    host_log(host, "failure: client queue full; disconnect");
    stop_host(host);
    return false;
  }
  HostRecord *record = malloc(sizeof(*record) + length);
  if (!record) { stop_host(host); return false; }
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
    /* No write_pty callback: only the editor answers queries. Detached queries
       go unanswered. ConPTY itself answers cursor-position DSR requests. */
    ghostty_terminal_vt_write(host->model, bytes, read);
    bool was_overflow = host->replay.overflow;
    anvil_terminal_replay_append(&host->replay, bytes, read);
    if (!was_overflow && host->replay.overflow)
      host_log(host, "raw replay unavailable: prefix limit exceeded or allocation failed");
    if (host->attached && !InterlockedCompareExchange(&host->stop, 0, 0))
      queue_record(host, ANVIL_TERMINAL_OUTPUT, bytes, read);
    InterlockedExchange64(&host->last_output, GetTickCount64());
    LeaveCriticalSection(&host->lock);
  }
  InterlockedExchange(&host->reader_done, 1);
  return 0;
}

static DWORD WINAPI host_writer(void *userdata) {
  TerminalHost *host = userdata;
  while (!InterlockedCompareExchange(&host->stop, 0, 0)) {
    EnterCriticalSection(&host->lock);
    while (!host->head && !InterlockedCompareExchange(&host->stop, 0, 0))
      SleepConditionVariableCS(&host->ready, &host->lock, INFINITE);
    HostRecord *record = host->head;
    if (record) {
      host->head = record->next; if (!host->head) host->tail = NULL;
      host->queued -= sizeof(*record) + record->length;
    }
    LeaveCriticalSection(&host->lock);
    if (!record) continue;
    bool ok = anvil_ipc_pipe_write(&host->pipe, record->type, record->bytes, record->length, NULL, 0);
    free(record);
    if (!ok) { stop_host(host); break; }
  }
  return 0;
}

static bool apply_size(TerminalHost *host, AnvilTerminalSize size) {
  if (!size.cols || !size.rows || size.cols > 32767 || size.rows > 32767 ||
      !size.cell_width || !size.cell_height) return false;
  if (FAILED(ResizePseudoConsole(host->pty.pseudoconsole, (COORD){size.cols, size.rows}))) return false;
  return ghostty_terminal_resize(host->model, size.cols, size.rows,
    size.cell_width, size.cell_height) == GHOSTTY_SUCCESS;
}

static DWORD WINAPI host_client(void *userdata) {
  TerminalHost *host = userdata;
  AnvilIPCHeader header; uint8_t bytes[ANVIL_TERMINAL_MAX_PAYLOAD];
  while (anvil_ipc_pipe_read(&host->pipe, &header, bytes, sizeof(bytes))) {
    if (header.type == ANVIL_TERMINAL_INPUT && header.size) {
      DWORD offset = 0;
      while (offset < header.size) {
        DWORD written = 0;
        if (!WriteFile(host->pty.input_write, bytes + offset, header.size - offset, &written, NULL) || !written) {
          stop_host(host); break;
        }
        offset += written;
      }
    } else if (header.type == ANVIL_TERMINAL_RESIZE && header.size == sizeof(AnvilTerminalSize)) {
      AnvilTerminalSize size; memcpy(&size, bytes, sizeof(size));
      EnterCriticalSection(&host->lock);
      bool ok = apply_size(host, size);
      LeaveCriticalSection(&host->lock);
      if (!ok) break;
    } else if ((header.type == ANVIL_TERMINAL_CLOSE || header.type == ANVIL_TERMINAL_DETACH) && !header.size) {
      break; /* Milestone 1: DETACH ends the host too. */
    } else break;
  }
  host_log(host, "detach");
  stop_host(host);
  return 0;
}

static DWORD WINAPI close_console(void *userdata) {
  TerminalHost *host = userdata;
  ClosePseudoConsole(host->pty.pseudoconsole);
  return 0;
}

static void join_reader(TerminalHost *host) {
  InterlockedExchange(&host->reader_stop, 1);
  if (!host->reader) return;
  /* Repeat cancellation to cover the gap before a synchronous ReadFile starts. */
  do { CancelSynchronousIo(host->reader); }
  while (WaitForSingleObject(host->reader, 10) == WAIT_TIMEOUT);
}

static bool connect_client(HANDLE pipe, HANDLE parent) {
  OVERLAPPED ov = {0}; ov.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (!ov.hEvent) return false;
  BOOL connected = ConnectNamedPipe(pipe, &ov);
  DWORD error = connected ? ERROR_SUCCESS : GetLastError(), done;
  if (error == ERROR_IO_PENDING) {
    HANDLE events[] = { ov.hEvent, parent };
    DWORD wait = WaitForMultipleObjects(2, events, FALSE, 5000);
    if (wait != WAIT_OBJECT_0) CancelIoEx(pipe, &ov);
    connected = GetOverlappedResult(pipe, &ov, &done, TRUE) && wait == WAIT_OBJECT_0;
  } else connected = connected || error == ERROR_PIPE_CONNECTED;
  CloseHandle(ov.hEvent);
  return connected != FALSE;
}

int anvil_terminal_host_main(int argc, char **argv) {
  if (argc != 13 || strlen(argv[2]) != ANVIL_TERMINAL_ID_LENGTH || strlen(argv[4]) > 32000) return 1;
  TerminalHost host = {0};
  InitializeCriticalSection(&host.lock); InitializeConditionVariable(&host.ready);
  char log_dir[32768]; snprintf(log_dir, sizeof(log_dir), "%s/logs", argv[4]);
  wchar_t *log_dir_wide = wide_string(log_dir);
  if (log_dir_wide) CreateDirectoryW(log_dir_wide, NULL);
  free(log_dir_wide);
  snprintf(host.log_path, sizeof(host.log_path), "%s/logs/terminal-session-%s.log", argv[4], argv[2]);
  host_log(&host, "start");
  BOOL in_job = FALSE;
  if (IsProcessInJob(GetCurrentProcess(), NULL, &in_job) && in_job)
    host_log(&host, "breakaway unavailable: host remains in parent job");
  AnvilTerminalSize size = { (uint16_t)atoi(argv[7]), (uint16_t)atoi(argv[8]),
    (uint32_t)strtoul(argv[9], NULL, 10), (uint32_t)strtoul(argv[10], NULL, 10) };
  size_t lines = (size_t)strtoull(argv[11], NULL, 10);
  DWORD client_pid = strtoul(argv[12], NULL, 10), error = 0, exit_code = 1;
  HANDLE parent = OpenProcess(SYNCHRONIZE, FALSE, client_pid);
  HANDLE handle = CreateNamedPipeA(argv[3], PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED |
    FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT |
    PIPE_REJECT_REMOTE_CLIENTS, 1, 65536, 65536, 0, NULL);
  if (handle == INVALID_HANDLE_VALUE || !parent) goto cleanup;
  if (!anvil_ipc_pipe_init(&host.pipe, handle, ANVIL_TERMINAL_PROTOCOL_VERSION,
                           ANVIL_TERMINAL_MAX_PAYLOAD)) { handle = INVALID_HANDLE_VALUE; goto cleanup; }
  handle = INVALID_HANDLE_VALUE; /* pipe owns it */
  host.pipe.timeout_ms = 5000;
  host.pty.cols = size.cols; host.pty.rows = size.rows;
  if (!size.cols || !size.rows || size.cols > 32767 || size.rows > 32767 ||
      !size.cell_width || !size.cell_height ||
      !anvil_terminal_model_new(&host.model, size.cols, size.rows, size.cell_width,
        size.cell_height, strcmp(argv[11], "-1") == 0 ? NULL : &lines) ||
      !anvil_conpty_start(&host.pty, argv[5], argv[6], &error)) goto cleanup;
  host.reader = CreateThread(NULL, 0, host_reader, &host, 0, NULL);
  if (!host.reader || !connect_client(host.pipe.handle, parent)) goto cleanup;
  ULONG actual_pid = 0;
  if (!GetNamedPipeClientProcessId(host.pipe.handle, &actual_pid) || actual_pid != client_pid) goto cleanup;
  AnvilIPCHeader header; AnvilTerminalHello hello;
  if (!anvil_ipc_pipe_read(&host.pipe, &header, &hello, sizeof(hello)) ||
      header.type != ANVIL_TERMINAL_HELLO || header.size != sizeof(hello) ||
      memcmp(hello.id, argv[2], ANVIL_TERMINAL_ID_LENGTH + 1) != 0) goto cleanup;
  host.pipe.timeout_ms = INFINITE;
  EnterCriticalSection(&host.lock);
  size_t replay_length = host.replay.length;
  bool attached = !host.replay.overflow && apply_size(&host, hello.size);
  if (attached) {
    AnvilTerminalWelcome welcome = { GetCurrentProcessId(), GetProcessId(host.pty.process), 1 };
    attached = queue_record(&host, ANVIL_TERMINAL_WELCOME, &welcome, sizeof(welcome));
    for (size_t offset = 0; attached && offset < host.replay.length;) {
      size_t count = host.replay.length - offset;
      if (count > ANVIL_TERMINAL_MAX_PAYLOAD) count = ANVIL_TERMINAL_MAX_PAYLOAD;
      attached = queue_record(&host, ANVIL_TERMINAL_REPLAY, host.replay.bytes + offset, count);
      offset += count;
    }
    attached = attached && queue_record(&host, ANVIL_TERMINAL_REPLAY_END, NULL, 0);
    host.attached = attached;
  }
  LeaveCriticalSection(&host.lock);
  if (!attached) goto cleanup;
  host_log(&host, "attach client=%lu shell=%lu replay=%zu", (unsigned long)client_pid,
    (unsigned long)GetProcessId(host.pty.process), replay_length);
  host.writer = CreateThread(NULL, 0, host_writer, &host, 0, NULL);
  host.client = CreateThread(NULL, 0, host_client, &host, 0, NULL);
  if (!host.writer || !host.client) goto cleanup;
  uint64_t exited_at = 0, sent_at = 0;
  while (!InterlockedCompareExchange(&host.stop, 0, 0)) {
    uint64_t now = GetTickCount64();
    if (!exited_at && WaitForSingleObject(host.pty.process, 10) == WAIT_OBJECT_0) {
      exited_at = now; GetExitCodeProcess(host.pty.process, &exit_code);
      host.console_close = CreateThread(NULL, 0, close_console, &host, 0, NULL);
      host_log(&host, "shell exit code=%lu; drain", (unsigned long)exit_code);
    }
    if (!exited_at && InterlockedCompareExchange(&host.reader_done, 0, 0)) {
      host_log(&host, "failure: ConPTY output ended while shell was running");
      break;
    }
    if (exited_at && !sent_at) {
      uint64_t last = InterlockedCompareExchange64(&host.last_output, 0, 0);
      if ((now - exited_at >= ANVIL_TERMINAL_DRAIN_QUIET_MS &&
           now - last >= ANVIL_TERMINAL_DRAIN_QUIET_MS && host.reader_done) ||
          now - exited_at >= ANVIL_TERMINAL_DRAIN_MAX_MS) {
        /* Stop and join the reader before EXITED. No later OUTPUT is allowed. */
        join_reader(&host);
        AnvilTerminalExited exited = { exit_code };
        EnterCriticalSection(&host.lock); queue_record(&host, ANVIL_TERMINAL_EXITED, &exited, sizeof(exited));
        LeaveCriticalSection(&host.lock); sent_at = now;
      }
    }
    if (sent_at && now - sent_at > 3000) break;
    if (WaitForSingleObject(parent, 0) == WAIT_OBJECT_0) break;
    if (exited_at) Sleep(10);
  }
cleanup:
  if (!host.attached) host_log(&host, "startup or attach failure Windows error=%lu",
    (unsigned long)(error ? error : GetLastError()));
  host_log(&host, "exit");
  /* Reader keeps draining while ClosePseudoConsole waits for its output sink. */
  anvil_conpty_kill(&host.pty);
  if (host.pty.pseudoconsole && !host.console_close)
    host.console_close = CreateThread(NULL, 0, close_console, &host, 0, NULL);
  if (host.console_close) {
    if (WaitForSingleObject(host.console_close, 5000) == WAIT_TIMEOUT) {
      host_log(&host, "failure: ConPTY close timeout; end host");
      ExitProcess(1);
    }
  }
  stop_host(&host);
  join_reader(&host);
  HANDLE threads[] = { host.reader, host.writer, host.client };
  for (size_t i = 0; i < 3; i++) if (threads[i]) {
    CancelSynchronousIo(threads[i]); WaitForSingleObject(threads[i], INFINITE); CloseHandle(threads[i]);
  }
  if (host.console_close) {
    /* Cancelling the output reader releases a stalled ConPTY close. */
    WaitForSingleObject(host.console_close, INFINITE); CloseHandle(host.console_close);
    host.pty.pseudoconsole = NULL;
  }
  anvil_conpty_close(&host.pty);
  anvil_ipc_pipe_close(&host.pipe);
  if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
  if (parent) CloseHandle(parent);
  while (host.head) { HostRecord *next = host.head->next; free(host.head); host.head = next; }
  anvil_terminal_replay_free(&host.replay);
  if (host.model) ghostty_terminal_free(host.model);
  DeleteCriticalSection(&host.lock);
  return (int)exit_code;
}

static wchar_t *wide_string(const char *text) {
  int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
  wchar_t *wide = count > 0 ? malloc(count * sizeof(wchar_t)) : NULL;
  if (wide) MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, wide, count);
  return wide;
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

bool anvil_terminal_host_launch(AnvilIPCPipe *pipe, HANDLE *process,
                                DWORD *host_pid, DWORD *shell_pid, uint64_t *replay_bytes,
                                const char *userdir, const char *shell, const char *cwd,
                                AnvilTerminalSize size, const size_t *scrollback_lines, DWORD *error) {
  uint8_t random[16]; char id[33], name[128];
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
  char cols[16], rows[16], cw[16], ch[16], lines[32], pid[16];
  snprintf(cols, sizeof(cols), "%u", size.cols); snprintf(rows, sizeof(rows), "%u", size.rows);
  snprintf(cw, sizeof(cw), "%u", size.cell_width); snprintf(ch, sizeof(ch), "%u", size.cell_height);
  if (scrollback_lines) snprintf(lines, sizeof(lines), "%zu", *scrollback_lines); else strcpy(lines, "-1");
  snprintf(pid, sizeof(pid), "%lu", (unsigned long)GetCurrentProcessId());
  const char *args[] = { "--terminal-session", id, name, userdir, shell ? shell : "",
    cwd ? cwd : "", cols, rows, cw, ch, lines, pid };
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
  DWORD launch_error = GetLastError();
  free(first_command);
  if (!created && valid && launch_error == ERROR_ACCESS_DENIED) {
    /* The parent job forbids breakaway. This host ends with that job. */
    created = CreateProcessW(exe, command, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &startup, &info);
    launch_error = GetLastError();
  }
  *error = valid ? launch_error : ERROR_INVALID_PARAMETER; free(command);
  if (!created) return false;
  CloseHandle(info.hThread); *process = info.hProcess; *host_pid = info.dwProcessId;
  uint64_t deadline = GetTickCount64() + 5000;
  HANDLE handle = INVALID_HANDLE_VALUE;
  while (GetTickCount64() < deadline && WaitForSingleObject(*process, 0) == WAIT_TIMEOUT) {
    handle = CreateFileA(name, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING,
      FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, NULL);
    if (handle != INVALID_HANDLE_VALUE) break;
    WaitNamedPipeA(name, 20); Sleep(1);
  }
  if (handle == INVALID_HANDLE_VALUE) { *error = ERROR_PIPE_NOT_CONNECTED; return false; }
  ULONG server = 0;
  if (!GetNamedPipeServerProcessId(handle, &server) || server != *host_pid) {
    CloseHandle(handle); *error = ERROR_ACCESS_DENIED; return false;
  }
  if (!anvil_ipc_pipe_init(pipe, handle, ANVIL_TERMINAL_PROTOCOL_VERSION, ANVIL_TERMINAL_MAX_PAYLOAD)) {
    *error = ERROR_NOT_ENOUGH_MEMORY; return false;
  }
  pipe->timeout_ms = 5000;
  AnvilTerminalHello hello = { .size = size }; memcpy(hello.id, id, sizeof(hello.id));
  if (!anvil_ipc_pipe_write(pipe, ANVIL_TERMINAL_HELLO, &hello, sizeof(hello), NULL, 0)) return false;
  AnvilIPCHeader header; AnvilTerminalWelcome welcome;
  if (!anvil_ipc_pipe_read(pipe, &header, &welcome, sizeof(welcome)) ||
      header.type != ANVIL_TERMINAL_WELCOME || header.size != sizeof(welcome) ||
      welcome.host_pid != *host_pid || !welcome.shell_pid || welcome.state != 1) {
    *error = ERROR_INVALID_DATA; return false;
  }
  *shell_pid = welcome.shell_pid; *replay_bytes = 0;
  pipe->timeout_ms = INFINITE;
  /* Reader thread consumes REPLAY and REPLAY_END before OUTPUT. */
  *error = ERROR_SUCCESS; return true;
}
