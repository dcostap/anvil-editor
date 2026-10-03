#ifndef ANVIL_INPUT_LATENCY_PROBE_H
#define ANVIL_INPUT_LATENCY_PROBE_H

#include <stdbool.h>
#include <stdint.h>
#include <SDL3/SDL.h>

/* Synthetic typing probe for comparing direct and shell-hosted latency.
 *
 * ANVIL_INPUT_LATENCY_PROBE=<count> enables it. The process that owns the
 * native window generates tagged keystrokes for that window. The process that
 * runs Lua records the highest tag it consumed. The window owner measures
 * from generation until the first presented frame that includes that tag,
 * writes ANVIL_INPUT_LATENCY_FILE, and calls the finish callback. */

void anvil_latency_probe_init(const char *role);
bool anvil_latency_probe_enabled(void);
void anvil_latency_probe_start(SDL_Window *window, void (*finish)(void));
void anvil_latency_probe_note_event(const SDL_Event *event);
uint64_t anvil_latency_probe_consumed_seq(void);
void anvil_latency_probe_presented(uint64_t consumed_seq);

#endif
