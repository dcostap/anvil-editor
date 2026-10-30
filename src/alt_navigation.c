#include "alt_navigation.h"
#include <SDL3/SDL_stdinc.h>

enum { ALT = 1, SHIFT = 2, CTRL = 4 };

typedef struct {
  SDL_Scancode from;
  /* The modifiers that the user holds, exactly. */
  Uint8 chord;
  SDL_Scancode to;
  SDL_Keymod mod;
  Uint8 count;
} Chord;

static const Chord chords[] = {
  {SDL_SCANCODE_J, ALT, SDL_SCANCODE_LEFT, SDL_KMOD_LCTRL},
  {SDL_SCANCODE_J, ALT | SHIFT, SDL_SCANCODE_LEFT, SDL_KMOD_LCTRL | SDL_KMOD_LSHIFT},
  {SDL_SCANCODE_J, ALT | CTRL, SDL_SCANCODE_LEFT, SDL_KMOD_LALT},
  {SDL_SCANCODE_L, ALT, SDL_SCANCODE_RIGHT, SDL_KMOD_LCTRL},
  {SDL_SCANCODE_L, ALT | SHIFT, SDL_SCANCODE_RIGHT, SDL_KMOD_LCTRL | SDL_KMOD_LSHIFT},
  {SDL_SCANCODE_L, ALT | CTRL, SDL_SCANCODE_RIGHT, SDL_KMOD_LALT},
  {SDL_SCANCODE_I, ALT, SDL_SCANCODE_UP, 0},
  {SDL_SCANCODE_I, ALT | SHIFT, SDL_SCANCODE_UP, SDL_KMOD_LSHIFT},
  {SDL_SCANCODE_I, ALT | CTRL, SDL_SCANCODE_UP, SDL_KMOD_LCTRL},
  {SDL_SCANCODE_K, ALT, SDL_SCANCODE_DOWN, 0},
  {SDL_SCANCODE_K, ALT | SHIFT, SDL_SCANCODE_DOWN, SDL_KMOD_LSHIFT},
  {SDL_SCANCODE_K, ALT | CTRL, SDL_SCANCODE_DOWN, SDL_KMOD_LCTRL},
  {SDL_SCANCODE_N, ALT, SDL_SCANCODE_LEFT, 0},
  {SDL_SCANCODE_N, ALT | SHIFT, SDL_SCANCODE_LEFT, SDL_KMOD_LSHIFT},
  {SDL_SCANCODE_M, ALT, SDL_SCANCODE_RIGHT, 0},
  {SDL_SCANCODE_M, ALT | SHIFT, SDL_SCANCODE_RIGHT, SDL_KMOD_LSHIFT},
  {SDL_SCANCODE_H, ALT, SDL_SCANCODE_HOME, 0},
  {SDL_SCANCODE_H, ALT | SHIFT, SDL_SCANCODE_HOME, SDL_KMOD_LSHIFT},
  {SDL_SCANCODE_H, ALT | CTRL, SDL_SCANCODE_HOME, SDL_KMOD_LCTRL},
  {SDL_SCANCODE_H, ALT | CTRL | SHIFT, SDL_SCANCODE_HOME, SDL_KMOD_LCTRL | SDL_KMOD_LSHIFT},
  /* The Spanish Ñ key. */
  {SDL_SCANCODE_SEMICOLON, ALT, SDL_SCANCODE_END, 0},
  {SDL_SCANCODE_SEMICOLON, ALT | SHIFT, SDL_SCANCODE_END, SDL_KMOD_LSHIFT},
  {SDL_SCANCODE_SEMICOLON, ALT | CTRL, SDL_SCANCODE_END, SDL_KMOD_LCTRL},
  {SDL_SCANCODE_SEMICOLON, ALT | CTRL | SHIFT, SDL_SCANCODE_END, SDL_KMOD_LCTRL | SDL_KMOD_LSHIFT},
  {SDL_SCANCODE_Q, ALT, SDL_SCANCODE_ESCAPE, 0},
  {SDL_SCANCODE_COMMA, ALT, SDL_SCANCODE_UP, 0, 20},
  {SDL_SCANCODE_COMMA, ALT | SHIFT, SDL_SCANCODE_UP, SDL_KMOD_LSHIFT, 20},
  {SDL_SCANCODE_COMMA, ALT | CTRL, SDL_SCANCODE_PAGEUP, SDL_KMOD_LCTRL},
  {SDL_SCANCODE_PERIOD, ALT, SDL_SCANCODE_DOWN, 0, 20},
  {SDL_SCANCODE_PERIOD, ALT | SHIFT, SDL_SCANCODE_DOWN, SDL_KMOD_LSHIFT, 20},
  {SDL_SCANCODE_PERIOD, ALT | CTRL, SDL_SCANCODE_PAGEDOWN, SDL_KMOD_LCTRL},
  {SDL_SCANCODE_U, ALT, SDL_SCANCODE_BACKSPACE, 0},
  {SDL_SCANCODE_O, ALT, SDL_SCANCODE_DELETE, 0},
  {SDL_SCANCODE_SPACE, ALT, SDL_SCANCODE_SPACE, 0},
  {SDL_SCANCODE_SPACE, ALT | SHIFT, SDL_SCANCODE_SPACE, 0},
};

/* Release order. Restores use the reverse order. */
static const struct { SDL_Keymod mod; SDL_Scancode scancode; } modifiers[] = {
  {SDL_KMOD_LCTRL, SDL_SCANCODE_LCTRL}, {SDL_KMOD_RCTRL, SDL_SCANCODE_RCTRL},
  {SDL_KMOD_LSHIFT, SDL_SCANCODE_LSHIFT}, {SDL_KMOD_RSHIFT, SDL_SCANCODE_RSHIFT},
  {SDL_KMOD_LALT, SDL_SCANCODE_LALT}, {SDL_KMOD_RALT, SDL_SCANCODE_RALT},
};

static void add(AnvilAltNavigationKey *keys, size_t *count, SDL_Scancode scancode, SDL_Keymod mod, bool down,
                bool space) {
  keys[(*count)++] = (AnvilAltNavigationKey){scancode, mod, down, space};
}

size_t anvil_alt_navigation_keys(SDL_Scancode scancode, SDL_Keymod mod,
                                 AnvilAltNavigationKey keys[ANVIL_ALT_NAVIGATION_MAX_KEYS]) {
  if (mod & SDL_KMOD_GUI) return 0;
  Uint8 chord = ((mod & SDL_KMOD_ALT) ? ALT : 0) | ((mod & SDL_KMOD_SHIFT) ? SHIFT : 0) |
                ((mod & SDL_KMOD_CTRL) ? CTRL : 0);
  const Chord *match = NULL;
  for (size_t i = 0; i < SDL_arraysize(chords) && !match; i++)
    if (chords[i].from == scancode && chords[i].chord == chord) match = &chords[i];
  if (!match) return 0;

  size_t count = 0;
  SDL_Keymod state = mod;
  SDL_Keymod released = mod & (SDL_KMOD_CTRL | SDL_KMOD_SHIFT | SDL_KMOD_ALT) & ~match->mod;
  SDL_Keymod pressed = match->mod & ~mod;
  for (size_t i = 0; i < SDL_arraysize(modifiers); i++)
    if (released & modifiers[i].mod) add(keys, &count, modifiers[i].scancode, state &= ~modifiers[i].mod, false, false);
  for (size_t i = 0; i < SDL_arraysize(modifiers); i++)
    if (pressed & modifiers[i].mod) add(keys, &count, modifiers[i].scancode, state |= modifiers[i].mod, true, false);
  for (Uint8 i = 0; i < (match->count ? match->count : 1); i++) {
    add(keys, &count, match->to, state, true, match->to == SDL_SCANCODE_SPACE);
    add(keys, &count, match->to, state, false, false);
  }
  for (size_t i = SDL_arraysize(modifiers); i-- > 0;)
    if (pressed & modifiers[i].mod) add(keys, &count, modifiers[i].scancode, state &= ~modifiers[i].mod, false, false);
  for (size_t i = SDL_arraysize(modifiers); i-- > 0;)
    if (released & modifiers[i].mod) add(keys, &count, modifiers[i].scancode, state |= modifiers[i].mod, true, false);
  return count;
}
