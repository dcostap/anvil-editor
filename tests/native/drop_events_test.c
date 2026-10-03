#include <SDL3/SDL.h>
#include <stdio.h>
#include "system_events.h"

#define CHECK(condition) do { \
  if (!(condition)) { \
    fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); \
    return 1; \
  } \
} while (0)

int main(void) {
  SDL_Event event = {0}, result;
  event.type = SDL_EVENT_DROP_BEGIN;
  event.drop.windowID = 17;
  system_push_event(&event);
  CHECK(system_event_pop(&result));
  CHECK(result.type == SDL_EVENT_DROP_BEGIN && result.drop.windowID == 17);

  /* Hover must not fill the queue or cross a payload boundary. */
  event.type = SDL_EVENT_DROP_POSITION;
  for (int i = 0; i < 1000; ++i) {
    event.drop.x = (float)i + 0.5f;
    event.drop.y = 12.25f;
    system_push_event(&event);
  }
  event.type = SDL_EVENT_DROP_FILE;
  event.drop.data = "C:/drop/one.txt";
  system_push_event(&event);
  event.type = SDL_EVENT_DROP_POSITION;
  event.drop.x = 42.5f;
  system_push_event(&event);
  event.type = SDL_EVENT_DROP_TEXT;
  event.drop.data = "first\r\n\r\nlast\r\n";
  system_push_event(&event);
  event.type = SDL_EVENT_DROP_COMPLETE;
  event.drop.data = NULL;
  system_push_event(&event);

  CHECK(system_event_pop(&result));
  CHECK(result.type == SDL_EVENT_DROP_POSITION);
  CHECK(result.drop.x == 999.5f && result.drop.y == 12.25f);
  CHECK(system_event_pop(&result));
  CHECK(result.type == SDL_EVENT_DROP_FILE);
  CHECK(SDL_strcmp(result.drop.data, "C:/drop/one.txt") == 0);
  CHECK(system_event_pop(&result));
  CHECK(result.type == SDL_EVENT_DROP_POSITION && result.drop.x == 42.5f);
  CHECK(system_event_pop(&result));
  CHECK(result.type == SDL_EVENT_DROP_TEXT);
  CHECK(SDL_strcmp(result.drop.data, "first\r\n\r\nlast\r\n") == 0);
  CHECK(system_event_pop(&result));
  CHECK(result.type == SDL_EVENT_DROP_COMPLETE && result.drop.windowID == 17);
  CHECK(!system_event_pop(&result));
  puts("PASS drop lifecycle, coordinates, payloads, and hover backlog");

  /* A focus flush must leave a record even though Lua never receives the key. */
  SDL_zero(event);
  event.type = SDL_EVENT_KEY_DOWN;
  event.key.windowID = 17;
  event.key.scancode = SDL_SCANCODE_F24;
  event.key.key = SDLK_F24;
  event.key.timestamp = 123456789;
  system_push_event(&event);
  system_flush_events(SDL_EVENT_KEY_DOWN);
  CHECK(!system_event_pop(&result));
  char line[SYSTEM_INPUT_TRACE_LINE_SIZE];
  bool queued = false, flushed = false;
  while (system_input_trace_read(line)) {
    if (SDL_strstr(line, "sdl stage=queued event=keydown") &&
        SDL_strstr(line, "timestamp_ns=123456789 window=17")) queued = true;
    if (SDL_strstr(line, "sdl stage=flushed event=keydown")) flushed = true;
  }
  CHECK(queued && flushed);

  event.type = SDL_EVENT_KEY_UP;
  system_push_event(&event);
  CHECK(system_event_pop(&result));
  bool polled = false;
  while (system_input_trace_read(line)) {
    if (SDL_strstr(line, "sdl stage=polled event=keyup")) polled = true;
  }
  CHECK(polled);

  /* A full event queue must report the key that it discards. */
  SDL_zero(event);
  event.type = SDL_EVENT_MOUSE_BUTTON_DOWN;
  for (int i = 0; i < 10000; i++) {
    int before = system_pending_event_count();
    system_push_event(&event);
    if (system_pending_event_count() == before) break;
  }
  event.type = SDL_EVENT_KEY_DOWN;
  event.key.windowID = 17;
  system_push_event(&event);
  bool dropped = false;
  while (system_input_trace_read(line)) {
    if (SDL_strstr(line, "sdl stage=dropped-full event=keydown")) dropped = true;
  }
  CHECK(dropped);
  while (system_event_pop(&result)) {}

  /* Trace loss must be visible, not mistaken for missing keyboard input. */
  for (int i = 0; i < 10000; i++) system_input_trace("test burst=%d", i);
  CHECK(system_input_trace_read(line));
  CHECK(SDL_strstr(line, "trace-overflow dropped_newest="));
  while (system_input_trace_read(line)) {}
  CHECK(!system_input_trace_read(line));
  puts("PASS keyboard trace delivery, focus flush, queue loss, and trace loss");
  return 0;
}
