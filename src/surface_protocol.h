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

#define ANVIL_SURFACE_PROTOCOL_VERSION 8u
#define ANVIL_SURFACE_MAX_PAYLOAD (64u * 1024u)
#define ANVIL_SURFACE_NAME_MAX 96
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
} AnvilSurfaceMessageType;

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
  ANVIL_SURFACE_CURSOR_COUNT
} AnvilSurfaceCursor;

typedef struct {
  uint64_t configuration;
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

typedef struct {
  uint32_t kind;         /* AnvilSurfaceFrameKind */
  uint32_t generation;   /* increments for every published frame */
  uint64_t configuration;
  int32_t width, height;
  uint64_t input_seq;    /* highest latency-probe input consumed before this frame */
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

/* Appends SDL_Log output from the shell and hosted processes to the file named
 * by ANVIL_SURFACE_LOG. Both processes can share the file. Startup failures
 * happen before Lua logging exists, so this is the only record of them. */
void anvil_surface_log_init(const char *role);

#include "ipc_pipe.h"

#endif
