#ifndef ANVIL_ALT_NAVIGATION_H
#define ANVIL_ALT_NAVIGATION_H
#include <SDL3/SDL_keyboard.h>
#include <stdbool.h>
#include <stddef.h>

/* Alt Navigation turns Alt chords into navigation keys, such as Alt+J into Ctrl+Left. It does what the
 * user's AutoHotkey script does on their own PC, for a PC without that script. Chords match physical key
 * positions, so the Spanish Ñ key is the semicolon key on a US layout. */

/* One key event of a replacement. `mod` is the modifier state after the event, as SDL reports it. */
typedef struct {
  SDL_Scancode scancode;
  SDL_Keymod mod;
  bool down;
  /* The press types a space. */
  bool space;
} AnvilAltNavigationKey;

#define ANVIL_ALT_NAVIGATION_MAX_KEYS 64

/* Writes the key events that replace one press of `scancode` with the modifier state `mod`, and returns their
 * count. Returns 0 when the press is not an Alt Navigation chord, so it passes unchanged.
 * Like AutoHotkey's Send, the events release the held modifiers that the result does not use, press the
 * result's modifiers, type the result, then restore the held modifiers. */
size_t anvil_alt_navigation_keys(SDL_Scancode scancode, SDL_Keymod mod,
                                 AnvilAltNavigationKey keys[ANVIL_ALT_NAVIGATION_MAX_KEYS]);

#endif
