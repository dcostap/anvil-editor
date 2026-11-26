#ifndef ANVIL_MARKDOWN_DELIMITERS_H
#define ANVIL_MARKDOWN_DELIMITERS_H

#include <stdbool.h>
#include <stdint.h>

typedef bool (*MarkdownPair)(void *, uint32_t open, uint32_t close, uint32_t width, char marker);
typedef struct MarkdownOpener MarkdownOpener;
typedef struct MarkdownDelimiters {
  const char *text;
  uint32_t start, end;
  MarkdownPair emit;
  bool (*stop)(void *);
  void *payload;
  MarkdownOpener *stack;
  void *unicode_match;
  uint32_t count, capacity, heads[18];
} MarkdownDelimiters;

/* Feed disjoint text intervals in order. Omitted intervals are opaque but
 * can occur inside a pair. Start a separate stack for a link label. */
bool markdown_delimiters_feed(MarkdownDelimiters *d, uint32_t start, uint32_t end);
void markdown_delimiters_free(MarkdownDelimiters *d);
#endif
