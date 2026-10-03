#include "ipc_pipe.h"
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
  pipe->stop_event = CreateEventW(NULL, TRUE, FALSE, NULL);
  pipe->read_event = CreateEventW(NULL, TRUE, FALSE, NULL);
  pipe->write_event = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (!pipe->read_event || !pipe->write_event || !pipe->stop_event) {
    anvil_ipc_pipe_close(pipe);
    return false;
  }
  InitializeCriticalSection(&pipe->write_lock);
  pipe->lock_ready = true;
  return true;
}

void anvil_ipc_pipe_cancel(AnvilIPCPipe *pipe) {
  if (pipe->stop_event) SetEvent(pipe->stop_event);
  if (pipe->handle) CancelIoEx(pipe->handle, NULL);
}

void anvil_ipc_pipe_close(AnvilIPCPipe *pipe) {
  if (!pipe) return;
  if (pipe->handle && pipe->handle != INVALID_HANDLE_VALUE) {
    CancelIoEx(pipe->handle, NULL);
    CloseHandle(pipe->handle);
  }
  if (pipe->read_event) CloseHandle(pipe->read_event);
  if (pipe->write_event) CloseHandle(pipe->write_event);
  if (pipe->stop_event) CloseHandle(pipe->stop_event);
  if (pipe->lock_ready) DeleteCriticalSection(&pipe->write_lock);
  memset(pipe, 0, sizeof(*pipe));
}

static bool pipe_transfer(AnvilIPCPipe *pipe, bool write, void *data, DWORD size) {
  uint8_t *cursor = (uint8_t *)data;
  HANDLE event = write ? pipe->write_event : pipe->read_event;
  while (size > 0) {
    if (WaitForSingleObject(pipe->stop_event, 0) == WAIT_OBJECT_0) return false;
    OVERLAPPED overlapped;
    memset(&overlapped, 0, sizeof(overlapped));
    overlapped.hEvent = event;
    ResetEvent(event);
    DWORD done = 0;
    BOOL ok = write
      ? WriteFile(pipe->handle, cursor, size, NULL, &overlapped)
      : ReadFile(pipe->handle, cursor, size, NULL, &overlapped);
    if (!ok && GetLastError() != ERROR_IO_PENDING) return false;
    HANDLE events[] = { pipe->stop_event, event };
    if (WaitForMultipleObjects(2, events, FALSE, pipe->timeout_ms) != WAIT_OBJECT_0 + 1) {
      CancelIoEx(pipe->handle, &overlapped);
      GetOverlappedResult(pipe->handle, &overlapped, &done, TRUE);
      return false;
    }
    if (!GetOverlappedResult(pipe->handle, &overlapped, &done, TRUE)) return false;
    if (done == 0) return false;
    cursor += done;
    size -= done;
  }
  return true;
}

bool anvil_ipc_pipe_read(AnvilIPCPipe *pipe, AnvilIPCHeader *header,
                             void *payload, uint32_t capacity) {
  if (!pipe || !pipe->handle || !header) return false;
  if (!pipe_transfer(pipe, false, header, sizeof(*header))) return false;
  if (header->version != pipe->version || header->size > pipe->max_payload ||
      header->size > capacity) {
    SetLastError(ERROR_INVALID_DATA);
    return false;
  }
  if (header->size == 0) return true;
  return pipe_transfer(pipe, false, payload, header->size);
}

bool anvil_ipc_pipe_write_records(AnvilIPCPipe *pipe, const void *bytes, uint32_t length) {
  EnterCriticalSection(&pipe->write_lock);
  bool ok = pipe_transfer(pipe, true, (void *)bytes, length);
  LeaveCriticalSection(&pipe->write_lock);
  return ok;
}

bool anvil_ipc_pipe_write(AnvilIPCPipe *pipe, uint16_t type,
                              const void *payload, uint32_t size,
                              const void *tail, uint32_t tail_size) {
  if (!pipe || !pipe->handle) return false;
  if (size > pipe->max_payload || tail_size > pipe->max_payload - size) return false;
  uint32_t total = size + tail_size;

  uint8_t stack_buffer[1024];
  size_t record_size = sizeof(AnvilIPCHeader) + total;
  uint8_t *record = record_size <= sizeof(stack_buffer) ? stack_buffer : malloc(record_size);
  if (!record) return false;
  AnvilIPCHeader header = { total, type, pipe->version };
  memcpy(record, &header, sizeof(header));
  if (size) memcpy(record + sizeof(header), payload, size);
  if (tail_size) memcpy(record + sizeof(header) + size, tail, tail_size);

  bool ok = anvil_ipc_pipe_write_records(pipe, record, (DWORD)record_size);
  if (record != stack_buffer) free(record);
  return ok;
}

#endif
