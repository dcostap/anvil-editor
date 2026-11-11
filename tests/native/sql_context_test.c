#include "sql_context.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static SqlLocal *source_local(SqlContext *c, const char *alias) {
  for (size_t i = 0; i < c->count; ++i)
    if (!strcmp(c->sources[i].alias[0] ? c->sources[i].alias : c->sources[i].name, alias))
      return c->sources[i].local ? &c->locals[c->sources[i].local - 1] : NULL;
  return NULL;
}
static int columns_are(SqlContext *c, SqlLocal *local, const char *expected) {
  char joined[1024] = "";
  for (size_t i = 0; i < local->count; ++i) {
    if (i) strcat(joined, ",");
    strcat(joined, c->columns[local->first + i]);
  }
  if (strcmp(joined, expected)) { fprintf(stderr, "columns: %s, expected %s\n", joined, expected); return 0; }
  return 1;
}

int main(void) {
  SqlContext c;
  const char *text = "SELECT c.na FROM sales.customers AS c WHERE c.id = 1";
  assert(sql_context_parse(text, strlen(text), strlen("SELECT c.na"), &c));
  assert(c.mode == SQL_CONTEXT_COLUMN);
  assert(strcmp(c.prefix, "na") == 0);
  assert(strcmp(c.qualifier, "c") == 0);
  assert(c.count == 1);
  assert(strcmp(c.sources[0].schema, "sales") == 0);
  assert(strcmp(c.sources[0].name, "customers") == 0);
  assert(strcmp(c.sources[0].alias, "c") == 0);
  text = "SELECT outer_c.id FROM old.customers outer_c WHERE EXISTS (SELECT c.na FROM sales.clients c)";
  const char *caret = strstr(text, "c.na") + 4;
  assert(sql_context_parse(text, strlen(text), (size_t)(caret - text), &c));
  assert(c.count == 1 && !strcmp(c.sources[0].name, "clients"));
  text = "SELECT * FROM old_table; SELECT c.na FROM [odd schema].[customer]]names] c";
  caret = strstr(text, "c.na") + 4;
  assert(sql_context_parse(text, strlen(text), (size_t)(caret - text), &c));
  assert(c.count == 1 && !strcmp(c.sources[0].schema, "odd schema"));
  assert(!strcmp(c.sources[0].name, "customer]names"));
  text = "SELECT c.na FROM dbo.customers c JOIN dbo.orders o ON c.id=o.customer_id";
  assert(sql_context_parse(text, strlen(text), 11, &c));
  assert(c.count == 2 && !strcmp(c.sources[1].alias, "o"));
  const char *blocked[] = { "SELECT 'FROM secret", "SELECT 1 -- FROM secret", "SELECT /* nested /* comment */ still comment",
    "SELECT c.na FROM dbo.fn(1) c" };
  for (size_t i = 0; i < sizeof(blocked) / sizeof(blocked[0]); ++i) {
    assert(sql_context_parse(blocked[i], strlen(blocked[i]), strlen(blocked[i]), &c));
    assert(c.mode == SQL_CONTEXT_NONE);
  }
  assert(sql_context_parse("", 0, 0, &c) && c.mode == SQL_CONTEXT_NONE);
  assert(!sql_context_parse("", 0, 1, &c));
  assert(!sql_context_parse("", 256 * 1024 + 1, 0, &c));
  text = "SELECT \xff FROM dbo.t";
  assert(sql_context_parse(text, strlen(text), 8, &c));
  sql_context_free(&c);

  /* CTEs: a column list, or the names of the SELECT's columns. */
  text = ";WITH a (x, [y z]) AS (SELECT 1, 2), b AS (SELECT c.id, c.name AS label, total = c.amount * 2,"
    " COUNT(*) n, c.a + 1, CASE WHEN c.ok = 1 THEN 1 ELSE 0 END, 7 FROM dbo.customers c UNION SELECT 1, 2, 3, 4, 5, 6, 7)"
    " SELECT b. FROM b JOIN a ON 1 = 1 JOIN dbo.b real_b ON 1 = 1";
  caret = strstr(text, "b. ") + 2;
  assert(sql_context_parse(text, strlen(text), (size_t)(caret - text), &c));
  assert(c.mode == SQL_CONTEXT_COLUMN && c.count == 3 && !strcmp(c.qualifier, "b"));
  assert(source_local(&c, "b") && source_local(&c, "b")->kind == SQL_LOCAL_CTE);
  assert(columns_are(&c, source_local(&c, "b"), "id,label,total,n"));
  assert(columns_are(&c, source_local(&c, "a"), "x,y z"));
  assert(!source_local(&c, "real_b"));
  sql_context_free(&c);
  text = "WITH c AS (SELECT * FROM dbo.customers) SELECT c.na FROM c";
  assert(sql_context_parse(text, strlen(text), strlen("WITH c AS (SELECT * FROM dbo.customers) SELECT c.na"), &c));
  assert(c.mode == SQL_CONTEXT_COLUMN && source_local(&c, "c") && source_local(&c, "c")->star);
  sql_context_free(&c);
  text = "SELECT c.na FROM dbo.customers c WITH (NOLOCK)";
  assert(sql_context_parse(text, strlen(text), 11, &c) && c.local_count == 0 && c.count == 1);

  /* Derived tables, with and without a column list. */
  text = "SELECT d.id, e. FROM (SELECT id, name FROM dbo.customers) AS d JOIN (SELECT 1, 2) e (p, q) ON 1 = 1";
  caret = strstr(text, "e. ") + 2;
  assert(sql_context_parse(text, strlen(text), (size_t)(caret - text), &c));
  assert(c.mode == SQL_CONTEXT_COLUMN && c.count == 2);
  assert(source_local(&c, "d")->kind == SQL_LOCAL_DERIVED && columns_are(&c, source_local(&c, "d"), "id,name"));
  assert(columns_are(&c, source_local(&c, "e"), "p,q"));
  sql_context_free(&c);

  /* Temporary tables and table variables anywhere in the text. */
  text = "CREATE TABLE #t (id int PRIMARY KEY, [the name] nvarchar(10), CONSTRAINT pk UNIQUE (id))\n"
    "SELECT x.id, x.v AS value INTO #u FROM dbo.y x\nDECLARE @v AS TABLE (k int)\nINSERT INTO #t SELECT 1, 2\n"
    "SELECT t. FROM #t t JOIN #U u ON 1 = 1 JOIN @v v ON 1 = 1";
  caret = strstr(text, "t. ") + 2;
  assert(sql_context_parse(text, strlen(text), (size_t)(caret - text), &c));
  assert(c.local_count == 3 && c.count == 3);
  assert(source_local(&c, "t")->kind == SQL_LOCAL_TEMP && columns_are(&c, source_local(&c, "t"), "id,the name"));
  assert(columns_are(&c, source_local(&c, "u"), "id,value"));
  assert(source_local(&c, "v")->kind == SQL_LOCAL_VARIABLE && columns_are(&c, source_local(&c, "v"), "k"));
  sql_context_free(&c);
  puts("SQL context passed");
  return 0;
}
