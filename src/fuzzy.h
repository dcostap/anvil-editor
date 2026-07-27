#ifndef ANVIL_FUZZY_H
#define ANVIL_FUZZY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
  FUZZY_MODE_GENERIC = 0,
  FUZZY_MODE_PATH = 1,
} FuzzyMode;

typedef enum {
  FUZZY_MATCH_NONE = 0,
  FUZZY_MATCH_LOOSE = 1,
  FUZZY_MATCH_COMPACT = 2,
  FUZZY_MATCH_CONTIGUOUS = 3,
} FuzzyMatchClass;

typedef struct {
  uint32_t text_offset;
  uint32_t lower_offset;
  uint32_t match_offset;
  uint32_t len;
  uint32_t source_index;    /* 1-based source item index */
  uint32_t basename_start;  /* 0-based byte offset */
  uint32_t extension_start; /* UINT32_MAX when absent */
} FuzzyEntry;

typedef struct {
  FuzzyEntry *entries;
  char *text_arena;
  char *match_arena;
  char *lower_arena;
  uint32_t count;
  uint32_t text_arena_len;
  uint32_t match_arena_len;
  uint32_t lower_arena_len;
  FuzzyMode mode;
  uint64_t generation;
} FuzzyIndex;

typedef struct {
  uint32_t entry_index;  /* 0-based FuzzyIndex entry index */
  uint32_t source_index; /* 1-based source item index */
  int score;
} FuzzySearchResult;

typedef struct {
  uint32_t start; /* 1-based inclusive */
  uint32_t end;   /* 1-based inclusive */
} FuzzySpan;

/* A normalized view of one string used for direct, non-indexed matching. */
typedef struct {
  char *match;
  char *lower;
  uint32_t len;
} FuzzyMatchBuffer;

FuzzyMode fuzzy_mode_from_string(const char *mode);
const char *fuzzy_mode_name(FuzzyMode mode);

bool fuzzy_match_buffer_build(FuzzyMatchBuffer *buffer, FuzzyMode mode, const char *text, uint32_t text_len);
void fuzzy_match_buffer_free(FuzzyMatchBuffer *buffer);
int fuzzy_match_buffer_score(FuzzyMode mode, const FuzzyMatchBuffer *buffer, const char *query);
uint32_t fuzzy_match_buffer_spans(FuzzyMode mode, const char *original, uint32_t original_len, const FuzzyMatchBuffer *buffer, const char *query, FuzzySpan *spans, uint32_t max_spans);

bool fuzzy_index_build(FuzzyIndex *idx, const char **items, uint32_t count, FuzzyMode mode);
void fuzzy_index_free(FuzzyIndex *idx);

FuzzySearchResult *fuzzy_index_search(const FuzzyIndex *idx, const char *query, uint32_t limit, uint32_t *out_count, bool *out_has_more);
const char *fuzzy_index_text(const FuzzyIndex *idx, uint32_t entry_index);

int fuzzy_match_score(FuzzyMode mode, const char *text, const char *lower, uint32_t len, uint32_t basename_start, const char *query);
FuzzyMatchClass fuzzy_match_text_class(FuzzyMode mode, const char *lower, uint32_t len, const char *query);
const char *fuzzy_match_class_name(FuzzyMatchClass match_class);
uint32_t fuzzy_match_text_spans(FuzzyMode mode, const char *lower, uint32_t len, const char *query, FuzzySpan *spans, uint32_t max_spans);
uint32_t fuzzy_match_spans(const FuzzyIndex *idx, uint32_t entry_index, const char *query, FuzzySpan *spans, uint32_t max_spans);

#endif
