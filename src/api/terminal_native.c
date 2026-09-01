#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <windows.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <SDL3/SDL_keyboard.h>
#include <SDL3/SDL_scancode.h>
#include <ghostty/vt.h>

#include "api.h"
#include "../custom_events.h"

#define TERMINAL_READ_BUDGET (128u * 1024u)
#define TERMINAL_READ_QUEUE_CAPACITY (4u * 1024u * 1024u)
#define TERMINAL_WRITE_QUEUE_CAPACITY (4u * 1024u * 1024u)
#define TERMINAL_CLIPBOARD_MAX_BYTES (1024u * 1024u)
#define TERMINAL_NOTIFICATION_MAX_BYTES (64u * 1024u)
#define TERMINAL_HYPERLINK_MAX_BYTES (32u * 1024u)
#define TERMINAL_SCROLLBACK_MAX_BYTES (64u * 1024u * 1024u)
#define TERMINAL_DRAIN_QUIET_MS 250u
#define TERMINAL_DRAIN_MAX_MS 5000u
#define TERMINAL_OUTPUT_EVENT "terminaloutput"

static void *terminal_alloc(
  void *ctx, size_t len, uint8_t alignment, uintptr_t ret_addr
) {
  (void)ctx;
  (void)alignment;
  (void)ret_addr;
  return HeapAlloc(GetProcessHeap(), 0, len);
}

static bool terminal_resize(
  void *ctx, void *memory, size_t memory_len, uint8_t alignment,
  size_t new_len, uintptr_t ret_addr
) {
  (void)ctx;
  (void)memory;
  (void)alignment;
  (void)ret_addr;
  return new_len <= memory_len;
}

static void *terminal_remap(
  void *ctx, void *memory, size_t memory_len, uint8_t alignment,
  size_t new_len, uintptr_t ret_addr
) {
  (void)ctx;
  (void)memory_len;
  (void)alignment;
  (void)ret_addr;
  return HeapReAlloc(GetProcessHeap(), 0, memory, new_len);
}

static void terminal_free(
  void *ctx, void *memory, size_t memory_len, uint8_t alignment,
  uintptr_t ret_addr
) {
  (void)ctx;
  (void)memory_len;
  (void)alignment;
  (void)ret_addr;
  if (memory) HeapFree(GetProcessHeap(), 0, memory);
}

static const GhosttyAllocatorVtable terminal_allocator_vtable = {
  .alloc = terminal_alloc,
  .resize = terminal_resize,
  .remap = terminal_remap,
  .free = terminal_free,
};

static const GhosttyAllocator terminal_allocator = {
  .ctx = NULL,
  .vtable = &terminal_allocator_vtable,
};

typedef enum {
  TERMINAL_STATE_NEW,
  TERMINAL_STATE_RUNNING,
  TERMINAL_STATE_DRAINING,
  TERMINAL_STATE_EXITED,
  TERMINAL_STATE_FAILED,
  TERMINAL_STATE_CLOSED,
} TerminalState;

typedef struct {
  HPCON pseudoconsole;
  HANDLE input_write;
  HANDLE output_read;
  HANDLE process;
  HANDLE process_thread;
  HANDLE job;
  HANDLE reader_thread;
  HANDLE writer_thread;
  HANDLE pseudoconsole_close_thread;
  CRITICAL_SECTION read_lock;
  CONDITION_VARIABLE read_ready;
  uint8_t *read_queue;
  size_t read_queue_head;
  size_t read_queue_count;
  volatile LONG closing;
  bool read_lock_initialized;
  CRITICAL_SECTION write_lock;
  CONDITION_VARIABLE write_ready;
  uint8_t *write_queue;
  size_t write_queue_head;
  size_t write_queue_count;
  uint8_t *snapshot_text;
  size_t snapshot_text_capacity;
  HANDLE vt_trace_file;
  uint64_t vt_trace_bytes;
  DWORD vt_trace_error;
  bool write_lock_initialized;
  bool transport_released;
  volatile LONG write_failed;
  volatile LONG read_failed;
  volatile LONG reader_done;
  volatile LONG discard_output;
  volatile LONG output_event_pending;
  DWORD read_error;
  DWORD write_error;
  DWORD exit_code;
  bool exit_code_known;
  bool mouse_button_pressed;
  GhosttyTerminal terminal;
  GhosttyRenderState render_state;
  GhosttyRenderStateRowIterator row_iterator;
  GhosttyRenderStateRowCells row_cells;
  GhosttyKeyEncoder key_encoder;
  GhosttyKeyEvent key_event;
  GhosttyMouseEncoder mouse_encoder;
  GhosttyMouseEvent mouse_event;
  GhosttySelectionGesture selection_gesture;
  GhosttySelectionGestureEvent selection_press;
  GhosttySelectionGestureEvent selection_drag;
  GhosttySelectionGestureEvent selection_release;
  uint16_t cols;
  uint16_t rows;
  uint32_t cell_width;
  uint32_t cell_height;
  GhosttyColorScheme color_scheme;
  bool color_scheme_known;
  bool closed;
  TerminalState state;
  uint64_t state_revision;
  uint64_t process_exit_seen_ms;
  uint64_t drain_empty_seen_ms;
  volatile LONG64 last_output_ms;
  volatile LONG64 output_bytes_read;
  uint64_t output_bytes_parsed;
  uint64_t input_bytes_queued;
  uint64_t read_queue_high_water;
  uint64_t write_queue_high_water;
  uint64_t rejected_writes;
  uint64_t forced_drain_finalizations;
  uint64_t render_generation;
  LONG bell_count;
  char *clipboard_text;
  size_t clipboard_text_length;
  bool clipboard_pending;
  bool clipboard_clear;
  char *notification_title;
  size_t notification_title_length;
  char *notification_body;
  size_t notification_body_length;
  bool notification_pending;
  size_t notification_count;
  char *search_query;
  size_t search_query_length;
  size_t search_row;
  size_t search_col;
  char *search_scan_query;
  size_t search_scan_query_length;
  size_t search_scan_total_rows;
  size_t search_scan_start_row;
  size_t search_scan_step;
  bool search_scan_active;
  bool search_scan_reverse;
  bool search_scan_continuing;
  uint64_t search_scan_generation;
} TerminalSession;

typedef struct {
  bool has_foreground;
  bool has_background;
  bool has_cursor;
  bool has_palette;
  GhosttyColorRgb foreground;
  GhosttyColorRgb background;
  GhosttyColorRgb cursor;
  GhosttyColorRgb palette[16];
} TerminalColors;

static void push_status(lua_State *L, TerminalSession *session);
static void set_integer_field(lua_State *L, const char *name, lua_Integer value);
static void set_boolean_field(lua_State *L, const char *name, bool value);
static uint32_t color_value(GhosttyColorRgb color);

static const char *terminal_state_name(TerminalState state) {
  switch (state) {
    case TERMINAL_STATE_NEW: return "new";
    case TERMINAL_STATE_RUNNING: return "running";
    case TERMINAL_STATE_DRAINING: return "draining";
    case TERMINAL_STATE_EXITED: return "exited";
    case TERMINAL_STATE_FAILED: return "failed";
    case TERMINAL_STATE_CLOSED: return "closed";
  }
  return "failed";
}

static void set_terminal_state(TerminalSession *session, TerminalState state) {
  if (session->state == state) return;
  session->state = state;
  session->state_revision++;
}

static void invalidate_search_scan(TerminalSession *session) {
  session->search_scan_active = false;
}

static bool terminal_is_live(const TerminalSession *session) {
  return session && session->state == TERMINAL_STATE_RUNNING;
}

static bool terminal_model_available(const TerminalSession *session) {
  return session && session->terminal && session->render_state &&
    session->state != TERMINAL_STATE_CLOSED;
}

static void wake_for_terminal_output(TerminalSession *session) {
  if (InterlockedCompareExchange(&session->output_event_pending, 1, 0) != 0) return;
  CustomEvent event = {0};
  if (!push_custom_event(TERMINAL_OUTPUT_EVENT, &event)) {
    InterlockedExchange(&session->output_event_pending, 0);
  }
}

static DWORD WINAPI terminal_reader_main(void *userdata) {
  TerminalSession *session = (TerminalSession *)userdata;
  uint8_t buffer[65536];

  while (InterlockedCompareExchange(&session->closing, 0, 0) == 0) {
    DWORD read = 0;
    BOOL read_ok = ReadFile(session->output_read, buffer, sizeof(buffer), &read, NULL);
    if (!read_ok || read == 0) {
      DWORD error = GetLastError();
      if (InterlockedCompareExchange(&session->closing, 0, 0) == 0 &&
          error != ERROR_BROKEN_PIPE && error != ERROR_PIPE_NOT_CONNECTED) {
        session->read_error = error;
        InterlockedExchange(&session->read_failed, 1);
      }
      break;
    }
    InterlockedExchange64(&session->last_output_ms, (LONG64)GetTickCount64());
    InterlockedAdd64(&session->output_bytes_read, (LONG64)read);

    if (InterlockedCompareExchange(&session->discard_output, 0, 0) != 0) continue;

    size_t offset = 0;
    EnterCriticalSection(&session->read_lock);
    bool queue_was_empty = session->read_queue_count == 0;
    while (offset < read && InterlockedCompareExchange(&session->closing, 0, 0) == 0) {
      while (session->read_queue_count == TERMINAL_READ_QUEUE_CAPACITY &&
             InterlockedCompareExchange(&session->closing, 0, 0) == 0 &&
             InterlockedCompareExchange(&session->discard_output, 0, 0) == 0) {
        SleepConditionVariableCS(&session->read_ready, &session->read_lock, INFINITE);
      }
      if (InterlockedCompareExchange(&session->discard_output, 0, 0) != 0) {
        offset = read;
        break;
      }
      if (InterlockedCompareExchange(&session->closing, 0, 0) != 0) break;

      size_t tail = (session->read_queue_head + session->read_queue_count) %
        TERMINAL_READ_QUEUE_CAPACITY;
      size_t available = TERMINAL_READ_QUEUE_CAPACITY - session->read_queue_count;
      size_t contiguous = TERMINAL_READ_QUEUE_CAPACITY - tail;
      size_t amount = read - offset;
      if (amount > available) amount = available;
      if (amount > contiguous) amount = contiguous;
      memcpy(session->read_queue + tail, buffer + offset, amount);
      session->read_queue_count += amount;
      if (session->read_queue_count > session->read_queue_high_water) {
        session->read_queue_high_water = session->read_queue_count;
      }
      offset += amount;
    }
    LeaveCriticalSection(&session->read_lock);
    if (queue_was_empty && offset > 0) wake_for_terminal_output(session);
  }
  InterlockedExchange(&session->reader_done, 1);
  wake_for_terminal_output(session);
  return 0;
}

static DWORD WINAPI terminal_pseudoconsole_close_main(void *userdata) {
  TerminalSession *session = (TerminalSession *)userdata;
  HPCON pseudoconsole = (HPCON)InterlockedExchangePointer(
    (PVOID volatile *)&session->pseudoconsole, NULL
  );
  if (pseudoconsole) ClosePseudoConsole(pseudoconsole);
  wake_for_terminal_output(session);
  return 0;
}

static void start_pseudoconsole_close(TerminalSession *session) {
  if (!session->pseudoconsole || session->pseudoconsole_close_thread) return;
  session->pseudoconsole_close_thread = CreateThread(
    NULL, 0, terminal_pseudoconsole_close_main, session, 0, NULL
  );
}

static DWORD WINAPI terminal_writer_main(void *userdata) {
  TerminalSession *session = (TerminalSession *)userdata;
  uint8_t buffer[65536];

  while (InterlockedCompareExchange(&session->closing, 0, 0) == 0) {
    size_t amount = 0;
    EnterCriticalSection(&session->write_lock);
    while (session->write_queue_count == 0 &&
           InterlockedCompareExchange(&session->closing, 0, 0) == 0) {
      SleepConditionVariableCS(&session->write_ready, &session->write_lock, INFINITE);
    }
    if (session->write_queue_count > 0) {
      amount = session->write_queue_count;
      if (amount > sizeof(buffer)) amount = sizeof(buffer);
      size_t contiguous = TERMINAL_WRITE_QUEUE_CAPACITY - session->write_queue_head;
      if (amount > contiguous) amount = contiguous;
      memcpy(buffer, session->write_queue + session->write_queue_head, amount);
      session->write_queue_head = (session->write_queue_head + amount) %
        TERMINAL_WRITE_QUEUE_CAPACITY;
      session->write_queue_count -= amount;
    }
    LeaveCriticalSection(&session->write_lock);
    if (amount == 0) continue;

    size_t offset = 0;
    while (offset < amount && InterlockedCompareExchange(&session->closing, 0, 0) == 0) {
      DWORD written = 0;
      if (!WriteFile(
        session->input_write, buffer + offset, (DWORD)(amount - offset), &written, NULL
      ) || written == 0) {
        DWORD error = GetLastError();
        EnterCriticalSection(&session->write_lock);
        if (InterlockedCompareExchange(&session->closing, 0, 0) == 0 &&
            error != ERROR_OPERATION_ABORTED && error != ERROR_BROKEN_PIPE &&
            error != ERROR_PIPE_NOT_CONNECTED) {
          session->write_error = error;
          InterlockedExchange(&session->write_failed, 1);
        }
        LeaveCriticalSection(&session->write_lock);
        return 0;
      }
      offset += written;
    }
  }
  return 0;
}

static bool start_terminal_io(TerminalSession *session) {
  session->read_queue = (uint8_t *)HeapAlloc(
    GetProcessHeap(), 0, TERMINAL_READ_QUEUE_CAPACITY
  );
  session->write_queue = (uint8_t *)HeapAlloc(
    GetProcessHeap(), 0, TERMINAL_WRITE_QUEUE_CAPACITY
  );
  if (!session->read_queue || !session->write_queue) return false;
  InitializeCriticalSection(&session->read_lock);
  session->read_lock_initialized = true;
  InitializeConditionVariable(&session->read_ready);
  InitializeCriticalSection(&session->write_lock);
  session->write_lock_initialized = true;
  InitializeConditionVariable(&session->write_ready);
  session->reader_thread = CreateThread(NULL, 0, terminal_reader_main, session, 0, NULL);
  session->writer_thread = CreateThread(NULL, 0, terminal_writer_main, session, 0, NULL);
  return session->reader_thread != NULL && session->writer_thread != NULL;
}

static TerminalSession *check_session(lua_State *L, int index) {
  return (TerminalSession *)luaL_checkudata(L, index, API_TYPE_TERMINAL_SESSION);
}

static void close_handle(HANDLE *handle) {
  if (*handle && *handle != INVALID_HANDLE_VALUE) {
    CloseHandle(*handle);
    *handle = NULL;
  }
}

static wchar_t *utf8_to_wide(const char *text) {
  if (!text) return NULL;
  int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
  if (count <= 0) return NULL;
  wchar_t *wide = (wchar_t *)HeapAlloc(GetProcessHeap(), 0, (size_t)count * sizeof(wchar_t));
  if (!wide) return NULL;
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, wide, count)) {
    HeapFree(GetProcessHeap(), 0, wide);
    return NULL;
  }
  return wide;
}

static void push_windows_error(lua_State *L, const char *prefix, DWORD code) {
  char *message = NULL;
  FormatMessageA(
    FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
      FORMAT_MESSAGE_IGNORE_INSERTS,
    NULL, code, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
    (char *)&message, 0, NULL
  );
  if (message) {
    size_t length = strlen(message);
    while (length > 0 && (message[length - 1] == '\r' || message[length - 1] == '\n')) {
      message[--length] = '\0';
    }
    lua_pushfstring(L, "%s: %s", prefix, message);
    LocalFree(message);
  } else {
    lua_pushfstring(L, "%s: Windows error %d", prefix, (int)code);
  }
}

static bool write_all(TerminalSession *session, const uint8_t *data, size_t length) {
  if (!terminal_is_live(session) || session->closed || !session->input_write ||
      !session->write_lock_initialized) {
    return false;
  }
  if (length > TERMINAL_WRITE_QUEUE_CAPACITY) {
    session->rejected_writes++;
    return false;
  }
  EnterCriticalSection(&session->write_lock);
  if (InterlockedCompareExchange(&session->write_failed, 0, 0) != 0 ||
      InterlockedCompareExchange(&session->closing, 0, 0) != 0 ||
      !session->input_write) {
    LeaveCriticalSection(&session->write_lock);
    return false;
  }
  if (length > TERMINAL_WRITE_QUEUE_CAPACITY - session->write_queue_count) {
    session->rejected_writes++;
    LeaveCriticalSection(&session->write_lock);
    return false;
  }
  size_t offset = 0;
  while (offset < length) {
    size_t tail = (session->write_queue_head + session->write_queue_count) %
      TERMINAL_WRITE_QUEUE_CAPACITY;
    size_t contiguous = TERMINAL_WRITE_QUEUE_CAPACITY - tail;
    size_t amount = length - offset;
    if (amount > contiguous) amount = contiguous;
    memcpy(session->write_queue + tail, data + offset, amount);
    session->write_queue_count += amount;
    if (session->write_queue_count > session->write_queue_high_water) {
      session->write_queue_high_water = session->write_queue_count;
    }
    offset += amount;
  }
  session->input_bytes_queued += length;
  WakeConditionVariable(&session->write_ready);
  LeaveCriticalSection(&session->write_lock);
  return true;
}

static void terminal_write_pty(
  GhosttyTerminal terminal, void *userdata, const uint8_t *data, size_t length
) {
  (void)terminal;
  write_all((TerminalSession *)userdata, data, length);
}

static void terminal_bell(GhosttyTerminal terminal, void *userdata) {
  (void)terminal;
  TerminalSession *session = (TerminalSession *)userdata;
  session->bell_count++;
}

static GhosttyClipboardWriteResult terminal_clipboard_write(
  GhosttyTerminal terminal, void *userdata, const GhosttyClipboardWrite *write
) {
  (void)terminal;
  TerminalSession *session = (TerminalSession *)userdata;
  if (!write || write->location != GHOSTTY_CLIPBOARD_LOCATION_STANDARD) {
    return GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED;
  }
  if (write->contents_len == 0) {
    if (session->clipboard_text) HeapFree(GetProcessHeap(), 0, session->clipboard_text);
    session->clipboard_text = NULL;
    session->clipboard_text_length = 0;
    session->clipboard_clear = true;
    session->clipboard_pending = true;
    return GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS;
  }
  const GhosttyClipboardContent *plain = NULL;
  for (size_t index = 0; index < write->contents_len; index++) {
    GhosttyString mime = write->contents[index].mime;
    if (mime.len == 10 && memcmp(mime.ptr, "text/plain", 10) == 0) {
      plain = &write->contents[index];
      break;
    }
  }
  if (!plain) return GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED;
  if (plain->data.len > TERMINAL_CLIPBOARD_MAX_BYTES) {
    return GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED;
  }
  char *text = (char *)HeapAlloc(
    GetProcessHeap(), 0, plain->data.len ? plain->data.len : 1
  );
  if (!text) return GHOSTTY_CLIPBOARD_WRITE_RESULT_IO_ERROR;
  if (plain->data.len) memcpy(text, plain->data.ptr, plain->data.len);
  if (session->clipboard_text) HeapFree(GetProcessHeap(), 0, session->clipboard_text);
  session->clipboard_text = text;
  session->clipboard_text_length = plain->data.len;
  session->clipboard_clear = false;
  session->clipboard_pending = true;
  return GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS;
}

static void terminal_desktop_notification(
  GhosttyTerminal terminal, void *userdata,
  const GhosttyTerminalDesktopNotification *notification
) {
  (void)terminal;
  TerminalSession *session = (TerminalSession *)userdata;
  if (!notification || notification->size <
        offsetof(GhosttyTerminalDesktopNotification, body) + sizeof(notification->body) ||
      notification->title.len > TERMINAL_NOTIFICATION_MAX_BYTES ||
      notification->body.len > TERMINAL_NOTIFICATION_MAX_BYTES) return;
  char *title = (char *)HeapAlloc(
    GetProcessHeap(), 0, notification->title.len ? notification->title.len : 1
  );
  char *body = (char *)HeapAlloc(
    GetProcessHeap(), 0, notification->body.len ? notification->body.len : 1
  );
  if (!title || !body) {
    if (title) HeapFree(GetProcessHeap(), 0, title);
    if (body) HeapFree(GetProcessHeap(), 0, body);
    return;
  }
  if (notification->title.len) {
    memcpy(title, notification->title.ptr, notification->title.len);
  }
  if (notification->body.len) memcpy(body, notification->body.ptr, notification->body.len);
  if (session->notification_title) {
    HeapFree(GetProcessHeap(), 0, session->notification_title);
  }
  if (session->notification_body) HeapFree(GetProcessHeap(), 0, session->notification_body);
  session->notification_title = title;
  session->notification_title_length = notification->title.len;
  session->notification_body = body;
  session->notification_body_length = notification->body.len;
  session->notification_pending = true;
  session->notification_count++;
}

static bool terminal_size(
  GhosttyTerminal terminal, void *userdata, GhosttySizeReportSize *out_size
) {
  (void)terminal;
  TerminalSession *session = (TerminalSession *)userdata;
  if (!session || !out_size) return false;
  out_size->rows = session->rows;
  out_size->columns = session->cols;
  out_size->cell_width = session->cell_width;
  out_size->cell_height = session->cell_height;
  return true;
}

static bool terminal_color_scheme(
  GhosttyTerminal terminal, void *userdata, GhosttyColorScheme *out_scheme
) {
  (void)terminal;
  TerminalSession *session = (TerminalSession *)userdata;
  if (!session || !session->color_scheme_known || !out_scheme) return false;
  *out_scheme = session->color_scheme;
  return true;
}

static GhosttyString terminal_version(GhosttyTerminal terminal, void *userdata) {
  (void)terminal;
  (void)userdata;
  static const uint8_t version[] = "Anvil Terminal";
  return (GhosttyString){ .ptr = version, .len = sizeof(version) - 1 };
}

static bool terminal_device_attributes(
  GhosttyTerminal terminal, void *userdata, GhosttyDeviceAttributes *out_attributes
) {
  (void)terminal;
  (void)userdata;
  if (!out_attributes) return false;
  out_attributes->primary.conformance_level = GHOSTTY_DA_CONFORMANCE_VT220;
  out_attributes->primary.features[0] = GHOSTTY_DA_FEATURE_COLUMNS_132;
  out_attributes->primary.features[1] = GHOSTTY_DA_FEATURE_SELECTIVE_ERASE;
  out_attributes->primary.features[2] = GHOSTTY_DA_FEATURE_ANSI_COLOR;
  out_attributes->primary.num_features = 3;
  out_attributes->secondary.device_type = GHOSTTY_DA_DEVICE_TYPE_VT220;
  out_attributes->secondary.firmware_version = 1;
  out_attributes->secondary.rom_cartridge = 0;
  out_attributes->tertiary.unit_id = 0;
  return true;
}

static void free_terminal_objects(TerminalSession *session) {
  if (session->selection_release) {
    ghostty_selection_gesture_event_free(session->selection_release);
    session->selection_release = NULL;
  }
  if (session->selection_drag) {
    ghostty_selection_gesture_event_free(session->selection_drag);
    session->selection_drag = NULL;
  }
  if (session->selection_press) {
    ghostty_selection_gesture_event_free(session->selection_press);
    session->selection_press = NULL;
  }
  if (session->selection_gesture) {
    ghostty_selection_gesture_free(session->selection_gesture, session->terminal);
    session->selection_gesture = NULL;
  }
  if (session->mouse_event) {
    ghostty_mouse_event_free(session->mouse_event);
    session->mouse_event = NULL;
  }
  if (session->mouse_encoder) {
    ghostty_mouse_encoder_free(session->mouse_encoder);
    session->mouse_encoder = NULL;
  }
  if (session->key_event) {
    ghostty_key_event_free(session->key_event);
    session->key_event = NULL;
  }
  if (session->key_encoder) {
    ghostty_key_encoder_free(session->key_encoder);
    session->key_encoder = NULL;
  }
  if (session->row_cells) {
    ghostty_render_state_row_cells_free(session->row_cells);
    session->row_cells = NULL;
  }
  if (session->row_iterator) {
    ghostty_render_state_row_iterator_free(session->row_iterator);
    session->row_iterator = NULL;
  }
  if (session->render_state) {
    ghostty_render_state_free(session->render_state);
    session->render_state = NULL;
  }
  if (session->terminal) {
    ghostty_terminal_free(session->terminal);
    session->terminal = NULL;
  }
}

static void release_terminal_transport(TerminalSession *session) {
  if (!session || session->transport_released) return;
  session->transport_released = true;
  if (session->pseudoconsole_close_thread) {
    InterlockedExchange(&session->discard_output, 1);
    if (session->read_lock_initialized) {
      EnterCriticalSection(&session->read_lock);
      session->read_queue_count = 0;
      session->read_queue_head = 0;
      WakeAllConditionVariable(&session->read_ready);
      LeaveCriticalSection(&session->read_lock);
    }
    WaitForSingleObject(session->pseudoconsole_close_thread, INFINITE);
    close_handle(&session->pseudoconsole_close_thread);
  }
  InterlockedExchange(&session->closing, 1);
  if (session->read_lock_initialized) {
    EnterCriticalSection(&session->read_lock);
    WakeAllConditionVariable(&session->read_ready);
    LeaveCriticalSection(&session->read_lock);
  }
  if (session->write_lock_initialized) {
    EnterCriticalSection(&session->write_lock);
    WakeAllConditionVariable(&session->write_ready);
    LeaveCriticalSection(&session->write_lock);
  }
  if (session->reader_thread) CancelSynchronousIo(session->reader_thread);
  if (session->writer_thread) CancelSynchronousIo(session->writer_thread);
  if (session->reader_thread) {
    WaitForSingleObject(session->reader_thread, INFINITE);
    close_handle(&session->reader_thread);
  }
  if (session->writer_thread) {
    WaitForSingleObject(session->writer_thread, INFINITE);
    close_handle(&session->writer_thread);
  }
  close_handle(&session->input_write);
  close_handle(&session->output_read);
  if (session->pseudoconsole) {
    ClosePseudoConsole(session->pseudoconsole);
    session->pseudoconsole = NULL;
  }
  if (session->read_lock_initialized) {
    DeleteCriticalSection(&session->read_lock);
    session->read_lock_initialized = false;
  }
  if (session->read_queue) {
    HeapFree(GetProcessHeap(), 0, session->read_queue);
    session->read_queue = NULL;
  }
  if (session->write_lock_initialized) {
    DeleteCriticalSection(&session->write_lock);
    session->write_lock_initialized = false;
  }
  if (session->write_queue) {
    HeapFree(GetProcessHeap(), 0, session->write_queue);
    session->write_queue = NULL;
  }
}

static void terminate_terminal_process(TerminalSession *session) {
  if (session->job) {
    close_handle(&session->job);
  } else if (session->process) {
    DWORD exit_code = 0;
    if (GetExitCodeProcess(session->process, &exit_code) && exit_code == STILL_ACTIVE) {
      TerminateProcess(session->process, 1);
    }
  }
  close_handle(&session->process_thread);
  close_handle(&session->process);
}

static void close_session(TerminalSession *session) {
  if (!session || session->closed) return;
  session->closed = true;
  set_terminal_state(session, TERMINAL_STATE_CLOSED);
  if (session->vt_trace_file) {
    FlushFileBuffers(session->vt_trace_file);
    close_handle(&session->vt_trace_file);
  }
  terminate_terminal_process(session);
  release_terminal_transport(session);
  free_terminal_objects(session);
  if (session->snapshot_text) {
    HeapFree(GetProcessHeap(), 0, session->snapshot_text);
    session->snapshot_text = NULL;
    session->snapshot_text_capacity = 0;
  }
  if (session->search_query) {
    HeapFree(GetProcessHeap(), 0, session->search_query);
    session->search_query = NULL;
  }
  if (session->search_scan_query) {
    HeapFree(GetProcessHeap(), 0, session->search_scan_query);
    session->search_scan_query = NULL;
  }
  if (session->clipboard_text) {
    HeapFree(GetProcessHeap(), 0, session->clipboard_text);
    session->clipboard_text = NULL;
  }
  if (session->notification_title) {
    HeapFree(GetProcessHeap(), 0, session->notification_title);
    session->notification_title = NULL;
  }
  if (session->notification_body) {
    HeapFree(GetProcessHeap(), 0, session->notification_body);
    session->notification_body = NULL;
  }
}

static bool set_terminal_colors(TerminalSession *session, const TerminalColors *colors) {
  if (colors->has_foreground && ghostty_terminal_set(
      session->terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &colors->foreground
    ) != GHOSTTY_SUCCESS) return false;
  if (colors->has_background && ghostty_terminal_set(
      session->terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &colors->background
    ) != GHOSTTY_SUCCESS) return false;
  if (colors->has_background) {
    unsigned int brightness = 299u * colors->background.r +
      587u * colors->background.g + 114u * colors->background.b;
    session->color_scheme = brightness >= 128000u ?
      GHOSTTY_COLOR_SCHEME_LIGHT : GHOSTTY_COLOR_SCHEME_DARK;
    session->color_scheme_known = true;
  }
  if (colors->has_cursor && ghostty_terminal_set(
      session->terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &colors->cursor
    ) != GHOSTTY_SUCCESS) return false;
  if (colors->has_palette) {
    GhosttyColorRgb palette[256];
    ghostty_color_palette_default(palette);
    memcpy(palette, colors->palette, sizeof(colors->palette));
    if (ghostty_terminal_set(
        session->terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, palette
      ) != GHOSTTY_SUCCESS) return false;
  }
  return true;
}

static bool initialize_terminal(
  TerminalSession *session, const TerminalColors *colors,
  const size_t *scrollback_max_lines
) {
  if (ghostty_terminal_new(
    &terminal_allocator, &session->terminal, session->cols, session->rows
  ) != GHOSTTY_SUCCESS) {
    return false;
  }
  size_t scrollback_max_bytes = TERMINAL_SCROLLBACK_MAX_BYTES;
  if (scrollback_max_lines && (
      ghostty_terminal_set(
        session->terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES,
        &scrollback_max_bytes
      ) != GHOSTTY_SUCCESS ||
      ghostty_terminal_set(
        session->terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES,
        scrollback_max_lines
      ) != GHOSTTY_SUCCESS
    )) return false;
  if (ghostty_render_state_new(
    &terminal_allocator, &session->render_state
  ) != GHOSTTY_SUCCESS) return false;
  if (ghostty_render_state_row_iterator_new(
    &terminal_allocator, &session->row_iterator
  ) != GHOSTTY_SUCCESS) return false;
  if (ghostty_render_state_row_cells_new(
    &terminal_allocator, &session->row_cells
  ) != GHOSTTY_SUCCESS) return false;
  if (ghostty_key_encoder_new(
    &terminal_allocator, &session->key_encoder
  ) != GHOSTTY_SUCCESS) return false;
  if (ghostty_key_event_new(
    &terminal_allocator, &session->key_event
  ) != GHOSTTY_SUCCESS) return false;
  if (ghostty_mouse_encoder_new(
    &terminal_allocator, &session->mouse_encoder
  ) != GHOSTTY_SUCCESS) return false;
  if (ghostty_mouse_event_new(
    &terminal_allocator, &session->mouse_event
  ) != GHOSTTY_SUCCESS) return false;
  if (ghostty_selection_gesture_new(
    &terminal_allocator, &session->selection_gesture
  ) != GHOSTTY_SUCCESS) return false;
  if (ghostty_selection_gesture_event_new(
    &terminal_allocator, &session->selection_press,
    GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS
  ) != GHOSTTY_SUCCESS) return false;
  if (ghostty_selection_gesture_event_new(
    &terminal_allocator, &session->selection_drag,
    GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG
  ) != GHOSTTY_SUCCESS) return false;
  if (ghostty_selection_gesture_event_new(
    &terminal_allocator, &session->selection_release,
    GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE
  ) != GHOSTTY_SUCCESS) return false;

  ghostty_terminal_set(session->terminal, GHOSTTY_TERMINAL_OPT_USERDATA, session);
  ghostty_terminal_set(
    session->terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, (const void *)terminal_write_pty
  );
  ghostty_terminal_set(
    session->terminal, GHOSTTY_TERMINAL_OPT_SIZE, (const void *)terminal_size
  );
  ghostty_terminal_set(
    session->terminal, GHOSTTY_TERMINAL_OPT_COLOR_SCHEME,
    (const void *)terminal_color_scheme
  );
  ghostty_terminal_set(
    session->terminal, GHOSTTY_TERMINAL_OPT_XTVERSION, (const void *)terminal_version
  );
  ghostty_terminal_set(
    session->terminal, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES,
    (const void *)terminal_device_attributes
  );
  ghostty_terminal_set(
    session->terminal, GHOSTTY_TERMINAL_OPT_BELL, (const void *)terminal_bell
  );
  ghostty_terminal_set(
    session->terminal, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE,
    (const void *)terminal_clipboard_write
  );
  ghostty_terminal_set(
    session->terminal, GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION,
    (const void *)terminal_desktop_notification
  );
  /*
   * Pi emits OSC 133 A inside synchronized repaints as a zero-width zone marker.
   * Ghostty gives A its specified fresh-line action. Pi does not track that move.
   * A later Pi erase can therefore remove a user message from Ghostty's model.
   * Suppress the move only during synchronized output. Keep normal shell behavior.
   * See tests/fixtures/terminal_semantic_prompt_repaint.ps1 and Pi issue #2971.
   */
  bool semantic_prompt_fresh_line_in_synchronized_output = false;
  if (ghostty_terminal_set(
      session->terminal,
      GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT_FRESH_LINE_IN_SYNCHRONIZED_OUTPUT,
      &semantic_prompt_fresh_line_in_synchronized_output
    ) != GHOSTTY_SUCCESS) return false;
  if (!set_terminal_colors(session, colors)) return false;
  ghostty_terminal_resize(
    session->terminal, session->cols, session->rows,
    session->cell_width, session->cell_height
  );
  return ghostty_render_state_update(session->render_state, session->terminal) == GHOSTTY_SUCCESS;
}

static GhosttyColorRgb unpack_color(lua_Integer value) {
  uint32_t color = (uint32_t)value;
  return (GhosttyColorRgb) {
    .r = (uint8_t)(color >> 16),
    .g = (uint8_t)(color >> 8),
    .b = (uint8_t)color,
  };
}

static bool read_color_field(
  lua_State *L, int table_index, const char *name, GhosttyColorRgb *color
) {
  lua_getfield(L, table_index, name);
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    return false;
  }
  lua_Integer value = luaL_checkinteger(L, -1);
  luaL_argcheck(
    L, value >= 0 && value <= 0xffffff, table_index, "terminal color is out of range"
  );
  *color = unpack_color(value);
  lua_pop(L, 1);
  return true;
}

static TerminalColors read_terminal_colors(lua_State *L, int table_index) {
  TerminalColors colors = {0};
  colors.has_foreground = read_color_field(L, table_index, "foreground", &colors.foreground);
  colors.has_background = read_color_field(L, table_index, "background", &colors.background);
  colors.has_cursor = read_color_field(L, table_index, "cursor_color", &colors.cursor);

  lua_getfield(L, table_index, "palette");
  if (!lua_isnil(L, -1)) {
    luaL_checktype(L, -1, LUA_TTABLE);
    luaL_argcheck(
      L, lua_rawlen(L, -1) == 16, table_index, "terminal palette must have 16 colors"
    );
    for (int index = 0; index < 16; index++) {
      lua_rawgeti(L, -1, index + 1);
      lua_Integer value = luaL_checkinteger(L, -1);
      luaL_argcheck(
        L, value >= 0 && value <= 0xffffff, table_index, "terminal color is out of range"
      );
      colors.palette[index] = unpack_color(value);
      lua_pop(L, 1);
    }
    colors.has_palette = true;
  }
  lua_pop(L, 1);
  return colors;
}

static int f_terminal_set_colors(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  luaL_checktype(L, 2, LUA_TTABLE);
  TerminalColors colors = read_terminal_colors(L, 2);
  bool ok = terminal_model_available(session) && set_terminal_colors(session, &colors) &&
    ghostty_render_state_update(session->render_state, session->terminal) == GHOSTTY_SUCCESS;
  lua_pushboolean(L, ok);
  return 1;
}

static bool create_kill_job(TerminalSession *session) {
  session->job = CreateJobObjectW(NULL, NULL);
  if (!session->job) return false;

  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
  memset(&limits, 0, sizeof(limits));
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(
    session->job, JobObjectExtendedLimitInformation, &limits, sizeof(limits)
  )) {
    close_handle(&session->job);
    return false;
  }
  if (!AssignProcessToJobObject(session->job, session->process)) {
    close_handle(&session->job);
    return false;
  }
  return true;
}

#ifndef ANVIL_PROJECT_VERSION_STR
#define ANVIL_PROJECT_VERSION_STR "unknown"
#endif

static bool environment_entry_has_key(const wchar_t *entry, const wchar_t *key) {
  size_t length = wcslen(key);
  return _wcsnicmp(entry, key, length) == 0 && entry[length] == L'=';
}

static wchar_t *terminal_environment(void) {
  LPWCH inherited = GetEnvironmentStringsW();
  if (!inherited) return NULL;
  static const wchar_t *keys[] = {
    L"TERM_PROGRAM", L"TERM_PROGRAM_VERSION", L"TERM", L"COLORTERM",
  };
  static const wchar_t *fixed_prefixes[] = {
    L"TERM_PROGRAM=anvil", L"TERM_PROGRAM_VERSION=", L"TERM=xterm-256color",
    L"COLORTERM=truecolor",
  };
  wchar_t *version = utf8_to_wide(ANVIL_PROJECT_VERSION_STR);
  if (!version) {
    FreeEnvironmentStringsW(inherited);
    return NULL;
  }
  size_t chars = 2;
  for (const wchar_t *entry = inherited; *entry; entry += wcslen(entry) + 1) {
    bool replace = false;
    for (size_t index = 0; index < 4; index++) {
      if (environment_entry_has_key(entry, keys[index])) { replace = true; break; }
    }
    if (!replace) chars += wcslen(entry) + 1;
  }
  chars += wcslen(fixed_prefixes[0]) + 1;
  chars += wcslen(fixed_prefixes[1]) + wcslen(version) + 1;
  chars += wcslen(fixed_prefixes[2]) + 1;
  chars += wcslen(fixed_prefixes[3]) + 1;
  wchar_t *block = (wchar_t *)HeapAlloc(GetProcessHeap(), 0, chars * sizeof(wchar_t));
  if (!block) {
    HeapFree(GetProcessHeap(), 0, version);
    FreeEnvironmentStringsW(inherited);
    return NULL;
  }
  wchar_t *out = block;
  for (const wchar_t *entry = inherited; *entry; entry += wcslen(entry) + 1) {
    bool replace = false;
    for (size_t index = 0; index < 4; index++) {
      if (environment_entry_has_key(entry, keys[index])) { replace = true; break; }
    }
    if (replace) continue;
    size_t length = wcslen(entry) + 1;
    memcpy(out, entry, length * sizeof(wchar_t));
    out += length;
  }
  size_t length = wcslen(fixed_prefixes[0]) + 1;
  memcpy(out, fixed_prefixes[0], length * sizeof(wchar_t)); out += length;
  length = wcslen(fixed_prefixes[1]);
  memcpy(out, fixed_prefixes[1], length * sizeof(wchar_t)); out += length;
  length = wcslen(version);
  memcpy(out, version, length * sizeof(wchar_t)); out += length; *out++ = L'\0';
  for (size_t index = 2; index < 4; index++) {
    length = wcslen(fixed_prefixes[index]) + 1;
    memcpy(out, fixed_prefixes[index], length * sizeof(wchar_t)); out += length;
  }
  *out = L'\0';
  HeapFree(GetProcessHeap(), 0, version);
  FreeEnvironmentStringsW(inherited);
  return block;
}

static bool create_shell_process(
  TerminalSession *session, const char *command_utf8, const char *cwd_utf8, DWORD *error_out
) {
  wchar_t *command = utf8_to_wide(command_utf8);
  wchar_t *cwd = cwd_utf8 && cwd_utf8[0] ? utf8_to_wide(cwd_utf8) : NULL;
  if (!command || (cwd_utf8 && cwd_utf8[0] && !cwd)) {
    if (command) HeapFree(GetProcessHeap(), 0, command);
    if (cwd) HeapFree(GetProcessHeap(), 0, cwd);
    *error_out = ERROR_NOT_ENOUGH_MEMORY;
    return false;
  }

  SIZE_T attribute_size = 0;
  InitializeProcThreadAttributeList(NULL, 1, 0, &attribute_size);
  PPROC_THREAD_ATTRIBUTE_LIST attributes =
    (PPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(GetProcessHeap(), 0, attribute_size);
  if (!attributes) {
    HeapFree(GetProcessHeap(), 0, command);
    if (cwd) HeapFree(GetProcessHeap(), 0, cwd);
    *error_out = ERROR_NOT_ENOUGH_MEMORY;
    return false;
  }

  bool initialized = InitializeProcThreadAttributeList(attributes, 1, 0, &attribute_size) != FALSE;
  bool updated = initialized && UpdateProcThreadAttribute(
    attributes, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
    session->pseudoconsole, sizeof(session->pseudoconsole), NULL, NULL
  ) != FALSE;

  STARTUPINFOEXW startup;
  PROCESS_INFORMATION process;
  memset(&startup, 0, sizeof(startup));
  memset(&process, 0, sizeof(process));
  startup.StartupInfo.cb = sizeof(startup);
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  startup.lpAttributeList = attributes;
  wchar_t *environment = terminal_environment();

  bool created = updated && environment && CreateProcessW(
    NULL, command, NULL, NULL, FALSE,
    EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED,
    environment, cwd, &startup.StartupInfo, &process
  ) != FALSE;
  *error_out = created ? ERROR_SUCCESS : environment ? GetLastError() : ERROR_NOT_ENOUGH_MEMORY;

  if (initialized) DeleteProcThreadAttributeList(attributes);
  HeapFree(GetProcessHeap(), 0, attributes);
  HeapFree(GetProcessHeap(), 0, command);
  if (environment) HeapFree(GetProcessHeap(), 0, environment);
  if (cwd) HeapFree(GetProcessHeap(), 0, cwd);

  if (!created) return false;
  session->process = process.hProcess;
  session->process_thread = process.hThread;
  if (!create_kill_job(session)) {
    *error_out = GetLastError();
    TerminateProcess(session->process, 1);
    WaitForSingleObject(session->process, INFINITE);
    close_handle(&session->process_thread);
    close_handle(&session->process);
    return false;
  }
  if (ResumeThread(session->process_thread) == (DWORD)-1) {
    *error_out = GetLastError();
    close_handle(&session->job);
    WaitForSingleObject(session->process, INFINITE);
    close_handle(&session->process_thread);
    close_handle(&session->process);
    return false;
  }
  set_terminal_state(session, TERMINAL_STATE_RUNNING);
  return true;
}

static bool create_pseudoconsole(
  TerminalSession *session, const char *shell, const char *cwd, DWORD *error_out
) {
  HANDLE input_read = NULL;
  HANDLE output_write = NULL;
  SECURITY_ATTRIBUTES security = {
    .nLength = sizeof(SECURITY_ATTRIBUTES),
    .lpSecurityDescriptor = NULL,
    .bInheritHandle = TRUE,
  };

  if (!CreatePipe(&input_read, &session->input_write, &security, 0) ||
      !CreatePipe(&session->output_read, &output_write, &security, 0)) {
    *error_out = GetLastError();
    close_handle(&input_read);
    close_handle(&output_write);
    return false;
  }
  SetHandleInformation(session->input_write, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(session->output_read, HANDLE_FLAG_INHERIT, 0);

  COORD size = { (SHORT)session->cols, (SHORT)session->rows };
  HRESULT result = CreatePseudoConsole(size, input_read, output_write, 0, &session->pseudoconsole);
  if (FAILED(result)) {
    close_handle(&input_read);
    close_handle(&output_write);
    *error_out = HRESULT_CODE(result);
    return false;
  }

  bool created = false;
  if (shell && shell[0]) {
    created = create_shell_process(session, shell, cwd, error_out);
  } else if (create_shell_process(session, "pwsh.exe -NoLogo", cwd, error_out)) {
    created = true;
  } else {
    created = create_shell_process(session, "powershell.exe -NoLogo", cwd, error_out);
  }
  close_handle(&input_read);
  close_handle(&output_write);
  return created;
}

static int f_terminal_new(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  TerminalColors colors = read_terminal_colors(L, 1);
  size_t scrollback_max_lines = 0;
  bool has_scrollback_max_lines = false;
  lua_getfield(L, 1, "scrollback_lines");
  if (!lua_isnil(L, -1)) {
    lua_Integer value = luaL_checkinteger(L, -1);
    luaL_argcheck(L, value >= 0, 1, "terminal scrollback line limit is out of range");
    scrollback_max_lines = (size_t)value;
    has_scrollback_max_lines = true;
  }
  lua_pop(L, 1);
  TerminalSession *session = (TerminalSession *)lua_newuserdata(L, sizeof(*session));
  memset(session, 0, sizeof(*session));
  session->state = TERMINAL_STATE_NEW;
  session->state_revision = 1;
  InterlockedExchange64(&session->last_output_ms, (LONG64)GetTickCount64());
  luaL_setmetatable(L, API_TYPE_TERMINAL_SESSION);

  lua_getfield(L, 1, "cols");
  session->cols = (uint16_t)luaL_optinteger(L, -1, 80);
  lua_pop(L, 1);
  lua_getfield(L, 1, "rows");
  session->rows = (uint16_t)luaL_optinteger(L, -1, 24);
  lua_pop(L, 1);
  lua_getfield(L, 1, "cell_width");
  session->cell_width = (uint32_t)luaL_optinteger(L, -1, 8);
  lua_pop(L, 1);
  lua_getfield(L, 1, "cell_height");
  session->cell_height = (uint32_t)luaL_optinteger(L, -1, 16);
  lua_pop(L, 1);
  if (session->cols == 0) session->cols = 1;
  if (session->rows == 0) session->rows = 1;
  if (session->cell_width == 0) session->cell_width = 1;
  if (session->cell_height == 0) session->cell_height = 1;

  lua_getfield(L, 1, "cwd");
  const char *cwd = lua_isstring(L, -1) ? lua_tostring(L, -1) : NULL;
  lua_getfield(L, 1, "shell");
  const char *shell = lua_isstring(L, -1) ? lua_tostring(L, -1) : NULL;

  DWORD error = ERROR_SUCCESS;
  if (!create_pseudoconsole(session, shell, cwd, &error)) {
    lua_pop(L, 2);
    close_session(session);
    lua_pop(L, 1);
    lua_pushnil(L);
    push_windows_error(L, "Could not start ConPTY", error);
    return 2;
  }
  lua_pop(L, 2);

  if (!start_terminal_io(session)) {
    close_session(session);
    lua_pop(L, 1);
    lua_pushnil(L);
    lua_pushliteral(L, "Could not start ConPTY input and output workers");
    return 2;
  }

  if (!initialize_terminal(
      session, &colors,
      has_scrollback_max_lines ? &scrollback_max_lines : NULL
    )) {
    close_session(session);
    lua_pop(L, 1);
    lua_pushnil(L);
    lua_pushliteral(L, "Could not initialize libghostty-vt");
    return 2;
  }
  return 1;
}

static bool process_running(TerminalSession *session) {
  if (!session->process || session->closed) return false;
  DWORD wait = WaitForSingleObject(session->process, 0);
  if (wait == WAIT_TIMEOUT) return true;
  if (wait != WAIT_OBJECT_0) return false;
  DWORD exit_code = 0;
  if (!GetExitCodeProcess(session->process, &exit_code)) return false;
  session->exit_code = exit_code;
  session->exit_code_known = true;
  return false;
}

static bool output_drained(TerminalSession *session) {
  if (!session->read_lock_initialized || !session->output_read) return true;
  bool empty = true;
  EnterCriticalSection(&session->read_lock);
  empty = session->read_queue_count == 0;
  LeaveCriticalSection(&session->read_lock);
  return empty && InterlockedCompareExchange(&session->reader_done, 0, 0) != 0;
}

static void push_status(lua_State *L, TerminalSession *session) {
  bool read_failed = InterlockedCompareExchange(&session->read_failed, 0, 0) != 0;
  bool write_failed = InterlockedCompareExchange(&session->write_failed, 0, 0) != 0;
  lua_createtable(L, 0, 4);
  lua_pushstring(L, terminal_state_name(session->state));
  lua_setfield(L, -2, "kind");
  set_integer_field(L, "revision", (lua_Integer)session->state_revision);
  if (session->state == TERMINAL_STATE_EXITED && session->exit_code_known) {
    lua_pushinteger(L, session->exit_code);
    lua_setfield(L, -2, "exit_code");
  }
  if (read_failed || write_failed) {
    DWORD error = read_failed ? session->read_error : session->write_error;
    const char *operation = read_failed ? "output" : "input";
    char *message = NULL;
    FormatMessageA(
      FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
        FORMAT_MESSAGE_IGNORE_INSERTS,
      NULL, error, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
      (char *)&message, 0, NULL
    );
    if (message) {
      size_t length = strlen(message);
      while (length > 0 && (message[length - 1] == '\r' || message[length - 1] == '\n')) {
        message[--length] = '\0';
      }
      lua_pushfstring(L, "ConPTY %s failed: %s", operation, message);
      LocalFree(message);
    } else {
      lua_pushfstring(L, "ConPTY %s failed: Windows error %d", operation, (int)error);
    }
    lua_setfield(L, -2, "error");
  }
}

static int f_terminal_update(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  if (session->closed) {
    lua_pushboolean(L, false);
    push_status(L, session);
    return 2;
  }
  if (session->transport_released) {
    lua_pushboolean(L, false);
    push_status(L, session);
    return 2;
  }

  uint8_t buffer[65536];
  size_t total = 0;
  bool changed = false;
  while (total < TERMINAL_READ_BUDGET) {
    size_t amount = 0;
    EnterCriticalSection(&session->read_lock);
    if (session->read_queue_count > 0) {
      amount = session->read_queue_count;
      if (amount > sizeof(buffer)) amount = sizeof(buffer);
      if (amount > TERMINAL_READ_BUDGET - total) amount = TERMINAL_READ_BUDGET - total;
      size_t contiguous = TERMINAL_READ_QUEUE_CAPACITY - session->read_queue_head;
      if (amount > contiguous) amount = contiguous;
      memcpy(buffer, session->read_queue + session->read_queue_head, amount);
      session->read_queue_head = (session->read_queue_head + amount) %
        TERMINAL_READ_QUEUE_CAPACITY;
      session->read_queue_count -= amount;
      WakeConditionVariable(&session->read_ready);
    }
    LeaveCriticalSection(&session->read_lock);
    if (amount == 0) break;
    if (session->vt_trace_file) {
      DWORD written = 0;
      BOOL write_ok = WriteFile(
        session->vt_trace_file, buffer, (DWORD)amount, &written, NULL
      );
      if (!write_ok || written != (DWORD)amount) {
        session->vt_trace_error = write_ok ? ERROR_WRITE_FAULT : GetLastError();
        close_handle(&session->vt_trace_file);
      } else {
        session->vt_trace_bytes += written;
      }
    }
    ghostty_terminal_vt_write(session->terminal, buffer, amount);
    session->output_bytes_parsed += amount;
    total += amount;
    changed = true;
  }

  if (changed) {
    if (ghostty_render_state_update(session->render_state, session->terminal) != GHOSTTY_SUCCESS) {
      changed = false;
    } else {
      session->render_generation++;
      invalidate_search_scan(session);
    }
  }
  bool output_remains = false;
  EnterCriticalSection(&session->read_lock);
  InterlockedExchange(&session->output_event_pending, 0);
  output_remains = session->read_queue_count > 0;
  LeaveCriticalSection(&session->read_lock);
  if (output_remains) wake_for_terminal_output(session);
  uint64_t now = GetTickCount64();
  if (session->state == TERMINAL_STATE_RUNNING && !process_running(session)) {
    session->process_exit_seen_ms = now;
    session->drain_empty_seen_ms = 0;
    LONG64 last_output = InterlockedCompareExchange64(&session->last_output_ms, 0, 0);
    if ((uint64_t)last_output < now) {
      InterlockedExchange64(&session->last_output_ms, (LONG64)now);
    }
    set_terminal_state(session, TERMINAL_STATE_DRAINING);
    start_pseudoconsole_close(session);
  }
  bool read_failed = InterlockedCompareExchange(&session->read_failed, 0, 0) != 0;
  bool write_failed = InterlockedCompareExchange(&session->write_failed, 0, 0) != 0;
  if ((session->state == TERMINAL_STATE_RUNNING ||
       session->state == TERMINAL_STATE_DRAINING) && (read_failed || write_failed)) {
    set_terminal_state(session, TERMINAL_STATE_FAILED);
    terminate_terminal_process(session);
    release_terminal_transport(session);
  }
  uint64_t last_output = (uint64_t)InterlockedCompareExchange64(
    &session->last_output_ms, 0, 0
  );
  bool drained = session->state == TERMINAL_STATE_DRAINING && output_drained(session);
  if (drained && session->drain_empty_seen_ms == 0) session->drain_empty_seen_ms = now;
  if (!drained) session->drain_empty_seen_ms = 0;
  bool drain_expired = session->state == TERMINAL_STATE_DRAINING &&
    now - session->process_exit_seen_ms >= TERMINAL_DRAIN_MAX_MS;
  bool drain_complete = session->state == TERMINAL_STATE_DRAINING &&
    drained && now - last_output >= TERMINAL_DRAIN_QUIET_MS &&
    now - session->drain_empty_seen_ms >= TERMINAL_DRAIN_QUIET_MS;
  if (drain_complete || drain_expired) {
    if (drain_expired) {
      session->forced_drain_finalizations++;
    }
    if (session->job) close_handle(&session->job);
    close_handle(&session->process_thread);
    close_handle(&session->process);
    release_terminal_transport(session);
    set_terminal_state(session, TERMINAL_STATE_EXITED);
  }
  lua_pushboolean(L, changed);
  push_status(L, session);
  return 2;
}

static int f_terminal_write(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  size_t length = 0;
  const char *text = luaL_checklstring(L, 2, &length);
  uint64_t rejected_before = session->rejected_writes;
  bool ok = write_all(session, (const uint8_t *)text, length);
  lua_pushboolean(L, ok);
  if (ok) return 1;
  if (session->rejected_writes != rejected_before) {
    lua_pushliteral(L, "queue_full");
    return 2;
  }
  lua_pushstring(L, terminal_state_name(session->state));
  return 2;
}

static int f_terminal_trace(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  if (lua_isnoneornil(L, 2)) {
    if (!session->vt_trace_file) {
      lua_pushboolean(L, false);
      lua_pushinteger(L, (lua_Integer)session->vt_trace_bytes);
      if (session->vt_trace_error != ERROR_SUCCESS) {
        push_windows_error(L, "Terminal VT trace failed", session->vt_trace_error);
      } else {
        lua_pushliteral(L, "Terminal VT trace is not active");
      }
      return 3;
    }
    if (!FlushFileBuffers(session->vt_trace_file) &&
        session->vt_trace_error == ERROR_SUCCESS) {
      session->vt_trace_error = GetLastError();
    }
    close_handle(&session->vt_trace_file);
    lua_pushboolean(L, session->vt_trace_error == ERROR_SUCCESS);
    lua_pushinteger(L, (lua_Integer)session->vt_trace_bytes);
    if (session->vt_trace_error != ERROR_SUCCESS) {
      push_windows_error(L, "Terminal VT trace failed", session->vt_trace_error);
      return 3;
    }
    return 2;
  }

  const char *path = luaL_checkstring(L, 2);
  if (session->closed || !terminal_model_available(session)) {
    lua_pushboolean(L, false);
    lua_pushliteral(L, "Terminal session is closed");
    return 2;
  }
  if (session->vt_trace_file) {
    lua_pushboolean(L, false);
    lua_pushliteral(L, "Terminal VT trace is already active");
    return 2;
  }
  if (!path[0]) {
    lua_pushboolean(L, false);
    lua_pushliteral(L, "Terminal VT trace path is empty");
    return 2;
  }

  wchar_t *wide_path = utf8_to_wide(path);
  if (!wide_path) {
    lua_pushboolean(L, false);
    lua_pushliteral(L, "Terminal VT trace path is not valid UTF-8");
    return 2;
  }
  HANDLE file = CreateFileW(
    wide_path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_DELETE,
    NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL
  );
  HeapFree(GetProcessHeap(), 0, wide_path);
  if (file == INVALID_HANDLE_VALUE) {
    DWORD error = GetLastError();
    lua_pushboolean(L, false);
    push_windows_error(L, "Could not start terminal VT trace", error);
    return 2;
  }
  session->vt_trace_file = file;
  session->vt_trace_bytes = 0;
  session->vt_trace_error = ERROR_SUCCESS;
  lua_pushboolean(L, true);
  return 1;
}

static int f_terminal_paste(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  size_t length = 0;
  const char *text = luaL_checklstring(L, 2, &length);
  bool allow_unsafe = lua_toboolean(L, 3) != 0;
  if (!terminal_is_live(session)) {
    lua_pushboolean(L, false);
    lua_pushstring(L, terminal_state_name(session->state));
    return 2;
  }
  bool safe = ghostty_paste_is_safe(text, length);
  if (!safe && !allow_unsafe) {
    lua_pushboolean(L, false);
    lua_pushliteral(L, "unsafe");
    return 2;
  }

  GhosttyTerminalModeConfig mode = {
    .mode = GHOSTTY_MODE_BRACKETED_PASTE,
    .value = false,
  };
  ghostty_terminal_get(session->terminal, GHOSTTY_TERMINAL_DATA_MODE, &mode);

  size_t capacity = length + 16;
  char *input = (char *)HeapAlloc(GetProcessHeap(), 0, length ? length : 1);
  char *encoded = (char *)HeapAlloc(GetProcessHeap(), 0, capacity);
  if (!input || !encoded) {
    if (input) HeapFree(GetProcessHeap(), 0, input);
    if (encoded) HeapFree(GetProcessHeap(), 0, encoded);
    lua_pushboolean(L, false);
    lua_pushliteral(L, "out_of_memory");
    return 2;
  }
  if (length) memcpy(input, text, length);

  size_t written = 0;
  GhosttyResult result = ghostty_paste_encode(
    input, length, mode.value, encoded, capacity, &written
  );
  uint64_t rejected_before = session->rejected_writes;
  bool ok = result == GHOSTTY_SUCCESS && write_all(
    session, (const uint8_t *)encoded, written
  );
  HeapFree(GetProcessHeap(), 0, input);
  HeapFree(GetProcessHeap(), 0, encoded);
  lua_pushboolean(L, ok);
  if (!ok) lua_pushstring(L,
    session->rejected_writes != rejected_before ? "queue_full" : "write_failed");
  return ok ? 1 : 2;
}

static int f_terminal_stats(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  uint64_t read_queue_high_water = 0;
  if (session->read_lock_initialized) {
    EnterCriticalSection(&session->read_lock);
    read_queue_high_water = session->read_queue_high_water;
    LeaveCriticalSection(&session->read_lock);
  } else read_queue_high_water = session->read_queue_high_water;
  lua_createtable(L, 0, 9);
  set_integer_field(L, "output_bytes_read", (lua_Integer)InterlockedCompareExchange64(
    &session->output_bytes_read, 0, 0));
  set_integer_field(L, "output_bytes_parsed", (lua_Integer)session->output_bytes_parsed);
  set_integer_field(L, "input_bytes_queued", (lua_Integer)session->input_bytes_queued);
  set_integer_field(L, "read_queue_high_water", (lua_Integer)read_queue_high_water);
  set_integer_field(L, "write_queue_high_water", (lua_Integer)session->write_queue_high_water);
  set_integer_field(L, "rejected_writes", (lua_Integer)session->rejected_writes);
  set_integer_field(L, "forced_drain_finalizations",
    (lua_Integer)session->forced_drain_finalizations);
  set_integer_field(L, "render_generation", (lua_Integer)session->render_generation);
  return 1;
}

static int f_terminal_resize(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  uint16_t cols = (uint16_t)luaL_checkinteger(L, 2);
  uint16_t rows = (uint16_t)luaL_checkinteger(L, 3);
  uint32_t cell_width = (uint32_t)luaL_checkinteger(L, 4);
  uint32_t cell_height = (uint32_t)luaL_checkinteger(L, 5);
  if (!terminal_is_live(session) || session->transport_released || !session->pseudoconsole ||
      cols == 0 || rows == 0 || cell_width == 0 || cell_height == 0) {
    lua_pushboolean(L, false);
    return 1;
  }

  COORD size = { (SHORT)cols, (SHORT)rows };
  if (FAILED(ResizePseudoConsole(session->pseudoconsole, size))) {
    lua_pushboolean(L, false);
    return 1;
  }
  if (ghostty_terminal_resize(
    session->terminal, cols, rows, cell_width, cell_height
  ) != GHOSTTY_SUCCESS) {
    lua_pushboolean(L, false);
    return 1;
  }
  session->cols = cols;
  session->rows = rows;
  session->cell_width = cell_width;
  session->cell_height = cell_height;
  ghostty_render_state_update(session->render_state, session->terminal);
  session->render_generation++;
  invalidate_search_scan(session);
  lua_pushboolean(L, true);
  return 1;
}

static int f_terminal_clear(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  if (!terminal_is_live(session)) {
    lua_pushboolean(L, false);
    return 1;
  }
  static const uint8_t clear_sequence[] = "\x1b[2J\x1b[3J\x1b[H";
  ghostty_terminal_vt_write(
    session->terminal, clear_sequence, sizeof(clear_sequence) - 1
  );
  ghostty_render_state_update(session->render_state, session->terminal);
  session->render_generation++;
  invalidate_search_scan(session);
  lua_pushboolean(L, true);
  return 1;
}

static GhosttyKey key_from_name(const char *name, uint32_t *codepoint, bool *printable) {
  *codepoint = 0;
  *printable = false;
  if (!name || !name[0]) return GHOSTTY_KEY_UNIDENTIFIED;
  if (name[1] == '\0' && name[0] >= 'a' && name[0] <= 'z') {
    *codepoint = (uint32_t)name[0];
    *printable = true;
    return (GhosttyKey)(GHOSTTY_KEY_A + (name[0] - 'a'));
  }
  if (name[1] == '\0' && name[0] >= '0' && name[0] <= '9') {
    *codepoint = (uint32_t)name[0];
    *printable = true;
    return (GhosttyKey)(GHOSTTY_KEY_DIGIT_0 + (name[0] - '0'));
  }
  if (name[0] == 'f' && name[1] >= '1' && name[1] <= '9') {
    char *end = NULL;
    long number = strtol(name + 1, &end, 10);
    if (end && *end == '\0' && number >= 1 && number <= 25) {
      return (GhosttyKey)(GHOSTTY_KEY_F1 + number - 1);
    }
  }

  struct KeyName { const char *name; GhosttyKey key; uint32_t codepoint; bool printable; };
  static const struct KeyName names[] = {
    { "return", GHOSTTY_KEY_ENTER, 0, false },
    { "enter", GHOSTTY_KEY_ENTER, 0, false },
    { "backspace", GHOSTTY_KEY_BACKSPACE, 0, false },
    { "delete", GHOSTTY_KEY_DELETE, 0, false },
    { "escape", GHOSTTY_KEY_ESCAPE, 0, false },
    { "tab", GHOSTTY_KEY_TAB, 0, false },
    { "left", GHOSTTY_KEY_ARROW_LEFT, 0, false },
    { "right", GHOSTTY_KEY_ARROW_RIGHT, 0, false },
    { "up", GHOSTTY_KEY_ARROW_UP, 0, false },
    { "down", GHOSTTY_KEY_ARROW_DOWN, 0, false },
    { "home", GHOSTTY_KEY_HOME, 0, false },
    { "end", GHOSTTY_KEY_END, 0, false },
    { "pageup", GHOSTTY_KEY_PAGE_UP, 0, false },
    { "pagedown", GHOSTTY_KEY_PAGE_DOWN, 0, false },
    { "insert", GHOSTTY_KEY_INSERT, 0, false },
    { "space", GHOSTTY_KEY_SPACE, ' ', true },
    { "-", GHOSTTY_KEY_MINUS, '-', true },
    { "=", GHOSTTY_KEY_EQUAL, '=', true },
    { "[", GHOSTTY_KEY_BRACKET_LEFT, '[', true },
    { "]", GHOSTTY_KEY_BRACKET_RIGHT, ']', true },
    { "\\", GHOSTTY_KEY_BACKSLASH, '\\', true },
    { ";", GHOSTTY_KEY_SEMICOLON, ';', true },
    { "'", GHOSTTY_KEY_QUOTE, '\'', true },
    { ",", GHOSTTY_KEY_COMMA, ',', true },
    { ".", GHOSTTY_KEY_PERIOD, '.', true },
    { "/", GHOSTTY_KEY_SLASH, '/', true },
    { "`", GHOSTTY_KEY_BACKQUOTE, '`', true },
  };
  for (size_t index = 0; index < sizeof(names) / sizeof(names[0]); index++) {
    if (strcmp(name, names[index].name) == 0) {
      *codepoint = names[index].codepoint;
      *printable = names[index].printable;
      return names[index].key;
    }
  }
  return GHOSTTY_KEY_UNIDENTIFIED;
}

static GhosttyKey key_from_scancode(lua_Integer value) {
  SDL_Scancode scancode = (SDL_Scancode)value;
  if (scancode >= SDL_SCANCODE_A && scancode <= SDL_SCANCODE_Z) {
    return (GhosttyKey)(GHOSTTY_KEY_A + scancode - SDL_SCANCODE_A);
  }
  if (scancode >= SDL_SCANCODE_1 && scancode <= SDL_SCANCODE_9) {
    return (GhosttyKey)(GHOSTTY_KEY_DIGIT_1 + scancode - SDL_SCANCODE_1);
  }
  if (scancode == SDL_SCANCODE_0) return GHOSTTY_KEY_DIGIT_0;
  if (scancode >= SDL_SCANCODE_F1 && scancode <= SDL_SCANCODE_F12) {
    return (GhosttyKey)(GHOSTTY_KEY_F1 + scancode - SDL_SCANCODE_F1);
  }
  if (scancode >= SDL_SCANCODE_F13 && scancode <= SDL_SCANCODE_F24) {
    return (GhosttyKey)(GHOSTTY_KEY_F13 + scancode - SDL_SCANCODE_F13);
  }

  struct ScanKey { SDL_Scancode scancode; GhosttyKey key; };
  static const struct ScanKey keys[] = {
    { SDL_SCANCODE_RETURN, GHOSTTY_KEY_ENTER },
    { SDL_SCANCODE_ESCAPE, GHOSTTY_KEY_ESCAPE },
    { SDL_SCANCODE_BACKSPACE, GHOSTTY_KEY_BACKSPACE },
    { SDL_SCANCODE_TAB, GHOSTTY_KEY_TAB },
    { SDL_SCANCODE_SPACE, GHOSTTY_KEY_SPACE },
    { SDL_SCANCODE_MINUS, GHOSTTY_KEY_MINUS },
    { SDL_SCANCODE_EQUALS, GHOSTTY_KEY_EQUAL },
    { SDL_SCANCODE_LEFTBRACKET, GHOSTTY_KEY_BRACKET_LEFT },
    { SDL_SCANCODE_RIGHTBRACKET, GHOSTTY_KEY_BRACKET_RIGHT },
    { SDL_SCANCODE_BACKSLASH, GHOSTTY_KEY_BACKSLASH },
    { SDL_SCANCODE_NONUSHASH, GHOSTTY_KEY_INTL_BACKSLASH },
    { SDL_SCANCODE_SEMICOLON, GHOSTTY_KEY_SEMICOLON },
    { SDL_SCANCODE_APOSTROPHE, GHOSTTY_KEY_QUOTE },
    { SDL_SCANCODE_GRAVE, GHOSTTY_KEY_BACKQUOTE },
    { SDL_SCANCODE_COMMA, GHOSTTY_KEY_COMMA },
    { SDL_SCANCODE_PERIOD, GHOSTTY_KEY_PERIOD },
    { SDL_SCANCODE_SLASH, GHOSTTY_KEY_SLASH },
    { SDL_SCANCODE_PRINTSCREEN, GHOSTTY_KEY_PRINT_SCREEN },
    { SDL_SCANCODE_SCROLLLOCK, GHOSTTY_KEY_SCROLL_LOCK },
    { SDL_SCANCODE_PAUSE, GHOSTTY_KEY_PAUSE },
    { SDL_SCANCODE_INSERT, GHOSTTY_KEY_INSERT },
    { SDL_SCANCODE_HOME, GHOSTTY_KEY_HOME },
    { SDL_SCANCODE_PAGEUP, GHOSTTY_KEY_PAGE_UP },
    { SDL_SCANCODE_DELETE, GHOSTTY_KEY_DELETE },
    { SDL_SCANCODE_END, GHOSTTY_KEY_END },
    { SDL_SCANCODE_PAGEDOWN, GHOSTTY_KEY_PAGE_DOWN },
    { SDL_SCANCODE_RIGHT, GHOSTTY_KEY_ARROW_RIGHT },
    { SDL_SCANCODE_LEFT, GHOSTTY_KEY_ARROW_LEFT },
    { SDL_SCANCODE_DOWN, GHOSTTY_KEY_ARROW_DOWN },
    { SDL_SCANCODE_UP, GHOSTTY_KEY_ARROW_UP },
    { SDL_SCANCODE_NUMLOCKCLEAR, GHOSTTY_KEY_NUM_LOCK },
    { SDL_SCANCODE_KP_DIVIDE, GHOSTTY_KEY_NUMPAD_DIVIDE },
    { SDL_SCANCODE_KP_MULTIPLY, GHOSTTY_KEY_NUMPAD_MULTIPLY },
    { SDL_SCANCODE_KP_MINUS, GHOSTTY_KEY_NUMPAD_SUBTRACT },
    { SDL_SCANCODE_KP_PLUS, GHOSTTY_KEY_NUMPAD_ADD },
    { SDL_SCANCODE_KP_ENTER, GHOSTTY_KEY_NUMPAD_ENTER },
    { SDL_SCANCODE_KP_1, GHOSTTY_KEY_NUMPAD_1 },
    { SDL_SCANCODE_KP_2, GHOSTTY_KEY_NUMPAD_2 },
    { SDL_SCANCODE_KP_3, GHOSTTY_KEY_NUMPAD_3 },
    { SDL_SCANCODE_KP_4, GHOSTTY_KEY_NUMPAD_4 },
    { SDL_SCANCODE_KP_5, GHOSTTY_KEY_NUMPAD_5 },
    { SDL_SCANCODE_KP_6, GHOSTTY_KEY_NUMPAD_6 },
    { SDL_SCANCODE_KP_7, GHOSTTY_KEY_NUMPAD_7 },
    { SDL_SCANCODE_KP_8, GHOSTTY_KEY_NUMPAD_8 },
    { SDL_SCANCODE_KP_9, GHOSTTY_KEY_NUMPAD_9 },
    { SDL_SCANCODE_KP_0, GHOSTTY_KEY_NUMPAD_0 },
    { SDL_SCANCODE_KP_PERIOD, GHOSTTY_KEY_NUMPAD_DECIMAL },
  };
  for (size_t index = 0; index < sizeof(keys) / sizeof(keys[0]); index++) {
    if (keys[index].scancode == scancode) return keys[index].key;
  }
  return GHOSTTY_KEY_UNIDENTIFIED;
}

static bool table_bool(lua_State *L, int index, const char *name) {
  lua_getfield(L, index, name);
  bool value = lua_toboolean(L, -1) != 0;
  lua_pop(L, 1);
  return value;
}

static int f_terminal_key(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  const char *name = luaL_checkstring(L, 2);
  luaL_checktype(L, 3, LUA_TTABLE);
  if (!terminal_is_live(session)) {
    lua_pushboolean(L, false);
    return 1;
  }

  GhosttyMods mods = 0;
  lua_getfield(L, 3, "raw");
  if (lua_isnumber(L, -1)) {
    SDL_Keymod raw = (SDL_Keymod)lua_tointeger(L, -1);
    if (raw & SDL_KMOD_SHIFT) mods |= GHOSTTY_MODS_SHIFT;
    if (raw & SDL_KMOD_CTRL) mods |= GHOSTTY_MODS_CTRL;
    if (raw & SDL_KMOD_ALT) mods |= GHOSTTY_MODS_ALT;
    if (raw & SDL_KMOD_GUI) mods |= GHOSTTY_MODS_SUPER;
    if (raw & SDL_KMOD_CAPS) mods |= GHOSTTY_MODS_CAPS_LOCK;
    if (raw & SDL_KMOD_NUM) mods |= GHOSTTY_MODS_NUM_LOCK;
    if (raw & SDL_KMOD_RSHIFT) mods |= GHOSTTY_MODS_SHIFT_SIDE;
    if (raw & SDL_KMOD_RCTRL) mods |= GHOSTTY_MODS_CTRL_SIDE;
    if (raw & SDL_KMOD_RALT) mods |= GHOSTTY_MODS_ALT_SIDE;
    if (raw & SDL_KMOD_RGUI) mods |= GHOSTTY_MODS_SUPER_SIDE;
  } else {
    if (table_bool(L, 3, "shift")) mods |= GHOSTTY_MODS_SHIFT;
    if (table_bool(L, 3, "ctrl")) mods |= GHOSTTY_MODS_CTRL;
    if (table_bool(L, 3, "alt")) mods |= GHOSTTY_MODS_ALT;
    if (table_bool(L, 3, "super")) mods |= GHOSTTY_MODS_SUPER;
  }
  lua_pop(L, 1);

  uint32_t codepoint = 0;
  bool printable = false;
  GhosttyKey key = key_from_name(name, &codepoint, &printable);
  const char *event_text = printable ? name : NULL;
  size_t event_text_length = printable ? strlen(name) : 0;
  uint32_t unshifted_codepoint = codepoint;
  GhosttyMods consumed_mods = 0;
  if (lua_istable(L, 5)) {
    lua_getfield(L, 5, "scancode");
    if (lua_isnumber(L, -1)) {
      GhosttyKey physical = key_from_scancode(lua_tointeger(L, -1));
      if (physical != GHOSTTY_KEY_UNIDENTIFIED) key = physical;
    }
    lua_pop(L, 1);
    lua_getfield(L, 5, "text");
    if (lua_isstring(L, -1)) event_text = lua_tolstring(L, -1, &event_text_length);
    lua_pop(L, 1);
    lua_getfield(L, 5, "unshifted_codepoint");
    if (lua_isnumber(L, -1)) unshifted_codepoint = (uint32_t)lua_tointeger(L, -1);
    lua_pop(L, 1);
    lua_getfield(L, 5, "consumed_modifiers");
    if (lua_isnumber(L, -1)) {
      SDL_Keymod consumed = (SDL_Keymod)lua_tointeger(L, -1);
      if (consumed & SDL_KMOD_SHIFT) consumed_mods |= GHOSTTY_MODS_SHIFT;
      if (consumed & SDL_KMOD_CTRL) consumed_mods |= GHOSTTY_MODS_CTRL;
      if (consumed & (SDL_KMOD_ALT | SDL_KMOD_MODE)) consumed_mods |= GHOSTTY_MODS_ALT;
      if (consumed & SDL_KMOD_GUI) consumed_mods |= GHOSTTY_MODS_SUPER;
      if (consumed & SDL_KMOD_CAPS) consumed_mods |= GHOSTTY_MODS_CAPS_LOCK;
      if (consumed & SDL_KMOD_NUM) consumed_mods |= GHOSTTY_MODS_NUM_LOCK;
    }
    lua_pop(L, 1);
  }
  GhosttyKeyAction action = GHOSTTY_KEY_ACTION_PRESS;
  const char *action_name = luaL_optstring(L, 4, "press");
  if (strcmp(action_name, "repeat") == 0) action = GHOSTTY_KEY_ACTION_REPEAT;
  else if (strcmp(action_name, "release") == 0) action = GHOSTTY_KEY_ACTION_RELEASE;
  GhosttyMods encoding_mods = mods & (
    GHOSTTY_MODS_SHIFT | GHOSTTY_MODS_CTRL | GHOSTTY_MODS_ALT | GHOSTTY_MODS_SUPER
  );
  if (key == GHOSTTY_KEY_UNIDENTIFIED ||
      (printable && encoding_mods == 0 && action != GHOSTTY_KEY_ACTION_RELEASE)) {
    lua_pushboolean(L, false);
    return 1;
  }

  ghostty_key_encoder_setopt_from_terminal(session->key_encoder, session->terminal);
  ghostty_key_event_set_action(session->key_event, action);
  ghostty_key_event_set_key(session->key_event, key);
  ghostty_key_event_set_mods(session->key_event, mods);
  ghostty_key_event_set_consumed_mods(session->key_event, consumed_mods);
  ghostty_key_event_set_composing(session->key_event, false);
  ghostty_key_event_set_utf8(session->key_event, event_text, event_text_length);
  ghostty_key_event_set_unshifted_codepoint(session->key_event, unshifted_codepoint);

  char encoded[128];
  size_t written = 0;
  GhosttyResult result = ghostty_key_encoder_encode(
    session->key_encoder, session->key_event, encoded, sizeof(encoded), &written
  );
  uint64_t rejected_before = session->rejected_writes;
  bool ok = result == GHOSTTY_SUCCESS && written > 0 &&
    write_all(session, (const uint8_t *)encoded, written);
  lua_pushboolean(L, ok);
  if (!ok && session->rejected_writes != rejected_before) {
    lua_pushliteral(L, "queue_full");
    return 2;
  }
  return 1;
}

static bool viewport_ref(
  TerminalSession *session, uint16_t x, uint32_t y, GhosttyGridRef *out_ref
);

static int f_terminal_scroll(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  if (!terminal_model_available(session)) {
    lua_pushboolean(L, false);
    return 1;
  }
  GhosttyTerminalScrollViewport viewport = { .tag = GHOSTTY_SCROLL_VIEWPORT_DELTA };
  if (lua_type(L, 2) == LUA_TSTRING) {
    const char *kind = lua_tostring(L, 2);
    if (strcmp(kind, "top") == 0) viewport.tag = GHOSTTY_SCROLL_VIEWPORT_TOP;
    else if (strcmp(kind, "bottom") == 0) viewport.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM;
    else if (strcmp(kind, "row") == 0) {
      viewport.tag = GHOSTTY_SCROLL_VIEWPORT_ROW;
      viewport.value.row = (size_t)luaL_checkinteger(L, 3);
    } else {
      viewport.value.delta = (intptr_t)luaL_checkinteger(L, 3);
    }
  } else {
    viewport.value.delta = (intptr_t)luaL_checkinteger(L, 2);
  }
  ghostty_terminal_scroll_viewport(session->terminal, viewport);
  ghostty_render_state_update(session->render_state, session->terminal);
  lua_pushboolean(L, true);
  return 1;
}

static int f_terminal_selection_gesture(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  const char *kind = luaL_checkstring(L, 2);
  uint16_t col = (uint16_t)luaL_checkinteger(L, 3);
  uint32_t row = (uint32_t)luaL_checkinteger(L, 4);
  double pixel_x = luaL_checknumber(L, 5);
  double pixel_y = luaL_checknumber(L, 6);
  (void)luaL_optinteger(L, 7, 1);
  bool rectangle = lua_toboolean(L, 8) != 0;
  if (!terminal_model_available(session)) {
    lua_pushboolean(L, false);
    return 1;
  }
  GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
  if (!viewport_ref(session, col, row, &ref)) {
    lua_pushboolean(L, false);
    return 1;
  }
  GhosttySelectionGestureEvent event = session->selection_drag;
  if (strcmp(kind, "press") == 0) event = session->selection_press;
  else if (strcmp(kind, "release") == 0) event = session->selection_release;
  ghostty_selection_gesture_event_set(
    event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref
  );
  if (event != session->selection_release) {
    GhosttySurfacePosition position = { .x = pixel_x, .y = pixel_y };
    ghostty_selection_gesture_event_set(
      event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position
    );
  }
  if (event == session->selection_press) {
    uint64_t now_ns = GetTickCount64() * 1000000ull;
    uint64_t repeat_ns = 500000000ull;
    double repeat_distance = 5.0;
    ghostty_selection_gesture_event_set(
      event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &now_ns
    );
    ghostty_selection_gesture_event_set(
      event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &repeat_ns
    );
    ghostty_selection_gesture_event_set(
      event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE, &repeat_distance
    );
  } else if (event == session->selection_drag) {
    GhosttySelectionGestureGeometry geometry = {
      .columns = session->cols,
      .cell_width = session->cell_width,
      .padding_left = 0,
      .screen_height = session->rows * session->cell_height,
    };
    ghostty_selection_gesture_event_set(
      event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geometry
    );
    ghostty_selection_gesture_event_set(
      event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &rectangle
    );
  }
  GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
  GhosttyResult result = ghostty_selection_gesture_event(
    session->selection_gesture, session->terminal, event, &selection
  );
  bool ok = result == GHOSTTY_SUCCESS || result == GHOSTTY_NO_VALUE;
  if (event == session->selection_press && result == GHOSTTY_NO_VALUE) {
    ghostty_terminal_set(session->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, NULL);
  }
  if (result == GHOSTTY_SUCCESS) {
    ok = ghostty_terminal_set(
      session->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection
    ) == GHOSTTY_SUCCESS;
  }
  if (ok) ghostty_render_state_update(session->render_state, session->terminal);
  lua_pushboolean(L, ok);
  GhosttySelectionGestureAutoscroll autoscroll = GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE;
  if (ghostty_selection_gesture_get(
    session->selection_gesture, session->terminal,
    GHOSTTY_SELECTION_GESTURE_DATA_AUTOSCROLL, &autoscroll
  ) == GHOSTTY_SUCCESS) {
    lua_pushstring(L, autoscroll == GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_UP ? "up" :
      autoscroll == GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_DOWN ? "down" : "none");
    return 2;
  }
  return 1;
}

static bool viewport_ref(
  TerminalSession *session, uint16_t x, uint32_t y, GhosttyGridRef *out_ref
) {
  GhosttyPoint point = {
    .tag = GHOSTTY_POINT_TAG_VIEWPORT,
    .value = { .coordinate = { .x = x, .y = y } },
  };
  return ghostty_terminal_grid_ref(session->terminal, point, out_ref) == GHOSTTY_SUCCESS;
}

static int f_terminal_select(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  uint16_t start_x = (uint16_t)luaL_checkinteger(L, 2);
  uint32_t start_y = (uint32_t)luaL_checkinteger(L, 3);
  uint16_t end_x = (uint16_t)luaL_checkinteger(L, 4);
  uint32_t end_y = (uint32_t)luaL_checkinteger(L, 5);
  if (!terminal_model_available(session)) {
    lua_pushboolean(L, false);
    return 1;
  }
  GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
  selection.rectangle = lua_toboolean(L, 6) != 0;
  bool ok = viewport_ref(session, start_x, start_y, &selection.start) &&
    viewport_ref(session, end_x, end_y, &selection.end) &&
    ghostty_terminal_set(
      session->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection
    ) == GHOSTTY_SUCCESS &&
    ghostty_render_state_update(session->render_state, session->terminal) == GHOSTTY_SUCCESS;
  lua_pushboolean(L, ok);
  return 1;
}

static int f_terminal_clear_selection(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  if (!terminal_model_available(session)) {
    lua_pushboolean(L, false);
    return 1;
  }
  GhosttyResult result = ghostty_terminal_set(
    session->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, NULL
  );
  if (result == GHOSTTY_SUCCESS) {
    ghostty_render_state_update(session->render_state, session->terminal);
  }
  lua_pushboolean(L, result == GHOSTTY_SUCCESS);
  return 1;
}

static int f_terminal_reset_selection_gesture(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  if (!terminal_model_available(session)) {
    lua_pushboolean(L, false);
    return 1;
  }
  ghostty_selection_gesture_reset(session->selection_gesture, session->terminal);
  lua_pushboolean(L, true);
  return 1;
}

static int f_terminal_selected_text(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  if (!terminal_model_available(session)) {
    lua_pushnil(L);
    return 1;
  }
  GhosttyTerminalSelectionFormatOptions options =
    GHOSTTY_INIT_SIZED(GhosttyTerminalSelectionFormatOptions);
  options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
  options.unwrap = true;
  options.trim = true;

  size_t length = 0;
  GhosttyResult result = ghostty_terminal_selection_format_buf(
    session->terminal, options, NULL, 0, &length
  );
  if (result == GHOSTTY_NO_VALUE) {
    lua_pushnil(L);
    return 1;
  }
  if (result != GHOSTTY_OUT_OF_SPACE || length == 0) {
    lua_pushliteral(L, "");
    return 1;
  }

  uint8_t *buffer = (uint8_t *)HeapAlloc(GetProcessHeap(), 0, length);
  if (!buffer) {
    lua_pushnil(L);
    return 1;
  }
  result = ghostty_terminal_selection_format_buf(
    session->terminal, options, buffer, length, &length
  );
  if (result == GHOSTTY_SUCCESS) lua_pushlstring(L, (const char *)buffer, length);
  else lua_pushnil(L);
  HeapFree(GetProcessHeap(), 0, buffer);
  return 1;
}

static int push_capture_error(lua_State *L, const char *message) {
  lua_pushnil(L);
  lua_pushstring(L, message);
  return 2;
}

static size_t utf8_length_for_codepoint(uint32_t codepoint) {
  if (codepoint <= 0x7f) return 1;
  if (codepoint <= 0x7ff) return 2;
  if (codepoint <= 0xffff) return 3;
  return codepoint <= 0x10ffff ? 4 : 0;
}

static size_t terminal_cursor_byte_offset(
  TerminalSession *session, size_t screen_row, uint16_t cursor_x, bool pending_wrap
) {
  size_t offset = 0;
  uint16_t end = cursor_x;
  if (pending_wrap && end < session->cols) end++;
  for (uint16_t col = 0; col < end && col < session->cols; col++) {
    GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
    GhosttyPoint point = {
      .tag = GHOSTTY_POINT_TAG_SCREEN,
      .value = { .coordinate = { .x = col, .y = (uint32_t)screen_row } },
    };
    if (ghostty_terminal_grid_ref(session->terminal, point, &ref) != GHOSTTY_SUCCESS) {
      continue;
    }
    GhosttyCell cell = 0;
    GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
    if (ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS) {
      ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide);
    }
    if (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL ||
        wide == GHOSTTY_CELL_WIDE_SPACER_HEAD) continue;
    uint32_t graphemes[16];
    size_t grapheme_count = 0;
    if (ghostty_grid_ref_graphemes(
        &ref, graphemes, 16, &grapheme_count
      ) == GHOSTTY_SUCCESS && grapheme_count > 0) {
      for (size_t index = 0; index < grapheme_count; index++) {
        offset += utf8_length_for_codepoint(graphemes[index]);
      }
    } else {
      offset++;
    }
  }
  return offset;
}

static size_t capture_line_length(
  const uint8_t *text, size_t length, size_t target_line
) {
  size_t start = 0;
  size_t line = 1;
  while (line < target_line && start < length) {
    const uint8_t *newline = memchr(text + start, '\n', length - start);
    if (!newline) {
      start = length;
      break;
    }
    start = (size_t)(newline - text) + 1;
    line++;
  }
  size_t end = start;
  while (end < length && text[end] != '\n') end++;
  if (end > start && text[end - 1] == '\r') end--;
  return end - start;
}

typedef struct {
  size_t start_offset;
  size_t end_offset;
  uint32_t foreground;
  uint32_t background;
  uint32_t underline_color;
  int underline;
  bool active;
  bool has_background;
  bool has_underline_color;
  bool bold;
  bool italic;
  bool faint;
  bool strikethrough;
} TerminalCaptureStyleRun;

static GhosttyColorRgb capture_style_color(
  GhosttyStyleColor color, GhosttyColorRgb fallback,
  const GhosttyRenderStateColors *colors
) {
  if (color.tag == GHOSTTY_STYLE_COLOR_RGB) return color.value.rgb;
  if (color.tag == GHOSTTY_STYLE_COLOR_PALETTE) {
    return colors->palette[color.value.palette];
  }
  return fallback;
}

static void read_capture_style(
  const GhosttyGridRef *ref, const GhosttyRenderStateColors *colors,
  TerminalCaptureStyleRun *run
) {
  GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);
  if (ghostty_grid_ref_style(ref, &style) != GHOSTTY_SUCCESS) {
    ghostty_style_default(&style);
  }
  GhosttyColorRgb foreground = capture_style_color(
    style.fg_color, colors->foreground, colors
  );
  GhosttyColorRgb background = capture_style_color(
    style.bg_color, colors->background, colors
  );
  run->has_background = style.bg_color.tag != GHOSTTY_STYLE_COLOR_NONE;
  if (style.inverse) {
    GhosttyColorRgb swap = foreground;
    foreground = background;
    background = swap;
    run->has_background = true;
  }
  run->foreground = color_value(foreground);
  run->background = color_value(background);
  run->bold = style.bold;
  run->italic = style.italic;
  run->faint = style.faint;
  run->underline = style.underline;
  run->strikethrough = style.strikethrough;
  if (style.underline_color.tag != GHOSTTY_STYLE_COLOR_NONE) {
    run->has_underline_color = true;
    run->underline_color = color_value(capture_style_color(
      style.underline_color, foreground, colors
    ));
  }
}

static bool same_capture_style(
  const TerminalCaptureStyleRun *left, const TerminalCaptureStyleRun *right
) {
  return left->foreground == right->foreground &&
    left->has_background == right->has_background &&
    (!left->has_background || left->background == right->background) &&
    left->bold == right->bold && left->italic == right->italic &&
    left->faint == right->faint && left->underline == right->underline &&
    left->strikethrough == right->strikethrough &&
    left->has_underline_color == right->has_underline_color &&
    (!left->has_underline_color ||
      left->underline_color == right->underline_color);
}

static void flush_capture_style(
  lua_State *L, int line_styles_index, int *run_count,
  TerminalCaptureStyleRun *run
) {
  if (!run->active || run->end_offset <= run->start_offset) return;
  lua_createtable(L, 0, 11);
  set_integer_field(L, "col1", (lua_Integer)run->start_offset + 1);
  set_integer_field(L, "col2", (lua_Integer)run->end_offset + 1);
  set_integer_field(L, "fg", run->foreground);
  if (run->has_background) {
    set_integer_field(L, "background", run->background);
  }
  if (run->bold) set_boolean_field(L, "bold", true);
  if (run->italic) set_boolean_field(L, "italic", true);
  if (run->faint) set_boolean_field(L, "faint", true);
  if (run->underline) set_integer_field(L, "underline", run->underline);
  if (run->strikethrough) set_boolean_field(L, "strikethrough", true);
  if (run->has_underline_color) {
    set_integer_field(L, "underline_color", run->underline_color);
  }
  lua_rawseti(L, line_styles_index, ++*run_count);
  run->active = false;
}

static void push_capture_styles(
  lua_State *L, TerminalSession *session,
  const GhosttyRenderStateColors *colors,
  const uint8_t *text, size_t length, size_t total_rows
) {
  lua_createtable(L, 0, 0);
  int styles_index = lua_absindex(L, -1);
  size_t text_offset = 0;

  for (size_t row = 0; row < total_rows; row++) {
    size_t line_start = text_offset;
    const uint8_t *newline = line_start < length
      ? memchr(text + line_start, '\n', length - line_start) : NULL;
    size_t line_end = newline ? (size_t)(newline - text) : length;
    if (line_end > line_start && text[line_end - 1] == '\r') line_end--;
    size_t line_length = line_end - line_start;
    text_offset = newline ? (size_t)(newline - text) + 1 : length;
    if (line_length == 0) continue;

    lua_createtable(L, 4, 0);
    int line_styles_index = lua_absindex(L, -1);
    TerminalCaptureStyleRun active = {0};
    int run_count = 0;
    size_t byte_offset = 0;

    for (uint16_t col = 0;
         col < session->cols && byte_offset < line_length; col++) {
      GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
      GhosttyPoint point = {
        .tag = GHOSTTY_POINT_TAG_SCREEN,
        .value = { .coordinate = { .x = col, .y = (uint32_t)row } },
      };
      if (ghostty_terminal_grid_ref(
          session->terminal, point, &ref
        ) != GHOSTTY_SUCCESS) continue;

      GhosttyCell cell = 0;
      GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
      if (ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS) {
        ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide);
      }
      if (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL ||
          wide == GHOSTTY_CELL_WIDE_SPACER_HEAD) continue;

      uint32_t graphemes[16];
      size_t grapheme_count = 0;
      size_t cell_length = 0;
      if (ghostty_grid_ref_graphemes(
          &ref, graphemes, 16, &grapheme_count
        ) == GHOSTTY_SUCCESS && grapheme_count > 0) {
        for (size_t index = 0; index < grapheme_count; index++) {
          cell_length += utf8_length_for_codepoint(graphemes[index]);
        }
      } else {
        cell_length = 1;
      }
      if (cell_length > line_length - byte_offset) {
        cell_length = line_length - byte_offset;
      }

      TerminalCaptureStyleRun current = {
        .start_offset = byte_offset,
        .end_offset = byte_offset + cell_length,
        .active = true,
      };
      read_capture_style(&ref, colors, &current);
      if (!active.active || !same_capture_style(&active, &current)) {
        flush_capture_style(
          L, line_styles_index, &run_count, &active
        );
        active = current;
      } else {
        active.end_offset = current.end_offset;
      }
      byte_offset += cell_length;
    }
    flush_capture_style(L, line_styles_index, &run_count, &active);
    lua_rawseti(L, styles_index, (lua_Integer)row + 1);
  }
}

static int f_terminal_text_capture(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  if (session->closed || !session->terminal) {
    return push_capture_error(L, "Terminal session is closed");
  }

  size_t total_rows = 0;
  size_t scrollback_rows = 0;
  uint16_t cursor_x = 0;
  uint16_t cursor_y = 0;
  bool pending_wrap = false;
  GhosttyTerminalScrollbar scrollbar = {0};
  GhosttyRenderStateColors colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
  if (ghostty_terminal_get(
      session->terminal, GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &total_rows
    ) != GHOSTTY_SUCCESS || total_rows == 0 ||
      ghostty_terminal_get(
        session->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &scrollback_rows
      ) != GHOSTTY_SUCCESS ||
      ghostty_terminal_get(
        session->terminal, GHOSTTY_TERMINAL_DATA_CURSOR_X, &cursor_x
      ) != GHOSTTY_SUCCESS ||
      ghostty_terminal_get(
        session->terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &cursor_y
      ) != GHOSTTY_SUCCESS ||
      ghostty_terminal_get(
        session->terminal, GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP, &pending_wrap
      ) != GHOSTTY_SUCCESS ||
      ghostty_terminal_get(
        session->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar
      ) != GHOSTTY_SUCCESS ||
      ghostty_render_state_colors_get(
        session->render_state, &colors
      ) != GHOSTTY_SUCCESS) {
    return push_capture_error(L, "Could not read terminal capture state");
  }

  GhosttyPoint start_point = {
    .tag = GHOSTTY_POINT_TAG_SCREEN,
    .value = { .coordinate = { .x = 0, .y = 0 } },
  };
  GhosttyPoint end_point = {
    .tag = GHOSTTY_POINT_TAG_SCREEN,
    .value = { .coordinate = {
      .x = (uint16_t)(session->cols - 1),
      .y = (uint32_t)(total_rows - 1),
    } },
  };
  GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
  if (ghostty_terminal_grid_ref(
      session->terminal, start_point, &selection.start
    ) != GHOSTTY_SUCCESS ||
      ghostty_terminal_grid_ref(
        session->terminal, end_point, &selection.end
      ) != GHOSTTY_SUCCESS) {
    return push_capture_error(L, "Could not resolve terminal capture rows");
  }

  GhosttyTerminalSelectionFormatOptions options =
    GHOSTTY_INIT_SIZED(GhosttyTerminalSelectionFormatOptions);
  options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
  options.unwrap = false;
  options.trim = true;
  options.selection = &selection;
  size_t length = 0;
  GhosttyResult result = ghostty_terminal_selection_format_buf(
    session->terminal, options, NULL, 0, &length
  );
  if (result != GHOSTTY_OUT_OF_SPACE && result != GHOSTTY_SUCCESS) {
    return push_capture_error(L, "Could not measure terminal text");
  }
  uint8_t *text = NULL;
  if (length > 0) {
    text = (uint8_t *)HeapAlloc(GetProcessHeap(), 0, length);
    if (!text) return push_capture_error(L, "Could not allocate terminal text");
    result = ghostty_terminal_selection_format_buf(
      session->terminal, options, text, length, &length
    );
    if (result != GHOSTTY_SUCCESS) {
      HeapFree(GetProcessHeap(), 0, text);
      return push_capture_error(L, "Could not format terminal text");
    }
  }

  size_t cursor_screen_row = scrollback_rows + cursor_y;
  if (cursor_screen_row >= total_rows) cursor_screen_row = total_rows - 1;
  bool cursor_in_viewport = cursor_screen_row >= scrollbar.offset &&
    cursor_screen_row < scrollbar.offset + scrollbar.len;
  size_t capture_cursor_row = cursor_in_viewport
    ? cursor_screen_row : (size_t)scrollbar.offset;
  uint16_t capture_cursor_x = cursor_in_viewport ? cursor_x : 0;
  size_t line_length = capture_line_length(
    text ? text : (const uint8_t *)"", length, capture_cursor_row + 1
  );
  size_t cursor_offset = terminal_cursor_byte_offset(
    session, capture_cursor_row, capture_cursor_x,
    cursor_in_viewport && pending_wrap
  );
  if (cursor_offset > line_length) cursor_offset = line_length;

  lua_createtable(L, 0, 10);
  int capture_index = lua_absindex(L, -1);
  lua_pushlstring(L, text ? (const char *)text : "", length);
  lua_setfield(L, -2, "text");
  set_integer_field(L, "foreground", color_value(colors.foreground));
  set_integer_field(L, "background", color_value(colors.background));
  set_integer_field(L, "cursor_line", (lua_Integer)capture_cursor_row + 1);
  set_integer_field(L, "cursor_col", (lua_Integer)cursor_offset + 1);
  set_integer_field(L, "viewport_line", (lua_Integer)scrollbar.offset + 1);
  set_integer_field(L, "columns", session->cols);
  set_integer_field(L, "rows", session->rows);
  set_integer_field(L, "total_rows", (lua_Integer)total_rows);
  push_capture_styles(
    L, session, &colors, text ? text : (const uint8_t *)"", length,
    total_rows
  );
  lua_setfield(L, capture_index, "styles");
  if (text) HeapFree(GetProcessHeap(), 0, text);
  return 1;
}

static bool byte_match(
  const uint8_t *text, size_t text_length, const char *query, size_t query_length,
  size_t begin, size_t end, bool reverse, size_t *match_col
) {
  if (query_length == 0 || query_length > text_length) return false;
  end = end > text_length ? text_length : end;
  begin = begin > end ? end : begin;
  if (!reverse) {
    for (size_t index = begin; index + query_length <= end; index++) {
      if (memcmp(text + index, query, query_length) == 0) {
        *match_col = index;
        return true;
      }
    }
  } else if (end >= query_length) {
    for (size_t index = end - query_length + 1; index-- > begin;) {
      if (memcmp(text + index, query, query_length) == 0) {
        *match_col = index;
        return true;
      }
    }
  }
  return false;
}

static size_t append_utf8(uint8_t *buffer, size_t capacity, size_t length, uint32_t codepoint) {
  if (codepoint <= 0x7f && length + 1 <= capacity) buffer[length++] = (uint8_t)codepoint;
  else if (codepoint <= 0x7ff && length + 2 <= capacity) {
    buffer[length++] = (uint8_t)(0xc0 | (codepoint >> 6));
    buffer[length++] = (uint8_t)(0x80 | (codepoint & 0x3f));
  } else if (codepoint <= 0xffff && length + 3 <= capacity) {
    buffer[length++] = (uint8_t)(0xe0 | (codepoint >> 12));
    buffer[length++] = (uint8_t)(0x80 | ((codepoint >> 6) & 0x3f));
    buffer[length++] = (uint8_t)(0x80 | (codepoint & 0x3f));
  } else if (codepoint <= 0x10ffff && length + 4 <= capacity) {
    buffer[length++] = (uint8_t)(0xf0 | (codepoint >> 18));
    buffer[length++] = (uint8_t)(0x80 | ((codepoint >> 12) & 0x3f));
    buffer[length++] = (uint8_t)(0x80 | ((codepoint >> 6) & 0x3f));
    buffer[length++] = (uint8_t)(0x80 | (codepoint & 0x3f));
  }
  return length;
}

static int f_terminal_row_text(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  uint32_t row = (uint32_t)luaL_checkinteger(L, 2);
  if (!terminal_model_available(session) || row >= session->rows) {
    lua_pushnil(L);
    return 1;
  }
  size_t capacity = (size_t)session->cols * 64u;
  if (capacity > 65536u) capacity = 65536u;
  uint8_t *text = (uint8_t *)HeapAlloc(GetProcessHeap(), 0, capacity ? capacity : 1);
  uint16_t *columns = (uint16_t *)HeapAlloc(
    GetProcessHeap(), 0, (capacity ? capacity : 1) * sizeof(*columns)
  );
  if (!text || !columns) {
    if (text) HeapFree(GetProcessHeap(), 0, text);
    if (columns) HeapFree(GetProcessHeap(), 0, columns);
    return luaL_error(L, "Could not allocate a terminal row query");
  }
  size_t length = 0;
  for (uint16_t col = 0; col < session->cols && length < capacity; col++) {
    GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
    if (!viewport_ref(session, col, row, &ref)) continue;
    GhosttyCell cell = 0;
    GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
    if (ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS) {
      ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide);
    }
    if (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL ||
        wide == GHOSTTY_CELL_WIDE_SPACER_HEAD) continue;
    size_t start = length;
    uint32_t graphemes[16];
    size_t count = 0;
    if (ghostty_grid_ref_graphemes(
        &ref, graphemes, 16, &count
      ) == GHOSTTY_SUCCESS && count > 0) {
      for (size_t index = 0; index < count; index++) {
        length = append_utf8(text, capacity, length, graphemes[index]);
      }
    } else if (length < capacity) {
      text[length++] = ' ';
    }
    for (size_t index = start; index < length; index++) columns[index] = col;
  }
  while (length > 0 && text[length - 1] == ' ') length--;
  lua_createtable(L, 0, 3);
  lua_pushlstring(L, (const char *)text, length);
  lua_setfield(L, -2, "text");
  lua_createtable(L, (int)length, 0);
  for (size_t index = 0; index < length; index++) {
    lua_pushinteger(L, columns[index]);
    lua_rawseti(L, -2, (lua_Integer)index + 1);
  }
  lua_setfield(L, -2, "columns");
  set_integer_field(L, "generation", (lua_Integer)session->render_generation);
  HeapFree(GetProcessHeap(), 0, text);
  HeapFree(GetProcessHeap(), 0, columns);
  return 1;
}

static int f_terminal_search(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  size_t query_length = 0;
  const char *query = luaL_checklstring(L, 2, &query_length);
  bool reverse = lua_toboolean(L, 3) != 0;
  if (!terminal_model_available(session)) {
    lua_pushboolean(L, false);
    return 1;
  }
  if (query_length == 0) {
    lua_pushboolean(L, false);
    return 1;
  }
  bool resume = session->search_scan_active &&
    session->search_scan_generation == session->render_generation &&
    session->search_scan_reverse == reverse &&
    session->search_scan_query_length == query_length &&
    memcmp(session->search_scan_query, query, query_length) == 0;
  if (!resume) {
    char *scan_query = session->search_scan_query
      ? (char *)HeapReAlloc(GetProcessHeap(), 0, session->search_scan_query, query_length)
      : (char *)HeapAlloc(GetProcessHeap(), 0, query_length);
    if (!scan_query) return luaL_error(L, "Could not allocate terminal search query");
    memcpy(scan_query, query, query_length);
    session->search_scan_query = scan_query;
    session->search_scan_query_length = query_length;
    session->search_scan_reverse = reverse;
    session->search_scan_continuing = session->search_query &&
      session->search_query_length == query_length &&
      memcmp(session->search_query, query, query_length) == 0;
    session->search_scan_total_rows = 0;
    ghostty_terminal_get(
      session->terminal, GHOSTTY_TERMINAL_DATA_TOTAL_ROWS,
      &session->search_scan_total_rows
    );
    session->search_scan_start_row = session->search_scan_continuing
      ? session->search_row
      : (reverse && session->search_scan_total_rows > 0
          ? session->search_scan_total_rows - 1 : 0);
    session->search_scan_step = 0;
    session->search_scan_active = true;
    session->search_scan_generation = session->render_generation;
  }
  size_t total_rows = session->search_scan_total_rows;
  bool continuing = session->search_scan_continuing;
  size_t start_row = session->search_scan_start_row;
  size_t row_capacity = (size_t)session->cols * 64;
  uint8_t *row_text = (uint8_t *)HeapAlloc(GetProcessHeap(), 0, row_capacity);
  uint16_t *byte_cols = (uint16_t *)HeapAlloc(
    GetProcessHeap(), 0, row_capacity * sizeof(*byte_cols)
  );
  if (!row_text || !byte_cols) {
    if (row_text) HeapFree(GetProcessHeap(), 0, row_text);
    if (byte_cols) HeapFree(GetProcessHeap(), 0, byte_cols);
    return luaL_error(L, "Could not allocate terminal search row");
  }
  bool found = false;
  size_t found_row = 0, found_col = 0, found_end_col = 0;
  uint64_t scan_started = GetTickCount64();
  for (; session->search_scan_step < total_rows; session->search_scan_step++) {
    size_t step = session->search_scan_step;
    size_t row = reverse
      ? (start_row + total_rows - step) % total_rows
      : (start_row + step) % total_rows;
    size_t length = 0;
    for (uint16_t col = 0; col < session->cols; col++) {
      GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
      GhosttyPoint point = {
        .tag = GHOSTTY_POINT_TAG_SCREEN,
        .value = { .coordinate = { .x = col, .y = (uint32_t)row } },
      };
      if (ghostty_terminal_grid_ref(session->terminal, point, &ref) != GHOSTTY_SUCCESS) continue;
      GhosttyCell raw_cell = 0;
      GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
      if (ghostty_grid_ref_cell(&ref, &raw_cell) == GHOSTTY_SUCCESS) {
        ghostty_cell_get(raw_cell, GHOSTTY_CELL_DATA_WIDE, &wide);
      }
      if (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL ||
          wide == GHOSTTY_CELL_WIDE_SPACER_HEAD) continue;
      uint32_t grapheme[16];
      size_t grapheme_length = 0;
      size_t cell_start = length;
      GhosttyResult grapheme_result = ghostty_grid_ref_graphemes(
        &ref, grapheme, 16, &grapheme_length
      );
      if (grapheme_result == GHOSTTY_SUCCESS && grapheme_length > 0) {
        for (size_t index = 0; index < grapheme_length; index++) {
          length = append_utf8(row_text, row_capacity, length, grapheme[index]);
        }
      } else if (grapheme_result == GHOSTTY_SUCCESS) {
        row_text[length++] = ' ';
      }
      for (size_t index = cell_start; index < length; index++) byte_cols[index] = col;
    }
    size_t match_offset = 0;
    size_t begin = 0, end = length;
    if (continuing && step == 0 && row == session->search_row) {
      size_t current_byte = 0;
      while (current_byte < length && byte_cols[current_byte] <= session->search_col) current_byte++;
      if (reverse) end = current_byte > 0 ? current_byte - 1 : 0;
      else begin = current_byte;
    }
    if (byte_match(row_text, length, query, query_length, begin, end, reverse, &match_offset)) {
      found = true;
      found_row = row;
      found_col = byte_cols[match_offset];
      found_end_col = byte_cols[match_offset + query_length - 1];
      break;
    }
    if (GetTickCount64() - scan_started >= 8) {
      session->search_scan_step++;
      HeapFree(GetProcessHeap(), 0, row_text);
      HeapFree(GetProcessHeap(), 0, byte_cols);
      lua_pushboolean(L, false);
      lua_pushliteral(L, "pending");
      return 2;
    }
  }
  HeapFree(GetProcessHeap(), 0, row_text);
  HeapFree(GetProcessHeap(), 0, byte_cols);
  if (!found) {
    session->search_scan_active = false;
    lua_pushboolean(L, false);
    lua_pushliteral(L, "not_found");
    return 2;
  }
  session->search_scan_active = false;
  char *saved = session->search_query
    ? (char *)HeapReAlloc(GetProcessHeap(), 0, session->search_query, query_length)
    : (char *)HeapAlloc(GetProcessHeap(), 0, query_length);
  if (saved) {
    memcpy(saved, query, query_length);
    session->search_query = saved;
    session->search_query_length = query_length;
    session->search_row = found_row;
    session->search_col = found_col;
  }
  GhosttyTerminalScrollViewport viewport = {
    .tag = GHOSTTY_SCROLL_VIEWPORT_ROW,
    .value = { .row = found_row },
  };
  ghostty_terminal_scroll_viewport(session->terminal, viewport);
  GhosttyGridRef start_ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
  GhosttyGridRef end_ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
  GhosttyPoint start_point = {
    .tag = GHOSTTY_POINT_TAG_SCREEN,
    .value = { .coordinate = { .x = (uint16_t)found_col, .y = (uint32_t)found_row } },
  };
  GhosttyPoint end_point = {
    .tag = GHOSTTY_POINT_TAG_SCREEN,
    .value = { .coordinate = {
      .x = (uint16_t)found_end_col,
      .y = (uint32_t)found_row
    } },
  };
  if (ghostty_terminal_grid_ref(session->terminal, start_point, &start_ref) != GHOSTTY_SUCCESS ||
      ghostty_terminal_grid_ref(session->terminal, end_point, &end_ref) != GHOSTTY_SUCCESS) {
    lua_pushboolean(L, false);
    return 1;
  }
  GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
  selection.start = start_ref;
  selection.end = end_ref;
  if (ghostty_terminal_set(
    session->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection
  ) != GHOSTTY_SUCCESS) {
    lua_pushboolean(L, false);
    return 1;
  }
  ghostty_render_state_update(session->render_state, session->terminal);
  lua_pushboolean(L, true);
  lua_pushinteger(L, (lua_Integer)found_row);
  return 2;
}

static GhosttyMouseButton mouse_button_from_name(const char *name) {
  if (strcmp(name, "left") == 0) return GHOSTTY_MOUSE_BUTTON_LEFT;
  if (strcmp(name, "right") == 0) return GHOSTTY_MOUSE_BUTTON_RIGHT;
  if (strcmp(name, "middle") == 0) return GHOSTTY_MOUSE_BUTTON_MIDDLE;
  if (strcmp(name, "four") == 0) return GHOSTTY_MOUSE_BUTTON_FOUR;
  if (strcmp(name, "five") == 0) return GHOSTTY_MOUSE_BUTTON_FIVE;
  return GHOSTTY_MOUSE_BUTTON_UNKNOWN;
}

static int f_terminal_mouse(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  const char *action_name = luaL_checkstring(L, 2);
  const char *button_name = luaL_optstring(L, 3, "");
  float x = (float)luaL_checknumber(L, 4);
  float y = (float)luaL_checknumber(L, 5);
  luaL_checktype(L, 6, LUA_TTABLE);
  if (!terminal_is_live(session)) {
    lua_pushboolean(L, false);
    return 1;
  }

  GhosttyMouseAction action = GHOSTTY_MOUSE_ACTION_MOTION;
  if (strcmp(action_name, "press") == 0) action = GHOSTTY_MOUSE_ACTION_PRESS;
  else if (strcmp(action_name, "release") == 0) action = GHOSTTY_MOUSE_ACTION_RELEASE;
  GhosttyMouseButton button = mouse_button_from_name(button_name);

  GhosttyMods mods = 0;
  if (table_bool(L, 6, "shift")) mods |= GHOSTTY_MODS_SHIFT;
  if (table_bool(L, 6, "ctrl")) mods |= GHOSTTY_MODS_CTRL;
  if (table_bool(L, 6, "alt")) mods |= GHOSTTY_MODS_ALT;
  if (table_bool(L, 6, "super")) mods |= GHOSTTY_MODS_SUPER;

  GhosttyMouseEncoderSize size = GHOSTTY_INIT_SIZED(GhosttyMouseEncoderSize);
  size.screen_width = session->cols * session->cell_width;
  size.screen_height = session->rows * session->cell_height;
  size.cell_width = session->cell_width;
  size.cell_height = session->cell_height;
  ghostty_mouse_encoder_setopt_from_terminal(session->mouse_encoder, session->terminal);
  bool wheel = button == GHOSTTY_MOUSE_BUTTON_FOUR || button == GHOSTTY_MOUSE_BUTTON_FIVE;
  if (!wheel && action == GHOSTTY_MOUSE_ACTION_PRESS) session->mouse_button_pressed = true;
  if (!wheel && action == GHOSTTY_MOUSE_ACTION_RELEASE) session->mouse_button_pressed = false;
  ghostty_mouse_encoder_setopt(
    session->mouse_encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size
  );
  ghostty_mouse_encoder_setopt(
    session->mouse_encoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED,
    &session->mouse_button_pressed
  );
  ghostty_mouse_event_set_action(session->mouse_event, action);
  if (button == GHOSTTY_MOUSE_BUTTON_UNKNOWN) ghostty_mouse_event_clear_button(session->mouse_event);
  else ghostty_mouse_event_set_button(session->mouse_event, button);
  ghostty_mouse_event_set_mods(session->mouse_event, mods);
  ghostty_mouse_event_set_position(
    session->mouse_event, (GhosttyMousePosition){ .x = x, .y = y }
  );

  char encoded[128];
  size_t written = 0;
  GhosttyResult result = ghostty_mouse_encoder_encode(
    session->mouse_encoder, session->mouse_event, encoded, sizeof(encoded), &written
  );
  bool ok = result == GHOSTTY_SUCCESS && (written == 0 || write_all(
    session, (const uint8_t *)encoded, written
  ));
  lua_pushboolean(L, ok);
  lua_pushboolean(L, written > 0);
  return 2;
}

static int f_terminal_hyperlink(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  uint16_t col = (uint16_t)luaL_checkinteger(L, 2);
  uint32_t row = (uint32_t)luaL_checkinteger(L, 3);
  if (!terminal_model_available(session)) {
    lua_pushnil(L);
    return 1;
  }
  GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
  if (!viewport_ref(session, col, row, &ref)) {
    lua_pushnil(L);
    return 1;
  }
  size_t length = 0;
  GhosttyResult result = ghostty_grid_ref_hyperlink_uri(&ref, NULL, 0, &length);
  if (result != GHOSTTY_OUT_OF_SPACE || length == 0 ||
      length > TERMINAL_HYPERLINK_MAX_BYTES) {
    lua_pushnil(L);
    return 1;
  }
  uint8_t *buffer = (uint8_t *)HeapAlloc(GetProcessHeap(), 0, length);
  if (!buffer) return luaL_error(L, "Could not allocate terminal hyperlink");
  result = ghostty_grid_ref_hyperlink_uri(&ref, buffer, length, &length);
  if (result == GHOSTTY_SUCCESS) lua_pushlstring(L, (const char *)buffer, length);
  else lua_pushnil(L);
  HeapFree(GetProcessHeap(), 0, buffer);
  return 1;
}

static int f_terminal_focus(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  bool focused = lua_toboolean(L, 2) != 0;
  if (!terminal_model_available(session)) {
    lua_pushboolean(L, false);
    return 1;
  }
  GhosttyTerminalModeConfig mode = {
    .mode = GHOSTTY_MODE_FOCUS_EVENT,
    .value = false,
  };
  GhosttyResult result = ghostty_terminal_get(
    session->terminal, GHOSTTY_TERMINAL_DATA_MODE, &mode
  );
  bool ok = result == GHOSTTY_SUCCESS;
  if (ok && mode.value) {
    static const uint8_t focus_in[] = "\x1b[I";
    static const uint8_t focus_out[] = "\x1b[O";
    ok = focused
      ? write_all(session, focus_in, sizeof(focus_in) - 1)
      : write_all(session, focus_out, sizeof(focus_out) - 1);
  }
  lua_pushboolean(L, ok);
  return 1;
}

static uint32_t color_value(GhosttyColorRgb color) {
  return ((uint32_t)color.r << 16) | ((uint32_t)color.g << 8) | color.b;
}

static void set_integer_field(lua_State *L, const char *name, lua_Integer value) {
  lua_pushinteger(L, value);
  lua_setfield(L, -2, name);
}

static void set_boolean_field(lua_State *L, const char *name, bool value) {
  lua_pushboolean(L, value);
  lua_setfield(L, -2, name);
}

static void push_cursor(lua_State *L, TerminalSession *session, GhosttyRenderStateColors *colors) {
  bool visible = false;
  bool in_viewport = false;
  bool blinking = false;
  uint16_t x = 0;
  uint16_t y = 0;
  GhosttyRenderStateCursorVisualStyle style = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
  ghostty_render_state_get(session->render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &visible);
  ghostty_render_state_get(
    session->render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &in_viewport
  );
  if (in_viewport) {
    ghostty_render_state_get(session->render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &x);
    ghostty_render_state_get(session->render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &y);
  }
  ghostty_render_state_get(
    session->render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &style
  );
  ghostty_render_state_get(
    session->render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING, &blinking
  );

  lua_createtable(L, 0, 5);
  set_boolean_field(L, "visible", visible && in_viewport);
  set_boolean_field(L, "blinking", blinking);
  set_integer_field(L, "x", x);
  set_integer_field(L, "y", y);
  set_integer_field(L, "color", color_value(colors->cursor_has_value ? colors->cursor : colors->foreground));
  const char *style_name = "block";
  if (style == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR) style_name = "bar";
  else if (style == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE) style_name = "underline";
  else if (style == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW) style_name = "hollow";
  lua_pushstring(L, style_name);
  lua_setfield(L, -2, "style");
}

typedef struct {
  uint8_t utf8[128];
  size_t text_length;
  uint32_t foreground;
  uint32_t background;
  int underline;
  uint8_t columns;
  bool has_text;
  bool has_background;
  bool selected;
  bool bold;
  bool italic;
  bool faint;
  bool blink;
  bool overline;
  bool invisible;
  bool strikethrough;
  bool underline_color_has_value;
  uint32_t underline_color;
} TerminalRenderCell;

typedef struct {
  uint8_t *text;
  size_t text_length;
  int start_col;
  int end_col;
  uint32_t foreground;
  int underline;
  bool active;
  bool bold;
  bool italic;
  bool faint;
  bool blink;
  bool overline;
  bool strikethrough;
  bool underline_color_has_value;
  uint32_t underline_color;
} TerminalTextRun;

typedef struct {
  int start_col;
  uint32_t color;
  bool active;
  bool selected;
} TerminalBackgroundSpan;

static void read_render_cell(
  TerminalSession *session, GhosttyRenderStateColors *colors, TerminalRenderCell *cell
) {
  memset(cell, 0, sizeof(*cell));
  uint8_t utf8[128];
  GhosttyBuffer grapheme = { .ptr = utf8, .cap = sizeof(utf8), .len = 0 };
  GhosttyColorRgb foreground = colors->foreground;
  GhosttyColorRgb background = colors->background;
  GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);
  GhosttyCell raw_cell = 0;
  GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;

  GhosttyResult text_result = ghostty_render_state_row_cells_get(
    session->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &grapheme
  );
  GhosttyResult fg_result = ghostty_render_state_row_cells_get(
    session->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &foreground
  );
  GhosttyResult bg_result = ghostty_render_state_row_cells_get(
    session->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &background
  );
  ghostty_render_state_row_cells_get(
    session->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style
  );
  if (ghostty_render_state_row_cells_get(
    session->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw_cell
  ) == GHOSTTY_SUCCESS && raw_cell) {
    ghostty_cell_get(raw_cell, GHOSTTY_CELL_DATA_WIDE, &wide);
  }

  cell->has_text = text_result == GHOSTTY_SUCCESS && grapheme.len > 0;
  cell->has_background = bg_result == GHOSTTY_SUCCESS;
  if (fg_result != GHOSTTY_SUCCESS) foreground = colors->foreground;
  if (bg_result != GHOSTTY_SUCCESS) background = colors->background;
  if (style.inverse) {
    GhosttyColorRgb swap = foreground;
    foreground = background;
    background = swap;
    cell->has_background = true;
  }
  if (cell->has_text) {
    memcpy(cell->utf8, utf8, grapheme.len);
    cell->text_length = grapheme.len;
  }
  cell->foreground = color_value(foreground);
  cell->background = color_value(background);
  cell->bold = style.bold;
  cell->italic = style.italic;
  cell->faint = style.faint;
  cell->blink = style.blink;
  cell->overline = style.overline;
  cell->invisible = style.invisible;
  cell->strikethrough = style.strikethrough;
  cell->underline = style.underline;
  if (style.underline_color.tag == GHOSTTY_STYLE_COLOR_RGB) {
    cell->underline_color_has_value = true;
    cell->underline_color = color_value(style.underline_color.value.rgb);
  } else if (style.underline_color.tag == GHOSTTY_STYLE_COLOR_PALETTE) {
    cell->underline_color_has_value = true;
    cell->underline_color = color_value(colors->palette[style.underline_color.value.palette]);
  }
  cell->columns = wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : 1;
  if (ghostty_render_state_row_cells_get(
    session->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED, &cell->selected
  ) != GHOSTTY_SUCCESS) cell->selected = false;
}

static bool same_text_run(const TerminalTextRun *run, const TerminalRenderCell *cell) {
  return run->foreground == cell->foreground && run->bold == cell->bold &&
    run->italic == cell->italic && run->underline == cell->underline &&
    run->strikethrough == cell->strikethrough && run->faint == cell->faint &&
    run->blink == cell->blink && run->overline == cell->overline &&
    run->underline_color_has_value == cell->underline_color_has_value &&
    (!run->underline_color_has_value || run->underline_color == cell->underline_color);
}

static void flush_text_run(
  lua_State *L, int runs_index, int *run_count, TerminalTextRun *run
) {
  if (!run->active) return;
  lua_createtable(L, 0, 8);
  lua_pushlstring(L, (const char *)run->text, run->text_length);
  lua_setfield(L, -2, "text");
  set_integer_field(L, "col", run->start_col);
  set_integer_field(L, "columns", run->end_col - run->start_col);
  set_integer_field(L, "fg", run->foreground);
  if (run->bold) set_boolean_field(L, "bold", true);
  if (run->italic) set_boolean_field(L, "italic", true);
  if (run->faint) set_boolean_field(L, "faint", true);
  if (run->blink) set_boolean_field(L, "blink", true);
  if (run->overline) set_boolean_field(L, "overline", true);
  if (run->underline) set_integer_field(L, "underline", run->underline);
  if (run->strikethrough) set_boolean_field(L, "strikethrough", true);
  if (run->underline_color_has_value) {
    set_integer_field(L, "underline_color", run->underline_color);
  }
  lua_rawseti(L, runs_index, ++*run_count);
  run->active = false;
  run->text_length = 0;
}

static void flush_background_span(
  lua_State *L, int backgrounds_index, int *span_count,
  TerminalBackgroundSpan *span, int end_col
) {
  if (!span->active) return;
  lua_createtable(L, 0, 4);
  set_integer_field(L, "col", span->start_col);
  set_integer_field(L, "columns", end_col - span->start_col);
  if (span->selected) set_boolean_field(L, "selected", true);
  else set_integer_field(L, "color", span->color);
  lua_rawseti(L, backgrounds_index, ++*span_count);
  span->active = false;
}

static void push_render_row(
  lua_State *L, TerminalSession *session, GhosttyRenderStateColors *colors
) {
  lua_createtable(L, 0, 2);
  int row_index = lua_absindex(L, -1);
  lua_createtable(L, 8, 0);
  int runs_index = lua_absindex(L, -1);
  lua_createtable(L, 8, 0);
  int backgrounds_index = lua_absindex(L, -1);

  TerminalTextRun run = { .text = session->snapshot_text };
  TerminalBackgroundSpan span = {0};
  int run_count = 0;
  int span_count = 0;
  int col = 0;
  while (ghostty_render_state_row_cells_next(session->row_cells)) {
    TerminalRenderCell cell;
    read_render_cell(session, colors, &cell);

    bool draw_background = cell.selected || cell.has_background;
    uint32_t background_color = cell.background;
    if (!draw_background || (span.active &&
        (span.selected != cell.selected || (!cell.selected && span.color != background_color)))) {
      flush_background_span(L, backgrounds_index, &span_count, &span, col);
    }
    if (draw_background && !span.active) {
      span.active = true;
      span.selected = cell.selected;
      span.color = background_color;
      span.start_col = col;
    }

    bool draw_text = cell.has_text && !cell.invisible;
    if (draw_text) {
      if (!run.active || col != run.end_col || !same_text_run(&run, &cell)) {
        flush_text_run(L, runs_index, &run_count, &run);
        run.active = true;
        run.start_col = col;
        run.end_col = col;
        run.foreground = cell.foreground;
        run.bold = cell.bold;
        run.italic = cell.italic;
        run.faint = cell.faint;
        run.blink = cell.blink;
        run.overline = cell.overline;
        run.underline = cell.underline;
        run.strikethrough = cell.strikethrough;
        run.underline_color_has_value = cell.underline_color_has_value;
        run.underline_color = cell.underline_color;
      }
      memcpy(run.text + run.text_length, cell.utf8, cell.text_length);
      run.text_length += cell.text_length;
      run.end_col = col + cell.columns;
    } else if (run.active && col >= run.end_col) {
      flush_text_run(L, runs_index, &run_count, &run);
    }
    col++;
  }
  flush_text_run(L, runs_index, &run_count, &run);
  flush_background_span(L, backgrounds_index, &span_count, &span, col);

  lua_setfield(L, row_index, "backgrounds");
  lua_setfield(L, row_index, "text_runs");
}

static bool ensure_snapshot_text(TerminalSession *session) {
  size_t capacity = (size_t)session->cols * sizeof(((TerminalRenderCell *)0)->utf8);
  if (session->snapshot_text_capacity >= capacity) return true;
  uint8_t *text = session->snapshot_text
    ? (uint8_t *)HeapReAlloc(GetProcessHeap(), 0, session->snapshot_text, capacity)
    : (uint8_t *)HeapAlloc(GetProcessHeap(), 0, capacity);
  if (!text) return false;
  session->snapshot_text = text;
  session->snapshot_text_capacity = capacity;
  return true;
}

static int f_terminal_snapshot(lua_State *L) {
  TerminalSession *session = check_session(L, 1);
  if (!session->render_state) {
    lua_pushnil(L);
    return 1;
  }

  GhosttyRenderStateColors colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
  if (ghostty_render_state_colors_get(session->render_state, &colors) != GHOSTTY_SUCCESS) {
    lua_pushnil(L);
    return 1;
  }

  bool reuse = lua_istable(L, 2);
  bool include_rows = lua_isnoneornil(L, 3) || lua_toboolean(L, 3) != 0;
  if (reuse) lua_pushvalue(L, 2);
  else lua_createtable(L, 0, 9);
  set_integer_field(L, "cols", session->cols);
  set_integer_field(L, "row_count", session->rows);
  set_integer_field(L, "foreground", color_value(colors.foreground));
  set_integer_field(L, "background", color_value(colors.background));
  set_boolean_field(L, "running", session->state == TERMINAL_STATE_RUNNING);
  lua_pushstring(L, terminal_state_name(session->state));
  lua_setfield(L, -2, "state");
  set_integer_field(L, "generation", (lua_Integer)session->render_generation);
  bool mouse_tracking = false;
  ghostty_terminal_get(
    session->terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &mouse_tracking
  );
  set_boolean_field(L, "mouse_tracking", mouse_tracking);

  GhosttyString title = {0};
  if (ghostty_terminal_get(
    session->terminal, GHOSTTY_TERMINAL_DATA_TITLE, &title
  ) == GHOSTTY_SUCCESS && title.ptr && title.len > 0) {
    lua_pushlstring(L, (const char *)title.ptr, title.len);
    lua_setfield(L, -2, "title");
  }
  GhosttyString pwd = {0};
  if (ghostty_terminal_get(
    session->terminal, GHOSTTY_TERMINAL_DATA_PWD, &pwd
  ) == GHOSTTY_SUCCESS && pwd.ptr && pwd.len > 0) {
    lua_pushlstring(L, (const char *)pwd.ptr, pwd.len);
    lua_setfield(L, -2, "pwd");
  } else {
    lua_pushnil(L);
    lua_setfield(L, -2, "pwd");
  }
  lua_createtable(L, (session->bell_count > 0 ? 1 : 0) +
    (session->clipboard_pending ? 1 : 0) + (session->notification_pending ? 1 : 0), 0);
  int event_count = 0;
  if (session->bell_count > 0) {
    lua_createtable(L, 0, 2);
    lua_pushliteral(L, "bell");
    lua_setfield(L, -2, "type");
    set_integer_field(L, "count", session->bell_count);
    lua_rawseti(L, -2, ++event_count);
    session->bell_count = 0;
  }
  if (session->clipboard_pending) {
    lua_createtable(L, 0, 2);
    lua_pushliteral(L, "clipboard");
    lua_setfield(L, -2, "type");
    lua_pushlstring(
      L, session->clipboard_text ? session->clipboard_text : "",
      session->clipboard_text_length
    );
    lua_setfield(L, -2, "text");
    if (session->clipboard_clear) set_boolean_field(L, "clear", true);
    lua_rawseti(L, -2, ++event_count);
    session->clipboard_pending = false;
  }
  if (session->notification_pending) {
    lua_createtable(L, 0, 3);
    lua_pushliteral(L, "notification");
    lua_setfield(L, -2, "type");
    lua_pushlstring(
      L, session->notification_title, session->notification_title_length
    );
    lua_setfield(L, -2, "title");
    lua_pushlstring(L, session->notification_body, session->notification_body_length);
    lua_setfield(L, -2, "body");
    set_integer_field(L, "count", (lua_Integer)session->notification_count);
    lua_rawseti(L, -2, ++event_count);
    session->notification_pending = false;
    session->notification_count = 0;
  }
  lua_setfield(L, -2, "events");
  GhosttyTerminalScrollbar scrollbar = {0};
  if (ghostty_terminal_get(
    session->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar
  ) == GHOSTTY_SUCCESS) {
    lua_createtable(L, 0, 3);
    set_integer_field(L, "total", (lua_Integer)scrollbar.total);
    set_integer_field(L, "offset", (lua_Integer)scrollbar.offset);
    set_integer_field(L, "len", (lua_Integer)scrollbar.len);
    lua_setfield(L, -2, "scrollbar");
  }

  push_cursor(L, session, &colors);
  lua_setfield(L, -2, "cursor");

  if (include_rows) {
    GhosttyRenderStateDirty dirty = GHOSTTY_RENDER_STATE_DIRTY_FULL;
    ghostty_render_state_get(
      session->render_state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty
    );
    if (reuse) lua_getfield(L, -1, "rows");
    if (!reuse || !lua_istable(L, -1)) {
      if (reuse) lua_pop(L, 1);
      lua_createtable(L, session->rows, 0);
    }
    if ((!reuse || dirty != GHOSTTY_RENDER_STATE_DIRTY_FALSE) &&
        ghostty_render_state_get(
          session->render_state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
          &session->row_iterator
        ) == GHOSTTY_SUCCESS) {
      if (!ensure_snapshot_text(session)) {
        return luaL_error(L, "Could not allocate a terminal text row");
      }
      int row_index = 1;
      while (ghostty_render_state_row_iterator_next(session->row_iterator)) {
        bool row_dirty = true;
        ghostty_render_state_row_get(
          session->row_iterator, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &row_dirty
        );
        if (!reuse || dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL || row_dirty) {
          if (ghostty_render_state_row_get(
            session->row_iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
            &session->row_cells
          ) == GHOSTTY_SUCCESS) {
            push_render_row(L, session, &colors);
          } else lua_createtable(L, 0, 0);
          lua_rawseti(L, -2, row_index);
        }
        bool clean = false;
        ghostty_render_state_row_set(
          session->row_iterator, GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &clean
        );
        row_index++;
      }
    }
    int existing_rows = (int)lua_rawlen(L, -1);
    for (int row_index = session->rows + 1; row_index <= existing_rows; row_index++) {
      lua_pushnil(L);
      lua_rawseti(L, -2, row_index);
    }
    lua_setfield(L, -2, "rows");
    GhosttyRenderStateDirty clean = GHOSTTY_RENDER_STATE_DIRTY_FALSE;
    ghostty_render_state_set(
      session->render_state, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &clean
    );
  }
  return 1;
}

static int f_terminal_close(lua_State *L) {
  close_session(check_session(L, 1));
  return 0;
}

static int f_terminal_gc(lua_State *L) {
  close_session(check_session(L, 1));
  return 0;
}

static const luaL_Reg terminal_methods[] = {
  { "update", f_terminal_update },
  { "write", f_terminal_write },
  { "trace", f_terminal_trace },
  { "paste", f_terminal_paste },
  { "resize", f_terminal_resize },
  { "clear", f_terminal_clear },
  { "key", f_terminal_key },
  { "scroll", f_terminal_scroll },
  { "selection_gesture", f_terminal_selection_gesture },
  { "select", f_terminal_select },
  { "clear_selection", f_terminal_clear_selection },
  { "reset_selection_gesture", f_terminal_reset_selection_gesture },
  { "selected_text", f_terminal_selected_text },
  { "text_capture", f_terminal_text_capture },
  { "search", f_terminal_search },
  { "row_text", f_terminal_row_text },
  { "mouse", f_terminal_mouse },
  { "hyperlink", f_terminal_hyperlink },
  { "focus", f_terminal_focus },
  { "set_colors", f_terminal_set_colors },
  { "snapshot", f_terminal_snapshot },
  { "stats", f_terminal_stats },
  { "close", f_terminal_close },
  { "__gc", f_terminal_gc },
  { NULL, NULL },
};

static const luaL_Reg terminal_module[] = {
  { "new", f_terminal_new },
  { NULL, NULL },
};

static int terminal_output_event_callback(lua_State *L, SDL_Event *event) {
  (void)event;
  lua_pushliteral(L, TERMINAL_OUTPUT_EVENT);
  return 1;
}

int luaopen_terminal_native(lua_State *L) {
  if (!register_custom_event(TERMINAL_OUTPUT_EVENT, terminal_output_event_callback)) {
    return luaL_error(L, "Could not register terminal output event: %s", SDL_GetError());
  }
  luaL_newmetatable(L, API_TYPE_TERMINAL_SESSION);
  luaL_setfuncs(L, terminal_methods, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);

  luaL_newlib(L, terminal_module);
  return 1;
}
