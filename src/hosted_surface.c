#include "hosted_surface.h"
#include "custom_events.h"
#include "input_latency_probe.h"
#include "system_events.h"
#include "process_exit.h"
#ifdef _WIN32
#include "shell_adoption.h"
#include "d3d11_backend.h"
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32

#define PIPE_PREFIX "\\\\.\\pipe\\anvil-surface-"
#define CONNECT_TIMEOUT_MS 5000
#define MEMORY_LOCK_TIMEOUT_MS 100
#define HOSTED_QUEUE_LIMIT (8u * 1024u * 1024u)
#define SHELL_LOSS_DEADLINE_MS 5000
/* A pipe can break just before the shell process is signalled as ended. */
#define SHELL_EXIT_GRACE_MS 1000

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

/* UI-thread state. Reader and writer threads use owned, Window-tagged packets. */
typedef struct HostedView {
  struct HostedView *next;
  SDL_Window *window;
  Uint32 window_id;
  AnvilSurfaceConfigure config;
  bool config_applied, text_active, removed;
  SDL_AtomicInt focused;
  int last_cursor;
  uint32_t frame_generation;
  Uint64 resize_configured_ns; /* when the latest live-resize size arrived; zero once published */
  uint32_t background, overlay;
  AnvilSurfaceArea raised[ANVIL_SURFACE_RAISED_MAX];
  SharedMemoryFrame memory;
} HostedView;
static HostedView first_view = {.last_cursor = -1};
static HostedView *view = &first_view, *views = &first_view;
static void release_memory_frame(SharedMemoryFrame *memory);
static void remove_view(HostedView *item);
static void send_message(uint16_t type, const void *payload, uint32_t size);

static struct {
  bool active;
  bool valid, restarted, sidebar, sidebar_query_needed;
  bool runtime_ready;
  DWORD shell_pid;
  HANDLE shell_process, loss_signal, exit_sent;
  /* Set for each inbound shell message, so an idle UI thread wakes for a resize or input at once. */
  HANDLE inbound_signal;
  Uint32 loss_event;
  /* Adoption after shell loss. `lost` drops outbound messages until the UI thread applies the new shell's
   * configuration. `adopting` holds inbound messages until then. Both change under `queue_lock`. */
  char *project_path;
  AnvilAdoptionOffer *offer;
  HANDLE adoption_ready;
  Uint32 adopted_event, gone_event, update_event;
  bool lost, writing;
  SDL_AtomicInt adopting, reader_running;
  /* Set when this Project's own rendering failed. No shell can adopt a broken surface. */
  SDL_AtomicInt render_failed;
  AnvilSurfaceConfigure adopted_config;
  /* Window state the next shell does not know. */
  char title[4097];
  bool has_title, has_hit_test, has_shell_colors;
  char *panes;
  AnvilSurfaceHitTest hit_test;
  AnvilSurfaceShellColors shell_colors;
  int bordered, visible;
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
  AnvilIPCPipe *pipe;
  SDL_Thread *reader;
  struct {
    uint32_t id;
    SDL_DialogFileCallback callback;
    void *userdata;
  } dialogs[ANVIL_SURFACE_DIALOG_LIMIT];

} hosted = { .valid = true, .bordered = -1, .visible = -1 };

bool anvil_hosted_surface_parse_args(int *argc, char **argv) {
  bool project = *argc > 1 && !strcmp(argv[1], ANVIL_PROJECT_ARG);
  bool original_arguments = false;
  for (int i = 1; i < *argc; i++) if (!strcmp(argv[i], ANVIL_PROJECT_ARGUMENTS_ARG)) original_arguments = true;
  if (project) {
    if (*argc < 3 || argv[2][0] == '-') { hosted.valid = false; return false; }
    hosted.project_path = _strdup(argv[2]);
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
    if (!strcmp(argv[i], "--internal-sidebar")) {
      hosted.sidebar = true;
      for (int j = i; j < *argc - 1; j++)
        argv[j] = argv[j + 1];
      argv[--(*argc)] = NULL;
      i--;
      continue;
    }
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
  if ((project || hosted.sidebar) != hosted.active || (project && hosted.sidebar) ||
      ((hosted.restarted || original_arguments) && !project) ||
      (hosted.sidebar && *argc != 1))
    hosted.valid = false;
  return hosted.active;
}

bool anvil_hosted_surface_parse_valid(void) { return hosted.valid; }
bool anvil_hosted_surface_restarted(void) { return hosted.restarted; }
bool anvil_hosted_surface_loss_event(Uint32 type) { return hosted.active && type == hosted.loss_event; }
bool anvil_hosted_surface_configuration_event(Uint32 type) { return hosted.active && type == hosted.geometry_event; }

static AnvilIPCPipe *open_shell_pipe(const char *name, DWORD pid, AnvilSurfaceConfigure *config, HANDLE *process);
static int SDLCALL reader_thread(void *data);

static void free_messages(HostedMessage **head, HostedMessage **tail, bool inbound) {
  while (*head) {
    HostedMessage *next = (*head)->next;
    if (inbound) SDL_AddAtomicInt(&hosted.inbound_bytes, -(int)(sizeof(**head) + (*head)->size + 1));
    free(*head);
    *head = next;
  }
  *tail = NULL;
}

/* Connects to an adopting shell. The UI thread applies its configuration when the adopted event arrives. */
static bool adopt(const char *name, DWORD pid) {
  char prefix[64];
  snprintf(prefix, sizeof(prefix), "%s%lu-", PIPE_PREFIX, (unsigned long)pid);
  if (strncmp(name, prefix, strlen(prefix)) || strlen(name) >= sizeof(hosted.pipe_name)) {
    SDL_Log("Project refused an adopting shell's pipe name");
    return false;
  }
  AnvilSurfaceConfigure config;
  HANDLE process = NULL;
  AnvilIPCPipe *pipe = open_shell_pipe(name, pid, &config, &process);
  if (!pipe) return false;
  /* The lost connection's reader ends on its cancelled pipe. Its writer is idle once `writing` clears. */
  for (int i = 0; i < 200 && SDL_GetAtomicInt(&hosted.reader_running); i++) Sleep(10);
  bool reader_done = !SDL_GetAtomicInt(&hosted.reader_running);
  SDL_LockMutex(hosted.queue_lock);
  while (hosted.writing) {
    SDL_UnlockMutex(hosted.queue_lock);
    Sleep(1);
    SDL_LockMutex(hosted.queue_lock);
  }
  AnvilIPCPipe *old = hosted.pipe;
  hosted.pipe = pipe;
  free_messages(&hosted.inbound_head, &hosted.inbound_tail, true);
  hosted.adopted_config = config;
  SDL_SetAtomicInt(&hosted.adopting, 1);
  SDL_UnlockMutex(hosted.queue_lock);
  if (reader_done) {
    anvil_ipc_pipe_close(old);
    free(old);
  } else SDL_Log("Project lost connection's reader did not end; keep its pipe");
  CloseHandle(hosted.shell_process);
  hosted.shell_process = process;
  hosted.shell_pid = pid;
  SDL_strlcpy(hosted.pipe_name, name, sizeof(hosted.pipe_name));
  ResetEvent(hosted.loss_signal);
  SDL_SetAtomicInt(&hosted.loss_cause, 0);
  SDL_SetAtomicInt(&hosted.reader_running, 1);
  SDL_Thread *reader = SDL_CreateThread(reader_thread, "anvil-hosted-input", pipe);
  if (reader) SDL_DetachThread(reader);
  else {
    SDL_SetAtomicInt(&hosted.reader_running, 0);
    SetEvent(hosted.loss_signal);
  }
  SDL_Event event = {0};
  event.type = hosted.adopted_event;
  SDL_PushEvent(&event);
  SDL_Log("Project adopted by shell pid=%lu configuration=%llu", (unsigned long)pid,
          (unsigned long long)config.configuration);
  return true;
}

static void loss_deadline(void) {
  Sleep(SHELL_LOSS_DEADLINE_MS);
  SDL_Log("Project shell-loss deadline expired; retain the last durable Workspace; unsaved edits may be lost");
  /* A stalled thread can hold DLL teardown locks. Do not run DLL detach here. */
  anvil_process_terminate(GetCurrentProcess(), 124);
}

/* Probe faults shorten the period or make the Project never answer a shell. */
static DWORD adoption_period(void) {
  const char *fault = SDL_getenv("ANVIL_SURFACE_FAULT_PROBE") ? SDL_getenv("ANVIL_SURFACE_FAULT_ADOPTION_PERIOD_MS") : NULL;
  int period = fault ? SDL_atoi(fault) : 0;
  return period > 0 ? (DWORD)period : ANVIL_ADOPTION_PERIOD_MS;
}

static bool adoption_hangs(void) {
  const char *fault = SDL_getenv("ANVIL_SURFACE_FAULT_PROBE") ? SDL_getenv("ANVIL_SURFACE_FAULT_ADOPTION") : NULL;
  return fault && !SDL_strcmp(fault, "hang");
}

static int SDLCALL loss_watchdog(void *data) {
  (void)data;
  for (;;) {
    HANDLE signals[] = { hosted.shell_process, hosted.loss_signal };
    DWORD reason = WaitForMultipleObjects(2, signals, FALSE, INFINITE);
    if (SDL_GetAtomicInt(&hosted.intentional_exit)) return 0;
    if (reason == WAIT_OBJECT_0) SDL_Log("Project shell loss cause: shell process exit pid=%lu", (unsigned long)hosted.shell_pid);
    SDL_SetAtomicInt(&hosted.loss_cause, 1);
    anvil_ipc_pipe_cancel(hosted.pipe);
    SDL_LockMutex(hosted.queue_lock);
    hosted.lost = true;
    free_messages(&hosted.head, &hosted.tail, false);
    hosted.queued = 0;
    SDL_UnlockMutex(hosted.queue_lock);
    DWORD period = adoption_period();
    uint64_t deadline = GetTickCount64() + period;
    /* Only a Project whose shell ended waits for adoption. A live shell that dropped the connection has
     * already failed this Project, and a Project whose rendering failed cannot show a surface. The Sidebar
     * process restarts with the next shell instead. */
    bool shell_ended = reason == WAIT_OBJECT_0 ||
                       WaitForSingleObject(hosted.shell_process, SHELL_EXIT_GRACE_MS) == WAIT_OBJECT_0;
    bool render_failed = SDL_GetAtomicInt(&hosted.render_failed) != 0;
    if (!shell_ended || render_failed)
      SDL_Log("Project offers no adoption: %s", render_failed ? "its rendering failed" : "the shell is still running");
    hosted.offer = hosted.sidebar || !hosted.project_path || !shell_ended || render_failed ? NULL
                 : anvil_adoption_offer_open(hosted.project_path, view->config.window_id);
    SDL_Log("Project shell connection lost; save %s; native deadline=%u ms",
            hosted.offer ? "and wait for adoption" : "and detach now", SHELL_LOSS_DEADLINE_MS);
    SDL_Event event = {0}; event.type = hosted.loss_event; SDL_PushEvent(&event);
    if (!hosted.offer) loss_deadline();
    if (WaitForSingleObject(hosted.adoption_ready, SHELL_LOSS_DEADLINE_MS) != WAIT_OBJECT_0) {
      anvil_adoption_offer_close(hosted.offer);
      SDL_Log("Project did not finish its shell-loss save in time");
      anvil_process_terminate(GetCurrentProcess(), 124);
    }
    ResetEvent(hosted.adoption_ready);
    SDL_Log("Project waits up to %lu ms for a shell to adopt it", (unsigned long)period);
    char name[256];
    DWORD pid = 0;
    bool adopted = false;
    if (adoption_hangs()) {
      SDL_Log("Project adoption fault: never answer a shell");
      for (;;) Sleep(INFINITE);
    }
    while (!adopted && anvil_adoption_offer_accept(hosted.offer, deadline, name, sizeof(name), &pid))
      adopted = adopt(name, pid);
    anvil_adoption_offer_close(hosted.offer);
    hosted.offer = NULL;
    if (!adopted) {
      SDL_Log("No shell adopted this Project within %lu ms; save, detach, and exit", (unsigned long)period);
      SDL_Event gone = {0}; gone.type = hosted.gone_event; SDL_PushEvent(&gone);
      loss_deadline();
    }
  }
}

bool anvil_hosted_surface_await_adoption(void) {
  if (!hosted.active || !hosted.offer) return false;
  SetEvent(hosted.adoption_ready);
  return true;
}
bool anvil_hosted_surface_adopted_event(Uint32 type) { return hosted.active && type == hosted.adopted_event; }
bool anvil_hosted_surface_gone_event(Uint32 type) { return hosted.active && type == hosted.gone_event; }
bool anvil_hosted_surface_update_event(Uint32 type) { return hosted.active && type == hosted.update_event; }

static void signal_loss(const char *cause, uint16_t type, size_t bytes) {
  if (SDL_GetAtomicInt(&hosted.intentional_exit)) return;
  if (SDL_CompareAndSwapAtomicInt(&hosted.loss_cause, 0, 1))
    SDL_Log("Project shell loss cause: %s message=%u bytes=%llu error=%lu", cause, type, (unsigned long long)bytes, (unsigned long)GetLastError());
  SetEvent(hosted.loss_signal);
}

bool anvil_hosted_surface_active(void) {
  return hosted.active;
}
bool anvil_hosted_surface_sidebar(void) { return hosted.active && hosted.sidebar; }
void anvil_hosted_surface_render_failed(const char *cause) {
  SDL_SetAtomicInt(&hosted.render_failed, 1);
  signal_loss(cause, ANVIL_SURFACE_MSG_FRAME, 0);
}
uint32_t anvil_hosted_surface_shell_pid(void) { return hosted.shell_pid; }
void anvil_hosted_surface_controls(int *x, int *y, int *w, int *h) {
  *x = view->config.controls_x; *y = view->config.controls_y;
  *w = view->config.controls_w; *h = view->config.controls_h;
}

static void push_window_event(Uint32 type) {
  if (!view->window_id) return;
  SDL_Event event;
  SDL_zero(event);
  event.type = type;
  event.window.windowID = view->window_id;
  if (!system_push_event(&event)) signal_loss("UI event queue overflow", 0, 0);
}

static void push_input(const AnvilSurfaceInput *input, const char *text) {
  if (!view->window_id) return;
  SDL_Event event = input->event;
  event.common.timestamp = SDL_GetTicksNS();
  switch (event.type) {
    case SDL_EVENT_KEY_DOWN:
    case SDL_EVENT_KEY_UP:
      event.key.windowID = view->window_id;
      break;
    case SDL_EVENT_TEXT_INPUT:
      event.text.windowID = view->window_id;
      event.text.text = text;
      break;
    case SDL_EVENT_TEXT_EDITING:
      event.edit.windowID = view->window_id;
      event.edit.text = text;
      break;
    case SDL_EVENT_MOUSE_MOTION:
      event.motion.windowID = view->window_id;
      break;
    case SDL_EVENT_MOUSE_BUTTON_DOWN:
    case SDL_EVENT_MOUSE_BUTTON_UP:
      event.button.windowID = view->window_id;
      break;
    case SDL_EVENT_MOUSE_WHEEL:
      event.wheel.windowID = view->window_id;
      break;
    case SDL_EVENT_WINDOW_MOUSE_LEAVE:
    case SDL_EVENT_WINDOW_MOUSE_ENTER:
    case SDL_EVENT_WINDOW_EXPOSED:
      event.window.windowID = view->window_id;
      break;
    case SDL_EVENT_DROP_BEGIN:
    case SDL_EVENT_DROP_POSITION:
    case SDL_EVENT_DROP_COMPLETE:
    case SDL_EVENT_DROP_FILE:
    case SDL_EVENT_DROP_TEXT:
      event.drop.windowID = view->window_id;
      event.drop.source = NULL;
      event.drop.data = input->text_len ? text : NULL;
      break;
    default:
      return;
  }
  if (!system_push_event(&event)) signal_loss("UI input queue overflow", ANVIL_SURFACE_MSG_INPUT, input->text_len);
}

static void apply_window_size(void) {
  if (!view->window || view->config.pixel_w <= 0 || view->config.pixel_h <= 0) return;
  int w = 0, h = 0;
  SDL_GetWindowSizeInPixels(view->window, &w, &h);
  if (w != view->config.pixel_w || h != view->config.pixel_h) {
    SDL_SetWindowSize(view->window, view->config.pixel_w, view->config.pixel_h);
  }
}

static void apply_configure(const AnvilSurfaceConfigure *config) {
  AnvilSurfaceConfigure previous = view->config;
  bool had_config = view->config_applied;
  view->config = *config;
  view->config_applied = true;
  if (had_config && previous.render_enabled != config->render_enabled) {
    SDL_Log("Project rendering %s; background work continues",
            config->render_enabled ? "enabled" : "disabled");
    if (config->render_enabled) push_window_event(SDL_EVENT_WINDOW_EXPOSED);
  }
  bool layout_changed = !had_config || previous.configuration != config->configuration;
  if (had_config && layout_changed) push_window_event(hosted.geometry_event);

  /* The shell waits for a frame of each new size while it live-resizes, so
   * resize frames must render immediately instead of at the refresh rate. */
  bool live_resize = view->config.live_resize != 0;
  if (live_resize != (previous.live_resize != 0)) {
    anvil_set_live_resize(live_resize);
  }
  apply_window_size();
  if (had_config && (previous.pixel_w != config->pixel_w || previous.pixel_h != config->pixel_h)) {
    if (live_resize) view->resize_configured_ns = SDL_GetTicksNS();
    SDL_Event event = {0};
    event.type = SDL_EVENT_WINDOW_RESIZED;
    event.window.windowID = view->window_id;
    event.window.data1 = config->pixel_w;
    event.window.data2 = config->pixel_h;
    system_push_event(&event);
  }
  if (layout_changed) anvil_hosted_surface_set_text_input(view->text_active);
  if (had_config && previous.live_resize && !live_resize) {
    anvil_request_resize_frame_for_window(view->window, "exit_sizemove");
  }
  if (!had_config) return;
  if (previous.display_scale != view->config.display_scale) {
    push_window_event(SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED);
  }
  /* A remote session can change the rate without a move or a scale change. */
  if (previous.refresh_hz != view->config.refresh_hz) {
    push_window_event(SDL_EVENT_WINDOW_DISPLAY_CHANGED);
  }
  if (previous.window_mode != view->config.window_mode) {
    switch (view->config.window_mode) {
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
    (config->render_enabled == 0 || config->render_enabled == 1) &&
    config->display_scale > 0 && config->display_scale <= 16 && config->refresh_hz >= 0 && config->refresh_hz <= 1000 &&
    config->controls_x >= 0 && config->controls_y >= 0 && config->controls_w >= 0 && config->controls_h >= 0 &&
    config->controls_x <= config->pixel_w && config->controls_w <= config->pixel_w - config->controls_x &&
    config->controls_y <= config->pixel_h && config->controls_h <= config->pixel_h - config->controls_y &&
    config->content_x >= 0 && config->content_x < config->pixel_w;
}

static HostedView *sidebar_view(uint32_t id, bool create) {
  size_t count = 0, total = 0;
  for (HostedView *item = views; item; item = item->next) {
    if (item->config.window_id == id) return item;
    total++;
    if (!item->removed) count++;
  }
  if (!create) return NULL;
  if (count >= 64 || total >= 128) { signal_loss("Sidebar surface bound exceeded", ANVIL_SURFACE_MSG_CONFIGURE, total); return NULL; }
  HostedView *item = calloc(1, sizeof(*item));
  if (!item) { signal_loss("Sidebar surface allocation failed", ANVIL_SURFACE_MSG_CONFIGURE, sizeof(*item)); return NULL; }
  item->config.window_id = id;
  item->last_cursor = -1;
  item->next = views;
  views = item;
  return item;
}

size_t anvil_hosted_surface_sidebar_views(uint32_t *ids, bool *removed, size_t capacity) {
  if (!hosted.sidebar) return 0;
  size_t count = 0;
  /* Drain removed surfaces first. A full live list must not hide their cleanup. */
  for (int pass = 0; pass < 2; pass++)
    for (HostedView *item = views; item && count < capacity; item = item->next) {
      if (!item->config.window_id || item->removed != (pass == 0)) continue;
      ids[count] = item->config.window_id;
      removed[count++] = item->removed;
    }
  return count;
}
bool anvil_hosted_surface_sidebar_activate(uint32_t id) {
  HostedView *item = hosted.sidebar ? sidebar_view(id, false) : NULL;
  if (!item || item->removed) return false;
  view = item;
  return true;
}

static void dispatch_message(HostedMessage *message) {
  uint16_t type = message->type;
  uint8_t *payload = message->payload;
  if (type == ANVIL_SURFACE_MSG_SIDEBAR_REMOVE) {
    HostedView *item = sidebar_view(*(uint32_t *)payload, false);
    if (item) {
      item->removed = true;
      if (!item->window) remove_view(item);
    }
    goto complete;
  }
  if (type == ANVIL_SURFACE_MSG_PING) {
    /* Dispatch runs on the UI thread, so the answer shows that thread still runs. */
    send_message(ANVIL_SURFACE_MSG_PONG, payload, sizeof(AnvilSurfaceInt));
    goto complete;
  }
  if (type == ANVIL_SURFACE_MSG_COLOR_THEME_CHANGED) {
    /* The Color Theme belongs to the whole process, not to one Sidebar surface. */
    CustomEvent event = {0};
    if (!push_custom_event("colorthemechanged", &event))
      SDL_Log("Color Theme change event dropped: %s", SDL_GetError());
    goto complete;
  }
  if (type == ANVIL_SURFACE_MSG_ZOOM_CHANGED) {
    CustomEvent event = {0};
    if (!push_custom_event("zoomchanged", &event))
      SDL_Log("Zoom change event dropped: %s", SDL_GetError());
    goto complete;
  }
  if (type == ANVIL_SURFACE_MSG_COLOR_THEME_PREVIEWED) {
    CustomEvent event = {0};
    event.data1 = _strdup((const char *)payload);
    if (!event.data1 || !push_custom_event("colorthemepreview", &event)) {
      free(event.data1);
      SDL_Log("Color Theme preview dropped: copy or event delivery failed");
    }
    goto complete;
  }
  if (type == ANVIL_SURFACE_MSG_FOCUS_TERMINAL) {
    CustomEvent event = {0};
    event.data1 = _strdup((const char *)payload);
    if (!event.data1 || !push_custom_event("focusterminal", &event)) {
      free(event.data1);
      SDL_Log("Terminal Session focus request dropped: copy or event delivery failed");
    }
    goto complete;
  }
  if (type == ANVIL_SURFACE_MSG_PANE_ACTION) {
    const AnvilSurfacePaneAction *action = (const void *)payload;
    CustomEvent event = {.code = (int32_t)action->action};
    event.data1 = _strdup(action->pane);
    if (!event.data1 || !push_custom_event("paneaction", &event)) {
      free(event.data1);
      SDL_Log("Pane action dropped: copy or event delivery failed");
    }
    goto complete;
  }
  if (type == ANVIL_SURFACE_MSG_SIDEBAR_SURFACE) {
    const AnvilSidebarSurfacePacket *packet = (const void *)payload;
    type = packet->type;
    HostedView *item = sidebar_view(packet->window_id, type == ANVIL_SURFACE_MSG_CONFIGURE);
    if (!item || item->removed) goto complete;
    view = item;
    payload += sizeof(*packet);
    if (type == ANVIL_SURFACE_MSG_CONFIGURE &&
        ((AnvilSurfaceConfigure *)payload)->window_id != packet->window_id) {
      signal_loss("Sidebar configuration Window identity mismatch", type, message->size);
      goto complete;
    }
  }
  switch (type) {
  case ANVIL_SURFACE_MSG_SIDEBAR_CHANGED: {
    CustomEvent event = {.windowID = view->window_id};
    if (!push_custom_event("projectsidebarchanged", &event)) {
      hosted.sidebar_query_needed = true;
      SDL_Log("Sidebar revision event dropped; query the current model on the next poll");
    }
    break;
  }
  case ANVIL_SURFACE_MSG_SIDEBAR_MODEL: {
    CustomEvent event = {.windowID = view->window_id};
    event.data1 = _strdup((const char *)payload);
    if (!event.data1 || !push_custom_event("projectsidebar", &event)) {
      free(event.data1);
      SDL_Log("Sidebar snapshot page dropped: copy or event delivery failed; request can retry");
    }
    break;
  }
    case ANVIL_SURFACE_MSG_CONFIGURE:
      if (((AnvilSurfaceConfigure *)payload)->configuration >= view->config.configuration) {
        if (view->config_applied && ((AnvilSurfaceConfigure *)payload)->configuration == view->config.configuration &&
            anvil_surface_layout_changed(&view->config, (AnvilSurfaceConfigure *)payload)) {
          signal_loss("layout changed without configuration epoch", message->type, message->size);
        } else {
          apply_configure((AnvilSurfaceConfigure *)payload);
        }
      }
      break;
    case ANVIL_SURFACE_MSG_INPUT:
      if (((AnvilSurfaceInput *)payload)->configuration == view->config.configuration)
        push_input((AnvilSurfaceInput *)payload, (char *)payload + sizeof(AnvilSurfaceInput));
      break;
    case ANVIL_SURFACE_MSG_FOCUS:
      SDL_SetAtomicInt(&view->focused, ((AnvilSurfaceInt *)payload)->value != 0);
      push_window_event(((AnvilSurfaceInt *)payload)->value
        ? SDL_EVENT_WINDOW_FOCUS_GAINED : SDL_EVENT_WINDOW_FOCUS_LOST);
      break;
    case ANVIL_SURFACE_MSG_CLOSE:
      push_window_event(SDL_EVENT_WINDOW_CLOSE_REQUESTED);
      break;
    case ANVIL_SURFACE_MSG_PREPARE_UPDATE:
      push_window_event(hosted.update_event);
      break;
    case ANVIL_SURFACE_MSG_DIALOG_RESULT: {
      AnvilSurfaceDialogResult *result = (AnvilSurfaceDialogResult *)payload;
      size_t index = 0;
      while (index < SDL_arraysize(hosted.dialogs) && hosted.dialogs[index].id != result->id) index++;
      if (index == SDL_arraysize(hosted.dialogs)) {
        signal_loss("unknown file dialog result ID", message->type, message->size);
        break;
      }
      SDL_DialogFileCallback callback = hosted.dialogs[index].callback;
      void *userdata = hosted.dialogs[index].userdata;
      hosted.dialogs[index].id = 0;
      const char *paths[ANVIL_SURFACE_DIALOG_PATH_LIMIT + 1] = {NULL};
      const char *cursor = (const char *)(result + 1);
      if (result->status == ANVIL_SURFACE_DIALOG_ERROR) {
        SDL_SetError("%s", cursor);
        callback(userdata, NULL, result->filter);
      } else {
        if (result->status == ANVIL_SURFACE_DIALOG_ACCEPT) {
          size_t count = 0;
          while (*cursor) { paths[count++] = cursor; cursor += strlen(cursor) + 1; }
        }
        callback(userdata, paths, result->filter);
      }
      break;
    }
  }
complete:
  SDL_AddAtomicInt(&hosted.inbound_bytes, -(int)(sizeof(*message) + message->size + 1));
  free(message);
}

static void apply_configure(const AnvilSurfaceConfigure *config);
/* Runs on the UI thread. The new shell knows nothing this Project told the old one, so send it again. */
void anvil_hosted_surface_finish_adoption(void) {
  SDL_LockMutex(hosted.queue_lock);
  AnvilSurfaceConfigure config = hosted.adopted_config;
  hosted.lost = false;
  SDL_UnlockMutex(hosted.queue_lock);
  apply_configure(&config);
  view->last_cursor = -1;
  if (hosted.has_title) anvil_hosted_surface_set_title(hosted.title);
  if (hosted.has_hit_test) anvil_hosted_surface_set_hit_test(&hosted.hit_test);
  if (hosted.has_shell_colors) anvil_hosted_surface_set_shell_colors(&hosted.shell_colors);
  if (!hosted.sidebar && hosted.panes) {
    char *panes = hosted.panes;
    hosted.panes = NULL;
    anvil_hosted_surface_set_panes(panes);
    free(panes);
  }
  if (hosted.bordered >= 0) anvil_hosted_surface_set_bordered(hosted.bordered);
  if (hosted.visible >= 0) anvil_hosted_surface_set_visible(hosted.visible);
  if (hosted.runtime_ready) anvil_hosted_surface_runtime_ready();
  SDL_SetAtomicInt(&hosted.adopting, 0);
  push_window_event(SDL_EVENT_WINDOW_EXPOSED);
  anvil_hosted_surface_poll();
}

bool anvil_hosted_surface_take_sidebar_query_needed(void) {
  bool needed = hosted.sidebar_query_needed;
  hosted.sidebar_query_needed = false;
  return needed;
}
bool anvil_hosted_surface_wait_inbound(double seconds) {
  if (!hosted.active || !hosted.inbound_signal) return false;
  return WaitForSingleObject(hosted.inbound_signal, (DWORD)SDL_max(0.0, seconds * 1000.0)) == WAIT_OBJECT_0;
}

void anvil_hosted_surface_poll(void) {
  if (!hosted.active || !hosted.queue_lock || SDL_GetAtomicInt(&hosted.adopting)) return;
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
  AnvilIPCPipe *pipe = data;
  uint8_t *payload = malloc(ANVIL_SURFACE_MAX_PAYLOAD);
  if (!payload) {
    signal_loss("inbound allocation failed", 0, ANVIL_SURFACE_MAX_PAYLOAD);
    SDL_SetAtomicInt(&hosted.reader_running, 0);
    return 1;
  }
  AnvilIPCHeader header = {0};
  const char *cause = "pipe EOF or invalid packet";
  while (anvil_ipc_pipe_read(pipe, &header, payload, ANVIL_SURFACE_MAX_PAYLOAD)) {
    uint16_t type = header.type;
    uint32_t size = header.size;
    uint8_t *body = payload;
    if (type == ANVIL_SURFACE_MSG_SIDEBAR_SURFACE) {
      if (!hosted.sidebar || size < sizeof(AnvilSidebarSurfacePacket)) goto failed;
      AnvilSidebarSurfacePacket packet;
      memcpy(&packet, body, sizeof(packet));
      if (!packet.window_id || (packet.type != ANVIL_SURFACE_MSG_CONFIGURE && packet.type != ANVIL_SURFACE_MSG_INPUT &&
          packet.type != ANVIL_SURFACE_MSG_FOCUS && packet.type != ANVIL_SURFACE_MSG_SIDEBAR_MODEL &&
          packet.type != ANVIL_SURFACE_MSG_SIDEBAR_CHANGED)) goto failed;
      type = packet.type; size -= sizeof(packet); body += sizeof(packet);
    }
    switch (type) {
      case ANVIL_SURFACE_MSG_CONFIGURE:
        if (size != sizeof(AnvilSurfaceConfigure) || !valid_configure((const AnvilSurfaceConfigure *)body)) goto failed;
        break;
      case ANVIL_SURFACE_MSG_INPUT: {
        if (size < sizeof(AnvilSurfaceInput)) goto failed;
        AnvilSurfaceInput input;
        memcpy(&input, body, sizeof(input));
        if (input.text_len != size - sizeof(AnvilSurfaceInput)) goto failed;
        if (memchr(body + sizeof(input), 0, input.text_len)) goto failed;
        break;
      }
      case ANVIL_SURFACE_MSG_FOCUS:
      case ANVIL_SURFACE_MSG_PING:
        if (size != sizeof(AnvilSurfaceInt)) goto failed;
        break;
      case ANVIL_SURFACE_MSG_CLOSE:
      case ANVIL_SURFACE_MSG_PREPARE_UPDATE:
      case ANVIL_SURFACE_MSG_SIDEBAR_CHANGED:
      case ANVIL_SURFACE_MSG_COLOR_THEME_CHANGED:
      case ANVIL_SURFACE_MSG_ZOOM_CHANGED:
        if (size) goto failed;
        break;
      case ANVIL_SURFACE_MSG_DIALOG_RESULT:
        if (!anvil_surface_dialog_result_valid(body, size)) goto failed;
        break;
      case ANVIL_SURFACE_MSG_SIDEBAR_MODEL:
        if (size < 2 || body[size - 1] || memchr(body, 0, size - 1))
          goto failed;
        break;
      case ANVIL_SURFACE_MSG_COLOR_THEME_PREVIEWED:
        if (!hosted.sidebar || !size || body[size - 1] || memchr(body, 0, size - 1)) goto failed;
        break;
      case ANVIL_SURFACE_MSG_FOCUS_TERMINAL:
        if (hosted.sidebar || size != ANVIL_SURFACE_TERMINAL_ID_LEN + 1 || body[size - 1] ||
            strspn((const char *)body, "0123456789abcdef") != ANVIL_SURFACE_TERMINAL_ID_LEN)
          goto failed;
        break;
      case ANVIL_SURFACE_MSG_SIDEBAR_REMOVE:
        if (!hosted.sidebar || size != sizeof(uint32_t) || !*(uint32_t *)body) goto failed;
        break;
      case ANVIL_SURFACE_MSG_PANE_ACTION:
        if (hosted.sidebar || size != sizeof(AnvilSurfacePaneAction) ||
            !anvil_surface_pane_action_valid((const AnvilSurfacePaneAction *)body))
          goto failed;
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
        SetEvent(hosted.inbound_signal);
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
    SetEvent(hosted.inbound_signal);
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
  SDL_SetAtomicInt(&hosted.reader_running, 0);
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
    AnvilIPCPipe *pipe = hosted.pipe;
    hosted.writing = true;
    SDL_UnlockMutex(hosted.queue_lock);
    bool ok = anvil_ipc_pipe_write(pipe, message->type, message->payload, message->size, NULL, 0);
    SDL_LockMutex(hosted.queue_lock);
    hosted.writing = false;
    SDL_UnlockMutex(hosted.queue_lock);
    bool final = message->type == ANVIL_SURFACE_MSG_EXIT_INTENT || message->type == ANVIL_SURFACE_MSG_RESTART;
    free(message);
    if (final) SetEvent(hosted.exit_sent);
    /* The writer outlives a lost connection. Messages are dropped until an adopting shell connects. */
    if (!ok) signal_loss("pipe write failed", 0, 0);
  }
  return 0;
}

static void send_message(uint16_t type, const void *payload, uint32_t size) {
  if (!hosted.active || !hosted.queue_lock || size > ANVIL_SURFACE_MAX_PAYLOAD) return;
  /* The Sidebar's process-wide messages have no surface. */
  bool wrapped = hosted.sidebar && type != ANVIL_SURFACE_MSG_EXIT_INTENT && type != ANVIL_SURFACE_MSG_RESTART &&
                 type != ANVIL_SURFACE_MSG_SHELL_COLORS && type != ANVIL_SURFACE_MSG_SIDEBAR_SOURCE;
  uint32_t prefix = wrapped ? sizeof(AnvilSidebarSurfacePacket) : 0;
  if (size > ANVIL_SURFACE_MAX_PAYLOAD - prefix) { signal_loss("Sidebar outbound packet overflow", type, size); return; }
  HostedMessage *message = malloc(sizeof(*message) + size + prefix);
  if (!message) { signal_loss("outbound allocation failed", type, sizeof(*message) + size); return; }
  message->next = NULL; message->type = wrapped ? ANVIL_SURFACE_MSG_SIDEBAR_SURFACE : type;
  message->size = size + prefix;
  if (wrapped) *(AnvilSidebarSurfacePacket *)message->payload = (AnvilSidebarSurfacePacket){view->config.window_id, type};
  if (size) memcpy(message->payload + prefix, payload, size);
  size += prefix;
  SDL_LockMutex(hosted.queue_lock);
  if (hosted.lost) {
    SDL_UnlockMutex(hosted.queue_lock);
    free(message);
    return;
  }
  if (type == ANVIL_SURFACE_MSG_FRAME && hosted.tail && hosted.tail->type == message->type && hosted.tail->size == size &&
      (!wrapped || ((AnvilSidebarSurfacePacket *)hosted.tail->payload)->window_id == view->config.window_id)) {
    memcpy(hosted.tail->payload, message->payload, size);
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

void anvil_hosted_surface_close_decision(AnvilSurfaceCloseDecision decision) {
  AnvilSurfaceInt message = {decision};
  send_message(ANVIL_SURFACE_MSG_CLOSE_DECISION, &message, sizeof(message));
}

void anvil_hosted_surface_dialog_result_failed(void) {
  if (hosted.active) signal_loss("UI file dialog result queue failed", ANVIL_SURFACE_MSG_DIALOG_RESULT, 0);
}
void anvil_hosted_surface_test_packet(bool stale) {
  if (!hosted.active || !SDL_getenv("ANVIL_SURFACE_FAULT_PROBE")) return;
  if (stale) {
    AnvilSurfaceFrame frame = {0};
    frame.configuration = view->config.configuration + 1;
    frame.generation = 1;
    frame.kind = ANVIL_SURFACE_FRAME_SHARED_MEMORY;
    frame.width = view->config.pixel_w; frame.height = view->config.pixel_h;
    SDL_snprintf(frame.name, sizeof(frame.name), "Local\\AnvilSurfaceMemory-%lu-999999", (unsigned long)GetCurrentProcessId());
    send_message(ANVIL_SURFACE_MSG_FRAME, &frame, sizeof(frame));
  } else {
    send_message(ANVIL_SURFACE_MSG_FRAME, "x", 1);
  }
}

static SDL_AtomicInt test_memory_release_failure;
void anvil_hosted_surface_test_memory_release_failure(void) {
  if (hosted.active && SDL_getenv("ANVIL_SURFACE_FAULT_PROBE"))
    SDL_SetAtomicInt(&test_memory_release_failure, 1);
}

bool anvil_hosted_surface_show_dialog(uint32_t id, SDL_FileDialogType type, SDL_PropertiesID props, SDL_DialogFileCallback callback, void *userdata) {
  size_t index = SDL_arraysize(hosted.dialogs);
  for (size_t i = 0; i < SDL_arraysize(hosted.dialogs); i++) {
    if (hosted.dialogs[i].id == id) return SDL_SetError("The file dialog ID is already active");
    if (!hosted.dialogs[i].id) index = i;
  }
  if (index == SDL_arraysize(hosted.dialogs)) return SDL_SetError("Too many file dialogs are active");
  uint32_t size;
  void *packet = anvil_surface_dialog_encode(id, type, props, &size);
  if (!packet) return SDL_SetError("The file dialog request is invalid or exceeds its limit");
  hosted.dialogs[index].id = id;
  hosted.dialogs[index].callback = callback;
  hosted.dialogs[index].userdata = userdata;
  send_message(ANVIL_SURFACE_MSG_DIALOG, packet, size);
  free(packet);
  return true;
}

static void send_exit(AnvilSurfaceMessageType type) {
  if (!hosted.active || !hosted.queue_lock) return;
  SDL_SetAtomicInt(&hosted.intentional_exit, 1);
  ResetEvent(hosted.exit_sent);
  send_message(type, NULL, 0);
  /* Teardown only. Normal frame and window requests never wait for the pipe. */
  if (WaitForSingleObject(hosted.exit_sent, 500) != WAIT_OBJECT_0) SDL_Log("Project exit-intent delivery timed out");
}

void anvil_hosted_surface_exit_intent(bool restart) {
  send_exit(restart ? ANVIL_SURFACE_MSG_RESTART : ANVIL_SURFACE_MSG_EXIT_INTENT);
}

void anvil_hosted_surface_hand_off(void) {
  send_exit(ANVIL_SURFACE_MSG_HAND_OFF);
}

bool anvil_hosted_surface_select_project(const char *path) {
  if (!hosted.active || SDL_GetAtomicInt(&hosted.loss_cause)) return false;
  send_message(ANVIL_SURFACE_MSG_SELECT_PROJECT, path, (uint32_t)strlen(path) + 1);
  return !SDL_GetAtomicInt(&hosted.loss_cause);
}

bool anvil_hosted_surface_new_window(void) {
  if (!hosted.active || !view->config.window_id) return false;
  send_message(ANVIL_SURFACE_MSG_NEW_WINDOW, &view->config.window_id, sizeof(uint32_t));
  return !SDL_GetAtomicInt(&hosted.loss_cause);
}
bool anvil_hosted_surface_move_project(uint32_t project_id, uint32_t target_window_id) {
  if (!hosted.active || !project_id || !target_window_id || SDL_GetAtomicInt(&hosted.loss_cause)) return false;
  AnvilSurfaceMoveProject request = {project_id, target_window_id};
  send_message(ANVIL_SURFACE_MSG_MOVE_PROJECT, &request, sizeof(request));
  return !SDL_GetAtomicInt(&hosted.loss_cause);
}

uint32_t anvil_hosted_surface_window_id(void) { return view->config.window_id; }
bool anvil_hosted_surface_open_project_window(const char *path) {
  if (!hosted.active || !view->config.window_id || !path || !*path) return false;
  size_t size = sizeof(uint32_t) + strlen(path) + 1;
  if (size >= 32768) return false;
  uint8_t *request = malloc(size);
  if (!request) { signal_loss("Open Project request allocation failed", ANVIL_SURFACE_MSG_OPEN_PROJECT_WINDOW, size); return false; }
  memcpy(request, &view->config.window_id, sizeof(uint32_t));
  memcpy(request + sizeof(uint32_t), path, strlen(path) + 1);
  send_message(ANVIL_SURFACE_MSG_OPEN_PROJECT_WINDOW, request, (uint32_t)size);
  free(request);
  return !SDL_GetAtomicInt(&hosted.loss_cause);
}
bool anvil_hosted_surface_open_project_picker(void) {
  if (!hosted.active || !view->config.window_id) return false;
  send_message(ANVIL_SURFACE_MSG_OPEN_PROJECT_PICKER, &view->config.window_id, sizeof(uint32_t));
  return !SDL_GetAtomicInt(&hosted.loss_cause);
}

bool anvil_hosted_surface_unload_project(const char *path) {
  if (!hosted.active || SDL_GetAtomicInt(&hosted.loss_cause)) return false;
  send_message(ANVIL_SURFACE_MSG_UNLOAD_PROJECT, path, (uint32_t)strlen(path) + 1);
  return !SDL_GetAtomicInt(&hosted.loss_cause);
}

void anvil_hosted_surface_runtime_ready(void) {
  if (!hosted.active || hosted.sidebar) return;
  hosted.runtime_ready = true;
  send_message(ANVIL_SURFACE_MSG_RUNTIME_READY, NULL, 0);
}

bool anvil_hosted_surface_set_panes(const char *panes) {
  size_t size = strlen(panes) + 1;
  if (hosted.sidebar || size > ANVIL_SURFACE_PANES_MAX) return false;
  char *copy = _strdup(panes);
  if (!copy) return false;
  free(hosted.panes);
  hosted.panes = copy;
  if (!hosted.active || SDL_GetAtomicInt(&hosted.loss_cause)) return false;
  send_message(ANVIL_SURFACE_MSG_PANES, panes, (uint32_t)size);
  return !SDL_GetAtomicInt(&hosted.loss_cause);
}

bool anvil_hosted_surface_pane_request(const char *path, const AnvilSurfacePaneAction *action) {
  size_t path_size = strlen(path) + 1;
  if (!hosted.active || !hosted.sidebar || !anvil_surface_pane_action_valid(action) || path_size < 2 ||
      path_size >= 32768 || SDL_GetAtomicInt(&hosted.loss_cause))
    return false;
  size_t size = sizeof(*action) + path_size;
  char *request = malloc(size);
  if (!request) { signal_loss("Pane request allocation failed", ANVIL_SURFACE_MSG_PANE_REQUEST, size); return false; }
  memcpy(request, action, sizeof(*action));
  memcpy(request + sizeof(*action), path, path_size);
  send_message(ANVIL_SURFACE_MSG_PANE_REQUEST, request, (uint32_t)size);
  free(request);
  return !SDL_GetAtomicInt(&hosted.loss_cause);
}

bool anvil_hosted_surface_select_terminal(const char *path, const char *id) {
  size_t path_size = strlen(path) + 1;
  if (!hosted.active || !hosted.sidebar || strlen(id) != ANVIL_SURFACE_TERMINAL_ID_LEN || path_size < 2 ||
      path_size >= 32768 || SDL_GetAtomicInt(&hosted.loss_cause))
    return false;
  size_t size = ANVIL_SURFACE_TERMINAL_ID_LEN + 1 + path_size;
  char *request = malloc(size);
  if (!request) { signal_loss("Terminal Session selection allocation failed", ANVIL_SURFACE_MSG_SELECT_TERMINAL, size); return false; }
  memcpy(request, id, ANVIL_SURFACE_TERMINAL_ID_LEN + 1);
  memcpy(request + ANVIL_SURFACE_TERMINAL_ID_LEN + 1, path, path_size);
  send_message(ANVIL_SURFACE_MSG_SELECT_TERMINAL, request, (uint32_t)size);
  free(request);
  return !SDL_GetAtomicInt(&hosted.loss_cause);
}

bool anvil_hosted_surface_project_menu(uint32_t row_id, int x, int y) {
  if (!hosted.active || !hosted.sidebar || !row_id || SDL_GetAtomicInt(&hosted.loss_cause)) return false;
  AnvilSurfaceProjectMenu request = {row_id, x, y};
  send_message(ANVIL_SURFACE_MSG_PROJECT_MENU, &request, sizeof(request));
  return !SDL_GetAtomicInt(&hosted.loss_cause);
}

bool anvil_hosted_surface_toggle_sidebar(void) {
  if (!hosted.active || hosted.sidebar || SDL_GetAtomicInt(&hosted.loss_cause)) return false;
  send_message(ANVIL_SURFACE_MSG_TOGGLE_SIDEBAR, NULL, 0);
  return !SDL_GetAtomicInt(&hosted.loss_cause);
}

bool anvil_hosted_surface_color_theme_saved(void) {
  if (!hosted.active || hosted.sidebar || SDL_GetAtomicInt(&hosted.loss_cause)) return false;
  send_message(ANVIL_SURFACE_MSG_COLOR_THEME_SAVED, NULL, 0);
  return !SDL_GetAtomicInt(&hosted.loss_cause);
}

bool anvil_hosted_surface_zoom_saved(void) {
  if (!hosted.active || hosted.sidebar || SDL_GetAtomicInt(&hosted.loss_cause)) return false;
  send_message(ANVIL_SURFACE_MSG_ZOOM_SAVED, NULL, 0);
  return !SDL_GetAtomicInt(&hosted.loss_cause);
}

bool anvil_hosted_surface_preview_color_theme(const char *preview) {
  if (!hosted.active || hosted.sidebar || SDL_GetAtomicInt(&hosted.loss_cause)) return false;
  size_t size = strlen(preview) + 1;
  if (size > ANVIL_SURFACE_MAX_PAYLOAD) return false;
  send_message(ANVIL_SURFACE_MSG_COLOR_THEME_PREVIEW, preview, (uint32_t)size);
  return !SDL_GetAtomicInt(&hosted.loss_cause);
}

bool anvil_hosted_surface_set_shell_colors(const AnvilSurfaceShellColors *colors) {
  if (!hosted.active || SDL_GetAtomicInt(&hosted.loss_cause)) return false;
  hosted.shell_colors = *colors;
  hosted.has_shell_colors = true;
  send_message(ANVIL_SURFACE_MSG_SHELL_COLORS, colors, sizeof(*colors));
  return !SDL_GetAtomicInt(&hosted.loss_cause);
}

bool anvil_hosted_surface_sidebar_source(const char *userdir, const char *recents) {
  if (!hosted.active || SDL_GetAtomicInt(&hosted.loss_cause))
    return false;
  size_t directory_size = strlen(userdir) + 1, recents_size = strlen(recents) + 1;
  size_t size = sizeof(AnvilSurfaceSidebarSource) + directory_size + recents_size;
  if (size > ANVIL_SURFACE_MAX_PAYLOAD)
    return false;
  AnvilSurfaceSidebarSource *message = malloc(size);
  if (!message)
    return false;
  message->userdir_size = (uint32_t)directory_size;
  memcpy(message + 1, userdir, directory_size);
  memcpy((char *)(message + 1) + directory_size, recents, recents_size);
  send_message(ANVIL_SURFACE_MSG_SIDEBAR_SOURCE, message, (uint32_t)size);
  free(message);
  return !SDL_GetAtomicInt(&hosted.loss_cause);
}
bool anvil_hosted_surface_sidebar_query(int offset, bool refresh) {
  if (!hosted.active || SDL_GetAtomicInt(&hosted.loss_cause))
    return false;
  AnvilSurfaceInt message = {offset};
  if (refresh && !offset) send_message(ANVIL_SURFACE_MSG_SIDEBAR_REFRESH, NULL, 0);
  send_message(ANVIL_SURFACE_MSG_SIDEBAR_QUERY, &message, sizeof(message));
  return !SDL_GetAtomicInt(&hosted.loss_cause);
}

static void send_int(uint16_t type, int value) {
  AnvilSurfaceInt message = { value };
  send_message(type, &message, sizeof(message));
}

/* Opens a shell's surface pipe, checks its server, greets it, and reads its first configuration. */
static AnvilIPCPipe *open_shell_pipe(const char *name, DWORD pid, AnvilSurfaceConfigure *config, HANDLE *process) {
  HANDLE handle = INVALID_HANDLE_VALUE;
  Uint64 deadline = SDL_GetTicks() + CONNECT_TIMEOUT_MS;
  for (;;) {
    handle = CreateFileA(name, GENERIC_READ | GENERIC_WRITE, 0, NULL,
                         OPEN_EXISTING,
                         FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
                         NULL);
    if (handle != INVALID_HANDLE_VALUE) break;
    if (GetLastError() != ERROR_PIPE_BUSY || SDL_GetTicks() >= deadline) {
      SDL_Log("Hosted surface could not open the shell pipe: %lu",
              (unsigned long)GetLastError());
      return NULL;
    }
    WaitNamedPipeA(name, 100);
  }
  AnvilIPCPipe *pipe = calloc(1, sizeof(*pipe));
  if (!pipe || !anvil_ipc_pipe_init(pipe, handle, ANVIL_SURFACE_PROTOCOL_VERSION, ANVIL_SURFACE_MAX_PAYLOAD)) {
    free(pipe);
    CloseHandle(handle);
    return NULL;
  }
  ULONG server = 0;
  if (!GetNamedPipeServerProcessId(handle, &server) || server != pid ||
      !(*process = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, server))) {
    SDL_Log("Project rejected shell pipe identity: expected=%lu actual=%lu", (unsigned long)pid, (unsigned long)server);
    anvil_ipc_pipe_close(pipe);
    free(pipe);
    return NULL;
  }
  pipe->timeout_ms = CONNECT_TIMEOUT_MS;

  AnvilSurfaceHello hello = { (uint32_t)GetCurrentProcessId() };
  AnvilIPCHeader header = { 0 };
  bool greeted = anvil_ipc_pipe_write(pipe, ANVIL_SURFACE_MSG_HELLO, &hello, sizeof(hello), NULL, 0);
  /* Startup reads the display scale and initial size, so wait for them. */
  bool read = greeted && anvil_ipc_pipe_read(pipe, &header, config, sizeof(*config));
  if (!read || header.type != ANVIL_SURFACE_MSG_CONFIGURE || header.size != sizeof(*config) || !valid_configure(config)) {
    SDL_Log("Hosted surface did not receive its first configuration: greeted=%d read=%d type=%u size=%u error=%lu",
            greeted, read, (unsigned)header.type, (unsigned)header.size, (unsigned long)GetLastError());
    CloseHandle(*process);
    *process = NULL;
    anvil_ipc_pipe_close(pipe);
    free(pipe);
    return NULL;
  }
  pipe->timeout_ms = INFINITE;
  return pipe;
}

bool anvil_hosted_surface_connect(void) {
  if (!hosted.active) return false;
  AnvilSurfaceConfigure config;
  hosted.pipe = open_shell_pipe(hosted.pipe_name, hosted.shell_pid, &config, &hosted.shell_process);
  if (!hosted.pipe) return false;
  view->config = config;
  view->config_applied = true;

  hosted.queue_lock = SDL_CreateMutex(); hosted.queue_condition = SDL_CreateCondition();
  hosted.loss_signal = CreateEventW(NULL, TRUE, FALSE, NULL);
  hosted.inbound_signal = CreateEventW(NULL, FALSE, FALSE, NULL);
  hosted.exit_sent = CreateEventW(NULL, TRUE, FALSE, NULL);
  hosted.adoption_ready = CreateEventW(NULL, TRUE, FALSE, NULL);
  hosted.loss_event = SDL_RegisterEvents(1);
  hosted.receive_event = SDL_RegisterEvents(1);
  hosted.geometry_event = SDL_RegisterEvents(1);
  hosted.adopted_event = SDL_RegisterEvents(1);
  hosted.gone_event = SDL_RegisterEvents(1);
  hosted.update_event = SDL_RegisterEvents(1);
  if (!hosted.queue_lock || !hosted.queue_condition || !hosted.loss_signal || !hosted.exit_sent ||
      !hosted.adoption_ready || hosted.loss_event == (Uint32)-1 || hosted.receive_event == (Uint32)-1 ||
      hosted.geometry_event == (Uint32)-1 || hosted.adopted_event == (Uint32)-1 || hosted.gone_event == (Uint32)-1 ||
      hosted.update_event == (Uint32)-1)
    return false;
  SDL_Thread *writer = SDL_CreateThread(writer_thread, "anvil-project-writer", NULL);
  SDL_Thread *watchdog = SDL_CreateThread(loss_watchdog, "anvil-project-deadline", NULL);
  if (!writer || !watchdog) return false;
  SDL_DetachThread(writer); SDL_DetachThread(watchdog);

  SDL_SetAtomicInt(&hosted.reader_running, 1);
  hosted.reader = SDL_CreateThread(reader_thread, "anvil-hosted-input", hosted.pipe);
  if (!hosted.reader) return false;
  SDL_DetachThread(hosted.reader);
  return true;
}

void anvil_hosted_surface_register_window(SDL_Window *window) {
  if (!hosted.active || view->window || !window) return;
  view->window = window;
  view->window_id = SDL_GetWindowID(window);
  apply_window_size();
}

bool anvil_hosted_surface_is_window(SDL_Window *window) {
  if (!hosted.active || !window) return false;
  for (HostedView *item = views; item; item = item->next)
    if (item->window == window) { view = item; return true; }
  return false;
}
static void remove_view(HostedView *item) {
  HostedView **link = &views;
  while (*link && *link != item) link = &(*link)->next;
  if (!*link) return;
  item->window = NULL; item->window_id = 0;
  release_memory_frame(&item->memory);
  if (item != &first_view) {
    *link = item->next;
    if (view == item) view = &first_view;
    free(item);
  } else item->config.window_id = 0;
}
void anvil_hosted_surface_unregister_window(SDL_Window *window) {
  for (HostedView *item = views; item; item = item->next) {
    if (item->window == window) { remove_view(item); return; }
  }
}

void anvil_hosted_surface_set_background(SDL_Window *window, uint32_t background) {
  if (anvil_hosted_surface_is_window(window)) view->background = background;
}
void anvil_hosted_surface_set_overlay(SDL_Window *window, uint32_t overlay, const AnvilSurfaceArea *raised,
                                      int count) {
  if (!anvil_hosted_surface_is_window(window)) return;
  view->overlay = overlay;
  memset(view->raised, 0, sizeof(view->raised));
  count = SDL_clamp(count, 0, ANVIL_SURFACE_RAISED_MAX);
  if (count) memcpy(view->raised, raised, (size_t)count * sizeof(*raised));
}
int anvil_hosted_surface_content_x(void) { return hosted.active ? view->config.content_x : 0; }

void anvil_hosted_surface_publish_d3d11(SDL_Window *window, const char *name, int width, int height) {
  if (!anvil_hosted_surface_should_render()) return;
  if (SDL_getenv("ANVIL_SURFACE_FAULT_PROBE") && SDL_getenv("ANVIL_SURFACE_FAULT_NO_FRAME")) return;
  if (!anvil_hosted_surface_is_window(window) || !name) return;
  AnvilSurfaceFrame frame;
  memset(&frame, 0, sizeof(frame));
  frame.kind = ANVIL_SURFACE_FRAME_D3D11;
  frame.generation = ++view->frame_generation;
  frame.configuration = view->config.configuration;
  frame.width = width;
  frame.height = height;
  frame.background = view->background;
  frame.overlay = view->overlay;
  memcpy(frame.raised, view->raised, sizeof(frame.raised));
  frame.input_seq = anvil_latency_probe_consumed_seq();
  anvil_latency_probe_stage("frame-published");
  SDL_strlcpy(frame.name, name, sizeof(frame.name));
  send_message(ANVIL_SURFACE_MSG_FRAME, &frame, sizeof(frame));
  if (view->resize_configured_ns && width == view->config.pixel_w && height == view->config.pixel_h) {
    SDL_Log("Hosted resize frame: %dx%d configure_to_publish_ms=%.1f", width, height,
            (double)(SDL_GetTicksNS() - view->resize_configured_ns) / SDL_NS_PER_MS);
    view->resize_configured_ns = 0;
  }
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
  static uint32_t serial;
  SharedMemoryFrame *memory = &view->memory;
  if (memory->view && memory->capacity >= needed) return true;
  release_memory_frame(memory);
  /* Grow with slack so a live resize does not replace the mapping each frame. */
  size_t capacity = needed + needed / 4;
  memory->generation++;
  if (serial == UINT32_MAX) return false;
  snprintf(memory->name, sizeof(memory->name), "Local\\AnvilSurfaceMemory-%lu-%u",
           (unsigned long)GetCurrentProcessId(), ++serial);
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
  if (!anvil_hosted_surface_should_render()) return true;
  if (SDL_GetAtomicInt(&hosted.loss_cause)) return false;
  if (SDL_getenv("ANVIL_SURFACE_FAULT_PROBE") && SDL_getenv("ANVIL_SURFACE_FAULT_NO_FRAME")) return true;
  if (SDL_BYTESPERPIXEL(surface->format) != 4) return false;
  int stride = surface->w * 4;
  size_t needed = sizeof(AnvilSurfaceMemoryHeader) + (size_t)stride * (size_t)surface->h;
  uint32_t old_generation = view->memory.generation;
  if (!ensure_memory_frame(needed)) return false;
  bool full = view->memory.generation != old_generation;

  DWORD wait = WaitForSingleObject(view->memory.mutex, MEMORY_LOCK_TIMEOUT_MS);
  if (wait != WAIT_OBJECT_0 && wait != WAIT_ABANDONED) return false;
  AnvilSurfaceMemoryHeader *header = (AnvilSurfaceMemoryHeader *)view->memory.view;
  if (header->width != surface->w || header->height != surface->h) full = true;
  uint8_t *pixels = view->memory.view + sizeof(AnvilSurfaceMemoryHeader);
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
  header->generation = ++view->frame_generation;
  header->configuration = view->config.configuration;
  BOOL released = ReleaseMutex(view->memory.mutex);
  if (SDL_CompareAndSwapAtomicInt(&test_memory_release_failure, 1, 0)) {
    released = FALSE;
    SetLastError(ERROR_NOT_OWNER);
  }
  if (!released) {
    signal_loss("Project shared memory mutex release failed", ANVIL_SURFACE_MSG_FRAME, 0);
    return false;
  }

  AnvilSurfaceFrame frame;
  memset(&frame, 0, sizeof(frame));
  frame.kind = ANVIL_SURFACE_FRAME_SHARED_MEMORY;
  frame.generation = header->generation;
  frame.configuration = header->configuration;
  frame.width = surface->w;
  frame.height = surface->h;
  frame.background = view->background;
  frame.overlay = view->overlay;
  memcpy(frame.raised, view->raised, sizeof(frame.raised));
  frame.input_seq = anvil_latency_probe_consumed_seq();
  anvil_latency_probe_stage("frame-published");
  SDL_strlcpy(frame.name, view->memory.name, sizeof(frame.name));
  send_message(ANVIL_SURFACE_MSG_FRAME, &frame, sizeof(frame));
  return true;
}

bool anvil_hosted_surface_has_focus(void) {
  return SDL_GetAtomicInt(&view->focused) != 0;
}

bool anvil_hosted_surface_should_render(void) {
  return !hosted.active || (view->config.render_enabled != 0 && !SDL_GetAtomicInt(&hosted.loss_cause));
}

float anvil_hosted_surface_display_scale(void) {
  return view->config.display_scale > 0 ? view->config.display_scale : 1.0f;
}

float anvil_hosted_surface_refresh_rate(void) {
  return view->config.refresh_hz;
}

AnvilSurfaceWindowMode anvil_hosted_surface_window_mode(void) {
  return (AnvilSurfaceWindowMode)view->config.window_mode;
}

void anvil_hosted_surface_window_bounds(int *x, int *y, int *w, int *h) {
  if (x) *x = view->config.window_x;
  if (y) *y = view->config.window_y;
  if (w) *w = view->config.window_w;
  if (h) *h = view->config.window_h;
}

void anvil_hosted_surface_set_cursor(AnvilSurfaceCursor cursor) {
  if ((int)cursor == view->last_cursor) return;
  view->last_cursor = (int)cursor;
  send_int(ANVIL_SURFACE_MSG_CURSOR, (int)cursor);
}

void anvil_hosted_surface_set_text_input(bool active) {
  view->text_active = active;
  AnvilSurfaceTextInput message = { .active = active ? 1 : 0, .cursor = -1 };
  message.configuration = view->config.configuration;
  send_message(ANVIL_SURFACE_MSG_TEXT_INPUT, &message, sizeof(message));
}

void anvil_hosted_surface_set_text_input_area(const SDL_Rect *rect, int cursor) {
  if (!rect) return;
  AnvilSurfaceTextInput message = { -1, rect->x, rect->y, rect->w, rect->h, cursor };
  message.configuration = view->config.configuration;
  send_message(ANVIL_SURFACE_MSG_TEXT_INPUT, &message, sizeof(message));
}

void anvil_hosted_surface_clear_ime(void) {
  send_message(ANVIL_SURFACE_MSG_CLEAR_IME, &view->config.configuration, sizeof(uint64_t));
}

void anvil_hosted_surface_set_window_mode(AnvilSurfaceWindowMode mode) {
  send_int(ANVIL_SURFACE_MSG_WINDOW_MODE, (int)mode);
}

void anvil_hosted_surface_set_title(const char *title) {
  if (!title) return;
  size_t len = strlen(title);
  if (len > 4096) len = 4096;
  if (title != hosted.title) {
    memcpy(hosted.title, title, len);
    hosted.title[len] = 0;
    hosted.has_title = true;
  }
  send_message(ANVIL_SURFACE_MSG_TITLE, title, (uint32_t)len);
}

void anvil_hosted_surface_set_hit_test(const AnvilSurfaceHitTest *hit_test) {
  if (!hit_test) return;
  hosted.hit_test = *hit_test;
  hosted.has_hit_test = true;
  AnvilSurfaceHitTest message = *hit_test;
  message.configuration = view->config.configuration;
  send_message(ANVIL_SURFACE_MSG_HIT_TEST, &message, sizeof(message));
}

void anvil_hosted_surface_set_bordered(bool bordered) {
  hosted.bordered = bordered;
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

void anvil_hosted_surface_set_visible(bool visible) {
  hosted.visible = visible;
  send_int(ANVIL_SURFACE_MSG_VISIBLE, visible);
}
bool anvil_hosted_surface_set_opacity(float opacity) {
  if (!(opacity >= 0 && opacity <= 1)) return false;
  send_message(ANVIL_SURFACE_MSG_OPACITY, &opacity, sizeof(opacity)); return true;
}
bool anvil_hosted_surface_frame_metrics(int *button, int *title, int *border) {
  if (!view->config_applied) return false;
  *button = view->config.button_width; *title = view->config.title_height; *border = view->config.resize_border;
  return true;
}

#else
bool anvil_hosted_surface_move_project(uint32_t project_id, uint32_t target_window_id) {
  (void)project_id; (void)target_window_id; return false;
}
void anvil_hosted_surface_unregister_window(SDL_Window *window) { (void)window; }
size_t anvil_hosted_surface_sidebar_views(uint32_t *ids, bool *removed, size_t capacity) {
  (void)ids; (void)removed; (void)capacity; return 0;
}
bool anvil_hosted_surface_sidebar_activate(uint32_t id) { (void)id; return false; }
bool anvil_hosted_surface_sidebar(void) { return false; }

bool anvil_hosted_surface_parse_args(int *argc, char **argv) { (void)argc; (void)argv; return false; }
bool anvil_hosted_surface_connect(void) { return false; }
bool anvil_hosted_surface_active(void) { return false; }
bool anvil_hosted_surface_dispatch(const SDL_Event *event) { (void)event; return false; }
void anvil_hosted_surface_poll(void) {}
bool anvil_hosted_surface_wait_inbound(double seconds) { (void)seconds; return false; }
bool anvil_hosted_surface_take_sidebar_query_needed(void) { return false; }
bool anvil_hosted_surface_configuration_event(Uint32 type) { (void)type; return false; }
uint32_t anvil_hosted_surface_shell_pid(void) { return 0; }
void anvil_hosted_surface_controls(int *x, int *y, int *w, int *h) { *x = *y = *w = *h = 0; }
bool anvil_hosted_surface_parse_valid(void) { return true; }
bool anvil_hosted_surface_restarted(void) { return false; }
bool anvil_hosted_surface_loss_event(Uint32 type) { (void)type; return false; }
bool anvil_hosted_surface_adopted_event(Uint32 type) { (void)type; return false; }
bool anvil_hosted_surface_gone_event(Uint32 type) { (void)type; return false; }
bool anvil_hosted_surface_update_event(Uint32 type) { (void)type; return false; }
bool anvil_hosted_surface_await_adoption(void) { return false; }
void anvil_hosted_surface_finish_adoption(void) {}
void anvil_hosted_surface_exit_intent(bool restart) { (void)restart; }
void anvil_hosted_surface_hand_off(void) {}
void anvil_hosted_surface_close_decision(AnvilSurfaceCloseDecision decision) { (void)decision; }
void anvil_hosted_surface_dialog_result_failed(void) {}
void anvil_hosted_surface_render_failed(const char *cause) { (void)cause; }
void anvil_hosted_surface_test_packet(bool stale) { (void)stale; }
void anvil_hosted_surface_test_memory_release_failure(void) {}
bool anvil_hosted_surface_show_dialog(uint32_t id, SDL_FileDialogType type, SDL_PropertiesID props, SDL_DialogFileCallback callback, void *userdata) {
  (void)id; (void)type; (void)props; (void)callback; (void)userdata; return false;
}
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
bool anvil_hosted_surface_should_render(void) { return true; }
bool anvil_hosted_surface_select_project(const char *path) { (void)path; return false; }
bool anvil_hosted_surface_new_window(void) { return false; }
uint32_t anvil_hosted_surface_window_id(void) { return 0; }
void anvil_hosted_surface_set_background(SDL_Window *window, uint32_t background) {
  (void)window; (void)background;
}
void anvil_hosted_surface_set_overlay(SDL_Window *window, uint32_t overlay, const AnvilSurfaceArea *raised,
                                      int count) {
  (void)window; (void)overlay; (void)raised; (void)count;
}
int anvil_hosted_surface_content_x(void) { return 0; }
bool anvil_hosted_surface_open_project_window(const char *path) { (void)path; return false; }
bool anvil_hosted_surface_open_project_picker(void) { return false; }
bool anvil_hosted_surface_preview_color_theme(const char *preview) { (void)preview; return false; }
bool anvil_hosted_surface_unload_project(const char *path) { (void)path; return false; }
bool anvil_hosted_surface_color_theme_saved(void) { return false; }
bool anvil_hosted_surface_zoom_saved(void) { return false; }
bool anvil_hosted_surface_toggle_sidebar(void) { return false; }
bool anvil_hosted_surface_project_menu(uint32_t row_id, int x, int y) { (void)row_id; (void)x; (void)y; return false; }
bool anvil_hosted_surface_set_panes(const char *panes) { (void)panes; return false; }
void anvil_hosted_surface_runtime_ready(void) {}
bool anvil_hosted_surface_pane_request(const char *path, const AnvilSurfacePaneAction *action) {
  (void)path; (void)action; return false;
}
bool anvil_hosted_surface_select_terminal(const char *path, const char *id) { (void)path; (void)id; return false; }
bool anvil_hosted_surface_set_shell_colors(const AnvilSurfaceShellColors *colors) {
  (void)colors;
  return false;
}
bool anvil_hosted_surface_sidebar_source(const char *userdir, const char *recents) {
  (void)userdir;
  (void)recents;
  return false;
}
bool anvil_hosted_surface_sidebar_query(int offset, bool refresh) {
  (void)refresh;
  (void)offset;
  return false;
}
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
