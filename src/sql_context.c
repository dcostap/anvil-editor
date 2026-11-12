/* The query-context slice follows DbVisualizer's token/context/provider split.
 * It supports SELECT sources and joins, the targets and sources of UPDATE,
 * DELETE, INSERT and MERGE, CTEs, derived tables, temporary tables and table
 * variables. Unsupported scopes return no candidates.
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
static int object_context(const char *s, Token *ts, size_t first, size_t last, size_t caret, SqlContext *out) {
  for (size_t i=first; i<last; ++i) {
    const char *kind=NULL;
    if (word(s,ts[i],"EXEC") || word(s,ts[i],"EXECUTE")) kind="procedure";
    else if (word(s,ts[i],"UPDATE") || word(s,ts[i],"INTO") || word(s,ts[i],"REFERENCES")) kind="table";
    else if (i>first && word(s,ts[i-1],"DELETE") && word(s,ts[i],"FROM")) kind="table";
    else if (i>first && (word(s,ts[i-1],"CREATE") || word(s,ts[i-1],"ALTER"))) {
      if (word(s,ts[i],"TABLE")) kind="table";
      else if (word(s,ts[i],"VIEW")) kind="view";
      else if (word(s,ts[i],"PROC") || word(s,ts[i],"PROCEDURE")) kind="procedure";
      else if (word(s,ts[i],"FUNCTION")) kind="function";
    }
    if (!kind || caret<=ts[i].end) continue;
    size_t target=i+1;
    if (target<last && !is_name(ts[target])) continue;
    if (target<last && target+1<last && ts[target+1].kind=='.') {
      if (!name(s,ts[target],ts[target].end,out->qualifier)) return -1;
      target+=2;
      if (target<last && (!is_name(ts[target]) || (target+1<last && ts[target+1].kind=='.'))) {
        out->qualifier[0]=0; continue;
      }
    }
    if (target<last && caret>ts[target].end) { out->qualifier[0]=0; continue; }
    /* Names with three parts require a cross-database catalog. */
    if (target>i+1 && caret<ts[target-1].end) { out->qualifier[0]=0; continue; }
    out->mode=SQL_CONTEXT_OBJECT;
    strcpy(out->object_kind,kind);
    if (target<last && caret>=ts[target].start) {
      out->start=ts[target].start; out->end=ts[target].end;
      if (!name(s,ts[target],caret,out->prefix)) return -1;
    }
    return 1;
  }
  return 0;
}
/* The token after a SELECT's DISTINCT, ALL and TOP parts. */
static size_t projection_first(const char *s, Token *ts, size_t begin, size_t target) {
  size_t i=begin+1;
  if (i<target && (word(s,ts[i],"DISTINCT") || word(s,ts[i],"ALL"))) ++i;
  if (i<target && word(s,ts[i],"TOP")) {
    ++i;
    if (i<target && ts[i].kind=='(') {
      int depth=ts[i++].depth;
      while (i<target && !(ts[i].kind==')' && ts[i].depth==depth)) ++i;
      if (i==target) return 0;
      ++i;
    } else if (i<target) ++i;
    if (i<target && word(s,ts[i],"PERCENT")) ++i;
    if (i+1<target && word(s,ts[i],"WITH") && word(s,ts[i+1],"TIES")) i+=2;
  }
  return i;
}
static int projection_start(const char *s, Token *ts, size_t begin, size_t target) {
  if (target>begin && ts[target-1].kind==',') return 1;
  return projection_first(s,ts,begin,target)==target;
}

/* The closing parenthesis of the one at open, or last when it is not closed. */
static size_t closing(Token *ts, size_t open, size_t last) {
  for (size_t i=open+1; i<last; ++i) if (ts[i].kind==')' && ts[i].depth==ts[open].depth) return i;
  return last;
}
static int same_name(const char *a, const char *b) {
  for (; *a && *b; ++a, ++b) if (toupper((unsigned char)*a)!=toupper((unsigned char)*b)) return 0;
  return *a==*b;
}
static SqlLocal *add_local(const char *s, Token t, int kind, SqlContext *out) {
  if (!out->locals && !(out->locals=calloc(SQL_CONTEXT_LOCALS,sizeof(*out->locals)))) return NULL;
  if (out->local_count==SQL_CONTEXT_LOCALS) return NULL;
  SqlLocal *local=&out->locals[out->local_count];
  memset(local,0,sizeof(*local));
  if (!name(s,t,t.end,local->name)) return NULL;
  /* Within one kind, the first definition of a name wins. */
  for (size_t i=0; i<out->local_count; ++i)
    if (out->locals[i].kind==kind && kind!=SQL_LOCAL_DERIVED && same_name(out->locals[i].name,local->name)) return NULL;
  local->kind=kind; local->first=out->column_count;
  ++out->local_count;
  return local;
}
static void add_column(const char *s, Token t, SqlLocal *local, SqlContext *out) {
  if (out->column_count==out->column_capacity) {
    size_t capacity=out->column_capacity ? out->column_capacity*2 : 64;
    if (capacity>SQL_CONTEXT_COLUMNS) capacity=SQL_CONTEXT_COLUMNS;
    void *grown=capacity>out->column_capacity ? realloc(out->columns,capacity*sizeof(*out->columns)) : NULL;
    if (!grown) { local->star=1; return; }
    out->columns=grown; out->column_capacity=capacity;
  }
  if (!name(s,t,t.end,out->columns[out->column_count])) { local->star=1; return; }
  ++out->column_count; ++local->count;
}
/* A column list, such as a CTE's `(a, b)` or a table's column definitions: the
 * first name of each item at the list's depth. Table constraints add nothing. */
static void add_column_list(const char *s, Token *ts, size_t open, size_t close, SqlLocal *local, SqlContext *out) {
  static const char *constraints[]={ "CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN", "INDEX", "PERIOD", NULL };
  int item=1;
  for (size_t i=open+1; i<close; ++i) {
    if (ts[i].depth!=ts[open].depth+1) continue;
    if (ts[i].kind==',') { item=1; continue; }
    if (!item) continue;
    item=0;
    int constraint=0;
    for (int k=0; constraints[k]; ++k) if (word(s,ts[i],constraints[k])) constraint=1;
    if (is_name(ts[i]) && !constraint) add_column(s,ts[i],local,out);
  }
}
/* One SELECT column: `alias = expression`, `expression [AS] alias`, or a column
 * with its own name. An expression without a name adds nothing. */
static void add_projection_item(const char *s, Token *ts, size_t a, size_t b, SqlLocal *local, SqlContext *out) {
  if (b-a>=2 && is_name(ts[a]) && ts[a+1].kind=='=') { add_column(s,ts[a],local,out); return; }
  static const char *expression_words[]={ "END", "NULL", "THEN", "ELSE", "AND", "OR", "NOT", "IS", NULL };
  Token last=ts[b-1];
  if (last.kind=='*') { local->star=1; return; }
  if (!is_name(last) || reserved(s,last) || (last.kind==IDENT && isdigit((unsigned char)s[last.start]))) return;
  for (int k=0; expression_words[k]; ++k) if (word(s,last,expression_words[k])) return;
  if (b-a==1) { add_column(s,last,local,out); return; }
  Token prev=ts[b-2];
  if (word(s,prev,"AS") || prev.kind=='.' || prev.kind==')' || prev.kind==LITERAL || (is_name(prev) && !reserved(s,prev)))
    add_column(s,last,local,out);
}
static int projection_end(const char *s, Token t) {
  static const char *words[]={ "FROM", "INTO", "WHERE", "GROUP", "ORDER", "HAVING", "UNION", "EXCEPT",
    "INTERSECT", "OPTION", "FOR", NULL };
  for (int i=0; words[i]; ++i) if (word(s,t,words[i])) return 1;
  return 0;
}
/* The names of the columns of the SELECT at select, which ends before end. */
static void add_projection(const char *s, Token *ts, size_t select, size_t end, SqlLocal *local, SqlContext *out) {
  int depth=ts[select].depth;
  size_t a=projection_first(s,ts,select,end);
  for (size_t i=a; i<=end; ++i) {
    int stop=i==end || ts[i].depth<depth || (ts[i].depth==depth && (ts[i].kind==',' || projection_end(s,ts[i])));
    if (!stop) continue;
    if (i>a) add_projection_item(s,ts,a,i,local,out);
    if (i==end || ts[i].kind!=',' || ts[i].depth!=depth) return;
    a=i+1;
  }
}
/* `WITH name [(columns)] AS (SELECT ...) [, ...]`. WITH (NOLOCK), WITH TIES and
 * other WITH clauses do not have this shape. */
static void add_ctes(const char *s, Token *ts, size_t first, size_t last, SqlContext *out) {
  for (size_t w=first; w<last; ++w) {
    if (!word(s,ts[w],"WITH")) continue;
    size_t i=w+1;
    while (i<last && is_name(ts[i]) && !reserved(s,ts[i])) {
      size_t at=i++, list=0, list_end=0;
      if (i<last && ts[i].kind=='(') { list=i; list_end=closing(ts,i,last); i=list_end+1; }
      if (i>=last || !word(s,ts[i],"AS") || i+1>=last || ts[i+1].kind!='(') break;
      size_t open=i+1, close=closing(ts,open,last);
      if (close==last) break;
      SqlLocal *local=add_local(s,ts[at],SQL_LOCAL_CTE,out);
      if (local) {
        if (list && list_end<last) add_column_list(s,ts,list,list_end,local,out);
        else if (open+1<close && word(s,ts[open+1],"SELECT")) add_projection(s,ts,open+1,close,local,out);
        else local->star=1;
      }
      i=close+1;
      if (i>=last || ts[i].kind!=',') break;
      ++i;
    }
  }
}
/* `CREATE TABLE #name (...)`, `DECLARE @name [AS] TABLE (...)` and
 * `SELECT ... INTO #name`, anywhere in the text. */
static void add_temporary_tables(const char *s, Token *ts, size_t n, SqlContext *out) {
  for (size_t i=0; i+1<n; ++i) {
    if (word(s,ts[i],"CREATE") && word(s,ts[i+1],"TABLE") && i+3<n && ts[i+2].kind==IDENT
        && s[ts[i+2].start]=='#' && ts[i+3].kind=='(') {
      SqlLocal *local=add_local(s,ts[i+2],SQL_LOCAL_TEMP,out);
      if (local) add_column_list(s,ts,i+3,closing(ts,i+3,n),local,out);
    } else if (word(s,ts[i],"DECLARE") && ts[i+1].kind==IDENT && s[ts[i+1].start]=='@') {
      size_t t=i+2;
      if (t<n && word(s,ts[t],"AS")) ++t;
      if (t+1<n && word(s,ts[t],"TABLE") && ts[t+1].kind=='(') {
        SqlLocal *local=add_local(s,ts[i+1],SQL_LOCAL_VARIABLE,out);
        if (local) add_column_list(s,ts,t+1,closing(ts,t+1,n),local,out);
      }
    } else if (word(s,ts[i],"INTO") && ts[i+1].kind==IDENT && s[ts[i+1].start]=='#'
        && !(i && word(s,ts[i-1],"INSERT"))) {
      size_t select=i;
      while (select-- > 0)
        if (ts[select].depth==ts[i].depth && (word(s,ts[select],"SELECT") || ts[select].kind==';')) break;
      if (select<i && word(s,ts[select],"SELECT")) {
        SqlLocal *local=add_local(s,ts[i+1],SQL_LOCAL_TEMP,out);
        if (local) add_projection(s,ts,select,i,local,out);
      }
    }
  }
}
/* An UPDATE, DELETE, INSERT or MERGE that starts a statement. A MERGE action
 * (THEN UPDATE), a trigger event (AFTER INSERT, ON DELETE), a permission and
 * the UPDATE() function do not. */
static int statement_start(const char *s, Token *ts, size_t i, size_t first, size_t n) {
  if (!word(s,ts[i],"UPDATE") && !word(s,ts[i],"DELETE") && !word(s,ts[i],"INSERT") && !word(s,ts[i],"MERGE")) return 0;
  if (i+1<n && ts[i+1].kind=='(') return 0;
  if (i>first) {
    static const char *before[]={ "THEN", "ON", "OF", "FOR", "AFTER", "GRANT", "DENY", "REVOKE", NULL };
    if (ts[i-1].kind==',') return 0;
    for (int k=0; before[k]; ++k) if (word(s,ts[i-1],before[k])) return 0;
  }
  return 1;
}
/* A name without a schema can mean a CTE, a temporary table or a table variable. */
static void link_local(SqlSource *src, SqlContext *out) {
  if (src->schema[0]) return;
  for (size_t k=0; k<out->local_count; ++k)
    if (out->locals[k].kind!=SQL_LOCAL_DERIVED && same_name(out->locals[k].name,src->name)) { src->local=k+1; return; }
}
/* Reads `[schema.]name` at ts[*at] and leaves *at on its last token. Returns 1,
 * 0 when a name is too long, or -1 for a name with more parts. */
static int read_name(const char *s, Token *ts, size_t *at, size_t end, SqlSource *src) {
  size_t i=*at;
  if (!name(s,ts[i],ts[i].end,src->name)) return 0;
  if (i+2<end && ts[i+1].kind=='.' && is_name(ts[i+2])) {
    memcpy(src->schema,src->name,sizeof(src->schema));
    i+=2;
    if (!name(s,ts[i],ts[i].end,src->name)) return 0;
  }
  *at=i;
  return i+1<end && ts[i+1].kind=='.' ? -1 : 1;
}
/* Sets the mode at the caret and reads the sources of a scope's FROM, JOIN and
 * USING lists. Tokens deeper than the scope belong to subqueries and calls.
 * Returns 0 on failure. Unsupported sources leave no context. */
static int read_scope(const char *s, Token *ts, size_t begin, size_t end, int scope, size_t caret, SqlContext *out) {
  static const char *column_words[]={ "WHERE", "ON", "GROUP", "ORDER", "HAVING", "SET", "OUTPUT", "WHEN", "THEN", NULL };
  int source_list=0, expect_source=0;
  for (size_t i=begin; i<end; ++i) {
    Token t=ts[i];
    if (t.depth!=scope) continue;
    if (word(s,t,"FROM") || word(s,t,"JOIN") || word(s,t,"USING")) {
      source_list=expect_source=1;
      if (t.end<=caret) out->mode=SQL_CONTEXT_TABLE;
      continue;
    }
    int column_word=0;
    for (int k=0; column_words[k]; ++k) if (word(s,t,column_words[k])) column_word=1;
    if (column_word || word(s,t,"VALUES")) {
      source_list=expect_source=0;
      if (t.end<=caret) out->mode=column_word ? SQL_CONTEXT_COLUMN : SQL_CONTEXT_NONE;
      continue;
    }
    if (t.kind==',' && source_list) {
      expect_source=1;
      if (t.end<=caret) out->mode=SQL_CONTEXT_TABLE;
      continue;
    }
    if (!expect_source) continue;
    if (t.kind=='(' && i+1<end && word(s,ts[i+1],"SELECT")) {
      /* A derived table: its columns are the inner SELECT's, or its column list. */
      size_t close=closing(ts,i,end);
      if (close==end) { out->mode=SQL_CONTEXT_NONE; out->count=0; return 1; }
      size_t at=close+1;
      if (at<end && word(s,ts[at],"AS")) ++at;
      if (at>=end || !is_name(ts[at]) || reserved(s,ts[at])) { out->mode=SQL_CONTEXT_NONE; out->count=0; return 1; }
      SqlLocal *local=out->count<SQL_CONTEXT_SOURCES ? add_local(s,ts[at],SQL_LOCAL_DERIVED,out) : NULL;
      if (!local) { out->mode=SQL_CONTEXT_NONE; out->count=0; return 1; }
      if (at+1<end && ts[at+1].kind=='(') {
        size_t list_end=closing(ts,at+1,end);
        add_column_list(s,ts,at+1,list_end,local,out);
        at=list_end;
      } else add_projection(s,ts,i+1,close,local,out);
      SqlSource src={0};
      memcpy(src.name,local->name,sizeof(src.name));
      memcpy(src.alias,local->name,sizeof(src.alias));
      src.local=out->local_count;
      out->sources[out->count++]=src;
      expect_source=0;
      i=at;
      continue;
    }
    if (!is_name(t) || reserved(s,t)) {
      /* Table-valued expressions need more metadata. */
      out->mode=SQL_CONTEXT_NONE; out->count=0; return 1;
    }
    SqlSource src={0};
    int read=read_name(s,ts,&i,end,&src);
    if (!read) return 0;
    if (read<0 || (i+1<end && ts[i+1].kind=='(')) { out->mode=SQL_CONTEXT_NONE; out->count=0; return 1; }
    if (i+1<end && word(s,ts[i+1],"AS")) ++i;
    if (i+1<end && is_name(ts[i+1]) && !reserved(s,ts[i+1])) {
      ++i;
      if (!name(s,ts[i],ts[i].end,src.alias)) return 0;
    }
    if (out->count==SQL_CONTEXT_SOURCES) return 0;
    link_local(&src,out);
    out->sources[out->count++]=src;
    expect_source=0;
  }
  return 1;
}
/* The target of an UPDATE, DELETE, INSERT or MERGE at begin is its first
 * source. An INSERT column list offers only the target's columns. */
static int read_statement(const char *s, Token *ts, size_t begin, size_t end, size_t caret, SqlContext *out) {
  int merge=word(s,ts[begin],"MERGE"), insert=word(s,ts[begin],"INSERT");
  int scope=ts[begin].depth;
  size_t i=begin+1;
  if (i<end && word(s,ts[i],"TOP")) {
    ++i;
    if (i<end && ts[i].kind=='(') i=closing(ts,i,end)+1;
    if (i<end && word(s,ts[i],"PERCENT")) ++i;
  }
  if (i<end && (merge || insert) && word(s,ts[i],"INTO")) ++i;
  /* DELETE FROM reads its target as a FROM source. */
  if (i<end && !word(s,ts[i],"FROM")) {
    if (!is_name(ts[i])) return 1;
    SqlSource target={0};
    int read=read_name(s,ts,&i,end,&target);
    if (read<=0) return read==0 ? 0 : 1;
    ++i;
    if (merge) {
      if (i<end && word(s,ts[i],"AS")) ++i;
      if (i<end && is_name(ts[i]) && !reserved(s,ts[i]) && !word(s,ts[i],"USING")) {
        if (!name(s,ts[i],ts[i].end,target.alias)) return 0;
        ++i;
      }
    }
    link_local(&target,out);
    out->sources[out->count++]=target;
    /* INSERT [INTO] target (columns), or MERGE's WHEN NOT MATCHED THEN INSERT (columns). */
    for (size_t k=insert ? i : begin; (insert || merge) && k<end; ++k) {
      if (ts[k].depth!=scope) continue;
      size_t open=insert ? k : k+1;
      if (!insert && !(word(s,ts[k],"INSERT") && k>begin && word(s,ts[k-1],"THEN"))) continue;
      if (open<end && ts[open].kind=='(') {
        size_t close=closing(ts,open,end);
        if (caret>ts[open].start && (close==end || caret<=ts[close].start)) { out->mode=SQL_CONTEXT_COLUMN; return 1; }
      }
      if (insert) break;
    }
  }
  if (!read_scope(s,ts,i,end,scope,caret,out)) return 0;
  /* UPDATE c ... FROM sales.customers c names its target by a FROM alias. */
  if (!merge && out->count>1 && !out->sources[0].schema[0])
    for (size_t k=1; k<out->count; ++k) {
      const char *other=out->sources[k].alias[0] ? out->sources[k].alias : out->sources[k].name;
      if (same_name(other,out->sources[0].name)) {
        memmove(out->sources,out->sources+1,(out->count-1)*sizeof(*out->sources));
        --out->count;
        break;
      }
    }
  return 1;
}
void sql_context_free(SqlContext *out) {
  free(out->locals); free(out->columns);
  out->locals=NULL; out->columns=NULL;
  out->local_count=out->column_count=out->column_capacity=0;
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
  add_ctes(s,ts,first,last,out);
  add_temporary_tables(s,ts,n,out);
  int object = object_context(s,ts,first,last,caret,out);
  if (object) { if (object<0) ok=0; goto done; }
  /* Select the innermost SELECT scope that contains the caret. Parentheses
   * without SELECT (function arguments) do not make a new query scope. The
   * nearest UPDATE, DELETE, INSERT or MERGE before the caret wins over a
   * SELECT before it, because statements need no semicolon. */
  size_t scopes[64], scope_count = 0, statement = n;
  for (size_t i = first; i < last && ts[i].start < caret; ++i) {
    while (scope_count && ts[scopes[scope_count - 1]].depth > ts[i].depth) --scope_count;
    if (statement < n && ts[statement].depth > ts[i].depth) statement = n;
    if (statement_start(s, ts, i, first, n)) statement = i;
    int select = word(s, ts[i], "SELECT");
    int separator = word(s, ts[i], "UNION") || word(s, ts[i], "EXCEPT") || word(s, ts[i], "INTERSECT");
    if ((select || separator) && scope_count && ts[scopes[scope_count - 1]].depth == ts[i].depth) --scope_count;
    if (select) {
      if (scope_count == sizeof(scopes) / sizeof(scopes[0])) { ok = 0; goto done; }
      scopes[scope_count++] = i;
    }
  }
  int dml = statement < n && (!scope_count || scopes[scope_count - 1] < statement);
  if (!dml && !scope_count) goto done;
  size_t begin = dml ? statement : scopes[scope_count - 1], end = last;
  int scope = ts[begin].depth;
  for (size_t i = begin + 1; i < last; ++i) {
    if (ts[i].depth < scope || (ts[i].depth == scope && (statement_start(s, ts, i, first, n) || (dml ? word(s, ts[i], "SELECT")
        : (word(s, ts[i], "UNION") || word(s, ts[i], "EXCEPT") || word(s, ts[i], "INTERSECT")))))) {
      end = i; break;
    }
  }
  size_t current = n, prev = n;
  for (size_t i = begin; i < end; ++i) {
    if ((is_name(ts[i]) || ts[i].kind=='*') && caret > ts[i].start && caret <= ts[i].end) { current = i; break; }
    if (ts[i].end <= caret) prev = i;
  }
  if (current < n) {
    out->start = ts[current].start; out->end = ts[current].end;
    if (ts[current].kind!='*' && !name(s, ts[current], caret, out->prefix)) { ok = 0; goto done; }
    prev = current > begin ? current - 1 : n;
  }
  if (!dml && current<n && ts[current].kind=='*' && ts[current].depth==scope) {
    size_t target=current;
    if (prev<n && ts[prev].kind=='.' && prev>begin && is_name(ts[prev-1])) target=prev-1;
    out->star=projection_start(s,ts,begin,target);
    for (size_t i=begin; i<current; ++i) if (ts[i].depth==scope && word(s,ts[i],"FROM")) out->star=0;
  }
  if (prev < n && ts[prev].kind == '.' && prev > begin && is_name(ts[prev - 1])) {
    if (!name(s, ts[prev - 1], ts[prev - 1].end, out->qualifier)) { ok = 0; goto done; }
  }
  if (dml) ok = read_statement(s, ts, begin, end, caret, out);
  else { out->mode = SQL_CONTEXT_COLUMN; ok = read_scope(s, ts, begin, end, scope, caret, out); }
done:
  free(ts);
  if (!ok) { sql_context_free(out); memset(out, 0, sizeof(*out)); }
  return ok;
}
