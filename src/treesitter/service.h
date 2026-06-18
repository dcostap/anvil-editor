#ifndef ANVIL_TREESITTER_SERVICE_H
#define ANVIL_TREESITTER_SERVICE_H

#include <stdbool.h>
#include <stdint.h>

#include <lua.h>
#include <SDL3/SDL_events.h>
#include <tree_sitter/api.h>

#include "languages.h"
#include "snapshot.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum AnvilTSStateStatus {
  ANVIL_TS_STATE_IDLE,
  ANVIL_TS_STATE_QUEUED,
  ANVIL_TS_STATE_PARSING,
  ANVIL_TS_STATE_READY,
  ANVIL_TS_STATE_CANCELED,
  ANVIL_TS_STATE_FAILED,
  ANVIL_TS_STATE_CLOSED,
} AnvilTSStateStatus;

typedef struct AnvilTSDocumentState AnvilTSDocumentState;

typedef struct AnvilTSPollResult {
  AnvilTSStateStatus status;
  bool changed;
  bool discarded_stale;
} AnvilTSPollResult;

typedef struct AnvilTSEdit {
  TSInputEdit input_edit;
} AnvilTSEdit;

typedef struct AnvilTSQueryCapture {
  const char *name;
  uint32_t name_len;
  uint32_t start_byte;
  uint32_t end_byte;
  TSPoint start_point;
  TSPoint end_point;
  int32_t priority;
  uint32_t match_id;
  uint32_t pattern_index;
  uint32_t capture_index;
  uint32_t order;
} AnvilTSQueryCapture;

typedef struct AnvilTSNodeRange {
  const char *type;
  uint32_t type_len;
  uint32_t start_byte;
  uint32_t end_byte;
  TSPoint start_point;
  TSPoint end_point;
  bool named;
} AnvilTSNodeRange;

typedef bool (*AnvilTSQueryCaptureCallback)(
  const AnvilTSQueryCapture *capture,
  void *payload
);

typedef bool (*AnvilTSNodeRangeCallback)(
  const AnvilTSNodeRange *range,
  void *payload
);

AnvilTSDocumentState *anvil_ts_document_state_new(
  const AnvilTSLanguage *language,
  uint32_t parse_timeout_ms
);
void anvil_ts_document_state_retain(AnvilTSDocumentState *state);
void anvil_ts_document_state_release(AnvilTSDocumentState *state);

const char *anvil_ts_document_state_language_id(const AnvilTSDocumentState *state);
AnvilTSStateStatus anvil_ts_document_state_status(const AnvilTSDocumentState *state);
const char *anvil_ts_document_state_status_string(AnvilTSStateStatus status);
bool anvil_ts_document_state_status_snapshot(
  const AnvilTSDocumentState *state,
  AnvilTSStateStatus *status,
  char **reason
);
uint64_t anvil_ts_document_state_generation(const AnvilTSDocumentState *state);
uint64_t anvil_ts_document_state_tree_generation(const AnvilTSDocumentState *state);
bool anvil_ts_document_state_has_tree(const AnvilTSDocumentState *state);
bool anvil_ts_document_state_query_captures(
  AnvilTSDocumentState *state,
  const TSQuery *query,
  uint32_t byte_start,
  uint32_t byte_end,
  uint32_t match_limit,
  uint32_t max_captures,
  uint32_t timeout_ms,
  AnvilTSQueryCaptureCallback callback,
  void *payload,
  bool *exceeded_match_limit,
  char **error
);
bool anvil_ts_document_state_node_ranges(
  AnvilTSDocumentState *state,
  uint32_t byte_start,
  uint32_t byte_end,
  bool named_only,
  uint32_t max_nodes,
  AnvilTSNodeRangeCallback callback,
  void *payload,
  char **error
);

bool anvil_ts_document_state_schedule_parse(
  AnvilTSDocumentState *state,
  AnvilTSSnapshot *snapshot,
  uint64_t generation,
  char **error
);
bool anvil_ts_document_state_schedule_parse_with_edit(
  AnvilTSDocumentState *state,
  AnvilTSSnapshot *snapshot,
  uint64_t generation,
  const AnvilTSEdit *edit,
  char **error
);
AnvilTSPollResult anvil_ts_document_state_poll(
  AnvilTSDocumentState *state,
  uint64_t current_generation
);
void anvil_ts_document_state_cancel(AnvilTSDocumentState *state);
void anvil_ts_document_state_close(AnvilTSDocumentState *state);

bool anvil_ts_service_register_complete_event(void);
int anvil_ts_service_complete_event_callback(lua_State *L, SDL_Event *event);
void anvil_ts_service_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif
