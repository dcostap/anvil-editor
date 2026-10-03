#include "surface_protocol.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char log_role[16];

static void SDLCALL write_surface_log(void *userdata, int category, SDL_LogPriority priority,
                                      const char *message) {
  (void)category;
  (void)priority;
  FILE *file = fopen((const char *)userdata, "ab");
  if (!file) return;
  fprintf(file, "%10.3f %s[%lu] %s\n", (double)SDL_GetTicksNS() / 1e9, log_role,
#ifdef _WIN32
          (unsigned long)GetCurrentProcessId(),
#else
          0ul,
#endif
          message);
  fclose(file);
}

void anvil_surface_log_init(const char *role) {
  const char *path = SDL_getenv("ANVIL_SURFACE_LOG");
  if (!path || !path[0]) return;
  SDL_strlcpy(log_role, role, sizeof(log_role));
  SDL_SetLogOutputFunction(write_surface_log, SDL_strdup(path));
}

#ifdef _WIN32


bool anvil_surface_pipe_init(AnvilSurfacePipe *pipe, HANDLE handle) {
  memset(pipe, 0, sizeof(*pipe));
  pipe->handle = handle;
  pipe->read_event = CreateEventW(NULL, TRUE, FALSE, NULL);
  pipe->write_event = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (!pipe->read_event || !pipe->write_event) {
    anvil_surface_pipe_close(pipe);
    return false;
  }
  InitializeCriticalSection(&pipe->write_lock);
  pipe->lock_ready = true;
  return true;
}

void anvil_surface_pipe_close(AnvilSurfacePipe *pipe) {
  if (!pipe) return;
  if (pipe->handle && pipe->handle != INVALID_HANDLE_VALUE) {
    CancelIoEx(pipe->handle, NULL);
    CloseHandle(pipe->handle);
  }
  if (pipe->read_event) CloseHandle(pipe->read_event);
  if (pipe->write_event) CloseHandle(pipe->write_event);
  if (pipe->lock_ready) DeleteCriticalSection(&pipe->write_lock);
  memset(pipe, 0, sizeof(*pipe));
}

static bool pipe_transfer(AnvilSurfacePipe *pipe, bool write, void *data, DWORD size) {
  uint8_t *cursor = (uint8_t *)data;
  HANDLE event = write ? pipe->write_event : pipe->read_event;
  while (size > 0) {
    OVERLAPPED overlapped;
    memset(&overlapped, 0, sizeof(overlapped));
    overlapped.hEvent = event;
    ResetEvent(event);
    DWORD done = 0;
    BOOL ok = write
      ? WriteFile(pipe->handle, cursor, size, NULL, &overlapped)
      : ReadFile(pipe->handle, cursor, size, NULL, &overlapped);
    if (!ok && GetLastError() != ERROR_IO_PENDING) return false;
    if (!GetOverlappedResult(pipe->handle, &overlapped, &done, TRUE)) return false;
    if (done == 0) return false;
    cursor += done;
    size -= done;
  }
  return true;
}

bool anvil_surface_pipe_read(AnvilSurfacePipe *pipe, AnvilSurfaceHeader *header,
                             void *payload, uint32_t capacity) {
  if (!pipe || !pipe->handle || !header) return false;
  if (!pipe_transfer(pipe, false, header, sizeof(*header))) return false;
  if (header->version != ANVIL_SURFACE_PROTOCOL_VERSION ||
      header->size > ANVIL_SURFACE_MAX_PAYLOAD || header->size > capacity) {
    return false;
  }
  if (header->size == 0) return true;
  return pipe_transfer(pipe, false, payload, header->size);
}

bool anvil_surface_pipe_write(AnvilSurfacePipe *pipe, uint16_t type,
                              const void *payload, uint32_t size,
                              const void *tail, uint32_t tail_size) {
  if (!pipe || !pipe->handle) return false;
  uint32_t total = size + tail_size;
  if (total > ANVIL_SURFACE_MAX_PAYLOAD) return false;

  uint8_t stack_buffer[1024];
  size_t record_size = sizeof(AnvilSurfaceHeader) + total;
  uint8_t *record = record_size <= sizeof(stack_buffer) ? stack_buffer : malloc(record_size);
  if (!record) return false;
  AnvilSurfaceHeader header = { total, type, ANVIL_SURFACE_PROTOCOL_VERSION };
  memcpy(record, &header, sizeof(header));
  if (size) memcpy(record + sizeof(header), payload, size);
  if (tail_size) memcpy(record + sizeof(header) + size, tail, tail_size);

  EnterCriticalSection(&pipe->write_lock);
  bool ok = pipe_transfer(pipe, true, record, (DWORD)record_size);
  LeaveCriticalSection(&pipe->write_lock);
  if (record != stack_buffer) free(record);
  return ok;
}

#endif
