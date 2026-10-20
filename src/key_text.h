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

#endif
