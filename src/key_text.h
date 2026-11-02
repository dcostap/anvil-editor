#ifndef KEY_TEXT_H
#define KEY_TEXT_H

#include <SDL3/SDL_keycode.h>
#include <stdbool.h>

/* Writes the text a layout key types as NUL-terminated UTF-8.
 * Returns false for keys that type no text, such as Delete. */
bool key_text_from_keycode(SDL_Keycode key, char out[5]);

/* Writes the keymap name of a key that types printable ASCII, such as "c" or ";".
 * Returns false for other keys, which need SDL's key or scancode names. */
bool key_name_from_ascii_keycode(SDL_Keycode key, char out[2]);

#ifdef _WIN32
/* Writes the text that a physical key types in the Windows keyboard layout `layout` (an HKL), as NUL-terminated
 * UTF-8. `scancode` is the key's set 1 scan code. A dead key gives its own character.
 * Returns false when the key types no text with these modifiers. */
bool key_layout_text(void *layout, unsigned scancode, bool shift, bool altgr, char out[16]);
#endif

#endif
