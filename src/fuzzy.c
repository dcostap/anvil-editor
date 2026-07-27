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
