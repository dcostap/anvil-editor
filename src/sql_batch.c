#include "sql_batch.h"
#include <ctype.h>

static int blank(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\f' || c == '\v'; }

/* Returns the offset after a GO line that starts at p, or 0. */
static size_t go_line(const char *s, size_t n, size_t p, unsigned *repeat, int *invalid) {
  while (p < n && blank(s[p])) ++p;
  if (p + 2 > n || toupper((unsigned char)s[p]) != 'G' || toupper((unsigned char)s[p + 1]) != 'O') return 0;
  p += 2;
  if (p < n && !blank(s[p]) && s[p] != '\n' && s[p] != '-') return 0;
  while (p < n && blank(s[p])) ++p;
  unsigned count = 1;
  if (p < n && isdigit((unsigned char)s[p])) {
    count = 0;
    while (p < n && isdigit((unsigned char)s[p])) {
      if (count <= SQL_BATCH_REPEAT_LIMIT) count = count * 10 + (unsigned)(s[p] - '0');
      ++p;
    }
    while (p < n && blank(s[p])) ++p;
  }
  if (p + 1 < n && s[p] == '-' && s[p + 1] == '-') while (p < n && s[p] != '\n') ++p;
  if (p < n && s[p] != '\n') return 0;
  if (!count || count > SQL_BATCH_REPEAT_LIMIT) *invalid = 1;
  *repeat = count;
  return p < n ? p + 1 : n;
}

static int add(SqlBatch *out, size_t capacity, size_t *count, const char *s, size_t start, size_t end,
               unsigned repeat, unsigned line) {
  size_t p = start;
  while (p < end && isspace((unsigned char)s[p])) ++p;
  if (p == end) return 1;
  if (*count == capacity) return 0;
  out[(*count)++] = (SqlBatch){ start, end, repeat, line };
  return 1;
}

int sql_batch_split(const char *s, size_t n, SqlBatch *out, size_t capacity) {
  size_t count = 0, start = 0, p = 0;
  unsigned line = 1, start_line = 1;
  int depth = 0;
  char close = 0;
  while (p <= n) {
    if (!close && !depth && (p == 0 || s[p - 1] == '\n')) {
      unsigned repeat = 1;
      int invalid = 0;
      size_t next = go_line(s, n, p, &repeat, &invalid);
      if (next) {
        if (invalid) return -1;
        if (!add(out, capacity, &count, s, start, p, repeat, start_line)) return -1;
        ++line;
        start = p = next; start_line = line;
        continue;
      }
    }
    if (p == n) break;
    char c = s[p++];
    if (c == '\n') { ++line; continue; }
    if (close) {
      if (c == close) {
        if (p < n && s[p] == close) ++p;
        else close = 0;
      }
    } else if (depth) {
      if (c == '/' && p < n && s[p] == '*') { ++depth; ++p; }
      else if (c == '*' && p < n && s[p] == '/') { --depth; ++p; }
    } else if (c == '-' && p < n && s[p] == '-') {
      while (p < n && s[p] != '\n') ++p;
    } else if (c == '/' && p < n && s[p] == '*') { depth = 1; ++p; }
    else if (c == '\'' || c == '"') close = c;
    else if (c == '[') close = ']';
  }
  if (!add(out, capacity, &count, s, start, n, 1, start_line)) return -1;
  return (int)count;
}
