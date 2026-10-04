#include "hosted_surface.h"
#include "input_latency_probe.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32

#define PIPE_PREFIX "\\\\.\\pipe\\anvil-surface-"
#define CONNECT_TIMEOUT_MS 5000
#define TEXT_RING_SIZE 4096
#define MEMORY_LOCK_TIMEOUT_MS 100
#define HOSTED_QUEUE_LIMIT (8u * 1024u * 1024u)
#define SHELL_LOSS_DEADLINE_MS 5000

typedef struct HostedMessage {
  struct HostedMessage *next;
  uint16_t type;
  uint32_t size;
  uint8_t payload[];
} HostedMessage;

/* Live-resize frame scheduling lives in main.c. */
void anvil_set_live_resize(bool live_resize);
void anvil_request_resize_frame_for_window(SDL_Window *window, const char *reason);

typedef struct {
  HANDLE mapping;
  HANDLE mutex;
  uint8_t *view;
  size_t capacity;
  uint32_t generation;
  char name[ANVIL_SURFACE_NAME_MAX];
} SharedMemoryFrame;

static struct {
  bool active;
  bool valid, restarted;
  DWORD shell_pid;
  HANDLE shell_process, loss_signal, exit_sent;
  Uint32 loss_event;
  SDL_AtomicInt intentional_exit;
  SDL_Mutex *queue_lock;
  SDL_Condition *queue_condition;
  HostedMessage *head, *tail;
  size_t queued;
  char pipe_name[256];
  AnvilIPCPipe pipe;
  SDL_Thread *reader;
  SDL_Window *window;
  Uint32 window_id;

  /* Written by the reader thread, applied on the main thread. */
  SDL_Mutex *config_lock;
  AnvilSurfaceConfigure pending_config;
  /* Main-thread state. */
  AnvilSurfaceConfigure config;
  bool config_applied;

  SDL_AtomicInt focused;
  int last_cursor;
  uint32_t frame_generation;
  SharedMemoryFrame memory;

  /* Only the reader thread fills this ring. Forwarded text stays alive until
   * its slot is reused; Lua copies text out of each event long before 4096
   * newer text events arrive. SDL never frees pointers it did not allocate. */
  char *text_ring[TEXT_RING_SIZE];
  unsigned text_ring_next;
} hosted = { .last_cursor = -1, .valid = true };

bool anvil_hosted_surface_parse_args(int *argc, char **argv) {
  bool project = *argc > 1 && !strcmp(argv[1], ANVIL_PROJECT_ARG);
  if (project) {
    if (*argc < 3 || argv[2][0] == '-') { hosted.valid = false; return false; }
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, argv[2], -1, NULL, 0);
    wchar_t *path = count > 0 ? malloc(count * sizeof(wchar_t)) : NULL;
    DWORD attrs = INVALID_FILE_ATTRIBUTES;
    if (path && MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, argv[2], -1, path, count)) attrs = GetFileAttributesW(path);
    free(path);
    if (attrs == INVALID_FILE_ATTRIBUTES || !(attrs & FILE_ATTRIBUTE_DIRECTORY)) hosted.valid = false;
    for (int j = 1; j < *argc - 1; j++) argv[j] = argv[j + 1];
    argv[--(*argc)] = NULL;
  }
  size_t prefix_len = strlen(ANVIL_SURFACE_PIPE_ARG);
  for (int i = 1; i < *argc; i++) {
    if (!strcmp(argv[i], ANVIL_PROJECT_RESTART_ARG)) {
      hosted.restarted = true;
      for (int j = i; j < *argc - 1; j++) argv[j] = argv[j + 1];
      argv[--(*argc)] = NULL; i--; continue;
    }
    if (strncmp(argv[i], ANVIL_SURFACE_PIPE_ARG, prefix_len) != 0) continue;
    const char *name = argv[i] + prefix_len;
    if (strncmp(name, PIPE_PREFIX, strlen(PIPE_PREFIX)) == 0 &&
        strlen(name) < sizeof(hosted.pipe_name) &&
        sscanf(name + strlen(PIPE_PREFIX), "%lu-", &hosted.shell_pid) == 1 && hosted.shell_pid) {
      SDL_strlcpy(hosted.pipe_name, name, sizeof(hosted.pipe_name));
      hosted.active = true;
    } else hosted.valid = false;
    for (int j = i; j < *argc - 1; j++) argv[j] = argv[j + 1];
    (*argc)--;
    argv[*argc] = NULL;
    i--;
  }
  if (project != hosted.active || (hosted.restarted && !project)) hosted.valid = false;
  return hosted.active;
}

bool anvil_hosted_surface_parse_valid(void) { return hosted.valid; }
bool anvil_hosted_surface_restarted(void) { return hosted.restarted; }
bool anvil_hosted_surface_loss_event(Uint32 type) { return hosted.active && type == hosted.loss_event; }

static int SDLCALL loss_watchdog(void *data) {
  (void)data;
  HANDLE signals[] = { hosted.shell_process, hosted.loss_signal };
  WaitForMultipleObjects(2, signals, FALSE, INFINITE);
  if (SDL_GetAtomicInt(&hosted.intentional_exit)) return 0;
  SDL_Log("Project shell connection lost; save and detach now; native deadline=%u ms", SHELL_LOSS_DEADLINE_MS);
  anvil_ipc_pipe_cancel(&hosted.pipe);
  SDL_Event event = {0}; event.type = hosted.loss_event; SDL_PushEvent(&event);
  Sleep(SHELL_LOSS_DEADLINE_MS);
  SDL_Log("Project shell-loss deadline expired; retain the last durable Workspace; unsaved edits may be lost");
  /* A stalled thread can hold DLL teardown locks. Do not run DLL detach here. */
  TerminateProcess(GetCurrentProcess(), 124);
  return 0;
}

bool anvil_hosted_surface_active(void) {
  return hosted.active;
}

static const char *own_text(const char *text, uint32_t len) {
  char *copy = malloc((size_t)len + 1);
  if (!copy) return "";
  memcpy(copy, text, len);
  copy[len] = '\0';
  unsigned slot = hosted.text_ring_next++ % TEXT_RING_SIZE;
  free(hosted.text_ring[slot]);
  hosted.text_ring[slot] = copy;
  return copy;
}

static void push_window_event(Uint32 type) {
  if (!hosted.window_id) return;
  SDL_Event event;
  SDL_zero(event);
  event.type = type;
  event.window.windowID = hosted.window_id;
  SDL_PushEvent(&event);
}

static void push_input(const AnvilSurfaceInput *input, const char *text) {
  if (!hosted.window_id) return;
  SDL_Event event = input->event;
  event.common.timestamp = 0;
  switch (event.type) {
    case SDL_EVENT_KEY_DOWN:
    case SDL_EVENT_KEY_UP:
      event.key.windowID = hosted.window_id;
      break;
    case SDL_EVENT_TEXT_INPUT:
      event.text.windowID = hosted.window_id;
      event.text.text = own_text(text, input->text_len);
      break;
    case SDL_EVENT_TEXT_EDITING:
      event.edit.windowID = hosted.window_id;
      event.edit.text = own_text(text, input->text_len);
      break;
    case SDL_EVENT_MOUSE_MOTION:
      event.motion.windowID = hosted.window_id;
      break;
    case SDL_EVENT_MOUSE_BUTTON_DOWN:
    case SDL_EVENT_MOUSE_BUTTON_UP:
      event.button.windowID = hosted.window_id;
      break;
    case SDL_EVENT_MOUSE_WHEEL:
      event.wheel.windowID = hosted.window_id;
      break;
    case SDL_EVENT_WINDOW_MOUSE_LEAVE:
    case SDL_EVENT_WINDOW_EXPOSED:
      event.window.windowID = hosted.window_id;
      break;
    case SDL_EVENT_DROP_BEGIN:
    case SDL_EVENT_DROP_POSITION:
    case SDL_EVENT_DROP_COMPLETE:
    case SDL_EVENT_DROP_FILE:
    case SDL_EVENT_DROP_TEXT:
      event.drop.windowID = hosted.window_id;
      event.drop.source = NULL;
      event.drop.data = input->text_len ? own_text(text, input->text_len) : NULL;
      break;
    default:
      return;
  }
  SDL_PushEvent(&event);
}

static void apply_window_size(void) {
  if (!hosted.window || hosted.config.pixel_w <= 0 || hosted.config.pixel_h <= 0) return;
  int w = 0, h = 0;
  SDL_GetWindowSizeInPixels(hosted.window, &w, &h);
  if (w != hosted.config.pixel_w || h != hosted.config.pixel_h) {
    SDL_SetWindowSize(hosted.window, hosted.config.pixel_w, hosted.config.pixel_h);
  }
}

static void SDLCALL apply_configure(void *data) {
  (void)data;
  AnvilSurfaceConfigure previous = hosted.config;
  bool had_config = hosted.config_applied;
  SDL_LockMutex(hosted.config_lock);
  hosted.config = hosted.pending_config;
  SDL_UnlockMutex(hosted.config_lock);
  hosted.config_applied = true;

  /* The shell waits for a frame of each new size while it live-resizes, so
   * resize frames must render immediately instead of at the refresh rate. */
  bool live_resize = hosted.config.live_resize != 0;
  if (live_resize != (previous.live_resize != 0)) {
    anvil_set_live_resize(live_resize);
  }
  apply_window_size();
  if (had_config && previous.live_resize && !live_resize) {
    anvil_request_resize_frame_for_window(hosted.window, "exit_sizemove");
  }
  if (!had_config) return;
  if (previous.display_scale != hosted.config.display_scale) {
    push_window_event(SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED);
  }
  if (previous.window_mode != hosted.config.window_mode) {
    switch (hosted.config.window_mode) {
      case ANVIL_SURFACE_WINDOW_MINIMIZED: push_window_event(SDL_EVENT_WINDOW_MINIMIZED); break;
      case ANVIL_SURFACE_WINDOW_MAXIMIZED: push_window_event(SDL_EVENT_WINDOW_MAXIMIZED); break;
      default: push_window_event(SDL_EVENT_WINDOW_RESTORED); break;
    }
  }
}

static void store_configure(const AnvilSurfaceConfigure *config) {
  SDL_LockMutex(hosted.config_lock);
  hosted.pending_config = *config;
  SDL_UnlockMutex(hosted.config_lock);
}

static bool valid_configure(const AnvilSurfaceConfigure *config) {
  return config->pixel_w > 0 && config->pixel_h > 0 && config->pixel_w <= 32768 && config->pixel_h <= 32768 &&
    config->window_w > 0 && config->window_h > 0 && config->window_mode >= 0 && config->window_mode <= ANVIL_SURFACE_WINDOW_FULLSCREEN &&
    config->display_scale > 0 && config->display_scale <= 16 && config->refresh_hz >= 0 && config->refresh_hz <= 1000;
}

static int SDLCALL reader_thread(void *data) {
  (void)data;
  uint8_t *payload = malloc(ANVIL_SURFACE_MAX_PAYLOAD);
  if (!payload) return 1;
  AnvilIPCHeader header;
  while (anvil_ipc_pipe_read(&hosted.pipe, &header, payload, ANVIL_SURFACE_MAX_PAYLOAD)) {
    switch (header.type) {
      case ANVIL_SURFACE_MSG_CONFIGURE:
        if (header.size != sizeof(AnvilSurfaceConfigure) || !valid_configure((const AnvilSurfaceConfigure *)payload)) goto failed;
        store_configure((const AnvilSurfaceConfigure *)payload);
        SDL_RunOnMainThread(apply_configure, NULL, false);
        break;
      case ANVIL_SURFACE_MSG_INPUT: {
        if (header.size < sizeof(AnvilSurfaceInput)) break;
        AnvilSurfaceInput input;
        memcpy(&input, payload, sizeof(input));
        if (input.text_len != header.size - sizeof(AnvilSurfaceInput)) break;
        push_input(&input, (const char *)payload + sizeof(AnvilSurfaceInput));
        break;
      }
      case ANVIL_SURFACE_MSG_FOCUS:
        if (header.size != sizeof(AnvilSurfaceInt)) break;
        SDL_SetAtomicInt(&hosted.focused, ((const AnvilSurfaceInt *)payload)->value != 0);
        push_window_event(((const AnvilSurfaceInt *)payload)->value
                          ? SDL_EVENT_WINDOW_FOCUS_GAINED : SDL_EVENT_WINDOW_FOCUS_LOST);
        break;
      case ANVIL_SURFACE_MSG_CLOSE:
        push_window_event(SDL_EVENT_WINDOW_CLOSE_REQUESTED);
        break;
      default:
        break;
    }
  }
failed:
  free(payload);
  if (!SDL_GetAtomicInt(&hosted.intentional_exit)) SetEvent(hosted.loss_signal);
  return 0;
}

static int SDLCALL writer_thread(void *data) {
  (void)data;
  for (;;) {
    SDL_LockMutex(hosted.queue_lock);
    while (!hosted.head) SDL_WaitCondition(hosted.queue_condition, hosted.queue_lock);
    HostedMessage *message = hosted.head;
    hosted.head = message->next;
    if (!hosted.head) hosted.tail = NULL;
    hosted.queued -= sizeof(*message) + message->size;
    SDL_UnlockMutex(hosted.queue_lock);
    bool ok = anvil_ipc_pipe_write(&hosted.pipe, message->type, message->payload, message->size, NULL, 0);
    bool final = message->type == ANVIL_SURFACE_MSG_EXIT_INTENT || message->type == ANVIL_SURFACE_MSG_RESTART;
    free(message);
    if (final) SetEvent(hosted.exit_sent);
    if (!ok) { if (!SDL_GetAtomicInt(&hosted.intentional_exit)) SetEvent(hosted.loss_signal); return 1; }
  }
}

static void send_message(uint16_t type, const void *payload, uint32_t size) {
  if (!hosted.active || !hosted.queue_lock || size > ANVIL_SURFACE_MAX_PAYLOAD) return;
  HostedMessage *message = malloc(sizeof(*message) + size);
  if (!message) { SetEvent(hosted.loss_signal); return; }
  message->next = NULL; message->type = type; message->size = size;
  if (size) memcpy(message->payload, payload, size);
  SDL_LockMutex(hosted.queue_lock);
  if (type == ANVIL_SURFACE_MSG_FRAME && hosted.tail && hosted.tail->type == type && hosted.tail->size == size) {
    memcpy(hosted.tail->payload, payload, size);
    SDL_UnlockMutex(hosted.queue_lock); free(message); return;
  }
  if (hosted.queued + sizeof(*message) + size > HOSTED_QUEUE_LIMIT) {
    SDL_UnlockMutex(hosted.queue_lock); free(message); SetEvent(hosted.loss_signal); return;
  }
  if (hosted.tail) hosted.tail->next = message; else hosted.head = message;
  hosted.tail = message; hosted.queued += sizeof(*message) + size;
  SDL_SignalCondition(hosted.queue_condition); SDL_UnlockMutex(hosted.queue_lock);
}

void anvil_hosted_surface_exit_intent(const char *restart_path) {
  if (!hosted.active || !hosted.queue_lock) return;
  SDL_SetAtomicInt(&hosted.intentional_exit, 1);
  ResetEvent(hosted.exit_sent);
  if (restart_path) send_message(ANVIL_SURFACE_MSG_RESTART, restart_path, (uint32_t)strlen(restart_path) + 1);
  else send_message(ANVIL_SURFACE_MSG_EXIT_INTENT, NULL, 0);
  /* Teardown only. Normal frame and window requests never wait for the pipe. */
  if (WaitForSingleObject(hosted.exit_sent, 500) != WAIT_OBJECT_0) SDL_Log("Project exit-intent delivery timed out");
}

static void send_int(uint16_t type, int value) {
  AnvilSurfaceInt message = { value };
  send_message(type, &message, sizeof(message));
}

bool anvil_hosted_surface_connect(void) {
  if (!hosted.active) return false;
  HANDLE handle = INVALID_HANDLE_VALUE;
  Uint64 deadline = SDL_GetTicks() + CONNECT_TIMEOUT_MS;
  for (;;) {
    handle = CreateFileA(hosted.pipe_name, GENERIC_READ | GENERIC_WRITE, 0, NULL,
                         OPEN_EXISTING,
                         FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
                         NULL);
    if (handle != INVALID_HANDLE_VALUE) break;
    if (GetLastError() != ERROR_PIPE_BUSY || SDL_GetTicks() >= deadline) {
      SDL_Log("Hosted surface could not open the shell pipe: %lu",
              (unsigned long)GetLastError());
      return false;
    }
    WaitNamedPipeA(hosted.pipe_name, 100);
  }
  if (!anvil_ipc_pipe_init(&hosted.pipe, handle, ANVIL_SURFACE_PROTOCOL_VERSION, ANVIL_SURFACE_MAX_PAYLOAD)) {
    CloseHandle(handle);
    return false;
  }
  ULONG server = 0;
  if (!GetNamedPipeServerProcessId(handle, &server) || server != hosted.shell_pid ||
      !(hosted.shell_process = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, server))) {
    SDL_Log("Project rejected shell pipe identity: expected=%lu actual=%lu", (unsigned long)hosted.shell_pid, (unsigned long)server);
    return false;
  }
  hosted.pipe.timeout_ms = CONNECT_TIMEOUT_MS;
  hosted.config_lock = SDL_CreateMutex();
  if (!hosted.config_lock) return false;

  AnvilSurfaceHello hello = { (uint32_t)GetCurrentProcessId() };
  if (!anvil_ipc_pipe_write(&hosted.pipe, ANVIL_SURFACE_MSG_HELLO, &hello, sizeof(hello), NULL, 0)) {
    SDL_Log("Hosted surface could not greet the shell.");
    return false;
  }

  /* Startup reads the display scale and initial size, so wait for them. */
  AnvilIPCHeader header = { 0 };
  AnvilSurfaceConfigure config;
  bool read = anvil_ipc_pipe_read(&hosted.pipe, &header, &config, sizeof(config));
  if (!read || header.type != ANVIL_SURFACE_MSG_CONFIGURE || header.size != sizeof(config) || !valid_configure(&config)) {
    SDL_Log("Hosted surface did not receive its first configuration: read=%d type=%u size=%u error=%lu",
            read, (unsigned)header.type, (unsigned)header.size, (unsigned long)GetLastError());
    return false;
  }
  hosted.pending_config = config;
  hosted.config = config;
  hosted.config_applied = true;

  hosted.pipe.timeout_ms = INFINITE;
  hosted.queue_lock = SDL_CreateMutex(); hosted.queue_condition = SDL_CreateCondition();
  hosted.loss_signal = CreateEventW(NULL, TRUE, FALSE, NULL);
  hosted.exit_sent = CreateEventW(NULL, TRUE, FALSE, NULL);
  hosted.loss_event = SDL_RegisterEvents(1);
  if (!hosted.queue_lock || !hosted.queue_condition || !hosted.loss_signal || !hosted.exit_sent || hosted.loss_event == (Uint32)-1) return false;
  SDL_Thread *writer = SDL_CreateThread(writer_thread, "anvil-project-writer", NULL);
  SDL_Thread *watchdog = SDL_CreateThread(loss_watchdog, "anvil-project-deadline", NULL);
  if (!writer || !watchdog) return false;
  SDL_DetachThread(writer); SDL_DetachThread(watchdog);

  hosted.reader = SDL_CreateThread(reader_thread, "anvil-hosted-input", NULL);
  if (!hosted.reader) return false;
  SDL_DetachThread(hosted.reader);
  return true;
}

void anvil_hosted_surface_register_window(SDL_Window *window) {
  if (!hosted.active || hosted.window || !window) return;
  hosted.window = window;
  hosted.window_id = SDL_GetWindowID(window);
  apply_window_size();
}

bool anvil_hosted_surface_is_window(SDL_Window *window) {
  return hosted.active && window && window == hosted.window;
}

void anvil_hosted_surface_publish_d3d11(SDL_Window *window, const char *name, int width, int height) {
  if (!anvil_hosted_surface_is_window(window) || !name) return;
  AnvilSurfaceFrame frame;
  memset(&frame, 0, sizeof(frame));
  frame.kind = ANVIL_SURFACE_FRAME_D3D11;
  frame.generation = ++hosted.frame_generation;
  frame.width = width;
  frame.height = height;
  frame.input_seq = anvil_latency_probe_consumed_seq();
  SDL_strlcpy(frame.name, name, sizeof(frame.name));
  send_message(ANVIL_SURFACE_MSG_FRAME, &frame, sizeof(frame));
}

static void release_memory_frame(SharedMemoryFrame *memory) {
  if (memory->view) UnmapViewOfFile(memory->view);
  if (memory->mapping) CloseHandle(memory->mapping);
  if (memory->mutex) CloseHandle(memory->mutex);
  memory->view = NULL;
  memory->mapping = NULL;
  memory->mutex = NULL;
  memory->capacity = 0;
}

static bool ensure_memory_frame(size_t needed) {
  SharedMemoryFrame *memory = &hosted.memory;
  if (memory->view && memory->capacity >= needed) return true;
  release_memory_frame(memory);
  /* Grow with slack so a live resize does not replace the mapping each frame. */
  size_t capacity = needed + needed / 4;
  memory->generation++;
  snprintf(memory->name, sizeof(memory->name), "Local\\AnvilSurfaceMemory-%lu-%u",
           (unsigned long)GetCurrentProcessId(), memory->generation);
  char lock_name[ANVIL_SURFACE_NAME_MAX + 8];
  snprintf(lock_name, sizeof(lock_name), "%s%s", memory->name, ANVIL_SURFACE_LOCK_SUFFIX);
  memory->mapping = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE,
                                       (DWORD)((uint64_t)capacity >> 32), (DWORD)capacity,
                                       memory->name);
  memory->mutex = CreateMutexA(NULL, FALSE, lock_name);
  if (memory->mapping) {
    memory->view = MapViewOfFile(memory->mapping, FILE_MAP_WRITE, 0, 0, capacity);
  }
  if (!memory->mapping || !memory->mutex || !memory->view) {
    release_memory_frame(memory);
    return false;
  }
  memory->capacity = capacity;
  return true;
}

bool anvil_hosted_surface_publish_software(SDL_Window *window, SDL_Surface *surface,
                                           const SDL_Rect *rects, int count) {
  if (!anvil_hosted_surface_is_window(window) || !surface) return false;
  if (SDL_BYTESPERPIXEL(surface->format) != 4) return false;
  int stride = surface->w * 4;
  size_t needed = sizeof(AnvilSurfaceMemoryHeader) + (size_t)stride * (size_t)surface->h;
  uint32_t old_generation = hosted.memory.generation;
  if (!ensure_memory_frame(needed)) return false;
  bool full = hosted.memory.generation != old_generation;

  DWORD wait = WaitForSingleObject(hosted.memory.mutex, MEMORY_LOCK_TIMEOUT_MS);
  if (wait != WAIT_OBJECT_0 && wait != WAIT_ABANDONED) return false;
  AnvilSurfaceMemoryHeader *header = (AnvilSurfaceMemoryHeader *)hosted.memory.view;
  if (header->width != surface->w || header->height != surface->h) full = true;
  uint8_t *pixels = hosted.memory.view + sizeof(AnvilSurfaceMemoryHeader);
  const uint8_t *source = surface->pixels;
  if (full || !rects || count <= 0) {
    for (int y = 0; y < surface->h; y++) {
      memcpy(pixels + (size_t)y * stride, source + (size_t)y * surface->pitch, (size_t)stride);
    }
  } else {
    for (int i = 0; i < count; i++) {
      SDL_Rect r = rects[i];
      SDL_Rect bounds = { 0, 0, surface->w, surface->h };
      if (!SDL_GetRectIntersection(&r, &bounds, &r)) continue;
      for (int y = r.y; y < r.y + r.h; y++) {
        memcpy(pixels + (size_t)y * stride + (size_t)r.x * 4,
               source + (size_t)y * surface->pitch + (size_t)r.x * 4, (size_t)r.w * 4);
      }
    }
  }
  header->width = surface->w;
  header->height = surface->h;
  header->stride = stride;
  header->generation = ++hosted.frame_generation;
  ReleaseMutex(hosted.memory.mutex);

  AnvilSurfaceFrame frame;
  memset(&frame, 0, sizeof(frame));
  frame.kind = ANVIL_SURFACE_FRAME_SHARED_MEMORY;
  frame.generation = header->generation;
  frame.width = surface->w;
  frame.height = surface->h;
  frame.input_seq = anvil_latency_probe_consumed_seq();
  SDL_strlcpy(frame.name, hosted.memory.name, sizeof(frame.name));
  send_message(ANVIL_SURFACE_MSG_FRAME, &frame, sizeof(frame));
  return true;
}

bool anvil_hosted_surface_has_focus(void) {
  return SDL_GetAtomicInt(&hosted.focused) != 0;
}

float anvil_hosted_surface_display_scale(void) {
  return hosted.config.display_scale > 0 ? hosted.config.display_scale : 1.0f;
}

float anvil_hosted_surface_refresh_rate(void) {
  return hosted.config.refresh_hz;
}

AnvilSurfaceWindowMode anvil_hosted_surface_window_mode(void) {
  return (AnvilSurfaceWindowMode)hosted.config.window_mode;
}

void anvil_hosted_surface_window_bounds(int *x, int *y, int *w, int *h) {
  if (x) *x = hosted.config.window_x;
  if (y) *y = hosted.config.window_y;
  if (w) *w = hosted.config.window_w;
  if (h) *h = hosted.config.window_h;
}

void anvil_hosted_surface_set_cursor(AnvilSurfaceCursor cursor) {
  if ((int)cursor == hosted.last_cursor) return;
  hosted.last_cursor = (int)cursor;
  send_int(ANVIL_SURFACE_MSG_CURSOR, (int)cursor);
}

void anvil_hosted_surface_set_text_input(bool active) {
  AnvilSurfaceTextInput message = { .active = active ? 1 : 0, .cursor = -1 };
  send_message(ANVIL_SURFACE_MSG_TEXT_INPUT, &message, sizeof(message));
}

void anvil_hosted_surface_set_text_input_area(const SDL_Rect *rect, int cursor) {
  if (!rect) return;
  AnvilSurfaceTextInput message = { -1, rect->x, rect->y, rect->w, rect->h, cursor };
  send_message(ANVIL_SURFACE_MSG_TEXT_INPUT, &message, sizeof(message));
}

void anvil_hosted_surface_clear_ime(void) {
  send_message(ANVIL_SURFACE_MSG_CLEAR_IME, NULL, 0);
}

void anvil_hosted_surface_set_window_mode(AnvilSurfaceWindowMode mode) {
  send_int(ANVIL_SURFACE_MSG_WINDOW_MODE, (int)mode);
}

void anvil_hosted_surface_set_title(const char *title) {
  if (!title) return;
  size_t len = strlen(title);
  if (len > 4096) len = 4096;
  send_message(ANVIL_SURFACE_MSG_TITLE, title, (uint32_t)len);
}

void anvil_hosted_surface_set_hit_test(const AnvilSurfaceHitTest *hit_test) {
  if (hit_test) send_message(ANVIL_SURFACE_MSG_HIT_TEST, hit_test, sizeof(*hit_test));
}

void anvil_hosted_surface_set_bordered(bool bordered) {
  send_int(ANVIL_SURFACE_MSG_BORDERED, bordered ? 1 : 0);
}

void anvil_hosted_surface_set_bounds(int x, int y, int w, int h) {
  AnvilSurfaceBounds bounds = { x, y, w, h };
  send_message(ANVIL_SURFACE_MSG_SET_BOUNDS, &bounds, sizeof(bounds));
}

void anvil_hosted_surface_raise(void) {
  send_message(ANVIL_SURFACE_MSG_RAISE, NULL, 0);
}

void anvil_hosted_surface_flash(int operation) {
  send_int(ANVIL_SURFACE_MSG_FLASH, operation);
}

void anvil_hosted_surface_set_visible(bool visible) { send_int(ANVIL_SURFACE_MSG_VISIBLE, visible); }
bool anvil_hosted_surface_set_opacity(float opacity) {
  if (!(opacity >= 0 && opacity <= 1)) return false;
  send_message(ANVIL_SURFACE_MSG_OPACITY, &opacity, sizeof(opacity)); return true;
}
bool anvil_hosted_surface_frame_metrics(int *button, int *title, int *border) {
  if (!hosted.config_applied) return false;
  *button = hosted.config.button_width; *title = hosted.config.title_height; *border = hosted.config.resize_border;
  return true;
}

#else

bool anvil_hosted_surface_parse_args(int *argc, char **argv) { (void)argc; (void)argv; return false; }
bool anvil_hosted_surface_connect(void) { return false; }
bool anvil_hosted_surface_active(void) { return false; }
bool anvil_hosted_surface_parse_valid(void) { return true; }
bool anvil_hosted_surface_restarted(void) { return false; }
bool anvil_hosted_surface_loss_event(Uint32 type) { (void)type; return false; }
void anvil_hosted_surface_exit_intent(const char *path) { (void)path; }
void anvil_hosted_surface_register_window(SDL_Window *window) { (void)window; }
bool anvil_hosted_surface_is_window(SDL_Window *window) { (void)window; return false; }
void anvil_hosted_surface_publish_d3d11(SDL_Window *window, const char *name, int width, int height) {
  (void)window; (void)name; (void)width; (void)height;
}
bool anvil_hosted_surface_publish_software(SDL_Window *window, SDL_Surface *surface,
                                           const SDL_Rect *rects, int count) {
  (void)window; (void)surface; (void)rects; (void)count;
  return false;
}
bool anvil_hosted_surface_has_focus(void) { return false; }
float anvil_hosted_surface_display_scale(void) { return 1.0f; }
float anvil_hosted_surface_refresh_rate(void) { return 0.0f; }
AnvilSurfaceWindowMode anvil_hosted_surface_window_mode(void) { return ANVIL_SURFACE_WINDOW_NORMAL; }
void anvil_hosted_surface_window_bounds(int *x, int *y, int *w, int *h) {
  if (x) *x = 0;
  if (y) *y = 0;
  if (w) *w = 0;
  if (h) *h = 0;
}
void anvil_hosted_surface_set_cursor(AnvilSurfaceCursor cursor) { (void)cursor; }
void anvil_hosted_surface_set_text_input(bool active) { (void)active; }
void anvil_hosted_surface_set_text_input_area(const SDL_Rect *rect, int cursor) { (void)rect; (void)cursor; }
void anvil_hosted_surface_clear_ime(void) {}
void anvil_hosted_surface_set_window_mode(AnvilSurfaceWindowMode mode) { (void)mode; }
void anvil_hosted_surface_set_title(const char *title) { (void)title; }
void anvil_hosted_surface_set_hit_test(const AnvilSurfaceHitTest *hit_test) { (void)hit_test; }
void anvil_hosted_surface_set_bordered(bool bordered) { (void)bordered; }
void anvil_hosted_surface_set_bounds(int x, int y, int w, int h) { (void)x; (void)y; (void)w; (void)h; }
void anvil_hosted_surface_raise(void) {}
void anvil_hosted_surface_flash(int operation) { (void)operation; }
void anvil_hosted_surface_set_visible(bool visible) { (void)visible; }
bool anvil_hosted_surface_set_opacity(float opacity) { (void)opacity; return false; }
bool anvil_hosted_surface_frame_metrics(int *button, int *title, int *border) { (void)button; (void)title; (void)border; return false; }

#endif
