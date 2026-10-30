#include <SDL3/SDL.h>
#include <stdio.h>
#include "alt_navigation.h"

#define CHECK(condition) do { \
  if (!(condition)) { \
    fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); \
    return 1; \
  } \
} while (0)

typedef struct {
  SDL_Scancode scancode;
  SDL_Keymod mod;
  bool down;
} Expected;

static int same(const AnvilAltNavigationKey *keys, size_t count, const Expected *expected, size_t expected_count) {
  if (count != expected_count) {
    fprintf(stderr, "  count %zu, expected %zu\n", count, expected_count);
    return 0;
  }
  for (size_t i = 0; i < count; i++)
    if (keys[i].scancode != expected[i].scancode || keys[i].mod != expected[i].mod ||
        keys[i].down != expected[i].down) {
      fprintf(stderr, "  key %zu: scancode=%d mod=0x%x down=%d\n", i, keys[i].scancode, keys[i].mod, keys[i].down);
      return 0;
    }
  return 1;
}

#define SAME(keys, count, ...) \
  same(keys, count, (const Expected[]){__VA_ARGS__}, sizeof((const Expected[]){__VA_ARGS__}) / sizeof(Expected))

/* The result key with its modifiers, from the first press of `scancode`. */
static bool result(SDL_Scancode from, SDL_Keymod mod, SDL_Scancode *to, SDL_Keymod *to_mod, size_t *presses) {
  AnvilAltNavigationKey keys[ANVIL_ALT_NAVIGATION_MAX_KEYS];
  size_t count = anvil_alt_navigation_keys(from, mod, keys);
  *presses = 0;
  for (size_t i = 0; i < count; i++) {
    if (!keys[i].down || keys[i].scancode == SDL_SCANCODE_LCTRL || keys[i].scancode == SDL_SCANCODE_RCTRL ||
        keys[i].scancode == SDL_SCANCODE_LSHIFT || keys[i].scancode == SDL_SCANCODE_RSHIFT ||
        keys[i].scancode == SDL_SCANCODE_LALT || keys[i].scancode == SDL_SCANCODE_RALT)
      continue;
    if (!*presses) { *to = keys[i].scancode; *to_mod = keys[i].mod; }
    (*presses)++;
  }
  return count > 0;
}

static bool maps(SDL_Scancode from, SDL_Keymod mod, SDL_Scancode to, SDL_Keymod to_mod) {
  SDL_Scancode key = SDL_SCANCODE_UNKNOWN;
  SDL_Keymod key_mod = 0;
  size_t presses;
  return result(from, mod, &key, &key_mod, &presses) && presses == 1 && key == to && key_mod == to_mod;
}

int main(void) {
  AnvilAltNavigationKey keys[ANVIL_ALT_NAVIGATION_MAX_KEYS];
  const SDL_Keymod A = SDL_KMOD_LALT, S = SDL_KMOD_LSHIFT, C = SDL_KMOD_LCTRL;

  /* Alt+J sends what AutoHotkey's Send sends: Alt goes up, Ctrl+Left, then Alt comes back. */
  size_t count = anvil_alt_navigation_keys(SDL_SCANCODE_J, A, keys);
  CHECK(SAME(keys, count,
             {SDL_SCANCODE_LALT, 0, false}, {SDL_SCANCODE_LCTRL, C, true}, {SDL_SCANCODE_LEFT, C, true},
             {SDL_SCANCODE_LEFT, C, false}, {SDL_SCANCODE_LCTRL, 0, false}, {SDL_SCANCODE_LALT, A, true}));

  /* A held modifier that the result uses stays down. */
  count = anvil_alt_navigation_keys(SDL_SCANCODE_J, A | S, keys);
  CHECK(SAME(keys, count,
             {SDL_SCANCODE_LALT, S, false}, {SDL_SCANCODE_LCTRL, S | C, true}, {SDL_SCANCODE_LEFT, S | C, true},
             {SDL_SCANCODE_LEFT, S | C, false}, {SDL_SCANCODE_LCTRL, S, false}, {SDL_SCANCODE_LALT, A | S, true}));
  count = anvil_alt_navigation_keys(SDL_SCANCODE_J, C | A, keys);
  CHECK(SAME(keys, count,
             {SDL_SCANCODE_LCTRL, A, false}, {SDL_SCANCODE_LEFT, A, true}, {SDL_SCANCODE_LEFT, A, false},
             {SDL_SCANCODE_LCTRL, A | C, true}));

  /* AltGr is Right Alt. A result with Alt uses Left Alt, which the editor does not read as AltGr. */
  count = anvil_alt_navigation_keys(SDL_SCANCODE_L, SDL_KMOD_LCTRL | SDL_KMOD_RALT, keys);
  CHECK(SAME(keys, count,
             {SDL_SCANCODE_LCTRL, SDL_KMOD_RALT, false}, {SDL_SCANCODE_RALT, 0, false}, {SDL_SCANCODE_LALT, A, true},
             {SDL_SCANCODE_RIGHT, A, true}, {SDL_SCANCODE_RIGHT, A, false}, {SDL_SCANCODE_LALT, 0, false},
             {SDL_SCANCODE_RALT, SDL_KMOD_RALT, true}, {SDL_SCANCODE_LCTRL, SDL_KMOD_LCTRL | SDL_KMOD_RALT, true}));

  /* The script's chords. */
  CHECK(maps(SDL_SCANCODE_L, A, SDL_SCANCODE_RIGHT, C));
  CHECK(maps(SDL_SCANCODE_L, A | S, SDL_SCANCODE_RIGHT, C | S));
  CHECK(maps(SDL_SCANCODE_I, A, SDL_SCANCODE_UP, 0));
  CHECK(maps(SDL_SCANCODE_I, A | S, SDL_SCANCODE_UP, S));
  CHECK(maps(SDL_SCANCODE_I, A | C, SDL_SCANCODE_UP, C));
  CHECK(maps(SDL_SCANCODE_K, A, SDL_SCANCODE_DOWN, 0));
  CHECK(maps(SDL_SCANCODE_K, A | S, SDL_SCANCODE_DOWN, S));
  CHECK(maps(SDL_SCANCODE_K, A | C, SDL_SCANCODE_DOWN, C));
  CHECK(maps(SDL_SCANCODE_N, A, SDL_SCANCODE_LEFT, 0));
  CHECK(maps(SDL_SCANCODE_N, A | S, SDL_SCANCODE_LEFT, S));
  CHECK(maps(SDL_SCANCODE_M, A, SDL_SCANCODE_RIGHT, 0));
  CHECK(maps(SDL_SCANCODE_M, A | S, SDL_SCANCODE_RIGHT, S));
  CHECK(maps(SDL_SCANCODE_H, A, SDL_SCANCODE_HOME, 0));
  CHECK(maps(SDL_SCANCODE_H, A | S, SDL_SCANCODE_HOME, S));
  CHECK(maps(SDL_SCANCODE_H, A | C, SDL_SCANCODE_HOME, C));
  CHECK(maps(SDL_SCANCODE_H, A | C | S, SDL_SCANCODE_HOME, C | S));
  /* The Spanish Ñ key. */
  CHECK(maps(SDL_SCANCODE_SEMICOLON, A, SDL_SCANCODE_END, 0));
  CHECK(maps(SDL_SCANCODE_SEMICOLON, A | S, SDL_SCANCODE_END, S));
  CHECK(maps(SDL_SCANCODE_SEMICOLON, A | C, SDL_SCANCODE_END, C));
  CHECK(maps(SDL_SCANCODE_SEMICOLON, A | C | S, SDL_SCANCODE_END, C | S));
  CHECK(maps(SDL_SCANCODE_Q, A, SDL_SCANCODE_ESCAPE, 0));
  CHECK(maps(SDL_SCANCODE_COMMA, A | C, SDL_SCANCODE_PAGEUP, C));
  CHECK(maps(SDL_SCANCODE_PERIOD, A | C, SDL_SCANCODE_PAGEDOWN, C));
  CHECK(maps(SDL_SCANCODE_U, A, SDL_SCANCODE_BACKSPACE, 0));
  CHECK(maps(SDL_SCANCODE_O, A, SDL_SCANCODE_DELETE, 0));

  /* Alt+, and Alt+. move 20 lines. */
  SDL_Scancode key;
  SDL_Keymod key_mod;
  size_t presses;
  CHECK(result(SDL_SCANCODE_COMMA, A, &key, &key_mod, &presses) && key == SDL_SCANCODE_UP && key_mod == 0 &&
        presses == 20);
  CHECK(result(SDL_SCANCODE_COMMA, A | S, &key, &key_mod, &presses) && key == SDL_SCANCODE_UP && key_mod == S &&
        presses == 20);
  CHECK(result(SDL_SCANCODE_PERIOD, A, &key, &key_mod, &presses) && key == SDL_SCANCODE_DOWN && key_mod == 0 &&
        presses == 20);
  CHECK(result(SDL_SCANCODE_PERIOD, A | S, &key, &key_mod, &presses) && key == SDL_SCANCODE_DOWN &&
        key_mod == S && presses == 20);

  /* Alt+Space and Alt+Shift+Space type a plain space. */
  for (int shift = 0; shift < 2; shift++) {
    count = anvil_alt_navigation_keys(SDL_SCANCODE_SPACE, shift ? A | S : A, keys);
    size_t spaces = 0;
    for (size_t i = 0; i < count; i++) {
      if (keys[i].scancode != SDL_SCANCODE_SPACE) { CHECK(!keys[i].space); continue; }
      CHECK(keys[i].mod == 0);
      if (keys[i].down) { CHECK(keys[i].space); spaces++; }
    }
    CHECK(spaces == 1);
  }

  /* Other keys and other modifier sets pass unchanged, as in the script. */
  CHECK(!anvil_alt_navigation_keys(SDL_SCANCODE_J, 0, keys));
  CHECK(!anvil_alt_navigation_keys(SDL_SCANCODE_J, C, keys));
  CHECK(!anvil_alt_navigation_keys(SDL_SCANCODE_X, A, keys));
  CHECK(!anvil_alt_navigation_keys(SDL_SCANCODE_J, A | SDL_KMOD_LGUI, keys));
  CHECK(!anvil_alt_navigation_keys(SDL_SCANCODE_N, A | C, keys));
  CHECK(!anvil_alt_navigation_keys(SDL_SCANCODE_U, A | C, keys));
  CHECK(!anvil_alt_navigation_keys(SDL_SCANCODE_Q, A | S, keys));

  /* Lock keys do not block a chord, and each replacement ends with the modifiers that the user holds. */
  CHECK(maps(SDL_SCANCODE_I, A | SDL_KMOD_CAPS | SDL_KMOD_NUM, SDL_SCANCODE_UP, SDL_KMOD_CAPS | SDL_KMOD_NUM));
  const SDL_Keymod held[] = {A, A | S, A | C, A | C | S, SDL_KMOD_RALT, SDL_KMOD_LCTRL | SDL_KMOD_RALT,
                             A | SDL_KMOD_RSHIFT | SDL_KMOD_CAPS};
  for (size_t h = 0; h < SDL_arraysize(held); h++)
    for (int scancode = 0; scancode < SDL_SCANCODE_COUNT; scancode++) {
      count = anvil_alt_navigation_keys((SDL_Scancode)scancode, held[h], keys);
      CHECK(count <= ANVIL_ALT_NAVIGATION_MAX_KEYS);
      if (count) CHECK(keys[count - 1].mod == held[h]);
    }
  return 0;
}
