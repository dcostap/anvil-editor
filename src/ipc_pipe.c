#include "ipc_pipe.h"
#include <SDL3/SDL.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32


bool anvil_ipc_pipe_init(AnvilIPCPipe *pipe, HANDLE handle, uint16_t version,
                          uint32_t max_payload) {
  memset(pipe, 0, sizeof(*pipe));
  pipe->handle = handle;
  pipe->version = version;
  pipe->max_payload = max_payload;
  pipe->timeout_ms = INFINITE;
  DWORD error = ERROR_SUCCESS;
  pipe->stop_event = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (!pipe->stop_event) error = GetLastError();
  pipe->read_event = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (!pipe->read_event && !error) error = GetLastError();
  pipe->write_event = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (!pipe->write_event && !error) error = GetLastError();
  if (!pipe->read_event || !pipe->write_event || !pipe->stop_event) {
    SDL_Log("IPC pipe initialization failed: handle=%p read_event=%d write_event=%d stop_event=%d error=%lu",
            (void *)handle, pipe->read_event != NULL, pipe->write_event != NULL,
            pipe->stop_event != NULL, (unsigned long)error);
    anvil_ipc_pipe_close(pipe);
    SetLastError(error);
    return false;
  }
  InitializeCriticalSection(&pipe->write_lock);
  pipe->lock_ready = true;
  return true;
}

void anvil_ipc_pipe_cancel(AnvilIPCPipe *pipe) {
  SDL_Log("IPC pipe cancel requested: handle=%p", (void *)pipe->handle);
  if (pipe->stop_event) SetEvent(pipe->stop_event);
  if (pipe->handle) CancelIoEx(pipe->handle, NULL);
}

void anvil_ipc_pipe_close(AnvilIPCPipe *pipe) {
  if (!pipe) return;
  if (pipe->handle && pipe->handle != INVALID_HANDLE_VALUE) {
    SDL_Log("IPC pipe close requested: handle=%p", (void *)pipe->handle);
    CancelIoEx(pipe->handle, NULL);
    CloseHandle(pipe->handle);
  }
  if (pipe->read_event) CloseHandle(pipe->read_event);
  if (pipe->write_event) CloseHandle(pipe->write_event);
  if (pipe->stop_event) CloseHandle(pipe->stop_event);
  if (pipe->lock_ready) DeleteCriticalSection(&pipe->write_lock);
  memset(pipe, 0, sizeof(*pipe));
}

/* Read peer IDs only on failure. Never let logging replace the I/O error. */
static bool pipe_failure(AnvilIPCPipe *pipe, bool write, const char *phase, const char *stage,
                         const AnvilIPCHeader *header, DWORD requested, DWORD remaining,
                         DWORD error, DWORD waited) {
  ULONG server = 0, client = 0;
  GetNamedPipeServerProcessId(pipe->handle, &server);
  GetNamedPipeClientProcessId(pipe->handle, &client);
  bool stopped = WaitForSingleObject(pipe->stop_event, 0) == WAIT_OBJECT_0;
  SDL_Log("IPC pipe failure: operation=%s phase=%s stage=%s handle=%p server_pid=%lu client_pid=%lu "
          "error=%lu wait=%lu stop_requested=%d timeout_ms=%lu requested=%lu completed=%lu "
          "header_known=%d type=%u bytes=%lu version=%u expected_version=%u max_payload=%lu",
          write ? "write" : "read", phase, stage, (void *)pipe->handle,
          (unsigned long)server, (unsigned long)client, (unsigned long)error,
          (unsigned long)waited, stopped, (unsigned long)pipe->timeout_ms,
          (unsigned long)requested, (unsigned long)(requested - remaining), header != NULL,
          header ? header->type : 0, (unsigned long)(header ? header->size : 0),
          header ? header->version : 0, pipe->version, (unsigned long)pipe->max_payload);
  SetLastError(error);
  return false;
}

static bool pipe_transfer(AnvilIPCPipe *pipe, bool write, void *data, DWORD size,
                          const char *phase, const AnvilIPCHeader *header) {
  uint8_t *cursor = (uint8_t *)data;
  DWORD requested = size;
  HANDLE event = write ? pipe->write_event : pipe->read_event;
  while (size > 0) {
    if (WaitForSingleObject(pipe->stop_event, 0) == WAIT_OBJECT_0)
      return pipe_failure(pipe, write, phase, "cancelled", header, requested, size,
                          ERROR_OPERATION_ABORTED, WAIT_OBJECT_0);
    OVERLAPPED overlapped;
    memset(&overlapped, 0, sizeof(overlapped));
    overlapped.hEvent = event;
    ResetEvent(event);
    DWORD done = 0;
    BOOL ok = write
      ? WriteFile(pipe->handle, cursor, size, NULL, &overlapped)
      : ReadFile(pipe->handle, cursor, size, NULL, &overlapped);
    DWORD error = ok ? ERROR_SUCCESS : GetLastError();
    if (!ok && error != ERROR_IO_PENDING)
      return pipe_failure(pipe, write, phase, "submit", header, requested, size, error, 0);
    HANDLE events[] = { pipe->stop_event, event };
    DWORD waited = WaitForMultipleObjects(2, events, FALSE, pipe->timeout_ms);
    if (waited != WAIT_OBJECT_0 + 1) {
      error = waited == WAIT_TIMEOUT ? ERROR_TIMEOUT
            : waited == WAIT_OBJECT_0 ? ERROR_OPERATION_ABORTED : GetLastError();
      CancelIoEx(pipe->handle, &overlapped);
      GetOverlappedResult(pipe->handle, &overlapped, &done, TRUE);
      return pipe_failure(pipe, write, phase, "wait", header, requested, size, error, waited);
    }
    if (!GetOverlappedResult(pipe->handle, &overlapped, &done, TRUE)) {
      error = GetLastError();
      return pipe_failure(pipe, write, phase, "complete", header, requested, size, error, waited);
    }
    if (done == 0)
      return pipe_failure(pipe, write, phase, "zero-bytes", header, requested, size,
                          ERROR_BROKEN_PIPE, waited);
    cursor += done;
    size -= done;
  }
  return true;
}

bool anvil_ipc_pipe_read(AnvilIPCPipe *pipe, AnvilIPCHeader *header,
                             void *payload, uint32_t capacity) {
  if (!pipe || !pipe->handle || !header) return false;
  if (!pipe_transfer(pipe, false, header, sizeof(*header), "header", NULL)) return false;
  if (header->version != pipe->version || header->size > pipe->max_payload ||
      header->size > capacity) {
    SDL_Log("IPC invalid-header: handle=%p type=%u bytes=%lu version=%u expected_version=%u "
            "max_payload=%lu capacity=%lu", (void *)pipe->handle, header->type,
            (unsigned long)header->size, header->version, pipe->version,
            (unsigned long)pipe->max_payload, (unsigned long)capacity);
    SetLastError(ERROR_INVALID_DATA);
    return false;
  }
  if (header->size == 0) return true;
  return pipe_transfer(pipe, false, payload, header->size, "payload", header);
}

bool anvil_ipc_pipe_write_records(AnvilIPCPipe *pipe, const void *bytes, uint32_t length) {
  EnterCriticalSection(&pipe->write_lock);
  /* A batch's header describes its first record; completed gives the failure offset. */
  AnvilIPCHeader header;
  bool known = length >= sizeof(header);
  if (known) memcpy(&header, bytes, sizeof(header));
  bool ok = pipe_transfer(pipe, true, (void *)bytes, length, "records", known ? &header : NULL);
  DWORD error = GetLastError();
  LeaveCriticalSection(&pipe->write_lock);
  if (!ok) SetLastError(error);
  return ok;
}

bool anvil_ipc_pipe_write(AnvilIPCPipe *pipe, uint16_t type,
                              const void *payload, uint32_t size,
                              const void *tail, uint32_t tail_size) {
  if (!pipe || !pipe->handle) return false;
  if (size > pipe->max_payload || tail_size > pipe->max_payload - size) {
    SDL_Log("IPC outbound-size rejected: handle=%p type=%u bytes=%lu tail_bytes=%lu max_payload=%lu error=%lu",
            (void *)pipe->handle, type, (unsigned long)size, (unsigned long)tail_size,
            (unsigned long)pipe->max_payload, (unsigned long)ERROR_INVALID_DATA);
    SetLastError(ERROR_INVALID_DATA);
    return false;
  }
  uint32_t total = size + tail_size;

  uint8_t stack_buffer[1024];
  size_t record_size = sizeof(AnvilIPCHeader) + total;
  uint8_t *record = record_size <= sizeof(stack_buffer) ? stack_buffer : malloc(record_size);
  if (!record) {
    SDL_Log("IPC outbound allocation failed: handle=%p type=%u bytes=%llu error=%lu",
            (void *)pipe->handle, type, (unsigned long long)record_size, (unsigned long)ERROR_NOT_ENOUGH_MEMORY);
    SetLastError(ERROR_NOT_ENOUGH_MEMORY);
    return false;
  }
  AnvilIPCHeader header = { total, type, pipe->version };
  memcpy(record, &header, sizeof(header));
  if (size) memcpy(record + sizeof(header), payload, size);
  if (tail_size) memcpy(record + sizeof(header) + size, tail, tail_size);

  bool ok = anvil_ipc_pipe_write_records(pipe, record, (DWORD)record_size);
  DWORD error = GetLastError();
  if (record != stack_buffer) free(record);
  if (!ok) SetLastError(error);
  return ok;
}

#endif
