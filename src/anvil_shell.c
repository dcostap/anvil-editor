#include "anvil_shell.h"

#ifdef _WIN32

#include "surface_protocol.h"
#include "input_latency_probe.h"
#include "cli_args.h"
#include "win32_frame_hwnd.h"
#include "project_sidebar.h"
#include "project_sidebar_scan.h"
#include "sidebar_registry_watch.h"
#include "process_exit.h"
#include "shell_launch.h"
#include "shell_state.h"
#include "shell_adoption.h"
#include "shell_compose_shader.h"

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

/* The shell owns the Sidebar region, including its native Restart action. */
#define SHELL_SIDEBAR_POINTS 240
#define SHELL_CONNECT_TIMEOUT_MS 30000
#define SHELL_SIDEBAR_HEALTHY_MS 60000
#define SHELL_WRITE_QUEUE_LIMIT (8u * 1024u * 1024u)
#define SHELL_SYNC_TIMEOUT_MS 0
#define SHELL_PIPE_BUFFER (64u * 1024u)
/* How long one resize step waits for a surface frame of the new size. */
#define SHELL_RESIZE_WAIT_MS 50
#define SHELL_CLOSE_TIMEOUT_MS 5000
/* Covers the Project's shell-loss save, which can take up to its 5 s deadline. */
#define SHELL_ADOPTION_REQUEST_MS 8000

/* Owned-window fault actions. These require the isolated test environment. */
#define SHELL_FAULT_MESSAGE (WM_APP + 0x4b)
#define SHELL_CONTROL_MESSAGE (WM_APP + 0x4c)
#define SHELL_MODEL_MESSAGE (WM_APP + 0x4d)
#define SHELL_PICKER_MESSAGE (WM_APP + 0x50)
/* Probe only: save the next composed frame as ANVIL_SHELL_CAPTURE_DIR/capture-<wparam>.bmp. */
#define SHELL_CAPTURE_MESSAGE (WM_APP + 0x52)
#define SHELL_MENU_NEW_WINDOW 0xe010
#define SHELL_MENU_OPEN_PROJECT 0xe020
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
  SHELL_EVENT_PICKER_RESULT,
  SHELL_EVENT_EXTERNAL,
};

typedef enum { SHELL_STARTING, SHELL_READY, SHELL_CLOSING, SHELL_FAILED, SHELL_DORMANT } ShellState;
typedef struct DormantProject {
  struct DormantProject *next;
  Uint32 id;
  char *path, *title;
  wchar_t *identity;
} DormantProject;
typedef struct ShellWindow ShellWindow;
typedef struct ShellDialog ShellDialog;
typedef struct ProjectLaunch ProjectLaunch;
typedef struct ProjectResolve ProjectResolve;
typedef struct ShellPicker ShellPicker;

typedef struct ShellProject {
  Uint32 window_id;
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
  bool exit_announced;
  bool failed_close;
  bool unloading;
  DormantProject *dormant;
  char *restart_path, *project_path;
  wchar_t *identity;
  bool resolving;
  /* A restored Project waits for its turn to start. Rank 0 is the frontmost saved Window. */
  bool restore_waiting;
  int restore_rank;
  /* A running Project from the shell that ended. Its first start asks it to connect instead of creating a
   * process. */
  DWORD adopt_pid;
  uint64_t adopt_created;
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
  bool sidebar;
} ShellProject;

typedef struct {
  ID3D11Texture2D *surface, *shared;
  IDXGIKeyedMutex *shared_mutex;
  int surface_w, surface_h; /* the last frame's size within the private texture */
  int texture_w, texture_h; /* private texture capacity; it grows with slack */
  bool have_surface, busy;
  /* Screen position of the last frame that matched its configuration. A stale frame stays there during a live
   * resize, so a left- or top-edge drag does not move the content. */
  POINT anchor;
  bool anchored;
  /* The last frame has premultiplied alpha; the shell blends it instead of copying it. */
  bool transparent;
  ID3D11ShaderResourceView *view; /* for blending; follows the private texture */
  ID3D11Texture2D *view_texture;
  char shared_name[ANVIL_SURFACE_NAME_MAX];
  HANDLE memory_mapping, memory_mutex;
  const uint8_t *memory_view;
  size_t memory_size;
  char memory_name[ANVIL_SURFACE_NAME_MAX];
} ShellPresentation;

struct ShellWindow {
  ShellWindow *next;
  bool sidebar;
  Uint32 id;
  ShellProject *selected, *empty;
  ShellProject *sidebar_client; /* Surface state only; the shared record owns the transport. */
  bool closing;
  bool removing;
  bool picker_pending;
  /* Front-to-back order for App State. A larger value was activated later. */
  uint64_t activated;
  /* The Window's App State entry when its Close began. A Close changes the selection as it ends Projects. */
  bool close_entry_valid;
  AnvilShellWindowState close_entry;
  char notice[256];
  unsigned resolve_revision;
  uint64_t close_generation;
  ShellPresentation project_presentation, sidebar_presentation;
  SDL_Window *window;
  HWND hwnd;
  WNDPROC sdl_wndproc;

  ID3D11Device *device;
  ID3D11Device1 *device1;
  ID3D11DeviceContext *context;
  IDXGISwapChain1 *swapchain;
  ID3D11Texture2D *backbuffer;
  ID3D11RenderTargetView *rtv;
  bool render_failed;
  const char *gpu_failure;
  int buffer_w, buffer_h;

  /* Frames coalesce: the main thread composites only the newest one. */

  /* Resize steps present only after the surface catches up to the new size.
   * A step that times out stops that wait until a matching frame arrives, so
   * a slow surface process can not make every step wait. */
  bool live_resize;
  bool resize_wait_disabled;
  /* The selected Project's frame background, R | G << 8 | B << 16 | A << 24. Exposed areas use it. */
  uint32_t background;
  /* The Project's modal overlay dim, in the same format; the shell extends it over the Sidebar. */
  uint32_t overlay;
  /* Blending for transparent layers. Without it, layers are copied. */
  ID3D11VertexShader *compose_vs;
  ID3D11PixelShader *compose_ps;
  ID3D11Buffer *compose_constants;
  ID3D11BlendState *compose_blend;
  ID3D11RasterizerState *compose_raster;
  bool compose_failed;
  unsigned capture; /* probe capture index of the next composed frame, or zero */

  float scale;
  int sidebar_w;
  Uint32 surface_buttons;
  float pointer_x, pointer_y;
  bool pointer_in_surface;
  bool pointer_in_sidebar; /* the Sidebar surface received motion and needs a leave */
  bool shown;
  ID3D11Texture2D *ui;
  ID3D11ShaderResourceView *ui_view;
  int ui_w, ui_h;               /* layer capacity */
  int ui_layout_w, ui_layout_h; /* the size the layer was last painted for */
  bool ui_dirty;
  bool ui_hover_dirty;
  HDC ui_dc;
  HBITMAP ui_bitmap;
  HGDIOBJ ui_old_bitmap;
  void *ui_pixels;
  bool frame_busy;
  SDL_TimerID retry_timer;
  int hovered_control, pressed_control;
  RECT controls, restart_button, close_button;
  RECT failure_card;
};

typedef struct {
  ShellProject *projects;
  ShellProject *retiring;
  DormantProject *dormants;
  Uint32 next_connection, next_project;
  ProjectResolve *resolvers;
  UINT_PTR resolve_timer;
  UINT_PTR state_timer;
  bool state_enabled;
  UINT_PTR restore_timer;
  Uint32 restore_active;
  Uint64 restore_active_since;
  uint64_t activation;
  UINT_PTR retire_timer;
  AnvilSidebarModel sidebar;
  AnvilSidebarScan *sidebar_scan;
  char *sidebar_userdir, *sidebar_recents;
  UINT_PTR sidebar_timer;
  AnvilSidebarWatch *sidebar_watch;
  uint64_t sidebar_notified_revision;
  UINT_PTR sidebar_restart_timer;
  unsigned sidebar_restart_attempts;
  bool sidebar_restart_limited;
  Uint64 sidebar_failure_since;
  bool sidebar_waiting_exit;
  UINT_PTR sidebar_healthy_timer;
  Uint64 sidebar_healthy_since;
  Uint32 sidebar_healthy_connection;
  unsigned sidebar_source_revision, sidebar_scan_revision, sidebar_jobs;
  bool sidebar_seeded, sidebar_scan_requested;
  ShellProject *sidebar_process;
  ShellWindow *windows;
  Uint32 next_window, sidebar_window_id;
  HWND service_hwnd;
  bool shutting_down;
  ShellPicker *pickers;
  Uint32 event_type;
  SDL_Cursor *cursors[ANVIL_SURFACE_CURSOR_COUNT];
} Shell;

static Shell shell;
_Static_assert(sizeof(uintptr_t) == 8, "Shell timer tags require 64-bit uintptr_t");
/* Window lookup runs only on the native UI thread. Async users carry IDs. */
/* `_Exit` skips atexit hooks. The shell's own D3D11 device also owns idle-priority driver threads. */
static _Noreturn void shell_exit(int code) {
  anvil_process_prepare_exit();
  _Exit(code);
}
static ShellWindow *window_for_id(Uint32 id) {
  for (ShellWindow *window = shell.windows; window; window = window->next)
    if (window->id == id) return window;
  return NULL;
}
static bool start_project(ShellProject *project, int argc, char **argv);
static void composite_and_present(ShellWindow *window);
static void request_close(ShellProject *project);
static void cancel_input(ShellWindow *window);
static void set_state(ShellProject *project, ShellState state);
static void check_transport_failure(ShellProject *project);
static void check_gpu_failure(ShellWindow *window);
static void close_memory_frame(ShellPresentation *surface);
static bool select_project_path(ShellWindow *window, const char *path);
static void select_project(ShellProject *project);
static void move_project(ShellWindow *requester, uint32_t project_id, uint32_t target_id);
static void present_deferred_dialogs(ShellProject *project);
static void finish_launch(ShellProject *project);
static void finish_resolutions(void);
static bool queue_resolution(ShellWindow *window, const char *path, int argc, char **argv, bool initial, bool unload,
                             bool new_window, AnvilShellLaunchRequest *external);
static bool unload_project_path(ShellWindow *window, const char *path);
static void begin_unload(ShellProject *project);
static void drain_retired_projects(void);
static void service_sidebar(void);
static void notify_sidebar_changes(void);
static void sidebar_source(const AnvilSurfaceSidebarSource *source, uint32_t size);
static void sync_sidebar_model(void);
static AnvilSidebarProject *sidebar_project(const char *path);
static void probe_sidebar_model(ShellWindow *window, WPARAM action, LPARAM value);
static void start_sidebar(void);
static void schedule_sidebar_restart(void);
static ShellWindow *create_window(const AnvilShellWindowState *placement);
static bool destroy_window(ShellWindow *window);
static void save_windows(bool final);
static void advance_restore(void);
static void retire_failed_placeholder(ShellProject *project);
static bool open_project_window(ShellWindow *window, const char *path);
static void show_project_picker(ShellWindow *window);
static void finish_project_picker(ShellPicker *picker);
static void probe_project_picker(WPARAM action, LPARAM window_id);
static void check_picker_failures(void);
/* The swapchain background shows where Windows grows the window before the next present. */
static void apply_swapchain_background(ShellWindow *window) {
  if (!window->swapchain) return;
  uint32_t c = window->background;
  DXGI_RGBA rgba = {(c & 0xff) / 255.0f, (c >> 8 & 0xff) / 255.0f, (c >> 16 & 0xff) / 255.0f, 1.0f};
  window->swapchain->lpVtbl->SetBackgroundColor(window->swapchain, &rgba);
}
/* The Project frame's background fills exposed areas, the native UI and the DWM border. */
static void apply_background(ShellWindow *window, uint32_t background) {
  background |= 0xffu << 24;
  if (window->background == background) return;
  window->background = background;
  apply_swapchain_background(window);
  COLORREF color = background & 0xffffff;
  if (window->hwnd) win32_frame_hwnd_update_dwm(window->hwnd, true, &color);
  window->ui_dirty = true;
  SDL_Log("Shell Window background: id=%u color=%06x", window->id, (unsigned)color);
}
static void window_notice(ShellWindow *window, const char *text) {
  SDL_strlcpy(window->notice, text, sizeof(window->notice));
  window->ui_dirty = true;
  SDL_Log("Shell Window status: id=%u %s", window->id, text);
  if (window->shown) composite_and_present(window);
}
static void window_entry(ShellWindow *window, AnvilShellWindowState *entry);
static void windows_changed(void);
static void begin_window_close(ShellWindow *window) {
  if (!window->closing) {
    free(window->close_entry.path);
    window_entry(window, &window->close_entry);
    window->close_entry.path = window->close_entry.path ? _strdup(window->close_entry.path) : NULL;
    window->close_entry_valid = true;
    window->closing = true;
    window->close_generation++;
    window->resolve_revision++;
  }
}
static void reset_unload(ShellProject *project) {
  project->unloading = false;
  free(project->dormant);
  project->dormant = NULL;
}
static ShellProject *project_for_connection(Uint32 connection) {
  if (shell.sidebar_process && shell.sidebar_process->connection == connection)
    return shell.sidebar_process;
  for (ShellProject *project = shell.projects; project; project = project->next)
    if (project->connection == connection)
      return project;
  return NULL;
}
static ShellProject *allocate_project(ShellWindow *window) {
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
  project->window_id = window->id;
  SDL_SetAtomicInt(&project->references, 1);
  project->child_cursor = ANVIL_SURFACE_CURSOR_ARROW;
  return project;
}
static ShellProject *new_project(ShellWindow *window) {
  ShellProject *project = allocate_project(window);
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
  if (project->sidebar && project != shell.sidebar_process) {
    if (shell.sidebar_process) fail_connection(shell.sidebar_process, cause);
    return;
  }
  ShellWindow *window = window_for_id(project->window_id);
  if (!window) return;
  SDL_Log("Shell connection failed: %s; Project=%u connection=%u", cause, project->id,
          project->connection);
  project->connected = false;
  stop_close_timer(project);
  if (project == window->selected)
    cancel_input(window);
  anvil_ipc_pipe_cancel(&project->pipe);
  if (project->pipe.handle)
    DisconnectNamedPipe(project->pipe.handle);
  set_state(project, SHELL_FAILED);
  if (project == window->selected) {
    SDL_SetWindowTitle(window->window, "Anvil - Project failed");
    composite_and_present(window);
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
  uintptr_t tag = (uintptr_t)data;
  SDL_Event event = {0};
  event.type = shell.event_type;
  event.user.code = SHELL_EVENT_FRAME;
  event.user.windowID = (Uint32)tag;
  event.user.data2 = (void *)(tag >> 32);
  SDL_PushEvent(&event);
  return interval;
}

static void set_frame_busy(ShellWindow *window, bool busy) {
  window->frame_busy = busy;
  if (busy && !window->retry_timer) {
    uintptr_t tag = ((uintptr_t)window->id << 32) | window->selected->connection;
    window->retry_timer = SDL_AddTimer(16, retry_frame, (void *)tag);
    SDL_Log("Shell frame retry started; last safe frame=%s",
            window->project_presentation.have_surface ? "retained" : "none");
  } else if (!busy && window->retry_timer) {
    SDL_RemoveTimer(window->retry_timer);
    window->retry_timer = 0;
    SDL_Log("Shell frame retry stopped");
  }
}
static void set_surface_busy(ShellWindow *window, ShellPresentation *surface, bool busy) {
  surface->busy = busy;
  set_frame_busy(window, window->project_presentation.busy || window->sidebar_presentation.busy);
}

static void set_state(ShellProject *project, ShellState state) {
  ShellWindow *window = window_for_id(project->window_id);
  if (!window) return;
  if (project->state == state)
    return;
  project->state = state;
  if (project == shell.sidebar_process) {
    for (ShellWindow *item = shell.windows; item; item = item->next) {
      item->ui_dirty = true;
      if (item->sidebar_client && state != SHELL_READY) {
        item->sidebar_client->state = state;
        set_surface_busy(item, &item->sidebar_presentation, false);
      }
    }
  }
  if (project->sidebar)
    window->ui_dirty = true;
  if (project->sidebar && (state == SHELL_STARTING || state == SHELL_FAILED))
    set_surface_busy(window, &window->sidebar_presentation, false);
  if (state != SHELL_STARTING && project->startup_timer) {
    KillTimer(project->sidebar ? shell.service_hwnd : window->hwnd, project->startup_timer);
    project->startup_timer = 0;
  }
  if (project == window->selected) {
    window->ui_dirty = true;
    if (state == SHELL_STARTING || state == SHELL_FAILED)
      set_surface_busy(window, &window->project_presentation, false);
  }
  static const char *names[] = {"Starting", "Ready", "Closing", "Failed", "Dormant"};
  if (project->sidebar && project != shell.sidebar_process)
    SDL_Log("Shell Sidebar surface state: Window=%u %s connection=%u", window->id, names[state], project->connection);
  else SDL_Log("Shell state: %s Project=%u connection=%u", names[state], project->id,
               project->connection);
}

static void controls_geometry(ShellWindow *window) {
  int width = SDL_min(SDL_max(1, window->buffer_w - window->sidebar_w), (int)(138 * window->scale));
  int height = SDL_min(window->buffer_h, SDL_max(1, (int)(32 * window->scale)));
  RECT rect = {window->buffer_w - width, 0, window->buffer_w, height};
  if (memcmp(&rect, &window->controls, sizeof(rect))) {
    window->controls = rect;
    window->ui_dirty = true;
    SDL_Log("Shell controls: x=%ld y=%ld w=%ld h=%ld sidebar=%d", rect.left, rect.top,
            rect.right - rect.left, rect.bottom - rect.top, window->sidebar_w);
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
      (size_t)exe_len * 2 + strlen(pipe_arg) * 2 +
      (project->project_path ? strlen(project->project_path) * 2 : 0) + 128;
  for (int i = 2; i < argc; i++) capacity += strlen(argv[i]) * 2 + 4;
  char *exe_utf8 = malloc((size_t)exe_len);
  char *line = malloc(capacity);
  wchar_t *wide = NULL;
  if (exe_utf8 && line) {
    WideCharToMultiByte(CP_UTF8, 0, exe, -1, exe_utf8, exe_len, NULL, NULL);
    size_t n = append_quoted_arg(line, exe_utf8);
    if (!project->sidebar) {
      line[n++] = ' '; n += append_quoted_arg(line + n, ANVIL_PROJECT_ARG);
      line[n++] = ' ';
      n += append_quoted_arg(line + n, project->project_path);
    }
    line[n++] = ' ';
    n += append_quoted_arg(line + n, pipe_arg);
    if (project->sidebar) {
      line[n++] = ' ';
      n += append_quoted_arg(line + n, "--internal-sidebar");
    }
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
  DWORD adopt_pid;
  uint64_t adopt_created;
  char pipe_name[128];
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
  if (launch->adopt_pid) {
    DWORD pid = launch->adopt_pid;
    AnvilAdoptionRecord record = {.pid = pid, .created = launch->adopt_created};
    HANDLE process = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE, FALSE, pid);
    if (process && anvil_adoption_request(&record, launch->pipe_name, SHELL_ADOPTION_REQUEST_MS)) {
      launch->process = (PROCESS_INFORMATION){.hProcess = process, .dwProcessId = pid};
      SDL_Log("Shell foreground grant to Project pid=%lu allowed=%d", (unsigned long)pid,
              AllowSetForegroundWindow(pid) != 0);
      SDL_Log("Shell adopted Project pid=%lu path=%s", (unsigned long)pid, project->project_path);
      goto launched;
    }
    /* Never two runtimes for one Project. The Project saved when it lost its shell. */
    if (process && WaitForSingleObject(process, 0) == WAIT_TIMEOUT) {
      TerminateProcess(process, 1);
      WaitForSingleObject(process, 2000);
      SDL_Log("Shell ended a Project that did not accept adoption: pid=%lu", (unsigned long)pid);
    }
    if (process) CloseHandle(process);
    SDL_Log("Shell starts a new runtime instead of adopting pid=%lu", (unsigned long)pid);
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
            project->project_path ? project->project_path : "Sidebar (no Project)");
  }
launched:
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
  /* Adoption is tried once. A later restart creates a process. */
  launch->adopt_pid = project->adopt_pid;
  launch->adopt_created = project->adopt_created;
  project->adopt_pid = 0;
  SDL_strlcpy(launch->pipe_name, pipe_name, sizeof(launch->pipe_name));
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
  case ANVIL_SURFACE_MSG_SIDEBAR_SURFACE: {
    if (size < sizeof(AnvilSidebarSurfacePacket)) return false;
    const AnvilSidebarSurfacePacket *packet = payload;
    if (!packet->window_id || packet->type == ANVIL_SURFACE_MSG_SIDEBAR_SURFACE) return false;
    switch (packet->type) {
    case ANVIL_SURFACE_MSG_FRAME: case ANVIL_SURFACE_MSG_CURSOR: case ANVIL_SURFACE_MSG_HIT_TEST:
    case ANVIL_SURFACE_MSG_SELECT_PROJECT: case ANVIL_SURFACE_MSG_UNLOAD_PROJECT:
    case ANVIL_SURFACE_MSG_MOVE_PROJECT:
    case ANVIL_SURFACE_MSG_SIDEBAR_QUERY: case ANVIL_SURFACE_MSG_SIDEBAR_REFRESH:
    case ANVIL_SURFACE_MSG_TEXT_INPUT: case ANVIL_SURFACE_MSG_TITLE:
    case ANVIL_SURFACE_MSG_VISIBLE: case ANVIL_SURFACE_MSG_SET_BOUNDS: case ANVIL_SURFACE_MSG_BORDERED:
      return valid_project_message(packet->type, packet + 1, size - sizeof(*packet));
    default: return false;
    }
  }
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
  case ANVIL_SURFACE_MSG_NEW_WINDOW:
  case ANVIL_SURFACE_MSG_OPEN_PROJECT_PICKER:
    return size == sizeof(uint32_t) && *(const uint32_t *)payload != 0;
  case ANVIL_SURFACE_MSG_MOVE_PROJECT:
    return size == sizeof(AnvilSurfaceMoveProject) && ((const AnvilSurfaceMoveProject *)payload)->project_id &&
           ((const AnvilSurfaceMoveProject *)payload)->target_window_id;
  case ANVIL_SURFACE_MSG_OPEN_PROJECT_WINDOW:
    return size > sizeof(uint32_t) + 1 && size < 32768 && *(const uint32_t *)payload &&
           ((const char *)payload)[size - 1] == 0 &&
           !memchr((const char *)payload + sizeof(uint32_t), 0, size - sizeof(uint32_t) - 1);
  case ANVIL_SURFACE_MSG_SIDEBAR_QUERY:
    return size == sizeof(AnvilSurfaceInt) && ((const AnvilSurfaceInt *)payload)->value >= 0 &&
           ((const AnvilSurfaceInt *)payload)->value <=
               ANVIL_SIDEBAR_PROJECT_LIMIT * (ANVIL_SIDEBAR_TERMINAL_LIMIT + 1);
  case ANVIL_SURFACE_MSG_SIDEBAR_SOURCE: {
    if (size < sizeof(AnvilSurfaceSidebarSource) + 4)
      return false;
    uint32_t directory_size = ((const AnvilSurfaceSidebarSource *)payload)->userdir_size;
    const char *text = (const char *)payload + sizeof(AnvilSurfaceSidebarSource);
    uint32_t bytes = size - sizeof(AnvilSurfaceSidebarSource);
    return directory_size > 1 && directory_size < 32768 && directory_size < bytes - 1 &&
           !text[directory_size - 1] && !memchr(text, 0, directory_size - 1) && !text[bytes - 1] &&
           !memchr(text + directory_size, 0, bytes - directory_size - 1);
  }
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
  case ANVIL_SURFACE_MSG_SIDEBAR_REFRESH:
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
      if (!valid_project_message(header.type, payload, header.size) ||
          (header.type == ANVIL_SURFACE_MSG_SIDEBAR_SURFACE && !project->sidebar)) {
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
  uint32_t window_id = project->window_id;
  uint32_t prefix = project->sidebar && project != shell.sidebar_process ? sizeof(AnvilSidebarSurfacePacket) : 0;
  uint16_t inner_type = type;
  if (prefix) {
    project = shell.sidebar_process;
    if (!project) return;
    type = ANVIL_SURFACE_MSG_SIDEBAR_SURFACE;
  }
  if (!project->connected)
    return;
  uint32_t total = size + tail_size + prefix;
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
  if (prefix) *(AnvilSidebarSurfacePacket *)message->payload = (AnvilSidebarSurfacePacket){window_id, inner_type};
  if (size) memcpy(message->payload + prefix, payload, size);
  if (tail_size) memcpy(message->payload + prefix + size, tail, tail_size);

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

static void update_scale(ShellWindow *window) {
  float scale = SDL_GetWindowDisplayScale(window->window);
  window->scale = scale > 0 ? scale : 1.0f;
  window->sidebar_w = window->sidebar ? (int)(SHELL_SIDEBAR_POINTS * window->scale + 0.5f) : 0;
}

static AnvilSurfaceWindowMode current_window_mode(ShellWindow *window) {
  SDL_WindowFlags flags = SDL_GetWindowFlags(window->window);
  if (flags & SDL_WINDOW_FULLSCREEN) return ANVIL_SURFACE_WINDOW_FULLSCREEN;
  if (flags & SDL_WINDOW_MINIMIZED) return ANVIL_SURFACE_WINDOW_MINIMIZED;
  if (flags & SDL_WINDOW_MAXIMIZED) return ANVIL_SURFACE_WINDOW_MAXIMIZED;
  return ANVIL_SURFACE_WINDOW_NORMAL;
}

static float current_refresh_rate(ShellWindow *window) {
  SDL_DisplayID display = SDL_GetDisplayForWindow(window->window);
  const SDL_DisplayMode *mode = display ? SDL_GetCurrentDisplayMode(display) : NULL;
  if (!mode || mode->refresh_rate <= 0) mode = display ? SDL_GetDesktopDisplayMode(display) : NULL;
  return mode && mode->refresh_rate > 0 ? mode->refresh_rate : 0.0f;
}

/* Inside the Win32 sizing loop SDL's cached size can trail the real client
 * rect by one message, so read the HWND directly. */
static void client_pixel_size(ShellWindow *window, int *width, int *height) {
  RECT rect = { 0 };
  GetClientRect(window->hwnd, &rect);
  *width = (int)(rect.right - rect.left);
  *height = (int)(rect.bottom - rect.top);
}

static void send_configure(ShellProject *project) {
  ShellWindow *window = window_for_id(project->window_id);
  if (!window) return;
  if (window->sidebar_client && project == window->selected && shell.sidebar_process)
    send_configure(window->sidebar_client);
  if (!project->connected)
    return;
  AnvilSurfaceConfigure config = project->last_config;
  config.window_id = window->id;
  config.window_mode = current_window_mode(window);
  config.live_resize = window->live_resize;
  config.render_enabled = (project == window->selected || project->sidebar) &&
                          IsWindowVisible(window->hwnd) && !IsIconic(window->hwnd);
  if (config.window_mode != ANVIL_SURFACE_WINDOW_MINIMIZED) {
    /* A minimized window keeps the last surface size. */
    int pixel_w = 0, pixel_h = 0;
    client_pixel_size(window, &pixel_w, &pixel_h);
    config.pixel_w = SDL_max(1, project->sidebar ? window->sidebar_w : pixel_w);
    config.pixel_h = SDL_max(1, pixel_h);
    RECT rect;
    if (GetWindowRect(window->hwnd, &rect)) {
      config.window_x = rect.left;
      config.window_y = rect.top;
      config.window_w = rect.right - rect.left;
      config.window_h = rect.bottom - rect.top;
    }
  } else if (project->last_config.window_id != window->id) {
    /* A newly assigned surface has no prior geometry in this minimized Window. */
    config.pixel_w = SDL_max(1, project->sidebar ? window->sidebar_w : window->buffer_w);
    config.pixel_h = SDL_max(1, window->buffer_h);
  }
  config.display_scale = window->scale;
  config.origin_x = 0;
  config.origin_y = 0;
  config.content_x = project->sidebar ? 0 : SDL_min(window->sidebar_w, SDL_max(0, config.pixel_w - 1));
  config.refresh_hz = current_refresh_rate(window);
  typedef UINT(WINAPI * DpiForWindow)(HWND);
  typedef int(WINAPI * MetricForDpi)(int, UINT);
  HMODULE user32 = GetModuleHandleW(L"user32.dll");
  DpiForWindow dpi_for_window = (DpiForWindow)GetProcAddress(user32, "GetDpiForWindow");
  MetricForDpi metric = (MetricForDpi)GetProcAddress(user32, "GetSystemMetricsForDpi");
  UINT dpi = dpi_for_window ? dpi_for_window(window->hwnd) : 96;
  config.button_width = metric ? metric(SM_CXSIZE, dpi) : GetSystemMetrics(SM_CXSIZE);
  config.title_height = metric ? metric(SM_CYSIZE, dpi) : GetSystemMetrics(SM_CYSIZE);
  config.resize_border =
      metric ? metric(SM_CXSIZEFRAME, dpi) + metric(SM_CXPADDEDBORDER, dpi)
             : GetSystemMetrics(SM_CXSIZEFRAME) + GetSystemMetrics(SM_CXPADDEDBORDER);
  controls_geometry(window);
  config.controls_x = SDL_max(0, window->controls.left);
  config.controls_y = 0;
  config.controls_w = window->controls.right - window->controls.left;
  config.controls_h = window->controls.bottom;
  if (project->sidebar && config.render_enabled != project->last_config.render_enabled)
    SDL_Log("Shell Sidebar rendering enabled=%u Window=%u", config.render_enabled, window->id);
  if (project->sidebar)
    config.controls_x = config.controls_y = config.controls_w = config.controls_h = 0;
  if (memcmp(&config, &project->last_config, sizeof(config)) == 0 && project->last_config.pixel_w)
    return;
  if (!config.configuration || anvil_surface_layout_changed(&project->last_config, &config)) {
    config.configuration++;
    if (project == window->selected)
      SDL_ClearComposition(window->window);
    project->hit = (AnvilSurfaceHitTest){0};
  }
  project->last_config = config;
  if (!config.render_enabled && project == window->selected)
    set_surface_busy(window, &window->project_presentation, false);
  if (!config.render_enabled && project->sidebar)
    set_surface_busy(window, &window->sidebar_presentation, false);
  shell_send(project, ANVIL_SURFACE_MSG_CONFIGURE, &config, sizeof(config), NULL, 0);
}

/* ------------------------------------------------------------------------ */
/* Rendering                                                                */

static bool create_backbuffer_view(ShellWindow *window) {
  HRESULT hr = window->swapchain->lpVtbl->GetBuffer(window->swapchain, 0, &IID_ID3D11Texture2D,
                                                  (void **)&window->backbuffer);
  if (SUCCEEDED(hr)) {
    hr = window->device->lpVtbl->CreateRenderTargetView(window->device, (ID3D11Resource *)window->backbuffer,
                                                      NULL, &window->rtv);
  }
  return SUCCEEDED(hr);
}

static bool init_d3d11(ShellWindow *window) {
  D3D_FEATURE_LEVEL levels[] = {
    D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0,
  };
  UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
  HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, flags, levels,
                                 (UINT)SDL_arraysize(levels), D3D11_SDK_VERSION,
                                 &window->device, NULL, &window->context);
  if (FAILED(hr)) {
    hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_WARP, NULL, flags, levels,
                           (UINT)SDL_arraysize(levels), D3D11_SDK_VERSION,
                           &window->device, NULL, &window->context);
  }
  if (FAILED(hr)) return false;
  hr = window->device->lpVtbl->QueryInterface(window->device, &IID_ID3D11Device1, (void **)&window->device1);
  if (FAILED(hr)) return false;

  IDXGIDevice1 *dxgi_device = NULL;
  IDXGIAdapter *adapter = NULL;
  IDXGIFactory2 *factory = NULL;
  hr = window->device->lpVtbl->QueryInterface(window->device, &IID_IDXGIDevice1, (void **)&dxgi_device);
  if (SUCCEEDED(hr)) {
    dxgi_device->lpVtbl->SetMaximumFrameLatency(dxgi_device, 2);
    hr = dxgi_device->lpVtbl->GetAdapter(dxgi_device, &adapter);
  }
  if (SUCCEEDED(hr)) hr = adapter->lpVtbl->GetParent(adapter, &IID_IDXGIFactory2, (void **)&factory);

  HWND hwnd = window->hwnd;
  int pixel_w = 0, pixel_h = 0;
  client_pixel_size(window, &pixel_w, &pixel_h);
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
    hr = factory->lpVtbl->CreateSwapChainForHwnd(factory, (IUnknown *)window->device, hwnd, &desc,
                                                 NULL, NULL, &window->swapchain);
    if (SUCCEEDED(hr)) {
      factory->lpVtbl->MakeWindowAssociation(factory, hwnd, DXGI_MWA_NO_ALT_ENTER);
      apply_swapchain_background(window);
    }
    window->buffer_w = (int)desc.Width;
    window->buffer_h = (int)desc.Height;
  } else if (SUCCEEDED(hr)) {
    hr = E_FAIL;
  }
  SAFE_RELEASE(factory);
  SAFE_RELEASE(adapter);
  SAFE_RELEASE(dxgi_device);
  return SUCCEEDED(hr) && create_backbuffer_view(window);
}

static void release_d3d11(ShellWindow *window) {
  if (window->context)
    window->context->lpVtbl->ClearState(window->context);
  SAFE_RELEASE(window->project_presentation.shared_mutex);
  SAFE_RELEASE(window->project_presentation.shared);
  SAFE_RELEASE(window->project_presentation.surface);
  SAFE_RELEASE(window->ui_view);
  SAFE_RELEASE(window->ui);
  SAFE_RELEASE(window->compose_vs);
  SAFE_RELEASE(window->compose_ps);
  SAFE_RELEASE(window->compose_constants);
  SAFE_RELEASE(window->compose_blend);
  SAFE_RELEASE(window->compose_raster);
  window->compose_failed = false;
  SAFE_RELEASE(window->project_presentation.view);
  SAFE_RELEASE(window->sidebar_presentation.view);
  window->project_presentation.view_texture = window->sidebar_presentation.view_texture = NULL;
  SAFE_RELEASE(window->rtv);
  SAFE_RELEASE(window->backbuffer);
  SAFE_RELEASE(window->swapchain);
  SAFE_RELEASE(window->context);
  SAFE_RELEASE(window->device1);
  SAFE_RELEASE(window->device);
  close_memory_frame(&window->project_presentation);
  window->project_presentation.have_surface = false;
  window->project_presentation.shared_name[0] = 0;
  SAFE_RELEASE(window->sidebar_presentation.shared_mutex);
  SAFE_RELEASE(window->sidebar_presentation.shared);
  SAFE_RELEASE(window->sidebar_presentation.surface);
  close_memory_frame(&window->sidebar_presentation);
  window->sidebar_presentation.have_surface = false;
  window->project_presentation.busy = window->sidebar_presentation.busy = false;
  set_frame_busy(window, false);
}

static void fail_gpu(ShellWindow *window, const char *operation, HRESULT error) {
  ShellProject *project = window->selected;
  if (window->render_failed)
    return;
  window->render_failed = true;
  SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
               "Shell GPU failure: %s HRESULT=0x%08lx; native OS actions remain available",
               operation, (unsigned long)error);
  /* Native paint and resize can run inside SDL's event pump. Finish SDL
   * cleanup in the main callback, not inside a nested window procedure. */
  window->gpu_failure = operation;
  SDL_Event event = {0};
  event.type = shell.event_type;
  event.user.code = SHELL_EVENT_FRAME;
  event.user.windowID = project->connection;
  SDL_PushEvent(&event);
  InvalidateRect(window->hwnd, NULL, FALSE);
}

static void check_gpu_failure(ShellWindow *window) {
  ShellProject *project = window->selected;
  if (!window->gpu_failure)
    return;
  const char *cause = window->gpu_failure;
  window->gpu_failure = NULL;
  release_d3d11(window);
  fail_connection(project, cause);
}

static void resize_buffers(ShellWindow *window) {
  int pixel_w = 0, pixel_h = 0;
  client_pixel_size(window, &pixel_w, &pixel_h);
  if (pixel_w <= 0 || pixel_h <= 0) return;
  if (pixel_w == window->buffer_w && pixel_h == window->buffer_h) return;
  if (window->render_failed) { window->buffer_w = pixel_w; window->buffer_h = pixel_h; return; }
  window->context->lpVtbl->OMSetRenderTargets(window->context, 0, NULL, NULL);
  SAFE_RELEASE(window->rtv);
  SAFE_RELEASE(window->backbuffer);
  HRESULT hr = window->swapchain->lpVtbl->ResizeBuffers(window->swapchain, 0, (UINT)pixel_w, (UINT)pixel_h,
                                                      DXGI_FORMAT_UNKNOWN, 0);
  if (take_fault(FAULT_RESIZE)) hr = DXGI_ERROR_DEVICE_REMOVED;
  if (FAILED(hr) || !create_backbuffer_view(window)) {
    fail_gpu(window, "swapchain resize failed", FAILED(hr) ? hr : E_FAIL);
    return;
  }
  window->buffer_w = pixel_w;
  window->buffer_h = pixel_h;
}

/* Grows the private texture with slack, so a live resize reuses it. The last frame survives growth, so a
 * stale step can still show it. The caller sets surface_w and surface_h after it copies a frame. */
static bool ensure_surface_texture(ShellWindow *window, ShellPresentation *surface, int width, int height) {
  if (surface->surface && width <= surface->texture_w && height <= surface->texture_h)
    return true;
  int capacity_w = width + width / 4, capacity_h = height + height / 4;
  ID3D11Texture2D *previous = surface->surface;
  surface->surface = NULL;
  D3D11_TEXTURE2D_DESC desc;
  ZeroMemory(&desc, sizeof(desc));
  desc.Width = (UINT)capacity_w;
  desc.Height = (UINT)capacity_h;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
  HRESULT hr = window->device->lpVtbl->CreateTexture2D(window->device, &desc, NULL, &surface->surface);
  if (FAILED(hr)) {
    SDL_Log("Shell private surface creation failed: 0x%08lx", (unsigned long)hr);
    SAFE_RELEASE(previous);
    surface->have_surface = false;
    surface->texture_w = surface->texture_h = 0;
    return false;
  }
  if (previous && surface->have_surface) {
    D3D11_BOX box = {0, 0, 0, (UINT)surface->surface_w, (UINT)surface->surface_h, 1};
    window->context->lpVtbl->CopySubresourceRegion(window->context, (ID3D11Resource *)surface->surface, 0, 0, 0,
                                                 0, (ID3D11Resource *)previous, 0, &box);
  }
  SAFE_RELEASE(previous);
  surface->texture_w = capacity_w;
  surface->texture_h = capacity_h;
  return true;
}

static bool load_d3d11_frame(ShellProject *project, ShellPresentation *surface,
                             const AnvilSurfaceFrame *frame) {
  ShellWindow *window = window_for_id(project->window_id);
  if (!window) return false;
  if (strcmp(frame->name, surface->shared_name) != 0 || !surface->shared) {
    SAFE_RELEASE(surface->shared_mutex);
    SAFE_RELEASE(surface->shared);
    surface->shared_name[0] = '\0';
    wchar_t name[ANVIL_SURFACE_NAME_MAX];
    MultiByteToWideChar(CP_UTF8, 0, frame->name, -1, name, ANVIL_SURFACE_NAME_MAX);
    HRESULT hr =
        take_fault(FAULT_OPEN)
            ? E_ACCESSDENIED
            : window->device1->lpVtbl->OpenSharedResourceByName(
                  window->device1, name, DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE,
                  &IID_ID3D11Texture2D, (void **)&surface->shared);
    if (SUCCEEDED(hr)) {
      hr = surface->shared->lpVtbl->QueryInterface(surface->shared, &IID_IDXGIKeyedMutex,
                                                   (void **)&surface->shared_mutex);
    }
    if (FAILED(hr)) {
      SDL_Log("Anvil shell could not open surface %s: 0x%08lx", frame->name, (unsigned long)hr);
      SAFE_RELEASE(surface->shared);
      return false;
    }
    SDL_strlcpy(surface->shared_name, frame->name, sizeof(surface->shared_name));
  }
  D3D11_TEXTURE2D_DESC desc;
  surface->shared->lpVtbl->GetDesc(surface->shared, &desc);
  if (desc.Width < (UINT)frame->width || desc.Height < (UINT)frame->height ||
      desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM) return false;
  if (!ensure_surface_texture(window, surface, frame->width, frame->height))
    return false;
  HRESULT acquired = take_fault(FAULT_ACQUIRE) ? WAIT_ABANDONED
                     : SDL_GetAtomicInt(&probe_fault) == FAULT_BUSY
                         ? WAIT_TIMEOUT
                         : surface->shared_mutex->lpVtbl->AcquireSync(surface->shared_mutex, 0,
                                                                      SHELL_SYNC_TIMEOUT_MS);
  if (acquired != S_OK) {
    if (acquired == WAIT_TIMEOUT || acquired == DXGI_ERROR_WAIT_TIMEOUT)
      surface->busy = true;
    else {
      SDL_Log("Shell shared mutex failed: 0x%08lx", (unsigned long)acquired);
      fail_connection(project, "shared surface mutex failed");
    }
    return false;
  }
  D3D11_BOX box = {0, 0, 0, (UINT)frame->width, (UINT)frame->height, 1};
  window->context->lpVtbl->CopySubresourceRegion(window->context, (ID3D11Resource *)surface->surface, 0, 0, 0, 0,
                                               (ID3D11Resource *)surface->shared, 0, &box);
  surface->surface_w = frame->width;
  surface->surface_h = frame->height;
  HRESULT released = surface->shared_mutex->lpVtbl->ReleaseSync(surface->shared_mutex, 0);
  if (take_fault(FAULT_RELEASE)) released = E_FAIL;
  if (released != S_OK) {
    fail_gpu(window, "surface mutex release failed", released);
    return false;
  }
  return true;
}

static void close_memory_frame(ShellPresentation *surface) {
  if (surface->memory_view)
    UnmapViewOfFile(surface->memory_view);
  if (surface->memory_mapping)
    CloseHandle(surface->memory_mapping);
  if (surface->memory_mutex)
    CloseHandle(surface->memory_mutex);
  surface->memory_view = NULL;
  surface->memory_mapping = NULL;
  surface->memory_mutex = NULL;
  surface->memory_size = 0;
  surface->memory_name[0] = '\0';
}

static bool load_memory_frame(ShellProject *project, ShellPresentation *surface,
                              const AnvilSurfaceFrame *frame) {
  ShellWindow *window = window_for_id(project->window_id);
  if (!window) return false;
  if (strcmp(frame->name, surface->memory_name) != 0 || !surface->memory_view) {
    close_memory_frame(surface);
    char lock_name[ANVIL_SURFACE_NAME_MAX + 8];
    snprintf(lock_name, sizeof(lock_name), "%s%s", frame->name, ANVIL_SURFACE_LOCK_SUFFIX);
    surface->memory_mapping =
        take_fault(FAULT_OPEN) ? NULL : OpenFileMappingA(FILE_MAP_READ, FALSE, frame->name);
    surface->memory_mutex = OpenMutexA(SYNCHRONIZE | MUTEX_MODIFY_STATE, FALSE, lock_name);
    if (surface->memory_mapping) {
      surface->memory_view = MapViewOfFile(surface->memory_mapping, FILE_MAP_READ, 0, 0, 0);
    }
    MEMORY_BASIC_INFORMATION info;
    if (!surface->memory_view || !surface->memory_mutex ||
        !VirtualQuery(surface->memory_view, &info, sizeof(info))) {
      SDL_Log("Anvil shell could not open surface memory %s", frame->name);
      close_memory_frame(surface);
      return false;
    }
    surface->memory_size = info.RegionSize;
    SDL_strlcpy(surface->memory_name, frame->name, sizeof(surface->memory_name));
  }
  DWORD wait = take_fault(FAULT_ACQUIRE) ? WAIT_FAILED
               : SDL_GetAtomicInt(&probe_fault) == FAULT_BUSY
                   ? WAIT_TIMEOUT
                   : WaitForSingleObject(surface->memory_mutex, SHELL_SYNC_TIMEOUT_MS);
  if (wait != WAIT_OBJECT_0) {
    if (wait == WAIT_TIMEOUT)
      surface->busy = true;
    else {
      if (wait == WAIT_ABANDONED)
        ReleaseMutex(surface->memory_mutex);
      fail_connection(project, "shared memory mutex failed");
    }
    return false;
  }
  const AnvilSurfaceMemoryHeader *header = (const AnvilSurfaceMemoryHeader *)surface->memory_view;
  bool ok =
      header->width == frame->width && header->height == frame->height &&
      header->configuration == frame->configuration && header->generation >= frame->generation &&
      header->width > 0 && header->height > 0 && header->stride >= header->width * 4 &&
      sizeof(*header) + (size_t)header->stride * (size_t)header->height <= surface->memory_size &&
      ensure_surface_texture(window, surface, header->width, header->height);
  if (ok) {
    D3D11_BOX box = {0, 0, 0, (UINT)header->width, (UINT)header->height, 1};
    window->context->lpVtbl->UpdateSubresource(window->context, (ID3D11Resource *)surface->surface, 0,
                                             &box, surface->memory_view + sizeof(*header),
                                             (UINT)header->stride, 0);
    surface->surface_w = header->width;
    surface->surface_h = header->height;
  }
  BOOL released = ReleaseMutex(surface->memory_mutex);
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

static void draw_lifecycle(ShellWindow *window, HDC dc) {
  ShellProject *project = window->selected;
  window->restart_button = (RECT){0};
  window->close_button = (RECT){0};
  if (window->notice[0]) {
    RECT notice = {window->sidebar_w, window->controls.bottom, window->buffer_w,
                   window->controls.bottom + (LONG)(48 * window->scale)};
    DrawTextA(dc, window->notice, -1, &notice, DT_CENTER | DT_TOP | DT_WORDBREAK);
  }
  if (!project->id && !project->project_path) {
    RECT area = {window->sidebar_w, window->controls.bottom, window->buffer_w, window->buffer_h};
    DrawTextW(dc, L"No Project selected", -1, &area, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    area.top = (area.top + area.bottom) / 2 + (int)(24 * window->scale);
    DrawTextW(dc, window->sidebar
                  ? L"Right-click the Title Bar to open a Project or create a Window.\n"
                    L"You can also select a Project in the Sidebar."
                  : L"Right-click the Title Bar to open a Project or create a Window.", -1,
              &area, DT_CENTER | DT_TOP | DT_WORDBREAK);
    return;
  }
  if (project->state != SHELL_STARTING && project->state != SHELL_FAILED &&
      project->state != SHELL_DORMANT)
    return;
  RECT area = {window->sidebar_w, window->controls.bottom, window->buffer_w, window->buffer_h};
  DrawTextW(dc,
            project->state == SHELL_STARTING  ? L"Starting Project..."
            : project->state == SHELL_DORMANT ? L"Project is Dormant"
                                              : L"Project failed",
            -1, &area, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  if (project->state != SHELL_FAILED && project->state != SHELL_DORMANT)
    return;
  int x = (area.left + area.right) / 2, y = (area.top + area.bottom) / 2 + (int)(30 * window->scale);
  window->failure_card = (RECT){SDL_max(area.left, x - (int)(180 * window->scale)),
                              SDL_max(area.top, y - (int)(90 * window->scale)),
                              SDL_min(area.right, x + (int)(180 * window->scale)),
                              SDL_min(area.bottom, y + (int)(50 * window->scale))};
  int w = (int)(140 * window->scale), h = (int)(32 * window->scale), gap = (int)(8 * window->scale);
  window->restart_button = (RECT){x - w - gap, y, x - gap, y + h};
  window->close_button = (RECT){x + gap, y, x + w + gap, y + h};
  ui_fill(dc, window->restart_button, RGB(55, 55, 62));
  ui_fill(dc, window->close_button, RGB(55, 55, 62));
  DrawTextW(dc, project->state == SHELL_DORMANT ? L"Load Project" : L"Restart Project", -1,
            &window->restart_button, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  DrawTextW(dc, project->state == SHELL_DORMANT ? L"Close Window" : L"Unload Project", -1,
            &window->close_button, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
}

static void paint_failed_window(ShellWindow *window, HDC dc) {
  client_pixel_size(window, &window->buffer_w, &window->buffer_h);
  controls_geometry(window);
  RECT client = {0, 0, window->buffer_w, window->buffer_h};
  ui_fill(dc, client, window->background & 0xffffff);
  SetBkMode(dc, TRANSPARENT);
  SetTextColor(dc, RGB(220, 220, 225));
  HGDIOBJ old = SelectObject(dc, GetStockObject(DEFAULT_GUI_FONT));
  draw_lifecycle(window, dc);
  const wchar_t *labels[] = {L"−", L"□", L"×"};
  int width = (window->controls.right - window->controls.left) / 3;
  for (int i = 0; i < 3; i++) {
    RECT button = {window->controls.left + i * width, 0,
                   i == 2 ? window->controls.right : window->controls.left + (i + 1) * width,
                   window->controls.bottom};
    DrawTextW(dc, labels[i], -1, &button, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  }
  SelectObject(dc, old);
}

/* The native strip above the Sidebar restarts it only while it has failed. Otherwise it drags the Window. */
static bool sidebar_restart_offered(void) {
  return shell.sidebar_restart_limited || !shell.sidebar_process || shell.sidebar_process->state == SHELL_FAILED;
}

static void update_ui(ShellWindow *window) {
  ShellProject *project = window->selected;
  controls_geometry(window);
  if (!window->ui_dirty && !window->ui_hover_dirty && window->ui && window->ui_layout_w == window->buffer_w &&
      window->ui_layout_h == window->buffer_h)
    return;
  if (window->buffer_w <= 0 || window->buffer_h <= 0)
    return;
  if (window->ui_layout_w != window->buffer_w || window->ui_layout_h != window->buffer_h) {
    window->ui_layout_w = window->buffer_w;
    window->ui_layout_h = window->buffer_h;
    window->ui_dirty = true;
  }
  /* The layer grows with slack, so a live resize repaints it without reallocating. */
  if (!window->ui || window->ui_w < window->buffer_w || window->ui_h < window->buffer_h) {
    int capacity_w = window->buffer_w + window->buffer_w / 4, capacity_h = window->buffer_h + window->buffer_h / 4;
    SAFE_RELEASE(window->ui);
    if (window->ui_dc) {
      SelectObject(window->ui_dc, window->ui_old_bitmap);
      DeleteObject(window->ui_bitmap);
      DeleteDC(window->ui_dc);
    }
    window->ui_dc = CreateCompatibleDC(NULL);
    BITMAPINFO info = {0};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = capacity_w;
    info.bmiHeader.biHeight = -capacity_h;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    window->ui_bitmap =
        CreateDIBSection(window->ui_dc, &info, DIB_RGB_COLORS, &window->ui_pixels, NULL, 0);
    if (!window->ui_dc || !window->ui_bitmap)
      return;
    window->ui_old_bitmap = SelectObject(window->ui_dc, window->ui_bitmap);
    D3D11_TEXTURE2D_DESC desc = {0};
    desc.Width = capacity_w;
    desc.Height = capacity_h;
    desc.MipLevels = 1;
    desc.ArraySize = 1;
    desc.SampleDesc.Count = 1;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    SAFE_RELEASE(window->ui_view);
    HRESULT hr = window->device->lpVtbl->CreateTexture2D(window->device, &desc, NULL, &window->ui);
    if (SUCCEEDED(hr))
      hr = window->device->lpVtbl->CreateShaderResourceView(window->device, (ID3D11Resource *)window->ui, NULL,
                                                            &window->ui_view);
    if (FAILED(hr)) {
      fail_gpu(window, "native UI texture creation failed", hr);
      return;
    }
    window->ui_w = capacity_w;
    window->ui_h = capacity_h;
    window->ui_dirty = true;
  }
  HDC dc = window->ui_dc;
  RECT all = {0, 0, window->buffer_w, window->buffer_h};
  RECT dirty[] = {{0, 0, window->sidebar_w, window->buffer_h}, window->controls, window->failure_card};
  bool full = window->ui_dirty;
  int dirty_count = (project->state == SHELL_FAILED || project->state == SHELL_DORMANT) ? 3 : 2;
  /* The composite reads the full Project area only while no Project frame covers it, and the notice strip. */
  bool cover = project->state == SHELL_STARTING || project->state == SHELL_DORMANT ||
               (project->state == SHELL_FAILED && !window->project_presentation.have_surface);
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
  ui_fill(dc, all, window->background & 0xffffff);
  RECT strip = {0, 0, window->sidebar_w, window->controls.bottom};
  ui_fill(dc, strip, 0);
  ui_fill(dc, window->controls, 0);
  HFONT font = CreateFontW(-(int)(13 * window->scale), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                           DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                           ANTIALIASED_QUALITY, DEFAULT_PITCH, L"Segoe UI");
  HGDIOBJ old_font = SelectObject(dc, font);
  SetBkMode(dc, TRANSPARENT);
  SetTextColor(dc, RGB(220, 220, 225));
  if (sidebar_restart_offered())
    DrawTextW(dc, L"Restart Sidebar", -1, &strip, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  RECT status = {0, window->buffer_h - (LONG)(40 * window->scale), window->sidebar_w, window->buffer_h};
  DrawTextW(dc,
            shell.sidebar_process && shell.sidebar_process->state == SHELL_FAILED
                ? L"Sidebar failed"
            : project->state == SHELL_FAILED  ? L"!"
            : project->state == SHELL_CLOSING ? L"..."
                                              : L"\x2022",
            -1, &status, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  int bw = (window->controls.right - window->controls.left) / 3;
  HPEN pen = CreatePen(PS_SOLID, SDL_max(1, (int)window->scale), RGB(220, 220, 225));
  HGDIOBJ old_pen = SelectObject(dc, pen);
  for (int i = 0; i < 3; i++) {
    RECT rect = {window->controls.left + i * bw, 0,
                 i == 2 ? window->controls.right : window->controls.left + (i + 1) * bw,
                 window->controls.bottom};
    if (window->hovered_control == i || window->pressed_control == i)
      ui_fill(dc, rect, i == 2 ? RGB(190, 45, 45) : RGB(55, 55, 62));
    int x = (rect.left + rect.right) / 2, y = rect.bottom / 2,
        r = SDL_max(3, (int)(5 * window->scale));
    if (i == 0) {
      MoveToEx(dc, x - r, y + 2, NULL);
      LineTo(dc, x + r, y + 2);
    } else if (i == 1) {
      HGDIOBJ brush = SelectObject(dc, GetStockObject(NULL_BRUSH));
      if (current_window_mode(window) == ANVIL_SURFACE_WINDOW_MAXIMIZED)
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
  draw_lifecycle(window, dc);
  GdiFlush();
  /* Blended regions take premultiplied alpha from their brightest channel. Other regions are copied. */
  RECT blended[] = {strip, window->controls};
  for (int i = 0; i < 2; i++) {
    RECT rect = blended[i];
    for (int y = SDL_max(0, rect.top); y < SDL_min(rect.bottom, window->buffer_h); y++) {
      uint8_t *row = (uint8_t *)window->ui_pixels + (size_t)y * window->ui_w * 4;
      for (int x = SDL_max(0, rect.left); x < SDL_min(rect.right, window->buffer_w); x++) {
        uint8_t *pixel = row + x * 4;
        pixel[3] = SDL_max(pixel[0], SDL_max(pixel[1], pixel[2]));
      }
    }
  }
  RECT uploads[4];
  int upload_count = 0;
  if (full && cover) {
    uploads[upload_count++] = all;
  } else {
    for (int i = 0; i < dirty_count; i++) uploads[upload_count++] = dirty[i];
    if (full)
      uploads[upload_count++] = (RECT){window->sidebar_w, window->controls.bottom, window->buffer_w,
                                       SDL_min(window->buffer_h, window->controls.bottom + (LONG)(48 * window->scale))};
  }
  for (int i = 0; i < upload_count; i++) {
    RECT rect = uploads[i];
    rect.right = SDL_min(rect.right, window->buffer_w);
    rect.bottom = SDL_min(rect.bottom, window->buffer_h);
    if (rect.right <= rect.left || rect.bottom <= rect.top)
      continue;
    D3D11_BOX box = {rect.left, rect.top, 0, rect.right, rect.bottom, 1};
    const uint8_t *pixels = (uint8_t *)window->ui_pixels + ((size_t)rect.top * window->ui_w + rect.left) * 4;
    window->context->lpVtbl->UpdateSubresource(window->context, (ID3D11Resource *)window->ui, 0, &box, pixels,
                                             window->ui_w * 4, 0);
  }
  if (!full) SDL_Log("Shell UI hover upload: regions=%d", dirty_count);
  SelectObject(dc, old_font);
  DeleteObject(font);
  SelectClipRgn(dc, NULL);
  DeleteObject(clip);
  window->ui_dirty = false;
  window->ui_hover_dirty = false;
}

typedef struct {
  float dst[4], src[4], color[4];
  float viewport[2], solid, pad;
} ShellComposeConstants;

static bool compose_ready(ShellWindow *window) {
  if (window->compose_vs) return true;
  if (window->compose_failed) return false;
  ID3D11Device *device = window->device;
  HRESULT hr = device->lpVtbl->CreateVertexShader(device, shell_compose_vertex_shader,
                                                  sizeof(shell_compose_vertex_shader), NULL, &window->compose_vs);
  if (SUCCEEDED(hr))
    hr = device->lpVtbl->CreatePixelShader(device, shell_compose_pixel_shader, sizeof(shell_compose_pixel_shader),
                                           NULL, &window->compose_ps);
  if (SUCCEEDED(hr)) {
    D3D11_BUFFER_DESC desc = {sizeof(ShellComposeConstants), D3D11_USAGE_DEFAULT, D3D11_BIND_CONSTANT_BUFFER, 0, 0, 0};
    hr = device->lpVtbl->CreateBuffer(device, &desc, NULL, &window->compose_constants);
  }
  if (SUCCEEDED(hr)) {
    D3D11_BLEND_DESC desc = {0};
    desc.RenderTarget[0].BlendEnable = TRUE;
    desc.RenderTarget[0].SrcBlend = desc.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
    desc.RenderTarget[0].DestBlend = desc.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
    desc.RenderTarget[0].BlendOp = desc.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
    desc.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    hr = device->lpVtbl->CreateBlendState(device, &desc, &window->compose_blend);
  }
  if (SUCCEEDED(hr)) {
    D3D11_RASTERIZER_DESC desc = {0};
    desc.FillMode = D3D11_FILL_SOLID;
    desc.CullMode = D3D11_CULL_NONE;
    desc.DepthClipEnable = TRUE;
    hr = device->lpVtbl->CreateRasterizerState(device, &desc, &window->compose_raster);
  }
  if (FAILED(hr)) {
    SAFE_RELEASE(window->compose_vs);
    SAFE_RELEASE(window->compose_ps);
    SAFE_RELEASE(window->compose_constants);
    SAFE_RELEASE(window->compose_blend);
    SAFE_RELEASE(window->compose_raster);
    window->compose_failed = true;
    SDL_Log("Shell blending unavailable: 0x%08lx; transparent layers are copied", (unsigned long)hr);
    return false;
  }
  return true;
}

/* Blends a premultiplied layer, or a solid premultiplied colour when view is NULL, into dst. */
static void compose_rect(ShellWindow *window, ID3D11ShaderResourceView *view, RECT dst, int src_x, int src_y,
                         const float color[4]) {
  dst.right = SDL_min(dst.right, window->buffer_w);
  dst.bottom = SDL_min(dst.bottom, window->buffer_h);
  if (dst.right <= dst.left || dst.bottom <= dst.top || !compose_ready(window)) return;
  ID3D11DeviceContext *context = window->context;
  ShellComposeConstants constants = {
      {(float)dst.left, (float)dst.top, (float)dst.right, (float)dst.bottom},
      {(float)src_x, (float)src_y, 0, 0},
      {color ? color[0] : 0, color ? color[1] : 0, color ? color[2] : 0, color ? color[3] : 0},
      {(float)window->buffer_w, (float)window->buffer_h},
      view ? 0.0f : 1.0f,
      0};
  context->lpVtbl->UpdateSubresource(context, (ID3D11Resource *)window->compose_constants, 0, NULL, &constants, 0,
                                     0);
  D3D11_VIEWPORT viewport = {0, 0, (float)window->buffer_w, (float)window->buffer_h, 0, 1};
  context->lpVtbl->OMSetRenderTargets(context, 1, &window->rtv, NULL);
  context->lpVtbl->OMSetBlendState(context, window->compose_blend, NULL, 0xffffffff);
  context->lpVtbl->RSSetViewports(context, 1, &viewport);
  context->lpVtbl->RSSetState(context, window->compose_raster);
  context->lpVtbl->IASetInputLayout(context, NULL);
  context->lpVtbl->IASetPrimitiveTopology(context, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
  context->lpVtbl->VSSetShader(context, window->compose_vs, NULL, 0);
  context->lpVtbl->VSSetConstantBuffers(context, 0, 1, &window->compose_constants);
  context->lpVtbl->PSSetShader(context, window->compose_ps, NULL, 0);
  context->lpVtbl->PSSetConstantBuffers(context, 0, 1, &window->compose_constants);
  context->lpVtbl->PSSetShaderResources(context, 0, 1, &view);
  context->lpVtbl->Draw(context, 4, 0);
  ID3D11ShaderResourceView *none = NULL;
  context->lpVtbl->PSSetShaderResources(context, 0, 1, &none);
}

static ID3D11ShaderResourceView *presentation_view(ShellWindow *window, ShellPresentation *surface) {
  if (surface->view && surface->view_texture == surface->surface) return surface->view;
  SAFE_RELEASE(surface->view);
  surface->view_texture = NULL;
  if (!surface->surface) return NULL;
  HRESULT hr = window->device->lpVtbl->CreateShaderResourceView(window->device, (ID3D11Resource *)surface->surface,
                                                                NULL, &surface->view);
  if (FAILED(hr)) {
    SDL_Log("Shell layer view creation failed: 0x%08lx", (unsigned long)hr);
    return NULL;
  }
  surface->view_texture = surface->surface;
  return surface->view;
}

static void copy_ui(ShellWindow *window, RECT rect);
static void blend_ui(ShellWindow *window, RECT rect) {
  if (window->ui_view && compose_ready(window))
    compose_rect(window, window->ui_view, rect, rect.left, rect.top, NULL);
  else
    copy_ui(window, rect);
}

static void copy_ui(ShellWindow *window, RECT rect) {
  if (!window->ui || rect.right <= rect.left || rect.bottom <= rect.top)
    return;
  D3D11_BOX box = {rect.left, rect.top, 0, rect.right, rect.bottom, 1};
  window->context->lpVtbl->CopySubresourceRegion(window->context, (ID3D11Resource *)window->backbuffer, 0,
                                               rect.left, rect.top, 0, (ID3D11Resource *)window->ui,
                                               0, &box);
}

/* Writes the composed backbuffer for an isolated probe. */
static void capture_backbuffer(ShellWindow *window) {
  unsigned index = window->capture;
  window->capture = 0;
  const char *directory = SDL_getenv("ANVIL_SHELL_CAPTURE_DIR");
  if (!directory) return;
  D3D11_TEXTURE2D_DESC desc;
  window->backbuffer->lpVtbl->GetDesc(window->backbuffer, &desc);
  desc.Usage = D3D11_USAGE_STAGING;
  desc.BindFlags = 0;
  desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  desc.MiscFlags = 0;
  ID3D11Texture2D *staging = NULL;
  if (FAILED(window->device->lpVtbl->CreateTexture2D(window->device, &desc, NULL, &staging))) return;
  window->context->lpVtbl->CopyResource(window->context, (ID3D11Resource *)staging,
                                        (ID3D11Resource *)window->backbuffer);
  D3D11_MAPPED_SUBRESOURCE mapped;
  if (SUCCEEDED(window->context->lpVtbl->Map(window->context, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0,
                                             &mapped))) {
    char path[MAX_PATH];
    SDL_snprintf(path, sizeof(path), "%s\\capture-%u.bmp", directory, index);
    FILE *file = fopen(path, "wb");
    if (file) {
      BITMAPFILEHEADER header = {0x4d42, 0, 0, 0, sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER)};
      BITMAPINFOHEADER info = {sizeof(info), (LONG)desc.Width, -(LONG)desc.Height, 1, 32, BI_RGB};
      header.bfSize = header.bfOffBits + desc.Width * desc.Height * 4;
      fwrite(&header, sizeof(header), 1, file);
      fwrite(&info, sizeof(info), 1, file);
      for (UINT y = 0; y < desc.Height; y++)
        fwrite((uint8_t *)mapped.pData + (size_t)y * mapped.RowPitch, 4, desc.Width, file);
      fclose(file);
      SDL_Log("Shell probe capture written: %s", path);
    }
    window->context->lpVtbl->Unmap(window->context, (ID3D11Resource *)staging, 0);
  }
  SAFE_RELEASE(staging);
}

static void composite_and_present(ShellWindow *window) {
  ShellProject *project = window->selected;
  if (window->render_failed) { InvalidateRect(window->hwnd, NULL, FALSE); return; }
  if (!window->rtv)
    return;
  uint32_t background = window->background;
  const FLOAT clear[4] = {(background & 0xff) / 255.0f, (background >> 8 & 0xff) / 255.0f,
                          (background >> 16 & 0xff) / 255.0f, 1.0f};
  window->context->lpVtbl->ClearRenderTargetView(window->context, window->rtv, clear);
  ShellPresentation *content = &window->project_presentation;
  if (content->have_surface) {
    /* A frame of the current size anchors the content. While a live resize waits for one, the old frame keeps
     * its screen position and the Project background fills the rest. */
    POINT origin = {project->last_config.origin_x, project->last_config.origin_y};
    ClientToScreen(window->hwnd, &origin);
    int x = project->last_config.origin_x, y = project->last_config.origin_y;
    bool current = content->surface_w == project->last_config.pixel_w &&
                   content->surface_h == project->last_config.pixel_h;
    if (current || !window->live_resize || !content->anchored) {
      content->anchor = origin;
      content->anchored = current;
    } else {
      x += content->anchor.x - origin.x;
      y += content->anchor.y - origin.y;
    }
    /* Clip to the Project area of the backbuffer. */
    int left = SDL_max(x, project->last_config.origin_x), top = SDL_max(y, project->last_config.origin_y);
    int right = SDL_min(x + content->surface_w, project->last_config.origin_x + project->last_config.pixel_w);
    int bottom = SDL_min(y + content->surface_h, project->last_config.origin_y + project->last_config.pixel_h);
    right = SDL_min(right, window->buffer_w);
    bottom = SDL_min(bottom, window->buffer_h);
    if (right > left && bottom > top) {
      D3D11_BOX box = {(UINT)(left - x), (UINT)(top - y), 0, (UINT)(right - x), (UINT)(bottom - y), 1};
      window->context->lpVtbl->CopySubresourceRegion(
          window->context, (ID3D11Resource *)window->backbuffer, 0, (UINT)left, (UINT)top, 0,
          (ID3D11Resource *)content->surface, 0, &box);
    }
  }
  update_ui(window);
  /* Layers: the Project backdrop and UI, the Sidebar, the Project's overlay dim over the Sidebar, then the
   * native strip and window controls. A transparent Sidebar shows the Project's wallpaper under it. */
  ShellPresentation *sidebar = &window->sidebar_presentation;
  if (sidebar->have_surface && shell.sidebar_process && shell.sidebar_process->state != SHELL_FAILED) {
    RECT rect = {0, 0, SDL_min(window->sidebar_w, sidebar->surface_w), SDL_min(window->buffer_h, sidebar->surface_h)};
    ID3D11ShaderResourceView *view = sidebar->transparent ? presentation_view(window, sidebar) : NULL;
    if (view && compose_ready(window)) {
      compose_rect(window, view, rect, 0, 0, NULL);
    } else {
      D3D11_BOX box = {0, 0, 0, (UINT)rect.right, (UINT)rect.bottom, 1};
      window->context->lpVtbl->CopySubresourceRegion(window->context, (ID3D11Resource *)window->backbuffer, 0,
                                                     0, 0, 0, (ID3D11Resource *)sidebar->surface, 0, &box);
    }
  } else {
    copy_ui(window, (RECT){0, window->controls.bottom, window->sidebar_w, window->buffer_h});
  }
  if (window->overlay >> 24) {
    uint32_t c = window->overlay;
    float a = (c >> 24) / 255.0f;
    float dim[4] = {(c & 0xff) / 255.0f * a, (c >> 8 & 0xff) / 255.0f * a, (c >> 16 & 0xff) / 255.0f * a, a};
    compose_rect(window, NULL, (RECT){0, 0, window->sidebar_w, window->buffer_h}, 0, 0, dim);
  }
  blend_ui(window, (RECT){0, 0, window->sidebar_w, window->controls.bottom});
  blend_ui(window, window->controls);
  if (project->state == SHELL_STARTING || project->state == SHELL_DORMANT ||
      (project->state == SHELL_FAILED && !window->project_presentation.have_surface))
    copy_ui(window, (RECT){window->sidebar_w, window->controls.bottom, window->buffer_w, window->buffer_h});
  else if (project->state == SHELL_FAILED)
    copy_ui(window, window->failure_card);
  if (window->notice[0])
    copy_ui(window, (RECT){window->sidebar_w, window->controls.bottom, window->buffer_w,
                           SDL_min(window->buffer_h, window->controls.bottom + (LONG)(48 * window->scale))});
  if (window->capture) capture_backbuffer(window);
  anvil_latency_probe_stage("present-begin");
  /* Like a direct window, a live resize step does not wait for vertical blank. */
  HRESULT hr = window->swapchain->lpVtbl->Present(window->swapchain, window->live_resize ? 0 : 1, 0);
  anvil_latency_probe_stage("present-end");
  if (take_fault(FAULT_PRESENT))
    hr = DXGI_ERROR_DEVICE_REMOVED;
  if (FAILED(hr))
    fail_gpu(window, "presentation failed", hr);
}

static void finish_latency_probe(void) {
  for (ShellProject *project = shell.projects; project; project = project->next)
    if (project->process.hProcess) anvil_process_terminate(project->process.hProcess, 0);
  if (shell.sidebar_process && shell.sidebar_process->process.hProcess)
    anvil_process_terminate(shell.sidebar_process->process.hProcess, 0);
  shell_exit(anvil_latency_probe_succeeded() ? 0 : 1);
}

/* Copies the newest published frame into the private surface texture. */
static void leave_sidebar(ShellWindow *window);

static bool load_pending_frame(ShellProject *project, ShellPresentation *surface,
                               AnvilSurfaceFrame *frame) {
  ShellWindow *window = window_for_id(project->window_id);
  if (!window) return false;
  SDL_LockMutex(project->lock);
  bool pending = project->frame_pending;
  *frame = project->latest_frame;
  project->frame_pending = false;
  SDL_UnlockMutex(project->lock);
  if (window->render_failed || project->state == SHELL_FAILED || !project->last_config.render_enabled)
    return false;
  if (!pending) return false;
  if (!anvil_surface_frame_matches(&project->last_config, frame)) {
    set_surface_busy(window, surface, false);
    /* A slow Project trails every configure during a drag. Its frames still show it is responsive. */
    if (surface == &window->project_presentation && window->live_resize)
      window->resize_wait_disabled = false;
    SDL_Log("Shell discarded stale frame: configuration=%llu current=%llu; last safe frame=%s",
            (unsigned long long)frame->configuration,
            (unsigned long long)project->last_config.configuration,
            surface->have_surface ? "retained" : "none");
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
  surface->busy = false;
  bool loaded = frame->kind == ANVIL_SURFACE_FRAME_D3D11 ? load_d3d11_frame(project, surface, frame)
                : frame->kind == ANVIL_SURFACE_FRAME_SHARED_MEMORY
                    ? load_memory_frame(project, surface, frame)
                    : false;
  if (!loaded) {
    set_surface_busy(window, surface, surface->busy);
    if (surface->busy) {
      SDL_LockMutex(project->lock);
      if (project->latest_frame.generation == frame->generation)
        project->frame_pending = true;
      SDL_UnlockMutex(project->lock);
    } else if (project->state != SHELL_FAILED) {
      HRESULT removed = window->device->lpVtbl->GetDeviceRemovedReason(window->device);
      if (FAILED(removed))
        fail_gpu(window, "surface device failed", removed);
      else
        fail_connection(project, "surface resource unavailable or invalid");
    }
    return false;
  }
  set_surface_busy(window, surface, false);
  surface->have_surface = true;
  if (surface == &window->project_presentation && frame->background)
    apply_background(window, frame->background);
  bool transparent = frame->kind == ANVIL_SURFACE_FRAME_D3D11 && (frame->background >> 24) == 0;
  if (surface == &window->sidebar_presentation && transparent != surface->transparent)
    SDL_Log("Shell Sidebar layer: Window=%u transparent=%d", window->id, transparent);
  surface->transparent = transparent;
  if (surface == &window->project_presentation) {
    if (!(window->overlay >> 24) != !(frame->overlay >> 24))
      SDL_Log("Shell Window overlay: id=%u shown=%d", window->id, (frame->overlay >> 24) != 0);
    window->overlay = frame->overlay;
    if (window->overlay >> 24) leave_sidebar(window);
  }
  /* A fresh Project frame shows the Project is responsive again, so resize steps wait for it once more.
   * During a drag frames trail the window size, so requiring an exact match kept waiting off for the rest
   * of the drag and presented stale content. */
  if (surface == &window->project_presentation &&
      (window->live_resize || (surface->surface_w == window->buffer_w && surface->surface_h == window->buffer_h))) {
    window->resize_wait_disabled = false;
  }
  return true;
}

static bool wait_for_surface_size(ShellWindow *window, int width, int height) {
  ShellProject *project = window->selected;
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
static void resize_step(ShellWindow *window) {
  ShellProject *project = window->selected;
  resize_buffers(window);
  send_configure(project);
  if (window->sidebar && shell.sidebar_process)
    send_configure(window->sidebar_client);
  int width = window->buffer_w, height = window->buffer_h;
  bool stale = !window->project_presentation.have_surface ||
               window->project_presentation.surface_w != width ||
               window->project_presentation.surface_h != height;
  Uint64 started = SDL_GetTicksNS();
  bool waited = stale && project->connected && window->shown && !window->resize_wait_disabled;
  if (waited && !wait_for_surface_size(window, width, height)) {
    window->resize_wait_disabled = true;
    SDL_Log("Anvil shell resize to %dx%d timed out waiting for the surface", width, height);
  }
  AnvilSurfaceFrame frame;
  load_pending_frame(window->selected, &window->project_presentation, &frame);
  if (window->shown) composite_and_present(window);
  if (window->live_resize)
    SDL_Log("Shell resize step: Window=%u target=%dx%d presented=%dx%d matched=%d waited=%d wait_ms=%.1f",
            window->id, width, height, window->project_presentation.surface_w,
            window->project_presentation.surface_h,
            window->project_presentation.surface_w == width && window->project_presentation.surface_h == height,
            waited, (double)(SDL_GetTicksNS() - started) / SDL_NS_PER_MS);
}

static void handle_frame(ShellWindow *window) {
  ShellProject *project = window->selected;
  AnvilSurfaceFrame frame;
  if (!load_pending_frame(window->selected, &window->project_presentation, &frame))
    return;
  if (project->state == SHELL_STARTING) {
    SDL_Log("Anvil shell showing its first %s frame %dx%d",
            frame.kind == ANVIL_SURFACE_FRAME_D3D11 ? "d3d11" : "memory",
            window->project_presentation.surface_w, window->project_presentation.surface_h);
    set_state(project, SHELL_READY);
  }
  composite_and_present(window);
  anvil_latency_probe_presented(frame.input_seq);
  if (project->state == SHELL_READY && !project->close_requested_ns)
    anvil_latency_probe_start(window->window, finish_latency_probe);
}
static void handle_sidebar_frame(ShellWindow *window) {
  ShellProject *project = window->sidebar_client;
  if (!project)
    return;
  AnvilSurfaceFrame frame;
  if (load_pending_frame(project, &window->sidebar_presentation, &frame)) {
    if (project->state == SHELL_STARTING) {
      set_state(project, SHELL_READY);
      SDL_Log("Shell Sidebar surface Ready: Window=%u connection=%u size=%dx%d", window->id,
              project->connection, frame.width, frame.height);
      if (shell.sidebar_process && shell.sidebar_process->state == SHELL_STARTING)
        set_state(shell.sidebar_process, SHELL_READY);
      if (shell.sidebar_restart_attempts && !shell.sidebar_healthy_timer) {
        shell.sidebar_healthy_since = SDL_GetTicks();
        shell.sidebar_healthy_connection = project->connection;
        shell.sidebar_healthy_timer = SetTimer(shell.service_hwnd, 0x8004, SHELL_SIDEBAR_HEALTHY_MS, NULL);
        if (!shell.sidebar_healthy_timer)
          SDL_Log("Shell Sidebar recovery-budget timer failed; manual Restart remains available");
      }
    }
    if (window->shown)
      composite_and_present(window);
  }
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

static void apply_window_mode(ShellWindow *window, int mode) {
  bool fullscreen = (SDL_GetWindowFlags(window->window) & SDL_WINDOW_FULLSCREEN) != 0;
  if (mode != ANVIL_SURFACE_WINDOW_FULLSCREEN && fullscreen)
    SDL_SetWindowFullscreen(window->window, false);
  switch (mode) {
  case ANVIL_SURFACE_WINDOW_MINIMIZED:
    SDL_MinimizeWindow(window->window);
    break;
  case ANVIL_SURFACE_WINDOW_MAXIMIZED:
    SDL_MaximizeWindow(window->window);
    break;
  case ANVIL_SURFACE_WINDOW_FULLSCREEN:
    SDL_SetWindowFullscreen(window->window, true);
    break;
  default:
    SDL_RestoreWindow(window->window);
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

/* Native picker callbacks hold copied results and IDs, never Window pointers. */
struct ShellPicker {
  ShellPicker *next;
  Uint32 window_id, event_type;
  uint64_t close_generation;
  uint32_t size;
  void *result;
  bool probe;
  SDL_AtomicInt notification_failed;
};

static void free_picker(ShellPicker *picker) {
  ShellPicker **link = &shell.pickers;
  while (*link != picker) link = &(*link)->next;
  *link = picker->next;
  free(picker->result);
  free(picker);
}

static void SDLCALL project_picker_finished(void *userdata, const char *const *paths, int filter) {
  ShellPicker *picker = userdata;
  picker->result = anvil_surface_dialog_result(picker->window_id, paths, filter, &picker->size);
  SDL_Event event = {.type = picker->event_type};
  event.user.code = SHELL_EVENT_PICKER_RESULT;
  event.user.windowID = picker->window_id;
  event.user.data1 = picker;
  if (!picker->result || !SDL_PushEvent(&event)) {
    SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Shell Open Project picker result notification failed");
    SDL_SetAtomicInt(&picker->notification_failed, 1);
    PostMessageW(shell.service_hwnd, WM_APP + 0x51, 0, 0);
  }
}

static void show_project_picker(ShellWindow *window) {
  if (window->closing || window->picker_pending) return;
  unsigned pending = 0;
  for (ShellPicker *item = shell.pickers; item; item = item->next) pending++;
  if (pending >= 64) { window_notice(window, "Too many Project folder pickers are pending."); return; }
  ShellPicker *picker = calloc(1, sizeof(*picker));
  SDL_PropertiesID props = SDL_CreateProperties();
  if (!picker || !props ||
      !SDL_SetPointerProperty(props, SDL_PROP_FILE_DIALOG_WINDOW_POINTER, window->window) ||
      !SDL_SetStringProperty(props, SDL_PROP_FILE_DIALOG_TITLE_STRING, "Open Project")) {
    free(picker);
    if (props) SDL_DestroyProperties(props);
    window_notice(window, "Cannot open the Project folder picker.");
    return;
  }
  picker->window_id = window->id;
  picker->close_generation = window->close_generation;
  picker->event_type = shell.event_type;
  picker->next = shell.pickers;
  shell.pickers = picker;
  window->picker_pending = true;
  cancel_input(window);
  const char *probe = SDL_getenv("ANVIL_SURFACE_FAULT_PROBE");
  const char *picker_probe = SDL_getenv("ANVIL_SHELL_PICKER_PROBE");
  picker->probe = probe && !strcmp(probe, "1") && picker_probe && !strcmp(picker_probe, "1");
  SDL_Log("Shell Open Project picker started: Window=%u parent=%p probe=%d", window->id,
          (void *)window->hwnd, picker->probe);
  if (!picker->probe)
    SDL_ShowFileDialogWithProperties(SDL_FILEDIALOG_OPENFOLDER, project_picker_finished, picker, props);
  SDL_DestroyProperties(props);
}

static void finish_project_picker(ShellPicker *picker) {
  ShellWindow *window = window_for_id(picker->window_id);
  if (window) window->picker_pending = false;
  if (!window || window->closing || picker->close_generation != window->close_generation) {
    SDL_Log("Shell discarded an Open Project picker result for removed or closing Window=%u", picker->window_id);
  } else if (!picker->result || !anvil_surface_dialog_result_valid(picker->result, picker->size)) {
    window_notice(window, "Cannot read the Project folder picker result.");
  } else {
    const AnvilSurfaceDialogResult *result = picker->result;
    if (result->status == ANVIL_SURFACE_DIALOG_ACCEPT) {
      const char *path = (const char *)(result + 1);
      bool accepted = window->selected->id ? open_project_window(window, path)
                                           : select_project_path(window, path);
      if (!accepted) window_notice(window, "Cannot submit the Open Project request.");
    } else if (result->status == ANVIL_SURFACE_DIALOG_ERROR)
      window_notice(window, "The Project folder picker failed.");
    else SDL_Log("Shell Open Project picker cancelled: Window=%u", window->id);
  }
  free_picker(picker);
}

static void check_picker_failures(void) {
  for (ShellPicker *picker = shell.pickers, *next; picker; picker = next) {
    next = picker->next;
    if (!SDL_GetAtomicInt(&picker->notification_failed)) continue;
    ShellWindow *window = window_for_id(picker->window_id);
    if (window) {
      window->picker_pending = false;
      window_notice(window, "The Project folder picker result could not be delivered.");
    }
    free_picker(picker);
  }
}

/* Only the owned test process can replace this nondeterministic platform boundary. */
static void probe_project_picker(WPARAM action, LPARAM window_id) {
  const char *enabled = SDL_getenv("ANVIL_SURFACE_FAULT_PROBE");
  if (!enabled || strcmp(enabled, "1")) return;
  for (ShellPicker *picker = shell.pickers; picker; picker = picker->next) {
    if (!picker->probe || picker->window_id != (Uint32)window_id || picker->result) continue;
    if (action == 3) {
      const char *paths[] = {NULL};
      project_picker_finished(picker, paths, 0);
    } else if (action == 1 || action == 2) {
      const char *root = SDL_getenv("ANVIL_PROJECT_PROBE_ROOT");
      char path[32768];
      if (!root || SDL_snprintf(path, sizeof(path), "%s/%s", root,
                                action == 1 ? "Replacement" : "Project") >= sizeof(path)) return;
      const char *paths[] = {path, NULL};
      project_picker_finished(picker, paths, 0);
    }
    return;
  }
}

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
  ShellWindow *window = window_for_id(dialog->project->window_id);
  if (!window) { free_dialog(dialog); return; }
  ShellProject *project = dialog->project;
  const AnvilSurfaceDialog *request = (const AnvilSurfaceDialog *)dialog->packet;
  SDL_Log("Shell file dialog started: id=%u type=%u connection=%u", request->id, request->type,
          project->connection);
  cancel_input(window);
  SDL_ClearComposition(window->window);
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
  ShellWindow *window = window_for_id(project->window_id);
  if (!window) return;
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
  if (!SDL_SetPointerProperty(props, SDL_PROP_FILE_DIALOG_WINDOW_POINTER, window->window)) {
    SDL_DestroyProperties(props);
    free(dialog);
    fail_connection(project, "file dialog parent allocation failed");
    return;
  }
  project->dialogs[slot] = request->id;
  retain_project(project);
  dialog->props = props;
  if (project == window->selected)
    present_dialog(dialog);
  else {
    project->deferred_dialogs[slot] = dialog;
    SDL_Log("Shell deferred an unselected Project file dialog: id=%u Project=%u", request->id,
            project->id);
  }
}

static void finish_dialog(ShellProject *project, ShellDialog *dialog) {
  ShellWindow *window = window_for_id(project->window_id);
  if (!window) return;
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
      if (project == window->selected && project->text_active)
        SDL_StartTextInput(window->window);
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
  ShellWindow *window = window_for_id(project->window_id);
  if (!window) return;
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
  dialog->parent = window->hwnd;
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
  ShellWindow *window = window_for_id(project->window_id);
  if (!window) return;
  if (decision < ANVIL_SURFACE_CLOSE_PENDING || decision > ANVIL_SURFACE_CLOSE_ACCEPTED) {
    fail_connection(project, "invalid close decision");
    return;
  }
  if (decision == ANVIL_SURFACE_CLOSE_CANCELLED) {
    if (project == window->selected)
      window->closing = false;
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
    EnumWindows(dismiss_close_warning, (LPARAM)window->hwnd);
    set_state(project, SHELL_READY);
    SDL_Log("Shell close decision: cancelled; Ready; request reset");
  } else {
    if (project == window->selected && !project->unloading)
      begin_window_close(window);
    if (!project->close_requested_ns) {
      project->close_requested_ns = SDL_GetTicksNS();
      project->close_serial++;
    }
    set_state(project, SHELL_CLOSING);
    if (decision == ANVIL_SURFACE_CLOSE_WAITING) {
      if (project != window->selected)
        select_project(project);
      stop_close_timer(project);
      project->close_waiting = true;
      project->close_serial++;
      project->close_prompt = false;
      EnumWindows(dismiss_close_warning, (LPARAM)window->hwnd);
      if (!IsWindowVisible(window->hwnd) || IsIconic(window->hwnd)) {
        if (IsIconic(window->hwnd)) SDL_RestoreWindow(window->window);
        else SDL_ShowWindow(window->window);
        window->shown = true;
        send_configure(project);
        SDL_RaiseWindow(window->window);
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
  composite_and_present(window);
}

static void handle_message(ShellProject *project, ShellMessage *message) {
  if (message->type == ANVIL_SURFACE_MSG_SIDEBAR_SURFACE) {
    AnvilSidebarSurfacePacket packet = *(AnvilSidebarSurfacePacket *)message->payload;
    ShellWindow *target = window_for_id(packet.window_id);
    /* A live Close choice rejects Move with status. Other closing-surface requests stay discarded. */
    if (!target || target->removing || !target->sidebar_client || project != shell.sidebar_process ||
        (target->closing && packet.type != ANVIL_SURFACE_MSG_MOVE_PROJECT)) {
      SDL_Log("Shell ignored stale Sidebar surface request: Window=%u type=%u", packet.window_id, packet.type);
      return;
    }
    message->type = packet.type;
    message->size -= sizeof(packet);
    memmove(message->payload, message->payload + sizeof(packet), message->size);
    handle_message(target->sidebar_client, message);
    return;
  }
  ShellWindow *window = window_for_id(project->window_id);
  if (!window) return;
  if (project->state == SHELL_FAILED)
    return;
  const void *payload = message->payload;
  if ((message->type == ANVIL_SURFACE_MSG_NEW_WINDOW ||
       message->type == ANVIL_SURFACE_MSG_OPEN_PROJECT_WINDOW ||
       message->type == ANVIL_SURFACE_MSG_OPEN_PROJECT_PICKER) &&
      *(const uint32_t *)payload != window->id) {
    SDL_Log("Shell ignored stale Window request: type=%u requested=%u connection_Window=%u connection=%u",
            message->type, *(const uint32_t *)payload, window->id, project->connection);
    return;
  }
  int value =
      message->size == sizeof(AnvilSurfaceInt) ? ((const AnvilSurfaceInt *)payload)->value : 0;
  if (project->sidebar && message->type != ANVIL_SURFACE_MSG_SIDEBAR_QUERY &&
      message->type != ANVIL_SURFACE_MSG_SIDEBAR_REFRESH &&
      message->type != ANVIL_SURFACE_MSG_SELECT_PROJECT &&
      message->type != ANVIL_SURFACE_MSG_UNLOAD_PROJECT &&
      message->type != ANVIL_SURFACE_MSG_MOVE_PROJECT &&
      message->type != ANVIL_SURFACE_MSG_FRAME &&
      message->type != ANVIL_SURFACE_MSG_EXIT_INTENT && message->type != ANVIL_SURFACE_MSG_CURSOR &&
      message->type != ANVIL_SURFACE_MSG_HIT_TEST)
    return;
  if (project != window->selected) {
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
  case ANVIL_SURFACE_MSG_MOVE_PROJECT: {
    const AnvilSurfaceMoveProject *request = payload;
    move_project(window, request->project_id, request->target_window_id);
    break;
  }
  case ANVIL_SURFACE_MSG_FRAME:
    memcpy(&project->latest_frame, payload, sizeof(project->latest_frame));
    project->frame_pending = true;
    handle_sidebar_frame(window);
    break;
  case ANVIL_SURFACE_MSG_NEW_WINDOW:
    if (*(const uint32_t *)payload == window->id && !window->closing)
      if (!create_window(NULL)) window_notice(window, "Cannot create a Window.");
    break;
  case ANVIL_SURFACE_MSG_OPEN_PROJECT_WINDOW:
    if (*(const uint32_t *)payload == window->id && !window->closing)
      open_project_window(window, (const char *)payload + sizeof(uint32_t));
    break;
  case ANVIL_SURFACE_MSG_OPEN_PROJECT_PICKER:
    if (*(const uint32_t *)payload == window->id && !window->closing)
      show_project_picker(window);
    break;
  case ANVIL_SURFACE_MSG_SIDEBAR_SOURCE:
    sidebar_source(payload, message->size);
    break;
  case ANVIL_SURFACE_MSG_SIDEBAR_QUERY: {
    sync_sidebar_model();
    char *snapshot = anvil_sidebar_snapshot(&shell.sidebar, (size_t)value);
    const char *reply =
        snapshot
            ? snapshot
            : "return {error=\"Project Sidebar snapshot exceeds its bound or allocation failed\"}";
    shell_send(project, ANVIL_SURFACE_MSG_SIDEBAR_MODEL, reply, (uint32_t)strlen(reply) + 1, NULL,
               0);
    free(snapshot);
    break;
  }
  case ANVIL_SURFACE_MSG_SIDEBAR_REFRESH:
    shell.sidebar_scan_requested = true;
    service_sidebar();
    break;
  case ANVIL_SURFACE_MSG_SELECT_PROJECT:
    if (!window->closing)
      select_project_path(window, payload);
    break;
  case ANVIL_SURFACE_MSG_UNLOAD_PROJECT:
    if (!window->closing)
      unload_project_path(window, payload);
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
      project->intentional_exit = project->exit_announced = true;
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
        SDL_ShowWindow(window->window);
        window->shown = true;
      } else if (!value) {
        SDL_HideWindow(window->window);
        window->shown = false;
      }
      send_configure(project);
    }
    break;
  case ANVIL_SURFACE_MSG_OPACITY:
    if (message->size == sizeof(float)) {
      float opacity;
      memcpy(&opacity, payload, sizeof(opacity));
      if (opacity >= 0 && opacity <= 1)
        SDL_SetWindowOpacity(window->window, opacity);
    }
    break;
  case ANVIL_SURFACE_MSG_CURSOR:
    project->child_cursor = value;
    if (project == window->selected && (window->pointer_in_surface || window->surface_buttons))
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
      if (project != window->selected)
        break;
      if (project->text_active)
        SDL_StartTextInput(window->window);
      else {
        SDL_ClearComposition(window->window);
        SDL_StopTextInput(window->window);
      }
    } else {
      if (project != window->selected)
        break;
      SDL_Rect rect;
      int cursor;
      if (anvil_surface_text_area(&project->last_config, input, &rect, &cursor)) {
        int point_w, point_h;
        SDL_GetWindowSize(window->window, &point_w, &point_h);
        float sx = (float)point_w / window->buffer_w;
        float sy = (float)point_h / window->buffer_h;
        rect = (SDL_Rect){(int)(rect.x * sx), (int)(rect.y * sy), SDL_max(1, (int)(rect.w * sx)),
                          SDL_max(1, (int)(rect.h * sy))};
        SDL_SetTextInputArea(window->window, &rect, SDL_clamp((int)(cursor * sx), 0, rect.w));
      }
    }
    break;
  }
  case ANVIL_SURFACE_MSG_CLEAR_IME:
    if (message->size == sizeof(uint64_t) &&
        *(uint64_t *)payload == project->last_config.configuration)
      SDL_ClearComposition(window->window);
    break;
  case ANVIL_SURFACE_MSG_WINDOW_MODE:
    apply_window_mode(window, value);
    break;
  case ANVIL_SURFACE_MSG_TITLE: {
    char *title = malloc((size_t)message->size + 1);
    if (!title)
      break;
    memcpy(title, payload, message->size);
    title[message->size] = '\0';
    free(project->title);
    project->title = title;
    if (project == window->selected)
      SDL_SetWindowTitle(window->window, title);
    break;
  }
  case ANVIL_SURFACE_MSG_HIT_TEST:
    if (message->size == sizeof(AnvilSurfaceHitTest) &&
        ((AnvilSurfaceHitTest *)payload)->configuration == project->last_config.configuration) {
      memcpy(&project->hit, payload, sizeof(project->hit));
      project->hit.title_height = SDL_clamp(project->hit.title_height, 0, (int)(96 * window->scale));
      controls_geometry(window);
      int available = SDL_max(0, window->controls.left);
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
    if (project != window->selected) {
      if (window->closing)
        break;
      select_project(project);
    }
    if (window->shown) {
      if (current_window_mode(window) == ANVIL_SURFACE_WINDOW_MINIMIZED)
        SDL_RestoreWindow(window->window);
      SDL_RaiseWindow(window->window);
      SDL_Log("Shell forwarded raise: foreground=%d", GetForegroundWindow() == window->hwnd);
    }
    break;
  case ANVIL_SURFACE_MSG_FLASH:
    SDL_FlashWindow(window->window, (SDL_FlashOperation)value);
    break;
  case ANVIL_SURFACE_MSG_SET_BOUNDS: {
    if (message->size != sizeof(AnvilSurfaceBounds))
      break;
    const AnvilSurfaceBounds *bounds = payload;
    if (bounds->w <= 0 || bounds->h <= 0)
      break;
    SetWindowPos(window->hwnd, NULL, bounds->x, bounds->y, bounds->w, bounds->h,
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

static void forward_event(ShellWindow *window, const SDL_Event *event, const char *text) {
  ShellProject *project = window->selected;
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

static void clear_composition(ShellWindow *window) {
  SDL_ClearComposition(window->window);
  SDL_Event event = {0};
  event.type = SDL_EVENT_TEXT_EDITING;
  forward_event(window, &event, "");
}

/* SDL owns a Project drag's capture, so it keeps reporting motion and the release outside the Window. A
 * raw SetCapture left SDL dropping the Window's mouse focus there, which lost the button release. */
static void capture_surface_pointer(ShellWindow *window) {
  if (!SDL_CaptureMouse(true)) {
    SDL_Log("Shell pointer capture fell back to native capture: %s", SDL_GetError());
    SetCapture(window->hwnd);
  }
}

static void release_surface_pointer(ShellWindow *window) {
  SDL_CaptureMouse(false);
  if (GetCapture() == window->hwnd) ReleaseCapture();
}

static void cancel_input(ShellWindow *window) {
  ShellProject *project = window->selected;
  Uint32 buttons = window->surface_buttons;
  window->surface_buttons = 0;
  window->pressed_control = -1;
  window->pointer_in_surface = false;
  window->hovered_control = -1;
  window->ui_hover_dirty = true;
  release_surface_pointer(window);
  for (int button = 1; button <= 5; button++) {
    if (!(buttons & SDL_BUTTON_MASK(button))) continue;
    SDL_Event event = {0};
    event.type = SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.button = button;
    event.button.x = window->pointer_x;
    event.button.y = window->pointer_y;
    anvil_surface_translate_input(&project->last_config, &event);
    forward_event(window, &event, NULL);
  }
  clear_composition(window);
  SDL_Event leave = {0};
  leave.type = SDL_EVENT_WINDOW_MOUSE_LEAVE;
  forward_event(window, &leave, NULL);
  apply_cursor(ANVIL_SURFACE_CURSOR_ARROW);
}

static void leave_surface(ShellWindow *window) {
  if (window->pointer_in_surface) {
    window->pointer_in_surface = false;
    SDL_Event leave = {0};
    leave.type = SDL_EVENT_WINDOW_MOUSE_LEAVE;
    forward_event(window, &leave, NULL);
  }
  if (!window->surface_buttons)
    apply_cursor(ANVIL_SURFACE_CURSOR_ARROW);
}

/* The Sidebar takes pointer input unless the Project's modal overlay dim covers it. */
static bool sidebar_takes_pointer(ShellWindow *window, float x) {
  return !window->surface_buttons && !(window->overlay >> 24) && x >= 0 && x < window->sidebar_w &&
         shell.sidebar_process && shell.sidebar_process->connected;
}

static void leave_sidebar(ShellWindow *window) {
  if (!window->pointer_in_sidebar) return;
  window->pointer_in_sidebar = false;
  if (!window->sidebar_client || !shell.sidebar_process || !shell.sidebar_process->connected) return;
  AnvilSurfaceInput input = {.configuration = window->sidebar_client->last_config.configuration};
  input.event.type = SDL_EVENT_WINDOW_MOUSE_LEAVE;
  shell_send(window->sidebar_client, ANVIL_SURFACE_MSG_INPUT, &input, sizeof(input), NULL, 0);
}

static int control_at(ShellWindow *window, float x, float y) {
  ShellProject *project = window->selected;
  POINT point = {(LONG)x, (LONG)y};
  if (x >= 0 && x < window->sidebar_w && y >= 0 && y < window->controls.bottom && sidebar_restart_offered())
    return 5;
  if (PtInRect(&window->controls, point)) {
    int width = SDL_max(1, (window->controls.right - window->controls.left) / 3);
    return SDL_min(2, ((int)x - window->controls.left) / width);
  }
  if (project->state == SHELL_FAILED || project->state == SHELL_DORMANT) {
    if (PtInRect(&window->restart_button, point))
      return 3;
    if (PtInRect(&window->close_button, point))
      return 4;
  }
  return -1;
}

static void perform_control(ShellWindow *window, int control) {
  ShellProject *project = window->selected;
  SDL_Log("Shell native control: %d state=%d", control, project->state);
  window->resize_wait_disabled = true;
  if (control == 5) {
    if (shell.sidebar_restart_timer) KillTimer(shell.service_hwnd, shell.sidebar_restart_timer);
    shell.sidebar_restart_timer = 0;
    shell.sidebar_restart_attempts = 0;
    shell.sidebar_restart_limited = false;
    shell.sidebar_failure_since = 0;
    shell.sidebar_waiting_exit = false;
    ShellProject *sidebar = shell.sidebar_process;
    if (sidebar && sidebar->process.hProcess &&
        WaitForSingleObject(sidebar->process.hProcess, 0) == WAIT_TIMEOUT)
      anvil_process_terminate(sidebar->process.hProcess, 125);
    start_sidebar();
    return;
  }
  if (control == 0)
    SDL_MinimizeWindow(window->window);
  else if (control == 1) {
    if (current_window_mode(window) == ANVIL_SURFACE_WINDOW_MAXIMIZED)
      SDL_RestoreWindow(window->window);
    else
      SDL_MaximizeWindow(window->window);
  } else if (control == 3) {
    if (project->state == SHELL_DORMANT) {
      select_project_path(window, project->project_path);
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
    if (window->render_failed) {
      SDL_Log("Shell explicit Restart: initialize presentation once");
      if (!init_d3d11(window)) {
        release_d3d11(window);
        InvalidateRect(window->hwnd, NULL, FALSE);
        return;
      }
      window->render_failed = false;
    }
    project->restart_path = _strdup(project->project_path);
    window->closing = false;
    if (!project->restart_path || !start_project(project, 0, NULL)) {
      free(project->restart_path);
      project->restart_path = NULL;
      set_state(project, SHELL_FAILED);
    } else {
      free(project->restart_path);
      project->restart_path = NULL;
      composite_and_present(window);
    }
  } else if (control == 4 && project->state != SHELL_DORMANT) {
    begin_unload(project);
  } else {
    begin_window_close(window);
    request_close(project);
  }
}

static bool surface_contains(ShellWindow *window, float x, float y) {
  ShellProject *project = window->selected;
  const AnvilSurfaceConfigure *config = &project->last_config;
  return x >= config->origin_x && y >= config->origin_y && x < config->origin_x + config->pixel_w &&
         y < config->origin_y + config->pixel_h;
}

static void route_motion(ShellWindow *window, SDL_Event *event) {
  ShellProject *project = window->selected;
  window->pointer_x = event->motion.x;
  window->pointer_y = event->motion.y;
  if (sidebar_takes_pointer(window, event->motion.x) && event->motion.y >= window->controls.bottom) {
    leave_surface(window);
    window->pointer_in_sidebar = true;
    AnvilSurfaceInput input = {.event = *event,
                               .configuration = window->sidebar_client->last_config.configuration};
    shell_send(window->sidebar_client, ANVIL_SURFACE_MSG_INPUT, &input, sizeof(input), NULL, 0);
    return;
  }
  leave_sidebar(window);
  int control = control_at(window, event->motion.x, event->motion.y);
  if (window->hovered_control != control) {
    window->hovered_control = control;
    window->ui_hover_dirty = true;
    composite_and_present(window);
  }
  if (!window->surface_buttons &&
      (control >= 0 || window->pressed_control >= 0 || project->state == SHELL_STARTING ||
       project->state == SHELL_FAILED || project->state == SHELL_DORMANT)) {
    leave_surface(window);
    return;
  }
  bool inside = surface_contains(window, event->motion.x, event->motion.y) && control < 0;
  if (!inside)
    leave_surface(window);
  if (window->surface_buttons || inside) {
    if (inside && !window->pointer_in_surface) {
      window->pointer_in_surface = true;
      apply_cursor(project->child_cursor);
      SDL_Event enter = {0};
      enter.type = SDL_EVENT_WINDOW_MOUSE_ENTER;
      forward_event(window, &enter, NULL);
    }
    anvil_surface_translate_input(&project->last_config, event);
    forward_event(window, event, NULL);
  }
}

static void route_button(ShellWindow *window, SDL_Event *event) {
  ShellProject *project = window->selected;
  window->pointer_x = event->button.x;
  window->pointer_y = event->button.y;
  Uint32 mask = SDL_BUTTON_MASK(event->button.button);
  bool down = event->type == SDL_EVENT_MOUSE_BUTTON_DOWN;
  int control = control_at(window, event->button.x, event->button.y);
  if (control < 0 && sidebar_takes_pointer(window, event->button.x)) {
    leave_surface(window);
    AnvilSurfaceInput input = {.event = *event,
                               .configuration = window->sidebar_client->last_config.configuration};
    shell_send(window->sidebar_client, ANVIL_SURFACE_MSG_INPUT, &input, sizeof(input), NULL, 0);
    return;
  }
  if (!window->surface_buttons && (control >= 0 || window->pressed_control >= 0)) {
    leave_surface(window);
    if (event->button.button != SDL_BUTTON_LEFT)
      return;
    if (down) {
      clear_composition(window);
      window->pressed_control = control;
      SetCapture(window->hwnd);
    } else {
      int pressed = window->pressed_control;
      window->pressed_control = -1;
      ReleaseCapture();
      if (control >= 0 && pressed == control)
        perform_control(window, control);
    }
    window->ui_hover_dirty = true;
    composite_and_present(window);
    return;
  }
  if (project->state == SHELL_STARTING || project->state == SHELL_FAILED ||
      project->state == SHELL_DORMANT)
    return;
  if (down) {
    if (!window->surface_buttons && !surface_contains(window, event->button.x, event->button.y)) {
      clear_composition(window);
      return;
    }
    window->surface_buttons |= mask;
    capture_surface_pointer(window);
  } else {
    if (!(window->surface_buttons & mask))
      return;
    window->surface_buttons &= ~mask;
    if (!window->surface_buttons) {
      release_surface_pointer(window);
      if (!surface_contains(window, event->button.x, event->button.y) || control >= 0)
        leave_surface(window);
    }
  }
  anvil_surface_translate_input(&project->last_config, event);
  forward_event(window, event, NULL);
}

static void request_close(ShellProject *project) {
  ShellWindow *window = window_for_id(project->window_id);
  if (!window) return;
  if (project == window->selected && !project->unloading)
    begin_window_close(window);
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
    composite_and_present(window);
    return;
  }
  set_state(project, SHELL_CLOSING);
  composite_and_present(window);
  shell_send(project, ANVIL_SURFACE_MSG_CLOSE, NULL, 0, NULL, 0);
}

static void handle_connected(ShellProject *project) {
  ShellWindow *window = window_for_id(project->window_id);
  if (!window) return;
  if (project->sidebar) {
    project->connected = true;
    send_configure(project);
    for (ShellWindow *item = shell.windows; item; item = item->next) {
      ShellProject *client = item->sidebar_client;
      if (!client || item->closing) continue;
      client->connected = true;
      client->connection = project->connection;
      client->process.dwProcessId = project->process.dwProcessId;
      client->last_config = (AnvilSurfaceConfigure){0};
      client->state = SHELL_STARTING;
      send_configure(client);
    }
    SDL_Log("Shell Sidebar connected: pid=%lu connection=%u",
            (unsigned long)project->process.dwProcessId, project->connection);
    return;
  }
  if (project->state == SHELL_FAILED)
    return;
  SDL_Log("Anvil shell connected to surface process %lu",
          (unsigned long)project->process.dwProcessId);
  project->connected = true;
  send_configure(project);
  bool focused = project == window->selected &&
                 (anvil_latency_probe_enabled() ||
                  (SDL_GetWindowFlags(window->window) & SDL_WINDOW_INPUT_FOCUS) != 0);
  shell_send_int(project, ANVIL_SURFACE_MSG_FOCUS, focused ? 1 : 0);
  if (project->close_requested_ns)
    shell_send(project, ANVIL_SURFACE_MSG_CLOSE, NULL, 0, NULL, 0);
}

/* Runs on the launch server thread. */
static bool notify_external(AnvilShellLaunchRequest *request) {
  SDL_Event event = {.type = shell.event_type};
  event.user.code = SHELL_EVENT_EXTERNAL;
  event.user.data1 = request;
  return SDL_PushEvent(&event);
}

static void accept_external(AnvilShellLaunchRequest *request) {
  SDL_Log("Shell external launch received: pid=%lu arguments=%d",
          (unsigned long)anvil_shell_launch_client_pid(request), anvil_shell_launch_argc(request) - 2);
  if (shell.shutting_down ||
      !queue_resolution(NULL, anvil_shell_launch_cwd(request), anvil_shell_launch_argc(request),
                        anvil_shell_launch_argv(request), false, false, true, request))
    anvil_shell_launch_finish(request, ANVIL_SHELL_LAUNCH_BUSY);
}

SDL_AppResult anvil_shell_event(void *appstate, SDL_Event *event) {
  ShellWindow *window = NULL;
  ShellProject *project = NULL;
  (void)appstate;
  if (event->type == shell.event_type) {
    if (event->user.code == SHELL_EVENT_PICKER_RESULT) {
      finish_project_picker(event->user.data1);
      return SDL_APP_CONTINUE;
    }
    if (event->user.code == SHELL_EVENT_EXTERNAL) {
      accept_external(event->user.data1);
      return SDL_APP_CONTINUE;
    }
    if (event->user.code == SHELL_EVENT_MESSAGE) {
      ShellMessage *message = event->user.data1;
      SDL_AddAtomicInt(&message->owner->inbound_bytes, -(int)(sizeof(*message) + message->size));
    }
    project = project_for_connection(event->user.windowID);
    window = project ? window_for_id(project->window_id) : NULL;
    if (!project || !window) {
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
    if (event->user.code == SHELL_EVENT_FRAME && event->user.data2 &&
        (Uint32)(uintptr_t)event->user.data2 != window->id) return SDL_APP_CONTINUE;
    check_gpu_failure(window);
    switch (event->user.code) {
    case SHELL_EVENT_LAUNCHED:
      finish_launch(project);
      break;
    case SHELL_EVENT_START_TIMEOUT: {
      bool visible = IsWindowVisible(window->hwnd) && !IsIconic(window->hwnd);
      if (project->sidebar) {
        visible = false;
        for (ShellWindow *item = shell.windows; item; item = item->next)
          visible |= !item->closing && IsWindowVisible(item->hwnd) && !IsIconic(item->hwnd);
      }
      if ((project->sidebar || project == window->selected) && project->state == SHELL_STARTING && visible)
        fail_connection(project, "startup deadline expired before the first frame");
      break;
    }
    case SHELL_EVENT_CONNECTED:
      handle_connected(project);
      break;
    case SHELL_EVENT_FRAME:
      if (project && project->sidebar) {
        handle_sidebar_frame(window);
        break;
      }
      if (project == window->selected)
        handle_frame(window);
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
              anvil_process_terminate(dialog->process, 125)) {
            project->intentional_exit = project->exit_announced = true;
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
      if (project->sidebar) {
        project->connected = false;
        stop_close_timer(project);
        set_state(project, SHELL_FAILED);
        SDL_Log("Shell Sidebar exited; Project and native controls remain available");
        schedule_sidebar_restart();
        break;
      }
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
      if (project->intentional_exit &&
          (project->exit_announced || (int)(intptr_t)event->user.data2 == 0)) {
        project->connected = false;
        project->failed_close = true;
        if (!project->unloading) {
          begin_window_close(window);
          if (project != window->selected)
            request_close(window->selected);
        }
        return SDL_APP_CONTINUE;
      }
      reset_unload(project);
      project->intentional_exit = false;
      project->failed_close = false;
      set_state(project, SHELL_FAILED);
      project->connected = false;
      if (project != window->selected)
        return SDL_APP_CONTINUE;
      cancel_input(window);
      SDL_Log("Project failed unexpectedly; retain shell for recovery");
      SDL_SetWindowTitle(window->window, "Anvil - Project failed");
      SDL_ShowWindow(window->window);
      window->shown = true;
      composite_and_present(window);
      return SDL_APP_CONTINUE;
    }
    return SDL_APP_CONTINUE;
  }

  if (event->type == SDL_EVENT_QUIT) {
    for (ShellWindow *item = shell.windows; item; item = item->next) {
      begin_window_close(item);
      request_close(item->selected);
    }
    return SDL_APP_CONTINUE;
  }
  SDL_Window *native = SDL_GetWindowFromEvent(event);
  if (!native) return SDL_APP_CONTINUE;
  HWND hwnd = (HWND)SDL_GetPointerProperty(SDL_GetWindowProperties(native),
                                          SDL_PROP_WINDOW_WIN32_HWND_POINTER, NULL);
  window = (ShellWindow *)GetPropW(hwnd, L"AnvilShellWindow");
  if (!window) return SDL_APP_CONTINUE;
  project = window->selected;
  check_gpu_failure(window);
  check_transport_failure(project);
  /* SDL points become physical client pixels only at this boundary. */
  int point_w, point_h;
  SDL_GetWindowSize(window->window, &point_w, &point_h);
  float sx = point_w > 0 ? (float)window->buffer_w / point_w : 1;
  float sy = point_h > 0 ? (float)window->buffer_h / point_h : 1;
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
  case SDL_EVENT_WINDOW_CLOSE_REQUESTED:
    begin_window_close(window);
    request_close(project);
    break;
  case SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED:
    update_scale(window);
    resize_step(window);
    break;
  /* WM_SIZE resizes and presents. These only keep the surface's window
   * bounds and mode current. */
  case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
  case SDL_EVENT_WINDOW_RESIZED:
  case SDL_EVENT_WINDOW_MOVED:
  case SDL_EVENT_WINDOW_MINIMIZED:
  case SDL_EVENT_WINDOW_MAXIMIZED:
  case SDL_EVENT_WINDOW_RESTORED:
    window->ui_dirty = true;
    send_configure(project);
    windows_changed();
    break;
  case SDL_EVENT_WINDOW_SHOWN:
  case SDL_EVENT_WINDOW_HIDDEN:
    window->shown = event->type == SDL_EVENT_WINDOW_SHOWN;
    if (!window->shown) cancel_input(window);
    send_configure(project);
    break;
  case SDL_EVENT_WINDOW_FOCUS_GAINED:
  case SDL_EVENT_WINDOW_FOCUS_LOST:
    if (event->type == SDL_EVENT_WINDOW_FOCUS_LOST)
      cancel_input(window);
    else {
      window->activated = ++shell.activation;
      windows_changed();
    }
    if (project->connected && !anvil_latency_probe_enabled()) {
      shell_send_int(project, ANVIL_SURFACE_MSG_FOCUS,
                     event->type == SDL_EVENT_WINDOW_FOCUS_GAINED);
    }
    break;
  case SDL_EVENT_WINDOW_MOUSE_LEAVE:
    leave_sidebar(window);
    window->hovered_control = -1;
    window->ui_hover_dirty = true;
    composite_and_present(window);
    if (!window->surface_buttons)
      leave_surface(window);
    break;
  case SDL_EVENT_KEY_DOWN:
  case SDL_EVENT_KEY_UP:
    anvil_latency_probe_note_event(event);
    if (project->state == SHELL_READY || project->state == SHELL_CLOSING)
      forward_event(window, event, NULL);
    break;
  case SDL_EVENT_TEXT_INPUT:
    if (project->state == SHELL_READY || project->state == SHELL_CLOSING)
      forward_event(window, event, event->text.text);
    break;
  case SDL_EVENT_TEXT_EDITING:
    if (project->state == SHELL_READY || project->state == SHELL_CLOSING)
      forward_event(window, event, event->edit.text);
    break;
  case SDL_EVENT_MOUSE_MOTION:
    route_motion(window, event);
    break;
  case SDL_EVENT_MOUSE_BUTTON_DOWN:
  case SDL_EVENT_MOUSE_BUTTON_UP:
    route_button(window, event);
    break;
  case SDL_EVENT_MOUSE_WHEEL:
    if (sidebar_takes_pointer(window, event->wheel.mouse_x)) {
      AnvilSurfaceInput input = {.event = *event,
                                 .configuration = window->sidebar_client->last_config.configuration};
      shell_send(window->sidebar_client, ANVIL_SURFACE_MSG_INPUT, &input, sizeof(input), NULL, 0);
    } else if (surface_contains(window, event->wheel.mouse_x, event->wheel.mouse_y) &&
        control_at(window, event->wheel.mouse_x, event->wheel.mouse_y) < 0 &&
        (project->state == SHELL_READY || project->state == SHELL_CLOSING)) {
      anvil_surface_translate_input(&project->last_config, event);
      forward_event(window, event, NULL);
    }
    break;
  case SDL_EVENT_DROP_BEGIN:
  case SDL_EVENT_DROP_COMPLETE:
    if (project->state == SHELL_READY || project->state == SHELL_CLOSING)
      forward_event(window, event, NULL);
    break;
  case SDL_EVENT_DROP_POSITION:
  case SDL_EVENT_DROP_FILE:
  case SDL_EVENT_DROP_TEXT:
    if (!surface_contains(window, event->drop.x, event->drop.y) ||
        control_at(window, event->drop.x, event->drop.y) >= 0 || project->state == SHELL_STARTING ||
        project->state == SHELL_FAILED || project->state == SHELL_DORMANT) {
      if (event->type == SDL_EVENT_DROP_POSITION && project->connected) {
        event->drop.x = event->drop.y = -1;
        forward_event(window, event, NULL);
      }
      break;
    }
    anvil_surface_translate_input(&project->last_config, event);
    forward_event(window, event, event->drop.data);
    break;
  default:
    break;
  }
  return SDL_APP_CONTINUE;
}

/* ------------------------------------------------------------------------ */
/* Native frame                                                             */

static void push_window_event(ShellWindow *window, SDL_EventType type, float x, float y) {
  SDL_Event event;
  SDL_zero(event);
  event.type = type;
  if (type == SDL_EVENT_MOUSE_MOTION) {
    event.motion.windowID = SDL_GetWindowID(window->window);
    event.motion.x = x;
    event.motion.y = y;
  } else {
    event.window.windowID = SDL_GetWindowID(window->window);
  }
  SDL_PushEvent(&event);
}

static LRESULT CALLBACK shell_service_wndproc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
  if (msg == WM_TIMER && shell.sidebar_process && shell.sidebar_process->startup_timer == wparam) {
    push_shell_event(shell.sidebar_process, SHELL_EVENT_START_TIMEOUT, NULL, 0);
    return 0;
  }
  if (msg == WM_APP + 0x51) { check_picker_failures(); return 0; }
  if (msg == SHELL_PICKER_MESSAGE) {
    probe_project_picker(wparam, lparam);
    return 0;
  }
  if (msg == WM_APP + 0x4e) {
    shell.sidebar_scan_requested = true;
    service_sidebar();
    return 0;
  }
  if (msg == WM_TIMER) {
    if (shell.sidebar_healthy_timer && wparam == shell.sidebar_healthy_timer) {
      KillTimer(shell.service_hwnd, shell.sidebar_healthy_timer);
      shell.sidebar_healthy_timer = 0;
      ShellProject *sidebar = shell.sidebar_process;
      if (sidebar && sidebar->connected && sidebar->state == SHELL_READY &&
          sidebar->connection == shell.sidebar_healthy_connection) {
        Uint64 elapsed = SDL_GetTicks() - shell.sidebar_healthy_since;
        if (elapsed < SHELL_SIDEBAR_HEALTHY_MS) {
          SDL_Log("Shell Sidebar recovery-budget timer arrived early: connection age=%llu ms",
                  (unsigned long long)elapsed);
          shell.sidebar_healthy_timer = SetTimer(shell.service_hwnd, 0x8004,
            (UINT)(SHELL_SIDEBAR_HEALTHY_MS - elapsed), NULL);
        } else {
          shell.sidebar_restart_attempts = 0;
          shell.sidebar_restart_limited = false;
          SDL_Log("Shell Sidebar stable connection restored its automatic recovery budget");
        }
      }
      return 0;
    }
    if (shell.sidebar_restart_timer && wparam == shell.sidebar_restart_timer) {
      KillTimer(shell.service_hwnd, shell.sidebar_restart_timer);
      shell.sidebar_restart_timer = 0;
      if (shell.sidebar_waiting_exit) {
        shell.sidebar_waiting_exit = false;
        schedule_sidebar_restart();
      } else {
        shell.sidebar_restart_attempts++;
        shell.sidebar_failure_since = 0;
        start_sidebar();
      }
      return 0;
    }
    if (shell.sidebar_timer && wparam == shell.sidebar_timer) {
      service_sidebar();
      return 0;
    }
    if (shell.retire_timer && wparam == shell.retire_timer) {
      drain_retired_projects();
      return 0;
    }
    if (shell.state_timer && wparam == shell.state_timer) {
      save_windows(false);
      return 0;
    }
    if (shell.restore_timer && wparam == shell.restore_timer) {
      advance_restore();
      return 0;
    }
    if (shell.resolve_timer && wparam == shell.resolve_timer) {
      finish_resolutions();
      return 0;
    }
  }
  return DefWindowProcW(hwnd, msg, wparam, lparam);
}

static LRESULT CALLBACK shell_wndproc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
  ShellWindow *window = (ShellWindow *)GetPropW(hwnd, L"AnvilShellWindow");
  if (!window)
    return DefWindowProcW(hwnd, msg, wparam, lparam);
  ShellProject *project = window->selected;
  if (msg == WM_TIMER) {
    ShellProject *timed = NULL;
    if (shell.sidebar_process && shell.sidebar_process->window_id == window->id &&
        shell.sidebar_process->startup_timer == wparam)
      timed = shell.sidebar_process;
    for (ShellProject *item = shell.projects; item; item = item->next)
      if (item->window_id == window->id && item->startup_timer && wparam == item->startup_timer) {
        timed = item;
        break;
      }
    if (!timed)
      return CallWindowProcW(window->sdl_wndproc, hwnd, msg, wparam, lparam);
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
  if (msg == SHELL_CAPTURE_MESSAGE && SDL_getenv("ANVIL_SURFACE_FAULT_PROBE")) {
    window->capture = (unsigned)wparam;
    composite_and_present(window);
    return 0;
  }
  if (msg == SHELL_FAULT_MESSAGE && SDL_getenv("ANVIL_SURFACE_FAULT_PROBE")) {
    SDL_Log("Shell fault probe armed: %u", (unsigned)wparam);
    if (wparam == FAULT_PIPE)
      fail_connection(project, "owned probe broke the pipe");
    else {
      SDL_SetAtomicInt(&probe_fault, (int)wparam);
      if (wparam == FAULT_OPEN) {
        SAFE_RELEASE(window->project_presentation.shared_mutex);
        SAFE_RELEASE(window->project_presentation.shared);
        close_memory_frame(&window->project_presentation);
      }
      if (wparam == FAULT_PRESENT)
        composite_and_present(window);
    }
    return 0;
  }
  if (msg == SHELL_CONTROL_MESSAGE) {
    /* Drive the native controls only in the isolated owned-window probe. */
    const char *probe = SDL_getenv("ANVIL_SURFACE_FAULT_PROBE");
    if (probe && !strcmp(probe, "1") && wparam <= 5)
      perform_control(window, (int)wparam);
    return 0;
  }
  if (msg == SHELL_MODEL_MESSAGE) {
    const char *probe = SDL_getenv("ANVIL_SURFACE_FAULT_PROBE");
    if (probe && !strcmp(probe, "1"))
      probe_sidebar_model(window, wparam, lparam);
    return 0;
  }
  if (anvil_routing_probe_message(window->window, msg, wparam, lparam)) return 0;
  switch (msg) {
    case WM_NCDESTROY:
      RemovePropW(hwnd, L"AnvilShellWindow");
      break;
    case WM_SYSCOMMAND:
      if ((wparam & 0xfff0) == SHELL_MENU_NEW_WINDOW) {
        if (!window->closing && !create_window(NULL)) window_notice(window, "Cannot create a Window.");
        return 0;
      }
      if ((wparam & 0xfff0) == SHELL_MENU_OPEN_PROJECT) {
        show_project_picker(window);
        return 0;
      }
      break;
    case WM_KILLFOCUS:
      cancel_input(window);
      shell_send_int(project, ANVIL_SURFACE_MSG_FOCUS, 0);
      break;
    case WM_CANCELMODE:
      cancel_input(window);
      break;
    case WM_MOUSEMOVE:
      if (window->pressed_control >= 0) {
        SDL_Event event = {0};
        event.type = SDL_EVENT_MOUSE_MOTION;
        event.motion.x = (float)GET_X_LPARAM(lparam);
        event.motion.y = (float)GET_Y_LPARAM(lparam);
        route_motion(window, &event);
        return 0;
      }
      break;
    case WM_LBUTTONDOWN:
    case WM_LBUTTONDBLCLK:
    case WM_LBUTTONUP: {
      float x = (float)GET_X_LPARAM(lparam);
      float y = (float)GET_Y_LPARAM(lparam);
      bool down = msg != WM_LBUTTONUP;
      if (!window->surface_buttons &&
          (window->pressed_control >= 0 || (down && control_at(window, x, y) >= 0))) {
        /* Handle native controls before SDL releases automatic capture.
         * Do not also queue this click through SDL. */
        SDL_Event event = {0};
        event.type = msg == WM_LBUTTONUP ? SDL_EVENT_MOUSE_BUTTON_UP : SDL_EVENT_MOUSE_BUTTON_DOWN;
        event.button.button = SDL_BUTTON_LEFT;
        event.button.x = x;
        event.button.y = y;
        route_button(window, &event);
        return 0;
      }
      break;
    }
    case WM_CAPTURECHANGED:
      if ((HWND)lparam != hwnd && (window->pressed_control >= 0 || window->surface_buttons)) {
        SDL_Log("Shell native control cancelled: capture changed");
        cancel_input(window);
        window->ui_hover_dirty = true;
        if (window->shown) composite_and_present(window);
      }
      break;
    case WM_NCCALCSIZE:
      return win32_frame_hwnd_nccalcsize(hwnd, wparam, lparam);

    case WM_NCHITTEST: {
      Win32FrameHitTest hit = {
          .title_height = SDL_max(window->controls.bottom, project->hit.title_height),
          .controls_width = window->controls.right - window->controls.left,
          .resize_border = project->last_config.resize_border > 0
                               ? project->last_config.resize_border
                               : (int)(8 * window->scale),
          .client_x = project->hit.client_x,
          .client_width = project->hit.client_width,
          .client2_x = project->hit.client2_x,
          .client2_width = project->hit.client2_width,
          .content_x = project->last_config.origin_x,
      };
      LRESULT result = win32_frame_hwnd_hit_test(hwnd, &hit, lparam);
      POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      ScreenToClient(hwnd, &point);
      if (result == HTCAPTION && point.x >= 0 && point.x < window->sidebar_w && sidebar_restart_offered())
        return HTCLIENT;
      return result;
    }

    case WM_GETMINMAXINFO:
      CallWindowProcW(window->sdl_wndproc, hwnd, msg, wparam, lparam);
      win32_frame_hwnd_apply_work_area(hwnd, (MINMAXINFO *)lparam);
      return 0;

    case WM_NCACTIVATE:
      /* SDL tracks keyboard focus from this message; the frame is drawn by
       * the surface, so suppress the default non-client repaint. */
      CallWindowProcW(window->sdl_wndproc, hwnd, msg, wparam, lparam);
      return TRUE;

    case WM_ERASEBKGND:
      return 1;

    case WM_ENTERSIZEMOVE:
    case WM_EXITSIZEMOVE: {
      LRESULT result = CallWindowProcW(window->sdl_wndproc, hwnd, msg, wparam, lparam);
      window->live_resize = msg == WM_ENTERSIZEMOVE;
      send_configure(project);
      return result;
    }

    case WM_SIZE: {
      LRESULT result = CallWindowProcW(window->sdl_wndproc, hwnd, msg, wparam, lparam);
      if (wparam != SIZE_MINIMIZED && window->swapchain) resize_step(window);
      else if (window->render_failed) InvalidateRect(hwnd, NULL, FALSE);
      return result;
    }

    case WM_PAINT: {
      if (window->render_failed) {
        PAINTSTRUCT paint;
        HDC dc = BeginPaint(hwnd, &paint);
        paint_failed_window(window, dc);
        EndPaint(hwnd, &paint);
        return 0;
      }
      LRESULT result = CallWindowProcW(window->sdl_wndproc, hwnd, msg, wparam, lparam);
      if (window->shown) composite_and_present(window);
      return result;
    }

    case WM_NCMOUSEMOVE: {
      /* Title Bar caption areas are non-client, but the surface draws hover
       * state there. */
      POINT pt = { GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam) };
      ScreenToClient(hwnd, &pt);
      push_window_event(window, SDL_EVENT_MOUSE_MOTION, (float)pt.x, (float)pt.y);
      TRACKMOUSEEVENT tme = { sizeof(tme), TME_LEAVE | TME_NONCLIENT, hwnd, HOVER_DEFAULT };
      TrackMouseEvent(&tme);
      break;
    }

    case WM_NCMOUSELEAVE:
      push_window_event(window, SDL_EVENT_WINDOW_MOUSE_LEAVE, 0, 0);
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
      win32_frame_hwnd_update_dwm(hwnd, true, &(COLORREF){window->background & 0xffffff});
      break;
  }
  return CallWindowProcW(window->sdl_wndproc, hwnd, msg, wparam, lparam);
}

static bool install_native_frame(ShellWindow *window) {
  window->hwnd = (HWND)SDL_GetPointerProperty(SDL_GetWindowProperties(window->window),
                                            SDL_PROP_WINDOW_WIN32_HWND_POINTER, NULL);
  if (!window->hwnd) return false;
  SDL_Log("Shell window hwnd=%p", (void *)window->hwnd);
  SDL_Log("Shell Window record: id=%u SDL=%u hwnd=%p", window->id,
          SDL_GetWindowID(window->window), (void *)window->hwnd);
  window->sdl_wndproc = (WNDPROC)GetWindowLongPtrW(window->hwnd, GWLP_WNDPROC);
  if (!SetPropW(window->hwnd, L"AnvilShellWindow", window))
    return false;
  SetWindowLongPtrW(window->hwnd, GWLP_WNDPROC, (LONG_PTR)shell_wndproc);
  HMENU menu = GetSystemMenu(window->hwnd, FALSE);
  if (!menu || !AppendMenuW(menu, MF_SEPARATOR, 0, NULL) ||
      !AppendMenuW(menu, MF_STRING, SHELL_MENU_NEW_WINDOW, L"New Window") ||
      !AppendMenuW(menu, MF_STRING, SHELL_MENU_OPEN_PROJECT, L"Open Project..."))
    return false;
  win32_frame_hwnd_apply_style(window->hwnd, false);
  return true;
}

/* ------------------------------------------------------------------------ */
/* Lifecycle                                                                */

static void set_window_icon(ShellWindow *window) {
  #include "../resources/icons/icon.inl"
  (void)icon_rgba_len;
  SDL_PixelFormat format = SDL_GetPixelFormatForMasks(32, 0x000000ff, 0x0000ff00, 0x00ff0000, 0xff000000);
  SDL_Surface *surface = SDL_CreateSurfaceFrom(64, 64, format, icon_rgba, 64 * 4);
  SDL_SetWindowIcon(window->window, surface);
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
  Uint32 window_id;
  SDL_Thread *thread;
  SDL_AtomicInt done;
  unsigned revision;
  uint64_t close_generation;
  bool initial, success, unload, new_window;
  /* A launch has no requesting Window. It comes from another process, or from the shell's own arguments
   * after a restore. */
  bool launch;
  /* An external launch has no requesting Window. It replies once its Project is selected or started. */
  AnvilShellLaunchRequest *external;
  /* A restored Window's initial resolution names its Project, because the Window's selection can change first. */
  Uint32 project_id;
  bool restored;
  int argc;
  char **argv;
  char *path;
  wchar_t *identity;
  DWORD error;
};

static void free_resolution(ProjectResolve *job) {
  if (job->external) anvil_shell_launch_finish(job->external, ANVIL_SHELL_LAUNCH_BUSY);
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

static bool queue_resolution(ShellWindow *window, const char *path, int argc, char **argv,
                             bool initial, bool unload, bool new_window, AnvilShellLaunchRequest *external) {
  unsigned pending = 0;
  for (ProjectResolve *item = shell.resolvers; item; item = item->next)
    pending++;
  /* A restore resolves every saved Window and adopted Project at once. */
  if (pending >= (initial ? ANVIL_SHELL_STATE_MAX_WINDOWS + ANVIL_ADOPTION_MAX_RECORDS + 8 : 8)) {
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
  job->window_id = window ? window->id : 0;
  job->close_generation = window ? window->close_generation : 0;
  job->unload = unload;
  job->new_window = new_window;
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
    shell.resolve_timer = SetTimer(shell.service_hwnd, 0x8000, 100, NULL);
  if (!shell.resolve_timer) {
    free_resolution(job);
    SDL_Log("Shell rejected Project selection: identity timer failed");
    return false;
  }
  /* Only a selection replaces the Window's earlier pending selection. Unload and New Window requests do not. */
  job->revision = window ? window->resolve_revision + (unload || new_window ? 0 : 1) : 0;
  job->thread =
      SDL_CreateThread(resolve_project_thread, "anvil-project-identity", job);
  if (!job->thread) {
    free_resolution(job);
    SDL_Log("Shell rejected Project selection: identity worker failed");
    return false;
  }
  if (window) window->resolve_revision = job->revision;
  job->external = external;
  job->launch = !window && !initial;
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
      if (project->launch->process.hThread) CloseHandle(project->launch->process.hThread);
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
  ShellWindow *window = window_for_id(project->window_id);
  if (!window) return false;
  reset_unload(project);
  project->exit_announced = false;
  /* Replacement starts only after the old process exited. Join cancelled transport users first. */
  if (project->process.hProcess || project->launcher || project->launch || project->reader ||
      project->writer || project->pipe.handle) {
    if (project == window->selected) {
      cancel_input(window);
      SDL_StopTextInput(window->window);
    }
    project->text_active = false;
    project->connected = false;
    if (!stop_transport(project, SDL_GetTicks() + 1000)) {
      SDL_Log("Shell transport cleanup exceeded its deadline");
      return false;
    }
    anvil_ipc_pipe_close(&project->pipe);
    if (project == window->selected) {
      SAFE_RELEASE(window->project_presentation.shared_mutex);
      SAFE_RELEASE(window->project_presentation.shared);
      window->project_presentation.shared_name[0] = 0;
      close_memory_frame(&window->project_presentation);
    }
    /* An adopted Project has no primary thread handle. */
    if (project->process.hThread) CloseHandle(project->process.hThread);
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
    if (project == window->selected)
      window->project_presentation.have_surface = false;
    project->close_requested_ns = 0;
    stop_close_timer(project);
    project->close_serial++;
    project->close_prompt = false;
    discard_deferred_dialogs(project);
    memset(project->dialogs, 0, sizeof(project->dialogs));
    project->last_config = (AnvilSurfaceConfigure){0};
    if (project == window->selected) {
      window->surface_buttons = 0;
      window->pointer_in_surface = false;
      SDL_ClearComposition(window->window);
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
  window->ui_dirty = true;
  project->failed_close = false;
  if (project == window->selected)
    window->hovered_control = window->pressed_control = -1;
  char pipe_name[128];
  if (!create_pipe(project, pipe_name, sizeof(pipe_name)) ||
      !launch_child(project, argc, argv, pipe_name))
    return false;
  project->startup_timer =
      SetTimer(project->sidebar ? shell.service_hwnd : window->hwnd, 0x10000u + project->connection, SHELL_CONNECT_TIMEOUT_MS, NULL);
  if (!project->startup_timer) {
    fail_connection(project, "Project launch timer setup failed");
    return false;
  }
  return true;
}

static void finish_launch(ShellProject *project) {
  ShellWindow *window = window_for_id(project->window_id);
  if (!window) return;
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
    KillTimer(window->hwnd, project->startup_timer);
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
  ShellWindow *window = window_for_id(project->window_id);
  if (!window) return;
  if (project == window->selected)
    return;
  ShellProject *previous = window->selected;
  windows_changed();
  cancel_input(window);
  if (previous->connected)
    shell_send_int(previous, ANVIL_SURFACE_MSG_FOCUS, 0);
  SDL_ClearComposition(window->window);
  SDL_StopTextInput(window->window);
  set_surface_busy(window, &window->project_presentation, false);
  SAFE_RELEASE(window->project_presentation.shared_mutex);
  SAFE_RELEASE(window->project_presentation.shared);
  window->project_presentation.shared_name[0] = 0;
  close_memory_frame(&window->project_presentation);
  window->project_presentation.have_surface = false;
  window->selected = project;
  window->resize_wait_disabled = false;
  window->ui_dirty = true;
  window->hovered_control = window->pressed_control = -1;
  SDL_SetWindowTitle(window->window, project->title ? project->title :
                     project->id ? "Anvil - Starting Project" : "Anvil - No Project selected");
  send_configure(previous);
  send_configure(project);
  if (project->connected)
    shell_send_int(project, ANVIL_SURFACE_MSG_FOCUS,
        !IsIconic(window->hwnd) &&
        (anvil_latency_probe_enabled() || (SDL_GetWindowFlags(window->window) & SDL_WINDOW_INPUT_FOCUS) != 0));
  if (project->text_active && !IsIconic(window->hwnd) &&
      (SDL_GetWindowFlags(window->window) & SDL_WINDOW_INPUT_FOCUS))
    SDL_StartTextInput(window->window);
  apply_cursor(project->child_cursor);
  present_deferred_dialogs(project);
  SDL_Log("Shell selected loaded Project: id=%u pid=%lu path=%s", project->id,
          (unsigned long)project->process.dwProcessId, project->project_path);
  composite_and_present(window);
}

static bool project_has_dialog(const ShellProject *project) {
  for (size_t i = 0; i < SDL_arraysize(project->dialogs); i++)
    if (project->dialogs[i] || project->deferred_dialogs[i]) return true;
  return false;
}
static void move_project(ShellWindow *requester, uint32_t project_id, uint32_t target_id) {
  ShellProject *project = NULL;
  for (ShellProject *item = shell.projects; item; item = item->next)
    if (item->id == project_id) { project = item; break; }
  ShellWindow *source = project ? window_for_id(project->window_id) : NULL;
  ShellWindow *target = window_for_id(target_id);
  if (!source || !target || source->removing || target->removing) {
    window_notice(requester, "Cannot move Project: Project or target Window is unavailable.");
    return;
  }
  if (requester->closing || source->closing || target->closing || project->close_requested_ns || project->close_waiting ||
      project->close_prompt || project->unloading || target->selected->close_requested_ns ||
      target->selected->close_waiting || target->selected->close_prompt) {
    window_notice(requester, "Cannot move Project during a pending Close choice.");
    return;
  }
  if (project_has_dialog(project) || project_has_dialog(target->selected) ||
      source->picker_pending || target->picker_pending) {
    window_notice(requester, "Cannot move Project while a native file dialog is open.");
    return;
  }
  if (!project->connected || project->state != SHELL_READY || project->resolving ||
      (project->launch && !project->launch->taken)) {
    window_notice(requester, "Cannot move Project until it is Ready.");
    return;
  }
  if (source == target) return;
  retain_project(project);
  /* Revoke the old surface before changing ownership. Keep the Project retained during native callbacks. */
  if (source->selected == project) {
    ShellProject *replacement = source->empty;
    for (ShellProject *item = shell.projects; item; item = item->next)
      if (item != project && item->window_id == source->id && !item->unloading && !item->failed_close) {
        replacement = item; break;
      }
    select_project(replacement);
  } else {
    shell_send_int(project, ANVIL_SURFACE_MSG_FOCUS, 0);
    send_configure(project);
  }
  project->window_id = target->id;
  /* Window identity is part of layout identity, even for equal-sized targets. */
  select_project(project);
  requester->notice[0] = 0;
  requester->ui_dirty = true;
  sync_sidebar_model();
  notify_sidebar_changes();
  SDL_Log("Shell moved Project: id=%u pid=%lu source=%u target=%u configuration=%llu", project->id,
          (unsigned long)project->process.dwProcessId, source->id, target->id,
          (unsigned long long)project->last_config.configuration);
  release_project(project);
}
static bool select_project_path(ShellWindow *window, const char *path) {
  if (window->closing || !path || !*path)
    return false;
  return queue_resolution(window, path, 0, NULL, false, false, false, NULL);
}

static bool unload_project_path(ShellWindow *window, const char *path) {
  if (window->closing || !path || !*path)
    return false;
  return queue_resolution(window, path, 0, NULL, false, true, false, NULL);
}
static bool open_project_window(ShellWindow *window, const char *path) {
  if (window->closing || !path || !*path) return false;
  if (!queue_resolution(window, path, 0, NULL, false, false, true, NULL)) {
    window_notice(window, "Cannot submit the Open Project request.");
    return false;
  }
  window->notice[0] = 0;
  window->ui_dirty = true;
  return true;
}

static void begin_unload(ShellProject *project) {
  ShellWindow *window = window_for_id(project->window_id);
  if (!window) return;
  if (project->unloading)
    return;
  if (!project->identity || !project->project_path) {
    begin_window_close(window);
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

static ShellProject *loaded_project(const wchar_t *identity) {
  for (ShellProject *item = shell.projects; item; item = item->next)
    if (item->identity && CompareStringOrdinal(item->identity, -1, identity, -1, TRUE) == CSTR_EQUAL)
      return item;
  return NULL;
}

/* Takes the resolved path and identity, and the Dormant record's Project id when one matches. */
static void assign_identity(ShellProject *project, ProjectResolve *job) {
  DormantProject **dormant_link = &shell.dormants;
  while (*dormant_link && CompareStringOrdinal((*dormant_link)->identity, -1, job->identity, -1,
                                               TRUE) != CSTR_EQUAL)
    dormant_link = &(*dormant_link)->next;
  DormantProject *dormant = *dormant_link;
  free(project->project_path);
  free(project->identity);
  project->project_path = job->path;
  job->path = NULL;
  project->identity = job->identity;
  job->identity = NULL;
  windows_changed();
  if (dormant) {
    project->id = dormant->id;
    *dormant_link = dormant->next;
    free(dormant->path);
    free(dormant->identity);
    free(dormant->title);
    free(dormant);
  }
}

static void raise_owner(ShellProject *project) {
  ShellWindow *owner = window_for_id(project->window_id);
  if (!owner || owner->closing) return;
  SDL_ShowWindow(owner->window);
  if (IsIconic(owner->hwnd)) SDL_RestoreWindow(owner->window);
  owner->shown = true;
  send_configure(project);
  SDL_RaiseWindow(owner->window);
}

/* An external launch selects its loaded Project, or starts it in a new Window. */
static void finish_external(ProjectResolve *job) {
  AnvilShellLaunchRequest *request = job->external;
  job->external = NULL;
  unsigned long client = request ? anvil_shell_launch_client_pid(request) : GetCurrentProcessId();
  ShellProject *project = job->success ? loaded_project(job->identity) : NULL;
  ShellWindow *owner = project ? window_for_id(project->window_id) : NULL;
  AnvilShellLaunchStatus status = ANVIL_SHELL_LAUNCH_ACCEPTED;
  if (shell.shutting_down) {
    status = ANVIL_SHELL_LAUNCH_BUSY;
  } else if (!job->success) {
    SDL_Log("Shell external launch identity failed: pid=%lu Windows error=%lu", client, (unsigned long)job->error);
    status = ANVIL_SHELL_LAUNCH_REJECTED;
  } else if (project && (!owner || owner->closing)) {
    SDL_Log("Shell external launch waits for its Project's Window Close: pid=%lu Project=%u", client, project->id);
    status = ANVIL_SHELL_LAUNCH_BUSY;
  } else if (project) {
    SDL_Log("Shell external launch selects loaded Project: pid=%lu Project=%u Window=%u", client, project->id,
            owner->id);
    if (project->restore_waiting) project->restore_rank = -1;
    select_project(project);
  } else if (!sidebar_project(job->path)) {
    SDL_Log("Shell external launch rejected: Project Sidebar list is full or allocation failed");
    status = ANVIL_SHELL_LAUNCH_REJECTED;
  } else if (!(owner = create_window(NULL)) || !(project = new_project(owner))) {
    SDL_Log("Shell external launch rejected: Window or runtime allocation failed");
    if (owner) destroy_window(owner);
    status = ANVIL_SHELL_LAUNCH_REJECTED;
  } else {
    assign_identity(project, job);
    select_project(project);
    SDL_Log("Shell external launch starts Project: pid=%lu Project=%u Window=%u", client, project->id, owner->id);
    if (!start_project(project, job->argc, job->argv)) fail_connection(project, "External launch startup failed");
  }
  if (status == ANVIL_SHELL_LAUNCH_ACCEPTED) {
    /* Windows decides whether the raise takes the foreground. Without the launcher's grant it may only flash. */
    SDL_Log("Shell external launch raise: foreground grant=%d",
            request ? anvil_shell_launch_foreground_granted(request) : 1);
    raise_owner(project);
  }
  if (request) anvil_shell_launch_finish(request, status);
}

static bool initial_resolution_pending(void) {
  for (ProjectResolve *item = shell.resolvers; item; item = item->next)
    if (item->initial) return true;
  return false;
}

static void finish_resolutions(void) {
  ProjectResolve **link = &shell.resolvers;
  while (*link) {
    ProjectResolve *job = *link;
    /* The first Project has no identity until its resolution finishes. A launch waits so it cannot duplicate it. */
    if (!SDL_GetAtomicInt(&job->done) || (job->launch && initial_resolution_pending())) {
      link = &job->next;
      continue;
    }
    if (job->thread)
      SDL_WaitThread(job->thread, NULL);
    *link = job->next;
    if (job->launch) {
      finish_external(job);
      free_resolution(job);
      continue;
    }
    ShellWindow *window = window_for_id(job->window_id);
    if (!window) {
      free_resolution(job);
      continue;
    }
    ShellProject *project = job->initial ? window->selected : NULL;
    if (job->project_id) {
      project = NULL;
      for (ShellProject *item = shell.projects; item; item = item->next)
        if (item->id == job->project_id) project = item;
      if (!project) {
        free_resolution(job);
        continue;
      }
    }
    if (job->initial)
      project->resolving = false;
    if (job->initial && window->closing) {
      project->failed_close = true;
    } else if (!job->initial && (window->closing || job->close_generation != window->close_generation)) {
      SDL_Log("Shell discarded Project identity result after its requesting Window began Close: Window=%u", job->window_id);
    } else if (!job->success) {
      SDL_Log("Shell rejected Project identity: Windows error=%lu",
              (unsigned long)job->error);
      if (job->restored) {
        /* The Window stays, empty. Its Project Sidebar entry comes from recent Projects and stays too. */
        SDL_Log("Shell restored Window has no Project: Window=%u path=%s", window->id, job->path);
        project->restore_waiting = false;
        retire_failed_placeholder(project);
        window_notice(window, "Cannot restore this Window's Project. Its folder was not found.");
      } else if (job->initial)
        fail_connection(project, "Initial Project identity resolution failed");
      else window_notice(window, "Cannot open Project. Check the directory path.");
    } else if (job->initial ||
               (!window->closing && (job->new_window || job->unload || job->revision == window->resolve_revision))) {
      if (!job->initial) project = loaded_project(job->identity);
      if (job->unload) {
        if (project)
          begin_unload(project);
        free_resolution(job);
        continue;
      }
      ShellProject *existing = job->restored ? loaded_project(job->identity) : NULL;
      if (existing && existing != project) {
        /* Two saved entries name one Project. Keep the adopted runtime; neither has started yet. */
        bool keep_this = project->adopt_pid && !existing->adopt_pid;
        ShellProject *duplicate = keep_this ? existing : project;
        ShellProject *kept = keep_this ? project : existing;
        SDL_Log("Shell restored one Project twice; keep Project=%u and drop Project=%u", kept->id, duplicate->id);
        duplicate->restore_waiting = false;
        ShellWindow *duplicate_window = window_for_id(duplicate->window_id);
        bool selected = duplicate_window && duplicate_window->selected == duplicate;
        retire_failed_placeholder(duplicate);
        if (selected && kept->window_id == duplicate_window->id) select_project(kept);
        if (!keep_this) {
          free_resolution(job);
          continue;
        }
      }
      if (project && !job->initial) {
        ShellWindow *owner = window_for_id(project->window_id);
        if (!owner || owner->closing) {
          window_notice(window, "That Project's Window is closing. Wait for its Close decision.");
          free_resolution(job);
          continue;
        }
      }
      bool created = job->initial || !project;
      /* Reserve a list entry before creating another runtime. Every runtime
       * can then become Dormant without dropping another Dormant record. */
      if (!project && !sidebar_project(job->path)) {
        SDL_Log(
            "Shell rejected Project selection: Project Sidebar list is full or allocation failed");
        free_resolution(job);
        continue;
      }
      if (!project && job->new_window) {
        window = create_window(NULL);
        if (!window) {
          ShellWindow *requester = window_for_id(job->window_id);
          if (requester) window_notice(requester, "Cannot create the Project's Window.");
          free_resolution(job);
          continue;
        }
      }
      if (!project)
        project = new_project(window);
      if (!project)
        window_notice(window, "Cannot load Project: runtime allocation failed.");
      else {
        if (created) assign_identity(project, job);
        /* The user may have selected another Project in a restored Window while this one resolved. */
        if (!job->restored || window->selected == project) select_project(project);
        if (!job->initial) raise_owner(project);
        if (created || (project->failed_close && project->process.hProcess &&
                        WaitForSingleObject(project->process.hProcess, 0) ==
                            WAIT_OBJECT_0)) {
          if (project->restore_waiting) {
            /* The restore sequence starts it. */
          } else if (!start_project(project, job->initial ? job->argc : 0,
                                    job->initial ? job->argv : NULL))
            fail_connection(project, "Project selection startup failed");
        }
      }
    }
    free_resolution(job);
  }
  if (!shell.resolvers && shell.resolve_timer) {
    KillTimer(shell.service_hwnd, shell.resolve_timer);
    shell.resolve_timer = 0;
  }
}

static void complete_unload(ShellProject *project) {
  ShellWindow *window = window_for_id(project->window_id);
  if (!window) return;
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
  if (window->selected == project) {
    ShellProject *next = NULL;
    for (ShellProject *item = shell.projects; item; item = item->next)
      if (item->window_id == window->id) { next = item; break; }
    if (next)
      select_project(next);
    else {
      free(window->empty->project_path);
      window->empty->project_path = _strdup(dormant->path);
      select_project(window->empty);
      SDL_SetWindowTitle(window->window, "Anvil - Dormant Project");
    }
  }
  project->connected = false;
  stop_close_timer(project);
  if (project->startup_timer)
    KillTimer(window->hwnd, project->startup_timer);
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
    shell.retire_timer = SetTimer(shell.service_hwnd, 0x8001, 100, NULL);
  SDL_Log("Shell Project is Dormant: id=%u path=%s", dormant->id, dormant->path);
}

static void retire_failed_placeholder(ShellProject *project) {
  ShellWindow *window = window_for_id(project->window_id);
  if (window && window->selected == project) select_project(window->empty);
  ShellProject **link = &shell.projects;
  while (*link != project) link = &(*link)->next;
  *link = project->next;
  stop_close_timer(project);
  if (window && project->startup_timer) KillTimer(window->hwnd, project->startup_timer);
  project->startup_timer = 0;
  discard_deferred_dialogs(project);
  anvil_ipc_pipe_cancel(&project->pipe);
  SDL_LockMutex(project->lock);
  project->writer_stop = true;
  SDL_BroadcastCondition(project->queue_cond);
  SDL_UnlockMutex(project->lock);
  project->next = shell.retiring;
  shell.retiring = project;
  if (!shell.retire_timer) shell.retire_timer = SetTimer(shell.service_hwnd, 0x8001, 100, NULL);
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
    if (SDL_GetAtomicInt(&project->references) != 1) {
      link = &project->next;
      continue;
    }
    *link = project->next;
    release_project(project);
  }
  if (!shell.retiring && shell.retire_timer) {
    KillTimer(shell.service_hwnd, shell.retire_timer);
    shell.retire_timer = 0;
  }
}

static AnvilSidebarProject *sidebar_project(const char *path) {
  AnvilSidebarProject *row = anvil_sidebar_find(&shell.sidebar, path);
  if (!row) {
    if (!anvil_sidebar_merge_recents(&shell.sidebar, &path, 1)) {
      SDL_Log("Shell Project Sidebar rejected a path: list bound or allocation failure");
      return NULL;
    }
    row = anvil_sidebar_find(&shell.sidebar, path);
  }
  return row;
}
static void sync_sidebar_model(void) {
  AnvilSidebarWindow windows[ANVIL_SIDEBAR_WINDOW_LIMIT];
  size_t count = 0;
  for (ShellWindow *window = shell.windows; window; window = window->next) {
    if (window->removing) continue;
    windows[count++] = (AnvilSidebarWindow){window->id, window->selected ? window->selected->id : 0};
  }
  anvil_sidebar_set_windows(&shell.sidebar, windows, count);
  for (ShellProject *project = shell.projects; project; project = project->next) {
    if (!project->project_path)
      continue;
    AnvilSidebarProject *row = sidebar_project(project->project_path);
    if (!row)
      continue;
    bool live = project->process.hProcess &&
                WaitForSingleObject(project->process.hProcess, 0) == WAIT_TIMEOUT;
    bool deferred = false;
    for (size_t i = 0; i < SDL_arraysize(project->deferred_dialogs); i++)
      deferred |= project->deferred_dialogs[i] != NULL;
    const AnvilSidebarState states[] = {ANVIL_SIDEBAR_STARTING, ANVIL_SIDEBAR_READY,
                                        ANVIL_SIDEBAR_CLOSING, ANVIL_SIDEBAR_FAILED,
                                        ANVIL_SIDEBAR_DORMANT};
    AnvilSidebarState state = states[project->state];
    if (project->failed_close && !live && !project->unloading)
      state = ANVIL_SIDEBAR_DORMANT;
    anvil_sidebar_set_runtime(&shell.sidebar, row, project->id,
                              live ? project->process.dwProcessId : 0,
                              state == ANVIL_SIDEBAR_DORMANT ? 0 : project->window_id, state,
                              window_for_id(project->window_id) && project == window_for_id(project->window_id)->selected &&
                              state != ANVIL_SIDEBAR_DORMANT, deferred,
                              live && (project->close_waiting || project->close_prompt));
  }
  for (DormantProject *project = shell.dormants; project; project = project->next) {
    AnvilSidebarProject *row = anvil_sidebar_find(&shell.sidebar, project->path);
    if (row)
      anvil_sidebar_set_runtime(&shell.sidebar, row, project->id, 0, 0, ANVIL_SIDEBAR_DORMANT, false,
                                false, false);
  }
}
static void sidebar_source(const AnvilSurfaceSidebarSource *source, uint32_t size) {
  (void)size; /* The reader checked both complete strings. */
  const char *directory = (const char *)(source + 1), *recents = directory + source->userdir_size;
  if (shell.sidebar_recents && !strcmp(shell.sidebar_recents, recents) && shell.sidebar_userdir &&
      !strcmp(shell.sidebar_userdir, directory))
    return;
  if (shell.sidebar_userdir && strcmp(shell.sidebar_userdir, directory)) {
    SDL_Log("Shell rejected a Project Sidebar source from another user directory");
    return;
  }
  char *directory_copy = _strdup(directory), *source_copy = _strdup(recents);
  if (!directory_copy || !source_copy) {
    free(directory_copy);
    free(source_copy);
    SDL_Log("Shell rejected Project Sidebar source: allocation failed");
    return;
  }
  free(shell.sidebar_userdir);
  free(shell.sidebar_recents);
  shell.sidebar_userdir = directory_copy;
  shell.sidebar_recents = source_copy;
  shell.sidebar_source_revision++;
  if (!shell.sidebar_watch) {
    shell.sidebar_watch = anvil_sidebar_watch_start(directory_copy, shell.service_hwnd, WM_APP + 0x4e);
    if (!shell.sidebar_watch) SDL_Log("Sidebar registry watcher unavailable; use explicit Refresh");
  }
  shell.sidebar_scan_requested = true;
  service_sidebar();
  if (!shell.sidebar_process)
    start_sidebar();
}
static ShellWindow *sidebar_service_window(void) {
  ShellWindow *window = window_for_id(shell.sidebar_window_id);
  if (!window || window->closing) {
    window = shell.windows;
    while (window && window->closing) window = window->next;
    shell.sidebar_window_id = window ? window->id : 0;
    if (shell.sidebar_process) shell.sidebar_process->window_id = shell.sidebar_window_id;
  }
  return window;
}
static void schedule_sidebar_restart(void) {
  ShellWindow *window = sidebar_service_window();
  ShellProject *project = shell.sidebar_process;
  if (!window || window->closing || shell.shutting_down || shell.sidebar_restart_timer || !project || project->state != SHELL_FAILED ||
      (project->launch && !project->launch->taken))
    return;
  if (shell.sidebar_healthy_timer) KillTimer(shell.service_hwnd, shell.sidebar_healthy_timer);
  shell.sidebar_healthy_timer = 0;
  if (project->process.hProcess && WaitForSingleObject(project->process.hProcess, 0) != WAIT_OBJECT_0) {
    if (!shell.sidebar_failure_since) shell.sidebar_failure_since = SDL_GetTicks();
    if (SDL_GetTicks() - shell.sidebar_failure_since < SHELL_CONNECT_TIMEOUT_MS) {
      shell.sidebar_waiting_exit = true;
      shell.sidebar_restart_timer = SetTimer(shell.service_hwnd, 0x8003, 100, NULL);
    }
    return;
  }
  const unsigned delays[] = {100, 500, 2000};
  if (shell.sidebar_restart_attempts >= SDL_arraysize(delays)) {
    if (!shell.sidebar_restart_limited)
      SDL_Log("Shell Sidebar automatic restart limit reached; use Restart Sidebar");
    shell.sidebar_restart_limited = true;
    return;
  }
  shell.sidebar_restart_timer = SetTimer(shell.service_hwnd, 0x8003, delays[shell.sidebar_restart_attempts], NULL);
  shell.sidebar_waiting_exit = false;
  SDL_Log("Shell Sidebar automatic restart scheduled: attempt=%u", shell.sidebar_restart_attempts + 1);
}
static void start_sidebar(void) {
  ShellWindow *window = sidebar_service_window();
  if (shell.sidebar_healthy_timer) KillTimer(shell.service_hwnd, shell.sidebar_healthy_timer);
  shell.sidebar_healthy_timer = 0;
  if (!window || window->closing || shell.shutting_down || !shell.sidebar_userdir)
    return;
  ShellProject *old = shell.sidebar_process;
  if (old) {
    if (old->launch && !old->launch->taken) {
      SDL_Log("Shell Sidebar Restart waits for the pending launch");
      return;
    }
    old->connected = false;
    if (old->startup_timer)
      KillTimer(shell.service_hwnd, old->startup_timer);
    old->startup_timer = 0;
    anvil_ipc_pipe_cancel(&old->pipe);
    SDL_LockMutex(old->lock);
    old->writer_stop = true;
    SDL_BroadcastCondition(old->queue_cond);
    SDL_UnlockMutex(old->lock);
    old->next = shell.retiring;
    shell.retiring = old;
    if (!shell.retire_timer)
      shell.retire_timer = SetTimer(shell.service_hwnd, 0x8001, 100, NULL);
  }
  for (ShellWindow *item = shell.windows; item; item = item->next) {
    SAFE_RELEASE(item->sidebar_presentation.shared_mutex);
    SAFE_RELEASE(item->sidebar_presentation.shared);
    SAFE_RELEASE(item->sidebar_presentation.surface);
    close_memory_frame(&item->sidebar_presentation);
    item->sidebar_presentation = (ShellPresentation){0};
    set_frame_busy(item, item->project_presentation.busy);
    if (item->sidebar_client) {
      item->sidebar_client->connected = false;
      item->sidebar_client->state = SHELL_STARTING;
    }
  }
  ShellProject *project = allocate_project(window);
  shell.sidebar_process = project;
  if (!project) {
    SDL_Log("Shell Sidebar allocation failed; Project remains available");
    return;
  }
  project->sidebar = true;
  shell.sidebar_notified_revision = UINT64_MAX;
  if (!start_project(project, 0, NULL)) {
    set_state(project, SHELL_FAILED);
    SDL_Log("Shell Sidebar startup failed; Project remains available");
  }
}
static void service_sidebar(void) {
  bool visible = false;
  for (ShellWindow *item = shell.windows; item; item = item->next)
    visible |= !item->closing && IsWindowVisible(item->hwnd) && !IsIconic(item->hwnd);
  if (shell.sidebar_scan && anvil_sidebar_scan_done(shell.sidebar_scan)) {
    bool limited = false;
    const AnvilSidebarModel *result = anvil_sidebar_scan_result(shell.sidebar_scan, &limited);
    if (result && shell.sidebar_scan_revision == shell.sidebar_source_revision) {
      sync_sidebar_model();
      const char *paths[ANVIL_SIDEBAR_PROJECT_LIMIT];
      for (size_t i = 0; i < result->count; i++)
        paths[i] = result->projects[i]->path;
      if (!shell.sidebar_seeded)
        shell.sidebar.seeded = false;
      if (anvil_sidebar_merge_recents(&shell.sidebar, paths, result->count)) {
        shell.sidebar_seeded = true;
        for (size_t i = 0; i < result->count; i++) {
          const AnvilSidebarProject *source = result->projects[i];
          AnvilSidebarProject *row = anvil_sidebar_find(&shell.sidebar, source->path);
          if (row->exists != source->exists) {
            row->exists = source->exists;
            shell.sidebar.revision++;
          }
          AnvilSidebarTerminal sessions[ANVIL_SIDEBAR_TERMINAL_LIMIT];
          size_t count = source->terminal_count;
          if (count)
            memcpy(sessions, source->terminals, count * sizeof(*sessions));
          /* An incomplete scan cannot prove that an old Session was removed. */
          if (limited)
            for (size_t j = 0; j < row->terminal_count && count < SDL_arraysize(sessions); j++) {
              bool found = false;
              for (size_t k = 0; k < count; k++)
                found |= !strcmp(sessions[k].id, row->terminals[j].id);
              if (!found)
                sessions[count++] = row->terminals[j];
            }
          if (!anvil_sidebar_set_terminals(&shell.sidebar, row, sessions, count))
            limited = true;
        }
      } else
        limited = true;
    } else if (!result) {
      limited = true;
      SDL_Log("Shell Project Sidebar source scan failed; retain the previous model");
    }
    if (shell.sidebar_scan_revision == shell.sidebar_source_revision &&
        shell.sidebar.status_limited != limited) {
      shell.sidebar.status_limited = limited;
      shell.sidebar.revision++;
    }
    anvil_sidebar_scan_free(shell.sidebar_scan);
    shell.sidebar_scan = NULL;
    sync_sidebar_model();
  }
  const char *disabled = SDL_getenv("ANVIL_SIDEBAR_SCAN_DISABLED");
  if (visible && !shell.shutting_down && !shell.sidebar_scan && shell.sidebar_userdir && shell.sidebar_scan_requested &&
      !(disabled && !strcmp(disabled, "1"))) {
    sync_sidebar_model();
    const char *probe = SDL_getenv("ANVIL_SURFACE_FAULT_PROBE"),
               *delay = SDL_getenv("ANVIL_SIDEBAR_SCAN_DELAY");
    bool pause =
        shell.sidebar_jobs == 0 && probe && !strcmp(probe, "1") && delay && !strcmp(delay, "1");
    shell.sidebar_scan =
        anvil_sidebar_scan_start(shell.sidebar_userdir, shell.sidebar_recents, &shell.sidebar,
                                 canonical_project_identity, pause);
    shell.sidebar_scan_revision = shell.sidebar_source_revision;
    shell.sidebar_jobs++;
    shell.sidebar_scan_requested = false;
    SDL_Log("Shell Sidebar status scan started: source=%u", shell.sidebar_scan_revision);
    if (shell.sidebar_scan && !shell.sidebar_timer)
      shell.sidebar_timer = SetTimer(shell.service_hwnd, 0x8002, 100, NULL);
    if (!shell.sidebar_scan)
      SDL_Log("Shell Project Sidebar worker failed; retain the previous model");
  }
  if (!shell.sidebar_scan && shell.sidebar_timer) {
    KillTimer(shell.service_hwnd, shell.sidebar_timer);
    shell.sidebar_timer = 0;
  }
  notify_sidebar_changes();
}
static void notify_sidebar_changes(void) {
  sync_sidebar_model();
  if (shell.sidebar_process && shell.sidebar_process->connected &&
      shell.sidebar_notified_revision != shell.sidebar.revision) {
    for (ShellWindow *window = shell.windows; window; window = window->next)
      if (window->sidebar_client && !window->closing)
        shell_send(window->sidebar_client, ANVIL_SURFACE_MSG_SIDEBAR_CHANGED, NULL, 0, NULL, 0);
    shell.sidebar_notified_revision = shell.sidebar.revision;
  }
}

static void probe_sidebar_model(ShellWindow *window, WPARAM action, LPARAM value) {
  sync_sidebar_model();
  if (action == 1) {
    for (size_t i = 0; i < shell.sidebar.count; i++)
      if (shell.sidebar.projects[i]->row_id == (uint32_t)value) {
        select_project_path(window, shell.sidebar.projects[i]->path);
        return;
      }
  } else if (action == 0 && value >= 0) {
    const char *root = SDL_getenv("ANVIL_PROJECT_PROBE_ROOT");
    if (!root)
      return;
    char *snapshot = anvil_sidebar_snapshot(&shell.sidebar, (size_t)value);
    if (!snapshot)
      return;
    char path[32768];
    int length = snprintf(path, sizeof(path), "%s/sidebar-%zu.lua", root, (size_t)value);
    wchar_t *wide = length > 0 && length < (int)sizeof(path)
                        ? (wchar_t *)SDL_iconv_string("UTF-16LE", "UTF-8", path, strlen(path) + 1)
                        : NULL;
    FILE *file = wide ? _wfopen(wide, L"wb") : NULL;
    if (file) {
      fputs(snapshot, file);
      fclose(file);
    }
    SDL_free(wide);
    free(snapshot);
  }
}

static BOOL CALLBACK add_visible_area(HMONITOR monitor, HDC dc, LPRECT bounds, LPARAM data) {
  (void)monitor; (void)dc;
  RECT *target = (RECT *)((LONG_PTR *)data)[0], overlap;
  if (IntersectRect(&overlap, target, bounds))
    *(LONGLONG *)((LONG_PTR *)data)[1] += (LONGLONG)(overlap.right - overlap.left) * (overlap.bottom - overlap.top);
  return TRUE;
}

/* Saved normal bounds in workspace coordinates. A Window that is not fully visible, for example on a removed
 * monitor, moves onto the nearest monitor's work area and shrinks to fit it. */
static RECT visible_placement(const AnvilShellWindowState *placement) {
  RECT bounds = {placement->x, placement->y, placement->x + placement->w, placement->y + placement->h};
  MONITORINFO primary = {.cbSize = sizeof(primary)};
  if (!GetMonitorInfoW(MonitorFromPoint((POINT){0, 0}, MONITOR_DEFAULTTOPRIMARY), &primary)) return bounds;
  /* Workspace coordinates start at the primary work area. */
  int dx = primary.rcWork.left - primary.rcMonitor.left, dy = primary.rcWork.top - primary.rcMonitor.top;
  RECT screen = {bounds.left + dx, bounds.top + dy, bounds.right + dx, bounds.bottom + dy};
  LONGLONG visible = 0;
  LONG_PTR data[2] = {(LONG_PTR)&screen, (LONG_PTR)&visible};
  EnumDisplayMonitors(NULL, NULL, add_visible_area, (LPARAM)data);
  if (visible >= (LONGLONG)(screen.right - screen.left) * (screen.bottom - screen.top)) return bounds;
  MONITORINFO target = {.cbSize = sizeof(target)};
  if (!GetMonitorInfoW(MonitorFromRect(&screen, MONITOR_DEFAULTTONEAREST), &target)) return bounds;
  RECT work = target.rcWork;
  int w = SDL_min(screen.right - screen.left, work.right - work.left);
  int h = SDL_min(screen.bottom - screen.top, work.bottom - work.top);
  int x = SDL_clamp(screen.left, work.left, work.right - w), y = SDL_clamp(screen.top, work.top, work.bottom - h);
  SDL_Log("Shell moved a restored Window onto a visible monitor: saved=%ld,%ld %ldx%ld screen=%d,%d %dx%d",
          (long)placement->x, (long)placement->y, (long)placement->w, (long)placement->h, x, y, w, h);
  return (RECT){x - dx, y - dy, x - dx + w, y - dy + h};
}

static ShellWindow *create_window(const AnvilShellWindowState *placement) {
  unsigned count = 0;
  for (ShellWindow *item = shell.windows; item; item = item->next) count++;
  if (count >= 64 || shell.next_window == UINT32_MAX || shell.shutting_down) {
    SDL_Log("Shell rejected New Window: Window bound or shutdown");
    return NULL;
  }
  ShellWindow *window = calloc(1, sizeof(*window));
  if (window) window->background = 23 | 23 << 8 | 28 << 16;
  if (!window) return NULL;
  window->id = ++shell.next_window;
  window->sidebar = true;
  if (!shell.sidebar_window_id) shell.sidebar_window_id = window->id;
  window->empty = allocate_project(window);
  if (!window->empty) { free(window); return NULL; }
  window->empty->state = SHELL_DORMANT;
  window->sidebar_client = allocate_project(window);
  if (!window->sidebar_client) { release_project(window->empty); free(window); return NULL; }
  window->sidebar_client->sidebar = true;
  window->sidebar_client->state = SHELL_STARTING;
  window->selected = window->empty;
  window->hovered_control = window->pressed_control = -1;
  window->next = shell.windows;
  shell.windows = window;
  const SDL_DisplayMode *mode = SDL_GetDesktopDisplayMode(SDL_GetPrimaryDisplay());
  int width = mode ? (int)(mode->w * 0.8) : 1280;
  int height = mode ? (int)(mode->h * 0.8) : 800;
  window->window =
      SDL_CreateWindow("Anvil - No Project selected", width, height,
                       SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY | SDL_WINDOW_HIDDEN);
  if (!window->window || !install_native_frame(window)) {
    SDL_Log("Anvil shell could not create its window: %s", SDL_GetError());
    destroy_window(window);
    return NULL;
  }
  update_scale(window);
  SDL_SetWindowMinimumSize(window->window, 240 + window->sidebar_w, 180);
  set_window_icon(window);
  if (placement) {
    /* Normal bounds first, while hidden. A maximized Window then keeps them for Restore. */
    WINDOWPLACEMENT saved = {.length = sizeof(saved)};
    GetWindowPlacement(window->hwnd, &saved);
    saved.flags = 0;
    saved.showCmd = SW_HIDE;
    saved.rcNormalPosition = visible_placement(placement);
    if (!SetWindowPlacement(window->hwnd, &saved))
      SDL_Log("Shell could not restore Window bounds: Windows error=%lu", (unsigned long)GetLastError());
    update_scale(window);
  }
  if (!init_d3d11(window)) fail_gpu(window, "initial presentation creation failed", E_FAIL);
  composite_and_present(window);
  SDL_ShowWindow(window->window);
  if (placement && placement->maximized) SDL_MaximizeWindow(window->window);
  if (placement) {
    AnvilShellWindowState actual;
    window_entry(window, &actual);
    SDL_Log("Shell restored Window placement: id=%u saved=%ld,%ld %ldx%ld max=%d actual=%ld,%ld %ldx%ld max=%d",
            window->id, (long)placement->x, (long)placement->y, (long)placement->w, (long)placement->h,
            placement->maximized, (long)actual.x, (long)actual.y, (long)actual.w, (long)actual.h, actual.maximized);
  }
  window->shown = true;
  window->activated = ++shell.activation;
  windows_changed();
  if (shell.sidebar_process && shell.sidebar_process->connected) {
    window->sidebar_client->connected = true;
    window->sidebar_client->connection = shell.sidebar_process->connection;
    window->sidebar_client->process.dwProcessId = shell.sidebar_process->process.dwProcessId;
    send_configure(window->sidebar_client);
  }
  SDL_Log("Shell empty Window ready: id=%u", window->id);
  return window;
}

static BOOL CALLBACK cancel_owned_dialog(HWND hwnd, LPARAM parent) {
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  if (pid == GetCurrentProcessId() && GetWindow(hwnd, GW_OWNER) == (HWND)parent)
    PostMessageW(hwnd, WM_CLOSE, 0, 0);
  return TRUE;
}

/* The Window's current App State entry. The path is borrowed from its Selected Project. */
static void window_entry(ShellWindow *window, AnvilShellWindowState *entry) {
  WINDOWPLACEMENT placement = {.length = sizeof(placement)};
  GetWindowPlacement(window->hwnd, &placement);
  RECT bounds = placement.rcNormalPosition;
  entry->id = window->id;
  entry->x = bounds.left;
  entry->y = bounds.top;
  entry->w = bounds.right - bounds.left;
  entry->h = bounds.bottom - bounds.top;
  entry->maximized = placement.showCmd == SW_SHOWMAXIMIZED ||
                     (placement.showCmd == SW_SHOWMINIMIZED && (placement.flags & WPF_RESTORETOMAXIMIZED));
  ShellProject *project = window->selected;
  entry->path = project && project != window->empty ? project->project_path : NULL;
}

/* `final` keeps Windows that are being removed, because the shell is ending with them. */
static void save_windows(bool final) {
  if (shell.state_timer) {
    KillTimer(shell.service_hwnd, shell.state_timer);
    shell.state_timer = 0;
  }
  if (!shell.state_enabled) return;
  ShellWindow *order[ANVIL_SHELL_STATE_MAX_WINDOWS];
  AnvilShellWindowState entries[ANVIL_SHELL_STATE_MAX_WINDOWS];
  size_t count = 0;
  for (ShellWindow *window = shell.windows; window && count < ANVIL_SHELL_STATE_MAX_WINDOWS; window = window->next)
    if (final || !window->removing) order[count++] = window;
  for (size_t i = 1; i < count; i++)
    for (size_t j = i; j > 0 && order[j]->activated > order[j - 1]->activated; j--) {
      ShellWindow *swap = order[j];
      order[j] = order[j - 1];
      order[j - 1] = swap;
    }
  for (size_t i = 0; i < count; i++) {
    if (order[i]->closing && order[i]->close_entry_valid) entries[i] = order[i]->close_entry;
    else window_entry(order[i], &entries[i]);
  }
  AnvilShellState state = {entries, count};
  size_t size = 0;
  char *data = anvil_shell_state_encode(&state, &size);
  if (!data) {
    SDL_Log("Shell Window state exceeds its bounds; keep the previous file");
    return;
  }
  SDL_Log("Shell Window state queued: Windows=%u final=%d", (unsigned)count, final);
  anvil_shell_state_submit(data, size);
}

/* Coalesces placement and selection changes into one write. */
static void windows_changed(void) {
  if (!shell.state_enabled || shell.state_timer) return;
  shell.state_timer = SetTimer(shell.service_hwnd, 0x8006, 500, NULL);
  if (!shell.state_timer) save_windows(false);
}

static bool has_project_argument(int argc, char **argv) {
  bool option_value = false;
  for (int i = 2; i < argc; i++) {
    if (option_value) option_value = false;
    else if (argv[i][0] == '-') option_value = anvil_cli_option_value(argv[i]);
    else return true;
  }
  return false;
}

#define RESTORE_STAGGER_MS 2000
/* Starts restored Projects one at a time, frontmost first. The next one starts when the previous one is ready,
 * has failed, or has used its stagger interval. Native controls never wait for this sequence. */
static void advance_restore(void) {
  ShellProject *next = NULL, *active = NULL;
  for (ShellProject *item = shell.projects; item; item = item->next) {
    if (item->id == shell.restore_active) active = item;
    if (!item->restore_waiting) continue;
    ShellWindow *owner = window_for_id(item->window_id);
    if (!owner || owner->closing || item->failed_close) {
      item->restore_waiting = false;
      continue;
    }
    if (!next || item->restore_rank < next->restore_rank) next = item;
  }
  if (!next) {
    if (shell.restore_timer) KillTimer(shell.service_hwnd, shell.restore_timer);
    shell.restore_timer = 0;
    return;
  }
  if (!shell.restore_timer) shell.restore_timer = SetTimer(shell.service_hwnd, 0x8007, 100, NULL);
  /* Duplicate saved entries resolve to one identity. Start nothing until each restored identity is known. */
  if (initial_resolution_pending()) return;
  if (active && active->state == SHELL_STARTING && SDL_GetTicks() < shell.restore_active_since + RESTORE_STAGGER_MS &&
      (!active->process.hProcess || WaitForSingleObject(active->process.hProcess, 0) == WAIT_TIMEOUT))
    return;
  if (next->resolving) return;
  next->restore_waiting = false;
  shell.restore_active = next->id;
  shell.restore_active_since = SDL_GetTicks();
  SDL_Log("Shell starts restored Project: Project=%u rank=%d", next->id, next->restore_rank);
  if (!start_project(next, 0, NULL)) fail_connection(next, "Restored Project startup failed");
}

/* A restored Project resolves its identity, then waits for the restore sequence to start or adopt it. */
static ShellProject *restored_project(ShellWindow *window, const char *path, int rank) {
  ShellProject *project = new_project(window);
  if (!project) {
    window_notice(window, "Cannot load Project: runtime allocation failed.");
    return NULL;
  }
  /* App State keeps the path while its identity resolves. */
  project->project_path = _strdup(path);
  if (!queue_resolution(window, path, 0, NULL, true, false, false, NULL)) {
    SDL_Log("Shell could not resolve a restored Project");
    set_state(project, SHELL_FAILED);
    return project;
  }
  shell.resolvers->project_id = project->id;
  shell.resolvers->restored = true;
  project->resolving = true;
  project->restore_waiting = true;
  project->restore_rank = rank;
  return project;
}

static void adopt_record(ShellProject *project, AnvilAdoptionRecord *record) {
  if (!project) return;
  project->adopt_pid = record->pid;
  project->adopt_created = record->created;
  record->pid = 0;
}

/* Restores saved Windows back to front, so the frontmost Window opens last. Each adoptable Project returns to
 * its saved Window, or to the frontmost Window when that Window was not saved. Returns the Window count. */
static size_t restore_windows(AnvilShellState *saved, AnvilAdoptionRecord *adoptable, size_t adoptable_count) {
  size_t restored = 0;
  int rank = (int)saved->count;
  ShellWindow *front = NULL;
  for (size_t i = saved->count; i-- > 0;) {
    AnvilShellWindowState *entry = &saved->windows[i];
    ShellWindow *window = create_window(entry);
    if (!window) continue;
    restored++;
    front = window;
    if (entry->path) {
      ShellProject *project = restored_project(window, entry->path, (int)i);
      if (project) select_project(project);
      for (size_t j = 0; project && j < adoptable_count; j++)
        if (adoptable[j].pid && adoptable[j].window_id == entry->id && !strcmp(adoptable[j].path, entry->path)) {
          adopt_record(project, &adoptable[j]);
          break;
        }
    }
    for (size_t j = 0; j < adoptable_count; j++)
      if (adoptable[j].pid && adoptable[j].window_id == entry->id)
        adopt_record(restored_project(window, adoptable[j].path, rank++), &adoptable[j]);
  }
  for (size_t j = 0; j < adoptable_count; j++) {
    if (!adoptable[j].pid) continue;
    if (!front && (front = create_window(NULL))) restored++;
    if (!front) break;
    ShellProject *project = restored_project(front, adoptable[j].path, rank++);
    if (project && front->selected == front->empty) select_project(project);
    adopt_record(project, &adoptable[j]);
  }
  SDL_Log("Shell restored %u Windows from %u saved Windows and %u adoptable Projects", (unsigned)restored,
          (unsigned)saved->count, (unsigned)adoptable_count);
  return restored;
}

static bool destroy_window(ShellWindow *window) {
  if (!window->removing) {
    window->removing = true;
    begin_window_close(window);
    if (window->window) SDL_HideWindow(window->window);
    window->shown = false;
  }
  /* SDL dialogs read their SDL_Window on their own thread. Cancel their native
   * UI, then retain the SDL_Window until their callbacks no longer need it. */
  if (!shell.shutting_down) {
    bool pending = false;
    for (ShellPicker *picker = shell.pickers; picker; picker = picker->next)
      pending |= picker->window_id == window->id && !picker->probe;
    for (ShellProject *project = shell.retiring; project; project = project->next)
      pending |= project->window_id == window->id;
    if (pending) {
      EnumWindows(cancel_owned_dialog, (LPARAM)window->hwnd);
      if (!shell.retire_timer) shell.retire_timer = SetTimer(shell.service_hwnd, 0x8001, 100, NULL);
      return false;
    }
  }
  SDL_Log("Shell removes Window: id=%u", window->id);
  /* The last Window's Close ends the shell. App State keeps that Window for the next launch. */
  bool last = shell.windows == window && !window->next;
  if (last) save_windows(true);
  if (window->sidebar_client && shell.sidebar_process) {
    shell_send(shell.sidebar_process, ANVIL_SURFACE_MSG_SIDEBAR_REMOVE, &window->id, sizeof(window->id), NULL, 0);
    if (shell.sidebar_window_id == window->id) {
      ShellWindow *next = shell.windows;
      while (next && (next == window || next->closing)) next = next->next;
      shell.sidebar_window_id = next ? next->id : 0;
      shell.sidebar_process->window_id = shell.sidebar_window_id;
    }
  }
  cancel_input(window);
  release_d3d11(window);
  if (window->ui_dc) {
    SelectObject(window->ui_dc, window->ui_old_bitmap);
    DeleteObject(window->ui_bitmap);
    DeleteDC(window->ui_dc);
  }
  if (window->hwnd && GetPropW(window->hwnd, L"AnvilShellWindow") == window) {
    RemovePropW(window->hwnd, L"AnvilShellWindow");
    if (window->sdl_wndproc) SetWindowLongPtrW(window->hwnd, GWLP_WNDPROC, (LONG_PTR)window->sdl_wndproc);
  }
  if (window->window) SDL_DestroyWindow(window->window);
  ShellWindow **link = &shell.windows;
  while (*link != window) link = &(*link)->next;
  *link = window->next;
  release_project(window->empty);
  release_project(window->sidebar_client);
  free(window->close_entry.path);
  free(window);
  if (!last) windows_changed();
  return true;
}

SDL_AppResult anvil_shell_init(void **appstate, int argc, char **argv) {
  *appstate = &shell;
  anvil_surface_log_init("shell");
  /* Another shell for this executable and user directory takes the launch. This process then ends. */
  AnvilShellLaunchResult launch = anvil_shell_launch_own_or_forward(argc, argv);
  if (launch == ANVIL_SHELL_LAUNCH_FORWARDED) shell_exit(0);
  if (launch == ANVIL_SHELL_LAUNCH_FAILED) {
    fprintf(stderr, "Anvil: the running Anvil did not accept this launch. Try again.\n");
    shell_exit(1);
  }
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
  if (!shell.event_type)
    return SDL_APP_FAILURE;

  WNDCLASSW services = {.lpfnWndProc = shell_service_wndproc,
                         .hInstance = GetModuleHandleW(NULL), .lpszClassName = L"AnvilShellServices"};
  if (!RegisterClassW(&services)) return SDL_APP_FAILURE;
  shell.service_hwnd = CreateWindowExW(0, services.lpszClassName, L"", 0, 0, 0, 0, 0,
                                      HWND_MESSAGE, NULL, services.hInstance, NULL);
  if (!shell.service_hwnd) return SDL_APP_FAILURE;
  SDL_Log("Shell service notifications hwnd=%p", (void *)shell.service_hwnd);
  const wchar_t *userdir = anvil_shell_launch_user_directory();
  static wchar_t state_file[32768 + 64];
  AnvilShellState saved = {0};
  if (userdir && _snwprintf(state_file, SDL_arraysize(state_file), L"%ls\\%ls", userdir,
                            ANVIL_SHELL_STATE_FILE) > 0) {
    if (!anvil_shell_state_load(state_file, &saved))
      SDL_Log("Shell Window state %s; start one Window",
              GetFileAttributesW(state_file) == INVALID_FILE_ATTRIBUTES ? "is absent" : "is invalid or too large");
    shell.state_enabled = anvil_shell_state_writer_start(state_file);
    if (!shell.state_enabled) SDL_Log("Shell Window state writer unavailable; Windows will not be restored");
  } else SDL_Log("Shell user directory unavailable; Windows will not be restored");
  /* Projects from a shell that ended wait for this one. */
  static AnvilAdoptionRecord adoptable[ANVIL_ADOPTION_MAX_RECORDS];
  size_t adoptable_count = userdir ? anvil_adoption_scan(adoptable, SDL_arraysize(adoptable)) : 0;
  size_t restored = saved.count || adoptable_count ? restore_windows(&saved, adoptable, adoptable_count) : 0;
  anvil_shell_state_free(&saved);
  for (size_t i = 0; i < adoptable_count; i++) anvil_adoption_free(&adoptable[i]);
  if (restored) {
    /* A Project argument after a restore acts like an external launch. */
    if (has_project_argument(argc, argv) &&
        !queue_resolution(NULL, NULL, argc, argv, false, false, true, NULL))
      SDL_Log("Shell could not open the launch's Project after restore");
    if (!anvil_shell_launch_start(notify_external))
      SDL_Log("Shell launch server unavailable; later launches cannot reach this shell");
    return SDL_APP_CONTINUE;
  }
  ShellWindow *window = create_window(NULL);
  if (!window) return SDL_APP_FAILURE;
  ShellProject *project = new_project(window);
  if (!project) return SDL_APP_FAILURE;
  select_project(project);
  if (!queue_resolution(window, NULL, argc, argv, true, false, false, NULL)) {
    SDL_Log("Anvil shell could not resolve its initial Project");
    set_state(project, SHELL_FAILED);
  } else project->resolving = true;
  if (!anvil_shell_launch_start(notify_external))
    SDL_Log("Shell launch server unavailable; later launches cannot reach this shell");
  return SDL_APP_CONTINUE;
}

SDL_AppResult anvil_shell_iterate(void *appstate) {
  (void)appstate;
  check_picker_failures();
  for (ShellWindow *window = shell.windows; window; window = window->next) check_gpu_failure(window);
  finish_resolutions();
  advance_restore();
  service_sidebar();
  if (shell.sidebar_process) {
    finish_launch(shell.sidebar_process);
    check_transport_failure(shell.sidebar_process);
    for (ShellWindow *window = shell.windows; window; window = window->next)
      if (window->sidebar_presentation.busy) handle_sidebar_frame(window);
    schedule_sidebar_restart();
  }
  for (ShellProject *item = shell.projects; item; item = item->next) {
    finish_launch(item);
    check_transport_failure(item);
    if ((Uint32)SDL_GetAtomicInt(&item->dialog_failure) == item->connection && item->connected)
      fail_connection(item, "native dialog result notification failed");
  }
  for (ShellProject *item = shell.projects, *next; item; item = next) {
    next = item->next;
    ShellWindow *owner = window_for_id(item->window_id);
    if ((item->unloading || (owner && owner->closing)) && item->failed_close && !item->resolving &&
        (!item->launch || item->launch->taken) &&
        (!item->process.hProcess ||
         WaitForSingleObject(item->process.hProcess, 0) == WAIT_OBJECT_0)) {
      if (!item->identity || !item->project_path) {
        retire_failed_placeholder(item);
        continue;
      }
      if (!item->unloading) begin_unload(item);
      if (item->unloading) complete_unload(item);
    }
  }
  drain_retired_projects();
  notify_sidebar_changes();
  for (ShellWindow *window = shell.windows, *following; window; window = following) {
    following = window->next;
    ShellProject *project = window->selected;
    if (window->frame_busy) handle_frame(window);
    if (!window->closing) continue;
    if (!project->id) project->failed_close = true;
    if (!project->failed_close) {
      if (!project->close_requested_ns) request_close(project);
      continue;
    }
    if (project->resolving || (project->launch && !project->launch->taken)) continue;
    ShellProject *next = NULL;
    for (ShellProject *item = shell.projects; item; item = item->next)
      if (item->window_id == window->id && item != project && !item->failed_close &&
          ((item->launch && !item->launch->taken) || (item->process.hProcess &&
           WaitForSingleObject(item->process.hProcess, 0) == WAIT_TIMEOUT))) {
        next = item; break;
      }
    if (next) { select_project(next); request_close(next); continue; }
    bool assigned = false;
    for (ShellProject *item = shell.projects; item; item = item->next)
      assigned |= item->window_id == window->id;
    if (assigned) continue;
    destroy_window(window);
  }
  return shell.windows ? SDL_APP_CONTINUE : SDL_APP_SUCCESS;
}

void anvil_shell_quit(void *appstate, SDL_AppResult result) {
  shell.shutting_down = true;
  /* Later launches then own a new shell instead of waiting for this one. */
  anvil_shell_launch_stop();
  if (shell.windows) save_windows(true);
  shell.state_enabled = false;
  anvil_shell_state_writer_stop(1000);
  (void)appstate;
  (void)result;
  /* Project loss detection owns save/detach and its deadline. Never kill it with a shell job. */
  Uint64 deadline = SDL_GetTicks() + 1000;
  if (!anvil_sidebar_watch_stop(shell.sidebar_watch, deadline)) {
    SDL_Log("Sidebar registry watcher shutdown deadline expired; exit this shell only");
    shell_exit(result == SDL_APP_FAILURE ? 1 : 0);
  }
  shell.sidebar_watch = NULL;
  if (shell.sidebar_restart_timer) KillTimer(shell.service_hwnd, shell.sidebar_restart_timer);
  shell.sidebar_restart_timer = 0;
  if (shell.sidebar_healthy_timer) KillTimer(shell.service_hwnd, shell.sidebar_healthy_timer);
  shell.sidebar_healthy_timer = 0;
  if (shell.sidebar_process) {
    ShellProject *project = shell.sidebar_process;
    if (project->connected)
      shell_send(project, ANVIL_SURFACE_MSG_CLOSE, NULL, 0, NULL, 0);
    if (project->process.hProcess &&
        WaitForSingleObject(project->process.hProcess, 0) == WAIT_TIMEOUT) {
      SDL_Log("Shell ends its disposable Sidebar frontend; Projects and Terminal Sessions stay "
              "independent");
      anvil_process_terminate(project->process.hProcess, 0);
    }
    if (project->startup_timer)
      KillTimer(shell.service_hwnd, project->startup_timer);
    if (!stop_transport(project, deadline)) {
      SDL_Log("Shell Sidebar shutdown deadline expired; exit this shell only");
      shell_exit(result == SDL_APP_FAILURE ? 1 : 0);
    }
    release_project(project);
    shell.sidebar_process = NULL;
  }
  if (shell.sidebar_timer)
    KillTimer(shell.service_hwnd, shell.sidebar_timer);
  if (shell.sidebar_scan && !anvil_sidebar_scan_stop(shell.sidebar_scan, deadline)) {
    SDL_Log("Shell Sidebar worker shutdown deadline expired; exit this shell only");
    shell_exit(result == SDL_APP_FAILURE ? 1 : 0);
  }
  if (shell.sidebar_scan)
    anvil_sidebar_scan_free(shell.sidebar_scan);
  anvil_sidebar_destroy(&shell.sidebar);
  free(shell.sidebar_userdir);
  free(shell.sidebar_recents);
  for (ProjectResolve *job = shell.resolvers; job; job = job->next) {
    while (!SDL_GetAtomicInt(&job->done)) {
      if (SDL_GetTicks() >= deadline) {
        SDL_Log("Shell identity shutdown deadline expired; exit this shell only");
        shell_exit(result == SDL_APP_FAILURE ? 1 : 0);
      }
      SDL_Delay(1);
    }
    SDL_WaitThread(job->thread, NULL);
  }
  for (ShellProject *project = shell.projects; project; project = project->next) {
    stop_close_timer(project);
    ShellWindow *window = window_for_id(project->window_id);
    if (project->startup_timer && window)
      KillTimer(window->hwnd, project->startup_timer);
    if (!stop_transport(project, deadline)) {
      SDL_Log("Shell transport shutdown deadline expired; exit this shell only");
      shell_exit(result == SDL_APP_FAILURE ? 1 : 0);
    }
  }
  for (ShellProject *project = shell.retiring; project; project = project->next) {
    if (!stop_transport(project, deadline)) {
      SDL_Log("Shell retired transport shutdown deadline expired; exit this shell only");
      shell_exit(result == SDL_APP_FAILURE ? 1 : 0);
    }
  }
  for (ShellPicker *picker = shell.pickers; picker; picker = picker->next)
    if (!picker->probe) {
      SDL_Log("Shell exits with a cancelled native picker; retain its callback storage until process exit");
      shell_exit(result == SDL_APP_FAILURE ? 1 : 0);
    }
  for (ShellProject *project = shell.retiring; project; project = project->next)
    if (SDL_GetAtomicInt(&project->references) > 1) {
      SDL_Log("Shell exits with retained native callback storage; do not free its SDL_Window");
      shell_exit(result == SDL_APP_FAILURE ? 1 : 0);
    }
  for (ShellProject *project = shell.projects; project; project = project->next)
    if (SDL_GetAtomicInt(&project->references) > 1) {
      SDL_Log("Shell exits with retained native callback storage; do not free its SDL_Window");
      shell_exit(result == SDL_APP_FAILURE ? 1 : 0);
    }
  while (shell.windows) destroy_window(shell.windows);
  if (shell.service_hwnd) DestroyWindow(shell.service_hwnd);
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
