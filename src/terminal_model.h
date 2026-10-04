#ifndef ANVIL_TERMINAL_MODEL_H
#define ANVIL_TERMINAL_MODEL_H
#include <windows.h>
#include <ghostty/vt.h>
extern const GhosttyAllocator terminal_allocator;
/* Bound parser continuation and the complete encoded checkpoint independently. */
#define ANVIL_TERMINAL_CONTINUATION_LIMIT (65u * 1024u * 1024u)
#define ANVIL_TERMINAL_SNAPSHOT_LIMIT (128u * 1024u * 1024u)
#define ANVIL_TERMINAL_DISK_SNAPSHOT_LIMIT (8u * 1024u * 1024u)
bool anvil_terminal_model_options(GhosttyTerminal model, const size_t *scrollback_lines);
bool anvil_terminal_model_new(GhosttyTerminal *model, uint16_t cols, uint16_t rows,
                              uint32_t cell_width, uint32_t cell_height,
                              const size_t *scrollback_lines);

/* Caller holds the model lock. Free the result with free(). */
bool anvil_terminal_snapshot_encode(GhosttyTerminal model, uint8_t **bytes, size_t *length);
/* Decode through FINISH. Reject trailing bytes. The caller owns the model. */
bool anvil_terminal_snapshot_decode(const uint8_t *bytes, size_t length, GhosttyTerminal *model);
/* Trim a copy, never the live model. A large active screen or continuation can fail. */
bool anvil_terminal_disk_snapshot_encode(GhosttyTerminal model, uint8_t **bytes, size_t *length);
#endif
