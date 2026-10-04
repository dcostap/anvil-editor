#ifndef ANVIL_TERMINAL_SNAPSHOT_H
#define ANVIL_TERMINAL_SNAPSHOT_H
#include "terminal_model.h"
#define ANVIL_TERMINAL_PROJECT_SNAPSHOTS 32u
/* Host/worker only. Payload is the Ghostty codec; the envelope binds its owner. */
bool anvil_terminal_snapshot_store(const char *path, const char *project, const char *id,
                                  const uint8_t *bytes, size_t length, bool final, DWORD *error);
bool anvil_terminal_snapshot_load(const char *path, const char *project, const char *id,
                                 GhosttyTerminal *model, DWORD *error);
#endif
