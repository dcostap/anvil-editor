#include "hosted_surface.h"
#include "input_latency_probe.h"
#include "system_events.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32

#define PIPE_PREFIX "\\\\.\\pipe\\anvil-surface-"
#define CONNECT_TIMEOUT_MS 5000
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
  Uint32 receive_event;
  Uint32 geometry_event;
  SDL_AtomicInt inbound_bytes;
  SDL_AtomicInt intentional_exit;
  SDL_AtomicInt loss_cause;
  SDL_Mutex *queue_lock;
  SDL_Condition *queue_condition;
  HostedMessage *head, *tail;
  HostedMessage *inbound_head, *inbound_tail;
  size_t queued;
  char pipe_name[256];
  AnvilIPCPipe pipe;
  SDL_Thread *reader;
  SDL_Window *window;
  Uint32 window_id;

  /* Main-thread state. */
  AnvilSurfaceConfigure config;
  bool config_applied;
  bool text_active;

  SDL_AtomicInt focused;
  int last_cursor;
  uint32_t frame_generation;
  SharedMemoryFrame memory;

} hosted = { .last_cursor = -1, .valid = true };

bool anvil_hosted_surface_parse_args(int *argc, char **argv) {
  bool project = *argc > 1 && !strcmp(argv[1], ANVIL_PROJECT_ARG);
  bool original_arguments = false;
  for (int i = 1; i < *argc; i++) if (!strcmp(argv[i], ANVIL_PROJECT_ARGUMENTS_ARG)) original_arguments = true;
  if (project) {
    if (*argc < 3 || argv[2][0] == '-') { hosted.valid = false; return false; }
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, argv[2], -1, NULL, 0);
    wchar_t *path = count > 0 ? malloc(count * sizeof(wchar_t)) : NULL;
    DWORD attrs = INVALID_FILE_ATTRIBUTES;
    if (path && MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, argv[2], -1, path, count)) attrs = GetFileAttributesW(path);
    free(path);
    if (attrs == INVALID_FILE_ATTRIBUTES || !(attrs & FILE_ATTRIBUTE_DIRECTORY)) hosted.valid = false;
    int removed = original_arguments ? 2 : 1;
    for (int j = 1; j < *argc - removed; j++) argv[j] = argv[j + removed];
    *argc -= removed; argv[*argc] = NULL;
  }
  size_t prefix_len = strlen(ANVIL_SURFACE_PIPE_ARG);
  for (int i = 1; i < *argc; i++) {
    if (!strcmp(argv[i], ANVIL_PROJECT_ARGUMENTS_ARG)) {
      for (int j = i; j < *argc - 1; j++) argv[j] = argv[j + 1];
      argv[--(*argc)] = NULL; i--; continue;
    }
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
  if (project != hosted.active || ((hosted.restarted || original_arguments) && !project)) hosted.valid = false;
  return hosted.active;
}

bool anvil_hosted_surface_parse_valid(void) { return hosted.valid; }
bool anvil_hosted_surface_restarted(void) { return hosted.restarted; }
bool anvil_hosted_surface_loss_event(Uint32 type) { return hosted.active && type == hosted.loss_event; }
bool anvil_hosted_surface_configuration_event(Uint32 type) { return hosted.active && type == hosted.geometry_event; }

static int SDLCALL loss_watchdog(void *data) {
  (void)data;
  HANDLE signals[] = { hosted.shell_process, hosted.loss_signal };
  DWORD reason = WaitForMultipleObjects(2, signals, FALSE, INFINITE);
  if (SDL_GetAtomicInt(&hosted.intentional_exit)) return 0;
  if (reason == WAIT_OBJECT_0) SDL_Log("Project shell loss cause: shell process exit pid=%lu", (unsigned long)hosted.shell_pid);
  SDL_Log("Project shell connection lost; save and detach now; native deadline=%u ms", SHELL_LOSS_DEADLINE_MS);
  anvil_ipc_pipe_cancel(&hosted.pipe);
  SDL_Event event = {0}; event.type = hosted.loss_event; SDL_PushEvent(&event);
  Sleep(SHELL_LOSS_DEADLINE_MS);
  SDL_Log("Project shell-loss deadline expired; retain the last durable Workspace; unsaved edits may be lost");
  /* A stalled thread can hold DLL teardown locks. Do not run DLL detach here. */
  TerminateProcess(GetCurrentProcess(), 124);
  return 0;
}

static void signal_loss(const char *cause, uint16_t type, size_t bytes) {
  if (SDL_GetAtomicInt(&hosted.intentional_exit)) return;
  if (SDL_CompareAndSwapAtomicInt(&hosted.loss_cause, 0, 1))
    SDL_Log("Project shell loss cause: %s message=%u bytes=%llu error=%lu", cause, type, (unsigned long long)bytes, (unsigned long)GetLastError());
  SetEvent(hosted.loss_signal);
}

bool anvil_hosted_surface_active(void) {
  return hosted.active;
}
uint32_t anvil_hosted_surface_shell_pid(void) { return hosted.shell_pid; }
void anvil_hosted_surface_controls(int *x, int *y, int *w, int *h) {
  *x = hosted.config.controls_x; *y = hosted.config.controls_y;
  *w = hosted.config.controls_w; *h = hosted.config.controls_h;
}

static void push_window_event(Uint32 type) {
  if (!hosted.window_id) return;
  SDL_Event event;
  SDL_zero(event);
  event.type = type;
  event.window.windowID = hosted.window_id;
  if (!system_push_event(&event)) signal_loss("UI event queue overflow", 0, 0);
}

static void push_input(const AnvilSurfaceInput *input, const char *text) {
  if (!hosted.window_id) return;
  SDL_Event event = input->event;
  event.common.timestamp = SDL_GetTicksNS();
  switch (event.type) {
    case SDL_EVENT_KEY_DOWN:
    case SDL_EVENT_KEY_UP:
      event.key.windowID = hosted.window_id;
      break;
    case SDL_EVENT_TEXT_INPUT:
      event.text.windowID = hosted.window_id;
      event.text.text = text;
      break;
    case SDL_EVENT_TEXT_EDITING:
      event.edit.windowID = hosted.window_id;
      event.edit.text = text;
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
    case SDL_EVENT_WINDOW_MOUSE_ENTER:
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
      event.drop.data = input->text_len ? text : NULL;
      break;
    default:
      return;
  }
  if (!system_push_event(&event)) signal_loss("UI input queue overflow", ANVIL_SURFACE_MSG_INPUT, input->text_len);
}

static void apply_window_size(void) {
  if (!hosted.window || hosted.config.pixel_w <= 0 || hosted.config.pixel_h <= 0) return;
  int w = 0, h = 0;
  SDL_GetWindowSizeInPixels(hosted.window, &w, &h);
  if (w != hosted.config.pixel_w || h != hosted.config.pixel_h) {
    SDL_SetWindowSize(hosted.window, hosted.config.pixel_w, hosted.config.pixel_h);
  }
}

static void apply_configure(const AnvilSurfaceConfigure *config) {
  AnvilSurfaceConfigure previous = hosted.config;
  bool had_config = hosted.config_applied;
  hosted.config = *config;
  hosted.config_applied = true;
  bool layout_changed = !had_config || previous.configuration != config->configuration;
  if (had_config && layout_changed) push_window_event(hosted.geometry_event);

  /* The shell waits for a frame of each new size while it live-resizes, so
   * resize frames must render immediately instead of at the refresh rate. */
  bool live_resize = hosted.config.live_resize != 0;
  if (live_resize != (previous.live_resize != 0)) {
    anvil_set_live_resize(live_resize);
  }
  apply_window_size();
  if (had_config && (previous.pixel_w != config->pixel_w || previous.pixel_h != config->pixel_h)) {
    SDL_Event event = {0};
    event.type = SDL_EVENT_WINDOW_RESIZED;
    event.window.windowID = hosted.window_id;
    event.window.data1 = config->pixel_w;
    event.window.data2 = config->pixel_h;
    system_push_event(&event);
  }
  if (layout_changed) anvil_hosted_surface_set_text_input(hosted.text_active);
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

static bool valid_configure(const AnvilSurfaceConfigure *config) {
  return config->configuration && config->origin_x >= 0 && config->origin_x <= 32768 &&
    config->origin_y >= 0 && config->origin_y <= 32768 &&
    config->pixel_w > 0 && config->pixel_h > 0 && config->pixel_w <= 32768 && config->pixel_h <= 32768 &&
    config->window_w > 0 && config->window_h > 0 && config->window_mode >= 0 && config->window_mode <= ANVIL_SURFACE_WINDOW_FULLSCREEN &&
    config->display_scale > 0 && config->display_scale <= 16 && config->refresh_hz >= 0 && config->refresh_hz <= 1000 &&
    config->controls_x >= 0 && config->controls_y >= 0 && config->controls_w >= 0 && config->controls_h >= 0 &&
    config->controls_x <= config->pixel_w && config->controls_w <= config->pixel_w - config->controls_x &&
    config->controls_y <= config->pixel_h && config->controls_h <= config->pixel_h - config->controls_y;
}

static void dispatch_message(HostedMessage *message) {
  switch (message->type) {
    case ANVIL_SURFACE_MSG_CONFIGURE:
      if (((AnvilSurfaceConfigure *)message->payload)->configuration >= hosted.config.configuration) {
        if (((AnvilSurfaceConfigure *)message->payload)->configuration == hosted.config.configuration &&
            anvil_surface_layout_changed(&hosted.config, (AnvilSurfaceConfigure *)message->payload)) {
          signal_loss("layout changed without configuration epoch", message->type, message->size);
        } else {
          apply_configure((AnvilSurfaceConfigure *)message->payload);
        }
      }
      break;
    case ANVIL_SURFACE_MSG_INPUT:
      if (((AnvilSurfaceInput *)message->payload)->configuration == hosted.config.configuration)
        push_input((AnvilSurfaceInput *)message->payload, (char *)message->payload + sizeof(AnvilSurfaceInput));
      break;
    case ANVIL_SURFACE_MSG_FOCUS:
      SDL_SetAtomicInt(&hosted.focused, ((AnvilSurfaceInt *)message->payload)->value != 0);
      push_window_event(((AnvilSurfaceInt *)message->payload)->value
        ? SDL_EVENT_WINDOW_FOCUS_GAINED : SDL_EVENT_WINDOW_FOCUS_LOST);
      break;
    case ANVIL_SURFACE_MSG_CLOSE:
      push_window_event(SDL_EVENT_WINDOW_CLOSE_REQUESTED);
      break;
  }
  SDL_AddAtomicInt(&hosted.inbound_bytes, -(int)(sizeof(*message) + message->size + 1));
  free(message);
}

void anvil_hosted_surface_poll(void) {
  if (!hosted.active || !hosted.window_id || !hosted.queue_lock) return;
  /* Configuration, focus, and input share one caller-visible order. */
  while (!system_has_pending_events()) {
    SDL_LockMutex(hosted.queue_lock);
    HostedMessage *message = hosted.inbound_head;
    if (message) {
      hosted.inbound_head = message->next;
      if (!hosted.inbound_head) hosted.inbound_tail = NULL;
    }
    SDL_UnlockMutex(hosted.queue_lock);
    if (!message) return;
    dispatch_message(message);
  }
}

bool anvil_hosted_surface_dispatch(const SDL_Event *event) {
  if (!hosted.active || event->type != hosted.receive_event) return false;
  anvil_hosted_surface_poll();
  return true;
}

static int SDLCALL reader_thread(void *data) {
  (void)data;
  uint8_t *payload = malloc(ANVIL_SURFACE_MAX_PAYLOAD);
  if (!payload) { signal_loss("inbound allocation failed", 0, ANVIL_SURFACE_MAX_PAYLOAD); return 1; }
  AnvilIPCHeader header = {0};
  const char *cause = "pipe EOF or invalid packet";
  while (anvil_ipc_pipe_read(&hosted.pipe, &header, payload, ANVIL_SURFACE_MAX_PAYLOAD)) {
    switch (header.type) {
      case ANVIL_SURFACE_MSG_CONFIGURE:
        if (header.size != sizeof(AnvilSurfaceConfigure) || !valid_configure((const AnvilSurfaceConfigure *)payload)) goto failed;
        break;
      case ANVIL_SURFACE_MSG_INPUT: {
        if (header.size < sizeof(AnvilSurfaceInput)) goto failed;
        AnvilSurfaceInput input;
        memcpy(&input, payload, sizeof(input));
        if (input.text_len != header.size - sizeof(AnvilSurfaceInput)) goto failed;
        if (memchr(payload + sizeof(input), 0, input.text_len)) goto failed;
        break;
      }
      case ANVIL_SURFACE_MSG_FOCUS:
        if (header.size != sizeof(AnvilSurfaceInt)) goto failed;
        break;
      case ANVIL_SURFACE_MSG_CLOSE:
        if (header.size) goto failed;
        break;
      default:
        continue;
    }
    size_t bytes = sizeof(HostedMessage) + header.size + 1;
    SDL_LockMutex(hosted.queue_lock);
    HostedMessage *tail = hosted.inbound_tail;
    if (header.type == ANVIL_SURFACE_MSG_INPUT && header.size == sizeof(AnvilSurfaceInput) &&
        tail && tail->type == header.type && tail->size == header.size) {
      AnvilSurfaceInput *next = (AnvilSurfaceInput *)payload;
      AnvilSurfaceInput *previous = (AnvilSurfaceInput *)tail->payload;
      if (next->event.type == SDL_EVENT_MOUSE_MOTION && previous->event.type == SDL_EVENT_MOUSE_MOTION &&
          next->configuration == previous->configuration) {
        next->event.motion.xrel += previous->event.motion.xrel;
        next->event.motion.yrel += previous->event.motion.yrel;
        memcpy(tail->payload, payload, header.size);
        SDL_UnlockMutex(hosted.queue_lock);
        continue;
      }
    }
    if ((size_t)SDL_AddAtomicInt(&hosted.inbound_bytes, (int)bytes) + bytes > HOSTED_QUEUE_LIMIT) {
      SDL_UnlockMutex(hosted.queue_lock);
      cause = "inbound queue overflow";
      goto failed;
    }
    HostedMessage *message = malloc(bytes);
    if (!message) {
      SDL_UnlockMutex(hosted.queue_lock);
      cause = "inbound allocation failed";
      goto failed;
    }
    message->type = header.type;
    message->next = NULL;
    message->size = header.size;
    memcpy(message->payload, payload, header.size);
    message->payload[header.size] = 0;
    bool wake = hosted.inbound_head == NULL;
    if (hosted.inbound_tail) hosted.inbound_tail->next = message;
    else hosted.inbound_head = message;
    hosted.inbound_tail = message;
    SDL_UnlockMutex(hosted.queue_lock);
    SDL_Event event = {0};
    event.type = hosted.receive_event;
    if (wake && !SDL_PushEvent(&event)) {
      cause = "inbound notification failed";
      goto failed;
    }
  }
failed:
  free(payload);
  signal_loss(cause, header.type, header.size);
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
    if (!ok) { signal_loss("pipe write failed", 0, 0); return 1; }
  }
}

static void send_message(uint16_t type, const void *payload, uint32_t size) {
  if (!hosted.active || !hosted.queue_lock || size > ANVIL_SURFACE_MAX_PAYLOAD) return;
  HostedMessage *message = malloc(sizeof(*message) + size);
  if (!message) { signal_loss("outbound allocation failed", type, sizeof(*message) + size); return; }
  message->next = NULL; message->type = type; message->size = size;
  if (size) memcpy(message->payload, payload, size);
  SDL_LockMutex(hosted.queue_lock);
  if (type == ANVIL_SURFACE_MSG_FRAME && hosted.tail && hosted.tail->type == type && hosted.tail->size == size) {
    memcpy(hosted.tail->payload, payload, size);
    SDL_UnlockMutex(hosted.queue_lock); free(message); return;
  }
  if (hosted.queued + sizeof(*message) + size > HOSTED_QUEUE_LIMIT) {
    size_t queued = hosted.queued;
    SDL_UnlockMutex(hosted.queue_lock); free(message); signal_loss("outbound queue overflow", type, queued + sizeof(*message) + size); return;
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
  hosted.config = config;
  hosted.config_applied = true;

  hosted.pipe.timeout_ms = INFINITE;
  hosted.queue_lock = SDL_CreateMutex(); hosted.queue_condition = SDL_CreateCondition();
  hosted.loss_signal = CreateEventW(NULL, TRUE, FALSE, NULL);
  hosted.exit_sent = CreateEventW(NULL, TRUE, FALSE, NULL);
  hosted.loss_event = SDL_RegisterEvents(1);
  hosted.receive_event = SDL_RegisterEvents(1);
  hosted.geometry_event = SDL_RegisterEvents(1);
  if (!hosted.queue_lock || !hosted.queue_condition || !hosted.loss_signal || !hosted.exit_sent ||
      hosted.loss_event == (Uint32)-1 || hosted.receive_event == (Uint32)-1 || hosted.geometry_event == (Uint32)-1) return false;
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
  frame.configuration = hosted.config.configuration;
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
  header->configuration = hosted.config.configuration;
  ReleaseMutex(hosted.memory.mutex);

  AnvilSurfaceFrame frame;
  memset(&frame, 0, sizeof(frame));
  frame.kind = ANVIL_SURFACE_FRAME_SHARED_MEMORY;
  frame.generation = header->generation;
  frame.configuration = header->configuration;
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
  hosted.text_active = active;
  AnvilSurfaceTextInput message = { .active = active ? 1 : 0, .cursor = -1 };
  message.configuration = hosted.config.configuration;
  send_message(ANVIL_SURFACE_MSG_TEXT_INPUT, &message, sizeof(message));
}

void anvil_hosted_surface_set_text_input_area(const SDL_Rect *rect, int cursor) {
  if (!rect) return;
  AnvilSurfaceTextInput message = { -1, rect->x, rect->y, rect->w, rect->h, cursor };
  message.configuration = hosted.config.configuration;
  send_message(ANVIL_SURFACE_MSG_TEXT_INPUT, &message, sizeof(message));
}

void anvil_hosted_surface_clear_ime(void) {
  send_message(ANVIL_SURFACE_MSG_CLEAR_IME, &hosted.config.configuration, sizeof(uint64_t));
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
  if (!hit_test) return;
  AnvilSurfaceHitTest message = *hit_test;
  message.configuration = hosted.config.configuration;
  send_message(ANVIL_SURFACE_MSG_HIT_TEST, &message, sizeof(message));
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
bool anvil_hosted_surface_dispatch(const SDL_Event *event) { (void)event; return false; }
void anvil_hosted_surface_poll(void) {}
bool anvil_hosted_surface_configuration_event(Uint32 type) { (void)type; return false; }
uint32_t anvil_hosted_surface_shell_pid(void) { return 0; }
void anvil_hosted_surface_controls(int *x, int *y, int *w, int *h) { *x = *y = *w = *h = 0; }
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
