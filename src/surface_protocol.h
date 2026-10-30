#ifndef ANVIL_SURFACE_PROTOCOL_H
#define ANVIL_SURFACE_PROTOCOL_H

/* Wire protocol between the native shell and a hosted surface process.
 *
 * The shell owns the native window. A hosted process renders offscreen and
 * publishes complete frames by name. Messages are length-prefixed binary
 * records on one duplex named pipe. Both ends run the same executable, so
 * SDL_Event payloads keep the same layout on both sides. */

#include <stdbool.h>
#include <stdint.h>
#include <SDL3/SDL.h>

#define ANVIL_SURFACE_PROTOCOL_VERSION 41u
#define ANVIL_SURFACE_MAX_PAYLOAD (64u * 1024u)
#define ANVIL_SURFACE_NAME_MAX 96
/* A Terminal Session id: 32 lowercase hex digits. */
#define ANVIL_SURFACE_TERMINAL_ID_LEN 32
#define ANVIL_SURFACE_PIPE_ARG "--anvil-hosted-pipe="
#define ANVIL_SHELL_ARG "--shell"
#define ANVIL_PROJECT_ARG "--project"
#define ANVIL_PROJECT_RESTART_ARG "--anvil-project-restart"
#define ANVIL_PROJECT_ARGUMENTS_ARG "--anvil-project-arguments"

typedef enum {
  /* Shell to surface process. */
  ANVIL_SURFACE_MSG_CONFIGURE = 1,
  ANVIL_SURFACE_MSG_INPUT = 2,
  ANVIL_SURFACE_MSG_FOCUS = 3,
  ANVIL_SURFACE_MSG_CLOSE = 4,
  ANVIL_SURFACE_MSG_DIALOG_RESULT = 5,
  ANVIL_SURFACE_MSG_SIDEBAR_MODEL = 6,
  ANVIL_SURFACE_MSG_SIDEBAR_CHANGED = 7,
  /* Another process saved a Color Theme; reload the saved one. No payload. */
  ANVIL_SURFACE_MSG_COLOR_THEME_CHANGED = 8,
  /* Focus this Terminal Session, opening it in this Project if no view shows it. Payload: id + NUL. */
  ANVIL_SURFACE_MSG_FOCUS_TERMINAL = 9,
  /* A Project shows a Color Theme it has not saved. Draw it until the next save or preview. Payload: the
   * preview + NUL, or only NUL to draw the saved Color Theme again. */
  ANVIL_SURFACE_MSG_COLOR_THEME_PREVIEWED = 10,
  /* Answer with ANVIL_SURFACE_MSG_PONG from the UI thread. A Project whose UI thread is stuck does not answer.
   * Payload: AnvilSurfaceInt, returned unchanged. */
  ANVIL_SURFACE_MSG_PING = 11,
  /* Save the Workspace and exit, leaving Terminal Sessions running. No payload. */
  ANVIL_SURFACE_MSG_PREPARE_UPDATE = 12,
  /* Pane request delivery: AnvilSurfacePaneDelivery followed by request text. */
  ANVIL_SURFACE_MSG_PANE_ACTION = 13,
  /* Another process saved the Zoom. Payload: AnvilSurfaceZoom. */
  ANVIL_SURFACE_MSG_ZOOM_CHANGED = 14,
  /* Open files, or an Untitled Editor, after this Terminal Session's command ends.
   * Payload: id + NUL, then zero or more absolute paths, each followed by NUL. */
  ANVIL_SURFACE_MSG_TERMINAL_EDITOR = 15,
  /* Ctrl-wheel over the Sidebar. Payload: AnvilSurfaceInt, signed Zoom direction. */
  ANVIL_SURFACE_MSG_ZOOM_WHEEL = 16,
  /* Terminal quit scope and the choice already made for this Window. Payload: AnvilSurfaceInt. */
  ANVIL_SURFACE_MSG_TERMINAL_QUIT_CONTEXT = 18,
  /* The answer to ANVIL_SURFACE_MSG_TOGGLE_ALT_NAVIGATION. Payload: AnvilSurfaceInt, 1 when Alt Navigation is on. */
  ANVIL_SURFACE_MSG_ALT_NAVIGATION = 19,

  /* Surface process to shell. */
  ANVIL_SURFACE_MSG_HELLO = 64,
  ANVIL_SURFACE_MSG_FRAME = 65,
  ANVIL_SURFACE_MSG_CURSOR = 66,
  ANVIL_SURFACE_MSG_TEXT_INPUT = 67,
  ANVIL_SURFACE_MSG_CLEAR_IME = 68,
  ANVIL_SURFACE_MSG_WINDOW_MODE = 69,
  ANVIL_SURFACE_MSG_TITLE = 70,
  ANVIL_SURFACE_MSG_HIT_TEST = 71,
  ANVIL_SURFACE_MSG_BORDERED = 72,
  ANVIL_SURFACE_MSG_RAISE = 73,
  ANVIL_SURFACE_MSG_FLASH = 74,
  ANVIL_SURFACE_MSG_SET_BOUNDS = 75,
  ANVIL_SURFACE_MSG_VISIBLE = 76,
  ANVIL_SURFACE_MSG_OPACITY = 77,
  ANVIL_SURFACE_MSG_EXIT_INTENT = 78,
  ANVIL_SURFACE_MSG_RESTART = 79,
  ANVIL_SURFACE_MSG_DIALOG = 80,
  ANVIL_SURFACE_MSG_CLOSE_DECISION = 81,
  ANVIL_SURFACE_MSG_SELECT_PROJECT = 82,
  ANVIL_SURFACE_MSG_UNLOAD_PROJECT = 83,
  ANVIL_SURFACE_MSG_SIDEBAR_SOURCE = 84,
  ANVIL_SURFACE_MSG_SIDEBAR_QUERY = 85,
  ANVIL_SURFACE_MSG_SIDEBAR_REFRESH = 86,
  ANVIL_SURFACE_MSG_NEW_WINDOW = 87,
  ANVIL_SURFACE_MSG_OPEN_PROJECT_WINDOW = 88,
  ANVIL_SURFACE_MSG_OPEN_PROJECT_PICKER = 89,
  ANVIL_SURFACE_MSG_SIDEBAR_SURFACE = 90,
  ANVIL_SURFACE_MSG_SIDEBAR_REMOVE = 91,
  ANVIL_SURFACE_MSG_MOVE_PROJECT = 92,
  /* This Project saved a Color Theme. The shell tells every other Project and the Sidebar. No payload. */
  ANVIL_SURFACE_MSG_COLOR_THEME_SAVED = 93,
  ANVIL_SURFACE_MSG_SHELL_COLORS = 94,
  /* This Project's Panes for the Project Sidebar, as Lua table text. The shell forwards it unread.
   * Payload: AnvilSurfacePaneReport, then text + NUL, at most ANVIL_SURFACE_PANES_MAX text bytes. */
  ANVIL_SURFACE_MSG_PANES = 95,
  /* Select a Project and focus one of its Terminal Sessions. Payload: id + NUL + Project path + NUL. */
  ANVIL_SURFACE_MSG_SELECT_TERMINAL = 96,
  /* Hide the Project Sidebar in every Window, or show it again. No payload. */
  ANVIL_SURFACE_MSG_TOGGLE_SIDEBAR = 97,
  /* This Project shows a Color Theme it has not saved. The shell forwards it to the Sidebar. Payload: the
   * preview + NUL, or only NUL when the Project shows the saved Color Theme again. */
  ANVIL_SURFACE_MSG_COLOR_THEME_PREVIEW = 99,
  /* The UI thread's answer to ANVIL_SURFACE_MSG_PING. Payload: the ping's AnvilSurfaceInt. */
  ANVIL_SURFACE_MSG_PONG = 100,
  /* Another instance shows this Project, so this Project exits. Its Window stays open. No payload. */
  ANVIL_SURFACE_MSG_HAND_OFF = 101,
  /* AnvilSurfacePaneRequest followed by path bytes and request text. */
  ANVIL_SURFACE_MSG_PANE_REQUEST = 102,
  /* Lua startup and Workspace restore finished. Independent of rendering. No payload. */
  ANVIL_SURFACE_MSG_RUNTIME_READY = 103,
  /* This Project saved the Zoom. The shell sends it to every other Project and the Sidebar.
   * Payload: AnvilSurfaceZoom. */
  ANVIL_SURFACE_MSG_ZOOM_SAVED = 104,
  /* Start a bounded in-memory timing capture at path, or stop with an empty string. */
  ANVIL_SURFACE_MSG_TIMING_CAPTURE = 105,
  /* Focus the Sidebar or return to the Selected Project. Payload: AnvilSurfaceInt. */
  ANVIL_SURFACE_MSG_SIDEBAR_FOCUS = 106,
  /* Request the current Terminal quit scope. No payload. */
  ANVIL_SURFACE_MSG_TERMINAL_QUIT_QUERY = 108,
  /* Save Keep or End for the rest of this Window Close, or of Close All Windows. Payload: AnvilSurfaceInt. */
  ANVIL_SURFACE_MSG_TERMINAL_QUIT_CHOICE = 109,
  /* Turn Alt Navigation on or off in every Window. No payload. */
  ANVIL_SURFACE_MSG_TOGGLE_ALT_NAVIGATION = 110,
  /* Close every Window, and keep them all for the next start. No payload. */
  ANVIL_SURFACE_MSG_CLOSE_ALL_WINDOWS = 111,
  /* Open the Window that closed last, with its placement and Projects. No payload. */
  ANVIL_SURFACE_MSG_REOPEN_CLOSED_WINDOW = 112,
} AnvilSurfaceMessageType;

typedef enum {
  ANVIL_SURFACE_TERMINAL_QUIT_PROJECT,
  ANVIL_SURFACE_TERMINAL_QUIT_ASK,
  ANVIL_SURFACE_TERMINAL_QUIT_KEEP,
  ANVIL_SURFACE_TERMINAL_QUIT_END,
  /* Close All Windows asks once for the Terminal Sessions of every Window. */
  ANVIL_SURFACE_TERMINAL_QUIT_ASK_ALL
} AnvilSurfaceTerminalQuit;

/* Static stage names only. Times use the same performance clock as system.get_time().
 * Records contain no key codes, text, or Buffer contents. Stop writes the CSV. */
bool anvil_timing_capture(const char *path);
void anvil_timing_note(const char *stage, uint64_t id, uint64_t a, uint64_t b);

/* Sidebar surface traffic shares one authenticated transport. */
typedef struct {
  uint32_t window_id;
  uint32_t type;
} AnvilSidebarSurfacePacket;
typedef struct { uint32_t project_id, target_window_id; } AnvilSurfaceMoveProject;
/* The Zoom as ratios over the base scale. The message carries it, so receivers never read a file that a
 * Project replaces during a fast Zoom. */
typedef struct { double interface_zoom, code_zoom; } AnvilSurfaceZoom;

typedef struct {
  uint32_t userdir_size;
} AnvilSurfaceSidebarSource;

#define ANVIL_SURFACE_PANES_MAX (16u * 1024u)
typedef enum {
  ANVIL_SURFACE_PANE_ROUTE_SELECT = 1,
  ANVIL_SURFACE_PANE_ROUTE_DIRECT = 2,
  ANVIL_SURFACE_PANE_ROUTE_POINTER = 3
} AnvilSurfacePaneRoute;
typedef struct {
  uint32_t route;
  int32_t x, y;
  uint32_t path_size;
} AnvilSurfacePaneRequest;
typedef struct { int32_t x, y; uint64_t request; } AnvilSurfacePaneDelivery;
typedef struct { uint64_t request; } AnvilSurfacePaneReport;
bool anvil_surface_pane_request_valid(const void *packet, uint32_t size);
bool anvil_surface_pane_delivery_valid(const void *packet, uint32_t size);

typedef enum {
  ANVIL_SURFACE_WINDOW_NORMAL = 0,
  ANVIL_SURFACE_WINDOW_MINIMIZED = 1,
  ANVIL_SURFACE_WINDOW_MAXIMIZED = 2,
  ANVIL_SURFACE_WINDOW_FULLSCREEN = 3,
} AnvilSurfaceWindowMode;

typedef enum {
  ANVIL_SURFACE_FRAME_D3D11 = 1,
  ANVIL_SURFACE_FRAME_SHARED_MEMORY = 2,
} AnvilSurfaceFrameKind;

/* Index order matches system.set_cursor names. */
typedef enum {
  ANVIL_SURFACE_CURSOR_ARROW = 0,
  ANVIL_SURFACE_CURSOR_IBEAM,
  ANVIL_SURFACE_CURSOR_SIZEH,
  ANVIL_SURFACE_CURSOR_SIZEV,
  ANVIL_SURFACE_CURSOR_HAND,
  ANVIL_SURFACE_CURSOR_CROSSHAIR,
  ANVIL_SURFACE_CURSOR_MOVE,
  ANVIL_SURFACE_CURSOR_GRAB,
  ANVIL_SURFACE_CURSOR_SIZENWSE,
  ANVIL_SURFACE_CURSOR_COUNT
} AnvilSurfaceCursor;

typedef struct {
  uint64_t configuration;
  uint64_t pane_request;             /* frame must include this Pane request */
  uint32_t window_id;                /* stable shell identity, not an SDL ID */
  int32_t origin_x, origin_y;        /* physical client pixels */
  int32_t pixel_w, pixel_h;          /* surface size */
  int32_t window_x, window_y;        /* shell window bounds, for saved app state */
  int32_t window_w, window_h;
  int32_t window_mode;               /* AnvilSurfaceWindowMode */
  int32_t live_resize;               /* the shell is in a Win32 move/size loop */
  int32_t render_enabled;            /* background work continues when this is zero */
  float display_scale;
  float refresh_hz;
  int32_t button_width, title_height, resize_border;
  int32_t controls_x, controls_y, controls_w, controls_h;
  /* The surface covers the whole client area. The Project lays out its UI right of content_x and draws only
   * its backdrop to the left of it, where the shell blends the Sidebar. The Sidebar lays out its strip left of
   * content_x and draws only popups right of it. */
  int32_t content_x;
} AnvilSurfaceConfigure;

typedef struct {
  uint64_t configuration;
  SDL_Event event;     /* window IDs and text pointers are rewritten by the receiver */
  uint32_t text_len;   /* UTF-8 bytes that follow, for text, editing, and drop events */
} AnvilSurfaceInput;

typedef struct { int32_t value; } AnvilSurfaceInt;

typedef enum {
  ANVIL_SURFACE_CLOSE_PENDING,
  ANVIL_SURFACE_CLOSE_WAITING,
  ANVIL_SURFACE_CLOSE_CANCELLED,
  ANVIL_SURFACE_CLOSE_ACCEPTED,
} AnvilSurfaceCloseDecision;

#define ANVIL_SURFACE_DIALOG_LIMIT 8
#define ANVIL_SURFACE_DIALOG_FILTER_LIMIT 64
#define ANVIL_SURFACE_DIALOG_PATH_LIMIT 256
/* Four NUL-terminated option strings precede name/pattern pairs. */
typedef struct { uint32_t id, type, filters, many; } AnvilSurfaceDialog;
typedef enum { ANVIL_SURFACE_DIALOG_ACCEPT, ANVIL_SURFACE_DIALOG_CANCEL, ANVIL_SURFACE_DIALOG_ERROR } AnvilSurfaceDialogStatus;
/* Accept contains a double-NUL path list; error contains one NUL-terminated string. */
typedef struct { uint32_t id; int32_t status, filter; } AnvilSurfaceDialogResult;

void *anvil_surface_dialog_encode(uint32_t id, SDL_FileDialogType type, SDL_PropertiesID props, uint32_t *size);
SDL_PropertiesID anvil_surface_dialog_decode(const void *packet, uint32_t size, SDL_DialogFileFilter filters[ANVIL_SURFACE_DIALOG_FILTER_LIMIT]);
void *anvil_surface_dialog_result(uint32_t id, const char *const *paths, int filter, uint32_t *size);
bool anvil_surface_dialog_result_valid(const void *packet, uint32_t size);

typedef struct { uint32_t pid; } AnvilSurfaceHello;

/* The most frame areas one frame shows above the Sidebar. */
#define ANVIL_SURFACE_RAISED_MAX 4
typedef struct { int32_t x, y, w, h; } AnvilSurfaceArea;

typedef struct {
  uint32_t kind;         /* AnvilSurfaceFrameKind */
  uint32_t generation;   /* increments for every published frame */
  uint64_t configuration;
  uint64_t pane_request; /* last Pane request completed before this frame */
  int32_t width, height;
  uint64_t input_seq;    /* highest latency-probe input consumed before this frame */
  /* The frame's full-window background, R | G << 8 | B << 16 | A << 24. The shell fills
   * exposed areas with it until a frame of the new size arrives. */
  uint32_t background;
  /* The dim the Project draws over its UI while a modal overlay is open, in the same layout; zero when none.
   * The shell applies it over the Sidebar, so the overlay covers the whole window. */
  uint32_t overlay;
  /* Frame areas that the shell shows above the other layer. Surface pixels; an empty area shows none. A Project's
   * areas, such as a modal popup and a warning bar, show above the Sidebar while the overlay is shown. A Sidebar's
   * areas are its popup, such as a menu, which shows above the Project and takes all pointer input. */
  AnvilSurfaceArea raised[ANVIL_SURFACE_RAISED_MAX];
  char name[ANVIL_SURFACE_NAME_MAX];
} AnvilSurfaceFrame;

/* Shared-memory frames start with this header; BGRA rows follow. The named
 * mutex is the frame name plus ANVIL_SURFACE_LOCK_SUFFIX. */
#define ANVIL_SURFACE_LOCK_SUFFIX "-lock"
typedef struct {
  int32_t width, height, stride;
  uint32_t generation;
  uint64_t configuration;
} AnvilSurfaceMemoryHeader;

typedef struct {
  int32_t active;      /* 1 starts text input, 0 stops it, -1 only moves the area */
  int32_t x, y, w, h;  /* IME area in surface coordinates */
  int32_t cursor;
  uint64_t configuration;
} AnvilSurfaceTextInput;

/* Title Bar layout in surface coordinates. All zero disables the Title Bar. */
typedef struct {
  int32_t title_height, controls_width, resize_border;
  int32_t client_x, client_width, client2_x, client2_width;
  uint64_t configuration;
} AnvilSurfaceHitTest;

bool anvil_surface_frame_matches(const AnvilSurfaceConfigure *config, const AnvilSurfaceFrame *frame);
bool anvil_surface_layout_changed(const AnvilSurfaceConfigure *previous, const AnvilSurfaceConfigure *next);
bool anvil_surface_text_area(const AnvilSurfaceConfigure *config, const AnvilSurfaceTextInput *input, SDL_Rect *area, int *cursor);
void anvil_surface_translate_input(const AnvilSurfaceConfigure *config, SDL_Event *event);

typedef struct {
  int32_t x, y, w, h;
} AnvilSurfaceBounds;

/* The Color Theme's colours for what the shell draws, each R | G << 8 | B << 16 | A << 24. Projects and the
 * Sidebar send them. The Project area uses the background while no Project frame covers it. */
typedef struct {
  uint32_t background, button;  /* the Project area, and the buttons of its native cards */
  uint32_t text, inactive_text; /* card text and control glyphs; glyphs use inactive_text while unfocused */
  uint32_t hover, pressed;      /* minimize and maximize backgrounds */
  uint32_t close_hover, close_pressed, close_text;
  /* The native cards look like the editor's dialogs. The border, shadow and button colours have alpha. */
  uint32_t card, card_border, card_shadow, card_button;
  uint32_t accent, accent_text; /* the primary button */
} AnvilSurfaceShellColors;

/* Windows always records SDL_Log output under USERDIR/logs, before Lua starts.
 * ANVIL_SURFACE_LOG selects a shared file for probes. Other platforms use that override only. */
void anvil_surface_log_init(const char *role);

#include "ipc_pipe.h"

#endif
