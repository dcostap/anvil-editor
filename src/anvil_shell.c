#include "anvil_shell.h"

#ifdef _WIN32

#include "surface_protocol.h"
#include "input_latency_probe.h"
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
#define SHELL_FORCE_CLOSE_NS (3ull * SDL_NS_PER_SECOND)
#define SHELL_SYNC_TIMEOUT_MS 100
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
};

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
  HANDLE job;
  AnvilSurfacePipe pipe;
  bool connected;

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
  bool pointer_in_surface;
  AnvilSurfaceHitTest hit;
  int child_cursor;
  SDL_Cursor *cursors[ANVIL_SURFACE_CURSOR_COUNT];
  Uint64 close_requested_ns;
  bool shown;
} Shell;

static Shell shell;

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
  size_t capacity = (size_t)exe_len * 2 + strlen(pipe_arg) * 2 + 16;
  for (int i = 2; i < argc; i++) capacity += strlen(argv[i]) * 2 + 4;
  char *exe_utf8 = malloc((size_t)exe_len);
  char *line = malloc(capacity);
  wchar_t *wide = NULL;
  if (exe_utf8 && line) {
    WideCharToMultiByte(CP_UTF8, 0, exe, -1, exe_utf8, exe_len, NULL, NULL);
    size_t n = append_quoted_arg(line, exe_utf8);
    line[n++] = ' ';
    n += append_quoted_arg(line + n, pipe_arg);
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

  /* The job kills the surface process if the shell dies. Processes the
   * surface starts, such as new windows and terminals, break away. */
  shell.job = CreateJobObjectW(NULL, NULL);
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
  ZeroMemory(&limits, sizeof(limits));
  limits.BasicLimitInformation.LimitFlags =
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
  if (!shell.job ||
      !SetInformationJobObject(shell.job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
    free(command_line);
    return false;
  }

  STARTUPINFOW startup;
  ZeroMemory(&startup, sizeof(startup));
  startup.cb = sizeof(startup);
  BOOL created = CreateProcessW(exe, command_line, NULL, NULL, FALSE, CREATE_SUSPENDED,
                                NULL, NULL, &startup, &shell.process);
  free(command_line);
  if (!created) return false;
  if (!AssignProcessToJobObject(shell.job, shell.process.hProcess)) {
    TerminateProcess(shell.process.hProcess, 1);
    return false;
  }
  ResumeThread(shell.process.hThread);
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
  AnvilSurfaceHeader header;
  if (payload && wait_for_child_connection() &&
      anvil_surface_pipe_read(&shell.pipe, &header, payload, ANVIL_SURFACE_MAX_PAYLOAD) &&
      header.type == ANVIL_SURFACE_MSG_HELLO) {
    push_shell_event(SHELL_EVENT_CONNECTED, NULL, 0);
    while (anvil_surface_pipe_read(&shell.pipe, &header, payload, ANVIL_SURFACE_MAX_PAYLOAD)) {
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
    while (!shell.queue_head) SDL_WaitCondition(shell.queue_cond, shell.lock);
    ShellMessage *message = shell.queue_head;
    shell.queue_head = message->next;
    if (!shell.queue_head) shell.queue_tail = NULL;
    shell.queue_bytes -= message->size;
    SDL_UnlockMutex(shell.lock);
    anvil_surface_pipe_write(&shell.pipe, message->type, message->payload, message->size, NULL, 0);
    free(message);
  }
  return 0;
}

/* Main-thread sends never block on the pipe. A hung surface process can not
 * stall the shell window; once the queue is full, new input is dropped. */
static void shell_send(uint16_t type, const void *payload, uint32_t size,
                       const void *tail, uint32_t tail_size) {
  if (!shell.connected) return;
  uint32_t total = size + tail_size;
  if (total > ANVIL_SURFACE_MAX_PAYLOAD) return;
  ShellMessage *message = malloc(sizeof(ShellMessage) + total);
  if (!message) return;
  message->next = NULL;
  message->type = type;
  message->size = total;
  if (size) memcpy(message->payload, payload, size);
  if (tail_size) memcpy(message->payload + size, tail, tail_size);

  SDL_LockMutex(shell.lock);
  if (shell.queue_bytes + total > SHELL_WRITE_QUEUE_LIMIT) {
    SDL_UnlockMutex(shell.lock);
    free(message);
    return;
  }
  if (shell.queue_tail) shell.queue_tail->next = message;
  else shell.queue_head = message;
  shell.queue_tail = message;
  shell.queue_bytes += total;
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
  if (!shell.connected) return;
  AnvilSurfaceConfigure config = shell.last_config;
  config.window_mode = current_window_mode();
  config.live_resize = shell.live_resize;
  if (config.window_mode != ANVIL_SURFACE_WINDOW_MINIMIZED) {
    /* A minimized window keeps the last surface size. */
    int pixel_w = 0, pixel_h = 0;
    client_pixel_size(&pixel_w, &pixel_h);
    config.pixel_w = SDL_max(1, pixel_w - shell.sidebar_w);
    config.pixel_h = SDL_max(1, pixel_h);
    SDL_GetWindowPosition(shell.window, &config.window_x, &config.window_y);
    SDL_GetWindowSize(shell.window, &config.window_w, &config.window_h);
  }
  config.display_scale = shell.scale;
  config.refresh_hz = current_refresh_rate();
  if (memcmp(&config, &shell.last_config, sizeof(config)) == 0 && shell.last_config.pixel_w) return;
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
  if (!ensure_surface_texture((int)desc.Width, (int)desc.Height)) return false;
  if (shell.shared_mutex->lpVtbl->AcquireSync(shell.shared_mutex, 0, SHELL_SYNC_TIMEOUT_MS) != S_OK) {
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
    shell.memory_mutex = OpenMutexA(SYNCHRONIZE, FALSE, lock_name);
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
  if (wait != WAIT_OBJECT_0 && wait != WAIT_ABANDONED) return false;
  const AnvilSurfaceMemoryHeader *header = (const AnvilSurfaceMemoryHeader *)shell.memory_view;
  bool ok = header->width > 0 && header->height > 0 && header->stride >= header->width * 4 &&
            sizeof(*header) + (size_t)header->stride * (size_t)header->height <= shell.memory_size &&
            ensure_surface_texture(header->width, header->height);
  if (ok) {
    shell.context->lpVtbl->UpdateSubresource(shell.context, (ID3D11Resource *)shell.surface, 0, NULL,
                                             shell.memory_view + sizeof(*header), (UINT)header->stride, 0);
  }
  ReleaseMutex(shell.memory_mutex);
  return ok;
}

static void composite_and_present(void) {
  if (!shell.rtv) return;
  const FLOAT sidebar[4] = { 0.09f, 0.09f, 0.11f, 1.0f };
  shell.context->lpVtbl->ClearRenderTargetView(shell.context, shell.rtv, sidebar);
  if (shell.have_surface) {
    D3D11_BOX box = { 0, 0, 0,
                      (UINT)SDL_min(shell.surface_w, shell.buffer_w - shell.sidebar_w),
                      (UINT)SDL_min(shell.surface_h, shell.buffer_h), 1 };
    if ((int)box.right > 0 && (int)box.bottom > 0) {
      shell.context->lpVtbl->CopySubresourceRegion(shell.context, (ID3D11Resource *)shell.backbuffer, 0,
                                                   (UINT)shell.sidebar_w, 0, 0,
                                                   (ID3D11Resource *)shell.surface, 0, &box);
    }
  }
  HRESULT hr = shell.swapchain->lpVtbl->Present(shell.swapchain, 1, 0);
  if (FAILED(hr)) SDL_Log("Anvil shell present failed: 0x%08lx", (unsigned long)hr);
}

static void finish_latency_probe(void) {
  if (shell.job) TerminateJobObject(shell.job, 0);
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

  bool loaded = frame->kind == ANVIL_SURFACE_FRAME_D3D11 ? load_d3d11_frame(frame)
              : frame->kind == ANVIL_SURFACE_FRAME_SHARED_MEMORY ? load_memory_frame(frame)
              : false;
  if (!loaded) return false;
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
}

/* ------------------------------------------------------------------------ */
/* Messages from the surface process                                        */

static void apply_cursor(int cursor) {
  static const SDL_SystemCursor system_cursors[ANVIL_SURFACE_CURSOR_COUNT] = {
    SDL_SYSTEM_CURSOR_DEFAULT, SDL_SYSTEM_CURSOR_TEXT, SDL_SYSTEM_CURSOR_EW_RESIZE,
    SDL_SYSTEM_CURSOR_NS_RESIZE, SDL_SYSTEM_CURSOR_POINTER, SDL_SYSTEM_CURSOR_CROSSHAIR,
    SDL_SYSTEM_CURSOR_MOVE, SDL_SYSTEM_CURSOR_MOVE,
  };
  if (cursor < 0 || cursor >= ANVIL_SURFACE_CURSOR_COUNT) cursor = ANVIL_SURFACE_CURSOR_ARROW;
  if (!shell.cursors[cursor]) shell.cursors[cursor] = SDL_CreateSystemCursor(system_cursors[cursor]);
  SDL_SetCursor(shell.cursors[cursor]);
}

static void apply_window_mode(int mode) {
  bool fullscreen = (SDL_GetWindowFlags(shell.window) & SDL_WINDOW_FULLSCREEN) != 0;
  if (mode != ANVIL_SURFACE_WINDOW_FULLSCREEN && fullscreen) SDL_SetWindowFullscreen(shell.window, false);
  switch (mode) {
    case ANVIL_SURFACE_WINDOW_MINIMIZED: SDL_MinimizeWindow(shell.window); break;
    case ANVIL_SURFACE_WINDOW_MAXIMIZED: SDL_MaximizeWindow(shell.window); break;
    case ANVIL_SURFACE_WINDOW_FULLSCREEN: SDL_SetWindowFullscreen(shell.window, true); break;
    default: SDL_RestoreWindow(shell.window); break;
  }
}

static void handle_message(ShellMessage *message) {
  const void *payload = message->payload;
  int value = message->size == sizeof(AnvilSurfaceInt) ? ((const AnvilSurfaceInt *)payload)->value : 0;
  switch (message->type) {
    case ANVIL_SURFACE_MSG_CURSOR:
      shell.child_cursor = value;
      if (shell.pointer_in_surface || shell.surface_buttons) apply_cursor(value);
      break;
    case ANVIL_SURFACE_MSG_TEXT_INPUT: {
      if (message->size != sizeof(AnvilSurfaceTextInput)) break;
      const AnvilSurfaceTextInput *input = payload;
      if (input->active > 0) SDL_StartTextInput(shell.window);
      else if (input->active == 0) SDL_StopTextInput(shell.window);
      else {
        SDL_Rect rect = { input->x + shell.sidebar_w, input->y, input->w, input->h };
        SDL_SetTextInputArea(shell.window, &rect, input->cursor);
      }
      break;
    }
    case ANVIL_SURFACE_MSG_CLEAR_IME:
      SDL_ClearComposition(shell.window);
      break;
    case ANVIL_SURFACE_MSG_WINDOW_MODE:
      apply_window_mode(value);
      break;
    case ANVIL_SURFACE_MSG_TITLE: {
      char *title = malloc((size_t)message->size + 1);
      if (!title) break;
      memcpy(title, payload, message->size);
      title[message->size] = '\0';
      SDL_SetWindowTitle(shell.window, title);
      free(title);
      break;
    }
    case ANVIL_SURFACE_MSG_HIT_TEST:
      if (message->size == sizeof(AnvilSurfaceHitTest)) memcpy(&shell.hit, payload, sizeof(shell.hit));
      break;
    case ANVIL_SURFACE_MSG_RAISE:
      if (shell.shown) SDL_RaiseWindow(shell.window);
      break;
    case ANVIL_SURFACE_MSG_FLASH:
      SDL_FlashWindow(shell.window, (SDL_FlashOperation)value);
      break;
    case ANVIL_SURFACE_MSG_SET_BOUNDS: {
      if (message->size != sizeof(AnvilSurfaceBounds)) break;
      const AnvilSurfaceBounds *bounds = payload;
      if (bounds->w <= 0 || bounds->h <= 0) break;
      SDL_SetWindowPosition(shell.window, bounds->x, bounds->y);
      SDL_SetWindowSize(shell.window, bounds->w, bounds->h);
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
  input.text_len = text ? (uint32_t)SDL_min(strlen(text), ANVIL_SURFACE_MAX_PAYLOAD / 2) : 0;
  shell_send(ANVIL_SURFACE_MSG_INPUT, &input, sizeof(input), text, input.text_len);
}

static void leave_surface(void) {
  if (!shell.pointer_in_surface) return;
  shell.pointer_in_surface = false;
  /* Motion outside the surface clears Title Bar hover state that the leave
   * event alone does not reach. */
  SDL_Event outside;
  SDL_zero(outside);
  outside.type = SDL_EVENT_MOUSE_MOTION;
  outside.motion.x = -1.0f;
  outside.motion.y = -1.0f;
  forward_event(&outside, NULL);
  SDL_Event leave;
  SDL_zero(leave);
  leave.type = SDL_EVENT_WINDOW_MOUSE_LEAVE;
  forward_event(&leave, NULL);
  apply_cursor(ANVIL_SURFACE_CURSOR_ARROW);
}

static void route_motion(SDL_Event *event) {
  if (shell.surface_buttons || event->motion.x >= shell.sidebar_w) {
    if (!shell.pointer_in_surface) {
      shell.pointer_in_surface = true;
      apply_cursor(shell.child_cursor);
    }
    event->motion.x -= shell.sidebar_w;
    forward_event(event, NULL);
  } else {
    leave_surface();
  }
}

static void route_button(SDL_Event *event) {
  Uint32 mask = SDL_BUTTON_MASK(event->button.button);
  bool down = event->type == SDL_EVENT_MOUSE_BUTTON_DOWN;
  if (down) {
    if (!shell.surface_buttons && event->button.x < shell.sidebar_w) return;
    shell.surface_buttons |= mask;
  } else {
    if (!(shell.surface_buttons & mask)) return;
    shell.surface_buttons &= ~mask;
  }
  event->button.x -= shell.sidebar_w;
  forward_event(event, NULL);
}

static void request_close(void) {
  Uint64 now = SDL_GetTicksNS();
  if (shell.close_requested_ns && now - shell.close_requested_ns > SHELL_FORCE_CLOSE_NS) {
    /* The surface process did not close after a second request. */
    TerminateProcess(shell.process.hProcess, 1);
    return;
  }
  if (!shell.close_requested_ns) shell.close_requested_ns = now;
  if (!shell.connected) {
    TerminateProcess(shell.process.hProcess, 1);
    return;
  }
  shell_send(ANVIL_SURFACE_MSG_CLOSE, NULL, 0, NULL, 0);
}

static void handle_connected(void) {
  SDL_Log("Anvil shell connected to surface process %lu", (unsigned long)shell.process.dwProcessId);
  shell.connected = true;
  send_configure();
  bool focused = anvil_latency_probe_enabled() ||
                 (SDL_GetWindowFlags(shell.window) & SDL_WINDOW_INPUT_FOCUS) != 0;
  shell_send_int(ANVIL_SURFACE_MSG_FOCUS, focused ? 1 : 0);
}

SDL_AppResult anvil_shell_event(void *appstate, SDL_Event *event) {
  (void)appstate;
  if (event->type == shell.event_type) {
    switch (event->user.code) {
      case SHELL_EVENT_CONNECTED: handle_connected(); break;
      case SHELL_EVENT_FRAME: handle_frame(); break;
      case SHELL_EVENT_MESSAGE:
        handle_message(event->user.data1);
        free(event->user.data1);
        break;
      case SHELL_EVENT_EXITED:
        SDL_Log("Anvil shell surface process exited with code %d", (int)(intptr_t)event->user.data2);
        return (intptr_t)event->user.data2 == 0 ? SDL_APP_SUCCESS : SDL_APP_FAILURE;
    }
    return SDL_APP_CONTINUE;
  }

  switch (event->type) {
    case SDL_EVENT_QUIT:
    case SDL_EVENT_WINDOW_CLOSE_REQUESTED:
      request_close();
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
      send_configure();
      break;
    case SDL_EVENT_WINDOW_FOCUS_GAINED:
    case SDL_EVENT_WINDOW_FOCUS_LOST:
      if (!anvil_latency_probe_enabled()) {
        shell_send_int(ANVIL_SURFACE_MSG_FOCUS, event->type == SDL_EVENT_WINDOW_FOCUS_GAINED);
      }
      break;
    case SDL_EVENT_WINDOW_MOUSE_LEAVE:
      if (!shell.surface_buttons) leave_surface();
      break;
    case SDL_EVENT_KEY_DOWN:
    case SDL_EVENT_KEY_UP:
      forward_event(event, NULL);
      break;
    case SDL_EVENT_TEXT_INPUT:
      forward_event(event, event->text.text);
      break;
    case SDL_EVENT_TEXT_EDITING:
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
      if (event->wheel.mouse_x >= shell.sidebar_w) {
        event->wheel.mouse_x -= shell.sidebar_w;
        forward_event(event, NULL);
      }
      break;
    case SDL_EVENT_DROP_BEGIN:
    case SDL_EVENT_DROP_POSITION:
    case SDL_EVENT_DROP_COMPLETE:
    case SDL_EVENT_DROP_FILE:
    case SDL_EVENT_DROP_TEXT:
      event->drop.x -= shell.sidebar_w;
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
  switch (msg) {
    case WM_NCCALCSIZE:
      return win32_frame_hwnd_nccalcsize(hwnd, wparam, lparam);

    case WM_NCHITTEST: {
      Win32FrameHitTest hit = {
        .title_height = shell.hit.title_height,
        .controls_width = shell.hit.controls_width,
        .resize_border = shell.hit.resize_border,
        .client_x = shell.hit.client_x,
        .client_width = shell.hit.client_width,
        .client2_x = shell.hit.client2_x,
        .client2_width = shell.hit.client2_width,
        .content_x = shell.sidebar_w,
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
  if (!anvil_surface_pipe_init(&shell.pipe, handle)) {
    CloseHandle(handle);
    return false;
  }
  return true;
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
  if (!shell.event_type || !shell.lock || !shell.queue_cond || !shell.frame_cond) return SDL_APP_FAILURE;

  const SDL_DisplayMode *mode = SDL_GetDesktopDisplayMode(SDL_GetPrimaryDisplay());
  int width = mode ? (int)(mode->w * 0.8) : 1280;
  int height = mode ? (int)(mode->h * 0.8) : 800;
  shell.window = SDL_CreateWindow("Anvil", width, height,
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

  char pipe_name[128];
  if (!create_pipe(pipe_name, sizeof(pipe_name)) || !launch_child(argc, argv, pipe_name)) {
    SDL_Log("Anvil shell could not start its surface process: %lu", (unsigned long)GetLastError());
    return SDL_APP_FAILURE;
  }
  SDL_Thread *reader = SDL_CreateThread(reader_thread, "anvil-shell-reader", NULL);
  SDL_Thread *writer = SDL_CreateThread(writer_thread, "anvil-shell-writer", NULL);
  if (!reader || !writer) return SDL_APP_FAILURE;
  SDL_DetachThread(reader);
  SDL_DetachThread(writer);
  return SDL_APP_CONTINUE;
}

SDL_AppResult anvil_shell_iterate(void *appstate) {
  (void)appstate;
  return SDL_APP_CONTINUE;
}

void anvil_shell_quit(void *appstate, SDL_AppResult result) {
  (void)appstate;
  (void)result;
  /* Closing the job ends a surface process that is still running. Process
   * exit releases the remaining handles and GPU objects. */
  if (shell.job) CloseHandle(shell.job);
  shell.job = NULL;
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
