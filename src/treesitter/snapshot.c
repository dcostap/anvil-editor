#include "snapshot.h"

#include <stdlib.h>
#include <string.h>

static uint64_t next_snapshot_id = 1;

static char *snapshot_strdup(const char *text) {
  if (!text) return NULL;
  size_t len = strlen(text);
  char *copy = (char *) malloc(len + 1);
  if (!copy) return NULL;
  memcpy(copy, text, len + 1);
  return copy;
}

static void snapshot_set_error(char **error, const char *message) {
  if (!error) return;
  *error = snapshot_strdup(message);
}

AnvilTSSnapshot *anvil_ts_snapshot_new_from_lines(
  const char *const *lines,
  const uint32_t *line_lengths,
  uint32_t line_count,
  char **error
) {
  if (error) *error = NULL;
  if (line_count > 0 && (!lines || !line_lengths)) {
    snapshot_set_error(error, "invalid line table");
    return NULL;
  }

  uint64_t total = 0;
  for (uint32_t i = 0; i < line_count; i++) {
    total += line_lengths[i];
    if (total > UINT32_MAX) {
      snapshot_set_error(error, "Tree-sitter snapshot exceeds 4GB byte limit");
      return NULL;
    }
  }

  AnvilTSSnapshot *snapshot = (AnvilTSSnapshot *) calloc(1, sizeof(*snapshot));
  if (!snapshot) {
    snapshot_set_error(error, "out of memory allocating Tree-sitter snapshot");
    return NULL;
  }

  snapshot->id = next_snapshot_id++;
  snapshot->byte_len = (uint32_t) total;
  snapshot->line_count = line_count;
  snapshot->bytes = (char *) malloc((size_t) snapshot->byte_len + 1);
  snapshot->line_starts = line_count ? (uint32_t *) malloc(sizeof(uint32_t) * line_count) : NULL;
  snapshot->line_lengths = line_count ? (uint32_t *) malloc(sizeof(uint32_t) * line_count) : NULL;
  if (!snapshot->bytes || (line_count && (!snapshot->line_starts || !snapshot->line_lengths))) {
    anvil_ts_snapshot_free(snapshot);
    snapshot_set_error(error, "out of memory copying Tree-sitter snapshot");
    return NULL;
  }

  uint32_t offset = 0;
  for (uint32_t i = 0; i < line_count; i++) {
    snapshot->line_starts[i] = offset;
    snapshot->line_lengths[i] = line_lengths[i];
    if (line_lengths[i] > 0) memcpy(snapshot->bytes + offset, lines[i], line_lengths[i]);
    offset += line_lengths[i];
  }
  snapshot->bytes[snapshot->byte_len] = '\0';
  return snapshot;
}

void anvil_ts_snapshot_free(AnvilTSSnapshot *snapshot) {
  if (!snapshot) return;
  free(snapshot->bytes);
  free(snapshot->line_starts);
  free(snapshot->line_lengths);
  free(snapshot);
}

bool anvil_ts_snapshot_position_from_anvil(
  const AnvilTSSnapshot *snapshot,
  uint32_t line,
  uint32_t column,
  AnvilTSPosition *out
) {
  if (!snapshot || !out || line == 0 || column == 0 || line > snapshot->line_count) return false;
  uint32_t line_index = line - 1;
  uint32_t col0 = column - 1;
  if (col0 > snapshot->line_lengths[line_index]) return false;

  uint32_t byte = snapshot->line_starts[line_index] + col0;
  if (byte > snapshot->byte_len) return false;
  out->byte = byte;
  out->point.row = line_index;
  out->point.column = col0;
  return true;
}

static const char *snapshot_read(
  void *payload,
  uint32_t byte_index,
  TSPoint position,
  uint32_t *bytes_read
) {
  (void) position;
  AnvilTSSnapshot *snapshot = (AnvilTSSnapshot *) payload;
  if (!snapshot || byte_index >= snapshot->byte_len) {
    *bytes_read = 0;
    return "";
  }
  uint32_t remaining = snapshot->byte_len - byte_index;
  *bytes_read = remaining > 8192 ? 8192 : remaining;
  return snapshot->bytes + byte_index;
}

TSInput anvil_ts_snapshot_input(AnvilTSSnapshot *snapshot) {
  TSInput input;
  input.payload = snapshot;
  input.read = snapshot_read;
  input.encoding = TSInputEncodingUTF8;
  input.decode = NULL;
  return input;
}
