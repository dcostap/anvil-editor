#include <SDL3/SDL.h>
#include <stdio.h>
#include <string.h>
#include "ipc_pipe.h"

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); return 1; } } while (0)

static char diagnostic[4096];
static void SDLCALL capture(void *data, int category, SDL_LogPriority priority, const char *message) {
  (void)data; (void)category; (void)priority;
  SDL_strlcpy(diagnostic, message, sizeof(diagnostic));
  /* A log callback must not replace the transport's Windows error. */
  SetLastError(ERROR_ACCESS_DENIED);
}

int main(void) {
  char name[128];
  SDL_snprintf(name, sizeof(name), "\\\\.\\pipe\\anvil-ipc-diagnostics-%lu", GetCurrentProcessId());
  HANDLE server = CreateNamedPipeA(name, PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
    PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT, 1, 4096, 4096, 0, NULL);
  CHECK(server != INVALID_HANDLE_VALUE);
  HANDLE client = CreateFileA(name, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, NULL);
  CHECK(client != INVALID_HANDLE_VALUE);
  CHECK(ConnectNamedPipe(server, NULL) || GetLastError() == ERROR_PIPE_CONNECTED);
  AnvilIPCPipe reader, writer;
  CHECK(anvil_ipc_pipe_init(&reader, server, 1, 1024));
  CHECK(anvil_ipc_pipe_init(&writer, client, 1, 1024));
  SDL_LogOutputFunction old_output;
  void *old_data;
  SDL_GetLogOutputFunction(&old_output, &old_data);
  SDL_SetLogOutputFunction(capture, NULL);

  AnvilIPCHeader invalid = {.version = 2, .type = 42, .size = 0}, header;
  char payload[16];
  reader.timeout_ms = 20;
  CHECK(!anvil_ipc_pipe_read(&reader, &header, payload, sizeof(payload)));
  CHECK(GetLastError() == ERROR_TIMEOUT);
  CHECK(strstr(diagnostic, "operation=read") && strstr(diagnostic, "stage=wait"));
  reader.timeout_ms = INFINITE;

  CHECK(anvil_ipc_pipe_write_records(&writer, &invalid, sizeof(invalid)));
  CHECK(!anvil_ipc_pipe_read(&reader, &header, payload, sizeof(payload)));
  CHECK(GetLastError() == ERROR_INVALID_DATA);
  CHECK(strstr(diagnostic, "invalid-header") && strstr(diagnostic, "type=42"));
  CHECK(strstr(diagnostic, "version=2") && strstr(diagnostic, "expected_version=1"));

  AnvilIPCHeader partial = {.version = 1, .type = 91, .size = 8};
  CHECK(anvil_ipc_pipe_write_records(&writer, &partial, sizeof(partial)));
  CHECK(anvil_ipc_pipe_write_records(&writer, "abc", 3));
  diagnostic[0] = 0;
  anvil_ipc_pipe_close(&writer);
  CHECK(!anvil_ipc_pipe_read(&reader, &header, payload, sizeof(payload)));
  CHECK(GetLastError() == ERROR_BROKEN_PIPE);
  CHECK(strstr(diagnostic, "phase=payload") && strstr(diagnostic, "type=91"));
  CHECK(strstr(diagnostic, "requested=8") && strstr(diagnostic, "completed=3"));

  diagnostic[0] = 0;
  CHECK(!anvil_ipc_pipe_read(&reader, &header, payload, sizeof(payload)));
  CHECK(GetLastError() == ERROR_BROKEN_PIPE);
  CHECK(strstr(diagnostic, "operation=read") && strstr(diagnostic, "phase=header"));
  CHECK(strstr(diagnostic, "server_pid=") && strstr(diagnostic, "client_pid="));

  diagnostic[0] = 0;
  CHECK(!anvil_ipc_pipe_write(&reader, 77, payload, sizeof(payload), NULL, 0));
  CHECK(GetLastError() != ERROR_ACCESS_DENIED && GetLastError() != ERROR_SUCCESS);
  CHECK(strstr(diagnostic, "operation=write") && strstr(diagnostic, "type=77"));

  diagnostic[0] = 0;
  anvil_ipc_pipe_cancel(&reader);
  CHECK(!anvil_ipc_pipe_read(&reader, &header, payload, sizeof(payload)));
  CHECK(GetLastError() == ERROR_OPERATION_ABORTED);
  CHECK(strstr(diagnostic, "stop_requested=1"));
  anvil_ipc_pipe_close(&reader);
  SDL_SetLogOutputFunction(old_output, old_data);
  puts("PASS pipe failures identify reads, writes, invalid headers and cancellation without losing Windows errors");
  return 0;
}
