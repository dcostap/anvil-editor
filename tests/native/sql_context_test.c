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
/* A Local Source's star sources: "at:schema.name", with ~ for a Local Source. */
static int stars_are(SqlContext *c, SqlLocal *local, const char *expected) {
  char joined[1024] = "";
  for (size_t i = 0; i < local->star_count; ++i) {
    const SqlStar *star = &c->stars[local->star_first + i];
    char one[1100];
    snprintf(one, sizeof(one), "%s%zu:%s%s%s%s", i ? "," : "", star->at, star->source.schema,
      star->source.schema[0] ? "." : "", star->source.name, star->source.local ? "~" : "");
    strcat(joined, one);
  }
  if (strcmp(joined, expected)) { fprintf(stderr, "stars: %s, expected %s\n", joined, expected); return 0; }
  return 1;
}

/* Parses with the caret after the first copy of marker. */
static void parse_after(SqlContext *c, const char *text, const char *marker) {
  sql_context_free(c);
  const char *at = strstr(text, marker);
  assert(at && sql_context_parse(text, strlen(text), (size_t)(at - text) + strlen(marker), c));
}
static int sources_are(SqlContext *c, const char *expected) {
  char joined[1024] = "";
  for (size_t i = 0; i < c->count; ++i) {
    if (i) strcat(joined, ",");
    strcat(joined, c->sources[i].name);
    if (c->sources[i].alias[0]) { strcat(joined, " "); strcat(joined, c->sources[i].alias); }
  }
  if (strcmp(joined, expected)) { fprintf(stderr, "sources: %s, expected %s\n", joined, expected); return 0; }
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
  const char *blocked[] = { "SELECT 'FROM secret", "SELECT 1 -- FROM secret", "SELECT /* nested /* comment */ still comment" };
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
  /* A * or x.* takes the columns of its sources, at its place in the list. */
  text = "WITH c AS (SELECT * FROM dbo.customers) SELECT c.na FROM c";
  assert(sql_context_parse(text, strlen(text), strlen("WITH c AS (SELECT * FROM dbo.customers) SELECT c.na"), &c));
  assert(c.mode == SQL_CONTEXT_COLUMN && source_local(&c, "c") && !source_local(&c, "c")->star);
  assert(columns_are(&c, source_local(&c, "c"), "") && stars_are(&c, source_local(&c, "c"), "0:dbo.customers"));
  parse_after(&c, "WITH c AS (SELECT o.id AS oid, x.*, total = 1 FROM dbo.orders o JOIN sales.lines AS x ON 1 = 1)"
    " SELECT c. FROM c", "c.");
  assert(!source_local(&c, "c")->star && columns_are(&c, source_local(&c, "c"), "oid,total"));
  assert(stars_are(&c, source_local(&c, "c"), "1:sales.lines"));
  parse_after(&c, "WITH a AS (SELECT 1 AS k) SELECT d. FROM dbo.x AS y JOIN (SELECT * FROM a JOIN (SELECT 2 AS m) e"
    " ON 1 = 1) d ON 1 = 1", "d.");
  assert(c.mode == SQL_CONTEXT_COLUMN && sources_are(&c, "x y,d d") && !source_local(&c, "d")->star);
  assert(stars_are(&c, source_local(&c, "d"), "0:a~,0:e~"));
  /* A recursive CTE takes its columns from its first SELECT. */
  parse_after(&c, "WITH r AS (SELECT * FROM dbo.t UNION ALL SELECT * FROM r) SELECT r. FROM r", "r.");
  assert(!source_local(&c, "r")->star && stars_are(&c, source_local(&c, "r"), "0:dbo.t"));
  /* A source that Anvil cannot read, or an unknown qualifier, leaves the list incomplete. */
  const char *incomplete[] = { "WITH c AS (SELECT * FROM dbo.t, srv.db.dbo.x) SELECT c. FROM c",
    "WITH c AS (SELECT * FROM OPENJSON(@j) WITH (a int) j) SELECT c. FROM c",
    "WITH c AS (SELECT q.* FROM dbo.t) SELECT c. FROM c", "WITH c AS (SELECT db.dbo.t.* FROM dbo.t) SELECT c. FROM c",
    "SELECT * INTO #c FROM dbo.t SELECT c. FROM #c c" };
  for (size_t i = 0; i < sizeof(incomplete) / sizeof(incomplete[0]); ++i) {
    parse_after(&c, incomplete[i], "c.");
    if (!source_local(&c, "c") || !source_local(&c, "c")->star) { fprintf(stderr, "complete: %s\n", incomplete[i]); return 1; }
  }
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

  /* UPDATE, DELETE, INSERT and MERGE read their target and sources. */
  text = "UPDATE sales.customers SET na";
  parse_after(&c, text, "SET na");
  assert(c.mode == SQL_CONTEXT_COLUMN && !strcmp(c.prefix, "na") && sources_are(&c, "customers"));
  assert(!strcmp(c.sources[0].schema, "sales"));
  text = "UPDATE c SET name = o.total FROM sales.customers c JOIN sales.orders o ON o.customer_id = c.id WHERE c.";
  parse_after(&c, text, "WHERE c.");
  assert(c.mode == SQL_CONTEXT_COLUMN && !strcmp(c.qualifier, "c") && sources_are(&c, "customers c,orders o"));
  parse_after(&c, text, "SET ");
  assert(c.mode == SQL_CONTEXT_COLUMN && sources_are(&c, "customers c,orders o"));
  parse_after(&c, text, "JOIN ");
  assert(c.mode == SQL_CONTEXT_TABLE);
  text = "DELETE FROM sales.orders WHERE to";
  parse_after(&c, text, "WHERE to");
  assert(c.mode == SQL_CONTEXT_COLUMN && sources_are(&c, "orders"));
  text = "INSERT INTO sales.customers (id, na) VALUES (1, na";
  parse_after(&c, text, "(id, na");
  assert(c.mode == SQL_CONTEXT_COLUMN && !strcmp(c.prefix, "na") && sources_are(&c, "customers"));
  parse_after(&c, text, "VALUES (1, na");
  assert(c.mode == SQL_CONTEXT_NONE);
  text = "INSERT #t (id) SELECT x. FROM dbo.y x";
  parse_after(&c, text, "SELECT x.");
  assert(c.mode == SQL_CONTEXT_COLUMN && sources_are(&c, "y x"));
  text = "MERGE INTO sales.customers AS t USING sales.staging s ON t.id = s.id\n"
    "WHEN MATCHED THEN UPDATE SET na = s.name\nWHEN NOT MATCHED THEN INSERT (id, na) VALUES (s.id, s.name);";
  parse_after(&c, text, "SET na");
  assert(c.mode == SQL_CONTEXT_COLUMN && sources_are(&c, "customers t,staging s"));
  parse_after(&c, text, "INSERT (id, na");
  assert(c.mode == SQL_CONTEXT_COLUMN && sources_are(&c, "customers t"));
  parse_after(&c, text, "USING ");
  assert(c.mode == SQL_CONTEXT_TABLE);
  /* MERGE's VALUES takes the source's columns. */
  parse_after(&c, text, "VALUES (s.");
  assert(c.mode == SQL_CONTEXT_COLUMN && !strcmp(c.qualifier, "s") && sources_are(&c, "customers t,staging s"));
  /* OUTPUT is not an alias, a table hint does not hide the column list, and a
   * target that FROM names again is one source. */
  text = "DELETE FROM sales.orders OUTPUT deleted.";
  parse_after(&c, text, "deleted.");
  assert(c.mode == SQL_CONTEXT_COLUMN && !strcmp(c.qualifier, "deleted") && sources_are(&c, "orders"));
  text = "INSERT INTO sales.customers WITH (TABLOCK) (id, na";
  parse_after(&c, text, "(id, na");
  assert(c.mode == SQL_CONTEXT_COLUMN && sources_are(&c, "customers"));
  text = "UPDATE sales.customers SET na = 1 FROM sales.customers JOIN sales.orders o ON o.customer_id = id";
  parse_after(&c, text, "SET na");
  assert(c.mode == SQL_CONTEXT_COLUMN && sources_are(&c, "customers,orders o"));
  /* FOR SYSTEM_TIME keeps the alias after it. */
  text = "SELECT h. FROM sales.customers FOR SYSTEM_TIME ALL AS h";
  parse_after(&c, text, "SELECT h.");
  assert(sources_are(&c, "customers h"));
  text = "SELECT h. FROM sales.customers FOR SYSTEM_TIME BETWEEN '2020' AND DATEADD(day, 1, @at) h JOIN sales.orders o ON 1 = 1";
  parse_after(&c, text, "SELECT h.");
  assert(sources_are(&c, "customers h,orders o"));
  /* An unfinished AS OF is not an alias. */
  text = "SELECT h. FROM sales.customers FOR SYSTEM_TIME AS OF ";
  parse_after(&c, text, "SELECT h.");
  assert(sources_are(&c, "customers"));
  /* A MERGE table hint keeps the alias after it. */
  text = "MERGE INTO sales.customers WITH (HOLDLOCK) AS tgt USING sales.staging s ON tgt.";
  parse_after(&c, text, "ON tgt.");
  assert(c.mode == SQL_CONTEXT_COLUMN && sources_are(&c, "customers tgt,staging s"));
  /* An UPDATE target names the FROM entry whose exposed name (its alias, or
   * else its table name) it has, with or without a schema, as in SQL Server. */
  text = "UPDATE sales.customers SET na = 1 FROM customers JOIN sales.orders o ON o.customer_id = id";
  parse_after(&c, text, "SET na");
  assert(sources_are(&c, "customers,orders o"));
  text = "UPDATE customers SET na = 1 FROM sales.customers c";
  parse_after(&c, text, "SET na");
  assert(sources_are(&c, "customers,customers c"));
  /* OUTPUT INTO names its own table. */
  text = "DELETE FROM sales.orders OUTPUT deleted.id INTO dbo.archive (i";
  parse_after(&c, text, "(i");
  assert(c.mode == SQL_CONTEXT_COLUMN && sources_are(&c, "archive"));
  parse_after(&c, text, "INTO ");
  assert(c.mode == SQL_CONTEXT_TABLE);
  /* A CTE or a temporary table can be the target. */
  text = "WITH old AS (SELECT id, total FROM sales.orders) DELETE FROM old WHERE to";
  parse_after(&c, text, "WHERE to");
  assert(c.mode == SQL_CONTEXT_COLUMN && source_local(&c, "old") && columns_are(&c, source_local(&c, "old"), "id,total"));
  /* A SELECT after an UPDATE without a semicolon is a new statement, and back. */
  text = "UPDATE sales.customers SET name = N'x'\nSELECT o. FROM sales.orders o";
  parse_after(&c, text, "SELECT o.");
  assert(c.mode == SQL_CONTEXT_COLUMN && sources_are(&c, "orders o"));
  text = "SELECT * FROM sales.orders\nDELETE FROM sales.customers WHERE na";
  parse_after(&c, text, "WHERE na");
  assert(c.mode == SQL_CONTEXT_COLUMN && sources_are(&c, "customers"));
  text = "SELECT o. FROM sales.orders o\nDELETE FROM sales.customers";
  parse_after(&c, text, "SELECT o.");
  assert(sources_are(&c, "orders o"));
  /* The UPDATE() function in a trigger does not start a statement. */
  text = "IF UPDATE(name) SELECT c. FROM sales.customers c";
  parse_after(&c, text, "SELECT c.");
  assert(sources_are(&c, "customers c"));
  /* A table-valued function is a source. A source without metadata adds no
   * columns, and the other sources keep theirs. */
  text = "SELECT o. FROM sales.orders o CROSS APPLY dbo.lines(o.id) AS l JOIN other.dbo.items i ON 1 = 1"
    " JOIN OPENJSON(@j) WITH (a int) j ON 1 = 1, (VALUES (1, 2)) v (p, q) OUTER APPLY (SELECT x FROM dbo.y) z"
    " JOIN dbo.pairs(1) AS p (a, b) ON 1 = 1";
  parse_after(&c, text, "SELECT o.");
  assert(c.mode == SQL_CONTEXT_COLUMN && sources_are(&c, "orders o,lines l,z z"));
  parse_after(&c, text, "lines(o.");
  assert(c.mode == SQL_CONTEXT_COLUMN && !strcmp(c.qualifier, "o"));
  text = "SELECT c.na FROM dbo.fn(1) c";
  parse_after(&c, text, "c.na");
  assert(c.mode == SQL_CONTEXT_COLUMN && sources_are(&c, "fn c") && !strcmp(c.sources[0].schema, "dbo"));
  text = "SELECT * FROM dbo.fn(1) c JOIN ";
  parse_after(&c, text, "JOIN ");
  assert(c.mode == SQL_CONTEXT_TABLE && sources_are(&c, "fn c"));
  /* A three-part target needs a cross-database catalog. */
  text = "UPDATE other.sales.customers SET na";
  parse_after(&c, text, "SET na");
  assert(c.mode == SQL_CONTEXT_NONE);
  /* The token before the caret tells what belongs there. A name follows a
   * keyword that starts a list of names, a comma, a parenthesis or a dot. */
  static const char *names[] = {
    "SELECT |", "SELECT name, |", "SELECT * FROM sales.customers WHERE |", "SELECT * FROM t WHERE a = 1 AND |",
    "SELECT * FROM t ORDER BY |", "SELECT TOP 10 |", "SELECT TOP (10) |", "SELECT ISNULL(|",
    "SELECT * FROM a JOIN b ON a.id = |", "SELECT * FROM t c WHERE c.|", "SELECT na|",
    "SELECT * FROM a CROSS APPLY |", "SELECT * FROM t WHERE NOT |", NULL };
  /* A value usually follows an operator or a value keyword. */
  static const char *values[] = {
    "SELECT * FROM sales.customers WHERE email <> |", "SELECT * FROM t WHERE email LIKE |",
    "SELECT * FROM t WHERE id IN (|", "SELECT * FROM t WHERE id IN (1, |", "SELECT * FROM t WHERE id BETWEEN 1 AND |",
    "UPDATE t SET name = |",
    "SELECT CASE WHEN a = 1 THEN |", "SELECT CASE WHEN a = 1 THEN 1 ELSE |", "SELECT a * |",
    "SELECT * FROM t WHERE email <> n|", NULL };
  /* No existing name follows a complete term, AS, or a number. */
  static const char *nothing[] = {
    "SELECT * FROM t WHERE email |", "SELECT * FROM t WHERE id = 1 |", "SELECT name |FROM t",
    "SELECT name AS |", "SELECT name AS n|", "SELECT * FROM sales.customers c |", "SELECT * FROM sales.customers c|",
    "SELECT * FROM t ORDER BY name |", "SELECT * FROM t WHERE email = 'a' |", "SELECT COUNT(*) |",
    "SELECT CASE WHEN a = 1 THEN 1 END |", "SELECT * FROM t WHERE id = 1|", "SELECT * |FROM t",
    "SELECT * FROM t WHERE a IS NULL |", "SELECT * FROM t WHERE id IS |", "SELECT * FROM t WHERE id IS NOT |",
    "SELECT * FROM a LEFT |", "SELECT * FROM t ORDER |", "SELECT a FROM t UNION |", "INSERT |", NULL };
  static const char **groups[] = { names, values, nothing };
  for (int group = 0; group < 3; ++group) {
    for (const char **item = groups[group]; *item; ++item) {
      char sql[256];
      const char *bar = strchr(*item, '|');
      size_t at = (size_t)(bar - *item);
      memcpy(sql, *item, at);
      strcpy(sql + at, bar + 1);
      sql_context_free(&c);
      assert(sql_context_parse(sql, strlen(sql), at, &c));
      int got = c.slot == SQL_SLOT_NONE ? 2 : c.slot == SQL_SLOT_VALUE ? 1 : 0;
      if (got != group) { fprintf(stderr, "%s: got %d, expected %d\n", *item, got, group); return 1; }
    }
  }
  /* Where no existing name follows, the clause names the keywords that can, and
   * alias tells that the term before the caret can still take an alias. */
  static const struct { const char *sql, *keywords; int alias; } follows[] = {
    { "SELECT * FROM t WHERE email |", "where", 0 }, { "SELECT name |", "select", 1 },
    { "SELECT name AS n |", "select", 0 }, { "SELECT * |", "select", 0 }, { "SELECT TOP 10 name |", "select", 1 },
    { "SELECT * FROM sales.customers |", "from", 1 }, { "SELECT * FROM sales.customers c |", "from", 0 },
    { "SELECT * FROM sales.customers c|", "from", 1 }, { "SELECT * FROM a JOIN b |", "join", 1 },
    { "SELECT * FROM a JOIN b ON a.id = b.id |", "on", 0 }, { "SELECT * FROM t ORDER BY name |", "order", 0 },
    { "SELECT * FROM t ORDER BY name DESC |", "sort", 0 }, { "SELECT * FROM t GROUP BY name |", "group", 0 },
    { "SELECT CASE WHEN a = 1 |", "when", 0 }, { "SELECT CASE WHEN a = 1 THEN 'x' |", "then", 0 },
    { "SELECT CASE WHEN a = 1 THEN 'x' END |", "select", 1 },
    { "SELECT * FROM t WHERE id IN (SELECT id FROM u |", "from", 1 }, { "SELECT * FROM t WHERE (a = 1 |", "where", 0 },
    { "SELECT COUNT(x |", "", 0 }, { "SELECT CONVERT(int, x |", "", 0 }, { "SELECT * FROM t WHERE id IN (1, 2 |", "", 0 },
    { "SELECT * FROM t WHERE id IN (1, 2) |", "where", 0 }, { "SELECT * FROM t WHERE a IS |", "is", 0 },
    { "SELECT * FROM t WHERE a IS NOT |", "is not", 0 }, { "SELECT * FROM a LEFT |", "left", 0 },
    { "SELECT * FROM t ORDER |", "by", 0 }, { "SELECT a FROM t UNION |", "union", 0 },
    { "SELECT a FROM t INTERSECT |", "except", 0 }, { "UPDATE sales.customers |", "update", 0 },
    { "INSERT INTO t (a, b) |", "into", 0 }, { "INSERT |", "insert", 0 }, { "SELECT name AS |", "", 0 },
    { "SELECT * FROM t WHERE id = 1|", "", 0 } };
  for (size_t i = 0; i < sizeof(follows) / sizeof(follows[0]); ++i) {
    char sql[256];
    const char *bar = strchr(follows[i].sql, '|');
    size_t at = (size_t)(bar - follows[i].sql);
    memcpy(sql, follows[i].sql, at);
    strcpy(sql + at, bar + 1);
    sql_context_free(&c);
    assert(sql_context_parse(sql, strlen(sql), at, &c));
    if (c.slot != SQL_SLOT_NONE || strcmp(c.keywords, follows[i].keywords) || c.alias != follows[i].alias) {
      fprintf(stderr, "%s: slot %d, keywords \"%s\", alias %d\n", follows[i].sql, c.slot, c.keywords, c.alias);
      return 1;
    }
  }
  /* At the start of a JOIN's ON, join is 1 + the index of the joined source. */
  static const struct { const char *sql; size_t join; } joins[] = {
    { "SELECT * FROM sales.customers c JOIN dbo.orders o ON |", 2 }, { "SELECT * FROM a JOIN b ON x|", 2 },
    { "SELECT * FROM a JOIN b ON a.id = b.id LEFT JOIN c ON |", 3 }, { "SELECT * FROM a JOIN b ON | JOIN c ON c.id = a.id", 2 },
    { "SELECT * FROM a JOIN (SELECT id FROM b) d ON |", 2 }, { "UPDATE c SET name = 1 FROM sales.customers c JOIN dbo.orders o ON |", 2 },
    { "SELECT * FROM a JOIN b ON a.id = |", 0 }, { "SELECT * FROM a JOIN b ON a.id = b.id AND |", 0 },
    { "SELECT * FROM a JOIN b ON b.|", 0 }, { "SELECT * FROM a JOIN b ON a.id = b.id WHERE |", 0 } };
  for (size_t i = 0; i < sizeof(joins) / sizeof(joins[0]); ++i) {
    char sql[256];
    const char *bar = strchr(joins[i].sql, '|');
    size_t at = (size_t)(bar - joins[i].sql);
    memcpy(sql, joins[i].sql, at);
    strcpy(sql + at, bar + 1);
    sql_context_free(&c);
    assert(sql_context_parse(sql, strlen(sql), at, &c));
    if (c.join != joins[i].join) { fprintf(stderr, "%s: join %zu\n", joins[i].sql, c.join); return 1; }
  }
  /* A typed variable gets the variables that the batch declares before the caret, "name type;" each. */
  static const struct { const char *sql, *variables; int declaring; } variables[] = {
    { "DECLARE @a int, @b varchar(10) = 'x'; SELECT * FROM t WHERE id = @|", "@a int;@b varchar(10);", 0 },
    { "DECLARE @a AS decimal(10, 2) = (SELECT 1), @b int SELECT @|", "@a decimal(10, 2);@b int;", 0 },
    { "CREATE PROCEDURE dbo.p @id int, @name nvarchar(80) = NULL OUTPUT, @o int OUT AS SELECT @|",
      "@id int;@name nvarchar(80);@o int;", 0 },
    { "CREATE OR ALTER FUNCTION f (@x AS int, @y bit) RETURNS int AS BEGIN RETURN @|", "@x int;@y bit;", 0 },
    { "DECLARE @a int; SET @a = @|", "@a int;", 0 }, { "DECLARE @a int; PRINT @|", "@a int;", 0 },
    { "DECLARE @a int; IF @| > 0 PRINT 1", "@a int;", 0 }, { "DECLARE @a int; EXEC dbo.p @id = @|", "@a int;", 0 },
    { "DECLARE @a int\nGO\nSELECT @|", "", 0 }, { "SELECT @| DECLARE @late int", "", 0 },
    { "DECLARE @t TABLE (id int); SELECT @|", "", 0 }, { "DECLARE @a int = 1, @b|", "@a int;", 1 },
    { "CREATE PROCEDURE p @a int, @b|", "@a int;", 1 }, { "DECLARE @a int; SELECT @@|", "@a int;", 0 } };
  for (size_t i = 0; i < sizeof(variables) / sizeof(variables[0]); ++i) {
    char sql[256], listed[2048] = "";
    const char *bar = strchr(variables[i].sql, '|');
    size_t at = (size_t)(bar - variables[i].sql);
    memcpy(sql, variables[i].sql, at);
    strcpy(sql + at, bar + 1);
    sql_context_free(&c);
    assert(sql_context_parse(sql, strlen(sql), at, &c));
    for (size_t v = 0; v < c.variable_count; ++v)
      snprintf(listed + strlen(listed), sizeof(listed) - strlen(listed), "%s %s;", c.variables[v].name, c.variables[v].type);
    size_t start = at;
    while (start && sql[start - 1] == '@') --start;
    if (strcmp(listed, variables[i].variables) || c.declaring != variables[i].declaring
        || (!variables[i].declaring && (c.start != start || strncmp(c.prefix, sql + start, at - start)))) {
      fprintf(stderr, "%s: variables \"%s\", declaring %d, prefix \"%s\"\n", variables[i].sql, listed, c.declaring, c.prefix);
      return 1;
    }
  }
  /* Where a parameter name goes in an EXEC: "schema.routine positional named;...". */
  static const struct { const char *sql, *call; } calls[] = {
    { "EXEC dbo.p |", "dbo.p 0 " }, { "EXEC sales.find_customer @id = 1, |", "sales.find_customer 0 @id;" },
    { "EXECUTE p 1, 'x', @c = 2, @|", ".p 2 @c;" }, { "EXEC @rc = dbo.p @a = 1, |", "dbo.p 0 @a;" },
    { "EXEC dbo.p @a = |", "" }, { "EXEC dbo.p @a = 1 |", "" }, { "EXEC dbo.p 1; SELECT |", "" },
    { "EXEC dbo.p|", "" }, { "EXEC dbo.p @a = dbo.f(1, |", "" }, { "EXEC dbo.p x|", "" } };
  for (size_t i = 0; i < sizeof(calls) / sizeof(calls[0]); ++i) {
    char sql[256], call[2048] = "";
    const char *bar = strchr(calls[i].sql, '|');
    size_t at = (size_t)(bar - calls[i].sql);
    memcpy(sql, calls[i].sql, at);
    strcpy(sql + at, bar + 1);
    sql_context_free(&c);
    assert(sql_context_parse(sql, strlen(sql), at, &c));
    if (c.routine[0]) {
      snprintf(call, sizeof(call), "%s.%s %zu ", c.routine_schema, c.routine, c.positional);
      for (size_t k = 0; k < c.named_count; ++k) { strncat(call, c.named[k], 200); strcat(call, ";"); }
    }
    if (strcmp(call, calls[i].call)) { fprintf(stderr, "%s: call \"%s\"\n", calls[i].sql, call); return 1; }
  }
  text = "select * from t where email l";
  parse_after(&c, text, "email l");
  assert(c.lower && !strcmp(c.keywords, "where"));
  text = "SELECT * FROM t WHERE email l";
  parse_after(&c, text, "email l");
  assert(!c.lower);
  /* Also at a name: the nearest keyword before the caret sets the case. */
  text = "SELECT * FROM t where cou";
  parse_after(&c, text, "where cou");
  assert(c.lower);
  text = "select * from t where a = 1 AND cou";
  parse_after(&c, text, "AND cou");
  assert(!c.lower);
  /* Also at a name: the nearest keyword before the caret sets the case. */
  text = "SELECT * FROM t where cou";
  parse_after(&c, text, "where cou");
  assert(c.lower);
  text = "select * from t where a = 1 AND cou";
  parse_after(&c, text, "AND cou");
  assert(!c.lower);
  sql_context_free(&c);
  puts("SQL context passed");
  return 0;
}
