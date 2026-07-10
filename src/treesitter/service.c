#include "service.h"

#include "../custom_events.h"

#include <SDL3/SDL.h>

#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ANVIL_TS_COMPLETE_EVENT "treesitter_complete"
#define ANVIL_TS_DOCUMENT_WORKER_COUNT 2

typedef struct AnvilTSParseJob AnvilTSParseJob;

struct AnvilTSDocumentState {
  uint64_t id;
  int refcount;
  const AnvilTSLanguage *language;
  uint32_t parse_timeout_ms;
  AnvilTSStateStatus status;
  char *reason;
  bool closed;
  uint64_t generation;
  uint64_t tree_generation;
  TSTree *current_tree;
  AnvilTSSnapshot *current_snapshot;
  AnvilTSParseJob *active_job;
};

struct AnvilTSParseJob {
  AnvilTSParseJob *next;
  AnvilTSParseJob *completed_next;
  uint64_t id;
  uint64_t generation;
  AnvilTSDocumentState *state;
  const AnvilTSLanguage *language;
  AnvilTSSnapshot *snapshot;
  SDL_AtomicInt cancel;
  uint32_t parse_timeout_ms;
  uint64_t started_ticks;
  TSTree *old_tree;
  TSTree *result_tree;
  bool canceled;
  bool timed_out;
  bool failed;
  char *error;
};

typedef struct AnvilTSService {
  SDL_Mutex *mutex;
  SDL_Condition *cond;
  SDL_Thread *workers[ANVIL_TS_DOCUMENT_WORKER_COUNT];
  bool initialized;
  bool shutdown;
  bool event_registered;
  bool complete_event_pending;
  bool atexit_registered;
  uint64_t next_state_id;
  uint64_t next_job_id;
  AnvilTSParseJob *queue_head;
  AnvilTSParseJob *queue_tail;
  AnvilTSParseJob *running_jobs[ANVIL_TS_DOCUMENT_WORKER_COUNT];
  AnvilTSParseJob *completed_head;
  AnvilTSParseJob *completed_tail;
} AnvilTSService;

static AnvilTSService service;

static char *service_strdup(const char *text) {
  if (!text) return NULL;
  size_t len = strlen(text);
  char *copy = (char *) malloc(len + 1);
  if (!copy) return NULL;
  memcpy(copy, text, len + 1);
  return copy;
}

static void service_set_error(char **error, const char *message) {
  if (!error) return;
  *error = service_strdup(message);
}

static void state_set_reason_locked(AnvilTSDocumentState *state, const char *reason) {
  free(state->reason);
  state->reason = service_strdup(reason);
}

static bool service_init_locked(void);
static int service_worker_main(void *userdata);
static void job_free(AnvilTSParseJob *job);

static bool service_lock(void) {
  if (!service.mutex) return false;
  SDL_LockMutex(service.mutex);
  return true;
}

static void service_unlock(void) {
  SDL_UnlockMutex(service.mutex);
}

static bool service_init_locked(void) {
  if (service.initialized) return true;
  memset(&service, 0, sizeof(service));
  service.mutex = SDL_CreateMutex();
  service.cond = SDL_CreateCondition();
  service.next_state_id = 1;
  service.next_job_id = 1;
  if (!service.mutex || !service.cond) {
    if (service.cond) SDL_DestroyCondition(service.cond);
    if (service.mutex) SDL_DestroyMutex(service.mutex);
    memset(&service, 0, sizeof(service));
    return false;
  }
  service.initialized = true;
  return true;
}

static bool service_ensure_initialized(void) {
  if (service.initialized) return true;
  SDL_Mutex *bootstrap = SDL_CreateMutex();
  if (!bootstrap) return false;
  SDL_LockMutex(bootstrap);
  bool ok = service_init_locked();
  SDL_UnlockMutex(bootstrap);
  SDL_DestroyMutex(bootstrap);
  return ok;
}

static bool service_ensure_worker_locked(void) {
  if (service.workers[0]) return true;
  service.shutdown = false;
  for (int i = 0; i < ANVIL_TS_DOCUMENT_WORKER_COUNT; i++) {
    char name[32];
    SDL_snprintf(name, sizeof(name), "anvil-ts-parser-%d", i + 1);
    service.workers[i] = SDL_CreateThread(service_worker_main, name, (void *) (intptr_t) i);
    if (!service.workers[i]) return i > 0;
  }
  return true;
}

static void enqueue_job_locked(AnvilTSParseJob *job) {
  job->next = NULL;
  if (service.queue_tail) {
    service.queue_tail->next = job;
  } else {
    service.queue_head = job;
  }
  service.queue_tail = job;
  SDL_SignalCondition(service.cond);
}

static AnvilTSParseJob *dequeue_job_locked(void) {
  AnvilTSParseJob *job = service.queue_head;
  if (!job) return NULL;
  service.queue_head = job->next;
  if (!service.queue_head) service.queue_tail = NULL;
  job->next = NULL;
  return job;
}

static void push_completed_locked(AnvilTSParseJob *job) {
  job->completed_next = NULL;
  if (service.completed_tail) {
    service.completed_tail->completed_next = job;
  } else {
    service.completed_head = job;
  }
  service.completed_tail = job;
}

static bool parse_progress(TSParseState *parse_state) {
  AnvilTSParseJob *job = (AnvilTSParseJob *) parse_state->payload;
  if (SDL_GetAtomicInt(&job->cancel)) return true;
  if (job->parse_timeout_ms > 0) {
    uint64_t now = SDL_GetTicks();
    if (now - job->started_ticks >= job->parse_timeout_ms) {
      job->timed_out = true;
      return true;
    }
  }
  return false;
}

static void push_complete_event_if_registered(void) {
  if (!service.event_registered || service.complete_event_pending) return;
  CustomEvent event;
  SDL_zero(event);
  service.complete_event_pending = true;
  if (!push_custom_event(ANVIL_TS_COMPLETE_EVENT, &event)) service.complete_event_pending = false;
}

static int service_worker_main(void *userdata) {
  int worker_index = (int) (intptr_t) userdata;
  for (;;) {
    if (!service_lock()) return 1;
    while (!service.shutdown && service.queue_head == NULL) {
      SDL_WaitCondition(service.cond, service.mutex);
    }
    if (service.shutdown) {
      service_unlock();
      break;
    }
    AnvilTSParseJob *job = dequeue_job_locked();
    service.running_jobs[worker_index] = job;
    if (job && job->state->active_job == job && !job->state->closed && !SDL_GetAtomicInt(&job->cancel)) {
      job->state->status = ANVIL_TS_STATE_PARSING;
      state_set_reason_locked(job->state, NULL);
    }
    service_unlock();

    if (!job) continue;

    if (!SDL_GetAtomicInt(&job->cancel)) {
      TSParser *parser = ts_parser_new();
      if (!parser) {
        job->failed = true;
        job->error = service_strdup("failed to allocate Tree-sitter parser");
      } else if (!ts_parser_set_language(parser, anvil_ts_language_ptr(job->language))) {
        job->failed = true;
        job->error = service_strdup("failed to set Tree-sitter parser language");
      } else {
        TSInput input = anvil_ts_snapshot_input(job->snapshot);
        TSParseOptions options;
        options.payload = job;
        options.progress_callback = parse_progress;
        job->started_ticks = SDL_GetTicks();
        job->result_tree = ts_parser_parse_with_options(parser, job->old_tree, input, options);
        if (SDL_GetAtomicInt(&job->cancel)) {
          job->canceled = true;
          if (job->result_tree) {
            ts_tree_delete(job->result_tree);
            job->result_tree = NULL;
          }
          ts_parser_reset(parser);
        } else if (job->timed_out) {
          job->failed = true;
          job->error = service_strdup("Tree-sitter parse timed out");
          if (job->result_tree) {
            ts_tree_delete(job->result_tree);
            job->result_tree = NULL;
          }
          ts_parser_reset(parser);
        } else if (!job->result_tree) {
          job->failed = true;
          job->error = service_strdup("Tree-sitter parse returned no tree");
          ts_parser_reset(parser);
        }
      }
      if (parser) ts_parser_delete(parser);
    } else {
      job->canceled = true;
    }

    bool free_without_poll = false;
    if (!service_lock()) {
      job_free(job);
      return 1;
    }
    service.running_jobs[worker_index] = NULL;
    if (job->state->closed) {
      if (job->state->active_job == job) job->state->active_job = NULL;
      free_without_poll = true;
    } else {
      push_completed_locked(job);
      push_complete_event_if_registered();
    }
    service_unlock();

    if (free_without_poll) job_free(job);
  }
  return 0;
}

AnvilTSDocumentState *anvil_ts_document_state_new(
  const AnvilTSLanguage *language,
  uint32_t parse_timeout_ms
) {
  if (!language || !anvil_ts_language_is_compatible(language)) return NULL;
  if (!service_ensure_initialized()) return NULL;
  if (!service_lock()) return NULL;
  AnvilTSDocumentState *state = (AnvilTSDocumentState *) calloc(1, sizeof(*state));
  if (!state) {
    service_unlock();
    return NULL;
  }
  state->id = service.next_state_id++;
  state->refcount = 1;
  state->language = language;
  state->parse_timeout_ms = parse_timeout_ms;
  state->status = ANVIL_TS_STATE_IDLE;
  service_unlock();
  return state;
}

void anvil_ts_document_state_retain(AnvilTSDocumentState *state) {
  if (!state || !service_ensure_initialized() || !service_lock()) return;
  state->refcount++;
  service_unlock();
}

static void state_destroy_unlocked(AnvilTSDocumentState *state) {
  if (!state) return;
  if (state->current_tree) ts_tree_delete(state->current_tree);
  anvil_ts_snapshot_free(state->current_snapshot);
  free(state->reason);
  free(state);
}

void anvil_ts_document_state_release(AnvilTSDocumentState *state) {
  if (!state) return;
  if (!service_ensure_initialized() || !service_lock()) return;
  state->refcount--;
  bool destroy = state->refcount == 0;
  service_unlock();
  if (destroy) state_destroy_unlocked(state);
}

const char *anvil_ts_document_state_language_id(const AnvilTSDocumentState *state) {
  return state && state->language ? state->language->id : NULL;
}

const char *anvil_ts_document_state_status_string(AnvilTSStateStatus status) {
  switch (status) {
    case ANVIL_TS_STATE_IDLE: return "idle";
    case ANVIL_TS_STATE_QUEUED: return "queued";
    case ANVIL_TS_STATE_PARSING: return "parsing";
    case ANVIL_TS_STATE_READY: return "ready";
    case ANVIL_TS_STATE_CANCELED: return "canceled";
    case ANVIL_TS_STATE_FAILED: return "failed";
    case ANVIL_TS_STATE_CLOSED: return "closed";
    default: return "unknown";
  }
}

AnvilTSStateStatus anvil_ts_document_state_status(const AnvilTSDocumentState *state) {
  if (!state || !service_ensure_initialized() || !service_lock()) return ANVIL_TS_STATE_FAILED;
  AnvilTSStateStatus status = state->status;
  service_unlock();
  return status;
}

bool anvil_ts_document_state_status_snapshot(
  const AnvilTSDocumentState *state,
  AnvilTSStateStatus *status,
  char **reason
) {
  if (reason) *reason = NULL;
  if (!state || !status || !service_ensure_initialized() || !service_lock()) return false;
  *status = state->status;
  if (reason && state->reason) {
    *reason = service_strdup(state->reason);
    if (!*reason) {
      service_unlock();
      return false;
    }
  }
  service_unlock();
  return true;
}

uint64_t anvil_ts_document_state_generation(const AnvilTSDocumentState *state) {
  if (!state || !service_ensure_initialized() || !service_lock()) return 0;
  uint64_t generation = state->generation;
  service_unlock();
  return generation;
}

uint64_t anvil_ts_document_state_tree_generation(const AnvilTSDocumentState *state) {
  if (!state || !service_ensure_initialized() || !service_lock()) return 0;
  uint64_t generation = state->tree_generation;
  service_unlock();
  return generation;
}

bool anvil_ts_document_state_has_tree(const AnvilTSDocumentState *state) {
  if (!state || !service_ensure_initialized() || !service_lock()) return false;
  bool has_tree = state->current_tree != NULL;
  service_unlock();
  return has_tree;
}

typedef struct AnvilTSQueryRun {
  uint64_t started_ticks;
  uint32_t timeout_ms;
  AnvilTSCancelCallback cancel_callback;
  void *cancel_payload;
  bool timed_out;
  bool cancelled;
} AnvilTSQueryRun;

static bool query_progress(TSQueryCursorState *cursor_state) {
  AnvilTSQueryRun *run = (AnvilTSQueryRun *) cursor_state->payload;
  if (!run) return false;
  if (run->cancel_callback && run->cancel_callback(run->cancel_payload)) {
    run->cancelled = true;
    return true;
  }
  if (run->timeout_ms > 0 && SDL_GetTicks() - run->started_ticks >= run->timeout_ms) {
    run->timed_out = true;
    return true;
  }
  return false;
}

static const char *query_string_value(const TSQuery *query, uint32_t id, uint32_t *len) {
  const char *value = ts_query_string_value_for_id(query, id, len);
  return value ? value : "";
}

static bool query_step_text_equals(const TSQuery *query, const TSQueryPredicateStep *step, const char *text) {
  if (!step || step->type != TSQueryPredicateStepTypeString || !text) return false;
  uint32_t len = 0;
  const char *value = query_string_value(query, step->value_id, &len);
  return strlen(text) == len && strncmp(value, text, len) == 0;
}

static const TSQueryCapture *match_capture_for_id(const TSQueryMatch *match, uint32_t capture_id) {
  for (uint16_t i = 0; i < match->capture_count; i++) {
    if (match->captures[i].index == capture_id) return &match->captures[i];
  }
  return NULL;
}

static bool capture_text_range(
  const AnvilTSSnapshot *snapshot,
  const TSQueryCapture *capture,
  uint32_t *start,
  uint32_t *end
) {
  if (!snapshot || !capture || !start || !end) return false;
  *start = ts_node_start_byte(capture->node);
  *end = ts_node_end_byte(capture->node);
  if (*end < *start || *end > snapshot->byte_len) return false;
  return true;
}

static bool predicate_arg_text(
  const TSQuery *query,
  const AnvilTSSnapshot *snapshot,
  const TSQueryMatch *match,
  const TSQueryPredicateStep *step,
  const char **text,
  uint32_t *len
) {
  if (!query || !snapshot || !match || !step || !text || !len) return false;
  if (step->type == TSQueryPredicateStepTypeString) {
    *text = query_string_value(query, step->value_id, len);
    return true;
  }
  if (step->type == TSQueryPredicateStepTypeCapture) {
    const TSQueryCapture *capture = match_capture_for_id(match, step->value_id);
    uint32_t start = 0, end = 0;
    if (!capture_text_range(snapshot, capture, &start, &end)) return false;
    *text = snapshot->bytes + start;
    *len = end - start;
    return true;
  }
  return false;
}

static bool text_equals(const char *a, uint32_t a_len, const char *b, uint32_t b_len) {
  return a_len == b_len && (a_len == 0 || strncmp(a, b, a_len) == 0);
}

static bool text_matches_regex(const char *text, uint32_t text_len, const char *pattern, uint32_t pattern_len, char **error) {
  int error_number = 0;
  PCRE2_SIZE error_offset = 0;
  pcre2_code *re = pcre2_compile(
    (PCRE2_SPTR) pattern,
    pattern_len,
    PCRE2_UTF,
    &error_number,
    &error_offset,
    NULL
  );
  if (!re) {
    service_set_error(error, "invalid Tree-sitter #match? predicate regex");
    return false;
  }
  pcre2_match_data *match_data = pcre2_match_data_create_from_pattern(re, NULL);
  if (!match_data) {
    pcre2_code_free(re);
    service_set_error(error, "out of memory evaluating Tree-sitter #match? predicate");
    return false;
  }
  int rc = pcre2_match(re, (PCRE2_SPTR) text, text_len, 0, 0, match_data, NULL);
  pcre2_match_data_free(match_data);
  pcre2_code_free(re);
  return rc >= 0;
}

static int32_t query_pattern_priority(const TSQuery *query, uint32_t pattern_index) {
  uint32_t step_count = 0;
  const TSQueryPredicateStep *steps = ts_query_predicates_for_pattern(query, pattern_index, &step_count);
  int32_t priority = 0;
  for (uint32_t i = 0; i < step_count;) {
    const TSQueryPredicateStep *op = &steps[i++];
    uint32_t arg_start = i;
    while (i < step_count && steps[i].type != TSQueryPredicateStepTypeDone) i++;
    uint32_t arg_end = i;
    if (i < step_count && steps[i].type == TSQueryPredicateStepTypeDone) i++;
    if (query_step_text_equals(query, op, "set!") && arg_end >= arg_start + 2 &&
        query_step_text_equals(query, &steps[arg_start], "priority") &&
        steps[arg_start + 1].type == TSQueryPredicateStepTypeString) {
      uint32_t len = 0;
      const char *value = query_string_value(query, steps[arg_start + 1].value_id, &len);
      char buffer[32];
      uint32_t copy_len = len < sizeof(buffer) - 1 ? len : (uint32_t) sizeof(buffer) - 1;
      memcpy(buffer, value, copy_len);
      buffer[copy_len] = '\0';
      priority = (int32_t) strtol(buffer, NULL, 10);
    }
  }
  return priority;
}

static bool query_match_predicates(
  const TSQuery *query,
  const AnvilTSSnapshot *snapshot,
  const TSQueryMatch *match,
  char **error
) {
  uint32_t step_count = 0;
  const TSQueryPredicateStep *steps = ts_query_predicates_for_pattern(query, match->pattern_index, &step_count);
  for (uint32_t i = 0; i < step_count;) {
    const TSQueryPredicateStep *op = &steps[i++];
    uint32_t arg_start = i;
    while (i < step_count && steps[i].type != TSQueryPredicateStepTypeDone) i++;
    uint32_t arg_end = i;
    if (i < step_count && steps[i].type == TSQueryPredicateStepTypeDone) i++;

    if (query_step_text_equals(query, op, "set!")) {
      continue;
    }

    bool negate = false;
    enum { PRED_UNKNOWN, PRED_EQ, PRED_MATCH, PRED_ANY_OF } kind = PRED_UNKNOWN;
    if (query_step_text_equals(query, op, "eq?")) kind = PRED_EQ;
    else if (query_step_text_equals(query, op, "not-eq?")) { kind = PRED_EQ; negate = true; }
    else if (query_step_text_equals(query, op, "match?")) kind = PRED_MATCH;
    else if (query_step_text_equals(query, op, "not-match?")) { kind = PRED_MATCH; negate = true; }
    else if (query_step_text_equals(query, op, "any-of?")) kind = PRED_ANY_OF;
    else if (query_step_text_equals(query, op, "not-any-of?")) { kind = PRED_ANY_OF; negate = true; }
    else {
      service_set_error(error, "unsupported Tree-sitter query predicate");
      return false;
    }

    bool result = false;
    if (kind == PRED_EQ) {
      if (arg_end < arg_start + 2) return false;
      const char *a = NULL, *b = NULL;
      uint32_t a_len = 0, b_len = 0;
      if (!predicate_arg_text(query, snapshot, match, &steps[arg_start], &a, &a_len) ||
          !predicate_arg_text(query, snapshot, match, &steps[arg_start + 1], &b, &b_len)) return false;
      result = text_equals(a, a_len, b, b_len);
    } else if (kind == PRED_MATCH) {
      if (arg_end < arg_start + 2) return false;
      const char *text = NULL, *pattern = NULL;
      uint32_t text_len = 0, pattern_len = 0;
      if (!predicate_arg_text(query, snapshot, match, &steps[arg_start], &text, &text_len) ||
          !predicate_arg_text(query, snapshot, match, &steps[arg_start + 1], &pattern, &pattern_len)) return false;
      result = text_matches_regex(text, text_len, pattern, pattern_len, error);
      if (error && *error) return false;
    } else if (kind == PRED_ANY_OF) {
      if (arg_end < arg_start + 2) return false;
      const char *text = NULL;
      uint32_t text_len = 0;
      if (!predicate_arg_text(query, snapshot, match, &steps[arg_start], &text, &text_len)) return false;
      for (uint32_t arg = arg_start + 1; arg < arg_end; arg++) {
        const char *candidate = NULL;
        uint32_t candidate_len = 0;
        if (!predicate_arg_text(query, snapshot, match, &steps[arg], &candidate, &candidate_len)) return false;
        if (text_equals(text, text_len, candidate, candidate_len)) {
          result = true;
          break;
        }
      }
    }
    if (negate) result = !result;
    if (!result) return false;
  }
  return true;
}

bool anvil_ts_query_captures_in_tree(
  TSTree *tree,
  const AnvilTSSnapshot *snapshot,
  const TSQuery *query,
  uint32_t byte_start,
  uint32_t byte_end,
  uint32_t match_limit,
  uint32_t max_captures,
  uint32_t timeout_ms,
  AnvilTSQueryCaptureCallback callback,
  void *payload,
  AnvilTSCancelCallback cancel_callback,
  void *cancel_payload,
  bool *exceeded_match_limit,
  char **error
) {
  if (error) *error = NULL;
  if (exceeded_match_limit) *exceeded_match_limit = false;
  if (!tree || !snapshot || !query || !callback) {
    service_set_error(error, "invalid Tree-sitter query request");
    return false;
  }

  if (byte_end > snapshot->byte_len) byte_end = snapshot->byte_len;
  if (byte_start > byte_end) byte_start = byte_end;
  TSNode root = ts_tree_root_node(tree);
  TSQueryCursor *cursor = ts_query_cursor_new();
  if (!cursor) {
    service_set_error(error, "failed to allocate Tree-sitter query cursor");
    return false;
  }
  if (match_limit > 0) ts_query_cursor_set_match_limit(cursor, match_limit);
  ts_query_cursor_set_byte_range(cursor, byte_start, byte_end);
  AnvilTSQueryRun run;
  memset(&run, 0, sizeof(run));
  run.started_ticks = SDL_GetTicks();
  run.timeout_ms = timeout_ms;
  run.cancel_callback = cancel_callback;
  run.cancel_payload = cancel_payload;
  TSQueryCursorOptions options;
  options.payload = &run;
  options.progress_callback = query_progress;
  ts_query_cursor_exec_with_options(cursor, query, root, &options);

  bool ok = true;
  uint32_t order = 0;
  TSQueryMatch match;
  char *predicate_error = NULL;
  while (ts_query_cursor_next_match(cursor, &match)) {
    if (!query_match_predicates(query, snapshot, &match, &predicate_error)) {
      if (predicate_error) {
        ok = false;
        break;
      }
      continue;
    }
    int32_t priority = query_pattern_priority(query, match.pattern_index);
    for (uint16_t i = 0; i < match.capture_count; i++) {
      const TSQueryCapture *capture = &match.captures[i];
      uint32_t start = ts_node_start_byte(capture->node);
      uint32_t end = ts_node_end_byte(capture->node);
      if (end <= byte_start || start >= byte_end || end <= start) continue;
      if (max_captures > 0 && order >= max_captures) {
        service_set_error(error, "Tree-sitter query capture limit exceeded");
        ok = false;
        goto done;
      }
      uint32_t name_len = 0;
      const char *name = ts_query_capture_name_for_id(query, capture->index, &name_len);
      AnvilTSQueryCapture out;
      out.name = name;
      out.name_len = name_len;
      out.start_byte = start;
      out.end_byte = end;
      out.start_point = ts_node_start_point(capture->node);
      out.end_point = ts_node_end_point(capture->node);
      out.priority = priority;
      out.match_id = match.id;
      out.pattern_index = match.pattern_index;
      out.capture_index = capture->index;
      out.order = order++;
      out.node_id = (uint64_t)(uintptr_t)capture->node.id;
      if (!callback(&out, payload)) {
        ok = false;
        goto done;
      }
    }
  }

done:
  if (predicate_error) {
    service_set_error(error, predicate_error);
    free(predicate_error);
  }
  if (run.cancelled && ok) {
    service_set_error(error, "Tree-sitter query cancelled");
    ok = false;
  } else if (run.timed_out && ok) {
    service_set_error(error, "Tree-sitter query timed out");
    ok = false;
  }
  if (exceeded_match_limit) *exceeded_match_limit = ts_query_cursor_did_exceed_match_limit(cursor);
  if (exceeded_match_limit && *exceeded_match_limit && ok) {
    service_set_error(error, "Tree-sitter query match limit exceeded");
    ok = false;
  }
  ts_query_cursor_delete(cursor);
  return ok;
}

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
) {
  if (error) *error = NULL;
  if (exceeded_match_limit) *exceeded_match_limit = false;
  if (!state || !query || !callback) {
    service_set_error(error, "invalid Tree-sitter query request");
    return false;
  }
  if (!service_ensure_initialized() || !service_lock()) {
    service_set_error(error, "failed to lock Tree-sitter service");
    return false;
  }
  if (!state->current_tree || !state->current_snapshot || state->closed) {
    service_unlock();
    service_set_error(error, "Tree-sitter tree is not ready");
    return false;
  }

  bool ok = anvil_ts_query_captures_in_tree(
    state->current_tree,
    state->current_snapshot,
    query,
    byte_start,
    byte_end,
    match_limit,
    max_captures,
    timeout_ms,
    callback,
    payload,
    NULL,
    NULL,
    exceeded_match_limit,
    error
  );
  service_unlock();
  return ok;
}

bool anvil_ts_document_state_node_ranges(
  AnvilTSDocumentState *state,
  uint32_t byte_start,
  uint32_t byte_end,
  bool named_only,
  uint32_t max_nodes,
  AnvilTSNodeRangeCallback callback,
  void *payload,
  char **error
) {
  if (error) *error = NULL;
  if (!state || !callback) {
    service_set_error(error, "invalid Tree-sitter node range request");
    return false;
  }
  if (!service_ensure_initialized() || !service_lock()) {
    service_set_error(error, "failed to lock Tree-sitter service");
    return false;
  }
  if (!state->current_tree || !state->current_snapshot || state->closed) {
    service_unlock();
    service_set_error(error, "Tree-sitter tree is not ready");
    return false;
  }

  const AnvilTSSnapshot *snapshot = state->current_snapshot;
  if (byte_end > snapshot->byte_len) byte_end = snapshot->byte_len;
  if (byte_start > byte_end) byte_start = byte_end;
  uint32_t query_end = byte_end;
  if (byte_end > byte_start) query_end = byte_end - 1;
  if (query_end > snapshot->byte_len) query_end = snapshot->byte_len;

  TSNode root = ts_tree_root_node(state->current_tree);
  TSNode node = named_only
    ? ts_node_named_descendant_for_byte_range(root, byte_start, query_end)
    : ts_node_descendant_for_byte_range(root, byte_start, query_end);
  uint32_t emitted = 0;
  while (!ts_node_is_null(node)) {
    if (!named_only || ts_node_is_named(node)) {
      const char *type = ts_node_type(node);
      AnvilTSNodeRange range;
      memset(&range, 0, sizeof(range));
      range.type = type;
      range.type_len = type ? (uint32_t) strlen(type) : 0;
      range.start_byte = ts_node_start_byte(node);
      range.end_byte = ts_node_end_byte(node);
      range.start_point = ts_node_start_point(node);
      range.end_point = ts_node_end_point(node);
      range.named = ts_node_is_named(node);
      if (!callback(&range, payload)) {
        service_unlock();
        return false;
      }
      emitted++;
      if (max_nodes > 0 && emitted >= max_nodes) break;
    }
    node = ts_node_parent(node);
  }
  service_unlock();
  return true;
}

static bool document_state_schedule_parse_internal(
  AnvilTSDocumentState *state,
  AnvilTSSnapshot *snapshot,
  uint64_t generation,
  const AnvilTSEdit *edit,
  char **error
) {
  if (error) *error = NULL;
  if (!state || !snapshot) {
    service_set_error(error, "invalid Tree-sitter parse request");
    return false;
  }
  if (!service_ensure_initialized() || !service_lock()) {
    service_set_error(error, "failed to initialize Tree-sitter service");
    return false;
  }
  if (state->closed) {
    service_unlock();
    service_set_error(error, "Tree-sitter document state is closed");
    return false;
  }
  if (!service_ensure_worker_locked()) {
    service_unlock();
    service_set_error(error, "failed to start Tree-sitter worker");
    return false;
  }

  if (state->active_job) SDL_SetAtomicInt(&state->active_job->cancel, 1);

  AnvilTSParseJob *job = (AnvilTSParseJob *) calloc(1, sizeof(*job));
  if (!job) {
    service_unlock();
    service_set_error(error, "out of memory allocating Tree-sitter parse job");
    return false;
  }
  job->id = service.next_job_id++;
  job->generation = generation;
  job->state = state;
  job->language = state->language;
  job->snapshot = snapshot;
  job->parse_timeout_ms = state->parse_timeout_ms;
  if (edit && state->current_tree) {
    ts_tree_edit(state->current_tree, &edit->input_edit);
    job->old_tree = ts_tree_copy(state->current_tree);
    if (!job->old_tree) {
      free(job);
      service_unlock();
      service_set_error(error, "failed to copy Tree-sitter tree for incremental parse");
      return false;
    }
    anvil_ts_snapshot_retain(snapshot);
    anvil_ts_snapshot_free(state->current_snapshot);
    state->current_snapshot = snapshot;
  }
  SDL_SetAtomicInt(&job->cancel, 0);
  state->refcount++;
  state->active_job = job;
  state->generation = generation;
  state->status = ANVIL_TS_STATE_QUEUED;
  state_set_reason_locked(state, NULL);
  enqueue_job_locked(job);
  service_unlock();
  return true;
}

bool anvil_ts_document_state_schedule_parse(
  AnvilTSDocumentState *state,
  AnvilTSSnapshot *snapshot,
  uint64_t generation,
  char **error
) {
  return document_state_schedule_parse_internal(state, snapshot, generation, NULL, error);
}

bool anvil_ts_document_state_schedule_parse_with_edit(
  AnvilTSDocumentState *state,
  AnvilTSSnapshot *snapshot,
  uint64_t generation,
  const AnvilTSEdit *edit,
  char **error
) {
  return document_state_schedule_parse_internal(state, snapshot, generation, edit, error);
}

static void job_detach_state_locked(AnvilTSParseJob *job) {
  if (!job || !job->state) return;
  if (job->state->active_job == job) job->state->active_job = NULL;
}

static void job_free(AnvilTSParseJob *job) {
  if (!job) return;
  if (job->old_tree) ts_tree_delete(job->old_tree);
  if (job->result_tree) ts_tree_delete(job->result_tree);
  anvil_ts_snapshot_free(job->snapshot);
  free(job->error);
  AnvilTSDocumentState *state = job->state;
  job->state = NULL;
  free(job);
  anvil_ts_document_state_release(state);
}

AnvilTSPollResult anvil_ts_document_state_poll(
  AnvilTSDocumentState *state,
  uint64_t current_generation
) {
  AnvilTSPollResult result;
  result.status = ANVIL_TS_STATE_FAILED;
  result.changed = false;
  result.discarded_stale = false;
  result.changed_ranges = NULL;
  result.changed_range_count = 0;
  result.changed_ranges_available = false;
  if (!state || !service_ensure_initialized() || !service_lock()) return result;

  AnvilTSParseJob *to_free = NULL;
  AnvilTSParseJob *prev = NULL;
  AnvilTSParseJob **link = &service.completed_head;
  while (*link) {
    AnvilTSParseJob *job = *link;
    if (job->state != state) {
      prev = job;
      link = &job->completed_next;
      continue;
    }

    *link = job->completed_next;
    if (service.completed_tail == job) service.completed_tail = prev;
    job->completed_next = to_free;
    to_free = job;

    bool is_active = state->active_job == job;
    bool is_current = is_active && job->generation == current_generation && !state->closed;
    if (!is_current) {
      result.discarded_stale = true;
      if (is_active) state->active_job = NULL;
      continue;
    }

    state->active_job = NULL;
    if (job->result_tree && !job->canceled && !job->failed) {
      if (state->current_tree) {
        result.changed_ranges_available = true;
        result.changed_ranges = ts_tree_get_changed_ranges(
          state->current_tree,
          job->result_tree,
          &result.changed_range_count
        );
        ts_tree_delete(state->current_tree);
      }
      anvil_ts_snapshot_free(state->current_snapshot);
      state->current_tree = job->result_tree;
      state->current_snapshot = job->snapshot;
      job->result_tree = NULL;
      job->snapshot = NULL;
      state->tree_generation = job->generation;
      state->generation = job->generation;
      state->status = ANVIL_TS_STATE_READY;
      state_set_reason_locked(state, NULL);
      result.changed = true;
    } else if (job->canceled) {
      state->status = ANVIL_TS_STATE_CANCELED;
      state_set_reason_locked(state, "canceled");
      result.changed = true;
    } else {
      state->status = ANVIL_TS_STATE_FAILED;
      state_set_reason_locked(state, job->error ? job->error : "parse failed");
      result.changed = true;
    }
  }
  if (!service.completed_head) service.completed_tail = NULL;
  result.status = state->status;
  service_unlock();

  while (to_free) {
    AnvilTSParseJob *next = to_free->completed_next;
    to_free->completed_next = NULL;
    job_free(to_free);
    to_free = next;
  }
  return result;
}

void anvil_ts_document_state_cancel(AnvilTSDocumentState *state) {
  if (!state || !service_ensure_initialized() || !service_lock()) return;
  if (state->active_job) SDL_SetAtomicInt(&state->active_job->cancel, 1);
  if (!state->closed) {
    state->status = ANVIL_TS_STATE_CANCELED;
    state_set_reason_locked(state, "canceled");
  }
  service_unlock();
}

void anvil_ts_document_state_close(AnvilTSDocumentState *state) {
  if (!state || !service_ensure_initialized() || !service_lock()) return;
  if (state->closed) {
    service_unlock();
    return;
  }
  state->closed = true;
  if (state->active_job) SDL_SetAtomicInt(&state->active_job->cancel, 1);
  if (state->current_tree) {
    ts_tree_delete(state->current_tree);
    state->current_tree = NULL;
  }
  anvil_ts_snapshot_free(state->current_snapshot);
  state->current_snapshot = NULL;
  state->status = ANVIL_TS_STATE_CLOSED;
  state_set_reason_locked(state, "closed");
  service_unlock();
}

bool anvil_ts_service_register_complete_event(void) {
  if (!service_ensure_initialized()) return false;
  if (!service_lock()) return false;
  bool already_registered = service.event_registered;
  service_unlock();
  if (!already_registered) {
    if (!register_custom_event(ANVIL_TS_COMPLETE_EVENT, anvil_ts_service_complete_event_callback)) {
      return false;
    }
    if (!service_lock()) return false;
    service.event_registered = true;
    if (!service.atexit_registered) {
      atexit(anvil_ts_service_shutdown);
      service.atexit_registered = true;
    }
    service_unlock();
  }
  return true;
}

void anvil_ts_service_ack_complete_event(void) {
  if (!service.initialized || !service_lock()) return;
  service.complete_event_pending = false;
  service_unlock();
}

int anvil_ts_service_complete_event_callback(lua_State *L, SDL_Event *event) {
  (void) event;
  lua_pushstring(L, ANVIL_TS_COMPLETE_EVENT);
  return 1;
}

void anvil_ts_service_shutdown(void) {
  if (!service.initialized) return;
  if (!service_lock()) return;
  service.shutdown = true;
  for (AnvilTSParseJob *job = service.queue_head; job; job = job->next) {
    SDL_SetAtomicInt(&job->cancel, 1);
  }
  for (AnvilTSParseJob *job = service.completed_head; job; job = job->completed_next) {
    SDL_SetAtomicInt(&job->cancel, 1);
  }
  for (int i = 0; i < ANVIL_TS_DOCUMENT_WORKER_COUNT; i++) {
    if (service.running_jobs[i]) SDL_SetAtomicInt(&service.running_jobs[i]->cancel, 1);
  }
  SDL_BroadcastCondition(service.cond);
  SDL_Thread *workers[ANVIL_TS_DOCUMENT_WORKER_COUNT];
  for (int i = 0; i < ANVIL_TS_DOCUMENT_WORKER_COUNT; i++) {
    workers[i] = service.workers[i];
    service.workers[i] = NULL;
  }
  service_unlock();

  for (int i = 0; i < ANVIL_TS_DOCUMENT_WORKER_COUNT; i++) {
    if (workers[i]) SDL_WaitThread(workers[i], NULL);
  }

  if (!service_lock()) return;
  AnvilTSParseJob *queued = service.queue_head;
  service.queue_head = NULL;
  service.queue_tail = NULL;
  for (AnvilTSParseJob *job = queued; job; job = job->next) {
    job_detach_state_locked(job);
  }
  AnvilTSParseJob *completed = service.completed_head;
  service.completed_head = NULL;
  service.completed_tail = NULL;
  for (AnvilTSParseJob *job = completed; job; job = job->completed_next) {
    job_detach_state_locked(job);
  }
  service_unlock();

  while (queued) {
    AnvilTSParseJob *next = queued->next;
    queued->next = NULL;
    job_free(queued);
    queued = next;
  }
  while (completed) {
    AnvilTSParseJob *next = completed->completed_next;
    completed->completed_next = NULL;
    job_free(completed);
    completed = next;
  }
}
