#ifndef KEY_TEXT_H
#define KEY_TEXT_H

#include <SDL3/SDL_keycode.h>
#include <stdbool.h>

/* Writes the text a layout key types as NUL-terminated UTF-8.
 * Returns false for keys that type no text, such as Delete. */
bool key_text_from_keycode(SDL_Keycode key, char out[5]);

#endif
