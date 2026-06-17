#include "service.h"

#include "../custom_events.h"

#include <SDL3/SDL.h>

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ANVIL_TS_COMPLETE_EVENT "treesitter_complete"

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
  bool failed;
  char *error;
};

typedef struct AnvilTSService {
  SDL_Mutex *mutex;
  SDL_Condition *cond;
  SDL_Thread *worker;
  bool initialized;
  bool shutdown;
  bool event_registered;
  bool atexit_registered;
  uint64_t next_state_id;
  uint64_t next_job_id;
  AnvilTSParseJob *queue_head;
  AnvilTSParseJob *queue_tail;
  AnvilTSParseJob *running_job;
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
  if (service.worker) return true;
  service.shutdown = false;
  service.worker = SDL_CreateThread(service_worker_main, "anvil-ts-parser", NULL);
  return service.worker != NULL;
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
    if (now - job->started_ticks >= job->parse_timeout_ms) return true;
  }
  return false;
}

static void push_complete_event_if_registered(void) {
  if (!service.event_registered) return;
  CustomEvent event;
  SDL_zero(event);
  push_custom_event(ANVIL_TS_COMPLETE_EVENT, &event);
}

static int service_worker_main(void *userdata) {
  (void) userdata;
  for (;;) {
    if (!service_lock()) return 1;
    while (!service.shutdown && service.queue_head == NULL) {
      SDL_WaitCondition(service.cond, service.mutex);
    }
    if (service.shutdown && service.queue_head == NULL) {
      service_unlock();
      break;
    }
    AnvilTSParseJob *job = dequeue_job_locked();
    service.running_job = job;
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
        if (!job->result_tree) {
          if (SDL_GetAtomicInt(&job->cancel)) {
            job->canceled = true;
          } else {
            job->failed = true;
            job->error = service_strdup("Tree-sitter parse canceled by timeout or returned no tree");
          }
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
    service.running_job = NULL;
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
      if (state->current_tree) ts_tree_delete(state->current_tree);
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
  if (service.running_job) SDL_SetAtomicInt(&service.running_job->cancel, 1);
  SDL_BroadcastCondition(service.cond);
  SDL_Thread *worker = service.worker;
  service.worker = NULL;
  service_unlock();

  if (worker) SDL_WaitThread(worker, NULL);

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
