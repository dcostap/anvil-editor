#include <SDL3/SDL.h>
#include "key_text.h"

bool key_text_from_keycode(SDL_Keycode key, char out[5]) {
  /* SDL key names are labels such as "Delete" and "Space", not typed text. */
  if ((key & SDLK_SCANCODE_MASK) || key < 0x20 || (key >= 0x7f && key < 0xa0) ||
      (key >= 0xd800 && key <= 0xdfff) || key > 0x10ffff) return false;
  char *end = SDL_UCS4ToUTF8(key, out);
  *end = '\0';
  return true;
}

bool key_name_from_ascii_keycode(SDL_Keycode key, char out[2]) {
  /* SDL names letters from the layout's shifted character. A stale Windows
   * keymap can return an invalid one, which SDL names U+FFFD. */
  if (key <= 0x20 || key >= 0x7f) return false;
  out[0] = (char)SDL_tolower((int)key);
  out[1] = '\0';
  return true;
}
