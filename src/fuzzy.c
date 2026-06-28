#include "fuzzy.h"

#include <ctype.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

#define FUZZY_SCORE_NO_MATCH INT_MIN
#define FUZZY_MAX_QUERY_WORDS 32
#define FUZZY_MAX_WORD_LEN 128

typedef struct {
  char text[FUZZY_MAX_WORD_LEN];
  uint32_t len;
} FuzzyWord;

static char lower_ascii_char(char c) {
  unsigned char uc = (unsigned char)c;
  return (char)tolower(uc);
}

static bool is_boundary_char(char c) {
  return c == '/' || c == '\\' || c == '_' || c == '-' || c == '.' || c == ' ' || c == ':';
}

static bool is_boundary_at(const char *text, uint32_t pos) {
  if (pos == 0) return true;
  char prev = text[pos - 1];
  char cur = text[pos];
  if (is_boundary_char(prev)) return true;
  return prev >= 'a' && prev <= 'z' && cur >= 'A' && cur <= 'Z';
}

static uint32_t basename_start_of(const char *text, uint32_t len) {
  for (uint32_t i = len; i > 0; --i) {
    char c = text[i - 1];
    if (c == '/' || c == '\\') return i;
  }
  return 0;
}

static uint32_t extension_start_of(const char *text, uint32_t len, uint32_t basename_start) {
  for (uint32_t i = len; i > basename_start; --i) {
    if (text[i - 1] == '.') return i - 1;
  }
  return UINT32_MAX;
}

FuzzyMode fuzzy_mode_from_string(const char *mode) {
  if (mode && strcmp(mode, "path") == 0) return FUZZY_MODE_PATH;
  return FUZZY_MODE_GENERIC;
}

const char *fuzzy_mode_name(FuzzyMode mode) {
  return mode == FUZZY_MODE_PATH ? "path" : "generic";
}

static uint32_t parse_query_words(const char *query, FuzzyWord words[FUZZY_MAX_QUERY_WORDS]) {
  uint32_t count = 0;
  const char *p = query ? query : "";
  while (*p && count < FUZZY_MAX_QUERY_WORDS) {
    while (*p && isspace((unsigned char)*p)) p++;
    if (!*p) break;
    uint32_t len = 0;
    while (*p && !isspace((unsigned char)*p)) {
      if (len + 1 < FUZZY_MAX_WORD_LEN) words[count].text[len++] = lower_ascii_char(*p);
      p++;
    }
    if (len > 0) {
      words[count].text[len] = '\0';
      words[count].len = len;
      count++;
    }
  }
  return count;
}

bool fuzzy_index_build(FuzzyIndex *idx, const char **items, uint32_t count, FuzzyMode mode) {
  if (!idx) return false;
  memset(idx, 0, sizeof(*idx));
  idx->mode = mode;

  size_t arena_len = 0;
  for (uint32_t i = 0; i < count; ++i) {
    const char *s = items[i] ? items[i] : "";
    arena_len += strlen(s) + 1;
    if (arena_len > UINT32_MAX) return false;
  }

  idx->entries = count ? (FuzzyEntry *)calloc(count, sizeof(FuzzyEntry)) : NULL;
  idx->text_arena = arena_len ? (char *)malloc(arena_len) : NULL;
  idx->lower_arena = arena_len ? (char *)malloc(arena_len) : NULL;
  if ((count && !idx->entries) || (arena_len && (!idx->text_arena || !idx->lower_arena))) {
    fuzzy_index_free(idx);
    return false;
  }

  uint32_t offset = 0;
  for (uint32_t i = 0; i < count; ++i) {
    const char *s = items[i] ? items[i] : "";
    size_t len_sz = strlen(s);
    if (len_sz > UINT32_MAX) { fuzzy_index_free(idx); return false; }
    uint32_t len = (uint32_t)len_sz;

    memcpy(idx->text_arena + offset, s, len + 1);
    for (uint32_t j = 0; j < len; ++j) idx->lower_arena[offset + j] = lower_ascii_char(s[j]);
    idx->lower_arena[offset + len] = '\0';

    FuzzyEntry *e = &idx->entries[i];
    e->text_offset = offset;
    e->lower_offset = offset;
    e->len = len;
    e->source_index = i + 1;
    e->basename_start = basename_start_of(s, len);
    e->extension_start = extension_start_of(s, len, e->basename_start);

    offset += len + 1;
  }

  idx->count = count;
  idx->text_arena_len = offset;
  idx->lower_arena_len = offset;
  idx->generation++;
  return true;
}

void fuzzy_index_free(FuzzyIndex *idx) {
  if (!idx) return;
  free(idx->entries);
  free(idx->text_arena);
  free(idx->lower_arena);
  memset(idx, 0, sizeof(*idx));
}

const char *fuzzy_index_text(const FuzzyIndex *idx, uint32_t entry_index) {
  if (!idx || entry_index >= idx->count) return "";
  return idx->text_arena + idx->entries[entry_index].text_offset;
}

static const char *find_substr(const char *haystack, uint32_t haystack_len, const char *needle, uint32_t needle_len) {
  if (needle_len == 0) return haystack;
  if (needle_len > haystack_len) return NULL;
  char first = needle[0];
  uint32_t max = haystack_len - needle_len;
  for (uint32_t i = 0; i <= max; ++i) {
    if (haystack[i] == first && memcmp(haystack + i, needle, needle_len) == 0) return haystack + i;
  }
  return NULL;
}

static bool fuzzy_subsequence_too_weak(uint32_t word_len, uint32_t span, uint32_t max_gap, uint32_t longest_run) {
  if (word_len < 4) return false;

  /* Loose two- and three-letter acronym matches are useful, but longer query
     words should have either a compact span or a strong contiguous run.  This
     rejects coincidence matches like "caret" -> "core:add-directory-picker"
     while preserving split-prefix plus long-tail matches such as
     "cinematic" -> "c_foo_inematic". */
  uint32_t strong_run = (word_len + 1) / 2;
  if (longest_run >= strong_run) return false;

  if (span > word_len * 2 + 4) return true;
  uint32_t max_reasonable_gap = word_len * 2;
  if (max_reasonable_gap < 10) max_reasonable_gap = 10;
  if (max_gap > max_reasonable_gap) return true;
  return false;
}

static int score_word(FuzzyMode mode, const char *text, const char *lower, uint32_t len, uint32_t basename_start, const FuzzyWord *word) {
  if (word->len == 0) return 0;
  if (word->len > len) return FUZZY_SCORE_NO_MATCH;

  const char *exact = find_substr(lower, len, word->text, word->len);
  if (exact) {
    uint32_t pos = (uint32_t)(exact - lower);
    /* A contiguous substring match is qualitatively better than a loose
       subsequence match. Keep this base comfortably above any per-character
       subsequence bonuses so adding the final query character cannot make
       split matches jump above exact basename matches. */
    int score = 10000 + (int)word->len * 220;
    score -= (int)pos;
    if (is_boundary_at(text, pos)) score += 300;
    if (mode == FUZZY_MODE_PATH && pos >= basename_start) score += 700;
    if (mode == FUZZY_MODE_PATH && pos == basename_start) score += 700;
    if (pos == 0) score += 300;
    return score;
  }

  uint32_t scan = 0, first = UINT32_MAX, last = 0, prev = UINT32_MAX;
  uint32_t max_gap = 0, current_run = 0, longest_run = 0;
  int score = 0;
  for (uint32_t i = 0; i < word->len; ++i) {
    char ch = word->text[i];
    while (scan < len && lower[scan] != ch) scan++;
    if (scan >= len) return FUZZY_SCORE_NO_MATCH;
    if (first == UINT32_MAX) first = scan;
    last = scan;

    bool consecutive = prev != UINT32_MAX && scan == prev + 1;
    if (consecutive) {
      current_run++;
    } else {
      current_run = 1;
      if (prev != UINT32_MAX) {
        uint32_t gap = scan - prev - 1;
        if (gap > max_gap) max_gap = gap;
      }
    }
    if (current_run > longest_run) longest_run = current_run;

    score += 100;
    if (is_boundary_at(text, scan)) score += 70;
    if (consecutive) score += 90;
    if (mode == FUZZY_MODE_PATH && scan >= basename_start) score += 24;
    prev = scan;
    scan++;
  }

  uint32_t span = last - first + 1;
  uint32_t gaps = span - word->len;
  bool weak_long_match = false;
  if (fuzzy_subsequence_too_weak(word->len, span, max_gap, longest_run)) weak_long_match = true;
  if (word->len >= 4 && (span > word->len * 3 + 4 || max_gap > 12)) weak_long_match = true;
  if (word->len >= 6 && longest_run < 3 && gaps > word->len) weak_long_match = true;
  if (word->len >= 8 && longest_run < 4 && span > word->len * 2 + 4) weak_long_match = true;
  if (weak_long_match) return FUZZY_SCORE_NO_MATCH;

  if (mode == FUZZY_MODE_PATH && first >= basename_start) score += 160;
  score -= (int)first;
  score -= (int)(gaps / 2);
  return score;
}

int fuzzy_match_score(FuzzyMode mode, const char *text, const char *lower, uint32_t len, uint32_t basename_start, const char *query) {
  FuzzyWord words[FUZZY_MAX_QUERY_WORDS];
  uint32_t word_count = parse_query_words(query, words);
  if (word_count == 0) return 0 - (int)(len / 8);

  int total = 0;
  for (uint32_t i = 0; i < word_count; ++i) {
    int score = score_word(mode, text, lower, len, basename_start, &words[i]);
    if (score == FUZZY_SCORE_NO_MATCH) return FUZZY_SCORE_NO_MATCH;
    total += score;
  }
  total -= (int)(len / 8);
  return total;
}

static int result_better(const FuzzyIndex *idx, const FuzzySearchResult *a, const FuzzySearchResult *b) {
  if (a->score != b->score) return a->score > b->score;
  const char *at = fuzzy_index_text(idx, a->entry_index);
  const char *bt = fuzzy_index_text(idx, b->entry_index);
  return strcmp(at, bt) < 0;
}

static void insert_top(const FuzzyIndex *idx, FuzzySearchResult *top, uint32_t *top_count, uint32_t limit, FuzzySearchResult candidate) {
  if (limit == 0) return;
  if (*top_count >= limit && !result_better(idx, &candidate, &top[*top_count - 1])) return;

  uint32_t pos = *top_count;
  if (*top_count < limit) (*top_count)++;
  else pos = limit - 1;

  while (pos > 0 && result_better(idx, &candidate, &top[pos - 1])) {
    top[pos] = top[pos - 1];
    pos--;
  }
  top[pos] = candidate;
}

FuzzySearchResult *fuzzy_index_search(const FuzzyIndex *idx, const char *query, uint32_t limit, uint32_t *out_count, bool *out_has_more) {
  if (out_count) *out_count = 0;
  if (out_has_more) *out_has_more = false;
  if (!idx || limit == 0) return NULL;

  uint32_t keep = limit + 1;
  if (keep < limit) keep = limit;
  FuzzySearchResult *top = (FuzzySearchResult *)malloc(sizeof(FuzzySearchResult) * keep);
  if (!top) return NULL;

  uint32_t top_count = 0;
  for (uint32_t i = 0; i < idx->count; ++i) {
    const FuzzyEntry *e = &idx->entries[i];
    const char *text = idx->text_arena + e->text_offset;
    const char *lower = idx->lower_arena + e->lower_offset;
    int score = fuzzy_match_score(idx->mode, text, lower, e->len, e->basename_start, query);
    if (score == FUZZY_SCORE_NO_MATCH) continue;
    FuzzySearchResult r = { i, e->source_index, score };
    insert_top(idx, top, &top_count, keep, r);
  }

  if (out_has_more && top_count > limit) *out_has_more = true;
  if (top_count > limit) top_count = limit;
  if (out_count) *out_count = top_count;
  return top;
}

static void append_span(FuzzySpan *spans, uint32_t max_spans, uint32_t *count, uint32_t s, uint32_t e) {
  if (*count > 0 && spans[*count - 1].end + 1 == s) {
    spans[*count - 1].end = e;
    return;
  }
  if (*count < max_spans) {
    spans[*count].start = s;
    spans[*count].end = e;
    (*count)++;
  }
}

uint32_t fuzzy_match_text_spans(const char *lower, uint32_t len, const char *query, FuzzySpan *spans, uint32_t max_spans) {
  if (!lower || !spans || max_spans == 0) return 0;
  FuzzyWord words[FUZZY_MAX_QUERY_WORDS];
  uint32_t word_count = parse_query_words(query, words);
  uint32_t count = 0;

  for (uint32_t w = 0; w < word_count; ++w) {
    const FuzzyWord *word = &words[w];
    const char *exact = find_substr(lower, len, word->text, word->len);
    if (exact) {
      uint32_t pos = (uint32_t)(exact - lower) + 1;
      append_span(spans, max_spans, &count, pos, pos + word->len - 1);
      continue;
    }
    uint32_t scan = 0;
    for (uint32_t i = 0; i < word->len; ++i) {
      char ch = word->text[i];
      while (scan < len && lower[scan] != ch) scan++;
      if (scan >= len) break;
      append_span(spans, max_spans, &count, scan + 1, scan + 1);
      scan++;
    }
  }

  return count;
}

uint32_t fuzzy_match_spans(const FuzzyIndex *idx, uint32_t entry_index, const char *query, FuzzySpan *spans, uint32_t max_spans) {
  if (!idx || entry_index >= idx->count) return 0;
  const FuzzyEntry *e = &idx->entries[entry_index];
  const char *lower = idx->lower_arena + e->lower_offset;
  return fuzzy_match_text_spans(lower, e->len, query, spans, max_spans);
}
