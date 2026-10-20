#include <SDL3/SDL.h>
#include <stdio.h>
#include <string.h>
#include "key_text.h"

#define CHECK(condition) do { \
  if (!(condition)) { \
    fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); \
    return 1; \
  } \
} while (0)

int main(void) {
  char text[5];

  /* Delete is a control key; terminals must not receive its key name as typed text. */
  CHECK(!key_text_from_keycode(SDLK_DELETE, text));
  CHECK(!key_text_from_keycode(SDLK_RETURN, text));
  CHECK(!key_text_from_keycode(SDLK_LEFT, text));

  CHECK(key_text_from_keycode(SDLK_SPACE, text) && strcmp(text, " ") == 0);
  CHECK(key_text_from_keycode(SDLK_O, text) && strcmp(text, "o") == 0);
  CHECK(key_text_from_keycode('O', text) && strcmp(text, "O") == 0);
  CHECK(key_text_from_keycode(0x00e9, text) && strcmp(text, "\xc3\xa9") == 0);
  CHECK(key_text_from_keycode(0x20ac, text) && strcmp(text, "\xe2\x82\xac") == 0);

  /* Shortcuts name printable ASCII keys by their own character, not SDL's keymap. */
  char name[2];
  CHECK(key_name_from_ascii_keycode(SDLK_C, name) && strcmp(name, "c") == 0);
  CHECK(key_name_from_ascii_keycode(SDLK_SEMICOLON, name) && strcmp(name, ";") == 0);
  CHECK(!key_name_from_ascii_keycode(SDLK_SPACE, name));
  CHECK(!key_name_from_ascii_keycode(SDLK_DELETE, name));
  CHECK(!key_name_from_ascii_keycode(SDLK_RETURN, name));
  CHECK(!key_name_from_ascii_keycode(0x00f1, name));
  return 0;
}
