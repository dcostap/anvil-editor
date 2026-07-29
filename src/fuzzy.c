#include "fuzzy.h"
#if defined(__GNUC__)
# pragma GCC diagnostic push
# pragma GCC diagnostic ignored "-Wunused-variable"
#endif
#include "unidata.h"
#if defined(__GNUC__)
# pragma GCC diagnostic pop
#endif

#include <ctype.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

#define FUZZY_SCORE_NO_MATCH INT_MIN
#define FUZZY_MAX_QUERY_WORDS 32
#define FUZZY_MAX_WORD_LEN 128
#define FUZZY_MAX_RETURN_SPANS 256

typedef struct {
  char text[FUZZY_MAX_WORD_LEN];
  uint32_t len;
} FuzzyWord;

static char lower_ascii_char(char c) {
  unsigned char uc = (unsigned char)c;
  return (char)(uc >= 'A' && uc <= 'Z' ? uc + ('a' - 'A') : uc);
}

static const char *decode_utf8(const char *s, const char *end, uint32_t *out) {
  unsigned char c = (unsigned char)*s;
  uint32_t value;
  uint32_t needed;
  if (c < 0x80) {
    *out = c;
    return s + 1;
  }
  if (c >= 0xC2 && c <= 0xDF) { value = c & 0x1F; needed = 1; }
  else if (c >= 0xE0 && c <= 0xEF) { value = c & 0x0F; needed = 2; }
  else if (c >= 0xF0 && c <= 0xF4) { value = c & 0x07; needed = 3; }
  else return NULL;
  if ((size_t)(end - s) <= needed) return NULL;
  for (uint32_t i = 1; i <= needed; ++i) {
    unsigned char continuation = (unsigned char)s[i];
    if ((continuation & 0xC0) != 0x80) return NULL;
    value = (value << 6) | (continuation & 0x3F);
  }
  if ((needed == 2 && value < 0x800) ||
      (needed == 3 && value < 0x10000) ||
      (value > 0x10FFFF) || (value >= 0xD800 && value <= 0xDFFF)) return NULL;
  *out = value;
  return s + needed + 1;
}

static uint32_t encode_utf8(uint32_t cp, char out[4]) {
  if (cp < 0x80) { out[0] = (char)cp; return 1; }
  if (cp < 0x800) {
    out[0] = (char)(0xC0 | (cp >> 6));
    out[1] = (char)(0x80 | (cp & 0x3F));
    return 2;
  }
  if (cp < 0x10000) {
    out[0] = (char)(0xE0 | (cp >> 12));
    out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
    out[2] = (char)(0x80 | (cp & 0x3F));
    return 3;
  }
  out[0] = (char)(0xF0 | (cp >> 18));
  out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
  out[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
  out[3] = (char)(0x80 | (cp & 0x3F));
  return 4;
}

static const decompose_table *decompose_codepoint(uint32_t cp) {
  size_t begin = 0, end = sizeof(nfc_decompose_table) / sizeof(nfc_decompose_table[0]);
  while (begin < end) {
    size_t mid = (begin + end) / 2;
    if (nfc_decompose_table[mid].cp < cp) begin = mid + 1;
    else if (nfc_decompose_table[mid].cp > cp) end = mid;
    else return &nfc_decompose_table[mid];
  }
  return NULL;
}

static bool is_combining_codepoint(uint32_t cp) {
  size_t begin = 0, end = sizeof(nfc_combining_table) / sizeof(nfc_combining_table[0]);
  while (begin < end) {
    size_t mid = (begin + end) / 2;
    if (nfc_combining_table[mid].last < cp) begin = mid + 1;
    else if (nfc_combining_table[mid].first > cp) end = mid;
    else return nfc_combining_table[mid].canon_cls != 0;
  }
  return false;
}

static uint32_t fold_codepoint(uint32_t cp, uint32_t out[8], uint32_t count) {
  if (is_combining_codepoint(cp)) return count;
  const decompose_table *decomposition = decompose_codepoint(cp);
  if (decomposition) {
    count = fold_codepoint(decomposition->to1, out, count);
    count = fold_codepoint(decomposition->to2, out, count);
    return count;
  }
  if (count < 8) out[count++] = cp;
  return count;
}

static uint32_t append_normalized_codepoint(
  FuzzyMode mode,
  uint32_t cp,
  char *match,
  char *lower,
  uint32_t offset
) {
  uint32_t folded[8];
  uint32_t count = fold_codepoint(cp, folded, 0);
  for (uint32_t i = 0; i < count; ++i) {
    uint32_t match_cp = folded[i];
    uint32_t lower_cp = match_cp;
    if (lower_cp >= 'A' && lower_cp <= 'Z') lower_cp += 'a' - 'A';
    if (mode == FUZZY_MODE_PATH && (match_cp == '/' || match_cp == '\\')) match_cp = '/';
    if (mode == FUZZY_MODE_PATH && (lower_cp == '/' || lower_cp == '\\')) lower_cp = '/';
    char encoded[4], lower_encoded[4];
    uint32_t encoded_len = encode_utf8(match_cp, encoded);
    uint32_t lower_encoded_len = encode_utf8(lower_cp, lower_encoded);
    if (lower_encoded_len != encoded_len) return offset;
    for (uint32_t j = 0; j < encoded_len; ++j) {
      match[offset] = encoded[j];
      lower[offset] = lower_encoded[j];
      offset++;
    }
  }
  return offset;
}

static uint32_t append_query_codepoint(FuzzyMode mode, uint32_t cp, char *out, uint32_t offset) {
  uint32_t folded[8];
  uint32_t count = fold_codepoint(cp, folded, 0);
  for (uint32_t i = 0; i < count; ++i) {
    uint32_t folded_cp = folded[i];
    if (mode == FUZZY_MODE_PATH && (folded_cp == '/' || folded_cp == '\\')) folded_cp = '/';
    char encoded[4];
    uint32_t encoded_len = encode_utf8(folded_cp, encoded);
    for (uint32_t j = 0; j < encoded_len && offset + 1 < FUZZY_MAX_WORD_LEN; ++j) {
      out[offset++] = lower_ascii_char(encoded[j]);
    }
  }
  return offset;
}

static bool normalized_length(const char *text, uint32_t text_len, uint32_t *out_len) {
  const char *p = text;
  const char *end = text + text_len;
  uint64_t length = 0;
  while (p < end) {
    uint32_t cp = 0;
    const char *next = decode_utf8(p, end, &cp);
    if (!next) {
      next = p + 1;
      cp = (unsigned char)*p;
    }
    uint32_t folded[8];
    uint32_t count = fold_codepoint(cp, folded, 0);
    for (uint32_t i = 0; i < count; ++i) {
      char encoded[4];
      length += encode_utf8(folded[i], encoded);
      if (length > UINT32_MAX) return false;
    }
    p = next;
  }
  *out_len = (uint32_t)length;
  return true;
}

static uint32_t normalize_into(
  FuzzyMode mode,
  const char *text,
  uint32_t text_len,
  char *match,
  char *lower
) {
  const char *p = text;
  const char *end = text + text_len;
  uint32_t offset = 0;
  while (p < end) {
    uint32_t cp = 0;
    const char *next = decode_utf8(p, end, &cp);
    if (!next) {
      next = p + 1;
      cp = (unsigned char)*p;
    }
    offset = append_normalized_codepoint(mode, cp, match, lower, offset);
    p = next;
  }
  match[offset] = '\0';
  lower[offset] = '\0';
  return offset;
}

bool fuzzy_match_buffer_build(FuzzyMatchBuffer *buffer, FuzzyMode mode, const char *text, uint32_t text_len) {
  if (!buffer) return false;
  memset(buffer, 0, sizeof(*buffer));
  text = text ? text : "";
  uint32_t normalized_len = 0;
  if (!normalized_length(text, text_len, &normalized_len)) return false;
  size_t capacity = (size_t)normalized_len + 1;
  if (capacity > SIZE_MAX / 2) return false;
  buffer->match = (char *)malloc(capacity * 2);
  if (!buffer->match) {
    fuzzy_match_buffer_free(buffer);
    return false;
  }
  buffer->lower = buffer->match + capacity;
  buffer->len = normalize_into(mode, text, text_len, buffer->match, buffer->lower);
  return true;
}

void fuzzy_match_buffer_free(FuzzyMatchBuffer *buffer) {
  if (!buffer) return;
  free(buffer->match);
  memset(buffer, 0, sizeof(*buffer));
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

static uint32_t parse_query_words(FuzzyMode mode, const char *query, FuzzyWord words[FUZZY_MAX_QUERY_WORDS]) {
  uint32_t count = 0;
  const char *p = query ? query : "";
  const char *end = p + strlen(p);
  while (*p && count < FUZZY_MAX_QUERY_WORDS) {
    while (*p && isspace((unsigned char)*p)) p++;
    if (!*p) break;
    uint32_t len = 0;
    while (*p && !isspace((unsigned char)*p)) {
      uint32_t cp = 0;
      const char *next = decode_utf8(p, end, &cp);
      if (!next) { cp = (unsigned char)*p; next = p + 1; }
      len = append_query_codepoint(mode, cp, words[count].text, len);
      p = next;
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

  size_t text_arena_len = 0;
  size_t match_arena_len = 0;
  for (uint32_t i = 0; i < count; ++i) {
    const char *s = items[i] ? items[i] : "";
    size_t len = strlen(s);
    if (len > UINT32_MAX) return false;
    uint32_t normalized_len = 0;
    if (!normalized_length(s, (uint32_t)len, &normalized_len)) return false;
    text_arena_len += len + 1;
    match_arena_len += (size_t)normalized_len + 1;
    if (text_arena_len > UINT32_MAX || match_arena_len > UINT32_MAX) return false;
  }
  idx->entries = count ? (FuzzyEntry *)calloc(count, sizeof(FuzzyEntry)) : NULL;
  idx->text_arena = text_arena_len ? (char *)malloc(text_arena_len) : NULL;
  idx->match_arena = match_arena_len ? (char *)malloc(match_arena_len) : NULL;
  idx->lower_arena = match_arena_len ? (char *)malloc(match_arena_len) : NULL;
  if ((count && !idx->entries) || (text_arena_len && !idx->text_arena) ||
      (match_arena_len && (!idx->match_arena || !idx->lower_arena))) {
    fuzzy_index_free(idx);
    return false;
  }

  uint32_t text_offset = 0, match_offset = 0;
  for (uint32_t i = 0; i < count; ++i) {
    const char *s = items[i] ? items[i] : "";
    size_t len_sz = strlen(s);
    if (len_sz > UINT32_MAX) { fuzzy_index_free(idx); return false; }
    uint32_t len = (uint32_t)len_sz;

    memcpy(idx->text_arena + text_offset, s, len + 1);
    uint32_t normalized_len = normalize_into(mode, s, len,
      idx->match_arena + match_offset,
      idx->lower_arena + match_offset);

    FuzzyEntry *e = &idx->entries[i];
    e->text_offset = text_offset;
    e->lower_offset = match_offset;
    e->match_offset = match_offset;
    e->len = normalized_len;
    e->source_index = i + 1;
    e->basename_start = basename_start_of(idx->match_arena + match_offset, normalized_len);
    e->extension_start = extension_start_of(s, len, basename_start_of(s, len));

    text_offset += len + 1;
    match_offset += normalized_len + 1;
  }

  idx->count = count;
  idx->text_arena_len = text_offset;
  idx->match_arena_len = match_offset;
  idx->lower_arena_len = match_offset;
  idx->generation++;
  return true;
}

void fuzzy_index_free(FuzzyIndex *idx) {
  if (!idx) return;
  free(idx->entries);
  free(idx->text_arena);
  free(idx->match_arena);
  free(idx->lower_arena);
  memset(idx, 0, sizeof(*idx));
}

const char *fuzzy_index_text(const FuzzyIndex *idx, uint32_t entry_index) {
  if (!idx || entry_index >= idx->count) return "";
  return idx->text_arena + idx->entries[entry_index].text_offset;
}

int fuzzy_match_buffer_score(FuzzyMode mode, const FuzzyMatchBuffer *buffer, const char *query) {
  if (!buffer) return FUZZY_SCORE_NO_MATCH;
  return fuzzy_match_score(mode, buffer->match, buffer->lower, buffer->len,
    basename_start_of(buffer->match, buffer->len), query);
}

static uint32_t map_match_spans(
  FuzzyMode mode,
  const char *original,
  uint32_t original_len,
  const FuzzySpan *normalized,
  uint32_t normalized_count,
  FuzzySpan *spans,
  uint32_t max_spans
) {
  uint32_t count = normalized_count < max_spans ? normalized_count : max_spans;
  if (count == 0) return 0;
  memset(spans, 0, (size_t)count * sizeof(*spans));

  const char *p = original;
  const char *end = original + original_len;
  uint32_t normalized_offset = 0;
  uint32_t previous_start = 0, previous_end = 0;
  while (p < end) {
    uint32_t cp = 0;
    const char *next = decode_utf8(p, end, &cp);
    if (!next) {
      next = p + 1;
      cp = (unsigned char)*p;
    }

    uint32_t folded[8];
    uint32_t folded_count = fold_codepoint(cp, folded, 0);
    uint32_t emitted = 0;
    for (uint32_t i = 0; i < folded_count; ++i) {
      uint32_t folded_cp = folded[i];
      if (mode == FUZZY_MODE_PATH && (folded_cp == '/' || folded_cp == '\\')) folded_cp = '/';
      char encoded[4];
      emitted += encode_utf8(folded_cp, encoded);
    }

    uint32_t source_start = (uint32_t)(p - original) + 1;
    uint32_t source_end = (uint32_t)(next - original);
    if (emitted > 0) {
      previous_start = normalized_offset + 1;
      normalized_offset += emitted;
      previous_end = normalized_offset;
      for (uint32_t i = 0; i < count; ++i) {
        if (normalized[i].start >= previous_start && normalized[i].start <= previous_end) {
          spans[i].start = source_start;
        }
        if (normalized[i].end >= previous_start && normalized[i].end <= previous_end) {
          spans[i].end = source_end;
        }
      }
    } else if (previous_end > 0) {
      /* A stripped combining mark remains part of the preceding displayed
       * character, so highlights ending there should include it. */
      for (uint32_t i = 0; i < count; ++i) {
        if (normalized[i].end >= previous_start && normalized[i].end <= previous_end) {
          spans[i].end = source_end;
        }
      }
    }
    p = next;
  }
  return count;
}

uint32_t fuzzy_match_buffer_spans(FuzzyMode mode, const char *original, uint32_t original_len, const FuzzyMatchBuffer *buffer, const char *query, FuzzySpan *spans, uint32_t max_spans) {
  if (!original || !buffer || !spans || max_spans == 0) return 0;
  FuzzySpan normalized[FUZZY_MAX_RETURN_SPANS];
  uint32_t count = fuzzy_match_text_spans(mode, buffer->lower, buffer->len, query,
    normalized, FUZZY_MAX_RETURN_SPANS);
  return map_match_spans(mode, original, original_len, normalized, count, spans, max_spans);
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

const char *fuzzy_match_class_name(FuzzyMatchClass match_class) {
  switch (match_class) {
    case FUZZY_MATCH_CONTIGUOUS: return "contiguous";
    case FUZZY_MATCH_COMPACT: return "compact";
    case FUZZY_MATCH_LOOSE: return "loose";
    default: return "none";
  }
}

FuzzyMatchClass fuzzy_match_text_class(FuzzyMode mode, const char *lower, uint32_t len, const char *query) {
  FuzzyWord words[FUZZY_MAX_QUERY_WORDS];
  uint32_t word_count = parse_query_words(mode, query, words);
  if (word_count == 0) return FUZZY_MATCH_NONE;

  bool all_contiguous = true;
  bool any_loose = false;
  for (uint32_t w = 0; w < word_count; ++w) {
    const FuzzyWord *word = &words[w];
    if (find_substr(lower, len, word->text, word->len)) continue;
    all_contiguous = false;

    uint32_t scan = 0, first = UINT32_MAX, previous = UINT32_MAX, last = 0, max_gap = 0;
    for (uint32_t i = 0; i < word->len; ++i) {
      while (scan < len && lower[scan] != word->text[i]) scan++;
      if (scan >= len) return FUZZY_MATCH_NONE;
      if (first == UINT32_MAX) first = scan;
      if (previous != UINT32_MAX) {
        uint32_t gap = scan - previous - 1;
        if (gap > max_gap) max_gap = gap;
      }
      previous = last = scan;
      scan++;
    }
    uint32_t span = last - first + 1;
    if (span > word->len * 2 + 4 || max_gap > (word->len * 2 > 10 ? word->len * 2 : 10)) {
      any_loose = true;
    }
  }
  if (all_contiguous) return FUZZY_MATCH_CONTIGUOUS;
  return any_loose ? FUZZY_MATCH_LOOSE : FUZZY_MATCH_COMPACT;
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
  uint32_t word_count = parse_query_words(mode, query, words);
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
    const char *text = idx->match_arena + e->match_offset;
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

uint32_t fuzzy_match_text_spans(FuzzyMode mode, const char *lower, uint32_t len, const char *query, FuzzySpan *spans, uint32_t max_spans) {
  if (!lower || !spans || max_spans == 0) return 0;
  FuzzyWord words[FUZZY_MAX_QUERY_WORDS];
  uint32_t word_count = parse_query_words(mode, query, words);
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
  if (!idx || entry_index >= idx->count || !spans || max_spans == 0) return 0;
  const FuzzyEntry *entry = &idx->entries[entry_index];
  FuzzySpan normalized[FUZZY_MAX_RETURN_SPANS];
  uint32_t count = fuzzy_match_text_spans(idx->mode,
    idx->lower_arena + entry->lower_offset, entry->len, query,
    normalized, FUZZY_MAX_RETURN_SPANS);
  const char *original = fuzzy_index_text(idx, entry_index);
  return map_match_spans(idx->mode, original, (uint32_t)strlen(original),
    normalized, count, spans, max_spans);
}

typedef struct {
  char *relative_prefix;
  char *label;
  char *role;
  char *id;
  int32_t rank_penalty;
} FuzzyFilePathMapping;

typedef struct {
  char *path;
  char *label;
  char *role;
  char *id;
  int32_t rank_penalty;
  FuzzyFilePathMapping *mappings;
  uint32_t mapping_count;
} FuzzyFileRoot;

typedef struct {
  char *relative_path;
  char *display_path;
  uint32_t root_index;
  uint32_t mapping_index;
} FuzzyFileEntry;

struct FuzzyFileIndexBuilder {
  FuzzyFileRoot *roots;
  uint32_t root_count;
  FuzzyFileEntry *entries;
  uint32_t count;
  uint32_t capacity;
  uint32_t *dedup_slots;
  uint32_t dedup_capacity;
  char *pending;
  size_t pending_len;
  size_t pending_capacity;
  uint32_t pending_root;
  bool has_pending_root;
  bool failed;
  FuzzyFileIndexStats stats;
};

struct FuzzyFileIndex {
  FuzzyFileRoot *roots;
  uint32_t root_count;
  FuzzyFileEntry *entries;
  uint32_t count;
  FuzzyIndex fuzzy;
};

#ifdef _WIN32
#define FUZZY_FILE_PATHSEP '\\'
#else
#define FUZZY_FILE_PATHSEP '/'
#endif

static char *file_strdup(const char *text) {
  text = text ? text : "";
  size_t len = strlen(text);
  char *copy = (char *)malloc(len + 1);
  if (copy) memcpy(copy, text, len + 1);
  return copy;
}

static char file_path_char(char c) {
  return (c == '/' || c == '\\') ? FUZZY_FILE_PATHSEP : c;
}

static char file_identity_char(char c) {
  c = file_path_char(c);
#ifdef _WIN32
  c = lower_ascii_char(c);
#endif
  return c;
}

static char *file_normalized_copy(const char *text, bool trim_edges) {
  char *copy = file_strdup(text);
  if (!copy) return NULL;
  size_t len = strlen(copy);
  for (size_t i = 0; i < len; ++i) copy[i] = file_path_char(copy[i]);
  if (trim_edges) {
    size_t start = 0;
    while (start < len && copy[start] == FUZZY_FILE_PATHSEP) start++;
    while (len > start && copy[len - 1] == FUZZY_FILE_PATHSEP) len--;
    if (start) memmove(copy, copy + start, len - start);
    len -= start;
    copy[len] = '\0';
  } else {
    while (len > 1 && copy[len - 1] == FUZZY_FILE_PATHSEP) copy[--len] = '\0';
  }
  return copy;
}

static void file_mapping_free(FuzzyFilePathMapping *mapping) {
  if (!mapping) return;
  free(mapping->relative_prefix);
  free(mapping->label);
  free(mapping->role);
  free(mapping->id);
  memset(mapping, 0, sizeof(*mapping));
}

static void file_root_free(FuzzyFileRoot *root) {
  if (!root) return;
  free(root->path);
  free(root->label);
  free(root->role);
  free(root->id);
  for (uint32_t i = 0; i < root->mapping_count; ++i) file_mapping_free(&root->mappings[i]);
  free(root->mappings);
  memset(root, 0, sizeof(*root));
}

static void file_roots_free(FuzzyFileRoot *roots, uint32_t count) {
  for (uint32_t i = 0; i < count; ++i) file_root_free(&roots[i]);
  free(roots);
}

static void file_entries_free(FuzzyFileEntry *entries, uint32_t count) {
  for (uint32_t i = 0; i < count; ++i) {
    free(entries[i].relative_path);
    free(entries[i].display_path);
  }
  free(entries);
}

static bool file_root_copy(FuzzyFileRoot *out, const FuzzyFileRootSpec *spec) {
  memset(out, 0, sizeof(*out));
  out->path = file_normalized_copy(spec->path, false);
  out->label = file_strdup(spec->label);
  out->role = file_strdup(spec->role);
  out->id = file_strdup(spec->id);
  out->rank_penalty = spec->rank_penalty;
  out->mapping_count = spec->mapping_count;
  if (!out->path || !out->label || !out->role || !out->id) return false;
  if (out->mapping_count) {
    out->mappings = (FuzzyFilePathMapping *)calloc(out->mapping_count, sizeof(*out->mappings));
    if (!out->mappings) return false;
  }
  for (uint32_t i = 0; i < out->mapping_count; ++i) {
    const FuzzyFilePathMappingSpec *source = &spec->mappings[i];
    FuzzyFilePathMapping *mapping = &out->mappings[i];
    mapping->relative_prefix = file_normalized_copy(source->relative_prefix, true);
    mapping->label = file_strdup(source->label);
    mapping->role = file_strdup(source->role);
    mapping->id = file_strdup(source->id);
    mapping->rank_penalty = source->rank_penalty;
    if (!mapping->relative_prefix || !mapping->label || !mapping->role || !mapping->id) return false;
  }
  return true;
}

FuzzyFileIndexBuilder *fuzzy_file_index_builder_create(
  const FuzzyFileRootSpec *roots,
  uint32_t root_count
) {
  if (!roots || root_count == 0) return NULL;
  FuzzyFileIndexBuilder *builder = (FuzzyFileIndexBuilder *)calloc(1, sizeof(*builder));
  if (!builder) return NULL;
  builder->roots = (FuzzyFileRoot *)calloc(root_count, sizeof(*builder->roots));
  builder->root_count = root_count;
  if (!builder->roots) {
    fuzzy_file_index_builder_free(builder);
    return NULL;
  }
  for (uint32_t i = 0; i < root_count; ++i) {
    if (!file_root_copy(&builder->roots[i], &roots[i])) {
      fuzzy_file_index_builder_free(builder);
      return NULL;
    }
  }
  return builder;
}

void fuzzy_file_index_builder_free(FuzzyFileIndexBuilder *builder) {
  if (!builder) return;
  file_roots_free(builder->roots, builder->root_count);
  file_entries_free(builder->entries, builder->count);
  free(builder->dedup_slots);
  free(builder->pending);
  free(builder);
}

static uint64_t file_identity_hash(const FuzzyFileRoot *root, const char *relative) {
  uint64_t hash = UINT64_C(1469598103934665603);
  const char *parts[] = { root->path, "\\", relative };
  for (uint32_t p = 0; p < 3; ++p) {
    for (const char *s = parts[p]; *s; ++s) {
      hash ^= (unsigned char)file_identity_char(*s);
      hash *= UINT64_C(1099511628211);
    }
  }
  return hash;
}

static bool file_identity_equal(
  const FuzzyFileRoot *left_root,
  const char *left,
  const FuzzyFileRoot *right_root,
  const char *right
) {
  const char *left_parts[] = { left_root->path, "\\", left };
  const char *right_parts[] = { right_root->path, "\\", right };
  for (uint32_t p = 0; p < 3; ++p) {
    const char *a = left_parts[p], *b = right_parts[p];
    while (*a && *b) {
      if (file_identity_char(*a++) != file_identity_char(*b++)) return false;
    }
    if (*a || *b) return false;
  }
  return true;
}

static bool file_dedup_rebuild(FuzzyFileIndexBuilder *builder, uint32_t capacity) {
  uint32_t *slots = (uint32_t *)calloc(capacity, sizeof(*slots));
  if (!slots) return false;
  for (uint32_t i = 0; i < builder->count; ++i) {
    FuzzyFileEntry *entry = &builder->entries[i];
    uint64_t hash = file_identity_hash(&builder->roots[entry->root_index], entry->relative_path);
    uint32_t slot = (uint32_t)hash & (capacity - 1);
    while (slots[slot]) slot = (slot + 1) & (capacity - 1);
    slots[slot] = i + 1;
  }
  free(builder->dedup_slots);
  builder->dedup_slots = slots;
  builder->dedup_capacity = capacity;
  return true;
}

static bool file_dedup_ensure(FuzzyFileIndexBuilder *builder) {
  if (builder->dedup_capacity && (builder->count + 1) * 10 < builder->dedup_capacity * 7) return true;
  uint32_t capacity = builder->dedup_capacity ? builder->dedup_capacity * 2 : 256;
  if (capacity < builder->dedup_capacity) return false;
  return file_dedup_rebuild(builder, capacity);
}

static bool file_mapping_matches(const char *relative, const char *prefix) {
  size_t prefix_len = strlen(prefix);
  if (prefix_len == 0) return true;
  for (size_t i = 0; i < prefix_len; ++i) {
    if (!relative[i] || file_identity_char(relative[i]) != file_identity_char(prefix[i])) return false;
  }
  return relative[prefix_len] == '\0' || relative[prefix_len] == FUZZY_FILE_PATHSEP;
}

static uint32_t file_best_mapping(const FuzzyFileRoot *root, const char *relative) {
  uint32_t best = UINT32_MAX;
  size_t best_len = 0;
  for (uint32_t i = 0; i < root->mapping_count; ++i) {
    const char *prefix = root->mappings[i].relative_prefix;
    size_t len = strlen(prefix);
    if (len >= best_len && file_mapping_matches(relative, prefix)) {
      best = i;
      best_len = len;
    }
  }
  return best;
}

static char *file_display_path(
  const FuzzyFileRoot *root,
  uint32_t mapping_index,
  const char *relative
) {
  const char *label = root->label;
  const char *role = root->role;
  const char *shown_relative = relative;
  if (mapping_index != UINT32_MAX) {
    const FuzzyFilePathMapping *mapping = &root->mappings[mapping_index];
    size_t prefix_len = strlen(mapping->relative_prefix);
    label = mapping->label;
    role = mapping->role;
    shown_relative = relative + prefix_len;
    if (*shown_relative == FUZZY_FILE_PATHSEP) shown_relative++;
  }
  if (strcmp(role, "root") == 0) return file_strdup(shown_relative);
  size_t label_len = strlen(label), rel_len = strlen(shown_relative);
  size_t total = label_len + (rel_len ? 1 : 0) + rel_len;
  char *display = (char *)malloc(total + 1);
  if (!display) return NULL;
  memcpy(display, label, label_len);
  size_t offset = label_len;
  if (rel_len) display[offset++] = FUZZY_FILE_PATHSEP;
  memcpy(display + offset, shown_relative, rel_len + 1);
  return display;
}

static char *file_candidate_normalize(const char *data, size_t len) {
  while (len && data[len - 1] == '\r') len--;
  if (len >= 2 && data[0] == '.' && (data[1] == '/' || data[1] == '\\')) {
    data += 2;
    len -= 2;
  }
  if (len == 0 || len > UINT32_MAX) return NULL;
  char *relative = (char *)malloc(len + 1);
  if (!relative) return NULL;
  for (size_t i = 0; i < len; ++i) relative[i] = file_path_char(data[i]);
  relative[len] = '\0';
  return relative;
}

static bool file_builder_add_candidate(
  FuzzyFileIndexBuilder *builder,
  uint32_t root_index,
  const char *data,
  size_t len
) {
  builder->stats.candidates++;
  char *relative = file_candidate_normalize(data, len);
  if (!relative) return len == 0;
  if (!file_dedup_ensure(builder)) {
    free(relative);
    return false;
  }
  FuzzyFileRoot *root = &builder->roots[root_index];
  uint64_t hash = file_identity_hash(root, relative);
  uint32_t slot = (uint32_t)hash & (builder->dedup_capacity - 1);
  while (builder->dedup_slots[slot]) {
    FuzzyFileEntry *existing = &builder->entries[builder->dedup_slots[slot] - 1];
    if (file_identity_equal(root, relative,
      &builder->roots[existing->root_index], existing->relative_path)) {
      builder->stats.duplicates++;
      free(relative);
      return true;
    }
    slot = (slot + 1) & (builder->dedup_capacity - 1);
  }
  if (builder->count == builder->capacity) {
    uint32_t capacity = builder->capacity ? builder->capacity * 2 : 256;
    if (capacity < builder->capacity) {
      free(relative);
      return false;
    }
    FuzzyFileEntry *entries = (FuzzyFileEntry *)realloc(builder->entries, sizeof(*entries) * capacity);
    if (!entries) {
      free(relative);
      return false;
    }
    builder->entries = entries;
    builder->capacity = capacity;
  }
  uint32_t mapping_index = file_best_mapping(root, relative);
  char *display = file_display_path(root, mapping_index, relative);
  if (!display) {
    free(relative);
    return false;
  }
  FuzzyFileEntry *entry = &builder->entries[builder->count];
  entry->relative_path = relative;
  entry->display_path = display;
  entry->root_index = root_index;
  entry->mapping_index = mapping_index;
  builder->dedup_slots[slot] = ++builder->count;
  builder->stats.accepted++;
  return true;
}

static bool file_pending_append(FuzzyFileIndexBuilder *builder, const char *data, size_t len) {
  if (len > SIZE_MAX - builder->pending_len - 1) return false;
  size_t needed = builder->pending_len + len + 1;
  if (needed > builder->pending_capacity) {
    size_t capacity = builder->pending_capacity ? builder->pending_capacity : 256;
    while (capacity < needed) {
      if (capacity > SIZE_MAX / 2) return false;
      capacity *= 2;
    }
    char *pending = (char *)realloc(builder->pending, capacity);
    if (!pending) return false;
    builder->pending = pending;
    builder->pending_capacity = capacity;
  }
  memcpy(builder->pending + builder->pending_len, data, len);
  builder->pending_len += len;
  builder->pending[builder->pending_len] = '\0';
  return true;
}

bool fuzzy_file_index_builder_feed(
  FuzzyFileIndexBuilder *builder,
  uint32_t root_index,
  const char *data,
  size_t len
) {
  if (!builder || builder->failed || root_index >= builder->root_count || (!data && len)) return false;
  if (builder->pending_len && builder->has_pending_root && builder->pending_root != root_index) {
    builder->failed = true;
    return false;
  }
  builder->stats.input_bytes += len;
  builder->pending_root = root_index;
  builder->has_pending_root = true;
  const char *cursor = data;
  const char *end = data + len;
  while (cursor < end) {
    const char *separator = (const char *)memchr(cursor, '\0', (size_t)(end - cursor));
    if (!separator) {
      if (!file_pending_append(builder, cursor, (size_t)(end - cursor))) builder->failed = true;
      break;
    }
    size_t fragment_len = (size_t)(separator - cursor);
    bool ok;
    if (builder->pending_len) {
      ok = file_pending_append(builder, cursor, fragment_len)
        && file_builder_add_candidate(builder, root_index, builder->pending, builder->pending_len);
      builder->pending_len = 0;
    } else {
      ok = file_builder_add_candidate(builder, root_index, cursor, fragment_len);
    }
    if (!ok) {
      builder->failed = true;
      return false;
    }
    cursor = separator + 1;
  }
  return !builder->failed;
}

static int file_entry_compare(const void *left, const void *right) {
  const FuzzyFileEntry *a = (const FuzzyFileEntry *)left;
  const FuzzyFileEntry *b = (const FuzzyFileEntry *)right;
  int display = strcmp(a->display_path, b->display_path);
  if (display) return display;
  if (a->root_index < b->root_index) return -1;
  if (a->root_index > b->root_index) return 1;
  return strcmp(a->relative_path, b->relative_path);
}

static bool file_disambiguate_display_collisions(FuzzyFileIndexBuilder *builder) {
  uint32_t start = 0;
  while (start < builder->count) {
    uint32_t end = start + 1;
    while (end < builder->count
      && strcmp(builder->entries[start].display_path, builder->entries[end].display_path) == 0) end++;
    if (end - start > 1) {
      for (uint32_t i = start; i < end; ++i) {
        FuzzyFileEntry *entry = &builder->entries[i];
        const char *root_path = builder->roots[entry->root_index].path;
        size_t display_len = strlen(entry->display_path);
        size_t root_len = strlen(root_path);
        size_t relative_len = strlen(entry->relative_path);
        static const char suffix[] = "  \xE2\x80\x94  ";
        size_t suffix_len = sizeof(suffix) - 1;
        if (display_len > SIZE_MAX - suffix_len - root_len - relative_len - 2) return false;
        size_t total = display_len + suffix_len + root_len + 1 + relative_len;
        char *display = (char *)malloc(total + 1);
        if (!display) return false;
        size_t offset = 0;
        memcpy(display + offset, entry->display_path, display_len); offset += display_len;
        memcpy(display + offset, suffix, suffix_len); offset += suffix_len;
        memcpy(display + offset, root_path, root_len); offset += root_len;
        display[offset++] = FUZZY_FILE_PATHSEP;
        memcpy(display + offset, entry->relative_path, relative_len + 1);
        free(entry->display_path);
        entry->display_path = display;
      }
    }
    start = end;
  }
  return true;
}

FuzzyFileIndex *fuzzy_file_index_builder_finish(
  FuzzyFileIndexBuilder *builder,
  FuzzyFileIndexStats *stats
) {
  if (!builder) return NULL;
  if (!builder->failed && builder->pending_len) {
    if (!file_builder_add_candidate(builder, builder->pending_root,
      builder->pending, builder->pending_len)) builder->failed = true;
    builder->pending_len = 0;
  }
  if (stats) *stats = builder->stats;
  if (builder->failed) {
    fuzzy_file_index_builder_free(builder);
    return NULL;
  }
  qsort(builder->entries, builder->count, sizeof(*builder->entries), file_entry_compare);
  if (!file_disambiguate_display_collisions(builder)) {
    fuzzy_file_index_builder_free(builder);
    return NULL;
  }
  qsort(builder->entries, builder->count, sizeof(*builder->entries), file_entry_compare);
  const char **items = builder->count
    ? (const char **)calloc(builder->count, sizeof(*items)) : NULL;
  if (builder->count && !items) {
    fuzzy_file_index_builder_free(builder);
    return NULL;
  }
  for (uint32_t i = 0; i < builder->count; ++i) items[i] = builder->entries[i].display_path;
  FuzzyFileIndex *index = (FuzzyFileIndex *)calloc(1, sizeof(*index));
  if (!index || !fuzzy_index_build(index ? &index->fuzzy : NULL,
    items, builder->count, FUZZY_MODE_PATH)) {
    free(items);
    free(index);
    fuzzy_file_index_builder_free(builder);
    return NULL;
  }
  free(items);
  index->roots = builder->roots;
  index->root_count = builder->root_count;
  index->entries = builder->entries;
  index->count = builder->count;
  builder->roots = NULL;
  builder->root_count = 0;
  builder->entries = NULL;
  builder->count = 0;
  fuzzy_file_index_builder_free(builder);
  return index;
}

void fuzzy_file_index_free(FuzzyFileIndex *index) {
  if (!index) return;
  fuzzy_index_free(&index->fuzzy);
  file_roots_free(index->roots, index->root_count);
  file_entries_free(index->entries, index->count);
  free(index);
}

uint32_t fuzzy_file_index_count(const FuzzyFileIndex *index) {
  return index ? index->count : 0;
}

bool fuzzy_file_index_entry_at(
  const FuzzyFileIndex *index,
  uint32_t index_number,
  FuzzyFileEntryView *view
) {
  if (!index || !view || index_number >= index->count) return false;
  const FuzzyFileEntry *entry = &index->entries[index_number];
  const FuzzyFileRoot *root = &index->roots[entry->root_index];
  const char *label = root->label, *role = root->role, *id = root->id;
  int32_t rank_penalty = root->rank_penalty;
  if (entry->mapping_index != UINT32_MAX) {
    const FuzzyFilePathMapping *mapping = &root->mappings[entry->mapping_index];
    label = mapping->label;
    role = mapping->role;
    id = mapping->id;
    rank_penalty = mapping->rank_penalty;
  }
  view->display_path = entry->display_path;
  view->relative_path = entry->relative_path;
  view->root_path = root->path;
  view->root_label = label;
  view->role = role;
  view->root_id = id;
  view->rank_penalty = rank_penalty;
  view->root_index = entry->root_index;
  return true;
}

FuzzySearchResult *fuzzy_file_index_search(
  const FuzzyFileIndex *index,
  const char *query,
  uint32_t limit,
  uint32_t *out_count,
  bool *out_has_more
) {
  if (!index) {
    if (out_count) *out_count = 0;
    if (out_has_more) *out_has_more = false;
    return NULL;
  }
  return fuzzy_index_search(&index->fuzzy, query, limit, out_count, out_has_more);
}

uint32_t fuzzy_file_index_match_spans(
  const FuzzyFileIndex *index,
  uint32_t fuzzy_entry_index,
  const char *query,
  FuzzySpan *spans,
  uint32_t max_spans
) {
  if (!index) return 0;
  return fuzzy_match_spans(&index->fuzzy, fuzzy_entry_index, query, spans, max_spans);
}
