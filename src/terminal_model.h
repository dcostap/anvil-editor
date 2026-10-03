#ifndef ANVIL_TERMINAL_MODEL_H
#define ANVIL_TERMINAL_MODEL_H
#include <windows.h>
#include <ghostty/vt.h>
extern const GhosttyAllocator terminal_allocator;
bool anvil_terminal_model_new(GhosttyTerminal *model, uint16_t cols, uint16_t rows,
                              uint32_t cell_width, uint32_t cell_height,
                              const size_t *scrollback_lines);

/* A bounded prefix, not a sliding window. Overflow makes replay unavailable. */
#define ANVIL_TERMINAL_REPLAY_LIMIT (8u * 1024u * 1024u)
typedef struct { uint8_t *bytes; size_t length; bool overflow; } AnvilTerminalReplay;
void anvil_terminal_replay_append(AnvilTerminalReplay *replay, const uint8_t *bytes, size_t length);
void anvil_terminal_replay_free(AnvilTerminalReplay *replay);
#endif
