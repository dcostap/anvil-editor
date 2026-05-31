#define SDL_MAIN_USE_CALLBACKS
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <string.h>
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include "api/api.h"
#include "system_events.h"
#include "renderer.h"
#include "custom_events.h"
#include "resize_diagnostics.h"
#include "win32_single_instance.h"

#ifdef _WIN32
  #include <windows.h>
#elif defined(__linux__) || defined(__serenity__)
  #include <unistd.h>
#elif defined(SDL_PLATFORM_APPLE)
  #include <mach-o/dyld.h>
#elif defined(__FreeBSD__)
  #include <sys/sysctl.h>
#endif

static void get_exe_filename(char *buf, int sz) {
#if _WIN32
  int len;
  wchar_t *buf_w = SDL_malloc(sizeof(wchar_t) * sz);
  if (buf_w) {
    len = GetModuleFileNameW(NULL, buf_w, sz - 1);
    buf_w[len] = L'\0';
    // if the conversion failed we'll empty the string
    if (!WideCharToMultiByte(CP_UTF8, 0, buf_w, -1, buf, sz, NULL, NULL))
      buf[0] = '\0';
    SDL_free(buf_w);
  } else {
    buf[0] = '\0';
  }
#elif __linux__ || __serenity__
  char path[] = "/proc/self/exe";
  ssize_t len = readlink(path, buf, sz - 1);
  if (len > 0)
    buf[len] = '\0';
#elif SDL_PLATFORM_APPLE
  /* use realpath to resolve a symlink if the process was launched from one.
  ** This happens when Homebrew installs a cack and creates a symlink in
  ** /usr/loca/bin for launching the executable from the command line. */
  unsigned size = sz;
  char exepath[size];
  _NSGetExecutablePath(exepath, &size);
  realpath(exepath, buf);
#elif __FreeBSD__
  size_t len = sz;
  const int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PATHNAME, -1 };
  sysctl(mib, 4, buf, &len, NULL, 0);
#else
  *buf = 0;
#endif
}

#ifdef _WIN32
#define ANVIL_OS_HOME "USERPROFILE"
#define ANVIL_PATHSEP_PATTERN "\\\\"
#define ANVIL_NONPATHSEP_PATTERN "[^\\\\]+"
#else
#define ANVIL_OS_HOME "HOME"
#define ANVIL_PATHSEP_PATTERN "/"
#define ANVIL_NONPATHSEP_PATTERN "[^/]+"
#endif

#ifdef SDL_PLATFORM_APPLE
void enable_momentum_scroll();
#ifdef MACOS_USE_BUNDLE
void set_macos_bundle_resources(lua_State *L);
#endif
#endif

#ifndef ANVIL_ARCH_TUPLE
  // https://learn.microsoft.com/en-us/cpp/preprocessor/predefined-macros?view=msvc-140
  #if defined(__x86_64__) || defined(_M_AMD64) || defined(__MINGW64__)
    #define ARCH_PROCESSOR "x86_64"
  #elif defined(__i386__) || defined(_M_IX86) || defined(__MINGW32__)
    #define ARCH_PROCESSOR "x86"
  #elif defined(__aarch64__) || defined(_M_ARM64) || defined (_M_ARM64EC)
    #define ARCH_PROCESSOR "aarch64"
  #elif defined(__arm__) || defined(_M_ARM)
    #define ARCH_PROCESSOR "arm"
  #endif

  #if _WIN32
    #define ARCH_PLATFORM "windows"
  #elif __linux__
    #define ARCH_PLATFORM "linux"
  #elif __FreeBSD__
    #define ARCH_PLATFORM "freebsd"
  #elif SDL_PLATFORM_APPLE
    #define ARCH_PLATFORM "darwin"
  #elif __serenity__
    #define ARCH_PLATFORM "serenity"
  #else
  #endif

  #if !defined(ARCH_PROCESSOR) || !defined(ARCH_PLATFORM)
    #error "Please define -DANVIL_ARCH_TUPLE."
  #endif

  #define ANVIL_ARCH_TUPLE ARCH_PROCESSOR "-" ARCH_PLATFORM
#endif

#ifdef LUA_JIT
  #define ANVIL_LUAJIT "true"
#else
  #define ANVIL_LUAJIT "false"
#endif

/* Application state shared across SDL3 callbacks. */
typedef struct {
  lua_State *L;
  int        argc;
  char     **argv;
  int        has_restarted;
  int        core_run_step_ref;
  bool       in_run_step;
  bool       live_resize;
  Uint64     last_resize_step_ns;
  uint64_t   resize_request_count;
  uint64_t   resize_request_throttled;
  uint64_t   resize_request_reentrant;
  uint64_t   resize_request_same_size;
  bool       pending_resize_frame;
  SDL_Window *pending_resize_window;
  char       pending_resize_reason[64];
  Uint32     last_rendered_resize_window_id;
  int        last_rendered_resize_pixel_w;
  int        last_rendered_resize_pixel_h;
} AppState;

static AppState *live_resize_app = NULL;
static bool renderer_initialized = false;
static bool custom_events_initialized = false;

static void log_resize_request(AppState *app, const char *reason, const char *action,
                               Uint64 since_last_ns, double run_ms) {
  anvil_resize_diag_log(&(AnvilResizeDiagEvent){
    .category = "resize_request",
    .name = action,
    .reason = reason,
    .live_resize = app ? app->live_resize : anvil_resize_diag_live_resize(),
    .in_run_step = app ? app->in_run_step : false,
    .queue_depth = system_pending_event_count(),
    .count_a = app ? (int)app->resize_request_count : 0,
    .count_b = (int)(since_last_ns / 1000000ull),
    .ms_a = run_ms
  });
}

void anvil_set_live_resize(bool live_resize) {
  AppState *app = live_resize_app;
  if (app) app->live_resize = live_resize;
  anvil_resize_diag_set_live_resize(live_resize);
}

static void get_window_pixel_size(SDL_Window *window, int *pixel_w, int *pixel_h) {
  if (pixel_w) *pixel_w = 0;
  if (pixel_h) *pixel_h = 0;
  if (!window) return;
  SDL_GetWindowSizeInPixels(window, pixel_w, pixel_h);
}

static double window_refresh_rate(SDL_Window *window) {
  if (!window) return 0.0;
  SDL_DisplayID display = SDL_GetDisplayForWindow(window);
  if (!display) return 0.0;
  const SDL_DisplayMode *mode = SDL_GetCurrentDisplayMode(display);
  if (mode && mode->refresh_rate > 0) return mode->refresh_rate;
  mode = SDL_GetDesktopDisplayMode(display);
  if (mode && mode->refresh_rate > 0) return mode->refresh_rate;
  return 0.0;
}

static Uint64 resize_min_interval_ns(AppState *app, SDL_Window *window) {
  if (app && app->live_resize) return 0;
  double hz = window_refresh_rate(window);
  if (hz < 30.0 || hz > 1000.0) hz = 120.0;
  return (Uint64)((double)SDL_NS_PER_SECOND / hz);
}

static bool resize_reason_allows_same_size(const char *reason) {
  if (!reason) return false;
  return strcmp(reason, "wm_paint") == 0 ||
         strcmp(reason, "wm_paint_owned") == 0 ||
         strcmp(reason, "wm_size_owned") == 0 ||
         strcmp(reason, "sdl_exposed") == 0 ||
         strcmp(reason, "sdl_focus_gained") == 0 ||
         strcmp(reason, "sdl_restored") == 0 ||
         strcmp(reason, "exit_sizemove") == 0 ||
         strcmp(reason, "reentrant_final") == 0;
}

static bool resize_reason_bypasses_throttle(const char *reason) {
  if (!reason) return false;
  return strcmp(reason, "exit_sizemove") == 0 ||
         strcmp(reason, "reentrant_final") == 0;
}

static void set_pending_resize_frame(AppState *app, SDL_Window *window, const char *reason) {
  if (!app) return;
  app->pending_resize_frame = true;
  app->pending_resize_window = window;
  SDL_strlcpy(app->pending_resize_reason, reason ? reason : "pending", sizeof(app->pending_resize_reason));
}

/* Lua init-code: loads and starts the core.  core.run() is now non-blocking
 * (it only sets up the run-loop state); SDL_AppIterate drives the loop by
 * calling core.run_step() on every frame. */
static const char *init_code =
  "core = false\n"
  "local os_exit = os.exit\n"
  "os.exit = function(code, close)\n"
  "  os_exit(code, close == nil and true or close)\n"
  "end\n"
  "xpcall(function()\n"
  "  local match = require('utf8extra').match\n"
  "  HOME = os.getenv('" ANVIL_OS_HOME "')\n"
  "  LUAJIT = " ANVIL_LUAJIT "\n"
  "  local exedir = match(EXEFILE, '^(.*)" ANVIL_PATHSEP_PATTERN ANVIL_NONPATHSEP_PATTERN "$')\n"
  "  local prefix = os.getenv('ANVIL_PREFIX') or match(exedir, '^(.*)" ANVIL_PATHSEP_PATTERN "bin$')\n"
  "  dofile((MACOS_RESOURCES or (prefix and prefix .. '/share/anvil' or exedir .. '/data')) .. '/core/start.lua')\n"
  "  core = require(os.getenv('ANVIL_RUNTIME') or 'core')\n"
  "  core.init()\n"
  "  core.run()\n"
  "end, function(err)\n"
  "  local error_path = 'error.txt'\n"
  "  io.stdout:write('Error: '..tostring(err)..'\\n')\n"
  "  io.stdout:write(debug.traceback('', 2)..'\\n')\n"
  "  if core and core.on_error then\n"
  "    error_path = USERDIR .. PATHSEP .. error_path\n"
  "    pcall(core.on_error, err)\n"
  "  else\n"
  "    local fp = io.open(error_path, 'wb')\n"
  "    fp:write('Error: ' .. tostring(err) .. '\\n')\n"
  "    fp:write(debug.traceback('', 2)..'\\n')\n"
  "    fp:close()\n"
  "    error_path = system.absolute_path(error_path)\n"
  "  end\n"
  "  system.show_fatal_error('Anvil internal error',\n"
  "    'An internal error occurred in a critical part of the application.\\n\\n'..\n"
  "    'Error: '..tostring(err)..'\\n\\n'..\n"
  "    'Details can be found in \\\"'..error_path..'\\\"')\n"
  "  os.exit(1)\n"
  "end)\n";

/* (Re-)create a Lua interpreter and run the init code. */
static bool init_lua_state(AppState *app) {
  app->L = luaL_newstate();
  luaL_openlibs(app->L);
  api_load_libs(app->L);

  lua_newtable(app->L);
  for (int i = 0; i < app->argc; i++) {
    lua_pushstring(app->L, app->argv[i]);
    lua_rawseti(app->L, -2, i + 1);
  }
  lua_setglobal(app->L, "ARGS");

  lua_pushstring(app->L, SDL_GetPlatform());
  lua_setglobal(app->L, "PLATFORM");

  lua_pushstring(app->L, ANVIL_ARCH_TUPLE);
  lua_setglobal(app->L, "ARCH");

  lua_pushboolean(app->L, app->has_restarted);
  lua_setglobal(app->L, "RESTARTED");

  char exename[2048];
  get_exe_filename(exename, sizeof(exename));
  if (*exename) {
    lua_pushstring(app->L, exename);
  } else {
    lua_pushstring(app->L, app->argv[0]);
  }
  lua_setglobal(app->L, "EXEFILE");

#ifdef MACOS_USE_BUNDLE
  set_macos_bundle_resources(app->L);
#endif

  if (luaL_loadstring(app->L, init_code)) {
    fprintf(stderr, "internal error when starting the application\n");
    return false;
  }
  lua_pcall(app->L, 0, 0, 0);

  /* Store a reference to core.run_step for faster lookup on SDL_AppIterate. */
  app->core_run_step_ref = -1;
  lua_getglobal(app->L, "core");
  if (lua_istable(app->L, -1)) {
    lua_getfield(app->L, -1, "run_step");
    if (lua_isfunction(app->L, -1)) {
      app->core_run_step_ref = luaL_ref(app->L, LUA_REGISTRYINDEX);
    } else {
      lua_pop(app->L, 1);
    }
  }
  lua_pop(app->L, 1);

  return true;
}


SDL_AppResult SDL_AppInit(void **appstate, int argc, char *argv[]) {
#ifdef _WIN32
  if (anvil_single_instance_forward_or_own(argc, argv)) {
    return SDL_APP_SUCCESS;
  }
#endif
#ifndef _WIN32
  signal(SIGPIPE, SIG_IGN);
#else
  /* Allow console output when called from anvil.com wrapper.
   * See: https://stackoverflow.com/q/73987850
   *      https://stackoverflow.com/q/17111308
  */
  if (getenv("ANVIL_COM_WRAP") && AttachConsole(ATTACH_PARENT_PROCESS)) {
    freopen("CONOUT$", "w", stdout);
    freopen("CONOUT$", "w", stderr);
    freopen("CONIN$", "r", stdin);
  }
#endif

#ifdef __linux__
  /* Use wayland by default if SDL_VIDEO_DRIVER not set and session type wayland */
  if (getenv("SDL_VIDEO_DRIVER") == NULL) {
    const char *session_type = getenv("XDG_SESSION_TYPE");
    if (session_type && strcmp(session_type, "wayland") == 0) {
      SDL_SetHint(SDL_HINT_VIDEO_DRIVER, "wayland");
    }
  }
#endif

  SDL_SetAppMetadata("Anvil", ANVIL_PROJECT_VERSION_STR, "io.github.dcostap.Anvil");
  if (!SDL_Init(SDL_INIT_EVENTS)) {
    fprintf(stderr, "Error initializing sdl: %s", SDL_GetError());
    return SDL_APP_FAILURE;
  }
  SDL_SetEventEnabled(SDL_EVENT_DROP_FILE, true);

  if (ren_init() != 0) {
    fprintf(stderr, "Error initializing renderer: %s\n", SDL_GetError());
    return SDL_APP_FAILURE;
  }
  renderer_initialized = true;

  if (!init_custom_events()) {
    fprintf(stderr, "Error initializing custom events: %s\n", SDL_GetError());
    return SDL_APP_FAILURE;
  }
  custom_events_initialized = true;

  if (!anvil_single_instance_start_server()) {
    /* Non-fatal: release native ownership so secondaries do not wait on a
     * pipe server that is unavailable. Existing Lua IPC remains fallback. */
    anvil_single_instance_stop();
  }

  AppState *app = SDL_malloc(sizeof(AppState));
  if (!app) {
    fprintf(stderr, "Out of memory\n");
    return SDL_APP_FAILURE;
  }
  app->L                 = NULL;
  app->argc              = argc;
  app->argv              = argv;
  app->has_restarted      = 0;
  app->core_run_step_ref  = -1;
  app->in_run_step        = false;
  app->live_resize        = false;
  app->last_resize_step_ns = 0;
  app->resize_request_count = 0;
  app->resize_request_throttled = 0;
  app->resize_request_reentrant = 0;
  app->resize_request_same_size = 0;
  app->pending_resize_frame = false;
  app->pending_resize_window = NULL;
  app->pending_resize_reason[0] = '\0';
  app->last_rendered_resize_window_id = 0;
  app->last_rendered_resize_pixel_w = 0;
  app->last_rendered_resize_pixel_h = 0;
  *appstate = app;
  live_resize_app = app;

#ifdef SDL_PLATFORM_APPLE
  enable_momentum_scroll();
#endif

  SDL_SetEventEnabled(SDL_EVENT_TEXT_INPUT, true);
  SDL_SetEventEnabled(SDL_EVENT_TEXT_EDITING, true);

  if (!init_lua_state(app))
    return SDL_APP_FAILURE;

  return SDL_APP_CONTINUE;
}


void anvil_request_resize_frame_for_window(SDL_Window *window, const char *reason);

static SDL_AppResult app_run_step_ex(AppState *app, bool immediate, const char *reason) {
  if (!app || !app->L) return SDL_APP_CONTINUE;
  if (app->in_run_step) {
    app->resize_request_reentrant++;
    set_pending_resize_frame(app, NULL, reason ? reason : "app_run_step");
    log_resize_request(app, reason ? reason : "app_run_step", "skip_reentrant", 0, 0.0);
    return SDL_APP_CONTINUE;
  }

  Uint64 run_start_ns = SDL_GetTicksNS();

  /* Call core.run_step() — one frame of the main loop.
   * Returns true  → keep running
   * Returns false → quit or restart */
  if (app->core_run_step_ref == -1) {
    fprintf(stderr, "Error: core.run_step not found or invalid\n");
    return SDL_APP_FAILURE;
  }

  app->in_run_step = true;
  lua_rawgeti(app->L, LUA_REGISTRYINDEX, app->core_run_step_ref);
  int nargs = 0;
  if (immediate) {
    lua_createtable(app->L, 0, 3);
    lua_pushboolean(app->L, true);
    lua_setfield(app->L, -2, "immediate");
    lua_pushstring(app->L, reason ? reason : "immediate");
    lua_setfield(app->L, -2, "reason");
    lua_pushboolean(app->L, app->live_resize || (reason && strcmp(reason, "exit_sizemove") == 0));
    lua_setfield(app->L, -2, "live_resize");
    nargs = 1;
  }
  if (lua_pcall(app->L, nargs, 1, 0) != LUA_OK) {
    app->in_run_step = false;
    const char *errmsg = lua_tostring(app->L, -1);
    lua_pop(app->L, 1);
    fprintf(stderr, "Error in core.run_step: %s\n", errmsg);

    lua_getglobal(app->L, "system");
    lua_getfield(app->L, -1, "show_fatal_error");
    lua_remove(app->L, -2); /* remove 'system' table */
    lua_pushstring(app->L, "Anvil internal error");
    lua_pushfstring(
      app->L,
      "    An internal error occurred in a critical part of the application.\n\n"
      "    Error: %s",
      errmsg
    );
    lua_call(app->L, 2, 0);
    lua_pop(app->L, 1);

    return SDL_APP_FAILURE;
  }

  bool should_continue = lua_toboolean(app->L, -1);
  lua_pop(app->L, 1);
  app->in_run_step = false;
  Uint64 run_end_ns = SDL_GetTicksNS();
  anvil_resize_diag_log(&(AnvilResizeDiagEvent){
    .category = "app_run_step",
    .name = immediate ? "end_immediate" : "end",
    .reason = reason,
    .live_resize = app->live_resize,
    .queue_depth = system_pending_event_count(),
    .ms_a = anvil_resize_diag_ticks_to_ms(run_start_ns, run_end_ns)
  });

  if (!should_continue) {
    /* Distinguish between quit and restart. */
    lua_getglobal(app->L, "core");
    lua_getfield(app->L, -1, "restart_request");
    bool restart = lua_toboolean(app->L, -1);
    lua_pop(app->L, 1);

    lua_getfield(app->L, -1, "exit_status");
    int exit_status = (int)luaL_optinteger(app->L, -1, 0);
    lua_pop(app->L, 2);

    if (restart) {
      /* Re-initialize the Lua state in place — mirrors the goto in old main(). */
      lua_close(app->L);
      app->L = NULL;
      app->has_restarted = 1;
      if (!init_lua_state(app))
        return SDL_APP_FAILURE;
      return SDL_APP_CONTINUE;
    }

    return exit_status == 0 ? SDL_APP_SUCCESS : SDL_APP_FAILURE;
  }

  if (app->pending_resize_frame) {
    SDL_Window *pending_window = app->pending_resize_window;
    char pending_reason[64];
    SDL_strlcpy(pending_reason,
                app->pending_resize_reason[0] ? app->pending_resize_reason : "reentrant_final",
                sizeof(pending_reason));
    app->pending_resize_frame = false;
    app->pending_resize_window = NULL;
    app->pending_resize_reason[0] = '\0';
    anvil_request_resize_frame_for_window(pending_window,
                                          pending_reason[0] ? pending_reason : "reentrant_final");
  }

  return SDL_APP_CONTINUE;
}

static SDL_AppResult app_run_step(AppState *app) {
  return app_run_step_ex(app, false, "iterate");
}


void anvil_request_resize_frame_for_window(SDL_Window *window, const char *reason) {
  AppState *app = live_resize_app;
  if (!app || !app->L || app->core_run_step_ref == -1) return;

  int pixel_w = 0, pixel_h = 0;
  get_window_pixel_size(window, &pixel_w, &pixel_h);
  Uint32 window_id = window ? SDL_GetWindowID(window) : 0;

  app->resize_request_count++;
  const Uint64 now = SDL_GetTicksNS();
  const Uint64 since_last = app->last_resize_step_ns == 0 ? 0 : now - app->last_resize_step_ns;
  const Uint64 min_interval = resize_reason_bypasses_throttle(reason) ? 0 : resize_min_interval_ns(app, window);

  if (app->in_run_step) {
    app->resize_request_reentrant++;
    set_pending_resize_frame(app, window, "reentrant_final");
    log_resize_request(app, reason, "skip_reentrant", since_last, 0.0);
    return;
  }

  if (window_id != 0 && !resize_reason_allows_same_size(reason) &&
      app->last_rendered_resize_window_id == window_id &&
      app->last_rendered_resize_pixel_w == pixel_w &&
      app->last_rendered_resize_pixel_h == pixel_h) {
    app->resize_request_same_size++;
    log_resize_request(app, reason, "skip_same_size", since_last, 0.0);
    return;
  }

  if (min_interval > 0 && app->last_resize_step_ns != 0 && since_last < min_interval) {
    app->resize_request_throttled++;
    log_resize_request(app, reason, "skip_throttle", since_last, 0.0);
    return;
  }

  app->last_resize_step_ns = now;
  Uint64 run_start_ns = SDL_GetTicksNS();
  SDL_AppResult result = app_run_step_ex(app, true, reason ? reason : "resize");
  (void)result;
  Uint64 run_end_ns = SDL_GetTicksNS();
  if (window_id != 0) {
    get_window_pixel_size(window, &pixel_w, &pixel_h);
    app->last_rendered_resize_window_id = window_id;
    app->last_rendered_resize_pixel_w = pixel_w;
    app->last_rendered_resize_pixel_h = pixel_h;
  }
  log_resize_request(app, reason, "run_immediate", since_last,
                     anvil_resize_diag_ticks_to_ms(run_start_ns, run_end_ns));
}

void anvil_request_resize_frame_reason(const char *reason) {
  anvil_request_resize_frame_for_window(NULL, reason);
}

void anvil_request_resize_frame(void) {
  anvil_request_resize_frame_reason("unknown");
}


static bool event_wants_immediate_resize_frame(const SDL_Event *event) {
  switch (event->type) {
    case SDL_EVENT_WINDOW_RESIZED:
    case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
    case SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED:
    case SDL_EVENT_WINDOW_EXPOSED:
    case SDL_EVENT_WINDOW_FOCUS_GAINED:
    case SDL_EVENT_WINDOW_RESTORED:
      return true;
    default:
      return false;
  }
}

SDL_AppResult SDL_AppEvent(void *appstate, SDL_Event *event) {
  AppState *app = (AppState *)appstate;
  system_push_event(event);

  /* Windows live-resize runs inside a modal sizing loop. SDL may keep sending
   * resize/paint events while normal SDL_AppIterate callbacks are sparse, so
   * render a throttled frame directly from the event callback. The Lua side
   * treats active resize as a frame-rate override, which keeps this from being
   * skipped by the normal FPS cap. */
  if (app && event_wants_immediate_resize_frame(event)) {
    const char *reason = anvil_resize_diag_event_reason(event->type);
    anvil_resize_diag_log(&(AnvilResizeDiagEvent){
      .category = "sdl_event",
      .name = app->live_resize ? "skip_live_resize_duplicate" : "immediate_resize_candidate",
      .reason = reason,
      .window_id = event->window.windowID,
      .live_resize = app->live_resize,
      .in_run_step = app->in_run_step,
      .queue_depth = system_pending_event_count(),
      .point_w = event->window.data1,
      .point_h = event->window.data2
    });
    if (!app->live_resize) {
      anvil_request_resize_frame_for_window(SDL_GetWindowFromID(event->window.windowID), reason);
    }
  }

  return SDL_APP_CONTINUE;
}


SDL_AppResult SDL_AppIterate(void *appstate) {
  return app_run_step((AppState *)appstate);
}


void SDL_AppQuit(void *appstate, SDL_AppResult result) {
  (void)result;
  AppState *app = appstate;
  if (app) {
    if (live_resize_app == app) live_resize_app = NULL;
    if (app->L) lua_close(app->L);
    SDL_free(app);
  }
  anvil_single_instance_stop();
  if (custom_events_initialized) {
    free_custom_events();
    custom_events_initialized = false;
  }
  if (renderer_initialized) {
    ren_free();
    renderer_initialized = false;
  }
}
