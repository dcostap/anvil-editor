#include "anvil_shell.h"

#ifdef _WIN32

#include "surface_protocol.h"
#include "input_latency_probe.h"
#include "cli_args.h"
#include "win32_frame_hwnd.h"

#include <windowsx.h>
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
#define SHELL_EXIT_WAIT_MS 10000
#define SHELL_WRITE_QUEUE_LIMIT (8u * 1024u * 1024u)
#define SHELL_SYNC_TIMEOUT_MS 0
#define SHELL_PIPE_BUFFER (64u * 1024u)
/* How long one resize step waits for a surface frame of the new size. */
#define SHELL_RESIZE_WAIT_MS 50

typedef struct ShellMessage {
  struct ShellMessage *next;
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
};

typedef enum { SHELL_STARTING, SHELL_READY, SHELL_CLOSING, SHELL_FAILED } ShellState;

typedef struct {
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

  PROCESS_INFORMATION process;
  SDL_Thread *reader, *writer;
  bool writer_stop;
  bool intentional_exit;
  bool failed_close;
  char *restart_path, *project_path;
  AnvilIPCPipe pipe;
  bool connected;
  Uint32 connection;
  bool text_active;

  SDL_Mutex *lock;
  SDL_Condition *queue_cond;
  ShellMessage *queue_head, *queue_tail;
  size_t queue_bytes;
  /* Frames coalesce: the main thread composites only the newest one. */
  AnvilSurfaceFrame latest_frame;
  bool frame_pending;
  SDL_Condition *frame_cond;

  /* Resize steps present only after the surface catches up to the new size.
   * A step that times out stops that wait until a matching frame arrives, so
   * a slow surface process can not make every step wait. */
  bool live_resize;
  bool resize_wait_disabled;

  float scale;
  int sidebar_w;
  AnvilSurfaceConfigure last_config;
  Uint32 surface_buttons;
  float pointer_x, pointer_y;
  bool pointer_in_surface;
  AnvilSurfaceHitTest hit;
  int child_cursor;
  SDL_Cursor *cursors[ANVIL_SURFACE_CURSOR_COUNT];
  Uint64 close_requested_ns;
  bool shown;
  ShellState state;
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
static bool start_project(int argc, char **argv);
static void composite_and_present(void);
static void request_close(void);
static void cancel_input(void);
static void set_state(ShellState state);
static void fail_connection(const char *cause) {
  SDL_Log("Shell connection failed: %s", cause);
  shell.connected = false;
  cancel_input();
  anvil_ipc_pipe_cancel(&shell.pipe);
  set_state(SHELL_FAILED);
  composite_and_present();
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
  shell.frame_busy = busy;
  SDL_SetAtomicInt(&shell.retry_frame, busy);
  if (busy && !shell.retry_timer) {
    shell.retry_timer = SDL_AddTimer(16, retry_frame, (void *)(uintptr_t)shell.connection);
    SDL_Log("Shell frame retry started");
  } else if (!busy && shell.retry_timer) {
    SDL_RemoveTimer(shell.retry_timer);
    shell.retry_timer = 0;
    SDL_Log("Shell frame retry stopped");
  }
}

static void set_state(ShellState state) {
  if (shell.state == state)
    return;
  shell.state = state;
  shell.ui_dirty = true;
  if (state == SHELL_STARTING || state == SHELL_FAILED) {
    set_frame_busy(false);
  }
  static const char *names[] = {"Starting", "Ready", "Closing", "Failed"};
  SDL_Log("Shell state: %s", names[state]);
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

static wchar_t *build_child_command_line(const wchar_t *exe, const char *pipe_arg,
                                         int argc, char **argv) {
  int exe_len = WideCharToMultiByte(CP_UTF8, 0, exe, -1, NULL, 0, NULL, NULL);
  size_t capacity = (size_t)exe_len * 2 + strlen(pipe_arg) * 2 + strlen(shell.project_path) * 2 + 128;
  for (int i = 2; i < argc; i++) capacity += strlen(argv[i]) * 2 + 4;
  char *exe_utf8 = malloc((size_t)exe_len);
  char *line = malloc(capacity);
  wchar_t *wide = NULL;
  if (exe_utf8 && line) {
    WideCharToMultiByte(CP_UTF8, 0, exe, -1, exe_utf8, exe_len, NULL, NULL);
    size_t n = append_quoted_arg(line, exe_utf8);
    line[n++] = ' '; n += append_quoted_arg(line + n, ANVIL_PROJECT_ARG);
    line[n++] = ' '; n += append_quoted_arg(line + n, shell.project_path);
    line[n++] = ' ';
    n += append_quoted_arg(line + n, pipe_arg);
    if (shell.restart_path) { line[n++] = ' '; n += append_quoted_arg(line + n, ANVIL_PROJECT_RESTART_ARG); }
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

static bool launch_child(int argc, char **argv, const char *pipe_name) {
  wchar_t exe[MAX_PATH * 4];
  DWORD exe_len = GetModuleFileNameW(NULL, exe, (DWORD)SDL_arraysize(exe));
  if (!exe_len || exe_len >= SDL_arraysize(exe)) return false;

  char pipe_arg[sizeof(ANVIL_SURFACE_PIPE_ARG) + 256];
  snprintf(pipe_arg, sizeof(pipe_arg), "%s%s", ANVIL_SURFACE_PIPE_ARG, pipe_name);
  wchar_t *command_line = build_child_command_line(exe, pipe_arg, argc, argv);
  if (!command_line) return false;

  STARTUPINFOW startup;
  ZeroMemory(&startup, sizeof(startup));
  startup.cb = sizeof(startup);
  BOOL created = CreateProcessW(exe, command_line, NULL, NULL, FALSE, CREATE_SUSPENDED,
                                NULL, NULL, &startup, &shell.process);
  free(command_line);
  if (!created) return false;
  SDL_Log("Shell foreground grant to Project pid=%lu allowed=%d", (unsigned long)shell.process.dwProcessId,
    AllowSetForegroundWindow(shell.process.dwProcessId) != 0);
  ResumeThread(shell.process.hThread);
  SDL_Log("Shell started Project pid=%lu path=%s", (unsigned long)shell.process.dwProcessId, shell.project_path);
  return true;
}

/* ------------------------------------------------------------------------ */
/* Pipe threads                                                             */

static void push_shell_event(int code, void *data, int value) {
  SDL_Event event;
  SDL_zero(event);
  event.type = shell.event_type;
  event.user.code = code;
  event.user.data1 = data;
  event.user.data2 = (void *)(intptr_t)value;
  event.user.windowID = shell.connection;
  SDL_PushEvent(&event);
}

static bool wait_for_child_connection(void) {
  HANDLE connect_event = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (!connect_event) return false;
  bool connected = false;
  for (;;) {
    OVERLAPPED overlapped;
    ZeroMemory(&overlapped, sizeof(overlapped));
    overlapped.hEvent = connect_event;
    ResetEvent(connect_event);
    DWORD error = ConnectNamedPipe(shell.pipe.handle, &overlapped) ? ERROR_PIPE_CONNECTED : GetLastError();
    if (error == ERROR_IO_PENDING) {
      HANDLE waits[2] = { connect_event, shell.process.hProcess };
      DWORD done = 0;
      if (WaitForMultipleObjects(2, waits, FALSE, SHELL_CONNECT_TIMEOUT_MS) != WAIT_OBJECT_0) {
        CancelIoEx(shell.pipe.handle, &overlapped);
        GetOverlappedResult(shell.pipe.handle, &overlapped, &done, TRUE);
        break;
      }
      error = GetOverlappedResult(shell.pipe.handle, &overlapped, &done, FALSE)
        ? ERROR_PIPE_CONNECTED : GetLastError();
    }
    if (error != ERROR_PIPE_CONNECTED) break;
    /* Only the process this shell started may drive its window. */
    ULONG client = 0;
    if (GetNamedPipeClientProcessId(shell.pipe.handle, &client) &&
        client == shell.process.dwProcessId) {
      connected = true;
      break;
    }
    SDL_Log("Anvil shell rejected a pipe client with pid %lu", (unsigned long)client);
    DisconnectNamedPipe(shell.pipe.handle);
  }
  CloseHandle(connect_event);
  return connected;
}

static int SDLCALL reader_thread(void *data) {
  (void)data;
  uint8_t *payload = malloc(ANVIL_SURFACE_MAX_PAYLOAD);
  AnvilIPCHeader header;
  if (payload && wait_for_child_connection() &&
      anvil_ipc_pipe_read(&shell.pipe, &header, payload, ANVIL_SURFACE_MAX_PAYLOAD) &&
      header.type == ANVIL_SURFACE_MSG_HELLO && header.size == sizeof(AnvilSurfaceHello) &&
      ((AnvilSurfaceHello *)payload)->pid == shell.process.dwProcessId) {
    push_shell_event(SHELL_EVENT_CONNECTED, NULL, 0);
    while (anvil_ipc_pipe_read(&shell.pipe, &header, payload, ANVIL_SURFACE_MAX_PAYLOAD)) {
      if (header.type == ANVIL_SURFACE_MSG_FRAME) {
        if (header.size != sizeof(AnvilSurfaceFrame)) continue;
        SDL_LockMutex(shell.lock);
        memcpy(&shell.latest_frame, payload, sizeof(AnvilSurfaceFrame));
        shell.latest_frame.name[ANVIL_SURFACE_NAME_MAX - 1] = '\0';
        bool notify = !shell.frame_pending;
        shell.frame_pending = true;
        SDL_BroadcastCondition(shell.frame_cond);
        SDL_UnlockMutex(shell.lock);
        if (notify) push_shell_event(SHELL_EVENT_FRAME, NULL, 0);
        continue;
      }
      ShellMessage *message = malloc(sizeof(ShellMessage) + header.size);
      if (!message) continue;
      message->next = NULL;
      message->type = header.type;
      message->size = header.size;
      memcpy(message->payload, payload, header.size);
      push_shell_event(SHELL_EVENT_MESSAGE, message, 0);
    }
  }
  free(payload);

  DWORD exit_code = 1;
  if (WaitForSingleObject(shell.process.hProcess, SHELL_EXIT_WAIT_MS) != WAIT_OBJECT_0) {
    TerminateProcess(shell.process.hProcess, 1);
    WaitForSingleObject(shell.process.hProcess, 1000);
  }
  GetExitCodeProcess(shell.process.hProcess, &exit_code);
  push_shell_event(SHELL_EVENT_EXITED, NULL, (int)exit_code);
  return 0;
}

static int SDLCALL writer_thread(void *data) {
  (void)data;
  for (;;) {
    SDL_LockMutex(shell.lock);
    while (!shell.queue_head && !shell.writer_stop) SDL_WaitCondition(shell.queue_cond, shell.lock);
    if (shell.writer_stop) { SDL_UnlockMutex(shell.lock); return 0; }
    ShellMessage *message = shell.queue_head;
    shell.queue_head = message->next;
    if (!shell.queue_head) shell.queue_tail = NULL;
    shell.queue_bytes -= sizeof(*message) + message->size;
    SDL_UnlockMutex(shell.lock);
    bool written = anvil_ipc_pipe_write(&shell.pipe, message->type, message->payload, message->size, NULL, 0);
    free(message);
    if (!written) {
      push_shell_event(SHELL_EVENT_DISCONNECTED, NULL, 0);
      return 1;
    }
  }
  return 0;
}

/* Main-thread sends never block on the pipe. A hung surface process can not
 * stall the shell window. Queue failure ends the connection, not just one key. */
static void shell_send(uint16_t type, const void *payload, uint32_t size,
                       const void *tail, uint32_t tail_size) {
  if (!shell.connected) return;
  uint32_t total = size + tail_size;
  if (total > ANVIL_SURFACE_MAX_PAYLOAD) {
    fail_connection("outbound packet too large");
    return;
  }
  ShellMessage *message = malloc(sizeof(ShellMessage) + total);
  if (!message) {
    fail_connection("outbound allocation failed");
    return;
  }
  message->next = NULL;
  message->type = type;
  message->size = total;
  if (size) memcpy(message->payload, payload, size);
  if (tail_size) memcpy(message->payload + size, tail, tail_size);

  SDL_LockMutex(shell.lock);
  ShellMessage *previous = shell.queue_tail;
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
    SDL_UnlockMutex(shell.lock);
    free(message);
    return;
  }
  if (shell.queue_bytes + sizeof(*message) + total > SHELL_WRITE_QUEUE_LIMIT) {
    SDL_UnlockMutex(shell.lock);
    free(message);
    fail_connection("outbound queue overflow");
    return;
  }
  if (shell.queue_tail) shell.queue_tail->next = message;
  else shell.queue_head = message;
  shell.queue_tail = message;
  shell.queue_bytes += sizeof(*message) + total;
  SDL_SignalCondition(shell.queue_cond);
  SDL_UnlockMutex(shell.lock);
}

static void shell_send_int(uint16_t type, int value) {
  AnvilSurfaceInt message = { value };
  shell_send(type, &message, sizeof(message), NULL, 0);
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

static void send_configure(void) {
  if (!shell.connected)
    return;
  AnvilSurfaceConfigure config = shell.last_config;
  config.window_mode = current_window_mode();
  config.live_resize = shell.live_resize;
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
  if (memcmp(&config, &shell.last_config, sizeof(config)) == 0 && shell.last_config.pixel_w)
    return;
  config.configuration++;
  SDL_ClearComposition(shell.window);
  shell.hit = (AnvilSurfaceHitTest){0};
  shell.last_config = config;
  shell_send(ANVIL_SURFACE_MSG_CONFIGURE, &config, sizeof(config), NULL, 0);
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

static void resize_buffers(void) {
  int pixel_w = 0, pixel_h = 0;
  client_pixel_size(&pixel_w, &pixel_h);
  if (pixel_w <= 0 || pixel_h <= 0) return;
  if (pixel_w == shell.buffer_w && pixel_h == shell.buffer_h) return;
  shell.context->lpVtbl->OMSetRenderTargets(shell.context, 0, NULL, NULL);
  SAFE_RELEASE(shell.rtv);
  SAFE_RELEASE(shell.backbuffer);
  HRESULT hr = shell.swapchain->lpVtbl->ResizeBuffers(shell.swapchain, 0, (UINT)pixel_w, (UINT)pixel_h,
                                                      DXGI_FORMAT_UNKNOWN, 0);
  if (FAILED(hr) || !create_backbuffer_view()) {
    SDL_Log("Anvil shell could not resize its swapchain: 0x%08lx", (unsigned long)hr);
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
  if (FAILED(shell.device->lpVtbl->CreateTexture2D(shell.device, &desc, NULL, &shell.surface))) return false;
  shell.surface_w = width;
  shell.surface_h = height;
  return true;
}

static bool load_d3d11_frame(const AnvilSurfaceFrame *frame) {
  if (strcmp(frame->name, shell.shared_name) != 0 || !shell.shared) {
    SAFE_RELEASE(shell.shared_mutex);
    SAFE_RELEASE(shell.shared);
    shell.shared_name[0] = '\0';
    wchar_t name[ANVIL_SURFACE_NAME_MAX];
    MultiByteToWideChar(CP_UTF8, 0, frame->name, -1, name, ANVIL_SURFACE_NAME_MAX);
    HRESULT hr = shell.device1->lpVtbl->OpenSharedResourceByName(
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
  if (shell.shared_mutex->lpVtbl->AcquireSync(shell.shared_mutex, 0, SHELL_SYNC_TIMEOUT_MS) != S_OK) {
    shell.frame_busy = true;
    return false;
  }
  shell.context->lpVtbl->CopyResource(shell.context, (ID3D11Resource *)shell.surface,
                                      (ID3D11Resource *)shell.shared);
  shell.shared_mutex->lpVtbl->ReleaseSync(shell.shared_mutex, 0);
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
  if (strcmp(frame->name, shell.memory_name) != 0 || !shell.memory_view) {
    close_memory_frame();
    char lock_name[ANVIL_SURFACE_NAME_MAX + 8];
    snprintf(lock_name, sizeof(lock_name), "%s%s", frame->name, ANVIL_SURFACE_LOCK_SUFFIX);
    shell.memory_mapping = OpenFileMappingA(FILE_MAP_READ, FALSE, frame->name);
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
  DWORD wait = WaitForSingleObject(shell.memory_mutex, SHELL_SYNC_TIMEOUT_MS);
  if (wait != WAIT_OBJECT_0 && wait != WAIT_ABANDONED) { shell.frame_busy = true; return false; }
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
  ReleaseMutex(shell.memory_mutex);
  return ok;
}

static void ui_fill(HDC dc, RECT rect, COLORREF color) {
  HBRUSH brush = CreateSolidBrush(color);
  FillRect(dc, &rect, brush);
  DeleteObject(brush);
}

static void update_ui(void) {
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
    if (FAILED(shell.device->lpVtbl->CreateTexture2D(shell.device, &desc, NULL, &shell.ui)))
      return;
    shell.ui_w = shell.buffer_w;
    shell.ui_h = shell.buffer_h;
    shell.ui_dirty = true;
  }
  HDC dc = shell.ui_dc;
  RECT all = {0, 0, shell.buffer_w, shell.buffer_h};
  RECT dirty[] = {{0, 0, shell.sidebar_w, shell.buffer_h}, shell.controls, shell.failure_card};
  bool full = shell.ui_dirty;
  int dirty_count = shell.state == SHELL_FAILED ? 3 : 2;
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
  static const wchar_t *states[] = {L"Starting Project...", L"Ready", L"Closing Project...",
                                    L"Project failed"};
  RECT status = {0, shell.buffer_h - (LONG)(40 * shell.scale), shell.sidebar_w, shell.buffer_h};
  DrawTextW(dc,
            shell.state == SHELL_FAILED    ? L"!"
            : shell.state == SHELL_CLOSING ? L"..."
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
  shell.restart_button = (RECT){0};
  shell.close_button = (RECT){0};
  if (shell.state == SHELL_STARTING || shell.state == SHELL_FAILED) {
    RECT area = {shell.sidebar_w, shell.controls.bottom, shell.buffer_w, shell.buffer_h};
    DrawTextW(dc, states[shell.state], -1, &area, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    if (shell.state == SHELL_FAILED) {
      int x = (area.left + area.right) / 2,
          y = (area.top + area.bottom) / 2 + (int)(30 * shell.scale);
      shell.failure_card = (RECT){SDL_max(area.left, x - (int)(180 * shell.scale)),
                                  SDL_max(area.top, y - (int)(90 * shell.scale)),
                                  SDL_min(area.right, x + (int)(180 * shell.scale)),
                                  SDL_min(area.bottom, y + (int)(50 * shell.scale))};
      int w = (int)(140 * shell.scale), h = (int)(32 * shell.scale), gap = (int)(8 * shell.scale);
      shell.restart_button = (RECT){x - w - gap, y, x - gap, y + h};
      shell.close_button = (RECT){x + gap, y, x + w + gap, y + h};
      ui_fill(dc, shell.restart_button, RGB(55, 55, 62));
      ui_fill(dc, shell.close_button, RGB(55, 55, 62));
      DrawTextW(dc, L"Restart Project", -1, &shell.restart_button,
                DT_CENTER | DT_VCENTER | DT_SINGLELINE);
      DrawTextW(dc, L"Close", -1, &shell.close_button, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    }
  }
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
  if (!shell.rtv)
    return;
  const FLOAT sidebar[4] = {0.09f, 0.09f, 0.11f, 1.0f};
  shell.context->lpVtbl->ClearRenderTargetView(shell.context, shell.rtv, sidebar);
  if (shell.have_surface) {
    D3D11_BOX box = {0,
                     0,
                     0,
                     (UINT)SDL_min(shell.surface_w, shell.last_config.pixel_w),
                     (UINT)SDL_min(shell.surface_h, shell.last_config.pixel_h),
                     1};
    if ((int)box.right > 0 && (int)box.bottom > 0) {
      shell.context->lpVtbl->CopySubresourceRegion(
          shell.context, (ID3D11Resource *)shell.backbuffer, 0, (UINT)shell.last_config.origin_x,
          (UINT)shell.last_config.origin_y, 0,
          (ID3D11Resource *)shell.surface, 0, &box);
    }
  }
  update_ui();
  copy_ui((RECT){0, 0, shell.sidebar_w, shell.buffer_h});
  copy_ui(shell.controls);
  if (shell.state == SHELL_STARTING || (shell.state == SHELL_FAILED && !shell.have_surface))
    copy_ui((RECT){shell.sidebar_w, shell.controls.bottom, shell.buffer_w, shell.buffer_h});
  else if (shell.state == SHELL_FAILED)
    copy_ui(shell.failure_card);
  HRESULT hr = shell.swapchain->lpVtbl->Present(shell.swapchain, 1, 0);
  if (FAILED(hr))
    SDL_Log("Anvil shell present failed: 0x%08lx", (unsigned long)hr);
}

static void finish_latency_probe(void) {
  if (shell.process.hProcess) TerminateProcess(shell.process.hProcess, 0);
  _Exit(0);
}

/* Copies the newest published frame into the private surface texture. */
static bool load_pending_frame(AnvilSurfaceFrame *frame) {
  SDL_LockMutex(shell.lock);
  bool pending = shell.frame_pending;
  *frame = shell.latest_frame;
  shell.frame_pending = false;
  SDL_UnlockMutex(shell.lock);
  if (!pending) return false;
  if (!anvil_surface_frame_matches(&shell.last_config, frame)) {
    set_frame_busy(false);
    SDL_Log("Shell discarded stale frame: configuration=%llu current=%llu",
      (unsigned long long)frame->configuration, (unsigned long long)shell.last_config.configuration);
    return false;
  }
  char prefix[80];
  SDL_snprintf(prefix, sizeof(prefix), frame->kind == ANVIL_SURFACE_FRAME_D3D11
    ? "Local\\AnvilSurface-%lu-" : "Local\\AnvilSurfaceMemory-%lu-", shell.process.dwProcessId);
  size_t prefix_length = strlen(prefix);
  if (strncmp(frame->name, prefix, prefix_length) || !frame->name[prefix_length] ||
      strspn(frame->name + prefix_length, "0123456789") != strlen(frame->name + prefix_length)) {
    fail_connection("unowned frame resource name");
    return false;
  }
  shell.frame_busy = false;
  bool loaded = frame->kind == ANVIL_SURFACE_FRAME_D3D11 ? load_d3d11_frame(frame)
              : frame->kind == ANVIL_SURFACE_FRAME_SHARED_MEMORY ? load_memory_frame(frame)
              : false;
  if (!loaded) {
    set_frame_busy(shell.frame_busy);
    if (shell.frame_busy) {
      SDL_LockMutex(shell.lock);
      if (shell.latest_frame.generation == frame->generation) shell.frame_pending = true;
      SDL_UnlockMutex(shell.lock);
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
  Uint64 deadline = SDL_GetTicksNS() + SHELL_RESIZE_WAIT_MS * SDL_NS_PER_MS;
  bool matched = false;
  SDL_LockMutex(shell.lock);
  for (;;) {
    if (shell.frame_pending && shell.latest_frame.width == width && shell.latest_frame.height == height) {
      matched = true;
      break;
    }
    Uint64 now = SDL_GetTicksNS();
    if (now >= deadline) break;
    SDL_WaitConditionTimeout(shell.frame_cond, shell.lock,
                             (Sint32)SDL_max(1, (deadline - now) / SDL_NS_PER_MS));
  }
  SDL_UnlockMutex(shell.lock);
  return matched;
}

/* Runs inside WM_SIZE, so Windows shows the new window size only together
 * with surface content of that size. This is how the direct window stays
 * smooth during live resize. */
static void resize_step(void) {
  resize_buffers();
  send_configure();
  int width = shell.buffer_w - shell.sidebar_w, height = shell.buffer_h;
  bool stale = !shell.have_surface || shell.surface_w != width || shell.surface_h != height;
  if (stale && shell.connected && shell.shown && !shell.resize_wait_disabled &&
      !wait_for_surface_size(width, height)) {
    shell.resize_wait_disabled = true;
    SDL_Log("Anvil shell resize to %dx%d timed out waiting for the surface", width, height);
  }
  AnvilSurfaceFrame frame;
  load_pending_frame(&frame);
  if (shell.shown) composite_and_present();
}

static void handle_frame(void) {
  AnvilSurfaceFrame frame;
  if (!load_pending_frame(&frame)) return;
  if (shell.state == SHELL_STARTING) set_state(SHELL_READY);
  composite_and_present();
  if (!shell.shown) {
    SDL_Log("Anvil shell showing its first %s frame %dx%d",
            frame.kind == ANVIL_SURFACE_FRAME_D3D11 ? "d3d11" : "memory", shell.surface_w, shell.surface_h);
    SDL_ShowWindow(shell.window);
    SDL_RaiseWindow(shell.window);
    shell.shown = true;
    anvil_latency_probe_start(shell.window, finish_latency_probe);
  }
  anvil_latency_probe_presented(frame.input_seq);
  if (shell.state == SHELL_READY && !shell.close_requested_ns) anvil_latency_probe_start(shell.window, finish_latency_probe);
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

static void handle_message(ShellMessage *message) {
  const void *payload = message->payload;
  int value =
      message->size == sizeof(AnvilSurfaceInt) ? ((const AnvilSurfaceInt *)payload)->value : 0;
  switch (message->type) {
  case ANVIL_SURFACE_MSG_EXIT_INTENT:
    if (!message->size) {
      shell.intentional_exit = true;
      SDL_Log("Project exit accepted by shell");
    }
    break;
  case ANVIL_SURFACE_MSG_RESTART:
    if (message->size > 1 && message->size < 32768 &&
        ((const char *)payload)[message->size - 1] == 0 && !memchr(payload, 0, message->size - 1)) {
      free(shell.restart_path);
      shell.restart_path = _strdup(payload);
      shell.intentional_exit = true;
    }
    break;
  case ANVIL_SURFACE_MSG_VISIBLE:
    if (message->size == sizeof(AnvilSurfaceInt)) {
      if (value && shell.have_surface) {
        SDL_ShowWindow(shell.window);
        shell.shown = true;
      } else if (!value) {
        SDL_HideWindow(shell.window);
        shell.shown = false;
      }
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
    shell.child_cursor = value;
    if (shell.pointer_in_surface || shell.surface_buttons)
      apply_cursor(value);
    break;
  case ANVIL_SURFACE_MSG_TEXT_INPUT: {
    if (message->size != sizeof(AnvilSurfaceTextInput))
      break;
    const AnvilSurfaceTextInput *input = payload;
    if (input->configuration != shell.last_config.configuration)
      break;
    if (input->active >= 0) {
      shell.text_active = input->active != 0;
      if (shell.text_active)
        SDL_StartTextInput(shell.window);
      else {
        SDL_ClearComposition(shell.window);
        SDL_StopTextInput(shell.window);
      }
    } else {
      SDL_Rect rect;
      int cursor;
      if (anvil_surface_text_area(&shell.last_config, input, &rect, &cursor)) {
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
        *(uint64_t *)payload == shell.last_config.configuration)
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
    SDL_SetWindowTitle(shell.window, title);
    free(title);
    break;
  }
  case ANVIL_SURFACE_MSG_HIT_TEST:
    if (message->size == sizeof(AnvilSurfaceHitTest) &&
        ((AnvilSurfaceHitTest *)payload)->configuration == shell.last_config.configuration) {
      memcpy(&shell.hit, payload, sizeof(shell.hit));
      shell.hit.title_height = SDL_clamp(shell.hit.title_height, 0, (int)(96 * shell.scale));
      controls_geometry();
      int available = SDL_max(0, shell.controls.left - shell.sidebar_w);
      shell.hit.client_x = SDL_clamp(shell.hit.client_x, 0, available);
      shell.hit.client_width = SDL_clamp(shell.hit.client_width, 0, available - shell.hit.client_x);
      shell.hit.client2_x = SDL_clamp(shell.hit.client2_x, 0, available);
      shell.hit.client2_width =
          SDL_clamp(shell.hit.client2_width, 0, available - shell.hit.client2_x);
      send_configure();
    }
    break;
  case ANVIL_SURFACE_MSG_RAISE:
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
  AnvilSurfaceInput input;
  SDL_zero(input);
  input.event = *event;
  input.configuration = shell.last_config.configuration;
  input.text_len = text ? (uint32_t)strlen(text) : 0;
  if (input.text_len > ANVIL_SURFACE_MAX_PAYLOAD - sizeof(input)) {
    fail_connection("input payload exceeds the protocol bound");
    return;
  }
  if (event->type == SDL_EVENT_TEXT_INPUT) input.event.text.text = NULL;
  if (event->type == SDL_EVENT_TEXT_EDITING) input.event.edit.text = NULL;
  if (event->type >= SDL_EVENT_DROP_FILE && event->type <= SDL_EVENT_DROP_POSITION) {
    input.event.drop.data = NULL;
    input.event.drop.source = NULL;
  }
  shell_send(ANVIL_SURFACE_MSG_INPUT, &input, sizeof(input), text, input.text_len);
}

static void clear_composition(void) {
  SDL_ClearComposition(shell.window);
  SDL_Event event = {0};
  event.type = SDL_EVENT_TEXT_EDITING;
  forward_event(&event, "");
}

static void cancel_input(void) {
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
    anvil_surface_translate_input(&shell.last_config, &event);
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
  POINT point = {(LONG)x, (LONG)y};
  if (PtInRect(&shell.controls, point)) {
    int width = SDL_max(1, (shell.controls.right - shell.controls.left) / 3);
    return SDL_min(2, ((int)x - shell.controls.left) / width);
  }
  if (shell.state == SHELL_FAILED) {
    if (PtInRect(&shell.restart_button, point))
      return 3;
    if (PtInRect(&shell.close_button, point))
      return 4;
  }
  return -1;
}

static void perform_control(int control) {
  SDL_Log("Shell native control: %d state=%d", control, shell.state);
  shell.resize_wait_disabled = true;
  if (control == 0)
    SDL_MinimizeWindow(shell.window);
  else if (control == 1) {
    if (current_window_mode() == ANVIL_SURFACE_WINDOW_MAXIMIZED)
      SDL_RestoreWindow(shell.window);
    else
      SDL_MaximizeWindow(shell.window);
  } else if (control == 3) {
    if (!shell.project_path) {
      SDL_Log("Shell Restart unavailable: no Project path");
      return;
    }
    if (shell.process.hProcess && WaitForSingleObject(shell.process.hProcess, 0) != WAIT_OBJECT_0) {
      SDL_Log("Shell Restart refused: previous Project has not exited");
      return;
    }
    shell.restart_path = _strdup(shell.project_path);
    if (!shell.restart_path || !start_project(0, NULL)) {
      free(shell.restart_path);
      shell.restart_path = NULL;
      set_state(SHELL_FAILED);
    } else {
      free(shell.restart_path);
      shell.restart_path = NULL;
      composite_and_present();
    }
  } else
    request_close();
}

static bool surface_contains(float x, float y) {
  const AnvilSurfaceConfigure *config = &shell.last_config;
  return x >= config->origin_x && y >= config->origin_y && x < config->origin_x + config->pixel_w &&
         y < config->origin_y + config->pixel_h;
}

static void route_motion(SDL_Event *event) {
  shell.pointer_x = event->motion.x;
  shell.pointer_y = event->motion.y;
  int control = control_at(event->motion.x, event->motion.y);
  if (shell.hovered_control != control) {
    shell.hovered_control = control;
    shell.ui_hover_dirty = true;
    composite_and_present();
  }
  if (!shell.surface_buttons && (control >= 0 || shell.pressed_control >= 0 ||
                                 shell.state == SHELL_STARTING || shell.state == SHELL_FAILED)) {
    leave_surface();
    return;
  }
  bool inside = surface_contains(event->motion.x, event->motion.y) && control < 0;
  if (!inside)
    leave_surface();
  if (shell.surface_buttons || inside) {
    if (inside && !shell.pointer_in_surface) {
      shell.pointer_in_surface = true;
      apply_cursor(shell.child_cursor);
      SDL_Event enter = {0};
      enter.type = SDL_EVENT_WINDOW_MOUSE_ENTER;
      forward_event(&enter, NULL);
    }
    anvil_surface_translate_input(&shell.last_config, event);
    forward_event(event, NULL);
  }
}

static void route_button(SDL_Event *event) {
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
  if (shell.state == SHELL_STARTING || shell.state == SHELL_FAILED)
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
  anvil_surface_translate_input(&shell.last_config, event);
  forward_event(event, NULL);
}

static void request_close(void) {
  if (!shell.process.hProcess || WaitForSingleObject(shell.process.hProcess, 0) == WAIT_OBJECT_0) {
    shell.failed_close = true;
    return;
  }
  Uint64 now = SDL_GetTicksNS();
  if (!shell.close_requested_ns)
    shell.close_requested_ns = now;
  if (!shell.connected) {
    set_state(SHELL_CLOSING);
    composite_and_present();
    return;
  }
  set_state(SHELL_CLOSING);
  composite_and_present();
  shell_send(ANVIL_SURFACE_MSG_CLOSE, NULL, 0, NULL, 0);
}

static void handle_connected(void) {
  SDL_Log("Anvil shell connected to surface process %lu", (unsigned long)shell.process.dwProcessId);
  shell.connected = true;
  send_configure();
  bool focused = anvil_latency_probe_enabled() ||
                 (SDL_GetWindowFlags(shell.window) & SDL_WINDOW_INPUT_FOCUS) != 0;
  shell_send_int(ANVIL_SURFACE_MSG_FOCUS, focused ? 1 : 0);
  if (shell.close_requested_ns)
    shell_send(ANVIL_SURFACE_MSG_CLOSE, NULL, 0, NULL, 0);
}

SDL_AppResult anvil_shell_event(void *appstate, SDL_Event *event) {
  (void)appstate;
  if (event->type == shell.event_type) {
    if (event->user.windowID != shell.connection) {
      if (event->user.code == SHELL_EVENT_MESSAGE)
        free(event->user.data1);
      return SDL_APP_CONTINUE;
    }
    switch (event->user.code) {
    case SHELL_EVENT_CONNECTED:
      handle_connected();
      break;
    case SHELL_EVENT_FRAME:
      handle_frame();
      break;
    case SHELL_EVENT_DISCONNECTED:
      if (!shell.intentional_exit)
        fail_connection("pipe write failed");
      break;
    case SHELL_EVENT_MESSAGE:
      handle_message(event->user.data1);
      free(event->user.data1);
      break;
    case SHELL_EVENT_EXITED:
      SDL_Log("Anvil shell surface process exited with code %d", (int)(intptr_t)event->user.data2);
      if (shell.restart_path) {
        free(shell.project_path);
        shell.project_path = _strdup(shell.restart_path);
        if (!start_project(0, NULL))
          return SDL_APP_FAILURE;
        free(shell.restart_path);
        shell.restart_path = NULL;
        return SDL_APP_CONTINUE;
      }
      if (shell.intentional_exit)
        return SDL_APP_SUCCESS;
      set_state(SHELL_FAILED);
      shell.connected = false;
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
    request_close();
    if (shell.failed_close)
      return SDL_APP_SUCCESS;
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
    send_configure();
    break;
  case SDL_EVENT_WINDOW_FOCUS_GAINED:
  case SDL_EVENT_WINDOW_FOCUS_LOST:
    if (event->type == SDL_EVENT_WINDOW_FOCUS_LOST)
      cancel_input();
    if (!anvil_latency_probe_enabled()) {
      shell_send_int(ANVIL_SURFACE_MSG_FOCUS, event->type == SDL_EVENT_WINDOW_FOCUS_GAINED);
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
    if (shell.state == SHELL_READY || shell.state == SHELL_CLOSING)
      forward_event(event, NULL);
    break;
  case SDL_EVENT_TEXT_INPUT:
    if (shell.state == SHELL_READY || shell.state == SHELL_CLOSING)
      forward_event(event, event->text.text);
    break;
  case SDL_EVENT_TEXT_EDITING:
    if (shell.state == SHELL_READY || shell.state == SHELL_CLOSING)
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
        (shell.state == SHELL_READY || shell.state == SHELL_CLOSING)) {
      anvil_surface_translate_input(&shell.last_config, event);
      forward_event(event, NULL);
    }
    break;
  case SDL_EVENT_DROP_BEGIN:
  case SDL_EVENT_DROP_COMPLETE:
    if (shell.state == SHELL_READY || shell.state == SHELL_CLOSING)
      forward_event(event, NULL);
    break;
  case SDL_EVENT_DROP_POSITION:
  case SDL_EVENT_DROP_FILE:
  case SDL_EVENT_DROP_TEXT:
    if (!surface_contains(event->drop.x, event->drop.y) || control_at(event->drop.x, event->drop.y) >= 0 ||
        shell.state == SHELL_STARTING || shell.state == SHELL_FAILED) {
      if (event->type == SDL_EVENT_DROP_POSITION && shell.connected) {
        event->drop.x = event->drop.y = -1;
        forward_event(event, NULL);
      }
      break;
    }
    anvil_surface_translate_input(&shell.last_config, event);
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
  if (anvil_routing_probe_message(shell.window, msg, wparam, lparam)) return 0;
  switch (msg) {
    case WM_KILLFOCUS:
      cancel_input();
      shell_send_int(ANVIL_SURFACE_MSG_FOCUS, 0);
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
        .title_height = SDL_max(shell.controls.bottom, shell.hit.title_height),
        .controls_width = shell.controls.right-shell.controls.left,
        .resize_border = shell.last_config.resize_border > 0 ? shell.last_config.resize_border : (int)(8 * shell.scale),
        .client_x = shell.hit.client_x,
        .client_width = shell.hit.client_width,
        .client2_x = shell.hit.client2_x,
        .client2_width = shell.hit.client2_width,
        .content_x = shell.last_config.origin_x,
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
      send_configure();
      return result;
    }

    case WM_SIZE: {
      LRESULT result = CallWindowProcW(shell.sdl_wndproc, hwnd, msg, wparam, lparam);
      if (wparam != SIZE_MINIMIZED && shell.swapchain) resize_step();
      return result;
    }

    case WM_PAINT: {
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

static bool create_pipe(char *name, size_t name_size) {
  snprintf(name, name_size, "\\\\.\\pipe\\anvil-surface-%lu-%08x%08x",
           (unsigned long)GetCurrentProcessId(), (unsigned)SDL_rand_bits(), (unsigned)SDL_rand_bits());
  HANDLE handle = CreateNamedPipeA(
    name, PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
    PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
    1, SHELL_PIPE_BUFFER, SHELL_PIPE_BUFFER, 0, NULL);
  if (handle == INVALID_HANDLE_VALUE) return false;
  if (!anvil_ipc_pipe_init(&shell.pipe, handle, ANVIL_SURFACE_PROTOCOL_VERSION, ANVIL_SURFACE_MAX_PAYLOAD)) {
    CloseHandle(handle);
    return false;
  }
  return true;
}

static bool choose_project(int argc, char **argv) {
  char *cwd = SDL_GetCurrentDirectory();
  if (!cwd) return false;
  shell.project_path = _strdup(cwd); SDL_free(cwd);
  bool option_value = false;
  for (int i = 2; i < argc; i++) {
    if (option_value) { option_value = false; continue; }
    if (argv[i][0] == '-') {
      option_value = anvil_cli_option_value(argv[i]);
      continue;
    }
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, argv[i], -1, NULL, 0);
    wchar_t *path = count > 0 ? malloc(count * sizeof(wchar_t)) : NULL;
    wchar_t full[32768];
    if (!path || !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, argv[i], -1, path, count)) { free(path); return false; }
    DWORD n = GetFullPathNameW(path, SDL_arraysize(full), full, NULL); free(path);
    DWORD attrs = n && n < SDL_arraysize(full) ? GetFileAttributesW(full) : INVALID_FILE_ATTRIBUTES;
    if (attrs == INVALID_FILE_ATTRIBUTES || !(attrs & FILE_ATTRIBUTE_DIRECTORY)) {
      wchar_t *slash = wcsrchr(full, L'\\'); if (!slash) return false;
      if (slash == full + 2) slash[1] = 0; else *slash = 0;
      DWORD parent_attrs = GetFileAttributesW(full);
      if (parent_attrs == INVALID_FILE_ATTRIBUTES || !(parent_attrs & FILE_ATTRIBUTE_DIRECTORY)) continue;
    }
    int bytes = WideCharToMultiByte(CP_UTF8, 0, full, -1, NULL, 0, NULL, NULL);
    free(shell.project_path); shell.project_path = bytes > 0 ? malloc(bytes) : NULL;
    if (!shell.project_path) return false;
    WideCharToMultiByte(CP_UTF8, 0, full, -1, shell.project_path, bytes, NULL, NULL);
  }
  return shell.project_path != NULL;
}

static bool start_project(int argc, char **argv) {
  /* Replacement starts only after the old process exited. Join cancelled transport users first. */
  if (shell.reader || shell.writer) {
    cancel_input();
    SDL_StopTextInput(shell.window);
    shell.text_active = false;
    shell.connected = false;
    anvil_ipc_pipe_cancel(&shell.pipe);
    SDL_LockMutex(shell.lock);
    shell.writer_stop = true;
    SDL_BroadcastCondition(shell.queue_cond);
    SDL_UnlockMutex(shell.lock);
    if (shell.writer)
      SDL_WaitThread(shell.writer, NULL);
    if (shell.reader)
      SDL_WaitThread(shell.reader, NULL);
    shell.reader = shell.writer = NULL;
    anvil_ipc_pipe_close(&shell.pipe);
    SAFE_RELEASE(shell.shared_mutex);
    SAFE_RELEASE(shell.shared);
    shell.shared_name[0] = 0;
    close_memory_frame();
    CloseHandle(shell.process.hThread);
    CloseHandle(shell.process.hProcess);
    while (shell.queue_head) {
      ShellMessage *next = shell.queue_head->next;
      free(shell.queue_head);
      shell.queue_head = next;
    }
    shell.queue_tail = NULL;
    shell.queue_bytes = 0;
    shell.writer_stop = false;
    shell.frame_pending = false;
    shell.have_surface = false;
    shell.close_requested_ns = 0;
    shell.last_config = (AnvilSurfaceConfigure){0};
    shell.surface_buttons = 0;
    shell.pointer_in_surface = false;
    SDL_ClearComposition(shell.window);
    SDL_CaptureMouse(false);
  }
  shell.intentional_exit = false;
  shell.connection++;
  set_state(SHELL_STARTING);
  shell.ui_dirty = true;
  shell.failed_close = false;
  shell.hovered_control = shell.pressed_control = -1;
  char pipe_name[128];
  if (!create_pipe(pipe_name, sizeof(pipe_name)) || !launch_child(argc, argv, pipe_name))
    return false;
  shell.reader = SDL_CreateThread(reader_thread, "anvil-shell-reader", NULL);
  shell.writer = SDL_CreateThread(writer_thread, "anvil-shell-writer", NULL);
  return shell.reader && shell.writer;
}

SDL_AppResult anvil_shell_init(void **appstate, int argc, char **argv) {
  *appstate = &shell;
  shell.child_cursor = ANVIL_SURFACE_CURSOR_ARROW;
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
  shell.lock = SDL_CreateMutex();
  shell.queue_cond = SDL_CreateCondition();
  shell.frame_cond = SDL_CreateCondition();
  if (!shell.event_type || !shell.lock || !shell.queue_cond || !shell.frame_cond)
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
  if (!init_d3d11()) {
    SDL_Log("Anvil shell could not initialize Direct3D 11.");
    return SDL_APP_FAILURE;
  }

  if (!choose_project(argc, argv) || !start_project(argc, argv)) {
    SDL_Log("Anvil shell could not start its surface process: %lu", (unsigned long)GetLastError());
    set_state(SHELL_FAILED);
  }
  composite_and_present();
  SDL_ShowWindow(shell.window);
  shell.shown = true;
  if (shell.state == SHELL_STARTING)
    SDL_Log("Shell state: Starting");
  return SDL_APP_CONTINUE;
}

SDL_AppResult anvil_shell_iterate(void *appstate) {
  (void)appstate;
  if (shell.frame_busy) handle_frame();
  return shell.failed_close ? SDL_APP_SUCCESS : SDL_APP_CONTINUE;
}

void anvil_shell_quit(void *appstate, SDL_AppResult result) {
  (void)appstate;
  (void)result;
  /* Project loss detection owns save/detach and its deadline. Never kill it with a shell job. */
  if (shell.pipe.handle) anvil_ipc_pipe_cancel(&shell.pipe);
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
