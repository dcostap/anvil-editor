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

#ifdef _WIN32
#include <windows.h>

bool key_layout_text(void *layout, unsigned scancode, bool shift, bool altgr, char out[16]) {
  HKL hkl = (HKL)layout;
  UINT vk = MapVirtualKeyExW(scancode, MAPVK_VSC_TO_VK, hkl);
  if (!vk) return false;
  BYTE state[256] = { 0 };
  if (shift) state[VK_SHIFT] = state[VK_LSHIFT] = 0x80;
  if (altgr) state[VK_CONTROL] = state[VK_LCONTROL] = state[VK_MENU] = state[VK_RMENU] = 0x80;
  WCHAR text[8];
  /* Flag 4 keeps the keyboard state, so a dead key does not wait for the next key the user types. */
  int count = ToUnicodeEx(vk, scancode, state, text, SDL_arraysize(text), 4, hkl);
  /* A dead key gives its own character with a negative count. */
  if (count < 0) count = 1;
  if (count == 0 || text[0] < 0x20 || text[0] == 0x7f) return false;
  int length = WideCharToMultiByte(CP_UTF8, 0, text, count, out, 15, NULL, NULL);
  if (length <= 0) return false;
  out[length] = '\0';
  return true;
}
#endif
