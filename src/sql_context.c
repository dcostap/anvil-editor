/* The query-context slice follows DbVisualizer's token/context/provider split.
 * It supports SELECT sources and joins. Unsupported scopes return no candidates.
 * This is not an execution parser. It never changes submitted SQL. */
#include "sql_context.h"
#include <ctype.h>
#include <stdlib.h>
#include <string.h>

#define TOKEN_LIMIT 32768
#define TEXT_LIMIT (256 * 1024)
typedef struct { size_t start, end; int kind, depth; } Token;
enum { IDENT = 256, QUOTED, LITERAL, COMMENT };

static int identifier(unsigned char c) {
  return c >= 128 || isalnum(c) || c == '_' || c == '#' || c == '@' || c == '$';
}
static int word(const char *s, Token t, const char *w) {
  if (t.kind != IDENT || t.end - t.start != strlen(w)) return 0;
  for (size_t i = 0; w[i]; ++i)
    if (toupper((unsigned char)s[t.start + i]) != (unsigned char)w[i]) return 0;
  return 1;
}
static int name(const char *s, Token t, size_t end, char *out) {
  size_t at = t.start, n = 0;
  char close = 0;
  if (t.kind == QUOTED) { close = s[at] == '[' ? ']' : '"'; ++at; }
  for (; at < end; ++at) {
    if (close && s[at] == close) {
      if (at + 1 < end && s[at + 1] == close) ++at;
      else break;
    }
    if (n + 1 >= SQL_CONTEXT_NAME) return 0;
    out[n++] = s[at];
  }
  out[n] = 0;
  return 1;
}
static int is_name(Token t) { return t.kind == IDENT || t.kind == QUOTED; }
static int reserved(const char *s, Token t) {
  static const char *words[] = { "SELECT", "FROM", "WHERE", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER",
    "FULL", "CROSS", "ON", "GROUP", "ORDER", "HAVING", "UNION", "EXCEPT", "INTERSECT", "OFFSET",
    "FETCH", "WITH", "AS", "SET", "VALUES", "INTO", "FOR", "OPTION", "APPLY", NULL };
  for (int i = 0; words[i]; ++i) if (word(s, t, words[i])) return 1;
  return 0;
}
static int go_line(const char *s, size_t len, Token t) {
  if (!word(s, t, "GO")) return 0;
  size_t a = t.start, b = t.end;
  while (a && s[a - 1] != '\n') if (!isspace((unsigned char)s[--a])) return 0;
  while (b < len && s[b] != '\n') if (!isspace((unsigned char)s[b++])) return 0;
  return 1;
}
int sql_context_parse(const char *s, size_t len, size_t caret, SqlContext *out) {
  memset(out, 0, sizeof(*out));
  if (!s || len > TEXT_LIMIT || caret > len) return 0;
  out->start = out->end = caret;
  Token *ts = malloc(TOKEN_LIMIT * sizeof(*ts));
  if (!ts) return 0;
  size_t n = 0, pos = 0;
  int depth = 0, blocked = 0, ok = 1;
  while (pos < len) {
    if (isspace((unsigned char)s[pos])) { ++pos; continue; }
    if (n == TOKEN_LIMIT) { ok = 0; goto done; }
    Token t = { pos, pos, (unsigned char)s[pos], depth };
    char c = s[pos++];
    if (c == '-' && pos < len && s[pos] == '-') {
      while (pos < len && s[pos] != '\n') ++pos;
      t.kind = COMMENT;
    } else if (c == '/' && pos < len && s[pos] == '*') {
      ++pos;
      int nesting = 1;
      while (pos < len && nesting) {
        if (pos + 1 < len && s[pos] == '/' && s[pos + 1] == '*') { ++nesting; pos += 2; }
        else if (pos + 1 < len && s[pos] == '*' && s[pos + 1] == '/') { --nesting; pos += 2; }
        else ++pos;
      }
      t.kind = COMMENT;
    } else if (c == '\'' || c == '[' || c == '"') {
      char close = c == '[' ? ']' : c;
      t.kind = c == '\'' ? LITERAL : QUOTED;
      while (pos < len) {
        if (s[pos++] != close) continue;
        if (pos < len && s[pos] == close) { ++pos; continue; }
        break;
      }
    } else if (identifier((unsigned char)c)) {
      t.kind = IDENT;
      while (pos < len && identifier((unsigned char)s[pos])) ++pos;
    } else if (c == '(') ++depth;
    else if (c == ')') { if (depth) --depth; t.depth = depth; }
    t.end = pos;
    if ((t.kind == COMMENT || t.kind == LITERAL) && caret > t.start && caret <= t.end) blocked = 1;
    if (t.kind != COMMENT) ts[n++] = t;
  }
  if (blocked) goto done;

  /* Find the containing statement. GO only separates a complete line. */
  size_t first = 0, last = n;
  for (size_t i = 0; i < n; ++i) {
    if (ts[i].kind != ';' && !go_line(s, len, ts[i])) continue;
    if (ts[i].end <= caret) first = i + 1;
    else { last = i; break; }
  }
  /* Select the innermost SELECT scope that contains the caret. Parentheses
   * without SELECT (function arguments) do not make a new query scope. */
  size_t scopes[64], scope_count = 0;
  for (size_t i = first; i < last && ts[i].start < caret; ++i) {
    while (scope_count && ts[scopes[scope_count - 1]].depth > ts[i].depth) --scope_count;
    int select = word(s, ts[i], "SELECT");
    int separator = word(s, ts[i], "UNION") || word(s, ts[i], "EXCEPT") || word(s, ts[i], "INTERSECT");
    if ((select || separator) && scope_count && ts[scopes[scope_count - 1]].depth == ts[i].depth) --scope_count;
    if (select) {
      if (scope_count == sizeof(scopes) / sizeof(scopes[0])) { ok = 0; goto done; }
      scopes[scope_count++] = i;
    }
  }
  if (!scope_count) goto done;
  size_t begin = scopes[scope_count - 1], end = last;
  int scope = ts[begin].depth;
  for (size_t i = begin + 1; i < last; ++i) {
    if (ts[i].depth < scope ||
        (ts[i].depth == scope && (word(s, ts[i], "UNION") || word(s, ts[i], "EXCEPT") || word(s, ts[i], "INTERSECT")))) {
      end = i; break;
    }
  }
  /* A CTE needs its own column model. Do not confuse its name with a real table. */
  if (first < n && word(s, ts[first], "WITH")) goto done;

  size_t current = n, prev = n;
  for (size_t i = begin; i < end; ++i) {
    if (is_name(ts[i]) && caret > ts[i].start && caret <= ts[i].end) { current = i; break; }
    if (ts[i].end <= caret) prev = i;
  }
  if (current < n) {
    out->start = ts[current].start; out->end = ts[current].end;
    if (!name(s, ts[current], caret, out->prefix)) { ok = 0; goto done; }
    prev = current > begin ? current - 1 : n;
  }
  if (prev < n && ts[prev].kind == '.' && prev > begin && is_name(ts[prev - 1])) {
    if (!name(s, ts[prev - 1], ts[prev - 1].end, out->qualifier)) { ok = 0; goto done; }
  }

  out->mode = SQL_CONTEXT_COLUMN;
  int source_list = 0, expect_source = 0;
  for (size_t i = begin; i < end; ++i) {
    Token t = ts[i];
    if (t.depth != scope) continue;
    if (word(s, t, "FROM") || word(s, t, "JOIN")) {
      source_list = expect_source = 1;
      if (t.end <= caret) out->mode = SQL_CONTEXT_TABLE;
      continue;
    }
    if (word(s, t, "WHERE") || word(s, t, "ON") || word(s, t, "GROUP") ||
        word(s, t, "ORDER") || word(s, t, "HAVING")) {
      source_list = expect_source = 0;
      if (t.end <= caret) out->mode = SQL_CONTEXT_COLUMN;
      continue;
    }
    if (t.kind == ',' && source_list) {
      expect_source = 1;
      if (t.end <= caret) out->mode = SQL_CONTEXT_TABLE;
      continue;
    }
    if (!expect_source) continue;
    if (!is_name(t) || reserved(s, t)) {
      /* Derived tables and table-valued expressions need more metadata. */
      out->mode = SQL_CONTEXT_NONE; out->count = 0; goto done;
    }
    SqlSource src = {0};
    if (!name(s, t, t.end, src.name)) { ok = 0; goto done; }
    if (i + 2 < end && ts[i + 1].kind == '.' && is_name(ts[i + 2])) {
      memcpy(src.schema, src.name, sizeof(src.schema));
      i += 2;
      if (!name(s, ts[i], ts[i].end, src.name)) { ok = 0; goto done; }
    }
    if (i + 1 < end && (ts[i + 1].kind == '.' || ts[i + 1].kind == '(')) {
      out->mode = SQL_CONTEXT_NONE; out->count = 0; goto done;
    }
    if (i + 1 < end && word(s, ts[i + 1], "AS")) ++i;
    if (i + 1 < end && is_name(ts[i + 1]) && !reserved(s, ts[i + 1])) {
      ++i;
      if (!name(s, ts[i], ts[i].end, src.alias)) { ok = 0; goto done; }
    }
    if (out->count == SQL_CONTEXT_SOURCES) { ok = 0; goto done; }
    out->sources[out->count++] = src;
    expect_source = 0;
  }
done:
  free(ts);
  if (!ok) memset(out, 0, sizeof(*out));
  return ok;
}
