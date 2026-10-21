#include <SDL3/SDL.h>
#include <windows.h>
#include <stdbool.h>
#include <stdio.h>

#define CHECK(condition) do { \
  if (!(condition)) { \
    fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); \
    failed = true; \
  } \
} while (0)

static bool layout_loaded(HKL layout) {
  HKL layouts[64];
  int count = GetKeyboardLayoutList(SDL_arraysize(layouts), layouts);
  for (int i = 0; i < count; i++) if (layouts[i] == layout) return true;
  return false;
}

int main(void) {
  bool failed = false;
  /* The Spanish layout has dead keys and ships with every Windows install. */
  HKL spanish = (HKL)(UINT_PTR)0x040a040a;
  bool was_loaded = layout_loaded(spanish);
  if (!LoadKeyboardLayoutA("0000040A", KLF_ACTIVATE | KLF_NOTELLSHELL)) {
    fprintf(stderr, "FAIL: cannot load the Spanish keyboard layout\n");
    return 1;
  }

  /* Ctrl+Shift switches the input language, so SDL builds the keymap while
   * both keys are held. */
  BYTE held[256] = { 0 };
  held[VK_CONTROL] = held[VK_LCONTROL] = 0x80;
  held[VK_SHIFT] = held[VK_LSHIFT] = 0x80;
  SetKeyboardState(held);
  SDL_SetHintWithPriority(SDL_HINT_VIDEO_DRIVER, "windows", SDL_HINT_OVERRIDE);
  bool initialized = SDL_Init(SDL_INIT_VIDEO);
  BYTE released[256] = { 0 };
  SetKeyboardState(released);
  CHECK(initialized && SDL_strcmp(SDL_GetCurrentVideoDriver(), "windows") == 0);

  if (initialized) {
    /* Each key follows a dead key in the keymap build. */
    CHECK(SDL_GetKeyFromScancode(SDL_SCANCODE_RIGHTBRACKET, SDL_KMOD_NONE, false) == '+');
    CHECK(SDL_GetKeyFromScancode(SDL_SCANCODE_RIGHTBRACKET, SDL_KMOD_SHIFT, false) == '*');
    CHECK(SDL_GetKeyFromScancode(SDL_SCANCODE_GRAVE, SDL_KMOD_NONE, false) == 0xba);
    SDL_Quit();
  }

  if (!was_loaded) UnloadKeyboardLayout(spanish);
  return failed ? 1 : 0;
}
