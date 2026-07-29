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

typedef struct {
  const char *relative_prefix;
  const char *label;
  const char *role;
  const char *id;
  int32_t rank_penalty;
} FuzzyFilePathMappingSpec;

typedef struct {
  const char *path;
  const char *label;
  const char *role;
  const char *id;
  int32_t rank_penalty;
  const FuzzyFilePathMappingSpec *mappings;
  uint32_t mapping_count;
} FuzzyFileRootSpec;

typedef struct FuzzyFileIndexBuilder FuzzyFileIndexBuilder;
typedef struct FuzzyFileIndex FuzzyFileIndex;

typedef struct {
  uint32_t candidates;
  uint32_t accepted;
  uint32_t duplicates;
  uint64_t input_bytes;
} FuzzyFileIndexStats;

typedef struct {
  const char *display_path;
  const char *relative_path;
  const char *root_path;
  const char *root_label;
  const char *role;
  const char *root_id;
  int32_t rank_penalty;
  uint32_t root_index;
} FuzzyFileEntryView;

FuzzyMode fuzzy_mode_from_string(const char *mode);
const char *fuzzy_mode_name(FuzzyMode mode);

bool fuzzy_match_buffer_build(FuzzyMatchBuffer *buffer, FuzzyMode mode, const char *text, uint32_t text_len);
void fuzzy_match_buffer_free(FuzzyMatchBuffer *buffer);
int fuzzy_match_buffer_score(FuzzyMode mode, const FuzzyMatchBuffer *buffer, const char *query);
uint32_t fuzzy_match_buffer_spans(FuzzyMode mode, const char *original, uint32_t original_len, const FuzzyMatchBuffer *buffer, const char *query, FuzzySpan *spans, uint32_t max_spans);

bool fuzzy_index_build(FuzzyIndex *idx, const char **items, uint32_t count, FuzzyMode mode);
void fuzzy_index_free(FuzzyIndex *idx);

FuzzyFileIndexBuilder *fuzzy_file_index_builder_create(
  const FuzzyFileRootSpec *roots,
  uint32_t root_count
);
void fuzzy_file_index_builder_free(FuzzyFileIndexBuilder *builder);
bool fuzzy_file_index_builder_feed(
  FuzzyFileIndexBuilder *builder,
  uint32_t root_index,
  const char *data,
  size_t len
);
FuzzyFileIndex *fuzzy_file_index_builder_finish(
  FuzzyFileIndexBuilder *builder,
  FuzzyFileIndexStats *stats
);
void fuzzy_file_index_free(FuzzyFileIndex *index);
uint32_t fuzzy_file_index_count(const FuzzyFileIndex *index);
bool fuzzy_file_index_entry_at(
  const FuzzyFileIndex *index,
  uint32_t index_number,
  FuzzyFileEntryView *view
);
FuzzySearchResult *fuzzy_file_index_search(
  const FuzzyFileIndex *index,
  const char *query,
  uint32_t limit,
  uint32_t *out_count,
  bool *out_has_more
);
uint32_t fuzzy_file_index_match_spans(
  const FuzzyFileIndex *index,
  uint32_t fuzzy_entry_index,
  const char *query,
  FuzzySpan *spans,
  uint32_t max_spans
);

FuzzySearchResult *fuzzy_index_search(const FuzzyIndex *idx, const char *query, uint32_t limit, uint32_t *out_count, bool *out_has_more);
const char *fuzzy_index_text(const FuzzyIndex *idx, uint32_t entry_index);

int fuzzy_match_score(FuzzyMode mode, const char *text, const char *lower, uint32_t len, uint32_t basename_start, const char *query);
FuzzyMatchClass fuzzy_match_text_class(FuzzyMode mode, const char *lower, uint32_t len, const char *query);
const char *fuzzy_match_class_name(FuzzyMatchClass match_class);
uint32_t fuzzy_match_text_spans(FuzzyMode mode, const char *lower, uint32_t len, const char *query, FuzzySpan *spans, uint32_t max_spans);
uint32_t fuzzy_match_spans(const FuzzyIndex *idx, uint32_t entry_index, const char *query, FuzzySpan *spans, uint32_t max_spans);

#endif
