#include "markdown_delimiters.h"
#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>
#include <SDL3/SDL_mutex.h>
#include <SDL3/SDL_stdinc.h>
#include <stdlib.h>

typedef enum { TEXT, SPACE, PUNCT, FAILED } Neighbor;

static Neighbor neighbor(MarkdownDelimiters *d, uint32_t at, uint32_t end) {
  const char *text = d->text;
  unsigned char b = text[at];
  if (b < 128) {
    if (b == ' ' || (b >= '\t' && b <= '\r')) return SPACE;
    return ((b >= '!' && b <= '/') || (b >= ':' && b <= '@') ||
      (b >= '[' && b <= '`') || (b >= '{' && b <= '~')) ? PUNCT : TEXT;
  }
  const char *p = text + at;
  size_t length = end - at;
  SDL_StepUTF8(&p, &length);
  static SDL_InitState init;
  static pcre2_code *classes;
  if (SDL_ShouldInit(&init)) {
    int error;
    PCRE2_SIZE offset;
    classes = pcre2_compile((PCRE2_SPTR)"(\\p{Zs})|[\\p{P}\\p{S}]", PCRE2_ZERO_TERMINATED,
      PCRE2_UTF, &error, &offset, NULL);
    SDL_SetInitialized(&init, classes != NULL);
  }
  if (!classes) return FAILED;
  if (!d->unicode_match) d->unicode_match = pcre2_match_data_create_from_pattern(classes, NULL);
  if (!d->unicode_match) return FAILED;
  int rc = pcre2_match(classes, (PCRE2_SPTR)(text + at), p - (text + at), 0, 0, d->unicode_match, NULL);
  return rc == 2 ? SPACE : rc == 1 ? PUNCT : TEXT;
}

/* Keep the most recent opener for each marker, length modulo three, and
 * closing ability. Failed searches inspect six buckets, not the paragraph. */
struct MarkdownOpener { uint32_t start, end, bucket, previous; };

static bool pair_run(MarkdownDelimiters *d, uint32_t start, uint32_t end) {
  char marker = d->text[start];
  uint32_t len = end - start, base = marker == '*' ? 0 : marker == '_' ? 6 : 12;
  if (marker == '~' && len > 2) return true;
  uint32_t prev = start;
  if (prev > d->start) {
    prev--;
    while (prev > d->start && start - prev < 4 && ((unsigned char)d->text[prev] & 0xc0) == 0x80) prev--;
  }
  Neighbor a = start == d->start ? SPACE : neighbor(d, prev, start);
  Neighbor b = end == d->end ? SPACE : neighbor(d, end, d->end);
  if (a == FAILED || b == FAILED) return false;
  bool left = b != SPACE && (b != PUNCT || a != TEXT);
  bool right = a != SPACE && (a != PUNCT || b != TEXT);
  bool open = left && (marker != '_' || !right || a == PUNCT);
  bool close = right && (marker != '_' || !left || b == PUNCT);
  while (close && start < end) {
    uint32_t best = 0;
    for (uint32_t i = 0; i < 6; i++) {
      if (marker == '~' ? i % 3 != len :
          ((open || i >= 3) && len % 3 && (i % 3 + len % 3 == 3))) continue;
      if (d->heads[base + i] > best) best = d->heads[base + i];
    }
    if (!best) break;
    while (d->count > best) {
      MarkdownOpener *old = &d->stack[--d->count];
      d->heads[old->bucket] = old->previous;
    }
    MarkdownOpener *op = &d->stack[best - 1];
    uint32_t width = op->end - op->start >= 2 && end - start >= 2 ? 2 : 1;
    op->end -= width;
    if (!d->emit(d->payload, op->end, start, width, marker)) return false;
    start += width;
    if (op->start == op->end) {
      d->heads[op->bucket] = op->previous;
      d->count--;
    }
  }
  if (open && start < end) {
    if (d->count == d->capacity) {
      uint32_t cap = d->capacity ? d->capacity * 2 : 16;
      if (cap <= d->capacity || SIZE_MAX / sizeof(*d->stack) < cap) return false;
      MarkdownOpener *p = realloc(d->stack, cap * sizeof(*p));
      if (!p) return false;
      d->stack = p;
      d->capacity = cap;
    }
    uint32_t bucket = base + len % 3 + (close ? 3 : 0);
    d->stack[d->count++] = (MarkdownOpener){start, end, bucket, d->heads[bucket]};
    d->heads[bucket] = d->count;
  }
  return true;
}

bool markdown_delimiters_feed(MarkdownDelimiters *d, uint32_t i, uint32_t end) {
  while (i < end) {
    if (d->stop && !(i & 4095) && d->stop(d->payload)) return false;
    char c = d->text[i++];
    if (c == '\\' && i < end) { i++; continue; }
    if (c != '*' && c != '_' && c != '~') continue;
    uint32_t start = i - 1;
    while (i < end && d->text[i] == c) i++;
    if (!pair_run(d, start, i)) return false;
  }
  return true;
}

void markdown_delimiters_free(MarkdownDelimiters *d) {
  pcre2_match_data_free(d->unicode_match);
  free(d->stack);
}
