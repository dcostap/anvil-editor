#include <SDL3/SDL.h>
#include "system_events.h"
#include "input_latency_probe.h"
#include "resize_diagnostics.h"
#include <stdarg.h>

/* Native callbacks must not write files or call Lua. Report any lost records. */
#define INPUT_TRACE_CAPACITY 2048
static SDL_InitState input_trace_init;
static SDL_Mutex *input_trace_mutex;
static char input_trace_lines[INPUT_TRACE_CAPACITY][SYSTEM_INPUT_TRACE_LINE_SIZE];
static unsigned input_trace_read, input_trace_count;
static Uint64 input_trace_sequence, input_trace_lost;

static bool input_trace_ready(void) {
  if (SDL_ShouldInit(&input_trace_init)) {
    input_trace_mutex = SDL_CreateMutex();
    SDL_SetInitialized(&input_trace_init, input_trace_mutex != NULL);
  }
  return input_trace_mutex != NULL;
}

void system_input_trace(const char *format, ...) {
  if (!input_trace_ready()) return;
  SDL_LockMutex(input_trace_mutex);
  Uint64 sequence = ++input_trace_sequence;
  if (input_trace_count == INPUT_TRACE_CAPACITY) {
    input_trace_lost++;
  } else {
    char *line = input_trace_lines[(input_trace_read + input_trace_count++) % INPUT_TRACE_CAPACITY];
    int prefix = SDL_snprintf(line, SYSTEM_INPUT_TRACE_LINE_SIZE,
      "native seq=%llu ticks_ns=%llu thread=%llu ",
      (unsigned long long)sequence, (unsigned long long)SDL_GetTicksNS(),
      (unsigned long long)SDL_GetCurrentThreadID());
    va_list args;
    va_start(args, format);
    SDL_vsnprintf(line + prefix, SYSTEM_INPUT_TRACE_LINE_SIZE - prefix, format, args);
    va_end(args);
  }
  SDL_UnlockMutex(input_trace_mutex);
}

bool system_input_trace_read(char line[SYSTEM_INPUT_TRACE_LINE_SIZE]) {
  if (!input_trace_ready()) return false;
  SDL_LockMutex(input_trace_mutex);
  bool available = input_trace_lost || input_trace_count;
  if (input_trace_lost) {
    SDL_snprintf(line, SYSTEM_INPUT_TRACE_LINE_SIZE,
      "native trace-overflow dropped_newest=%llu", (unsigned long long)input_trace_lost);
    input_trace_lost = 0;
  } else if (input_trace_count) {
    SDL_strlcpy(line, input_trace_lines[input_trace_read], SYSTEM_INPUT_TRACE_LINE_SIZE);
    input_trace_read = (input_trace_read + 1) % INPUT_TRACE_CAPACITY;
    input_trace_count--;
  }
  SDL_UnlockMutex(input_trace_mutex);
  return available;
}

static void trace_input_event(const SDL_Event *event, const char *stage, int depth) {
  if (event->type == SDL_EVENT_KEY_DOWN || event->type == SDL_EVENT_KEY_UP) {
    system_input_trace("sdl stage=%s event=%s timestamp_ns=%llu window=%u keyboard=%u "
      "scancode=%u keycode=%u modifiers=0x%x repeat=%d queue=%d",
      stage, event->type == SDL_EVENT_KEY_DOWN ? "keydown" : "keyup",
      (unsigned long long)event->key.timestamp, event->key.windowID, event->key.which,
      (unsigned)event->key.scancode, (unsigned)event->key.key, event->key.mod,
      event->key.repeat, depth);
  } else if (event->type == SDL_EVENT_WINDOW_FOCUS_GAINED || event->type == SDL_EVENT_WINDOW_FOCUS_LOST) {
    system_input_trace("sdl stage=%s event=%s timestamp_ns=%llu window=%u queue=%d",
      stage, event->type == SDL_EVENT_WINDOW_FOCUS_GAINED ? "focusgained" : "focuslost",
      (unsigned long long)event->window.timestamp, event->window.windowID, depth);
  }
}

/* ---------------------------------------------------------------------------
 * Internal event queue for SDL3 main-callback mode.
 *
 * When SDL_MAIN_USE_CALLBACKS is active the SDL event loop calls
 * SDL_AppEvent() for every pending event *before* calling SDL_AppIterate().
 * By the time our Lua code runs there are no more events left in SDL's own
 * queue, so SDL_PollEvent() would always return 0.
 *
 * To preserve the existing poll_event / wait_event Lua API we maintain our
 * own ring buffer.  SDL_AppEvent() pushes events here; f_poll_event() pops
 * from here instead of calling SDL_PollEvent().  Mouse-motion and
 * finger-motion events are coalesced on the way in, mirroring what the old
 * SDL_PeepEvents() loop used to do in f_poll_event().
 * ------------------------------------------------------------------------- */

/* 512 slots give plenty of headroom for a full key-repeat burst plus several
 * pending mouse-motion and touch events without allocating heap memory.
 * Unhandled event types are filtered out in system_push_event() so they
 * never waste queue slots. */
#define SYSTEM_EVENT_QUEUE_SIZE 512

static SDL_Event system_event_queue[SYSTEM_EVENT_QUEUE_SIZE];
static int       system_event_queue_read  = 0;
static int       system_event_queue_count = 0;
static char *system_event_text[SYSTEM_EVENT_QUEUE_SIZE];
/* A popped payload stays valid until the next pop, like SDL event payloads. */
static char *system_popped_text;

static const char *event_text(const SDL_Event *event) {
  if (event->type == SDL_EVENT_TEXT_INPUT) return event->text.text;
  if (event->type == SDL_EVENT_TEXT_EDITING) return event->edit.text;
  if (event->type == SDL_EVENT_DROP_FILE || event->type == SDL_EVENT_DROP_TEXT) return event->drop.data;
  return NULL;
}

/* Keep this in sync with the switch in f_poll_event() (src/api/system.c).
 * Only types listed here are allowed into the ring buffer; everything else
 * is silently discarded at the SDL callback boundary. */
static bool system_event_is_handled(uint32_t type) {
  switch (type) {
    /* Core lifecycle */
    case SDL_EVENT_QUIT:

    /* Window events that f_poll_event handles */
    case SDL_EVENT_WINDOW_RESIZED:
    case SDL_EVENT_WINDOW_MOVED:
    case SDL_EVENT_WINDOW_DISPLAY_CHANGED:
    case SDL_EVENT_WINDOW_EXPOSED:
    case SDL_EVENT_WINDOW_MINIMIZED:
    case SDL_EVENT_WINDOW_MAXIMIZED:
    case SDL_EVENT_WINDOW_RESTORED:
    case SDL_EVENT_WINDOW_MOUSE_LEAVE:
    case SDL_EVENT_WINDOW_MOUSE_ENTER:
    case SDL_EVENT_WINDOW_FOCUS_LOST:
    case SDL_EVENT_WINDOW_FOCUS_GAINED:
    case SDL_EVENT_WINDOW_CLOSE_REQUESTED:
    case SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED:
    case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:

    /* Mobile lifecycle */
    case SDL_EVENT_WILL_ENTER_FOREGROUND:
    case SDL_EVENT_DID_ENTER_FOREGROUND:
    case SDL_EVENT_WILL_ENTER_BACKGROUND:
    case SDL_EVENT_DID_ENTER_BACKGROUND:

    /* Drag & drop */
    case SDL_EVENT_DROP_FILE:
    case SDL_EVENT_DROP_TEXT:
    case SDL_EVENT_DROP_BEGIN:
    case SDL_EVENT_DROP_POSITION:
    case SDL_EVENT_DROP_COMPLETE:

    /* Keyboard */
    case SDL_EVENT_KEY_DOWN:
    case SDL_EVENT_KEY_UP:
    case SDL_EVENT_TEXT_INPUT:
    case SDL_EVENT_TEXT_EDITING:

    /* Mouse */
    case SDL_EVENT_MOUSE_BUTTON_DOWN:
    case SDL_EVENT_MOUSE_BUTTON_UP:
    case SDL_EVENT_MOUSE_MOTION:
    case SDL_EVENT_MOUSE_WHEEL:

    /* Touch */
    case SDL_EVENT_FINGER_DOWN:
    case SDL_EVENT_FINGER_UP:
    case SDL_EVENT_FINGER_MOTION:
      return true;

    default:
      /* Custom events (>= SDL_EVENT_USER) are always allowed through */
      return type >= SDL_EVENT_USER;
  }
}

static uint32_t system_event_window_id(const SDL_Event *event) {
  switch (event->type) {
    case SDL_EVENT_WINDOW_RESIZED:
    case SDL_EVENT_WINDOW_MOVED:
    case SDL_EVENT_WINDOW_DISPLAY_CHANGED:
    case SDL_EVENT_WINDOW_EXPOSED:
    case SDL_EVENT_WINDOW_MINIMIZED:
    case SDL_EVENT_WINDOW_MAXIMIZED:
    case SDL_EVENT_WINDOW_RESTORED:
    case SDL_EVENT_WINDOW_MOUSE_LEAVE:
    case SDL_EVENT_WINDOW_FOCUS_LOST:
    case SDL_EVENT_WINDOW_FOCUS_GAINED:
    case SDL_EVENT_WINDOW_CLOSE_REQUESTED:
    case SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED:
    case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
      return event->window.windowID;
    case SDL_EVENT_MOUSE_BUTTON_DOWN:
    case SDL_EVENT_MOUSE_BUTTON_UP:
      return event->button.windowID;
    case SDL_EVENT_MOUSE_MOTION:
      return event->motion.windowID;
    case SDL_EVENT_MOUSE_WHEEL:
      return event->wheel.windowID;
    case SDL_EVENT_TEXT_INPUT:
      return event->text.windowID;
    case SDL_EVENT_TEXT_EDITING:
      return event->edit.windowID;
    case SDL_EVENT_KEY_DOWN:
    case SDL_EVENT_KEY_UP:
      return event->key.windowID;
    case SDL_EVENT_DROP_FILE:
    case SDL_EVENT_DROP_TEXT:
    case SDL_EVENT_DROP_BEGIN:
    case SDL_EVENT_DROP_POSITION:
    case SDL_EVENT_DROP_COMPLETE:
      return event->drop.windowID;
    case SDL_EVENT_FINGER_DOWN:
    case SDL_EVENT_FINGER_UP:
    case SDL_EVENT_FINGER_MOTION:
      return event->tfinger.windowID;
    default:
      return 0;
  }
}

bool system_push_event(const SDL_Event *event) {
  /* Discard event types that f_poll_event() never consumes */
  if (!system_event_is_handled(event->type))
    return true;

  int queue_depth_before = system_event_queue_count;
  uint32_t event_window_id = system_event_window_id(event);

  /* Coalesce high-frequency events for the same window. During live window
   * resize, SDL can deliver many resize / pixel-size events before Lua gets a
   * chance to draw. Keeping every intermediate size makes the UI churn through
   * stale layouts and looks janky; only the latest size matters. */
  if (event->type == SDL_EVENT_WINDOW_RESIZED ||
      event->type == SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED ||
      event->type == SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED) {
    for (int i = system_event_queue_count - 1; i >= 0; i--) {
      int idx = (system_event_queue_read + i) % SYSTEM_EVENT_QUEUE_SIZE;
      bool same_window = system_event_queue[idx].window.windowID == event->window.windowID;
      bool same_type = system_event_queue[idx].type == event->type;
      bool resize_or_pixel = event->type == SDL_EVENT_WINDOW_RESIZED ||
                             event->type == SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED;
      bool queued_resize_or_pixel = system_event_queue[idx].type == SDL_EVENT_WINDOW_RESIZED ||
                                    system_event_queue[idx].type == SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED;
      if (!same_window || !(same_type || (resize_or_pixel && queued_resize_or_pixel))) break;
      if (same_window && (same_type || (resize_or_pixel && queued_resize_or_pixel))) {
        const char *detail = same_type ? "same_type_resize" : "resize_pixel_pair";
        if (system_event_queue[idx].type == SDL_EVENT_WINDOW_RESIZED &&
            event->type == SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED) {
          anvil_resize_diag_log(&(AnvilResizeDiagEvent){
            .category = "event_queue",
            .name = "coalesce",
            .reason = anvil_resize_diag_event_reason(event->type),
            .window_id = event->window.windowID,
            .live_resize = anvil_resize_diag_live_resize(),
            .queue_depth = system_event_queue_count,
            .count_a = queue_depth_before,
            .detail = detail
          });
          return true;
        }
        system_event_queue[idx] = *event;
        anvil_resize_diag_log(&(AnvilResizeDiagEvent){
          .category = "event_queue",
          .name = "coalesce",
          .reason = anvil_resize_diag_event_reason(event->type),
          .window_id = event->window.windowID,
          .live_resize = anvil_resize_diag_live_resize(),
          .queue_depth = system_event_queue_count,
          .count_a = queue_depth_before,
          .detail = detail
        });
        return true;
      }
    }
  /* Coalesce consecutive mouse-motion events for the same window */
  } else if (event->type == SDL_EVENT_MOUSE_MOTION) {
    for (int i = system_event_queue_count - 1; i >= 0; i--) {
      int idx = (system_event_queue_read + i) % SYSTEM_EVENT_QUEUE_SIZE;
      if (system_event_queue[idx].type == SDL_EVENT_MOUSE_MOTION &&
          system_event_queue[idx].motion.windowID == event->motion.windowID) {
        system_event_queue[idx].motion.x    = event->motion.x;
        system_event_queue[idx].motion.y    = event->motion.y;
        system_event_queue[idx].motion.xrel += event->motion.xrel;
        system_event_queue[idx].motion.yrel += event->motion.yrel;
        return true;
      }
      break;
    }
  /* A drop position has no payload. Keep only the latest consecutive position. */
  } else if (event->type == SDL_EVENT_DROP_POSITION && system_event_queue_count > 0) {
    int idx = (system_event_queue_read + system_event_queue_count - 1) % SYSTEM_EVENT_QUEUE_SIZE;
    if (system_event_queue[idx].type == SDL_EVENT_DROP_POSITION &&
        system_event_queue[idx].drop.windowID == event->drop.windowID) {
      system_event_queue[idx] = *event;
      return true;
    }
  /* Coalesce consecutive finger-motion events for the same finger */
  } else if (event->type == SDL_EVENT_FINGER_MOTION) {
    for (int i = system_event_queue_count - 1; i >= 0; i--) {
      int idx = (system_event_queue_read + i) % SYSTEM_EVENT_QUEUE_SIZE;
      if (system_event_queue[idx].type == SDL_EVENT_FINGER_MOTION &&
          system_event_queue[idx].tfinger.fingerID == event->tfinger.fingerID) {
        system_event_queue[idx].tfinger.x  = event->tfinger.x;
        system_event_queue[idx].tfinger.y  = event->tfinger.y;
        system_event_queue[idx].tfinger.dx += event->tfinger.dx;
        system_event_queue[idx].tfinger.dy += event->tfinger.dy;
        return true;
      }
      break;
    }
  }

  if (system_event_queue_count < SYSTEM_EVENT_QUEUE_SIZE) {
    int write_idx = (system_event_queue_read + system_event_queue_count)
                    % SYSTEM_EVENT_QUEUE_SIZE;
    system_event_queue[write_idx] = *event;
    const char *text = event_text(event);
    char *copy = text ? SDL_strdup(text) : NULL;
    if (text && !copy) {
      SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Cannot retain queued input text");
      return false;
    }
    system_event_text[write_idx] = copy;
    if (event->type == SDL_EVENT_TEXT_INPUT) system_event_queue[write_idx].text.text = copy;
    if (event->type == SDL_EVENT_TEXT_EDITING) system_event_queue[write_idx].edit.text = copy;
    if (event->type == SDL_EVENT_DROP_FILE || event->type == SDL_EVENT_DROP_TEXT) {
      system_event_queue[write_idx].drop.data = copy;
      system_event_queue[write_idx].drop.source = NULL;
    }
    system_event_queue_count++;
    trace_input_event(event, "queued", system_event_queue_count);
    anvil_resize_diag_log(&(AnvilResizeDiagEvent){
      .category = "event_queue",
      .name = "push",
      .reason = anvil_resize_diag_event_reason(event->type),
      .window_id = event_window_id,
      .live_resize = anvil_resize_diag_live_resize(),
      .queue_depth = system_event_queue_count,
      .count_a = queue_depth_before
    });
  } else {
    trace_input_event(event, "dropped-full", system_event_queue_count);
    anvil_resize_diag_log(&(AnvilResizeDiagEvent){
      .category = "event_queue",
      .name = "drop_full",
      .reason = anvil_resize_diag_event_reason(event->type),
      .window_id = event_window_id,
      .live_resize = anvil_resize_diag_live_resize(),
      .queue_depth = system_event_queue_count,
      .count_a = queue_depth_before
    });
    SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                "system event queue full; dropping event type 0x%x", event->type);
    return false;
  }
  return true;
}

void system_flush_events(uint32_t type) {
  int new_read  = system_event_queue_read;
  int new_count = 0;
  for (int i = 0; i < system_event_queue_count; i++) {
    int src = (system_event_queue_read + i) % SYSTEM_EVENT_QUEUE_SIZE;
    if (system_event_queue[src].type != type) {
      int dst = (new_read + new_count) % SYSTEM_EVENT_QUEUE_SIZE;
      if (src != dst) {
        system_event_queue[dst] = system_event_queue[src];
        system_event_text[dst] = system_event_text[src];
        system_event_text[src] = NULL;
      }
      new_count++;
    } else {
      SDL_free(system_event_text[src]);
      system_event_text[src] = NULL;
      trace_input_event(&system_event_queue[src], "flushed", system_event_queue_count);
    }
  }
  system_event_queue_read  = new_read;
  system_event_queue_count = new_count;
}

bool system_has_pending_events(void) {
  return system_event_queue_count > 0;
}

int system_pending_event_count(void) {
  return system_event_queue_count;
}

bool system_event_pop(SDL_Event *event) {
  SDL_free(system_popped_text);
  system_popped_text = NULL;
  if (system_event_queue_count == 0) return false;
  *event = system_event_queue[system_event_queue_read];
  system_popped_text = system_event_text[system_event_queue_read];
  system_event_text[system_event_queue_read] = NULL;
  system_event_queue_read  = (system_event_queue_read + 1) % SYSTEM_EVENT_QUEUE_SIZE;
  system_event_queue_count--;
  trace_input_event(event, "polled", system_event_queue_count);
  anvil_latency_probe_note_event(event);
  return true;
}
