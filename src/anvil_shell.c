#include "anvil_shell.h"

#ifdef _WIN32

#include "surface_protocol.h"
#include "input_latency_probe.h"
#include "cli_args.h"
#include "win32_frame_hwnd.h"

#include <windowsx.h>
#include <commctrl.h>
#include <d3d11_1.h>
#include <dxgi1_2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef SAFE_RELEASE
#define SAFE_RELEASE(p) do { if (p) { (p)->lpVtbl->Release(p); (p) = NULL; } } while (0)
#endif

/* The sidebar is a placeholder strip until the Sidebar process exists. It
 * exercises the offset path for input, hit testing, IME, and compositing. */
#define SHELL_SIDEBAR_POINTS 48
#define SHELL_CONNECT_TIMEOUT_MS 30000
#define SHELL_WRITE_QUEUE_LIMIT (8u * 1024u * 1024u)
#define SHELL_SYNC_TIMEOUT_MS 0
#define SHELL_PIPE_BUFFER (64u * 1024u)
/* How long one resize step waits for a surface frame of the new size. */
#define SHELL_RESIZE_WAIT_MS 50
#define SHELL_CLOSE_TIMEOUT_MS 5000

/* Owned-window fault actions. These require the isolated test environment. */
#define SHELL_FAULT_MESSAGE (WM_APP + 0x4b)
#define SHELL_CONTROL_MESSAGE (WM_APP + 0x4c)
enum {
  FAULT_ALLOC = 1,
  FAULT_EVENT,
  FAULT_OPEN,
  FAULT_ACQUIRE,
  FAULT_PRESENT,
  FAULT_RESIZE,
  FAULT_WRITE,
  FAULT_PIPE,
  FAULT_BUSY,
  FAULT_BLOCK_WRITE,
  FAULT_RELEASE,
  FAULT_SELECT_ALLOC
};
static SDL_AtomicInt probe_fault;
static bool take_fault(int point) { return SDL_CompareAndSwapAtomicInt(&probe_fault, point, 0); }

typedef struct ShellMessage {
  struct ShellMessage *next;
  struct ShellProject *owner;
  uint16_t type;
  uint32_t size;
  uint8_t payload[];
} ShellMessage;

/* SDL user event codes posted by the shell's pipe threads. */
enum {
  SHELL_EVENT_CONNECTED = 1,
  SHELL_EVENT_MESSAGE,
  SHELL_EVENT_FRAME,
  SHELL_EVENT_EXITED,
  SHELL_EVENT_DISCONNECTED,
  SHELL_EVENT_DIALOG_RESULT,
  SHELL_EVENT_CLOSE_TIMEOUT,
  SHELL_EVENT_FORCE_RESULT,
  SHELL_EVENT_START_TIMEOUT,
  SHELL_EVENT_LAUNCHED,
};

typedef enum { SHELL_STARTING, SHELL_READY, SHELL_CLOSING, SHELL_FAILED, SHELL_DORMANT } ShellState;
typedef struct DormantProject {
  struct DormantProject *next;
  Uint32 id;
  char *path, *title;
  wchar_t *identity;
} DormantProject;
typedef struct ShellDialog ShellDialog;
typedef struct ProjectLaunch ProjectLaunch;
typedef struct ProjectResolve ProjectResolve;

typedef struct ShellProject {
  struct ShellProject *next;
  Uint32 id;
  char *title;
  UINT_PTR startup_timer;
  PROCESS_INFORMATION process;
  SDL_Thread *reader, *writer;
  SDL_Thread *launcher;
  ProjectLaunch *launch;
  unsigned launch_attempt;
  bool writer_stop;
  bool intentional_exit;
  bool failed_close;
  bool unloading;
  DormantProject *dormant;
  char *restart_path, *project_path;
  wchar_t *identity;
  bool resolving;
  AnvilIPCPipe pipe;
  bool connected;
  Uint32 connection;
  bool text_active;
  SDL_Mutex *lock;
  SDL_Condition *queue_cond;
  ShellMessage *queue_head, *queue_tail;
  size_t queue_bytes;
  AnvilSurfaceFrame latest_frame;
  bool frame_pending;
  SDL_Condition *frame_cond;
  AnvilSurfaceConfigure last_config;
  AnvilSurfaceHitTest hit;
  int child_cursor;
  Uint64 close_requested_ns;
  SDL_TimerID close_timer;
  Uint32 close_serial;
  bool close_prompt;
  bool close_waiting;
  uint32_t dialogs[ANVIL_SURFACE_DIALOG_LIMIT];
  ShellDialog *deferred_dialogs[ANVIL_SURFACE_DIALOG_LIMIT];
  SDL_AtomicInt dialog_failure;
  SDL_AtomicInt references;
  SDL_AtomicInt transport_failure, inbound_bytes, reader_done, writer_done;
  ShellState state;
} ShellProject;

typedef struct {
  ShellProject *projects, *selected;
  ShellProject *retiring, *empty;
  DormantProject *dormants;
  Uint32 next_connection, next_project;
  bool closing;
  ProjectResolve *resolvers;
  unsigned resolve_revision;
  UINT_PTR resolve_timer;
  UINT_PTR retire_timer;
  SDL_Window *window;
  HWND hwnd;
  WNDPROC sdl_wndproc;
  Uint32 event_type;

  ID3D11Device *device;
  ID3D11Device1 *device1;
  ID3D11DeviceContext *context;
  IDXGISwapChain1 *swapchain;
  ID3D11Texture2D *backbuffer;
  ID3D11RenderTargetView *rtv;
  bool render_failed;
  const char *gpu_failure;
  int buffer_w, buffer_h;

  /* Private copy of the newest surface frame. */
  ID3D11Texture2D *surface;
  int surface_w, surface_h;
  bool have_surface;

  ID3D11Texture2D *shared;
  IDXGIKeyedMutex *shared_mutex;
  char shared_name[ANVIL_SURFACE_NAME_MAX];

  HANDLE memory_mapping;
  HANDLE memory_mutex;
  const uint8_t *memory_view;
  size_t memory_size;
  char memory_name[ANVIL_SURFACE_NAME_MAX];


  /* Frames coalesce: the main thread composites only the newest one. */

  /* Resize steps present only after the surface catches up to the new size.
   * A step that times out stops that wait until a matching frame arrives, so
   * a slow surface process can not make every step wait. */
  bool live_resize;
  bool resize_wait_disabled;

  float scale;
  int sidebar_w;
  Uint32 surface_buttons;
  float pointer_x, pointer_y;
  bool pointer_in_surface;
  SDL_Cursor *cursors[ANVIL_SURFACE_CURSOR_COUNT];
  bool shown;
  ID3D11Texture2D *ui;
  int ui_w, ui_h;
  bool ui_dirty;
  bool ui_hover_dirty;
  HDC ui_dc;
  HBITMAP ui_bitmap;
  HGDIOBJ ui_old_bitmap;
  void *ui_pixels;
  bool frame_busy;
  SDL_AtomicInt retry_frame;
  SDL_TimerID retry_timer;
  int hovered_control, pressed_control;
  RECT controls, restart_button, close_button;
  RECT failure_card;
} Shell;

static Shell shell;
static bool start_project(ShellProject *project, int argc, char **argv);
static void composite_and_present(void);
static void request_close(ShellProject *project);
static void cancel_input(void);
static void set_state(ShellProject *project, ShellState state);
static void check_transport_failure(ShellProject *project);
static void check_gpu_failure(void);
static void close_memory_frame(void);
static bool select_project_path(const char *path);
static void select_project(ShellProject *project);
static void present_deferred_dialogs(ShellProject *project);
static void finish_launch(ShellProject *project);
static void finish_resolutions(void);
static bool unload_project_path(const char *path);
static void begin_unload(ShellProject *project);
static void drain_retired_projects(void);
static void drain_retired_projects(void);
static ShellProject *project_for_connection(Uint32 connection) {
  for (ShellProject *project = shell.projects; project; project = project->next)
    if (project->connection == connection)
      return project;
  return NULL;
}
static ShellProject *allocate_project(void) {
  ShellProject *project = calloc(1, sizeof(*project));
  if (!project)
    return NULL;
  project->lock = SDL_CreateMutex();
  project->queue_cond = SDL_CreateCondition();
  project->frame_cond = SDL_CreateCondition();
  if (!project->lock || !project->queue_cond || !project->frame_cond) {
    SDL_DestroyMutex(project->lock);
    SDL_DestroyCondition(project->queue_cond);
    SDL_DestroyCondition(project->frame_cond);
    free(project);
    return NULL;
  }
  SDL_SetAtomicInt(&project->references, 1);
  project->child_cursor = ANVIL_SURFACE_CURSOR_ARROW;
  return project;
}
static ShellProject *new_project(void) {
  ShellProject *project = allocate_project();
  if (!project)
    return NULL;
  project->id = ++shell.next_project;
  project->next = shell.projects;
  shell.projects = project;
  return project;
}

static ShellProject *retain_project(ShellProject *project) {
  SDL_AddAtomicInt(&project->references, 1);
  return project;
}

/* The registry owns one reference until all transport threads have been joined.
 * Packets and dialog callbacks can retain it after removal from that registry. */
static void release_project(ShellProject *project) {
  if (SDL_AddAtomicInt(&project->references, -1) != 1)
    return;
  SDL_Log("Shell freed Project runtime: id=%u connection=%u", project->id, project->connection);
  anvil_ipc_pipe_close(&project->pipe);
  if (project->process.hThread)
    CloseHandle(project->process.hThread);
  if (project->process.hProcess)
    CloseHandle(project->process.hProcess);
  SDL_DestroyCondition(project->frame_cond);
  SDL_DestroyCondition(project->queue_cond);
  SDL_DestroyMutex(project->lock);
  free(project->title);
  free(project->restart_path);
  free(project->project_path);
  free(project->identity);
  free(project->dormant);
  free(project);
}

static void free_message(ShellMessage *message) {
  if (message->owner)
    release_project(message->owner);
  free(message);
}
enum { FAILURE_ALLOC = 1, FAILURE_EVENT, FAILURE_PACKET, FAILURE_OVERFLOW };
static void report_transport_failure(ShellProject *project, int reason) {
  SDL_CompareAndSwapAtomicInt(&project->transport_failure, 0, reason);
  SDL_Event event = {0};
  event.type = shell.event_type;
  event.user.code = SHELL_EVENT_FRAME;
  event.user.windowID = project->connection;
  SDL_PushEvent(&event);
}
static void stop_close_timer(ShellProject *project) {
  if (project->close_timer)
    SDL_RemoveTimer(project->close_timer);
  project->close_timer = 0;
}
static Uint32 SDLCALL close_timeout(void *data, SDL_TimerID timer, Uint32 interval) {
  (void)timer;
  (void)interval;
  uintptr_t tag = (uintptr_t)data;
  SDL_Event event = {0};
  event.type = shell.event_type;
  event.user.code = SHELL_EVENT_CLOSE_TIMEOUT;
  event.user.windowID = (Uint32)tag;
  event.user.data2 = (void *)(tag >> 32);
  SDL_PushEvent(&event);
  return 0;
}
static void arm_close_timer(ShellProject *project) {
  stop_close_timer(project);
  project->close_waiting = false;
  uintptr_t tag = ((uintptr_t)project->close_serial << 32) | project->connection;
  project->close_timer = SDL_AddTimer(SHELL_CLOSE_TIMEOUT_MS, close_timeout, (void *)tag);
}
static void fail_connection(ShellProject *project, const char *cause) {
  SDL_Log("Shell connection failed: %s; Project=%u connection=%u", cause, project->id,
          project->connection);
  project->connected = false;
  stop_close_timer(project);
  if (project == shell.selected)
    cancel_input();
  anvil_ipc_pipe_cancel(&project->pipe);
  if (project->pipe.handle)
    DisconnectNamedPipe(project->pipe.handle);
  set_state(project, SHELL_FAILED);
  if (project == shell.selected) {
    SDL_SetWindowTitle(shell.window, "Anvil - Project failed");
    composite_and_present();
  }
}
static void check_transport_failure(ShellProject *project) {
  int reason = SDL_GetAtomicInt(&project->transport_failure);
  if (!reason || project->state == SHELL_FAILED)
    return;
  static const char *causes[] = {"", "inbound allocation failed", "inbound notification failed",
                                 "invalid surface packet", "inbound queue overflow"};
  fail_connection(project, causes[reason]);
}
static Uint32 SDLCALL retry_frame(void *data, SDL_TimerID timer, Uint32 interval) {
  (void)timer;
  if (!SDL_GetAtomicInt(&shell.retry_frame))
    return 0;
  SDL_Event event = {0};
  event.type = shell.event_type;
  event.user.code = SHELL_EVENT_FRAME;
  event.user.windowID = (Uint32)(uintptr_t)data;
  SDL_PushEvent(&event);
  return interval;
}

static void set_frame_busy(bool busy) {
  ShellProject *project = shell.selected;
  shell.frame_busy = busy;
  SDL_SetAtomicInt(&shell.retry_frame, busy);
  if (busy && !shell.retry_timer) {
    shell.retry_timer = SDL_AddTimer(16, retry_frame, (void *)(uintptr_t)project->connection);
    SDL_Log("Shell frame retry started; last safe frame=%s", shell.have_surface ? "retained" : "none");
  } else if (!busy && shell.retry_timer) {
    SDL_RemoveTimer(shell.retry_timer);
    shell.retry_timer = 0;
    SDL_Log("Shell frame retry stopped");
  }
}

static void set_state(ShellProject *project, ShellState state) {
  if (project->state == state)
    return;
  project->state = state;
  if (state != SHELL_STARTING && project->startup_timer) {
    KillTimer(shell.hwnd, project->startup_timer);
    project->startup_timer = 0;
  }
  if (project == shell.selected) {
    shell.ui_dirty = true;
    if (state == SHELL_STARTING || state == SHELL_FAILED)
      set_frame_busy(false);
  }
  static const char *names[] = {"Starting", "Ready", "Closing", "Failed", "Dormant"};
  SDL_Log("Shell state: %s Project=%u connection=%u", names[state], project->id,
          project->connection);
}

static void controls_geometry(void) {
  int width = SDL_min(SDL_max(1, shell.buffer_w - shell.sidebar_w), (int)(138 * shell.scale));
  int height = SDL_min(shell.buffer_h, SDL_max(1, (int)(32 * shell.scale)));
  RECT rect = {shell.buffer_w - width, 0, shell.buffer_w, height};
  if (memcmp(&rect, &shell.controls, sizeof(rect))) {
    shell.controls = rect;
    shell.ui_dirty = true;
    SDL_Log("Shell controls: x=%ld y=%ld w=%ld h=%ld sidebar=%d", rect.left, rect.top,
            rect.right - rect.left, rect.bottom - rect.top, shell.sidebar_w);
  }
}

/* ------------------------------------------------------------------------ */
/* Child process                                                            */

static size_t append_quoted_arg(char *out, const char *arg) {
  size_t n = 0;
  bool quote = arg[0] == '\0' || strpbrk(arg, " \t\n\v\"") != NULL;
  if (!quote) {
    size_t len = strlen(arg);
    memcpy(out, arg, len);
    return len;
  }
  out[n++] = '"';
  for (const char *p = arg;; p++) {
    size_t slashes = 0;
    while (*p == '\\') { slashes++; p++; }
    if (*p == '\0') {
      for (size_t i = 0; i < slashes * 2; i++) out[n++] = '\\';
      break;
    }
    if (*p == '"') {
      for (size_t i = 0; i < slashes * 2 + 1; i++) out[n++] = '\\';
    } else {
      for (size_t i = 0; i < slashes; i++) out[n++] = '\\';
    }
    out[n++] = *p;
  }
  out[n++] = '"';
  return n;
}

static wchar_t *build_child_command_line(ShellProject *project, const wchar_t *exe,
                                         const char *pipe_arg, int argc, char **argv) {
  int exe_len = WideCharToMultiByte(CP_UTF8, 0, exe, -1, NULL, 0, NULL, NULL);
  size_t capacity =
      (size_t)exe_len * 2 + strlen(pipe_arg) * 2 + strlen(project->project_path) * 2 + 128;
  for (int i = 2; i < argc; i++) capacity += strlen(argv[i]) * 2 + 4;
  char *exe_utf8 = malloc((size_t)exe_len);
  char *line = malloc(capacity);
  wchar_t *wide = NULL;
  if (exe_utf8 && line) {
    WideCharToMultiByte(CP_UTF8, 0, exe, -1, exe_utf8, exe_len, NULL, NULL);
    size_t n = append_quoted_arg(line, exe_utf8);
    line[n++] = ' '; n += append_quoted_arg(line + n, ANVIL_PROJECT_ARG);
    line[n++] = ' ';
    n += append_quoted_arg(line + n, project->project_path);
    line[n++] = ' ';
    n += append_quoted_arg(line + n, pipe_arg);
    if (project->restart_path) {
      line[n++] = ' ';
      n += append_quoted_arg(line + n, ANVIL_PROJECT_RESTART_ARG);
    }
    if (argc > 2) { line[n++] = ' '; n += append_quoted_arg(line + n, ANVIL_PROJECT_ARGUMENTS_ARG); }
    for (int i = 2; i < argc; i++) {
      line[n++] = ' ';
      n += append_quoted_arg(line + n, argv[i]);
    }
    line[n] = '\0';
    int wide_len = MultiByteToWideChar(CP_UTF8, 0, line, -1, NULL, 0);
    wide = wide_len > 0 ? malloc(sizeof(wchar_t) * (size_t)wide_len) : NULL;
    if (wide) MultiByteToWideChar(CP_UTF8, 0, line, -1, wide, wide_len);
  }
  free(exe_utf8);
  free(line);
  return wide;
}

struct ProjectLaunch {
  ShellProject *project;
  Uint32 connection;
  wchar_t exe[MAX_PATH * 4];
  wchar_t *command_line;
  PROCESS_INFORMATION process;
  SDL_AtomicInt done;
  DWORD error;
  bool taken;
};

static int SDLCALL launch_thread(void *data) {
  ProjectLaunch *launch = data;
  ShellProject *project = launch->project;
  const char *probe = SDL_getenv("ANVIL_SURFACE_FAULT_PROBE");
  const char *fault = SDL_getenv("ANVIL_SURFACE_FAULT_STARTUP");
  if (probe && !strcmp(probe, "1") && fault && !strcmp(fault, "selection-launch") &&
      project->id == 2) {
    SDL_Log("Shell paused the owned Project launch worker: Project=%u", project->id);
    SDL_Delay(7000);
  }
  STARTUPINFOW startup = {.cb = sizeof(startup)};
  if (!CreateProcessW(launch->exe, launch->command_line, NULL, NULL, FALSE, CREATE_SUSPENDED, NULL,
                      NULL, &startup, &launch->process)) {
    launch->error = GetLastError();
  } else {
    SDL_Log("Shell foreground grant to Project pid=%lu allowed=%d",
            (unsigned long)launch->process.dwProcessId,
            AllowSetForegroundWindow(launch->process.dwProcessId) != 0);
    ResumeThread(launch->process.hThread);
    SDL_Log("Shell started Project pid=%lu path=%s", (unsigned long)launch->process.dwProcessId,
            project->project_path);
  }
  SDL_SetAtomicInt(&launch->done, 1);
  SDL_Event event = {0};
  event.type = shell.event_type;
  event.user.code = SHELL_EVENT_LAUNCHED;
  event.user.windowID = launch->connection;
  if (!SDL_PushEvent(&event))
    report_transport_failure(project, FAILURE_EVENT);
  return 0;
}

static bool launch_child(ShellProject *project, int argc, char **argv, const char *pipe_name) {
  ProjectLaunch *launch = calloc(1, sizeof(*launch));
  if (!launch)
    return false;
  project->launch = launch;
  launch->project = retain_project(project);
  launch->connection = project->connection;
  DWORD exe_len = GetModuleFileNameW(NULL, launch->exe, (DWORD)SDL_arraysize(launch->exe));
  if (!exe_len || exe_len >= SDL_arraysize(launch->exe))
    goto failed;

  char pipe_arg[sizeof(ANVIL_SURFACE_PIPE_ARG) + 256];
  snprintf(pipe_arg, sizeof(pipe_arg), "%s%s", ANVIL_SURFACE_PIPE_ARG, pipe_name);
  launch->command_line = build_child_command_line(project, launch->exe, pipe_arg, argc, argv);
  if (!launch->command_line)
    goto failed;
  project->launcher = SDL_CreateThread(launch_thread, "anvil-shell-launch", launch);
  if (project->launcher)
    return true;
failed:
  project->launch = NULL;
  free(launch->command_line);
  release_project(launch->project);
  free(launch);
  return false;
}

/* ------------------------------------------------------------------------ */
/* Pipe threads                                                             */

static bool push_shell_event(ShellProject *project, int code, void *data, int value) {
  SDL_Event event;
  SDL_zero(event);
  event.type = shell.event_type;
  event.user.code = code;
  event.user.data1 = data;
  event.user.data2 = (void *)(intptr_t)value;
  event.user.windowID = project->connection;
  if (!take_fault(FAULT_EVENT) && SDL_PushEvent(&event))
    return true;
  if (code == SHELL_EVENT_MESSAGE) {
    ShellMessage *message = data;
    SDL_AddAtomicInt(&project->inbound_bytes, -(int)(sizeof(*message) + message->size));
    free_message(message);
  }
  report_transport_failure(project, FAILURE_EVENT);
  return false;
}

static bool valid_project_message(uint16_t type, const void *payload, uint32_t size) {
  switch (type) {
  case ANVIL_SURFACE_MSG_FRAME: {
    if (size != sizeof(AnvilSurfaceFrame))
      return false;
    const AnvilSurfaceFrame *frame = payload;
    return frame->generation && frame->configuration && frame->width > 0 && frame->height > 0 &&
           frame->width <= 32768 && frame->height <= 32768 && frame->name[0] &&
           memchr(frame->name, 0, sizeof(frame->name)) &&
           (frame->kind == ANVIL_SURFACE_FRAME_D3D11 ||
            frame->kind == ANVIL_SURFACE_FRAME_SHARED_MEMORY);
  }
  case ANVIL_SURFACE_MSG_CURSOR:
  case ANVIL_SURFACE_MSG_WINDOW_MODE:
  case ANVIL_SURFACE_MSG_BORDERED:
  case ANVIL_SURFACE_MSG_VISIBLE:
  case ANVIL_SURFACE_MSG_FLASH:
  case ANVIL_SURFACE_MSG_CLOSE_DECISION:
    return size == sizeof(AnvilSurfaceInt);
  case ANVIL_SURFACE_MSG_TEXT_INPUT:
    return size == sizeof(AnvilSurfaceTextInput);
  case ANVIL_SURFACE_MSG_CLEAR_IME:
    return size == sizeof(uint64_t);
  case ANVIL_SURFACE_MSG_HIT_TEST:
    return size == sizeof(AnvilSurfaceHitTest);
  case ANVIL_SURFACE_MSG_SET_BOUNDS:
    return size == sizeof(AnvilSurfaceBounds);
  case ANVIL_SURFACE_MSG_OPACITY:
    return size == sizeof(float);
  case ANVIL_SURFACE_MSG_RAISE:
  case ANVIL_SURFACE_MSG_EXIT_INTENT:
    return size == 0;
  case ANVIL_SURFACE_MSG_TITLE:
    return !memchr(payload, 0, size);
  case ANVIL_SURFACE_MSG_RESTART:
  case ANVIL_SURFACE_MSG_SELECT_PROJECT:
  case ANVIL_SURFACE_MSG_UNLOAD_PROJECT:
    return size > 1 && size < 32768 && ((const char *)payload)[size - 1] == 0 &&
           !memchr(payload, 0, size - 1);
  case ANVIL_SURFACE_MSG_DIALOG:
    return size >= sizeof(AnvilSurfaceDialog);
  default:
    return false;
  }
}

static bool wait_for_child_connection(ShellProject *project) {
  HANDLE connect_event = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (!connect_event) return false;
  bool connected = false;
  for (;;) {
    OVERLAPPED overlapped;
    ZeroMemory(&overlapped, sizeof(overlapped));
    overlapped.hEvent = connect_event;
    ResetEvent(connect_event);
    DWORD error =
        ConnectNamedPipe(project->pipe.handle, &overlapped) ? ERROR_PIPE_CONNECTED : GetLastError();
    if (error == ERROR_IO_PENDING) {
      HANDLE waits[3] = {connect_event, project->process.hProcess, project->pipe.stop_event};
      DWORD done = 0;
      if (WaitForMultipleObjects(3, waits, FALSE, SHELL_CONNECT_TIMEOUT_MS) != WAIT_OBJECT_0) {
        CancelIoEx(project->pipe.handle, &overlapped);
        GetOverlappedResult(project->pipe.handle, &overlapped, &done, TRUE);
        break;
      }
      error = GetOverlappedResult(project->pipe.handle, &overlapped, &done, FALSE)
                  ? ERROR_PIPE_CONNECTED
                  : GetLastError();
    }
    if (error != ERROR_PIPE_CONNECTED) break;
    /* Only the process this shell started may drive its window. */
    ULONG client = 0;
    if (GetNamedPipeClientProcessId(project->pipe.handle, &client) &&
        client == project->process.dwProcessId) {
      connected = true;
      break;
    }
    SDL_Log("Anvil shell rejected a pipe client with pid %lu", (unsigned long)client);
    DisconnectNamedPipe(project->pipe.handle);
  }
  CloseHandle(connect_event);
  return connected;
}

static int reader_loop(void *data) {
  ShellProject *project = data;
  uint8_t *payload = malloc(ANVIL_SURFACE_MAX_PAYLOAD);
  AnvilIPCHeader header;
  if (payload && wait_for_child_connection(project) &&
      anvil_ipc_pipe_read(&project->pipe, &header, payload, ANVIL_SURFACE_MAX_PAYLOAD) &&
      header.type == ANVIL_SURFACE_MSG_HELLO && header.size == sizeof(AnvilSurfaceHello) &&
      ((AnvilSurfaceHello *)payload)->pid == project->process.dwProcessId) {
    push_shell_event(project, SHELL_EVENT_CONNECTED, NULL, 0);
    while (anvil_ipc_pipe_read(&project->pipe, &header, payload, ANVIL_SURFACE_MAX_PAYLOAD)) {
      if (!valid_project_message(header.type, payload, header.size)) {
        report_transport_failure(project, FAILURE_PACKET);
        break;
      }
      if (header.type == ANVIL_SURFACE_MSG_FRAME) {
        SDL_LockMutex(project->lock);
        memcpy(&project->latest_frame, payload, sizeof(AnvilSurfaceFrame));
        bool notify = !project->frame_pending;
        project->frame_pending = true;
        SDL_BroadcastCondition(project->frame_cond);
        SDL_UnlockMutex(project->lock);
        if (notify)
          push_shell_event(project, SHELL_EVENT_FRAME, NULL, 0);
        continue;
      }
      ShellMessage *message =
          take_fault(FAULT_ALLOC) ? NULL : malloc(sizeof(ShellMessage) + header.size);
      if (!message) {
        report_transport_failure(project, FAILURE_ALLOC);
        break;
      }
      message->next = NULL;
      message->owner = retain_project(project);
      message->type = header.type;
      message->size = header.size;
      memcpy(message->payload, payload, header.size);
      int bytes = (int)(sizeof(*message) + header.size);
      if ((size_t)SDL_AddAtomicInt(&project->inbound_bytes, bytes) + bytes >
          SHELL_WRITE_QUEUE_LIMIT) {
        SDL_AddAtomicInt(&project->inbound_bytes, -bytes);
        free_message(message);
        report_transport_failure(project, FAILURE_OVERFLOW);
        break;
      }
      if (!push_shell_event(project, SHELL_EVENT_MESSAGE, message, 0))
        break;
    }
  } else if (!payload)
    report_transport_failure(project, FAILURE_ALLOC);
  free(payload);

  push_shell_event(project, SHELL_EVENT_DISCONNECTED, NULL, 0);
  HANDLE waits[] = {project->process.hProcess, project->pipe.stop_event};
  WaitForMultipleObjects(2, waits, FALSE, INFINITE);
  if (WaitForSingleObject(project->process.hProcess, 0) == WAIT_OBJECT_0) {
    DWORD exit_code = 1;
    GetExitCodeProcess(project->process.hProcess, &exit_code);
    push_shell_event(project, SHELL_EVENT_EXITED, NULL, (int)exit_code);
  }
  SDL_SetAtomicInt(&project->reader_done, 1);
  return 0;
}

static int writer_loop(void *data) {
  ShellProject *project = data;
  for (;;) {
    SDL_LockMutex(project->lock);
    while (!project->queue_head && !project->writer_stop)
      SDL_WaitCondition(project->queue_cond, project->lock);
    if (project->writer_stop) {
      SDL_UnlockMutex(project->lock);
      SDL_SetAtomicInt(&project->writer_done, 1);
      return 0;
    }
    ShellMessage *message = project->queue_head;
    project->queue_head = message->next;
    if (!project->queue_head)
      project->queue_tail = NULL;
    project->queue_bytes -= sizeof(*message) + message->size;
    SDL_UnlockMutex(project->lock);
    if (take_fault(FAULT_BLOCK_WRITE))
      WaitForSingleObject(project->pipe.stop_event, INFINITE);
    bool written =
        !take_fault(FAULT_WRITE) && anvil_ipc_pipe_write(&project->pipe, message->type,
                                                         message->payload, message->size, NULL, 0);
    free(message);
    if (!written) {
      push_shell_event(project, SHELL_EVENT_DISCONNECTED, NULL, 0);
      SDL_SetAtomicInt(&project->writer_done, 1);
      return 1;
    }
  }
  return 0;
}

static int SDLCALL reader_thread(void *data) {
  int result = reader_loop(data);
  release_project(data);
  return result;
}

static int SDLCALL writer_thread(void *data) {
  int result = writer_loop(data);
  release_project(data);
  return result;
}

static SDL_Thread *start_transport_thread(SDL_ThreadFunction function, const char *name,
                                          ShellProject *project) {
  retain_project(project);
  SDL_Thread *thread = SDL_CreateThread(function, name, project);
  if (!thread)
    release_project(project);
  return thread;
}

/* Main-thread sends never block on the pipe. A hung surface process can not
 * stall the shell window. Queue failure ends the connection, not just one key. */
static void shell_send(ShellProject *project, uint16_t type, const void *payload, uint32_t size,
                       const void *tail, uint32_t tail_size) {
  if (!project->connected)
    return;
  uint32_t total = size + tail_size;
  if (total > ANVIL_SURFACE_MAX_PAYLOAD) {
    fail_connection(project, "outbound packet too large");
    return;
  }
  ShellMessage *message = malloc(sizeof(ShellMessage) + total);
  if (!message) {
    fail_connection(project, "outbound allocation failed");
    return;
  }
  message->next = NULL;
  message->owner = NULL;
  message->type = type;
  message->size = total;
  if (size) memcpy(message->payload, payload, size);
  if (tail_size) memcpy(message->payload + size, tail, tail_size);

  SDL_LockMutex(project->lock);
  ShellMessage *previous = project->queue_tail;
  bool replace = previous && previous->type == type && previous->size == total &&
    type == ANVIL_SURFACE_MSG_CONFIGURE;
  if (previous && previous->type == ANVIL_SURFACE_MSG_INPUT && type == ANVIL_SURFACE_MSG_INPUT &&
      previous->size == total && total == sizeof(AnvilSurfaceInput)) {
    AnvilSurfaceInput *old = (AnvilSurfaceInput *)previous->payload;
    AnvilSurfaceInput *next = (AnvilSurfaceInput *)message->payload;
    if (old->configuration == next->configuration && old->event.type == SDL_EVENT_MOUSE_MOTION &&
        next->event.type == SDL_EVENT_MOUSE_MOTION) {
      next->event.motion.xrel += old->event.motion.xrel;
      next->event.motion.yrel += old->event.motion.yrel;
      replace = true;
    }
  }
  if (replace) {
    memcpy(previous->payload, message->payload, total);
    SDL_UnlockMutex(project->lock);
    free(message);
    return;
  }
  if (project->queue_bytes + sizeof(*message) + total > SHELL_WRITE_QUEUE_LIMIT) {
    SDL_UnlockMutex(project->lock);
    free(message);
    fail_connection(project, "outbound queue overflow");
    return;
  }
  if (project->queue_tail)
    project->queue_tail->next = message;
  else
    project->queue_head = message;
  project->queue_tail = message;
  project->queue_bytes += sizeof(*message) + total;
  SDL_SignalCondition(project->queue_cond);
  SDL_UnlockMutex(project->lock);
}

static void shell_send_int(ShellProject *project, uint16_t type, int value) {
  AnvilSurfaceInt message = { value };
  shell_send(project, type, &message, sizeof(message), NULL, 0);
}

/* ------------------------------------------------------------------------ */
/* Layout and configuration                                                 */

static void update_scale(void) {
  float scale = SDL_GetWindowDisplayScale(shell.window);
  shell.scale = scale > 0 ? scale : 1.0f;
  shell.sidebar_w = (int)(SHELL_SIDEBAR_POINTS * shell.scale + 0.5f);
}

static AnvilSurfaceWindowMode current_window_mode(void) {
  SDL_WindowFlags flags = SDL_GetWindowFlags(shell.window);
  if (flags & SDL_WINDOW_FULLSCREEN) return ANVIL_SURFACE_WINDOW_FULLSCREEN;
  if (flags & SDL_WINDOW_MINIMIZED) return ANVIL_SURFACE_WINDOW_MINIMIZED;
  if (flags & SDL_WINDOW_MAXIMIZED) return ANVIL_SURFACE_WINDOW_MAXIMIZED;
  return ANVIL_SURFACE_WINDOW_NORMAL;
}

static float current_refresh_rate(void) {
  SDL_DisplayID display = SDL_GetDisplayForWindow(shell.window);
  const SDL_DisplayMode *mode = display ? SDL_GetCurrentDisplayMode(display) : NULL;
  if (!mode || mode->refresh_rate <= 0) mode = display ? SDL_GetDesktopDisplayMode(display) : NULL;
  return mode && mode->refresh_rate > 0 ? mode->refresh_rate : 0.0f;
}

/* Inside the Win32 sizing loop SDL's cached size can trail the real client
 * rect by one message, so read the HWND directly. */
static void client_pixel_size(int *width, int *height) {
  RECT rect = { 0 };
  GetClientRect(shell.hwnd, &rect);
  *width = (int)(rect.right - rect.left);
  *height = (int)(rect.bottom - rect.top);
}

static void send_configure(ShellProject *project) {
  if (!project->connected)
    return;
  AnvilSurfaceConfigure config = project->last_config;
  config.window_mode = current_window_mode();
  config.live_resize = shell.live_resize;
  config.render_enabled =
      project == shell.selected && IsWindowVisible(shell.hwnd) && !IsIconic(shell.hwnd);
  if (config.window_mode != ANVIL_SURFACE_WINDOW_MINIMIZED) {
    /* A minimized window keeps the last surface size. */
    int pixel_w = 0, pixel_h = 0;
    client_pixel_size(&pixel_w, &pixel_h);
    config.pixel_w = SDL_max(1, pixel_w - shell.sidebar_w);
    config.pixel_h = SDL_max(1, pixel_h);
    RECT rect;
    if (GetWindowRect(shell.hwnd, &rect)) {
      config.window_x = rect.left;
      config.window_y = rect.top;
      config.window_w = rect.right - rect.left;
      config.window_h = rect.bottom - rect.top;
    }
  }
  config.display_scale = shell.scale;
  config.origin_x = shell.sidebar_w;
  config.origin_y = 0;
  config.refresh_hz = current_refresh_rate();
  typedef UINT(WINAPI * DpiForWindow)(HWND);
  typedef int(WINAPI * MetricForDpi)(int, UINT);
  HMODULE user32 = GetModuleHandleW(L"user32.dll");
  DpiForWindow dpi_for_window = (DpiForWindow)GetProcAddress(user32, "GetDpiForWindow");
  MetricForDpi metric = (MetricForDpi)GetProcAddress(user32, "GetSystemMetricsForDpi");
  UINT dpi = dpi_for_window ? dpi_for_window(shell.hwnd) : 96;
  config.button_width = metric ? metric(SM_CXSIZE, dpi) : GetSystemMetrics(SM_CXSIZE);
  config.title_height = metric ? metric(SM_CYSIZE, dpi) : GetSystemMetrics(SM_CYSIZE);
  config.resize_border =
      metric ? metric(SM_CXSIZEFRAME, dpi) + metric(SM_CXPADDEDBORDER, dpi)
             : GetSystemMetrics(SM_CXSIZEFRAME) + GetSystemMetrics(SM_CXPADDEDBORDER);
  controls_geometry();
  config.controls_x = SDL_max(0, shell.controls.left - shell.sidebar_w);
  config.controls_y = 0;
  config.controls_w = shell.controls.right - shell.controls.left;
  config.controls_h = shell.controls.bottom;
  if (memcmp(&config, &project->last_config, sizeof(config)) == 0 && project->last_config.pixel_w)
    return;
  if (!config.configuration || anvil_surface_layout_changed(&project->last_config, &config)) {
    config.configuration++;
    if (project == shell.selected)
      SDL_ClearComposition(shell.window);
    project->hit = (AnvilSurfaceHitTest){0};
  }
  project->last_config = config;
  if (!config.render_enabled && project == shell.selected)
    set_frame_busy(false);
  shell_send(project, ANVIL_SURFACE_MSG_CONFIGURE, &config, sizeof(config), NULL, 0);
}

/* ------------------------------------------------------------------------ */
/* Rendering                                                                */

static bool create_backbuffer_view(void) {
  HRESULT hr = shell.swapchain->lpVtbl->GetBuffer(shell.swapchain, 0, &IID_ID3D11Texture2D,
                                                  (void **)&shell.backbuffer);
  if (SUCCEEDED(hr)) {
    hr = shell.device->lpVtbl->CreateRenderTargetView(shell.device, (ID3D11Resource *)shell.backbuffer,
                                                      NULL, &shell.rtv);
  }
  return SUCCEEDED(hr);
}

static bool init_d3d11(void) {
  D3D_FEATURE_LEVEL levels[] = {
    D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0,
  };
  UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
  HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, flags, levels,
                                 (UINT)SDL_arraysize(levels), D3D11_SDK_VERSION,
                                 &shell.device, NULL, &shell.context);
  if (FAILED(hr)) {
    hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_WARP, NULL, flags, levels,
                           (UINT)SDL_arraysize(levels), D3D11_SDK_VERSION,
                           &shell.device, NULL, &shell.context);
  }
  if (FAILED(hr)) return false;
  hr = shell.device->lpVtbl->QueryInterface(shell.device, &IID_ID3D11Device1, (void **)&shell.device1);
  if (FAILED(hr)) return false;

  IDXGIDevice1 *dxgi_device = NULL;
  IDXGIAdapter *adapter = NULL;
  IDXGIFactory2 *factory = NULL;
  hr = shell.device->lpVtbl->QueryInterface(shell.device, &IID_IDXGIDevice1, (void **)&dxgi_device);
  if (SUCCEEDED(hr)) {
    dxgi_device->lpVtbl->SetMaximumFrameLatency(dxgi_device, 2);
    hr = dxgi_device->lpVtbl->GetAdapter(dxgi_device, &adapter);
  }
  if (SUCCEEDED(hr)) hr = adapter->lpVtbl->GetParent(adapter, &IID_IDXGIFactory2, (void **)&factory);

  HWND hwnd = shell.hwnd;
  int pixel_w = 0, pixel_h = 0;
  client_pixel_size(&pixel_w, &pixel_h);
  if (SUCCEEDED(hr) && hwnd) {
    DXGI_SWAP_CHAIN_DESC1 desc;
    ZeroMemory(&desc, sizeof(desc));
    desc.Width = (UINT)SDL_max(1, pixel_w);
    desc.Height = (UINT)SDL_max(1, pixel_h);
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.Scaling = DXGI_SCALING_NONE;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    desc.AlphaMode = DXGI_ALPHA_MODE_UNSPECIFIED;
    hr = factory->lpVtbl->CreateSwapChainForHwnd(factory, (IUnknown *)shell.device, hwnd, &desc,
                                                 NULL, NULL, &shell.swapchain);
    if (SUCCEEDED(hr)) factory->lpVtbl->MakeWindowAssociation(factory, hwnd, DXGI_MWA_NO_ALT_ENTER);
    shell.buffer_w = (int)desc.Width;
    shell.buffer_h = (int)desc.Height;
  } else if (SUCCEEDED(hr)) {
    hr = E_FAIL;
  }
  SAFE_RELEASE(factory);
  SAFE_RELEASE(adapter);
  SAFE_RELEASE(dxgi_device);
  return SUCCEEDED(hr) && create_backbuffer_view();
}

static void release_d3d11(void) {
  if (shell.context)
    shell.context->lpVtbl->ClearState(shell.context);
  SAFE_RELEASE(shell.shared_mutex);
  SAFE_RELEASE(shell.shared);
  SAFE_RELEASE(shell.surface);
  SAFE_RELEASE(shell.ui);
  SAFE_RELEASE(shell.rtv);
  SAFE_RELEASE(shell.backbuffer);
  SAFE_RELEASE(shell.swapchain);
  SAFE_RELEASE(shell.context);
  SAFE_RELEASE(shell.device1);
  SAFE_RELEASE(shell.device);
  close_memory_frame();
  shell.have_surface = false;
  shell.shared_name[0] = 0;
}

static void fail_gpu(const char *operation, HRESULT error) {
  ShellProject *project = shell.selected;
  if (shell.render_failed)
    return;
  shell.render_failed = true;
  SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
               "Shell GPU failure: %s HRESULT=0x%08lx; native OS actions remain available",
               operation, (unsigned long)error);
  /* Native paint and resize can run inside SDL's event pump. Finish SDL
   * cleanup in the main callback, not inside a nested window procedure. */
  shell.gpu_failure = operation;
  SDL_Event event = {0};
  event.type = shell.event_type;
  event.user.code = SHELL_EVENT_FRAME;
  event.user.windowID = project->connection;
  SDL_PushEvent(&event);
  InvalidateRect(shell.hwnd, NULL, FALSE);
}

static void check_gpu_failure(void) {
  ShellProject *project = shell.selected;
  if (!shell.gpu_failure)
    return;
  const char *cause = shell.gpu_failure;
  shell.gpu_failure = NULL;
  release_d3d11();
  fail_connection(project, cause);
}

static void resize_buffers(void) {
  int pixel_w = 0, pixel_h = 0;
  client_pixel_size(&pixel_w, &pixel_h);
  if (pixel_w <= 0 || pixel_h <= 0) return;
  if (pixel_w == shell.buffer_w && pixel_h == shell.buffer_h) return;
  if (shell.render_failed) { shell.buffer_w = pixel_w; shell.buffer_h = pixel_h; return; }
  shell.context->lpVtbl->OMSetRenderTargets(shell.context, 0, NULL, NULL);
  SAFE_RELEASE(shell.rtv);
  SAFE_RELEASE(shell.backbuffer);
  HRESULT hr = shell.swapchain->lpVtbl->ResizeBuffers(shell.swapchain, 0, (UINT)pixel_w, (UINT)pixel_h,
                                                      DXGI_FORMAT_UNKNOWN, 0);
  if (take_fault(FAULT_RESIZE)) hr = DXGI_ERROR_DEVICE_REMOVED;
  if (FAILED(hr) || !create_backbuffer_view()) {
    fail_gpu("swapchain resize failed", FAILED(hr) ? hr : E_FAIL);
    return;
  }
  shell.buffer_w = pixel_w;
  shell.buffer_h = pixel_h;
}

static bool ensure_surface_texture(int width, int height) {
  if (shell.surface && shell.surface_w == width && shell.surface_h == height) return true;
  SAFE_RELEASE(shell.surface);
  shell.have_surface = false;
  D3D11_TEXTURE2D_DESC desc;
  ZeroMemory(&desc, sizeof(desc));
  desc.Width = (UINT)width;
  desc.Height = (UINT)height;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
  HRESULT hr = shell.device->lpVtbl->CreateTexture2D(shell.device, &desc, NULL, &shell.surface);
  if (FAILED(hr)) {
    SDL_Log("Shell private surface creation failed: 0x%08lx", (unsigned long)hr);
    return false;
  }
  shell.surface_w = width;
  shell.surface_h = height;
  return true;
}

static bool load_d3d11_frame(const AnvilSurfaceFrame *frame) {
  ShellProject *project = shell.selected;
  if (strcmp(frame->name, shell.shared_name) != 0 || !shell.shared) {
    SAFE_RELEASE(shell.shared_mutex);
    SAFE_RELEASE(shell.shared);
    shell.shared_name[0] = '\0';
    wchar_t name[ANVIL_SURFACE_NAME_MAX];
    MultiByteToWideChar(CP_UTF8, 0, frame->name, -1, name, ANVIL_SURFACE_NAME_MAX);
    HRESULT hr = take_fault(FAULT_OPEN) ? E_ACCESSDENIED : shell.device1->lpVtbl->OpenSharedResourceByName(
      shell.device1, name, DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE,
      &IID_ID3D11Texture2D, (void **)&shell.shared);
    if (SUCCEEDED(hr)) {
      hr = shell.shared->lpVtbl->QueryInterface(shell.shared, &IID_IDXGIKeyedMutex,
                                                (void **)&shell.shared_mutex);
    }
    if (FAILED(hr)) {
      SDL_Log("Anvil shell could not open surface %s: 0x%08lx", frame->name, (unsigned long)hr);
      SAFE_RELEASE(shell.shared);
      return false;
    }
    SDL_strlcpy(shell.shared_name, frame->name, sizeof(shell.shared_name));
  }
  D3D11_TEXTURE2D_DESC desc;
  shell.shared->lpVtbl->GetDesc(shell.shared, &desc);
  if (desc.Width != (UINT)frame->width || desc.Height != (UINT)frame->height ||
      desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM) return false;
  if (!ensure_surface_texture((int)desc.Width, (int)desc.Height)) return false;
  HRESULT acquired =
      take_fault(FAULT_ACQUIRE) ? WAIT_ABANDONED
      : SDL_GetAtomicInt(&probe_fault) == FAULT_BUSY
          ? WAIT_TIMEOUT
          : shell.shared_mutex->lpVtbl->AcquireSync(shell.shared_mutex, 0, SHELL_SYNC_TIMEOUT_MS);
  if (acquired != S_OK) {
    if (acquired == WAIT_TIMEOUT || acquired == DXGI_ERROR_WAIT_TIMEOUT)
      shell.frame_busy = true;
    else {
      SDL_Log("Shell shared mutex failed: 0x%08lx", (unsigned long)acquired);
      fail_connection(project, "shared surface mutex failed");
    }
    return false;
  }
  shell.context->lpVtbl->CopyResource(shell.context, (ID3D11Resource *)shell.surface,
                                      (ID3D11Resource *)shell.shared);
  HRESULT released = shell.shared_mutex->lpVtbl->ReleaseSync(shell.shared_mutex, 0);
  if (take_fault(FAULT_RELEASE)) released = E_FAIL;
  if (released != S_OK) {
    fail_gpu("surface mutex release failed", released);
    return false;
  }
  return true;
}

static void close_memory_frame(void) {
  if (shell.memory_view) UnmapViewOfFile(shell.memory_view);
  if (shell.memory_mapping) CloseHandle(shell.memory_mapping);
  if (shell.memory_mutex) CloseHandle(shell.memory_mutex);
  shell.memory_view = NULL;
  shell.memory_mapping = NULL;
  shell.memory_mutex = NULL;
  shell.memory_size = 0;
  shell.memory_name[0] = '\0';
}

static bool load_memory_frame(const AnvilSurfaceFrame *frame) {
  ShellProject *project = shell.selected;
  if (strcmp(frame->name, shell.memory_name) != 0 || !shell.memory_view) {
    close_memory_frame();
    char lock_name[ANVIL_SURFACE_NAME_MAX + 8];
    snprintf(lock_name, sizeof(lock_name), "%s%s", frame->name, ANVIL_SURFACE_LOCK_SUFFIX);
    shell.memory_mapping = take_fault(FAULT_OPEN) ? NULL : OpenFileMappingA(FILE_MAP_READ, FALSE, frame->name);
    shell.memory_mutex = OpenMutexA(SYNCHRONIZE | MUTEX_MODIFY_STATE, FALSE, lock_name);
    if (shell.memory_mapping) {
      shell.memory_view = MapViewOfFile(shell.memory_mapping, FILE_MAP_READ, 0, 0, 0);
    }
    MEMORY_BASIC_INFORMATION info;
    if (!shell.memory_view || !shell.memory_mutex ||
        !VirtualQuery(shell.memory_view, &info, sizeof(info))) {
      SDL_Log("Anvil shell could not open surface memory %s", frame->name);
      close_memory_frame();
      return false;
    }
    shell.memory_size = info.RegionSize;
    SDL_strlcpy(shell.memory_name, frame->name, sizeof(shell.memory_name));
  }
  DWORD wait = take_fault(FAULT_ACQUIRE) ? WAIT_FAILED
               : SDL_GetAtomicInt(&probe_fault) == FAULT_BUSY
                   ? WAIT_TIMEOUT
                   : WaitForSingleObject(shell.memory_mutex, SHELL_SYNC_TIMEOUT_MS);
  if (wait != WAIT_OBJECT_0) {
    if (wait == WAIT_TIMEOUT)
      shell.frame_busy = true;
    else {
      if (wait == WAIT_ABANDONED)
        ReleaseMutex(shell.memory_mutex);
      fail_connection(project, "shared memory mutex failed");
    }
    return false;
  }
  const AnvilSurfaceMemoryHeader *header = (const AnvilSurfaceMemoryHeader *)shell.memory_view;
  bool ok = header->width == frame->width && header->height == frame->height &&
            header->configuration == frame->configuration && header->generation >= frame->generation &&
            header->width > 0 && header->height > 0 && header->stride >= header->width * 4 &&
            sizeof(*header) + (size_t)header->stride * (size_t)header->height <= shell.memory_size &&
            ensure_surface_texture(header->width, header->height);
  if (ok) {
    shell.context->lpVtbl->UpdateSubresource(shell.context, (ID3D11Resource *)shell.surface, 0, NULL,
                                             shell.memory_view + sizeof(*header), (UINT)header->stride, 0);
  }
  BOOL released = ReleaseMutex(shell.memory_mutex);
  if (take_fault(FAULT_RELEASE)) {
    released = FALSE;
    SetLastError(ERROR_NOT_OWNER);
  }
  if (!released) {
    SDL_Log("Shell memory mutex release failed: %lu", (unsigned long)GetLastError());
    fail_connection(project, "shared memory mutex release failed");
    return false;
  }
  return ok;
}

static void ui_fill(HDC dc, RECT rect, COLORREF color) {
  HBRUSH brush = CreateSolidBrush(color);
  FillRect(dc, &rect, brush);
  DeleteObject(brush);
}

static void draw_lifecycle(HDC dc) {
  ShellProject *project = shell.selected;
  shell.restart_button = (RECT){0};
  shell.close_button = (RECT){0};
  if (project->state != SHELL_STARTING && project->state != SHELL_FAILED &&
      project->state != SHELL_DORMANT)
    return;
  RECT area = {shell.sidebar_w, shell.controls.bottom, shell.buffer_w, shell.buffer_h};
  DrawTextW(dc,
            project->state == SHELL_STARTING  ? L"Starting Project..."
            : project->state == SHELL_DORMANT ? L"Project is Dormant"
                                              : L"Project failed",
            -1, &area, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  if (project->state != SHELL_FAILED && project->state != SHELL_DORMANT)
    return;
  int x = (area.left + area.right) / 2, y = (area.top + area.bottom) / 2 + (int)(30 * shell.scale);
  shell.failure_card = (RECT){SDL_max(area.left, x - (int)(180 * shell.scale)),
                              SDL_max(area.top, y - (int)(90 * shell.scale)),
                              SDL_min(area.right, x + (int)(180 * shell.scale)),
                              SDL_min(area.bottom, y + (int)(50 * shell.scale))};
  int w = (int)(140 * shell.scale), h = (int)(32 * shell.scale), gap = (int)(8 * shell.scale);
  shell.restart_button = (RECT){x - w - gap, y, x - gap, y + h};
  shell.close_button = (RECT){x + gap, y, x + w + gap, y + h};
  ui_fill(dc, shell.restart_button, RGB(55, 55, 62));
  ui_fill(dc, shell.close_button, RGB(55, 55, 62));
  DrawTextW(dc, project->state == SHELL_DORMANT ? L"Load Project" : L"Restart Project", -1,
            &shell.restart_button, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  DrawTextW(dc, project->state == SHELL_DORMANT ? L"Close Window" : L"Unload Project", -1,
            &shell.close_button, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
}

static void paint_failed_window(HDC dc) {
  client_pixel_size(&shell.buffer_w, &shell.buffer_h);
  controls_geometry();
  RECT client = {0, 0, shell.buffer_w, shell.buffer_h};
  ui_fill(dc, client, RGB(23, 23, 28));
  SetBkMode(dc, TRANSPARENT);
  SetTextColor(dc, RGB(220, 220, 225));
  HGDIOBJ old = SelectObject(dc, GetStockObject(DEFAULT_GUI_FONT));
  draw_lifecycle(dc);
  const wchar_t *labels[] = {L"−", L"□", L"×"};
  int width = (shell.controls.right - shell.controls.left) / 3;
  for (int i = 0; i < 3; i++) {
    RECT button = {shell.controls.left + i * width, 0,
                   i == 2 ? shell.controls.right : shell.controls.left + (i + 1) * width,
                   shell.controls.bottom};
    DrawTextW(dc, labels[i], -1, &button, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  }
  SelectObject(dc, old);
}

static void update_ui(void) {
  ShellProject *project = shell.selected;
  controls_geometry();
  if (!shell.ui_dirty && !shell.ui_hover_dirty && shell.ui && shell.ui_w == shell.buffer_w &&
      shell.ui_h == shell.buffer_h)
    return;
  if (shell.buffer_w <= 0 || shell.buffer_h <= 0)
    return;
  if (!shell.ui || shell.ui_w != shell.buffer_w || shell.ui_h != shell.buffer_h) {
    SAFE_RELEASE(shell.ui);
    if (shell.ui_dc) {
      SelectObject(shell.ui_dc, shell.ui_old_bitmap);
      DeleteObject(shell.ui_bitmap);
      DeleteDC(shell.ui_dc);
    }
    shell.ui_dc = CreateCompatibleDC(NULL);
    BITMAPINFO info = {0};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = shell.buffer_w;
    info.bmiHeader.biHeight = -shell.buffer_h;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    shell.ui_bitmap =
        CreateDIBSection(shell.ui_dc, &info, DIB_RGB_COLORS, &shell.ui_pixels, NULL, 0);
    if (!shell.ui_dc || !shell.ui_bitmap)
      return;
    shell.ui_old_bitmap = SelectObject(shell.ui_dc, shell.ui_bitmap);
    D3D11_TEXTURE2D_DESC desc = {0};
    desc.Width = shell.buffer_w;
    desc.Height = shell.buffer_h;
    desc.MipLevels = 1;
    desc.ArraySize = 1;
    desc.SampleDesc.Count = 1;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.Usage = D3D11_USAGE_DEFAULT;
    HRESULT hr = shell.device->lpVtbl->CreateTexture2D(shell.device, &desc, NULL, &shell.ui);
    if (FAILED(hr)) {
      fail_gpu("native UI texture creation failed", hr);
      return;
    }
    shell.ui_w = shell.buffer_w;
    shell.ui_h = shell.buffer_h;
    shell.ui_dirty = true;
  }
  HDC dc = shell.ui_dc;
  RECT all = {0, 0, shell.buffer_w, shell.buffer_h};
  RECT dirty[] = {{0, 0, shell.sidebar_w, shell.buffer_h}, shell.controls, shell.failure_card};
  bool full = shell.ui_dirty;
  int dirty_count = (project->state == SHELL_FAILED || project->state == SHELL_DORMANT) ? 3 : 2;
  HRGN clip = CreateRectRgn(0, 0, 0, 0);
  if (!full) {
    for (int i = 0; i < dirty_count; i++) {
      HRGN part = CreateRectRgnIndirect(&dirty[i]);
      CombineRgn(clip, clip, part, RGN_OR);
      DeleteObject(part);
    }
    SelectClipRgn(dc, clip);
  } else
    SelectClipRgn(dc, NULL);
  ui_fill(dc, all, RGB(23, 23, 28));
  HFONT font = CreateFontW(-(int)(13 * shell.scale), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                           DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                           ANTIALIASED_QUALITY, DEFAULT_PITCH, L"Segoe UI");
  HGDIOBJ old_font = SelectObject(dc, font);
  SetBkMode(dc, TRANSPARENT);
  SetTextColor(dc, RGB(220, 220, 225));
  RECT logo = {0, 0, shell.sidebar_w, (LONG)(48 * shell.scale)};
  DrawTextW(dc, L"A", 1, &logo, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  RECT status = {0, shell.buffer_h - (LONG)(40 * shell.scale), shell.sidebar_w, shell.buffer_h};
  DrawTextW(dc,
            project->state == SHELL_FAILED    ? L"!"
            : project->state == SHELL_CLOSING ? L"..."
                                              : L"\x2022",
            -1, &status, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  int bw = (shell.controls.right - shell.controls.left) / 3;
  HPEN pen = CreatePen(PS_SOLID, SDL_max(1, (int)shell.scale), RGB(220, 220, 225));
  HGDIOBJ old_pen = SelectObject(dc, pen);
  for (int i = 0; i < 3; i++) {
    RECT rect = {shell.controls.left + i * bw, 0,
                 i == 2 ? shell.controls.right : shell.controls.left + (i + 1) * bw,
                 shell.controls.bottom};
    if (shell.hovered_control == i || shell.pressed_control == i)
      ui_fill(dc, rect, i == 2 ? RGB(190, 45, 45) : RGB(55, 55, 62));
    int x = (rect.left + rect.right) / 2, y = rect.bottom / 2,
        r = SDL_max(3, (int)(5 * shell.scale));
    if (i == 0) {
      MoveToEx(dc, x - r, y + 2, NULL);
      LineTo(dc, x + r, y + 2);
    } else if (i == 1) {
      HGDIOBJ brush = SelectObject(dc, GetStockObject(NULL_BRUSH));
      if (current_window_mode() == ANVIL_SURFACE_WINDOW_MAXIMIZED)
        Rectangle(dc, x - r + 2, y - r - 2, x + r + 2, y + r - 2);
      Rectangle(dc, x - r, y - r, x + r, y + r);
      SelectObject(dc, brush);
    } else {
      MoveToEx(dc, x - r, y - r, NULL);
      LineTo(dc, x + r, y + r);
      MoveToEx(dc, x + r, y - r, NULL);
      LineTo(dc, x - r, y + r);
    }
  }
  SelectObject(dc, old_pen);
  DeleteObject(pen);
  draw_lifecycle(dc);
  GdiFlush();
  if (full) {
    shell.context->lpVtbl->UpdateSubresource(shell.context, (ID3D11Resource *)shell.ui, 0, NULL,
                                             shell.ui_pixels, shell.buffer_w * 4, 0);
  } else {
    for (int i = 0; i < dirty_count; i++) {
      RECT rect = dirty[i];
      if (rect.right <= rect.left || rect.bottom <= rect.top)
        continue;
      D3D11_BOX box = {rect.left, rect.top, 0, rect.right, rect.bottom, 1};
      const uint8_t *pixels =
          (uint8_t *)shell.ui_pixels + ((size_t)rect.top * shell.buffer_w + rect.left) * 4;
      shell.context->lpVtbl->UpdateSubresource(shell.context, (ID3D11Resource *)shell.ui, 0, &box,
                                               pixels, shell.buffer_w * 4, 0);
    }
    SDL_Log("Shell UI hover upload: regions=%d", dirty_count);
  }
  SelectObject(dc, old_font);
  DeleteObject(font);
  SelectClipRgn(dc, NULL);
  DeleteObject(clip);
  shell.ui_dirty = false;
  shell.ui_hover_dirty = false;
}

static void copy_ui(RECT rect) {
  if (!shell.ui || rect.right <= rect.left || rect.bottom <= rect.top)
    return;
  D3D11_BOX box = {rect.left, rect.top, 0, rect.right, rect.bottom, 1};
  shell.context->lpVtbl->CopySubresourceRegion(shell.context, (ID3D11Resource *)shell.backbuffer, 0,
                                               rect.left, rect.top, 0, (ID3D11Resource *)shell.ui,
                                               0, &box);
}

static void composite_and_present(void) {
  ShellProject *project = shell.selected;
  if (shell.render_failed) { InvalidateRect(shell.hwnd, NULL, FALSE); return; }
  if (!shell.rtv)
    return;
  const FLOAT sidebar[4] = {0.09f, 0.09f, 0.11f, 1.0f};
  shell.context->lpVtbl->ClearRenderTargetView(shell.context, shell.rtv, sidebar);
  if (shell.have_surface) {
    D3D11_BOX box = {0,
                     0,
                     0,
                     (UINT)SDL_min(shell.surface_w, project->last_config.pixel_w),
                     (UINT)SDL_min(shell.surface_h, project->last_config.pixel_h),
                     1};
    if ((int)box.right > 0 && (int)box.bottom > 0) {
      shell.context->lpVtbl->CopySubresourceRegion(
          shell.context, (ID3D11Resource *)shell.backbuffer, 0, (UINT)project->last_config.origin_x,
          (UINT)project->last_config.origin_y, 0, (ID3D11Resource *)shell.surface, 0, &box);
    }
  }
  update_ui();
  copy_ui((RECT){0, 0, shell.sidebar_w, shell.buffer_h});
  copy_ui(shell.controls);
  if (project->state == SHELL_STARTING || project->state == SHELL_DORMANT ||
      (project->state == SHELL_FAILED && !shell.have_surface))
    copy_ui((RECT){shell.sidebar_w, shell.controls.bottom, shell.buffer_w, shell.buffer_h});
  else if (project->state == SHELL_FAILED)
    copy_ui(shell.failure_card);
  HRESULT hr = shell.swapchain->lpVtbl->Present(shell.swapchain, 1, 0);
  if (take_fault(FAULT_PRESENT))
    hr = DXGI_ERROR_DEVICE_REMOVED;
  if (FAILED(hr))
    fail_gpu("presentation failed", hr);
}

static void finish_latency_probe(void) {
  ShellProject *project = shell.selected;
  if (project->process.hProcess)
    TerminateProcess(project->process.hProcess, 0);
  _Exit(0);
}

/* Copies the newest published frame into the private surface texture. */
static bool load_pending_frame(AnvilSurfaceFrame *frame) {
  ShellProject *project = shell.selected;
  SDL_LockMutex(project->lock);
  bool pending = project->frame_pending;
  *frame = project->latest_frame;
  project->frame_pending = false;
  SDL_UnlockMutex(project->lock);
  if (shell.render_failed || project->state == SHELL_FAILED || !project->last_config.render_enabled)
    return false;
  if (!pending) return false;
  if (!anvil_surface_frame_matches(&project->last_config, frame)) {
    set_frame_busy(false);
    SDL_Log("Shell discarded stale frame: configuration=%llu current=%llu; last safe frame=%s",
            (unsigned long long)frame->configuration,
            (unsigned long long)project->last_config.configuration,
            shell.have_surface ? "retained" : "none");
    return false;
  }
  char prefix[80];
  SDL_snprintf(prefix, sizeof(prefix),
               frame->kind == ANVIL_SURFACE_FRAME_D3D11 ? "Local\\AnvilSurface-%lu-"
                                                        : "Local\\AnvilSurfaceMemory-%lu-",
               project->process.dwProcessId);
  size_t prefix_length = strlen(prefix);
  if (strncmp(frame->name, prefix, prefix_length) || !frame->name[prefix_length] ||
      strspn(frame->name + prefix_length, "0123456789") != strlen(frame->name + prefix_length)) {
    fail_connection(project, "unowned frame resource name");
    return false;
  }
  shell.frame_busy = false;
  bool loaded = frame->kind == ANVIL_SURFACE_FRAME_D3D11 ? load_d3d11_frame(frame)
              : frame->kind == ANVIL_SURFACE_FRAME_SHARED_MEMORY ? load_memory_frame(frame)
              : false;
  if (!loaded) {
    set_frame_busy(shell.frame_busy);
    if (shell.frame_busy) {
      SDL_LockMutex(project->lock);
      if (project->latest_frame.generation == frame->generation)
        project->frame_pending = true;
      SDL_UnlockMutex(project->lock);
    } else if (project->state != SHELL_FAILED) {
      HRESULT removed = shell.device->lpVtbl->GetDeviceRemovedReason(shell.device);
      if (FAILED(removed))
        fail_gpu("surface device failed", removed);
      else
        fail_connection(project, "surface resource unavailable or invalid");
    }
    return false;
  }
  set_frame_busy(false);
  shell.have_surface = true;
  if (shell.surface_w == shell.buffer_w - shell.sidebar_w && shell.surface_h == shell.buffer_h) {
    shell.resize_wait_disabled = false;
  }
  return true;
}

static bool wait_for_surface_size(int width, int height) {
  ShellProject *project = shell.selected;
  Uint64 deadline = SDL_GetTicksNS() + SHELL_RESIZE_WAIT_MS * SDL_NS_PER_MS;
  bool matched = false;
  SDL_LockMutex(project->lock);
  for (;;) {
    if (project->frame_pending && project->latest_frame.width == width &&
        project->latest_frame.height == height) {
      matched = true;
      break;
    }
    Uint64 now = SDL_GetTicksNS();
    if (now >= deadline) break;
    SDL_WaitConditionTimeout(project->frame_cond, project->lock,
                             (Sint32)SDL_max(1, (deadline - now) / SDL_NS_PER_MS));
  }
  SDL_UnlockMutex(project->lock);
  return matched;
}

/* Runs inside WM_SIZE, so Windows shows the new window size only together
 * with surface content of that size. This is how the direct window stays
 * smooth during live resize. */
static void resize_step(void) {
  ShellProject *project = shell.selected;
  resize_buffers();
  send_configure(project);
  int width = shell.buffer_w - shell.sidebar_w, height = shell.buffer_h;
  bool stale = !shell.have_surface || shell.surface_w != width || shell.surface_h != height;
  if (stale && project->connected && shell.shown && !shell.resize_wait_disabled &&
      !wait_for_surface_size(width, height)) {
    shell.resize_wait_disabled = true;
    SDL_Log("Anvil shell resize to %dx%d timed out waiting for the surface", width, height);
  }
  AnvilSurfaceFrame frame;
  load_pending_frame(&frame);
  if (shell.shown) composite_and_present();
}

static void handle_frame(void) {
  ShellProject *project = shell.selected;
  AnvilSurfaceFrame frame;
  if (!load_pending_frame(&frame)) return;
  if (project->state == SHELL_STARTING) {
    SDL_Log("Anvil shell showing its first %s frame %dx%d",
            frame.kind == ANVIL_SURFACE_FRAME_D3D11 ? "d3d11" : "memory", shell.surface_w, shell.surface_h);
    set_state(project, SHELL_READY);
  }
  composite_and_present();
  anvil_latency_probe_presented(frame.input_seq);
  if (project->state == SHELL_READY && !project->close_requested_ns)
    anvil_latency_probe_start(shell.window, finish_latency_probe);
}

/* ------------------------------------------------------------------------ */
/* Messages from the surface process                                        */

static void apply_cursor(int cursor) {
  static const SDL_SystemCursor system_cursors[ANVIL_SURFACE_CURSOR_COUNT] = {
      SDL_SYSTEM_CURSOR_DEFAULT,   SDL_SYSTEM_CURSOR_TEXT,    SDL_SYSTEM_CURSOR_EW_RESIZE,
      SDL_SYSTEM_CURSOR_NS_RESIZE, SDL_SYSTEM_CURSOR_POINTER, SDL_SYSTEM_CURSOR_CROSSHAIR,
      SDL_SYSTEM_CURSOR_MOVE,      SDL_SYSTEM_CURSOR_MOVE,
  };
  if (cursor < 0 || cursor >= ANVIL_SURFACE_CURSOR_COUNT)
    cursor = ANVIL_SURFACE_CURSOR_ARROW;
  if (!shell.cursors[cursor])
    shell.cursors[cursor] = SDL_CreateSystemCursor(system_cursors[cursor]);
  SDL_SetCursor(shell.cursors[cursor]);
}

static void apply_window_mode(int mode) {
  bool fullscreen = (SDL_GetWindowFlags(shell.window) & SDL_WINDOW_FULLSCREEN) != 0;
  if (mode != ANVIL_SURFACE_WINDOW_FULLSCREEN && fullscreen)
    SDL_SetWindowFullscreen(shell.window, false);
  switch (mode) {
  case ANVIL_SURFACE_WINDOW_MINIMIZED:
    SDL_MinimizeWindow(shell.window);
    break;
  case ANVIL_SURFACE_WINDOW_MAXIMIZED:
    SDL_MaximizeWindow(shell.window);
    break;
  case ANVIL_SURFACE_WINDOW_FULLSCREEN:
    SDL_SetWindowFullscreen(shell.window, true);
    break;
  default:
    SDL_RestoreWindow(shell.window);
    break;
  }
}

struct ShellDialog {
  ShellProject *project;
  Uint32 connection, event_type;
  uint32_t size;
  void *result;
  SDL_DialogFileFilter filters[ANVIL_SURFACE_DIALOG_FILTER_LIMIT];
  SDL_PropertiesID props;
  uint8_t packet[];
};

static void free_dialog(ShellDialog *dialog) {
  if (dialog->props)
    SDL_DestroyProperties(dialog->props);
  free(dialog->result);
  release_project(dialog->project);
  free(dialog);
}

static void fail_dialog_notification(ShellProject *project, Uint32 connection) {
  int previous = SDL_GetAtomicInt(&project->dialog_failure);
  while (connection > (Uint32)previous) {
    if (SDL_CompareAndSwapAtomicInt(&project->dialog_failure, previous, (int)connection))
      return;
    previous = SDL_GetAtomicInt(&project->dialog_failure);
  }
}

static void SDLCALL dialog_finished(void *userdata, const char *const *paths, int filter) {
  ShellDialog *dialog = userdata;
  ShellProject *project = dialog->project;
  dialog->result = anvil_surface_dialog_result(((AnvilSurfaceDialog *)dialog->packet)->id, paths,
                                               filter, &dialog->size);
  SDL_Event event = {0};
  event.type = dialog->event_type;
  event.user.code = SHELL_EVENT_DIALOG_RESULT;
  event.user.windowID = dialog->connection;
  event.user.data1 = dialog;
  if (!dialog->result || !SDL_PushEvent(&event)) {
    SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Shell could not retain a file dialog result");
    fail_dialog_notification(project, dialog->connection);
    free_dialog(dialog);
  }
}

static void present_dialog(ShellDialog *dialog) {
  ShellProject *project = dialog->project;
  const AnvilSurfaceDialog *request = (const AnvilSurfaceDialog *)dialog->packet;
  SDL_Log("Shell file dialog started: id=%u type=%u connection=%u", request->id, request->type,
          project->connection);
  cancel_input();
  SDL_ClearComposition(shell.window);
  SDL_PropertiesID props = dialog->props;
  dialog->props = 0;
  SDL_ShowFileDialogWithProperties(request->type, dialog_finished, dialog, props);
  SDL_DestroyProperties(props);
}
static void present_deferred_dialogs(ShellProject *project) {
  if (!project->connected || project->state == SHELL_FAILED)
    return;
  for (size_t i = 0; i < SDL_arraysize(project->deferred_dialogs); i++) {
    ShellDialog *dialog = project->deferred_dialogs[i];
    project->deferred_dialogs[i] = NULL;
    if (dialog)
      present_dialog(dialog);
  }
}
static void discard_deferred_dialogs(ShellProject *project) {
  for (size_t i = 0; i < SDL_arraysize(project->deferred_dialogs); i++) {
    ShellDialog *dialog = project->deferred_dialogs[i];
    if (!dialog)
      continue;
    free_dialog(dialog);
    project->deferred_dialogs[i] = NULL;
    project->dialogs[i] = 0;
  }
}
static void show_dialog(ShellProject *project, const ShellMessage *message) {
  if (message->size < sizeof(AnvilSurfaceDialog)) {
    fail_connection(project, "invalid file dialog request");
    return;
  }
  const AnvilSurfaceDialog *request = (const AnvilSurfaceDialog *)message->payload;
  size_t slot = SDL_arraysize(project->dialogs);
  for (size_t i = 0; i < SDL_arraysize(project->dialogs); i++) {
    if (project->dialogs[i] == request->id) {
      fail_connection(project, "duplicate file dialog ID");
      return;
    }
    if (!project->dialogs[i])
      slot = i;
  }
  if (slot == SDL_arraysize(project->dialogs)) {
    fail_connection(project, "file dialog request limit");
    return;
  }
  ShellDialog *dialog = calloc(1, sizeof(*dialog) + message->size);
  if (!dialog) {
    fail_connection(project, "file dialog allocation failed");
    return;
  }
  dialog->project = project;
  dialog->connection = project->connection;
  dialog->event_type = shell.event_type;
  memcpy(dialog->packet, message->payload, message->size);
  SDL_PropertiesID props =
      anvil_surface_dialog_decode(dialog->packet, message->size, dialog->filters);
  if (!props) {
    free(dialog);
    fail_connection(project, "invalid file dialog options");
    return;
  }
  if (!SDL_SetPointerProperty(props, SDL_PROP_FILE_DIALOG_WINDOW_POINTER, shell.window)) {
    SDL_DestroyProperties(props);
    free(dialog);
    fail_connection(project, "file dialog parent allocation failed");
    return;
  }
  project->dialogs[slot] = request->id;
  retain_project(project);
  dialog->props = props;
  if (project == shell.selected)
    present_dialog(dialog);
  else {
    project->deferred_dialogs[slot] = dialog;
    SDL_Log("Shell deferred an unselected Project file dialog: id=%u Project=%u", request->id,
            project->id);
  }
}

static void finish_dialog(ShellProject *project, ShellDialog *dialog) {
  AnvilSurfaceDialogResult *result = dialog->result;
  size_t slot = 0;
  while (slot < SDL_arraysize(project->dialogs) && project->dialogs[slot] != result->id)
    slot++;
  if (slot < SDL_arraysize(project->dialogs)) {
    project->dialogs[slot] = 0;
    if (project->connected) {
      SDL_Log("Shell file dialog finished: id=%u status=%d filter=%d", result->id, result->status,
              result->filter);
      shell_send(project, ANVIL_SURFACE_MSG_DIALOG_RESULT, result, dialog->size, NULL, 0);
      if (project == shell.selected && project->text_active)
        SDL_StartTextInput(shell.window);
    }
  }
  free_dialog(dialog);
}

typedef struct {
  ShellProject *project;
  HWND parent;
  HANDLE process;
  Uint32 connection, serial, event_type;
  bool force;
} ForceCloseDialog;

static void free_force_dialog(ForceCloseDialog *dialog) {
  CloseHandle(dialog->process);
  release_project(dialog->project);
  free(dialog);
}

static int SDLCALL force_close_dialog(void *userdata) {
  ForceCloseDialog *dialog = userdata;
  ShellProject *project = dialog->project;
  const wchar_t *warning =
      L"Force close can lose unsaved files and the latest Workspace changes. "
      L"Terminal Sessions will keep running. Choose Wait to keep this Project running.";
  int answer = IDNO;
  HMODULE controls = LoadLibraryW(L"comctl32.dll");
  typedef HRESULT(WINAPI * TaskDialogFn)(const TASKDIALOGCONFIG *, int *, int *, BOOL *);
  TaskDialogFn task_dialog =
      controls ? (TaskDialogFn)GetProcAddress(controls, "TaskDialogIndirect") : NULL;
  TASKDIALOG_BUTTON buttons[] = {{IDNO, L"Wait"}, {IDYES, L"Force close"}};
  TASKDIALOGCONFIG config = {0};
  config.cbSize = sizeof(config);
  config.hwndParent = dialog->parent;
  config.dwFlags = TDF_ALLOW_DIALOG_CANCELLATION | TDF_SIZE_TO_CONTENT;
  config.pszWindowTitle = L"Anvil - Project not responding";
  config.pszMainInstruction = L"The Project has not completed Close.";
  config.pszContent = warning;
  config.pszMainIcon = TD_WARNING_ICON;
  config.cButtons = SDL_arraysize(buttons);
  config.pButtons = buttons;
  config.nDefaultButton = IDNO;
  if (!task_dialog || FAILED(task_dialog(&config, &answer, NULL, NULL))) {
    answer = MessageBoxW(dialog->parent,
                         L"The Project has not completed Close.\n\nForce close can lose unsaved "
                         L"files and the latest Workspace changes. "
                         L"Terminal Sessions will keep running.\n\nYes: Force close\nNo: Wait",
                         config.pszWindowTitle, MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2);
  }
  if (controls)
    FreeLibrary(controls);
  dialog->force = answer == IDYES;
  SDL_Event event = {0};
  event.type = dialog->event_type;
  event.user.code = SHELL_EVENT_FORCE_RESULT;
  event.user.windowID = dialog->connection;
  event.user.data1 = dialog;
  if (!SDL_PushEvent(&event)) {
    fail_dialog_notification(project, dialog->connection);
    free_force_dialog(dialog);
  }
  return 0;
}

static void offer_force_close(ShellProject *project) {
  if (project->close_prompt || !project->process.hProcess ||
      WaitForSingleObject(project->process.hProcess, 0) != WAIT_TIMEOUT)
    return;
  ForceCloseDialog *dialog = calloc(1, sizeof(*dialog));
  if (!dialog) {
    SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Unable to allocate close warning");
    return;
  }
  if (!DuplicateHandle(GetCurrentProcess(), project->process.hProcess, GetCurrentProcess(),
                       &dialog->process, 0, FALSE, DUPLICATE_SAME_ACCESS)) {
    free(dialog);
    return;
  }
  dialog->parent = shell.hwnd;
  dialog->project = retain_project(project);
  dialog->connection = project->connection;
  dialog->serial = project->close_serial;
  dialog->event_type = shell.event_type;
  SDL_Thread *thread = SDL_CreateThread(force_close_dialog, "AnvilCloseWarning", dialog);
  if (!thread) {
    free_force_dialog(dialog);
    return;
  }
  project->close_prompt = true;
  SDL_DetachThread(thread);
}

static BOOL CALLBACK dismiss_close_warning(HWND window, LPARAM parent) {
  DWORD pid = 0;
  GetWindowThreadProcessId(window, &pid);
  if (pid == GetCurrentProcessId() && GetWindow(window, GW_OWNER) == (HWND)parent) {
    wchar_t title[96];
    GetWindowTextW(window, title, SDL_arraysize(title));
    if (!wcscmp(title, L"Anvil - Project not responding"))
      PostMessageW(window, WM_CLOSE, 0, 0);
  }
  return TRUE;
}

static void close_decision(ShellProject *project, int decision) {
  if (decision < ANVIL_SURFACE_CLOSE_PENDING || decision > ANVIL_SURFACE_CLOSE_ACCEPTED) {
    fail_connection(project, "invalid close decision");
    return;
  }
  if (decision == ANVIL_SURFACE_CLOSE_CANCELLED) {
    if (project == shell.selected)
      shell.closing = false;
    if (project->intentional_exit)
      return;
    stop_close_timer(project);
    project->close_requested_ns = 0;
    project->close_serial++;
    project->close_prompt = false;
    project->close_waiting = false;
    project->unloading = false;
    free(project->dormant);
    project->dormant = NULL;
    EnumWindows(dismiss_close_warning, (LPARAM)shell.hwnd);
    set_state(project, SHELL_READY);
    SDL_Log("Shell close decision: cancelled; Ready; request reset");
  } else {
    if (project == shell.selected && !project->unloading)
      shell.closing = true;
    if (!project->close_requested_ns) {
      project->close_requested_ns = SDL_GetTicksNS();
      project->close_serial++;
    }
    set_state(project, SHELL_CLOSING);
    if (decision == ANVIL_SURFACE_CLOSE_WAITING) {
      if (project != shell.selected)
        select_project(project);
      stop_close_timer(project);
      project->close_waiting = true;
      project->close_serial++;
      project->close_prompt = false;
      EnumWindows(dismiss_close_warning, (LPARAM)shell.hwnd);
      if (!IsWindowVisible(shell.hwnd) || IsIconic(shell.hwnd)) {
        if (IsIconic(shell.hwnd)) SDL_RestoreWindow(shell.window);
        else SDL_ShowWindow(shell.window);
        shell.shown = true;
        send_configure(project);
        SDL_RaiseWindow(shell.window);
        SDL_Log("Shell restored its Window for the pending Close choice");
      }
    } else
      arm_close_timer(project);
    if (decision == ANVIL_SURFACE_CLOSE_ACCEPTED)
      project->intentional_exit = true;
    SDL_Log("Shell close decision: %s", decision == ANVIL_SURFACE_CLOSE_WAITING ? "waiting for user"
                                        : decision == ANVIL_SURFACE_CLOSE_ACCEPTED ? "accepted"
                                                                                   : "pending");
  }
  composite_and_present();
}

static void handle_message(ShellProject *project, ShellMessage *message) {
  if (project->state == SHELL_FAILED)
    return;
  const void *payload = message->payload;
  int value =
      message->size == sizeof(AnvilSurfaceInt) ? ((const AnvilSurfaceInt *)payload)->value : 0;
  if (project != shell.selected) {
    switch (message->type) {
    case ANVIL_SURFACE_MSG_VISIBLE:
    case ANVIL_SURFACE_MSG_OPACITY:
    case ANVIL_SURFACE_MSG_WINDOW_MODE:
    case ANVIL_SURFACE_MSG_FLASH:
    case ANVIL_SURFACE_MSG_BORDERED:
    case ANVIL_SURFACE_MSG_SET_BOUNDS:
    case ANVIL_SURFACE_MSG_CLEAR_IME:
      SDL_Log("Shell ignored an unselected Project Window request: id=%u type=%u", project->id,
              message->type);
      return;
    default:
      break;
    }
  }
  switch (message->type) {
  case ANVIL_SURFACE_MSG_SELECT_PROJECT:
    if (!shell.closing)
      select_project_path(payload);
    break;
  case ANVIL_SURFACE_MSG_UNLOAD_PROJECT:
    if (!shell.closing)
      unload_project_path(payload);
    break;
  case ANVIL_SURFACE_MSG_DIALOG:
    show_dialog(project, message);
    break;
  case ANVIL_SURFACE_MSG_CLOSE_DECISION:
    if (message->size != sizeof(AnvilSurfaceInt))
      fail_connection(project, "invalid close decision size");
    else
      close_decision(project, value);
    break;
  case ANVIL_SURFACE_MSG_EXIT_INTENT:
    if (!message->size) {
      project->intentional_exit = true;
      SDL_Log("Project exit accepted by shell");
    }
    break;
  case ANVIL_SURFACE_MSG_RESTART:
    if (message->size > 1 && message->size < 32768 &&
        ((const char *)payload)[message->size - 1] == 0 && !memchr(payload, 0, message->size - 1)) {
      free(project->restart_path);
      project->restart_path = _strdup(payload);
      project->intentional_exit = true;
    }
    break;
  case ANVIL_SURFACE_MSG_VISIBLE:
    if (message->size == sizeof(AnvilSurfaceInt)) {
      if (value) {
        SDL_ShowWindow(shell.window);
        shell.shown = true;
      } else if (!value) {
        SDL_HideWindow(shell.window);
        shell.shown = false;
      }
      send_configure(project);
    }
    break;
  case ANVIL_SURFACE_MSG_OPACITY:
    if (message->size == sizeof(float)) {
      float opacity;
      memcpy(&opacity, payload, sizeof(opacity));
      if (opacity >= 0 && opacity <= 1)
        SDL_SetWindowOpacity(shell.window, opacity);
    }
    break;
  case ANVIL_SURFACE_MSG_CURSOR:
    project->child_cursor = value;
    if (project == shell.selected && (shell.pointer_in_surface || shell.surface_buttons))
      apply_cursor(value);
    break;
  case ANVIL_SURFACE_MSG_TEXT_INPUT: {
    if (message->size != sizeof(AnvilSurfaceTextInput))
      break;
    const AnvilSurfaceTextInput *input = payload;
    if (input->configuration != project->last_config.configuration)
      break;
    if (input->active >= 0) {
      project->text_active = input->active != 0;
      if (project != shell.selected)
        break;
      if (project->text_active)
        SDL_StartTextInput(shell.window);
      else {
        SDL_ClearComposition(shell.window);
        SDL_StopTextInput(shell.window);
      }
    } else {
      if (project != shell.selected)
        break;
      SDL_Rect rect;
      int cursor;
      if (anvil_surface_text_area(&project->last_config, input, &rect, &cursor)) {
        int point_w, point_h;
        SDL_GetWindowSize(shell.window, &point_w, &point_h);
        float sx = (float)point_w / shell.buffer_w;
        float sy = (float)point_h / shell.buffer_h;
        rect = (SDL_Rect){(int)(rect.x * sx), (int)(rect.y * sy), SDL_max(1, (int)(rect.w * sx)),
                          SDL_max(1, (int)(rect.h * sy))};
        SDL_SetTextInputArea(shell.window, &rect, SDL_clamp((int)(cursor * sx), 0, rect.w));
      }
    }
    break;
  }
  case ANVIL_SURFACE_MSG_CLEAR_IME:
    if (message->size == sizeof(uint64_t) &&
        *(uint64_t *)payload == project->last_config.configuration)
      SDL_ClearComposition(shell.window);
    break;
  case ANVIL_SURFACE_MSG_WINDOW_MODE:
    apply_window_mode(value);
    break;
  case ANVIL_SURFACE_MSG_TITLE: {
    char *title = malloc((size_t)message->size + 1);
    if (!title)
      break;
    memcpy(title, payload, message->size);
    title[message->size] = '\0';
    free(project->title);
    project->title = title;
    if (project == shell.selected)
      SDL_SetWindowTitle(shell.window, title);
    break;
  }
  case ANVIL_SURFACE_MSG_HIT_TEST:
    if (message->size == sizeof(AnvilSurfaceHitTest) &&
        ((AnvilSurfaceHitTest *)payload)->configuration == project->last_config.configuration) {
      memcpy(&project->hit, payload, sizeof(project->hit));
      project->hit.title_height = SDL_clamp(project->hit.title_height, 0, (int)(96 * shell.scale));
      controls_geometry();
      int available = SDL_max(0, shell.controls.left - shell.sidebar_w);
      project->hit.client_x = SDL_clamp(project->hit.client_x, 0, available);
      project->hit.client_width =
          SDL_clamp(project->hit.client_width, 0, available - project->hit.client_x);
      project->hit.client2_x = SDL_clamp(project->hit.client2_x, 0, available);
      project->hit.client2_width =
          SDL_clamp(project->hit.client2_width, 0, available - project->hit.client2_x);
      send_configure(project);
    }
    break;
  case ANVIL_SURFACE_MSG_RAISE:
    if (project != shell.selected) {
      if (shell.closing)
        break;
      select_project(project);
    }
    if (shell.shown) {
      if (current_window_mode() == ANVIL_SURFACE_WINDOW_MINIMIZED)
        SDL_RestoreWindow(shell.window);
      SDL_RaiseWindow(shell.window);
      SDL_Log("Shell forwarded raise: foreground=%d", GetForegroundWindow() == shell.hwnd);
    }
    break;
  case ANVIL_SURFACE_MSG_FLASH:
    SDL_FlashWindow(shell.window, (SDL_FlashOperation)value);
    break;
  case ANVIL_SURFACE_MSG_SET_BOUNDS: {
    if (message->size != sizeof(AnvilSurfaceBounds))
      break;
    const AnvilSurfaceBounds *bounds = payload;
    if (bounds->w <= 0 || bounds->h <= 0)
      break;
    SetWindowPos(shell.hwnd, NULL, bounds->x, bounds->y, bounds->w, bounds->h,
                 SWP_NOZORDER | SWP_NOACTIVATE);
    break;
  }
  case ANVIL_SURFACE_MSG_BORDERED:
    /* The shell window is always borderless. */
    break;
  default:
    break;
  }
}

/* ------------------------------------------------------------------------ */
/* Window and input                                                         */

static void forward_event(const SDL_Event *event, const char *text) {
  ShellProject *project = shell.selected;
  AnvilSurfaceInput input;
  SDL_zero(input);
  input.event = *event;
  input.configuration = project->last_config.configuration;
  input.text_len = text ? (uint32_t)strlen(text) : 0;
  if (input.text_len > ANVIL_SURFACE_MAX_PAYLOAD - sizeof(input)) {
    fail_connection(project, "input payload exceeds the protocol bound");
    return;
  }
  if (event->type == SDL_EVENT_TEXT_INPUT) input.event.text.text = NULL;
  if (event->type == SDL_EVENT_TEXT_EDITING) input.event.edit.text = NULL;
  if (event->type >= SDL_EVENT_DROP_FILE && event->type <= SDL_EVENT_DROP_POSITION) {
    input.event.drop.data = NULL;
    input.event.drop.source = NULL;
  }
  shell_send(project, ANVIL_SURFACE_MSG_INPUT, &input, sizeof(input), text, input.text_len);
}

static void clear_composition(void) {
  SDL_ClearComposition(shell.window);
  SDL_Event event = {0};
  event.type = SDL_EVENT_TEXT_EDITING;
  forward_event(&event, "");
}

static void cancel_input(void) {
  ShellProject *project = shell.selected;
  Uint32 buttons = shell.surface_buttons;
  shell.surface_buttons = 0;
  shell.pressed_control = -1;
  shell.pointer_in_surface = false;
  shell.hovered_control = -1;
  shell.ui_hover_dirty = true;
  ReleaseCapture();
  for (int button = 1; button <= 5; button++) {
    if (!(buttons & SDL_BUTTON_MASK(button))) continue;
    SDL_Event event = {0};
    event.type = SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.button = button;
    event.button.x = shell.pointer_x;
    event.button.y = shell.pointer_y;
    anvil_surface_translate_input(&project->last_config, &event);
    forward_event(&event, NULL);
  }
  clear_composition();
  SDL_Event leave = {0};
  leave.type = SDL_EVENT_WINDOW_MOUSE_LEAVE;
  forward_event(&leave, NULL);
  apply_cursor(ANVIL_SURFACE_CURSOR_ARROW);
}

static void leave_surface(void) {
  if (shell.pointer_in_surface) {
    shell.pointer_in_surface = false;
    SDL_Event leave = {0};
    leave.type = SDL_EVENT_WINDOW_MOUSE_LEAVE;
    forward_event(&leave, NULL);
  }
  if (!shell.surface_buttons)
    apply_cursor(ANVIL_SURFACE_CURSOR_ARROW);
}

static int control_at(float x, float y) {
  ShellProject *project = shell.selected;
  POINT point = {(LONG)x, (LONG)y};
  if (PtInRect(&shell.controls, point)) {
    int width = SDL_max(1, (shell.controls.right - shell.controls.left) / 3);
    return SDL_min(2, ((int)x - shell.controls.left) / width);
  }
  if (project->state == SHELL_FAILED || project->state == SHELL_DORMANT) {
    if (PtInRect(&shell.restart_button, point))
      return 3;
    if (PtInRect(&shell.close_button, point))
      return 4;
  }
  return -1;
}

static void perform_control(int control) {
  ShellProject *project = shell.selected;
  SDL_Log("Shell native control: %d state=%d", control, project->state);
  shell.resize_wait_disabled = true;
  if (control == 0)
    SDL_MinimizeWindow(shell.window);
  else if (control == 1) {
    if (current_window_mode() == ANVIL_SURFACE_WINDOW_MAXIMIZED)
      SDL_RestoreWindow(shell.window);
    else
      SDL_MaximizeWindow(shell.window);
  } else if (control == 3) {
    if (project->state == SHELL_DORMANT) {
      select_project_path(project->project_path);
      return;
    }
    if (!project->project_path) {
      SDL_Log("Shell Restart unavailable: no Project path");
      return;
    }
    if (project->process.hProcess &&
        WaitForSingleObject(project->process.hProcess, 0) != WAIT_OBJECT_0) {
      SDL_Log("Shell Restart refused: previous Project has not exited");
      return;
    }
    if (shell.render_failed) {
      SDL_Log("Shell explicit Restart: initialize presentation once");
      if (!init_d3d11()) {
        release_d3d11();
        InvalidateRect(shell.hwnd, NULL, FALSE);
        return;
      }
      shell.render_failed = false;
    }
    project->restart_path = _strdup(project->project_path);
    if (!project->restart_path || !start_project(project, 0, NULL)) {
      free(project->restart_path);
      project->restart_path = NULL;
      set_state(project, SHELL_FAILED);
    } else {
      free(project->restart_path);
      project->restart_path = NULL;
      composite_and_present();
    }
  } else if (control == 4 && project->state != SHELL_DORMANT) {
    begin_unload(project);
  } else {
    shell.closing = true;
    request_close(project);
  }
}

static bool surface_contains(float x, float y) {
  ShellProject *project = shell.selected;
  const AnvilSurfaceConfigure *config = &project->last_config;
  return x >= config->origin_x && y >= config->origin_y && x < config->origin_x + config->pixel_w &&
         y < config->origin_y + config->pixel_h;
}

static void route_motion(SDL_Event *event) {
  ShellProject *project = shell.selected;
  shell.pointer_x = event->motion.x;
  shell.pointer_y = event->motion.y;
  int control = control_at(event->motion.x, event->motion.y);
  if (shell.hovered_control != control) {
    shell.hovered_control = control;
    shell.ui_hover_dirty = true;
    composite_and_present();
  }
  if (!shell.surface_buttons &&
      (control >= 0 || shell.pressed_control >= 0 || project->state == SHELL_STARTING ||
       project->state == SHELL_FAILED || project->state == SHELL_DORMANT)) {
    leave_surface();
    return;
  }
  bool inside = surface_contains(event->motion.x, event->motion.y) && control < 0;
  if (!inside)
    leave_surface();
  if (shell.surface_buttons || inside) {
    if (inside && !shell.pointer_in_surface) {
      shell.pointer_in_surface = true;
      apply_cursor(project->child_cursor);
      SDL_Event enter = {0};
      enter.type = SDL_EVENT_WINDOW_MOUSE_ENTER;
      forward_event(&enter, NULL);
    }
    anvil_surface_translate_input(&project->last_config, event);
    forward_event(event, NULL);
  }
}

static void route_button(SDL_Event *event) {
  ShellProject *project = shell.selected;
  shell.pointer_x = event->button.x;
  shell.pointer_y = event->button.y;
  Uint32 mask = SDL_BUTTON_MASK(event->button.button);
  bool down = event->type == SDL_EVENT_MOUSE_BUTTON_DOWN;
  int control = control_at(event->button.x, event->button.y);
  if (!shell.surface_buttons && (control >= 0 || shell.pressed_control >= 0)) {
    leave_surface();
    if (event->button.button != SDL_BUTTON_LEFT)
      return;
    if (down) {
      clear_composition();
      shell.pressed_control = control;
      SetCapture(shell.hwnd);
    } else {
      int pressed = shell.pressed_control;
      shell.pressed_control = -1;
      ReleaseCapture();
      if (control >= 0 && pressed == control)
        perform_control(control);
    }
    shell.ui_hover_dirty = true;
    composite_and_present();
    return;
  }
  if (project->state == SHELL_STARTING || project->state == SHELL_FAILED ||
      project->state == SHELL_DORMANT)
    return;
  if (down) {
    if (!shell.surface_buttons && !surface_contains(event->button.x, event->button.y)) {
      clear_composition();
      return;
    }
    shell.surface_buttons |= mask;
    SetCapture(shell.hwnd);
  } else {
    if (!(shell.surface_buttons & mask))
      return;
    shell.surface_buttons &= ~mask;
    if (!shell.surface_buttons) {
      ReleaseCapture();
      if (!surface_contains(event->button.x, event->button.y) || control >= 0)
        leave_surface();
    }
  }
  anvil_surface_translate_input(&project->last_config, event);
  forward_event(event, NULL);
}

static void request_close(ShellProject *project) {
  if (project == shell.selected && !project->unloading)
    shell.closing = true;
  if (project->resolving) {
    project->failed_close = true;
    return;
  }
  if (project->launch && !project->launch->taken) {
    if (!project->close_requested_ns) {
      project->close_requested_ns = SDL_GetTicksNS();
      project->close_serial++;
      arm_close_timer(project);
    }
    set_state(project, SHELL_CLOSING);
    return;
  }
  if (!project->process.hProcess ||
      WaitForSingleObject(project->process.hProcess, 0) == WAIT_OBJECT_0) {
    project->failed_close = true;
    return;
  }
  if (project->close_requested_ns) {
    SDL_Log("Shell ignored repeated Close while a decision is pending");
    return;
  }
  project->close_requested_ns = SDL_GetTicksNS();
  project->close_serial++;
  arm_close_timer(project);
  if (!project->connected) {
    set_state(project, SHELL_CLOSING);
    composite_and_present();
    return;
  }
  set_state(project, SHELL_CLOSING);
  composite_and_present();
  shell_send(project, ANVIL_SURFACE_MSG_CLOSE, NULL, 0, NULL, 0);
}

static void handle_connected(ShellProject *project) {
  if (project->state == SHELL_FAILED)
    return;
  SDL_Log("Anvil shell connected to surface process %lu",
          (unsigned long)project->process.dwProcessId);
  project->connected = true;
  send_configure(project);
  bool focused = project == shell.selected &&
                 (anvil_latency_probe_enabled() ||
                  (SDL_GetWindowFlags(shell.window) & SDL_WINDOW_INPUT_FOCUS) != 0);
  shell_send_int(project, ANVIL_SURFACE_MSG_FOCUS, focused ? 1 : 0);
  if (project->close_requested_ns)
    shell_send(project, ANVIL_SURFACE_MSG_CLOSE, NULL, 0, NULL, 0);
}

SDL_AppResult anvil_shell_event(void *appstate, SDL_Event *event) {
  ShellProject *project = shell.selected;
  (void)appstate;
  check_gpu_failure();
  check_transport_failure(project);
  if (event->type == shell.event_type) {
    if (event->user.code == SHELL_EVENT_MESSAGE) {
      ShellMessage *message = event->user.data1;
      SDL_AddAtomicInt(&message->owner->inbound_bytes, -(int)(sizeof(*message) + message->size));
    }
    project = project_for_connection(event->user.windowID);
    if (!project) {
      if (event->user.code == SHELL_EVENT_MESSAGE) {
        free_message(event->user.data1);
      } else if (event->user.code == SHELL_EVENT_DIALOG_RESULT) {
        ShellDialog *dialog = event->user.data1;
        free_dialog(dialog);
        SDL_Log("Shell discarded a late file dialog result for an old connection");
      } else if (event->user.code == SHELL_EVENT_FORCE_RESULT) {
        ForceCloseDialog *dialog = event->user.data1;
        free_force_dialog(dialog);
      }
      return SDL_APP_CONTINUE;
    }
    switch (event->user.code) {
    case SHELL_EVENT_LAUNCHED:
      finish_launch(project);
      break;
    case SHELL_EVENT_START_TIMEOUT:
      if (project == shell.selected && project->state == SHELL_STARTING &&
          IsWindowVisible(shell.hwnd) && !IsIconic(shell.hwnd))
        fail_connection(project, "startup deadline expired before the first frame");
      break;
    case SHELL_EVENT_CONNECTED:
      handle_connected(project);
      break;
    case SHELL_EVENT_FRAME:
      if (project == shell.selected)
        handle_frame();
      else {
        SDL_LockMutex(project->lock);
        project->frame_pending = false;
        SDL_UnlockMutex(project->lock);
        SDL_Log("Shell discarded a frame from an unselected Project: id=%u", project->id);
      }
      break;
    case SHELL_EVENT_DISCONNECTED:
      if (!project->intentional_exit)
        fail_connection(project, "pipe connection ended");
      break;
    case SHELL_EVENT_MESSAGE:
      handle_message(project, event->user.data1);
      free_message(event->user.data1);
      break;
    case SHELL_EVENT_DIALOG_RESULT:
      finish_dialog(project, event->user.data1);
      break;
    case SHELL_EVENT_CLOSE_TIMEOUT:
      if ((Uint32)(uintptr_t)event->user.data2 == project->close_serial &&
          project->close_requested_ns && !project->close_waiting) {
        project->close_timer = 0;
        if (project->process.hProcess &&
            WaitForSingleObject(project->process.hProcess, 0) == WAIT_OBJECT_0) {
          project->failed_close = true;
          break;
        }
        offer_force_close(project);
      }
      break;
    case SHELL_EVENT_FORCE_RESULT: {
      ForceCloseDialog *dialog = event->user.data1;
      if (dialog->serial == project->close_serial && project->close_requested_ns) {
        project->close_prompt = false;
        if (dialog->force) {
          if (WaitForSingleObject(dialog->process, 0) != WAIT_TIMEOUT ||
              TerminateProcess(dialog->process, 125)) {
            project->intentional_exit = true;
            project->failed_close = true;
            stop_close_timer(project);
            SDL_Log("Shell explicitly forced Project close; Terminal Sessions remain independent");
          } else {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Project forced close failed: %lu",
                         (unsigned long)GetLastError());
            arm_close_timer(project);
          }
        } else {
          project->close_requested_ns = SDL_GetTicksNS();
          arm_close_timer(project);
          SDL_Log("Shell close timeout: Wait selected");
        }
      }
      free_force_dialog(dialog);
      break;
    }
    case SHELL_EVENT_EXITED:
      stop_close_timer(project);
      SDL_Log("Anvil shell surface process exited with code %d", (int)(intptr_t)event->user.data2);
      if (project->restart_path) {
        char *path = _strdup(project->restart_path);
        bool started = false;
        if (path) {
          free(project->project_path);
          project->project_path = path;
          started = start_project(project, 0, NULL);
        }
        free(project->restart_path);
        project->restart_path = NULL;
        if (!started) {
          project->intentional_exit = false;
          fail_connection(project, "Project replacement startup failed");
        }
        return SDL_APP_CONTINUE;
      }
      if (project->intentional_exit) {
        project->connected = false;
        project->failed_close = true;
        if (!project->unloading) {
          shell.closing = true;
          if (project != shell.selected)
            request_close(shell.selected);
        }
        return SDL_APP_CONTINUE;
      }
      set_state(project, SHELL_FAILED);
      project->connected = false;
      if (project != shell.selected)
        return SDL_APP_CONTINUE;
      cancel_input();
      SDL_Log("Project failed unexpectedly; retain shell for recovery");
      SDL_SetWindowTitle(shell.window, "Anvil - Project failed");
      SDL_ShowWindow(shell.window);
      shell.shown = true;
      composite_and_present();
      return SDL_APP_CONTINUE;
    }
    return SDL_APP_CONTINUE;
  }

  /* SDL points become physical client pixels only at this boundary. */
  int point_w, point_h;
  SDL_GetWindowSize(shell.window, &point_w, &point_h);
  float sx = point_w > 0 ? (float)shell.buffer_w / point_w : 1;
  float sy = point_h > 0 ? (float)shell.buffer_h / point_h : 1;
  switch (event->type) {
  case SDL_EVENT_MOUSE_MOTION:
    event->motion.x *= sx;
    event->motion.y *= sy;
    event->motion.xrel *= sx;
    event->motion.yrel *= sy;
    break;
  case SDL_EVENT_MOUSE_BUTTON_DOWN:
  case SDL_EVENT_MOUSE_BUTTON_UP:
    event->button.x *= sx;
    event->button.y *= sy;
    break;
  case SDL_EVENT_MOUSE_WHEEL:
    event->wheel.mouse_x *= sx;
    event->wheel.mouse_y *= sy;
    break;
  case SDL_EVENT_DROP_POSITION:
  case SDL_EVENT_DROP_FILE:
  case SDL_EVENT_DROP_TEXT:
    event->drop.x *= sx;
    event->drop.y *= sy;
    break;
  default:
    break;
  }
  switch (event->type) {
  case SDL_EVENT_QUIT:
  case SDL_EVENT_WINDOW_CLOSE_REQUESTED:
    shell.closing = true;
    request_close(project);
    break;
  case SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED:
    update_scale();
    resize_step();
    break;
  /* WM_SIZE resizes and presents. These only keep the surface's window
   * bounds and mode current. */
  case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
  case SDL_EVENT_WINDOW_RESIZED:
  case SDL_EVENT_WINDOW_MOVED:
  case SDL_EVENT_WINDOW_MINIMIZED:
  case SDL_EVENT_WINDOW_MAXIMIZED:
  case SDL_EVENT_WINDOW_RESTORED:
    shell.ui_dirty = true;
    send_configure(project);
    break;
  case SDL_EVENT_WINDOW_SHOWN:
  case SDL_EVENT_WINDOW_HIDDEN:
    shell.shown = event->type == SDL_EVENT_WINDOW_SHOWN;
    if (!shell.shown) cancel_input();
    send_configure(project);
    break;
  case SDL_EVENT_WINDOW_FOCUS_GAINED:
  case SDL_EVENT_WINDOW_FOCUS_LOST:
    if (event->type == SDL_EVENT_WINDOW_FOCUS_LOST)
      cancel_input();
    if (project->connected && !anvil_latency_probe_enabled()) {
      shell_send_int(project, ANVIL_SURFACE_MSG_FOCUS,
                     event->type == SDL_EVENT_WINDOW_FOCUS_GAINED);
    }
    break;
  case SDL_EVENT_WINDOW_MOUSE_LEAVE:
    shell.hovered_control = -1;
    shell.ui_hover_dirty = true;
    composite_and_present();
    if (!shell.surface_buttons)
      leave_surface();
    break;
  case SDL_EVENT_KEY_DOWN:
  case SDL_EVENT_KEY_UP:
    if (project->state == SHELL_READY || project->state == SHELL_CLOSING)
      forward_event(event, NULL);
    break;
  case SDL_EVENT_TEXT_INPUT:
    if (project->state == SHELL_READY || project->state == SHELL_CLOSING)
      forward_event(event, event->text.text);
    break;
  case SDL_EVENT_TEXT_EDITING:
    if (project->state == SHELL_READY || project->state == SHELL_CLOSING)
      forward_event(event, event->edit.text);
    break;
  case SDL_EVENT_MOUSE_MOTION:
    route_motion(event);
    break;
  case SDL_EVENT_MOUSE_BUTTON_DOWN:
  case SDL_EVENT_MOUSE_BUTTON_UP:
    route_button(event);
    break;
  case SDL_EVENT_MOUSE_WHEEL:
    if (surface_contains(event->wheel.mouse_x, event->wheel.mouse_y) &&
        control_at(event->wheel.mouse_x, event->wheel.mouse_y) < 0 &&
        (project->state == SHELL_READY || project->state == SHELL_CLOSING)) {
      anvil_surface_translate_input(&project->last_config, event);
      forward_event(event, NULL);
    }
    break;
  case SDL_EVENT_DROP_BEGIN:
  case SDL_EVENT_DROP_COMPLETE:
    if (project->state == SHELL_READY || project->state == SHELL_CLOSING)
      forward_event(event, NULL);
    break;
  case SDL_EVENT_DROP_POSITION:
  case SDL_EVENT_DROP_FILE:
  case SDL_EVENT_DROP_TEXT:
    if (!surface_contains(event->drop.x, event->drop.y) ||
        control_at(event->drop.x, event->drop.y) >= 0 || project->state == SHELL_STARTING ||
        project->state == SHELL_FAILED || project->state == SHELL_DORMANT) {
      if (event->type == SDL_EVENT_DROP_POSITION && project->connected) {
        event->drop.x = event->drop.y = -1;
        forward_event(event, NULL);
      }
      break;
    }
    anvil_surface_translate_input(&project->last_config, event);
    forward_event(event, event->drop.data);
    break;
  default:
    break;
  }
  return SDL_APP_CONTINUE;
}

/* ------------------------------------------------------------------------ */
/* Native frame                                                             */

static void push_window_event(SDL_EventType type, float x, float y) {
  SDL_Event event;
  SDL_zero(event);
  event.type = type;
  if (type == SDL_EVENT_MOUSE_MOTION) {
    event.motion.windowID = SDL_GetWindowID(shell.window);
    event.motion.x = x;
    event.motion.y = y;
  } else {
    event.window.windowID = SDL_GetWindowID(shell.window);
  }
  SDL_PushEvent(&event);
}

static LRESULT CALLBACK shell_wndproc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
  ShellProject *project = shell.selected;
  if (msg == WM_TIMER) {
    if (shell.retire_timer && wparam == shell.retire_timer) {
      drain_retired_projects();
      return 0;
    }
    if (shell.resolve_timer && wparam == shell.resolve_timer) {
      finish_resolutions();
      return 0;
    }
    ShellProject *timed = NULL;
    for (ShellProject *item = shell.projects; item; item = item->next)
      if (item->startup_timer && wparam == item->startup_timer) {
        timed = item;
        break;
      }
    if (!timed)
      return CallWindowProcW(shell.sdl_wndproc, hwnd, msg, wparam, lparam);
    project = timed;
    bool waiting = false;
    for (size_t i = 0; i < SDL_arraysize(project->dialogs); i++)
      waiting |= project->dialogs[i] != 0;
    if (!waiting) {
      SDL_Event event = {0};
      event.type = shell.event_type;
      event.user.code = SHELL_EVENT_START_TIMEOUT;
      event.user.windowID = project->connection;
      if (!SDL_PushEvent(&event))
        report_transport_failure(project, FAILURE_EVENT);
    }
    return 0;
  }
  if (msg == SHELL_FAULT_MESSAGE && SDL_getenv("ANVIL_SURFACE_FAULT_PROBE")) {
    SDL_Log("Shell fault probe armed: %u", (unsigned)wparam);
    if (wparam == FAULT_PIPE)
      fail_connection(project, "owned probe broke the pipe");
    else {
      SDL_SetAtomicInt(&probe_fault, (int)wparam);
      if (wparam == FAULT_OPEN) {
        SAFE_RELEASE(shell.shared_mutex);
        SAFE_RELEASE(shell.shared);
        close_memory_frame();
      }
      if (wparam == FAULT_PRESENT)
        composite_and_present();
    }
    return 0;
  }
  if (msg == SHELL_CONTROL_MESSAGE) {
    /* Drive the native controls only in the isolated owned-window probe. */
    const char *probe = SDL_getenv("ANVIL_SURFACE_FAULT_PROBE");
    if (probe && !strcmp(probe, "1") && wparam <= 4)
      perform_control((int)wparam);
    return 0;
  }
  if (anvil_routing_probe_message(shell.window, msg, wparam, lparam)) return 0;
  switch (msg) {
    case WM_KILLFOCUS:
      cancel_input();
      shell_send_int(project, ANVIL_SURFACE_MSG_FOCUS, 0);
      break;
    case WM_CANCELMODE:
      cancel_input();
      break;
    case WM_MOUSEMOVE:
      if (shell.pressed_control >= 0) {
        SDL_Event event = {0};
        event.type = SDL_EVENT_MOUSE_MOTION;
        event.motion.x = (float)GET_X_LPARAM(lparam);
        event.motion.y = (float)GET_Y_LPARAM(lparam);
        route_motion(&event);
        return 0;
      }
      break;
    case WM_LBUTTONDOWN:
    case WM_LBUTTONDBLCLK:
    case WM_LBUTTONUP: {
      float x = (float)GET_X_LPARAM(lparam);
      float y = (float)GET_Y_LPARAM(lparam);
      bool down = msg != WM_LBUTTONUP;
      if (!shell.surface_buttons &&
          (shell.pressed_control >= 0 || (down && control_at(x, y) >= 0))) {
        /* Handle native controls before SDL releases automatic capture.
         * Do not also queue this click through SDL. */
        SDL_Event event = {0};
        event.type = msg == WM_LBUTTONUP ? SDL_EVENT_MOUSE_BUTTON_UP : SDL_EVENT_MOUSE_BUTTON_DOWN;
        event.button.button = SDL_BUTTON_LEFT;
        event.button.x = x;
        event.button.y = y;
        route_button(&event);
        return 0;
      }
      break;
    }
    case WM_CAPTURECHANGED:
      if ((HWND)lparam != hwnd && (shell.pressed_control >= 0 || shell.surface_buttons)) {
        SDL_Log("Shell native control cancelled: capture changed");
        cancel_input();
        shell.ui_hover_dirty = true;
        if (shell.shown) composite_and_present();
      }
      break;
    case WM_NCCALCSIZE:
      return win32_frame_hwnd_nccalcsize(hwnd, wparam, lparam);

    case WM_NCHITTEST: {
      Win32FrameHitTest hit = {
          .title_height = SDL_max(shell.controls.bottom, project->hit.title_height),
          .controls_width = shell.controls.right - shell.controls.left,
          .resize_border = project->last_config.resize_border > 0
                               ? project->last_config.resize_border
                               : (int)(8 * shell.scale),
          .client_x = project->hit.client_x,
          .client_width = project->hit.client_width,
          .client2_x = project->hit.client2_x,
          .client2_width = project->hit.client2_width,
          .content_x = project->last_config.origin_x,
      };
      return win32_frame_hwnd_hit_test(hwnd, &hit, lparam);
    }

    case WM_GETMINMAXINFO:
      CallWindowProcW(shell.sdl_wndproc, hwnd, msg, wparam, lparam);
      win32_frame_hwnd_apply_work_area(hwnd, (MINMAXINFO *)lparam);
      return 0;

    case WM_NCACTIVATE:
      /* SDL tracks keyboard focus from this message; the frame is drawn by
       * the surface, so suppress the default non-client repaint. */
      CallWindowProcW(shell.sdl_wndproc, hwnd, msg, wparam, lparam);
      return TRUE;

    case WM_ERASEBKGND:
      return 1;

    case WM_ENTERSIZEMOVE:
    case WM_EXITSIZEMOVE: {
      LRESULT result = CallWindowProcW(shell.sdl_wndproc, hwnd, msg, wparam, lparam);
      shell.live_resize = msg == WM_ENTERSIZEMOVE;
      send_configure(project);
      return result;
    }

    case WM_SIZE: {
      LRESULT result = CallWindowProcW(shell.sdl_wndproc, hwnd, msg, wparam, lparam);
      if (wparam != SIZE_MINIMIZED && shell.swapchain) resize_step();
      else if (shell.render_failed) InvalidateRect(hwnd, NULL, FALSE);
      return result;
    }

    case WM_PAINT: {
      if (shell.render_failed) {
        PAINTSTRUCT paint;
        HDC dc = BeginPaint(hwnd, &paint);
        paint_failed_window(dc);
        EndPaint(hwnd, &paint);
        return 0;
      }
      LRESULT result = CallWindowProcW(shell.sdl_wndproc, hwnd, msg, wparam, lparam);
      if (shell.shown) composite_and_present();
      return result;
    }

    case WM_NCMOUSEMOVE: {
      /* Title Bar caption areas are non-client, but the surface draws hover
       * state there. */
      POINT pt = { GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam) };
      ScreenToClient(hwnd, &pt);
      push_window_event(SDL_EVENT_MOUSE_MOTION, (float)pt.x, (float)pt.y);
      TRACKMOUSEEVENT tme = { sizeof(tme), TME_LEAVE | TME_NONCLIENT, hwnd, HOVER_DEFAULT };
      TrackMouseEvent(&tme);
      break;
    }

    case WM_NCMOUSELEAVE:
      push_window_event(SDL_EVENT_WINDOW_MOUSE_LEAVE, 0, 0);
      break;

    case WM_NCRBUTTONUP:
      if (wparam == HTCAPTION) {
        win32_frame_hwnd_show_system_menu(hwnd, lparam);
        return 0;
      }
      break;

    case WM_DPICHANGED:
    case WM_SETTINGCHANGE:
    case WM_THEMECHANGED:
      win32_frame_hwnd_update_dwm(hwnd, true, NULL);
      break;
  }
  return CallWindowProcW(shell.sdl_wndproc, hwnd, msg, wparam, lparam);
}

static bool install_native_frame(void) {
  shell.hwnd = (HWND)SDL_GetPointerProperty(SDL_GetWindowProperties(shell.window),
                                            SDL_PROP_WINDOW_WIN32_HWND_POINTER, NULL);
  if (!shell.hwnd) return false;
  SDL_Log("Shell window hwnd=%p", (void *)shell.hwnd);
  shell.sdl_wndproc = (WNDPROC)GetWindowLongPtrW(shell.hwnd, GWLP_WNDPROC);
  SetWindowLongPtrW(shell.hwnd, GWLP_WNDPROC, (LONG_PTR)shell_wndproc);
  win32_frame_hwnd_apply_style(shell.hwnd, false);
  return true;
}

/* ------------------------------------------------------------------------ */
/* Lifecycle                                                                */

static void set_window_icon(void) {
  #include "../resources/icons/icon.inl"
  (void)icon_rgba_len;
  SDL_PixelFormat format = SDL_GetPixelFormatForMasks(32, 0x000000ff, 0x0000ff00, 0x00ff0000, 0xff000000);
  SDL_Surface *surface = SDL_CreateSurfaceFrom(64, 64, format, icon_rgba, 64 * 4);
  SDL_SetWindowIcon(shell.window, surface);
  SDL_DestroySurface(surface);
}

static bool create_pipe(ShellProject *project, char *name, size_t name_size) {
  snprintf(name, name_size, "\\\\.\\pipe\\anvil-surface-%lu-%08x%08x",
           (unsigned long)GetCurrentProcessId(), (unsigned)SDL_rand_bits(), (unsigned)SDL_rand_bits());
  HANDLE handle = CreateNamedPipeA(
    name, PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
    PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
    1, SHELL_PIPE_BUFFER, SHELL_PIPE_BUFFER, 0, NULL);
  if (handle == INVALID_HANDLE_VALUE) return false;
  if (!anvil_ipc_pipe_init(&project->pipe, handle, ANVIL_SURFACE_PROTOCOL_VERSION,
                           ANVIL_SURFACE_MAX_PAYLOAD)) {
    CloseHandle(handle);
    return false;
  }
  return true;
}

/* Called only by the resolve worker. Opening a directory can wait for a remote server. */
static wchar_t *canonical_project_identity(const char *path) {
  wchar_t *wide =
      (wchar_t *)SDL_iconv_string("UTF-16LE", "UTF-8", path, strlen(path) + 1);
  if (!wide) {
    SetLastError(ERROR_NOT_ENOUGH_MEMORY);
    return NULL;
  }
  HANDLE directory =
      CreateFileW(wide, FILE_READ_ATTRIBUTES,
                  FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                  OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
  SDL_free(wide);
  if (directory == INVALID_HANDLE_VALUE)
    return NULL;
  BY_HANDLE_FILE_INFORMATION info;
  if (!GetFileInformationByHandle(directory, &info) ||
      !(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
    CloseHandle(directory);
    SetLastError(ERROR_DIRECTORY);
    return NULL;
  }
  DWORD size = GetFinalPathNameByHandleW(
      directory, NULL, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  wchar_t *final =
      size && size < 32768 ? malloc((size + 1) * sizeof(*final)) : NULL;
  DWORD written =
      final ? GetFinalPathNameByHandleW(directory, final, size + 1,
                                        FILE_NAME_NORMALIZED | VOLUME_NAME_DOS)
            : 0;
  DWORD error = final ? GetLastError() : ERROR_NOT_ENOUGH_MEMORY;
  CloseHandle(directory);
  if (!written || written > size) {
    free(final);
    SetLastError(error);
    return NULL;
  }
  if (!wcsncmp(final, L"\\\\?\\UNC\\", 8)) {
    memmove(final + 2, final + 8, (wcslen(final + 8) + 1) * sizeof(*final));
    final[0] = final[1] = L'\\';
  } else if (!wcsncmp(final, L"\\\\?\\", 4)) {
    memmove(final, final + 4, (wcslen(final + 4) + 1) * sizeof(*final));
  }
  size_t length = wcslen(final), root = 0;
  if (length >= 3 && final[1] == L':' && final[2] == L'\\')
    root = 3;
  else if (length >= 2 && final[0] == L'\\' && final[1] == L'\\') {
    wchar_t *server = wcschr(final + 2, L'\\');
    wchar_t *share = server ? wcschr(server + 1, L'\\') : NULL;
    root = share ? (size_t)(share - final) + 1 : length;
  }
  while (length > root &&
         (final[length - 1] == L'\\' || final[length - 1] == L'/'))
    final[--length] = 0;
  return final;
}

typedef struct {
  char *path;
  wchar_t *identity;
} ProjectIdentity;

static bool choose_project(ProjectIdentity *project, int argc, char **argv) {
  bool option_value = false;
  for (int i = 2; i < argc; i++) {
    if (option_value) {
      option_value = false;
      continue;
    }
    if (argv[i][0] == '-') {
      option_value = anvil_cli_option_value(argv[i]);
      continue;
    }
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, argv[i], -1,
                                    NULL, 0);
    wchar_t *path = count > 0 ? malloc(count * sizeof(wchar_t)) : NULL;
    wchar_t full[32768];
    if (!path || !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, argv[i],
                                      -1, path, count)) {
      free(path);
      return false;
    }
    DWORD n = GetFullPathNameW(path, SDL_arraysize(full), full, NULL);
    free(path);
    if (!n || n >= SDL_arraysize(full))
      return false;
    DWORD attrs = GetFileAttributesW(full);
    if (attrs == INVALID_FILE_ATTRIBUTES ||
        !(attrs & FILE_ATTRIBUTE_DIRECTORY)) {
      wchar_t *slash = wcsrchr(full, L'\\');
      if (!slash)
        return false;
      if (slash == full + 2)
        slash[1] = 0;
      else
        *slash = 0;
      DWORD parent_attrs = GetFileAttributesW(full);
      if (parent_attrs == INVALID_FILE_ATTRIBUTES ||
          !(parent_attrs & FILE_ATTRIBUTE_DIRECTORY))
        continue;
    }
    int bytes = WideCharToMultiByte(CP_UTF8, 0, full, -1, NULL, 0, NULL, NULL);
    free(project->path);
    project->path = bytes > 0 ? malloc(bytes) : NULL;
    if (!project->path)
      return false;
    WideCharToMultiByte(CP_UTF8, 0, full, -1, project->path, bytes, NULL, NULL);
  }
  if (!project->path)
    return false;
  project->identity = canonical_project_identity(project->path);
  if (!project->identity)
    return false;
  char *normalized =
      SDL_iconv_string("UTF-8", "UTF-16LE", (const char *)project->identity,
                       (wcslen(project->identity) + 1) * sizeof(wchar_t));
  if (!normalized)
    return false;
  char *path = _strdup(normalized);
  SDL_free(normalized);
  if (!path)
    return false;
  free(project->path);
  project->path = path;
  return true;
}

struct ProjectResolve {
  ProjectResolve *next;
  SDL_Thread *thread;
  SDL_AtomicInt done;
  unsigned revision;
  bool initial, success, unload;
  int argc;
  char **argv;
  char *path;
  wchar_t *identity;
  DWORD error;
};

static void free_resolution(ProjectResolve *job) {
  for (int i = 0; i < job->argc; i++)
    free(job->argv[i]);
  free(job->argv);
  free(job->path);
  free(job->identity);
  free(job);
}

static int SDLCALL resolve_project_thread(void *data) {
  ProjectResolve *job = data;
  const char *probe = SDL_getenv("ANVIL_SURFACE_FAULT_PROBE");
  const char *delay = SDL_getenv("ANVIL_SURFACE_FAULT_IDENTITY_DELAY");
  if (!job->initial && probe && !strcmp(probe, "1") && delay &&
      !strcmp(delay, "1")) {
    SDL_Log("Shell paused the owned Project identity worker");
    SDL_Delay(7000);
  }
  ProjectIdentity result = {.path = job->path};
  job->success = choose_project(&result, job->argc, job->argv);
  job->path = result.path;
  job->identity = result.identity;
  job->error = job->success ? 0 : GetLastError();
  SDL_SetAtomicInt(&job->done, 1);
  /* The temporary native timer also drains completion if this notification
   * fails. */
  SDL_Event event = {.type = shell.event_type};
  event.user.code = SHELL_EVENT_FRAME;
  SDL_PushEvent(&event);
  return 0;
}

static bool queue_resolution(const char *path, int argc, char **argv, bool initial, bool unload) {
  unsigned pending = 0;
  for (ProjectResolve *item = shell.resolvers; item; item = item->next)
    pending++;
  if (pending >= 8) {
    SDL_Log("Shell rejected Project selection: identity queue full");
    return false;
  }
  ProjectResolve *job =
      take_fault(FAULT_SELECT_ALLOC) ? NULL : calloc(1, sizeof(*job));
  if (!job) {
    SDL_Log("Shell rejected Project selection: identity allocation failed");
    return false;
  }
  job->initial = initial;
  job->unload = unload;
  job->argc = argc;
  job->argv = argc ? calloc(argc, sizeof(*job->argv)) : NULL;
  char *cwd = path ? NULL : SDL_GetCurrentDirectory();
  job->path = _strdup(path ? path : cwd ? cwd : "");
  SDL_free(cwd);
  if (!job->path || (argc && !job->argv)) {
    job->argc = 0;
    free_resolution(job);
    SDL_Log("Shell rejected Project selection: identity allocation failed");
    return false;
  }
  for (int i = 0; i < argc; i++) {
    job->argv[i] = _strdup(argv[i]);
    if (!job->argv[i]) {
      free_resolution(job);
      SDL_Log("Shell rejected Project selection: argument allocation failed");
      return false;
    }
  }
  if (!shell.resolve_timer)
    shell.resolve_timer = SetTimer(shell.hwnd, 0x8000, 100, NULL);
  if (!shell.resolve_timer) {
    free_resolution(job);
    SDL_Log("Shell rejected Project selection: identity timer failed");
    return false;
  }
  job->revision = shell.resolve_revision + (unload ? 0 : 1);
  job->thread =
      SDL_CreateThread(resolve_project_thread, "anvil-project-identity", job);
  if (!job->thread) {
    free_resolution(job);
    SDL_Log("Shell rejected Project selection: identity worker failed");
    return false;
  }
  shell.resolve_revision = job->revision;
  job->next = shell.resolvers;
  shell.resolvers = job;
  return true;
}

static bool stop_transport(ShellProject *project, Uint64 deadline) {
  if (project->pipe.handle)
    anvil_ipc_pipe_cancel(&project->pipe);
  if (project->lock) {
    SDL_LockMutex(project->lock);
    project->writer_stop = true;
    SDL_BroadcastCondition(project->queue_cond);
    SDL_UnlockMutex(project->lock);
  }
  while ((project->launcher && !SDL_GetAtomicInt(&project->launch->done)) ||
         (project->reader && !SDL_GetAtomicInt(&project->reader_done)) ||
         (project->writer && !SDL_GetAtomicInt(&project->writer_done))) {
    if (SDL_GetTicks() >= deadline)
      return false;
    SDL_Delay(1);
  }
  if (project->writer)
    SDL_WaitThread(project->writer, NULL);
  if (project->reader)
    SDL_WaitThread(project->reader, NULL);
  if (project->launcher)
    SDL_WaitThread(project->launcher, NULL);
  project->launcher = NULL;
  if (project->launch) {
    if (!project->launch->taken && project->launch->process.hProcess) {
      CloseHandle(project->launch->process.hThread);
      CloseHandle(project->launch->process.hProcess);
    }
    free(project->launch->command_line);
    release_project(project->launch->project);
    free(project->launch);
    project->launch = NULL;
  }
  project->reader = project->writer = NULL;
  return true;
}

static bool startup_fault(ShellProject *project, const char *phase) {
  const char *probe = SDL_getenv("ANVIL_SURFACE_FAULT_PROBE");
  const char *fault = SDL_getenv("ANVIL_SURFACE_FAULT_STARTUP");
  if (!probe || strcmp(probe, "1") || !fault) return false;
  bool replacement = !strncmp(fault, "replacement-", 12);
  if (replacement) fault += 12;
  return project->id == 1 && project->launch_attempt == (replacement ? 2u : 1u) &&
         !strcmp(fault, phase);
}

static bool start_project(ShellProject *project, int argc, char **argv) {
  /* Replacement starts only after the old process exited. Join cancelled transport users first. */
  if (project->process.hProcess || project->launcher || project->launch || project->reader ||
      project->writer || project->pipe.handle) {
    if (project == shell.selected) {
      cancel_input();
      SDL_StopTextInput(shell.window);
    }
    project->text_active = false;
    project->connected = false;
    if (!stop_transport(project, SDL_GetTicks() + 1000)) {
      SDL_Log("Shell transport cleanup exceeded its deadline");
      return false;
    }
    anvil_ipc_pipe_close(&project->pipe);
    if (project == shell.selected) {
      SAFE_RELEASE(shell.shared_mutex);
      SAFE_RELEASE(shell.shared);
      shell.shared_name[0] = 0;
      close_memory_frame();
    }
    CloseHandle(project->process.hThread);
    CloseHandle(project->process.hProcess);
    project->process = (PROCESS_INFORMATION){0};
    while (project->queue_head) {
      ShellMessage *next = project->queue_head->next;
      free(project->queue_head);
      project->queue_head = next;
    }
    project->queue_tail = NULL;
    project->queue_bytes = 0;
    project->writer_stop = false;
    project->frame_pending = false;
    if (project == shell.selected)
      shell.have_surface = false;
    project->close_requested_ns = 0;
    stop_close_timer(project);
    project->close_serial++;
    project->close_prompt = false;
    discard_deferred_dialogs(project);
    memset(project->dialogs, 0, sizeof(project->dialogs));
    project->last_config = (AnvilSurfaceConfigure){0};
    if (project == shell.selected) {
      shell.surface_buttons = 0;
      shell.pointer_in_surface = false;
      SDL_ClearComposition(shell.window);
      SDL_CaptureMouse(false);
    }
  }
  project->intentional_exit = false;
  SDL_SetAtomicInt(&project->transport_failure, 0);
  SDL_SetAtomicInt(&project->reader_done, 0);
  SDL_SetAtomicInt(&project->writer_done, 0);
  project->connection = ++shell.next_connection;
  project->launch_attempt++;
  set_state(project, SHELL_STARTING);
  shell.ui_dirty = true;
  project->failed_close = false;
  if (project == shell.selected)
    shell.hovered_control = shell.pressed_control = -1;
  char pipe_name[128];
  if (!create_pipe(project, pipe_name, sizeof(pipe_name)) ||
      !launch_child(project, argc, argv, pipe_name))
    return false;
  project->startup_timer =
      SetTimer(shell.hwnd, 0x10000u + project->connection, SHELL_CONNECT_TIMEOUT_MS, NULL);
  if (!project->startup_timer) {
    fail_connection(project, "Project launch timer setup failed");
    return false;
  }
  return true;
}

static void finish_launch(ShellProject *project) {
  if (!project->launch || project->launch->taken || !SDL_GetAtomicInt(&project->launch->done))
    return;
  project->launch->taken = true;
  project->process = project->launch->process;
  if (project->launch->error || !project->process.hProcess) {
    fail_connection(project, "Project process creation failed");
    if (project->close_requested_ns)
      project->failed_close = true;
    return;
  }
  if (project->state == SHELL_FAILED)
    return;
  project->reader = startup_fault(project, "reader")
                        ? NULL
                        : start_transport_thread(reader_thread, "anvil-shell-reader", project);
  project->writer = startup_fault(project, "writer")
                        ? NULL
                        : start_transport_thread(writer_thread, "anvil-shell-writer", project);
  if (startup_fault(project, "timer")) {
    KillTimer(shell.hwnd, project->startup_timer);
    project->startup_timer = 0;
  }
  if (!project->reader || !project->writer ||
      (!project->startup_timer && !project->close_requested_ns)) {
    fail_connection(project, "Project transport setup failed");
    if (stop_transport(project, SDL_GetTicks() + 1000))
      anvil_ipc_pipe_close(&project->pipe);
    else
      SDL_Log("Shell partial startup cleanup exceeded its deadline");
    return;
  }
}

static void select_project(ShellProject *project) {
  if (project == shell.selected)
    return;
  ShellProject *previous = shell.selected;
  cancel_input();
  if (previous->connected)
    shell_send_int(previous, ANVIL_SURFACE_MSG_FOCUS, 0);
  SDL_StopTextInput(shell.window);
  set_frame_busy(false);
  SAFE_RELEASE(shell.shared_mutex);
  SAFE_RELEASE(shell.shared);
  shell.shared_name[0] = 0;
  close_memory_frame();
  shell.have_surface = false;
  shell.selected = project;
  shell.resize_wait_disabled = false;
  shell.ui_dirty = true;
  shell.hovered_control = shell.pressed_control = -1;
  SDL_SetWindowTitle(shell.window, project->title ? project->title : "Anvil - Starting Project");
  send_configure(previous);
  send_configure(project);
  if (project->connected)
    shell_send_int(project, ANVIL_SURFACE_MSG_FOCUS,
        anvil_latency_probe_enabled() || (SDL_GetWindowFlags(shell.window) & SDL_WINDOW_INPUT_FOCUS) != 0);
  if (project->text_active)
    SDL_StartTextInput(shell.window);
  apply_cursor(project->child_cursor);
  present_deferred_dialogs(project);
  SDL_Log("Shell selected loaded Project: id=%u pid=%lu path=%s", project->id,
          (unsigned long)project->process.dwProcessId, project->project_path);
  composite_and_present();
}

static bool select_project_path(const char *path) {
  if (shell.closing || !path || !*path)
    return false;
  return queue_resolution(path, 0, NULL, false, false);
}

static bool unload_project_path(const char *path) {
  if (shell.closing || !path || !*path)
    return false;
  return queue_resolution(path, 0, NULL, false, true);
}

static void begin_unload(ShellProject *project) {
  if (project->unloading)
    return;
  if (!project->identity || !project->project_path) {
    shell.closing = true;
    request_close(project);
    return;
  }
  DormantProject *dormant = calloc(1, sizeof(*dormant));
  if (!dormant) {
    SDL_Log("Shell rejected Project unload: allocation failed");
    return;
  }
  project->dormant = dormant;
  project->unloading = true;
  discard_deferred_dialogs(project);
  SDL_Log("Shell requested Project unload: id=%u connection=%u", project->id, project->connection);
  request_close(project);
}

static void finish_resolutions(void) {
  ProjectResolve **link = &shell.resolvers;
  while (*link) {
    ProjectResolve *job = *link;
    if (!SDL_GetAtomicInt(&job->done)) {
      link = &job->next;
      continue;
    }
    if (job->thread)
      SDL_WaitThread(job->thread, NULL);
    *link = job->next;
    ShellProject *project = job->initial ? shell.selected : NULL;
    if (job->initial)
      project->resolving = false;
    if (job->initial && shell.closing) {
      project->failed_close = true;
    } else if (!job->success) {
      SDL_Log("Shell rejected Project identity: Windows error=%lu",
              (unsigned long)job->error);
      if (job->initial)
        fail_connection(project, "Initial Project identity resolution failed");
    } else if (job->initial ||
               (!shell.closing && (job->unload || job->revision == shell.resolve_revision))) {
      if (!job->initial) {
        for (ShellProject *item = shell.projects; item; item = item->next)
          if (item->identity &&
              CompareStringOrdinal(item->identity, -1, job->identity, -1,
                                   TRUE) == CSTR_EQUAL) {
            project = item;
            break;
          }
      }
      if (job->unload) {
        if (project)
          begin_unload(project);
        free_resolution(job);
        continue;
      }
      DormantProject **dormant_link = &shell.dormants;
      while (*dormant_link && CompareStringOrdinal((*dormant_link)->identity, -1, job->identity, -1,
                                                   TRUE) != CSTR_EQUAL)
        dormant_link = &(*dormant_link)->next;
      DormantProject *dormant = *dormant_link;
      bool created = job->initial || !project;
      if (!project)
        project = new_project();
      if (!project)
        SDL_Log("Shell rejected Project selection: Project allocation failed");
      else {
        if (created) {
          free(project->project_path);
          free(project->identity);
          project->project_path = job->path;
          job->path = NULL;
          project->identity = job->identity;
          job->identity = NULL;
          if (dormant) {
            project->id = dormant->id;
            *dormant_link = dormant->next;
            if (shell.empty->project_path == dormant->path)
              shell.empty->project_path = NULL;
            free(dormant->path);
            free(dormant->identity);
            free(dormant->title);
            free(dormant);
          }
        }
        select_project(project);
        if (created || (project->failed_close && project->process.hProcess &&
                        WaitForSingleObject(project->process.hProcess, 0) ==
                            WAIT_OBJECT_0)) {
          if (!start_project(project, job->initial ? job->argc : 0,
                             job->initial ? job->argv : NULL))
            fail_connection(project, "Project selection startup failed");
        }
      }
    }
    free_resolution(job);
  }
  if (!shell.resolvers && shell.resolve_timer) {
    KillTimer(shell.hwnd, shell.resolve_timer);
    shell.resolve_timer = 0;
  }
}

static void complete_unload(ShellProject *project) {
  DormantProject *dormant = project->dormant;
  project->dormant = NULL;
  dormant->id = project->id;
  dormant->path = project->project_path;
  project->project_path = NULL;
  dormant->identity = project->identity;
  project->identity = NULL;
  dormant->title = project->title;
  project->title = NULL;
  dormant->next = shell.dormants;
  shell.dormants = dormant;
  ShellProject **link = &shell.projects;
  while (*link != project)
    link = &(*link)->next;
  *link = project->next;
  if (shell.selected == project) {
    if (shell.projects)
      select_project(shell.projects);
    else {
      shell.empty->project_path = dormant->path;
      select_project(shell.empty);
      SDL_SetWindowTitle(shell.window, "Anvil - Dormant Project");
    }
  }
  project->connected = false;
  stop_close_timer(project);
  if (project->startup_timer)
    KillTimer(shell.hwnd, project->startup_timer);
  project->startup_timer = 0;
  discard_deferred_dialogs(project);
  if (project->pipe.handle)
    anvil_ipc_pipe_cancel(&project->pipe);
  SDL_LockMutex(project->lock);
  project->writer_stop = true;
  SDL_BroadcastCondition(project->queue_cond);
  SDL_UnlockMutex(project->lock);
  project->next = shell.retiring;
  shell.retiring = project;
  if (!shell.retire_timer)
    shell.retire_timer = SetTimer(shell.hwnd, 0x8001, 100, NULL);
  SDL_Log("Shell Project is Dormant: id=%u path=%s", dormant->id, dormant->path);
}

static void drain_retired_projects(void) {
  ShellProject **link = &shell.retiring;
  while (*link) {
    ShellProject *project = *link;
    if (!stop_transport(project, SDL_GetTicks())) {
      link = &project->next;
      continue;
    }
    while (project->queue_head) {
      ShellMessage *message = project->queue_head;
      project->queue_head = message->next;
      free_message(message);
    }
    *link = project->next;
    release_project(project);
  }
  if (!shell.retiring && shell.retire_timer) {
    KillTimer(shell.hwnd, shell.retire_timer);
    shell.retire_timer = 0;
  }
}

SDL_AppResult anvil_shell_init(void **appstate, int argc, char **argv) {
  ShellProject *project = new_project();
  if (!project)
    return SDL_APP_FAILURE;
  shell.selected = project;
  shell.empty = allocate_project();
  if (!shell.empty)
    return SDL_APP_FAILURE;
  shell.empty->state = SHELL_DORMANT;
  *appstate = &shell;
  project->child_cursor = ANVIL_SURFACE_CURSOR_ARROW;
  anvil_surface_log_init("shell");
  anvil_latency_probe_init("shell");

  SDL_SetAppMetadata("Anvil", ANVIL_PROJECT_VERSION_STR, "io.github.dcostap.Anvil");
  SDL_SetHint(SDL_HINT_MAIN_CALLBACK_RATE, "waitevent");
  SDL_SetHint(SDL_HINT_QUIT_ON_LAST_WINDOW_CLOSE, "0");
  SDL_SetHint(SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH, "1");
  /* Capture belongs to the shell's routed target, not SDL's button queue. */
  SDL_SetHint(SDL_HINT_MOUSE_AUTO_CAPTURE, "0");
  SDL_SetHint(SDL_HINT_IME_IMPLEMENTED_UI, "composition");
  SDL_SetHint("SDL_MOUSE_DOUBLE_CLICK_RADIUS", "4");
  if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS)) {
    SDL_Log("Anvil shell could not initialize SDL: %s", SDL_GetError());
    return SDL_APP_FAILURE;
  }
  SDL_SetEventEnabled(SDL_EVENT_DROP_FILE, true);
  SDL_SetEventEnabled(SDL_EVENT_DROP_TEXT, true);
  SDL_SetEventEnabled(SDL_EVENT_DROP_BEGIN, true);
  SDL_SetEventEnabled(SDL_EVENT_DROP_POSITION, true);
  SDL_SetEventEnabled(SDL_EVENT_DROP_COMPLETE, true);

  shell.event_type = SDL_RegisterEvents(1);
  if (!shell.event_type || !project->lock || !project->queue_cond || !project->frame_cond)
    return SDL_APP_FAILURE;

  const SDL_DisplayMode *mode = SDL_GetDesktopDisplayMode(SDL_GetPrimaryDisplay());
  int width = mode ? (int)(mode->w * 0.8) : 1280;
  int height = mode ? (int)(mode->h * 0.8) : 800;
  shell.window =
      SDL_CreateWindow("Anvil", width, height,
                       SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY | SDL_WINDOW_HIDDEN);
  if (!shell.window || !install_native_frame()) {
    SDL_Log("Anvil shell could not create its window: %s", SDL_GetError());
    return SDL_APP_FAILURE;
  }
  update_scale();
  SDL_SetWindowMinimumSize(shell.window, 240 + shell.sidebar_w, 180);
  set_window_icon();
  if (!init_d3d11())
    fail_gpu("initial presentation creation failed", E_FAIL);
  else if (!queue_resolution(NULL, argc, argv, true, false)) {
    SDL_Log("Anvil shell could not start its surface process: %lu", (unsigned long)GetLastError());
    set_state(project, SHELL_FAILED);
  } else
    project->resolving = true;
  composite_and_present();
  SDL_ShowWindow(shell.window);
  shell.shown = true;
  if (project->state == SHELL_STARTING)
    SDL_Log("Shell state: Starting");
  return SDL_APP_CONTINUE;
}

SDL_AppResult anvil_shell_iterate(void *appstate) {
  ShellProject *project = shell.selected;
  (void)appstate;
  check_gpu_failure();
  finish_resolutions();
  for (ShellProject *item = shell.projects; item; item = item->next) {
    finish_launch(item);
    check_transport_failure(item);
    if ((Uint32)SDL_GetAtomicInt(&item->dialog_failure) == item->connection && item->connected)
      fail_connection(item, "native dialog result notification failed");
  }
  for (ShellProject *item = shell.projects, *next; item; item = next) {
    next = item->next;
    if (item->unloading && item->failed_close && !item->resolving &&
        (!item->launch || item->launch->taken) &&
        (!item->process.hProcess ||
         WaitForSingleObject(item->process.hProcess, 0) == WAIT_OBJECT_0))
      complete_unload(item);
  }
  drain_retired_projects();
  project = shell.selected;
  if (shell.frame_busy) handle_frame();
  if (shell.closing && project->failed_close) {
    if (project->launch && !project->launch->taken)
      return SDL_APP_CONTINUE;
    ShellProject *next = NULL;
    for (ShellProject *item = shell.projects; item; item = item->next)
      if (item != project && !item->failed_close &&
          ((item->launch && !item->launch->taken) ||
           (item->process.hProcess &&
            WaitForSingleObject(item->process.hProcess, 0) == WAIT_TIMEOUT))) {
        next = item;
        break;
      }
    if (!next)
      return SDL_APP_SUCCESS;
    select_project(next);
    request_close(next);
  }
  return SDL_APP_CONTINUE;
}

void anvil_shell_quit(void *appstate, SDL_AppResult result) {
  (void)appstate;
  (void)result;
  /* Project loss detection owns save/detach and its deadline. Never kill it with a shell job. */
  Uint64 deadline = SDL_GetTicks() + 1000;
  for (ProjectResolve *job = shell.resolvers; job; job = job->next) {
    while (!SDL_GetAtomicInt(&job->done)) {
      if (SDL_GetTicks() >= deadline) {
        SDL_Log("Shell identity shutdown deadline expired; exit this shell only");
        _Exit(result == SDL_APP_FAILURE ? 1 : 0);
      }
      SDL_Delay(1);
    }
    SDL_WaitThread(job->thread, NULL);
  }
  for (ShellProject *project = shell.projects; project; project = project->next) {
    stop_close_timer(project);
    if (project->startup_timer)
      KillTimer(shell.hwnd, project->startup_timer);
    if (!stop_transport(project, deadline)) {
      SDL_Log("Shell transport shutdown deadline expired; exit this shell only");
      _Exit(result == SDL_APP_FAILURE ? 1 : 0);
    }
  }
  for (ShellProject *project = shell.retiring; project; project = project->next) {
    if (!stop_transport(project, deadline)) {
      SDL_Log("Shell retired transport shutdown deadline expired; exit this shell only");
      _Exit(result == SDL_APP_FAILURE ? 1 : 0);
    }
  }
  if (shell.retry_timer) SDL_RemoveTimer(shell.retry_timer);
}

#else

SDL_AppResult anvil_shell_init(void **appstate, int argc, char **argv) {
  (void)appstate; (void)argc; (void)argv;
  SDL_Log("The Anvil shell is only available on Windows.");
  return SDL_APP_FAILURE;
}
SDL_AppResult anvil_shell_event(void *appstate, SDL_Event *event) {
  (void)appstate; (void)event;
  return SDL_APP_FAILURE;
}
SDL_AppResult anvil_shell_iterate(void *appstate) {
  (void)appstate;
  return SDL_APP_FAILURE;
}
void anvil_shell_quit(void *appstate, SDL_AppResult result) {
  (void)appstate; (void)result;
}

#endif
