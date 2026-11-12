/* Formats T-SQL in DbVisualizer's default layout. See sql_format.h. */
#include "sql_format.h"
#include <stdlib.h>
#include <string.h>

#define NONE ((size_t)-1)
#define FRAME_LIMIT 64
#define BASE_LIMIT 256
#define OUTPUT_LIMIT (64u * 1024u * 1024u)

/* The T-SQL reserved keywords, sorted. They cannot be names without brackets or quotes, so uppercase is safe. */
static const char *const RESERVED[] = {
  "ADD", "ALL", "ALTER", "AND", "ANY", "AS", "ASC", "AUTHORIZATION", "BACKUP", "BEGIN", "BETWEEN", "BREAK", "BROWSE",
  "BULK", "BY", "CASCADE", "CASE", "CHECK", "CHECKPOINT", "CLOSE", "CLUSTERED", "COALESCE", "COLLATE", "COLUMN",
  "COMMIT", "COMPUTE", "CONSTRAINT", "CONTAINS", "CONTAINSTABLE", "CONTINUE", "CONVERT", "CREATE", "CROSS",
  "CURRENT", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "CURRENT_USER", "CURSOR", "DATABASE", "DBCC",
  "DEALLOCATE", "DECLARE", "DEFAULT", "DELETE", "DENY", "DESC", "DISK", "DISTINCT", "DISTRIBUTED", "DOUBLE", "DROP",
  "DUMP", "ELSE", "END", "ERRLVL", "ESCAPE", "EXCEPT", "EXEC", "EXECUTE", "EXISTS", "EXIT", "EXTERNAL", "FETCH",
  "FILE", "FILLFACTOR", "FOR", "FOREIGN", "FREETEXT", "FREETEXTTABLE", "FROM", "FULL", "FUNCTION", "GOTO", "GRANT",
  "GROUP", "HAVING", "HOLDLOCK", "IDENTITY", "IDENTITYCOL", "IDENTITY_INSERT", "IF", "IN", "INDEX", "INNER",
  "INSERT", "INTERSECT", "INTO", "IS", "JOIN", "KEY", "KILL", "LEFT", "LIKE", "LINENO", "LOAD", "MERGE", "NATIONAL",
  "NOCHECK", "NONCLUSTERED", "NOT", "NULL", "NULLIF", "OF", "OFF", "OFFSETS", "ON", "OPEN", "OPENDATASOURCE",
  "OPENQUERY", "OPENROWSET", "OPENXML", "OPTION", "OR", "ORDER", "OUTER", "OVER", "PERCENT", "PIVOT", "PLAN",
  "PRECISION", "PRIMARY", "PRINT", "PROC", "PROCEDURE", "PUBLIC", "RAISERROR", "READ", "READTEXT", "RECONFIGURE",
  "REFERENCES", "REPLICATION", "RESTORE", "RESTRICT", "RETURN", "REVERT", "REVOKE", "RIGHT", "ROLLBACK", "ROWCOUNT",
  "ROWGUIDCOL", "RULE", "SAVE", "SCHEMA", "SECURITYAUDIT", "SELECT", "SEMANTICKEYPHRASETABLE",
  "SEMANTICSIMILARITYDETAILSTABLE", "SEMANTICSIMILARITYTABLE", "SESSION_USER", "SET", "SETUSER", "SHUTDOWN", "SOME",
  "STATISTICS", "SYSTEM_USER", "TABLE", "TABLESAMPLE", "TEXTSIZE", "THEN", "TO", "TOP", "TRAN", "TRANSACTION",
  "TRIGGER", "TRUNCATE", "TRY_CONVERT", "TSEQUAL", "UNION", "UNIQUE", "UNPIVOT", "UPDATE", "UPDATETEXT", "USE",
  "USER", "VALUES", "VARYING", "VIEW", "WAITFOR", "WHEN", "WHERE", "WHILE", "WITH", "WITHIN", "WRITETEXT",
};

static int upper(int c) { return c >= 'a' && c <= 'z' ? c - 32 : c; }
static int word_char(unsigned char c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '@' ||
    c == '#' || c == '$' || c >= 0x80;
}
static int digit(unsigned char c) { return c >= '0' && c <= '9'; }
static int blank(unsigned char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == '\v'; }

/* Compares text with an uppercase word, ignoring the text's case. */
static int compare_word(const char *s, size_t n, const char *word) {
  size_t i = 0;
  for (; i < n && word[i]; ++i) {
    int a = upper((unsigned char)s[i]), b = (unsigned char)word[i];
    if (a != b) return a - b;
  }
  if (i < n) return 1;
  return word[i] ? -1 : 0;
}

static int reserved(const char *s, size_t n) {
  size_t low = 0, high = sizeof RESERVED / sizeof *RESERVED;
  while (low < high) {
    size_t mid = (low + high) / 2;
    int c = compare_word(s, n, RESERVED[mid]);
    if (c == 0) return 1;
    if (c < 0) high = mid; else low = mid + 1;
  }
  return 0;
}

/* Whether text holds an uppercase word, ignoring the text's case. */
static int contains(const char *s, size_t n, const char *word) {
  size_t w = strlen(word);
  for (size_t i = 0; i + w <= n; ++i) if (compare_word(s + i, w, word) == 0) return 1;
  return 0;
}

static int at_line_start(const char *t, size_t p) {
  while (p > 0 && (t[p - 1] == ' ' || t[p - 1] == '\t')) --p;
  return p == 0 || t[p - 1] == '\n';
}

/* The end of a GO line's text at p, or 0. The rules are sql_batch.c's. */
static size_t go_line(const char *t, size_t len, size_t p) {
  if (p + 2 > len || upper((unsigned char)t[p]) != 'G' || upper((unsigned char)t[p + 1]) != 'O') return 0;
  size_t i = p + 2, end = i;
  if (i < len && word_char((unsigned char)t[i])) return 0;
  if (!at_line_start(t, p)) return 0;
  while (i < len && (t[i] == ' ' || t[i] == '\t')) ++i;
  if (i < len && digit((unsigned char)t[i])) {
    while (i < len && digit((unsigned char)t[i])) ++i;
    if (i < len && word_char((unsigned char)t[i])) return 0;
    end = i;
    while (i < len && (t[i] == ' ' || t[i] == '\t')) ++i;
  }
  if (i + 1 < len && t[i] == '-' && t[i + 1] == '-') {
    while (i < len && t[i] != '\n' && t[i] != '\r') ++i;
    end = i;
  }
  if (i < len && t[i] != '\n' && t[i] != '\r') return 0;
  return end;
}

static size_t quoted_end(const char *t, size_t len, size_t i, char close) {
  while (i < len) {
    if (t[i] == close) {
      if (i + 1 < len && t[i + 1] == close) i += 2;
      else return i + 1;
    } else {
      ++i;
    }
  }
  return len;
}

int sql_format_token(const char *t, size_t len, size_t pos, size_t *start, size_t *end, SqlTokenKind *kind) {
  static const char *const pairs[] = { "<=", ">=", "<>", "!=", "!<", "!>", "+=", "-=", "*=", "/=", "%=", "&=", "|=",
    "^=", "::" };
  size_t i = pos, g;
  while (i < len && blank((unsigned char)t[i])) ++i;
  if (i >= len) return 0;
  *start = i;
  unsigned char c = (unsigned char)t[i];
  if ((c == 'g' || c == 'G') && (g = go_line(t, len, i))) { *end = g; *kind = SQL_TOKEN_GO; return 1; }
  if (c == '-' && i + 1 < len && t[i + 1] == '-') {
    while (i < len && t[i] != '\n' && t[i] != '\r') ++i;
    *end = i; *kind = SQL_TOKEN_LINE_COMMENT; return 1;
  }
  if (c == '/' && i + 1 < len && t[i + 1] == '*') {
    size_t depth = 0;
    while (i < len) {
      if (t[i] == '/' && i + 1 < len && t[i + 1] == '*') { ++depth; i += 2; }
      else if (t[i] == '*' && i + 1 < len && t[i + 1] == '/') { i += 2; if (--depth == 0) break; }
      else ++i;
    }
    *end = i; *kind = SQL_TOKEN_BLOCK_COMMENT; return 1;
  }
  if (c == '\'' || ((c == 'N' || c == 'n') && i + 1 < len && t[i + 1] == '\'')) {
    *end = quoted_end(t, len, i + (c == '\'' ? 1 : 2), '\''); *kind = SQL_TOKEN_STRING; return 1;
  }
  if (c == '[') { *end = quoted_end(t, len, i + 1, ']'); *kind = SQL_TOKEN_QUOTED; return 1; }
  if (c == '"') { *end = quoted_end(t, len, i + 1, '"'); *kind = SQL_TOKEN_QUOTED; return 1; }
  int after_name = i > 0 && (word_char((unsigned char)t[i - 1]) || t[i - 1] == ']' || t[i - 1] == '"' || t[i - 1] == ')');
  if (digit(c) || (c == '.' && i + 1 < len && digit((unsigned char)t[i + 1]) && !after_name)) {
    while (i < len && digit((unsigned char)t[i])) ++i;
    if (i < len && t[i] == '.') { ++i; while (i < len && digit((unsigned char)t[i])) ++i; }
    if (i < len && (t[i] == 'e' || t[i] == 'E')) {
      size_t j = i + 1;
      if (j < len && (t[j] == '+' || t[j] == '-')) ++j;
      if (j < len && digit((unsigned char)t[j])) { i = j; while (i < len && digit((unsigned char)t[i])) ++i; }
    }
    while (i < len && word_char((unsigned char)t[i])) ++i;
    *end = i; *kind = SQL_TOKEN_WORD; return 1;
  }
  if (word_char(c)) {
    while (i < len && word_char((unsigned char)t[i])) ++i;
    *end = i; *kind = SQL_TOKEN_WORD; return 1;
  }
  *end = i + 1;
  switch (c) {
  case '(': *kind = SQL_TOKEN_OPEN; return 1;
  case ')': *kind = SQL_TOKEN_CLOSE; return 1;
  case ',': *kind = SQL_TOKEN_COMMA; return 1;
  case '.': *kind = SQL_TOKEN_DOT; return 1;
  case ';': *kind = SQL_TOKEN_SEMICOLON; return 1;
  default: break;
  }
  *kind = SQL_TOKEN_OPERATOR;
  for (size_t p = 0; p < sizeof pairs / sizeof *pairs; ++p) {
    if (i + 1 < len && t[i] == pairs[p][0] && t[i + 1] == pairs[p][1]) { *end = i + 2; break; }
  }
  return 1;
}

/* off: the token is in a FORMAT_OFF region, or is one of its markers. */
typedef struct { size_t start, end; unsigned char kind, space_before, newline_before, off; } Tok;
typedef struct { char *p; size_t n, cap; int failed; } Buf;
typedef struct { const char *text; Tok *tok; size_t n; } Sql;

static void put(Buf *b, const char *s, size_t n) {
  if (b->failed || n == 0) return;
  if (b->n + n > OUTPUT_LIMIT) { b->failed = 1; return; }
  if (b->n + n + 1 > b->cap) {
    size_t cap = b->cap ? b->cap : 1024;
    while (cap < b->n + n + 1) cap *= 2;
    char *p = realloc(b->p, cap);
    if (!p) { b->failed = 1; return; }
    b->p = p; b->cap = cap;
  }
  memcpy(b->p + b->n, s, n);
  b->n += n;
  b->p[b->n] = 0;
}

/* A word token, uppercase when it is a reserved keyword or `force` is set. A word after a dot is a name, such as
 * an XML method, whose case can matter. */
static void put_token(Buf *b, const Sql *q, size_t k, int force) {
  const Tok *t = &q->tok[k];
  const char *s = q->text + t->start;
  size_t n = t->end - t->start;
  char word[40];
  if (t->kind == SQL_TOKEN_WORD && !t->off && n < sizeof word && (k == 0 || q->tok[k - 1].kind != SQL_TOKEN_DOT) &&
      (force || reserved(s, n))) {
    for (size_t i = 0; i < n; ++i) word[i] = (char)upper((unsigned char)s[i]);
    put(b, word, n);
  } else {
    put(b, s, n);
  }
}

static int is(const Sql *q, size_t k, size_t e, const char *word) {
  return k < e && q->tok[k].kind == SQL_TOKEN_WORD &&
    compare_word(q->text + q->tok[k].start, q->tok[k].end - q->tok[k].start, word) == 0;
}
static int is_any(const Sql *q, size_t k, const char *const *words) {
  for (; *words; ++words) if (is(q, k, q->n, *words)) return 1;
  return 0;
}
static int comment(const Tok *t) { return t->kind == SQL_TOKEN_LINE_COMMENT || t->kind == SQL_TOKEN_BLOCK_COMMENT; }
static int operator_is(const Sql *q, size_t k, const char *op) {
  const Tok *t = &q->tok[k];
  size_t n = strlen(op);
  return t->kind == SQL_TOKEN_OPERATOR && t->end - t->start == n && memcmp(q->text + t->start, op, n) == 0;
}
static size_t prev_sig(const Sql *q, size_t k) {
  while (k > 0) { --k; if (!comment(&q->tok[k])) return k; }
  return NONE;
}
static size_t next_sig(const Sql *q, size_t k) {
  for (++k; k < q->n; ++k) if (!comment(&q->tok[k])) return k;
  return NONE;
}

static const char *const DML[] = { "SELECT", "INSERT", "UPDATE", "DELETE", NULL };
static const char *const CHANGES[] = { "INSERT", "UPDATE", "DELETE", NULL };
/* After these words, a DML word names an action, as in a trigger or a permission, and starts nothing. */
static const char *const ACTION_CONTEXT[] = { "FOR", "AFTER", "OF", "ON", "GRANT", "DENY", "REVOKE", "BULK", NULL };
static const char *const SET_OPERATORS[] = { "UNION", "ALL", "EXCEPT", "INTERSECT", NULL };
static const char *const JOIN_KINDS[] = { "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", NULL };
/* Words that start another statement. */
static const char *const STARTERS[] = { "MERGE", "CREATE", "ALTER", "DROP", "DECLARE", "IF", "ELSE", "BEGIN", "END",
  "WHILE", "RETURN", "EXEC", "EXECUTE", "PRINT", "RAISERROR", "THROW", "TRUNCATE", "USE", "GRANT", "REVOKE", "DENY",
  "OPEN", "CLOSE", "DEALLOCATE", "BREAK", "CONTINUE", "GOTO", "WAITFOR", "COMMIT", "ROLLBACK", "SAVE", "BACKUP",
  "RESTORE", "DBCC", "KILL", "RECONFIGURE", "SHUTDOWN", "CHECKPOINT", "BULK", "READTEXT", "WRITETEXT", "UPDATETEXT",
  "REVERT", "SETUSER", NULL };

/* WITH starts a statement only as a common table expression: WITH name AS ( or WITH name (columns) AS (. */
static int cte_start(const Sql *q, size_t k) {
  size_t p = prev_sig(q, k), name = next_sig(q, k);
  if (p != NONE && q->tok[p].kind != SQL_TOKEN_SEMICOLON && q->tok[p].kind != SQL_TOKEN_GO &&
      !is(q, p, q->n, "BEGIN") && !is(q, p, q->n, "AS")) return 0;
  if (name == NONE || (q->tok[name].kind != SQL_TOKEN_WORD && q->tok[name].kind != SQL_TOKEN_QUOTED)) return 0;
  size_t after = next_sig(q, name);
  return after != NONE && (is(q, after, q->n, "AS") || q->tok[after].kind == SQL_TOKEN_OPEN);
}

/* The next statement that gets the layout, from token i. Other text stays as it is. */
static size_t find_start(const Sql *q, size_t i) {
  int depth = 0, merge = 0;
  for (size_t k = i; k < q->n; ++k) {
    unsigned char kind = q->tok[k].kind;
    if (q->tok[k].off) continue;
    if (kind == SQL_TOKEN_OPEN) ++depth;
    else if (kind == SQL_TOKEN_CLOSE) { if (depth > 0) --depth; }
    else if (kind == SQL_TOKEN_SEMICOLON || kind == SQL_TOKEN_GO) { depth = 0; merge = 0; }
    else if (kind == SQL_TOKEN_WORD && depth == 0 && !merge) {
      size_t p = prev_sig(q, k);
      if (p != NONE && q->tok[p].kind == SQL_TOKEN_DOT) continue;
      /* MERGE holds INSERT, UPDATE and DELETE actions, and it must end with a semicolon. */
      if (is(q, k, q->n, "MERGE")) { merge = 1; continue; }
      if (is_any(q, k, DML)) {
        if (p != NONE && (q->tok[p].kind == SQL_TOKEN_COMMA || is_any(q, p, ACTION_CONTEXT))) continue;
        size_t next = next_sig(q, k);
        if (is(q, k, q->n, "UPDATE") && next != NONE &&
            (q->tok[next].kind == SQL_TOKEN_OPEN || is(q, next, q->n, "STATISTICS"))) continue;
        return k;
      }
      if (is(q, k, q->n, "WITH") && cte_start(q, k)) return k;
    }
  }
  return q->n;
}

/* Comments before the next statement stay with it. */
static size_t trim_end(const Sql *q, size_t s, size_t e) {
  while (e > s + 1 && comment(&q->tok[e - 1])) --e;
  return e;
}

/* The end of the statement at s, exclusive. */
static size_t find_end(const Sql *q, size_t s) {
  int depth = 0, cases = 0, cte = is(q, s, q->n, "WITH"), seen_select = 0, seen_set = 0;
  size_t dml = cte ? NONE : s;
  for (size_t k = s + 1; k < q->n; ++k) {
    if (q->tok[k].off) return trim_end(q, s, k);
    switch (q->tok[k].kind) {
    case SQL_TOKEN_OPEN: ++depth; break;
    case SQL_TOKEN_CLOSE: if (depth == 0) return trim_end(q, s, k); --depth; break;
    case SQL_TOKEN_SEMICOLON: if (depth == 0) return k + 1; break;
    case SQL_TOKEN_GO: return trim_end(q, s, k);
    case SQL_TOKEN_WORD: {
      if (is(q, k, q->n, "CASE")) { ++cases; break; }
      if (is(q, k, q->n, "END") && cases > 0) { --cases; break; }
      if (depth > 0 || cases > 0) break;
      size_t p = prev_sig(q, k);
      if (p != NONE && q->tok[p].kind == SQL_TOKEN_DOT) break;
      if (is(q, k, q->n, "SELECT")) {
        if (p != NONE && is_any(q, p, SET_OPERATORS)) break;
        if (cte) { cte = 0; dml = k; break; }
        if (dml != NONE && is(q, dml, q->n, "INSERT") && !seen_select) { seen_select = 1; break; }
        return trim_end(q, s, k);
      }
      if (is_any(q, k, CHANGES)) {
        if (p != NONE && is_any(q, p, ACTION_CONTEXT)) break;
        if (cte) { cte = 0; dml = k; break; }
        return trim_end(q, s, k);
      }
      if (is(q, k, q->n, "SET")) {
        if (dml != NONE && is(q, dml, q->n, "UPDATE") && !seen_set) { seen_set = 1; break; }
        return trim_end(q, s, k);
      }
      if (is(q, k, q->n, "FETCH")) {
        if (p != NONE && (is(q, p, q->n, "ROWS") || is(q, p, q->n, "ROW"))) break;
        return trim_end(q, s, k);
      }
      /* A join hint: INNER MERGE JOIN. */
      if (is(q, k, q->n, "MERGE") && p != NONE && is_any(q, p, JOIN_KINDS)) break;
      if (is_any(q, k, STARTERS)) return trim_end(q, s, k);
      break;
    }
    default: break;
    }
  }
  return trim_end(q, s, q->n);
}

enum { FRAME_QUERY, FRAME_PAREN, FRAME_CASE };
enum { C_NONE, C_SELECT, C_FROM, C_WHERE, C_JOIN, C_ON, C_GROUP, C_HAVING, C_ORDER, C_INSERT, C_VALUES, C_UPDATE,
  C_SET, C_DELETE, C_INTO, C_WITH, C_SET_OPERATOR, C_LINE };
typedef struct { unsigned char kind, clause, between; int level; } Frame;

typedef struct {
  const Sql *q;
  Buf *out;
  const char *base, *indent, *eol;
  size_t base_len, indent_len, end;
  /* line_empty: the line holds only its indentation. pending: the level of a line that the next token starts. */
  int line_empty, line_level, pending, top, failed;
  size_t last, before_last;
  Frame frames[FRAME_LIMIT];
} Layout;

static void newline(Layout *l, int level) {
  if (level < 0) level = 0;
  if (level > FRAME_LIMIT) { l->failed = 1; return; }
  put(l->out, l->eol, strlen(l->eol));
  put(l->out, l->base, l->base_len);
  for (int i = 0; i < level; ++i) put(l->out, l->indent, l->indent_len);
  l->line_empty = 1;
  l->line_level = level;
}

static void break_line(Layout *l, int level) {
  l->pending = -1;
  if (!l->line_empty) newline(l, level);
}

static void push(Layout *l, unsigned char kind, int level) {
  if (l->top + 1 >= FRAME_LIMIT) { l->failed = 1; return; }
  Frame *f = &l->frames[++l->top];
  f->kind = kind; f->clause = C_NONE; f->between = 0; f->level = level;
}

/* A minus, plus or tilde after an operator, a parenthesis, a comma or a keyword is a sign. */
static int sign(const Layout *l) {
  if (l->before_last == NONE) return 1;
  const Tok *t = &l->q->tok[l->before_last];
  if (t->kind == SQL_TOKEN_OPERATOR || t->kind == SQL_TOKEN_OPEN || t->kind == SQL_TOKEN_COMMA) return 1;
  return t->kind == SQL_TOKEN_WORD && reserved(l->q->text + t->start, t->end - t->start);
}

static int needs_space(const Layout *l, size_t k) {
  const Sql *q = l->q;
  if (l->last == NONE) return 0;
  const Tok *a = &q->tok[l->last], *b = &q->tok[k];
  if (b->kind == SQL_TOKEN_COMMA || b->kind == SQL_TOKEN_SEMICOLON || b->kind == SQL_TOKEN_CLOSE) return 0;
  if (a->kind == SQL_TOKEN_OPEN || a->kind == SQL_TOKEN_DOT || b->kind == SQL_TOKEN_DOT) return 0;
  if (operator_is(q, l->last, "::") || operator_is(q, k, "::")) return 0;
  /* Tokens that the text joined stay joined where a space could matter: a call, a label or a sign. */
  if (!b->space_before) {
    if (b->kind == SQL_TOKEN_OPEN || operator_is(q, l->last, ":") || operator_is(q, k, ":") ||
        operator_is(q, l->last, "{") || operator_is(q, k, "}")) return 0;
    if ((operator_is(q, l->last, "-") || operator_is(q, l->last, "+") || operator_is(q, l->last, "~")) && sign(l))
      return 0;
  }
  return 1;
}

static void note(Layout *l, size_t k) {
  l->line_empty = 0;
  l->before_last = l->last;
  l->last = k;
}

static void place_comment(Layout *l, size_t k) {
  const Tok *t = &l->q->tok[k];
  int level = l->pending >= 0 ? l->pending : l->line_level;
  /* A block comment at a line break goes with the next item. A line comment ends its line. */
  if (t->kind == SQL_TOKEN_BLOCK_COMMENT && l->pending >= 0) {
    if (!l->line_empty) newline(l, level);
    l->pending = -1;
  } else if (t->newline_before && !l->line_empty) {
    newline(l, level);
    if (t->kind == SQL_TOKEN_BLOCK_COMMENT) l->pending = -1;
  } else if (!l->line_empty) {
    put(l->out, " ", 1);
  }
  put_token(l->out, l->q, k, 0);
  note(l, k);
  if (t->kind == SQL_TOKEN_LINE_COMMENT) l->pending = level;
}

static void place(Layout *l, size_t k, int force_upper) {
  const Tok *t = &l->q->tok[k];
  if (comment(t)) { place_comment(l, k); return; }
  if (l->pending >= 0) {
    if (!l->line_empty) newline(l, l->pending);
    l->pending = -1;
  } else if (!l->line_empty && needs_space(l, k)) {
    put(l->out, " ", 1);
  }
  put_token(l->out, l->q, k, force_upper);
  note(l, k);
}

/* The words of a join: [INNER | LEFT [OUTER] | RIGHT [OUTER] | FULL [OUTER] | CROSS] [hint] JOIN, or APPLY. */
static size_t join_words(const Sql *q, size_t k, size_t e) {
  size_t i = k;
  if (is(q, i, e, "CROSS")) return is(q, i + 1, e, "JOIN") || is(q, i + 1, e, "APPLY") ? 2 : 0;
  if (is(q, i, e, "OUTER")) return is(q, i + 1, e, "APPLY") ? 2 : 0;
  if (is(q, i, e, "INNER")) {
    ++i;
  } else if (is(q, i, e, "LEFT") || is(q, i, e, "RIGHT") || is(q, i, e, "FULL")) {
    ++i;
    if (is(q, i, e, "OUTER")) ++i;
  }
  if (is(q, i, e, "LOOP") || is(q, i, e, "HASH") || is(q, i, e, "MERGE") || is(q, i, e, "REMOTE")) ++i;
  return is(q, i, e, "JOIN") ? i - k + 1 : 0;
}

/* SELECT keeps ALL, DISTINCT and TOP (n) [PERCENT] [WITH TIES] on its line. */
static size_t select_modifiers(Layout *l, size_t k) {
  const Sql *q = l->q;
  size_t i = k, e = l->end;
  if (is(q, i, e, "ALL") || is(q, i, e, "DISTINCT")) place(l, i++, 0);
  if (!is(q, i, e, "TOP")) return i - k;
  place(l, i++, 0);
  if (i < e && q->tok[i].kind == SQL_TOKEN_OPEN) {
    int depth = 0;
    do {
      if (q->tok[i].kind == SQL_TOKEN_OPEN) ++depth;
      else if (q->tok[i].kind == SQL_TOKEN_CLOSE) --depth;
      place(l, i++, 0);
    } while (i < e && depth > 0);
  } else if (i < e && !comment(&q->tok[i])) {
    place(l, i++, 0);
  }
  if (is(q, i, e, "PERCENT")) place(l, i++, 0);
  if (is(q, i, e, "WITH") && is(q, i + 1, e, "TIES")) { place(l, i++, 0); place(l, i++, 0); }
  return i - k;
}

/* A main keyword at k: it starts a line at its query's level, and its content starts a line one level deeper.
 * Returns the tokens that it used, or 0. */
static size_t clause(Layout *l, size_t k, size_t s) {
  const Sql *q = l->q;
  size_t e = l->end, n = 0, p = prev_sig(q, k), next = next_sig(q, k);
  Frame *f = &l->frames[l->top];
  int kind = C_NONE, content = 1, force = 0;
  if (p != NONE && q->tok[p].kind == SQL_TOKEN_DOT) return 0;
  if (is(q, k, e, "SELECT")) { n = 1; kind = C_SELECT; }
  else if (is(q, k, e, "FROM")) {
    /* IS [NOT] DISTINCT FROM compares values. */
    size_t before = p != NONE ? prev_sig(q, p) : NONE;
    if (!(p != NONE && is(q, p, e, "DISTINCT") && before != NONE && (is(q, before, e, "IS") || is(q, before, e, "NOT")))) {
      n = 1; kind = C_FROM;
    }
  }
  else if (is(q, k, e, "WHERE")) { n = 1; kind = C_WHERE; }
  else if (is(q, k, e, "HAVING")) { n = 1; kind = C_HAVING; }
  else if (is(q, k, e, "GROUP") && is(q, k + 1, e, "BY")) { n = 2; kind = C_GROUP; }
  else if (is(q, k, e, "ORDER") && is(q, k + 1, e, "BY")) { n = 2; kind = C_ORDER; }
  else if (is(q, k, e, "VALUES")) { if (!(p != NONE && is(q, p, e, "DEFAULT"))) { n = 1; kind = C_VALUES; } }
  else if (is(q, k, e, "SET")) { n = 1; kind = C_SET; }
  else if (is(q, k, e, "INTO") && f->clause == C_SELECT) { n = 1; kind = C_INTO; }
  else if (is(q, k, e, "INSERT")) { n = is(q, k + 1, e, "INTO") ? 2 : 1; kind = C_INSERT; }
  else if (is(q, k, e, "UPDATE")) { n = 1; kind = C_UPDATE; }
  else if (is(q, k, e, "DELETE")) { n = is(q, k + 1, e, "FROM") ? 2 : 1; kind = C_DELETE; }
  else if ((n = join_words(q, k, e)) != 0) { kind = C_JOIN; force = 1; }
  else if (is(q, k, e, "ON") && f->clause == C_JOIN) { n = 1; kind = C_ON; }
  else if (is(q, k, e, "UNION")) { n = is(q, k + 1, e, "ALL") ? 2 : 1; kind = C_SET_OPERATOR; content = 0; }
  else if (is(q, k, e, "EXCEPT") || is(q, k, e, "INTERSECT")) { n = 1; kind = C_SET_OPERATOR; content = 0; }
  else if (is(q, k, e, "WITH") && k == s) { n = 1; kind = C_WITH; content = 0; }
  else if (is(q, k, e, "OFFSET") && f->clause == C_ORDER && p != NONE && !is(q, p, e, "BY") &&
           q->tok[p].kind != SQL_TOKEN_COMMA) { n = 1; kind = C_LINE; content = 0; }
  else if (is(q, k, e, "OPTION") && next != NONE && q->tok[next].kind == SQL_TOKEN_OPEN) { n = 1; kind = C_LINE; content = 0; }
  else if (is(q, k, e, "FOR") && (is(q, k + 1, e, "XML") || is(q, k + 1, e, "JSON") || is(q, k + 1, e, "BROWSE"))) {
    n = 1; kind = C_LINE; content = 0;
  }
  if (!n) return 0;
  if (k != s) break_line(l, f->level);
  for (size_t i = 0; i < n; ++i) place(l, k + i, force);
  if (kind == C_SELECT) n += select_modifiers(l, k + 1);
  f->clause = (unsigned char)kind;
  f->between = 0;
  if (content) l->pending = f->level + 1;
  return n;
}

static void layout_statement(Layout *l, size_t s) {
  const Sql *q = l->q;
  size_t e = l->end;
  for (size_t k = s; k < e && !l->failed && !l->out->failed;) {
    Frame *f = &l->frames[l->top];
    switch (q->tok[k].kind) {
    case SQL_TOKEN_WORD:
      if (f->kind == FRAME_QUERY) {
        size_t used = clause(l, k, s);
        if (used) { k += used; continue; }
        if (is(q, k, e, "AND") && f->between) { f->between = 0; place(l, k++, 0); continue; }
        if ((is(q, k, e, "AND") || is(q, k, e, "OR")) &&
            (f->clause == C_WHERE || f->clause == C_ON || f->clause == C_HAVING)) {
          break_line(l, f->level);
          place(l, k++, 0);
          continue;
        }
        if (is(q, k, e, "BETWEEN")) f->between = 1;
      } else if (f->kind == FRAME_CASE) {
        if (is(q, k, e, "WHEN") || is(q, k, e, "ELSE")) { break_line(l, f->level + 1); place(l, k++, 0); continue; }
        if (is(q, k, e, "END")) { break_line(l, f->level); place(l, k++, 0); --l->top; continue; }
      }
      place(l, k, 0);
      if (is(q, k, e, "CASE")) push(l, FRAME_CASE, l->line_level);
      ++k;
      break;
    case SQL_TOKEN_OPEN: {
      size_t next = next_sig(q, k);
      place(l, k++, 0);
      if (next != NONE && next < e && is(q, next, e, "SELECT")) push(l, FRAME_QUERY, l->line_level + 1);
      else push(l, FRAME_PAREN, l->line_level);
      break;
    }
    case SQL_TOKEN_CLOSE:
      while (l->top > 0 && l->frames[l->top].kind == FRAME_CASE) --l->top;
      if (l->top > 0 && l->frames[l->top].kind == FRAME_QUERY) break_line(l, l->frames[l->top].level - 1);
      place(l, k++, 0);
      if (l->top > 0) --l->top;
      break;
    case SQL_TOKEN_COMMA:
      place(l, k++, 0);
      if (f->kind == FRAME_QUERY && f->clause != C_NONE && f->clause != C_LINE && f->clause != C_SET_OPERATOR)
        l->pending = f->clause == C_WITH ? f->level : f->level + 1;
      break;
    default:
      place(l, k++, 0);
      break;
    }
  }
}

/* Whether the output has the same tokens as the statement. Only the case of a word can differ. */
static int same_tokens(const Sql *q, size_t s, size_t e, const char *o, size_t on) {
  size_t pos = 0, a, b;
  SqlTokenKind kind;
  for (size_t i = s; i < e; ++i) {
    const Tok *t = &q->tok[i];
    size_t n = t->end - t->start;
    if (!sql_format_token(o, on, pos, &a, &b, &kind) || (unsigned char)kind != t->kind || b - a != n) return 0;
    if (memcmp(o + a, q->text + t->start, n) != 0) {
      if (kind != SQL_TOKEN_WORD) return 0;
      for (size_t j = 0; j < n; ++j) {
        if (upper((unsigned char)o[a + j]) != upper((unsigned char)q->text[t->start + j])) return 0;
      }
    }
    pos = b;
  }
  return !sql_format_token(o, on, pos, &a, &b, &kind);
}

/* Copies tokens i to e and the text between them, with reserved keywords in uppercase. */
static void copy_tokens(Buf *out, const Sql *q, size_t i, size_t e, size_t *pos) {
  for (size_t k = i; k < e; ++k) {
    put(out, q->text + *pos, q->tok[k].start - *pos);
    put_token(out, q, k, 0);
    *pos = q->tok[k].end;
  }
}

/* The statement's lines start with the indentation of the output line where it starts. */
static int format_statement(Buf *out, const Sql *q, size_t s, size_t e, const char *indent, size_t indent_len,
  const char *eol, char *base, size_t *base_len) {
  size_t line = out->n, n = 0;
  while (line > 0 && out->p[line - 1] != '\n') --line;
  while (line + n < out->n && (out->p[line + n] == ' ' || out->p[line + n] == '\t')) ++n;
  if (n > BASE_LIMIT) return 0;
  memcpy(base, out->p + line, n);
  *base_len = n;
  Layout *l = calloc(1, sizeof *l);
  if (!l) return 0;
  l->q = q; l->out = out; l->base = base; l->base_len = n; l->indent = indent;
  l->indent_len = indent_len; l->eol = eol; l->end = e; l->pending = -1; l->last = NONE; l->before_last = NONE;
  l->line_empty = 1;
  for (size_t i = out->n; i > 0 && out->p[i - 1] != '\n'; --i) {
    if (out->p[i - 1] != ' ' && out->p[i - 1] != '\t') { l->line_empty = 0; break; }
  }
  l->frames[0].kind = FRAME_QUERY;
  size_t start = out->n;
  layout_statement(l, s);
  int ok = !l->failed && !out->failed && same_tokens(q, s, e, out->p + start, out->n - start);
  free(l);
  if (!ok && !out->failed) out->n = start;
  return ok;
}

int sql_format(const char *text, size_t length, const char *indent, size_t indent_length, char **out,
  size_t *out_length) {
  if (length > SQL_FORMAT_LIMIT || indent_length > 16) return 0;
  Sql q = { text, NULL, 0 };
  size_t cap = 0, pos = 0, s, e;
  SqlTokenKind kind;
  int off = 0;
  const char *eol = "\n";
  for (size_t i = 0; i + 1 < length; ++i) if (text[i] == '\r' && text[i + 1] == '\n') { eol = "\r\n"; break; }
  while (sql_format_token(text, length, pos, &s, &e, &kind)) {
    if (q.n == cap) {
      cap = cap ? cap * 2 : 256;
      Tok *tok = realloc(q.tok, cap * sizeof *tok);
      if (!tok) { free(q.tok); return 0; }
      q.tok = tok;
    }
    Tok *t = &q.tok[q.n++];
    t->start = s; t->end = e; t->kind = (unsigned char)kind; t->space_before = s > pos; t->newline_before = 0;
    for (size_t i = pos; i < s; ++i) if (text[i] == '\n') { t->newline_before = 1; break; }
    if (comment(t) && !off && contains(text + s, e - s, "FORMAT_OFF")) off = 1;
    t->off = (unsigned char)off;
    if (comment(t) && off && contains(text + s, e - s, "FORMAT_ON")) off = 0;
    pos = e;
  }
  Buf b = { NULL, 0, 0, 0 };
  char base[BASE_LIMIT];
  size_t base_len = 0, formatted_end = NONE;
  pos = 0;
  for (size_t i = 0; i < q.n && !b.failed;) {
    size_t start = find_start(&q, i);
    copy_tokens(&b, &q, i, start, &pos);
    if (start >= q.n) break;
    size_t end = find_end(&q, start);
    /* A statement right after a formatted statement on its line starts a line. */
    if (start == i && formatted_end == b.n && !memchr(text + pos, '\n', q.tok[start].start - pos)) {
      put(&b, eol, strlen(eol));
      put(&b, base, base_len);
    } else {
      put(&b, text + pos, q.tok[start].start - pos);
    }
    pos = q.tok[start].start;
    if (format_statement(&b, &q, start, end, indent, indent_length, eol, base, &base_len)) {
      pos = q.tok[end - 1].end;
      formatted_end = b.n;
    } else {
      copy_tokens(&b, &q, start, end, &pos);
    }
    i = end;
  }
  put(&b, text + pos, length - pos);
  free(q.tok);
  if (b.failed) { free(b.p); return 0; }
  if (!b.p) {
    b.p = malloc(1);
    if (!b.p) return 0;
    b.p[0] = 0;
  }
  *out = b.p;
  *out_length = b.n;
  return 1;
}
