#include "sql_batch.h"
#include <ctype.h>
#include <stdlib.h>
#include <string.h>

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

/* Skips whitespace and comments. Block comments nest in T-SQL. */
static size_t skip_space(const char *s, size_t n, size_t p) {
  for (;;) {
    while (p < n && isspace((unsigned char)s[p])) ++p;
    if (p + 1 < n && s[p] == '-' && s[p + 1] == '-') {
      while (p < n && s[p] != '\n') ++p;
    } else if (p + 1 < n && s[p] == '/' && s[p + 1] == '*') {
      int depth = 1;
      for (p += 2; p < n && depth; ++p) {
        if (p + 1 < n && s[p] == '/' && s[p + 1] == '*') { ++depth; ++p; }
        else if (p + 1 < n && s[p] == '*' && s[p + 1] == '/') { --depth; ++p; }
      }
    } else return p;
  }
}

static int word_char(char c) { return isalnum((unsigned char)c) || c == '_' || c == '@' || c == '#' || c == '$' || (c & 0x80); }

/* Takes the keyword at p and moves p past it and the space after it. */
static int keyword(const char *s, size_t n, size_t *p, const char *word) {
  size_t length = strlen(word);
  if (*p + length > n) return 0;
  for (size_t i = 0; i < length; ++i)
    if (toupper((unsigned char)s[*p + i]) != word[i]) return 0;
  if (*p + length < n && word_char(s[*p + length])) return 0;
  *p = skip_space(s, n, *p + length);
  return 1;
}

int sql_batch_module(const char *s, size_t n, char *name, size_t size) {
  size_t p = skip_space(s, n, 0);
  if (!keyword(s, n, &p, "CREATE") && !keyword(s, n, &p, "ALTER")) return 0;
  if (keyword(s, n, &p, "OR") && !keyword(s, n, &p, "ALTER")) return 0;
  if (!keyword(s, n, &p, "PROCEDURE") && !keyword(s, n, &p, "PROC") && !keyword(s, n, &p, "FUNCTION") &&
      !keyword(s, n, &p, "TRIGGER")) return 0;
  /* Each part of the name replaces the previous part, so the last part stays. */
  for (;;) {
    size_t used = 0;
    if (p < n && (s[p] == '[' || s[p] == '"')) {
      char close = s[p] == '[' ? ']' : '"';
      for (++p;; ++p) {
        if (p == n) return 0;
        if (s[p] == close) {
          if (p + 1 < n && s[p + 1] == close) ++p;
          else { ++p; break; }
        }
        if (used + 1 == size) return 0;
        name[used++] = s[p];
      }
    } else {
      while (p < n && word_char(s[p])) {
        if (used + 1 == size) return 0;
        name[used++] = s[p++];
      }
    }
    if (!used) return 0;
    name[used] = 0;
    size_t dot = skip_space(s, n, p);
    if (dot < n && s[dot] == '.') p = skip_space(s, n, dot + 1);
    else return 1;
  }
}

static int is_word(const char *w, const char *const *words) {
  for (int i = 0; words[i]; ++i) if (!strcmp(w, words[i])) return 1;
  return 0;
}

int sql_batch_changes_schema(const char *s, size_t n) {
  static const char *const verbs[] = { "CREATE", "ALTER", "DROP", NULL };
  static const char *const kinds[] = { "TABLE", "VIEW", "PROC", "PROCEDURE", "FUNCTION", "TRIGGER", "SCHEMA",
    "SYNONYM", "TYPE", "SEQUENCE", NULL };
  /* After a verb, after its object kind, or after INTO: the next name decides.
   * An INTO after OUTPUT names an existing table, not a new one. */
  enum { NONE, VERB, NAME } state = NONE;
  char previous[16] = "";
  int output = 0;
  size_t p = 0;
  for (;;) {
    p = skip_space(s, n, p);
    if (p >= n) return 0;
    char c = s[p];
    if (c == '\'' || c == '[' || c == '"') {
      if (c != '\'' && state == NAME && !(p + 1 < n && s[p + 1] == '#')) return 1;
      char close = c == '[' ? ']' : c;
      for (++p; p < n; ++p)
        if (s[p] == close) {
          if (p + 1 < n && s[p + 1] == close) ++p;
          else { ++p; break; }
        }
      state = NONE; previous[0] = 0;
      continue;
    }
    if (!word_char(c)) {
      if (c == ';') output = 0;
      ++p; state = NONE; previous[0] = 0; continue;
    }
    size_t start = p;
    while (p < n && word_char(s[p])) ++p;
    char w[16] = "";
    if (p - start < sizeof(w))
      for (size_t i = start; i < p; ++i) w[i - start] = (char)toupper((unsigned char)s[i]);
    if (state == NAME) {
      if (!strcmp(w, "IF") || !strcmp(w, "EXISTS")) continue;
      if (s[start] != '#' && s[start] != '@') return 1;
      state = NONE;
    } else if (state == VERB && (!strcmp(w, "OR") || !strcmp(w, "ALTER") || !strcmp(w, "EXTERNAL"))) {
      continue;
    } else if (state == VERB && is_word(w, kinds)) {
      state = NAME;
      continue;
    } else if (is_word(w, verbs)) {
      state = VERB;
    } else if (!strcmp(w, "SP_RENAME")) {
      return 1;
    } else if (!strcmp(w, "OUTPUT") || !strcmp(w, "SELECT")) {
      /* OUTPUT has no SELECT inside it, so a SELECT ends its clause. */
      output = w[0] == 'O';
      state = NONE;
    } else if (!strcmp(w, "INTO") && output) {
      output = 0;
      state = NONE;
    } else {
      state = !strcmp(w, "INTO") && strcmp(previous, "INSERT") && strcmp(previous, "MERGE") ? NAME : NONE;
    }
    memcpy(previous, w, sizeof(previous));
  }
}
/* A token of the risk scan: a word (w holds it in uppercase, cut to fit), a
 * quoted name, a string, or one punctuation character. Temp tells that a word
 * or quoted name starts with # or @. */
typedef struct { char kind, w[24]; size_t start; int temp; } RiskToken;

static int risk_token(const char *s, size_t n, size_t *p, RiskToken *t) {
  *p = skip_space(s, n, *p);
  if (*p >= n) return 0;
  size_t start = *p;
  char c = s[start];
  memset(t, 0, sizeof(*t));
  t->start = start;
  if (c == '\'' || c == '[' || c == '"') {
    char close = c == '[' ? ']' : c;
    t->kind = c == '\'' ? 's' : 'q';
    t->temp = t->kind == 'q' && start + 1 < n && (s[start + 1] == '#' || s[start + 1] == '@');
    for (++*p; *p < n; ++*p)
      if (s[*p] == close) {
        if (*p + 1 < n && s[*p + 1] == close) ++*p;
        else { ++*p; break; }
      }
    return 1;
  }
  if (c == 'N' && start + 1 < n && s[start + 1] == '\'') { ++*p; return risk_token(s, n, p, t) ? (t->start = start, 1) : 0; }
  if (!word_char(c)) { t->kind = c; ++*p; return 1; }
  t->kind = 'w';
  t->temp = c == '#' || c == '@';
  while (*p < n && word_char(s[*p])) ++*p;
  if (*p - start < sizeof(t->w))
    for (size_t i = start; i < *p; ++i) t->w[i - start] = (char)toupper((unsigned char)s[i]);
  return 1;
}

static int next_is(const char *s, size_t end, size_t p, char c) {
  p = skip_space(s, end, p);
  return p < end && s[p] == c;
}
static int word_is(const RiskToken *t, const char *w) { return t->kind == 'w' && !strcmp(t->w, w); }
static int word_in(const RiskToken *t, const char *const *words) { return t->kind == 'w' && is_word(t->w, words); }

/* Words that start a statement. They end an open UPDATE or DELETE at its level. */
static const char *const NEXT_WORDS[] = { "SELECT", "INSERT", "UPDATE", "DELETE", "MERGE", "DECLARE", "IF", "ELSE",
  "WHILE", "BEGIN", "END", "RETURN", "PRINT", "EXEC", "EXECUTE", "CREATE", "ALTER", "DROP", "TRUNCATE", "USE",
  "COMMIT", "ROLLBACK", "RAISERROR", "THROW", "WAITFOR", "SET", "WITH", NULL };
/* Statements that only read, or control the flow. */
static const char *const READ_WORDS[] = { "SELECT", "WITH", "DECLARE", "SET", "PRINT", "IF", "ELSE", "WHILE",
  "BEGIN", "END", "RETURN", "USE", "RAISERROR", "THROW", "WAITFOR", "COMMIT", "ROLLBACK", "SAVE", "OPEN", "FETCH",
  "CLOSE", "DEALLOCATE", "GOTO", "BREAK", "CONTINUE", NULL };
/* Verbs whose target decides: a temporary table or a table variable changes nothing that stays. */
static const char *const TARGET_VERBS[] = { "INSERT", "UPDATE", "DELETE", "MERGE", "TRUNCATE", "CREATE", "ALTER",
  "DROP", NULL };
/* Words between such a verb and its target. */
static const char *const TARGET_SKIP[] = { "INTO", "FROM", "TABLE", "TOP", "PERCENT", "IF", "EXISTS", "OR", "ALTER",
  NULL };
static const char *const OTHER_CHANGES[] = { "EXEC", "EXECUTE", "GRANT", "REVOKE", "DENY", "BULK", "DBCC",
  "RESTORE", "BACKUP", "KILL", "SHUTDOWN", "RECONFIGURE", "ENABLE", "DISABLE", "SP_RENAME", NULL };
/* After these words, INSERT, UPDATE and DELETE name an action, not a statement. */
static const char *const ACTION_BEFORE[] = { "THEN", "ON", "OF", "FOR", "AFTER", "INSTEAD", "GRANT", "DENY",
  "REVOKE", NULL };
static const char *const OUTER_JOINS[] = { "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", NULL };

static void risk_batch(const char *s, size_t begin, size_t end, unsigned line, SqlBatchRisk *out) {
  char name[1100];
  if (sql_batch_module(s + begin, end - begin, name, sizeof(name))) { out->changes = 1; return; }
  /* The target of a verb, and an open UPDATE or DELETE, both at their verb's level. */
  struct { const char *verb; size_t depth; int active; } target = { 0 };
  struct { const char *verb; size_t start, depth; int active, set, cases; } open = { 0 };
  RiskToken t, previous = { 0 };
  size_t p = begin, depth = 0;
  int first = 1, output = 0, into = 0;
  #define REPORT() do { \
    if (!out->unfiltered_line) { \
      out->unfiltered_line = line; \
      for (size_t k = begin; k < open.start; ++k) if (s[k] == '\n') ++out->unfiltered_line; \
      strcpy(out->unfiltered_verb, open.verb); \
    } \
    open.active = 0; } while (0)
  while (risk_token(s, end, &p, &t)) {
    if (t.kind == '(') { ++depth; previous = t; first = 0; continue; }
    if (t.kind == ')') {
      if (depth) --depth;
      if (open.active && depth < open.depth) REPORT();
      previous = t; continue;
    }
    if (first && t.kind == 'w' && !word_in(&t, READ_WORDS) && !word_in(&t, TARGET_VERBS) && !word_in(&t, OTHER_CHANGES))
      out->changes = 1; /* A procedure call without EXEC. */
    first = 0;
    if (into && (t.kind == 'w' || t.kind == 'q')) { if (!t.temp) out->changes = 1; into = 0; }
    if (target.active && depth == target.depth) {
      if (word_in(&t, TARGET_SKIP)) { previous = t; continue; }
      target.active = 0;
      if (t.kind != 'w' && t.kind != 'q') out->changes = 1;
      else if (!t.temp) {
        out->changes = 1;
        if (!strcmp(target.verb, "UPDATE") && word_is(&t, "STATISTICS")) { previous = t; continue; }
        if ((!strcmp(target.verb, "UPDATE") || !strcmp(target.verb, "DELETE")) && !open.active) {
          open.active = 1; open.verb = target.verb; open.depth = depth; open.set = 0; open.cases = 0;
        }
      }
      previous = t; continue;
    }
    if (open.active && depth == open.depth) {
      if (t.kind == ';') REPORT();
      else if (word_is(&t, "WHERE")) open.active = 0;
      else if (word_is(&t, "JOIN") && !word_in(&previous, OUTER_JOINS)) open.active = 0;
      else if (word_is(&t, "CASE")) ++open.cases;
      else if (word_is(&t, "END") && open.cases) --open.cases;
      else if (word_is(&t, "SET") && !strcmp(open.verb, "UPDATE") && !open.set) open.set = 1;
      else if (word_is(&t, "WITH") && next_is(s, end, p, '(')) {}
      else if (word_in(&t, NEXT_WORDS)) REPORT();
    }
    if (t.kind == ';') output = 0;
    if (word_is(&t, "OUTPUT")) output = 1;
    else if (word_is(&t, "SELECT")) output = 0;
    else if (word_is(&t, "INTO") && !word_is(&previous, "INSERT") && !word_is(&previous, "MERGE") && !output) into = 1;
    else if (word_in(&t, OTHER_CHANGES)) out->changes = 1;
    else if (word_in(&t, TARGET_VERBS)) {
      int dml = word_is(&t, "INSERT") || word_is(&t, "UPDATE") || word_is(&t, "DELETE") || word_is(&t, "MERGE");
      int action = dml && (previous.kind == ',' || word_in(&previous, ACTION_BEFORE) || next_is(s, end, p, '('));
      if (!action) {
        static const char *const verbs[] = { "INSERT", "UPDATE", "DELETE", "MERGE", "TRUNCATE", "CREATE", "ALTER", "DROP" };
        for (size_t k = 0; k < sizeof(verbs) / sizeof(verbs[0]); ++k) if (word_is(&t, verbs[k])) target.verb = verbs[k];
        target.active = 1; target.depth = depth;
        if (!open.active) open.start = t.start;
      }
    }
    previous = t;
  }
  if (target.active) out->changes = 1;
  if (open.active) REPORT();
  #undef REPORT
}

void sql_batch_risk(const char *s, size_t n, SqlBatchRisk *out) {
  memset(out, 0, sizeof(*out));
  SqlBatch *batches = malloc((SQL_BATCH_LIMIT + 1) * sizeof(*batches));
  if (!batches) { out->changes = 1; return; }
  int count = sql_batch_split(s, n, batches, SQL_BATCH_LIMIT + 1);
  /* A run with too many batches does not start, so it changes nothing. */
  for (int i = 0; i < count; ++i) risk_batch(s, batches[i].start, batches[i].end, batches[i].line, out);
  free(batches);
}
