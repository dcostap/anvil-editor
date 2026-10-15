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
