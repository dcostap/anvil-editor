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
  return 0;
}
