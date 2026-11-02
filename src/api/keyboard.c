#include <SDL3/SDL.h>
#include "api.h"
#include "../alt_navigation.h"
#include "../key_text.h"
#ifdef _WIN32
  #include <windows.h>
#endif

/* Facts about the physical keyboard, for the Keyboard Map. */

/* The texts that the physical key with set 1 scan code `scancode` types in the keyboard layout of the focused
 * window: plain, with Shift and with AltGr. Each is nil when the key types nothing. Returns nothing outside
 * Windows. */
static int f_layout_text(lua_State *L) {
#ifdef _WIN32
  unsigned scancode = (unsigned)luaL_checkinteger(L, 1);
  /* A Project process has no focused window of its own. The shell's window has the user's layout. */
  HWND foreground = GetForegroundWindow();
  HKL layout = GetKeyboardLayout(foreground ? GetWindowThreadProcessId(foreground, NULL) : 0);
  static const bool mods[3][2] = { { false, false }, { true, false }, { false, true } };
  for (int i = 0; i < 3; i++) {
    char text[16];
    if (key_layout_text(layout, scancode, mods[i][0], mods[i][1], text)) lua_pushstring(L, text);
    else lua_pushnil(L);
  }
  return 3;
#else
  return 0;
#endif
}

static void push_lower(lua_State *L, const char *text) {
  char buf[64];
  SDL_strlcpy(buf, text, sizeof(buf));
  for (char *p = buf; *p; p++) *p = (char)SDL_tolower((unsigned char)*p);
  lua_pushstring(L, buf);
}

/* The Alt Navigation chords. Each has the held key's scancode name, such as "j", the `ctrl` and `shift` held
 * with Alt, and the key name that the chord types, with its modifiers and count. */
static int f_alt_navigation_chords(lua_State *L) {
  lua_newtable(L);
  AnvilAltNavigationChord chord;
  for (size_t i = 0; anvil_alt_navigation_chord(i, &chord); i++) {
    lua_createtable(L, 0, 8);
    push_lower(L, SDL_GetScancodeName(chord.from));
    lua_setfield(L, -2, "key");
    lua_pushboolean(L, chord.ctrl);
    lua_setfield(L, -2, "ctrl");
    lua_pushboolean(L, chord.shift);
    lua_setfield(L, -2, "shift");
    push_lower(L, SDL_GetKeyName(SDL_GetKeyFromScancode(chord.to, SDL_KMOD_NONE, false)));
    lua_setfield(L, -2, "target");
    lua_pushboolean(L, (chord.mod & SDL_KMOD_CTRL) != 0);
    lua_setfield(L, -2, "target_ctrl");
    lua_pushboolean(L, (chord.mod & SDL_KMOD_SHIFT) != 0);
    lua_setfield(L, -2, "target_shift");
    lua_pushboolean(L, (chord.mod & SDL_KMOD_ALT) != 0);
    lua_setfield(L, -2, "target_alt");
    lua_pushinteger(L, chord.count);
    lua_setfield(L, -2, "count");
    lua_rawseti(L, -2, (int)i + 1);
  }
  return 1;
}

static const luaL_Reg lib[] = {
  { "layout_text", f_layout_text },
  { "alt_navigation_chords", f_alt_navigation_chords },
  { NULL, NULL }
};

int luaopen_keyboard(lua_State *L) {
  luaL_newlib(L, lib);
  return 1;
}
