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
