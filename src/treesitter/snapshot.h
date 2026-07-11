#ifndef ANVIL_TREESITTER_SNAPSHOT_H
#define ANVIL_TREESITTER_SNAPSHOT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <tree_sitter/api.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AnvilTSSnapshot {
  uint64_t id;
  uint32_t refcount;
  char *bytes;
  uint32_t byte_len;
  uint32_t line_count;
  uint32_t *line_starts;
  uint32_t *line_lengths;
} AnvilTSSnapshot;

typedef struct AnvilTSPosition {
  uint32_t byte;
  TSPoint point;
} AnvilTSPosition;

AnvilTSSnapshot *anvil_ts_snapshot_new_from_lines(
  const char *const *lines,
  const uint32_t *line_lengths,
  uint32_t line_count,
  char **error
);
/* Takes ownership of a malloc-allocated, NUL-terminated byte buffer on every path. */
AnvilTSSnapshot *anvil_ts_snapshot_new_take_text(
  char *bytes,
  uint32_t byte_len,
  char **error
);
void anvil_ts_snapshot_retain(AnvilTSSnapshot *snapshot);
void anvil_ts_snapshot_free(AnvilTSSnapshot *snapshot);

bool anvil_ts_snapshot_position_from_anvil(
  const AnvilTSSnapshot *snapshot,
  uint32_t line,
  uint32_t column,
  AnvilTSPosition *out
);

TSInput anvil_ts_snapshot_input(AnvilTSSnapshot *snapshot);

#ifdef __cplusplus
}
#endif

#endif
