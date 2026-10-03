#ifndef ANVIL_IPC_PIPE_H
#define ANVIL_IPC_PIPE_H
#include <stdbool.h>
#include <stdint.h>

typedef struct {
  uint32_t size;
  uint16_t type;
  uint16_t version;
} AnvilIPCHeader;

#ifdef _WIN32
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <windows.h>
typedef struct {
  HANDLE handle, read_event, write_event, stop_event;
  CRITICAL_SECTION write_lock;
  bool lock_ready;
  uint16_t version;
  uint32_t max_payload;
  DWORD timeout_ms; /* INFINITE after the startup handshake */
} AnvilIPCPipe;

bool anvil_ipc_pipe_init(AnvilIPCPipe *pipe, HANDLE handle, uint16_t version,
                         uint32_t max_payload);
/* Cancel, join all users, then close. One reader and any number of writers. */
void anvil_ipc_pipe_cancel(AnvilIPCPipe *pipe);
void anvil_ipc_pipe_close(AnvilIPCPipe *pipe);
bool anvil_ipc_pipe_read(AnvilIPCPipe *pipe, AnvilIPCHeader *header,
                         void *payload, uint32_t capacity);
/* Flush an ordered byte queue of already framed records. */
bool anvil_ipc_pipe_write_records(AnvilIPCPipe *pipe, const void *bytes, uint32_t length);
bool anvil_ipc_pipe_write(AnvilIPCPipe *pipe, uint16_t type,
                          const void *payload, uint32_t size,
                          const void *tail, uint32_t tail_size);
#endif
#endif
