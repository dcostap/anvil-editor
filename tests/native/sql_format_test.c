#include "sql_format.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;

static void check(const char *input, const char *expected) {
  char *out = NULL;
  size_t n = 0;
  if (!sql_format(input, strlen(input), "    ", 4, &out, &n)) {
    printf("FAIL: no result for:\n%s\n", input);
    ++failures;
    return;
  }
  if (n != strlen(expected) || memcmp(out, expected, n) != 0) {
    printf("FAIL for:\n%s\n--- expected:\n%s\n--- got:\n%s\n", input, expected, out);
    ++failures;
  }
  free(out);
}

int main(void) {
  check("select a, b.c as d, count(*) from dbo.t join sales.u on t.id=u.id and u.x>-1 where a in (1,2) "
        "and b between 1 and 2 or c is null group by a, b order by a desc;",
    "SELECT\n"
    "    a,\n"
    "    b.c AS d,\n"
    "    count(*)\n"
    "FROM\n"
    "    dbo.t\n"
    "JOIN\n"
    "    sales.u\n"
    "ON\n"
    "    t.id = u.id\n"
    "AND u.x > -1\n"
    "WHERE\n"
    "    a IN (1, 2)\n"
    "AND b BETWEEN 1 AND 2\n"
    "OR c IS NULL\n"
    "GROUP BY\n"
    "    a,\n"
    "    b\n"
    "ORDER BY\n"
    "    a DESC;");

  /* Subqueries, CASE, TOP, a left join and UNION ALL. */
  check("SELECT TOP (10) id, CASE WHEN x = 1 THEN 'one' ELSE 'other' END AS label FROM "
        "(SELECT id, x FROM t) d LEFT OUTER JOIN u ON u.id = d.id UNION ALL SELECT 1, 'x'",
    "SELECT TOP (10)\n"
    "    id,\n"
    "    CASE\n"
    "        WHEN x = 1 THEN 'one'\n"
    "        ELSE 'other'\n"
    "    END AS label\n"
    "FROM\n"
    "    (\n"
    "        SELECT\n"
    "            id,\n"
    "            x\n"
    "        FROM\n"
    "            t\n"
    "    ) d\n"
    "LEFT OUTER JOIN\n"
    "    u\n"
    "ON\n"
    "    u.id = d.id\n"
    "UNION ALL\n"
    "SELECT\n"
    "    1,\n"
    "    'x'");

  /* A CTE, INSERT, UPDATE and DELETE. */
  check("with a as (select 1 as n), b (n) as (select n from a) select n from b;\n"
        "insert into t (a, b) values (1, 2), (3, 4)\n"
        "update t set a = 1, b = 2 where c = 3\n"
        "delete from t where a = 1",
    "WITH a AS (\n"
    "    SELECT\n"
    "        1 AS n\n"
    "),\n"
    "b (n) AS (\n"
    "    SELECT\n"
    "        n\n"
    "    FROM\n"
    "        a\n"
    ")\n"
    "SELECT\n"
    "    n\n"
    "FROM\n"
    "    b;\n"
    "INSERT INTO\n"
    "    t (a, b)\n"
    "VALUES\n"
    "    (1, 2),\n"
    "    (3, 4)\n"
    "UPDATE\n"
    "    t\n"
    "SET\n"
    "    a = 1,\n"
    "    b = 2\n"
    "WHERE\n"
    "    c = 3\n"
    "DELETE FROM\n"
    "    t\n"
    "WHERE\n"
    "    a = 1");

  /* Strings, quoted names, comments, GO and other statements keep their text. Only keywords change case. */
  check("-- head select\ncreate table [select] (a int)\nGO\nselect 'from x', [order by] -- why, from\n"
        ", /* c, from */ b from t\ngo 2\nexec p @a = 1",
    "-- head select\nCREATE TABLE [select] (a int)\nGO\nSELECT\n"
    "    'from x',\n"
    "    [order by] -- why, from\n"
    "    ,\n"
    "    /* c, from */ b\n"
    "FROM\n"
    "    t\ngo 2\nEXEC p @a = 1");

  /* An indented statement keeps its indentation, and text before it on its line stays. */
  check("BEGIN\n  IF @x = 1 select a, b from t\nEND",
    "BEGIN\n  IF @x = 1 SELECT\n      a,\n      b\n  FROM\n      t\nEND");

  /* A statement after a statement on the same line starts a line. */
  check("  select 1; select 2", "  SELECT\n      1;\n  SELECT\n      2");

  /* FORMAT_OFF regions keep their text and case. */
  check("/* FORMAT_OFF */ select a,b from t /* FORMAT_ON */\nselect a,b from t",
    "/* FORMAT_OFF */ select a,b from t /* FORMAT_ON */\nSELECT\n    a,\n    b\nFROM\n    t");

  /* Calls, signs, XML methods, OVER and OFFSET. */
  check("select x.value('(/a)[1]', 'int'), row_number() over (partition by a order by b), -1, a-1, @@rowcount "
        "from t order by a offset 5 rows fetch next 5 rows only",
    "SELECT\n"
    "    x.value('(/a)[1]', 'int'),\n"
    "    row_number() OVER (partition BY a ORDER BY b),\n"
    "    -1,\n"
    "    a - 1,\n"
    "    @@rowcount\n"
    "FROM\n"
    "    t\n"
    "ORDER BY\n"
    "    a\n"
    "offset 5 rows FETCH next 5 rows only");

  /* Trigger actions and permissions are not statements. MERGE keeps its layout. */
  check("CREATE TRIGGER tr ON t AFTER insert, update AS select 1\nGRANT select ON t TO u\n"
        "merge t using s on t.id = s.id when matched then update set a = 1;",
    "CREATE TRIGGER tr ON t AFTER INSERT, UPDATE AS SELECT\n    1\nGRANT SELECT ON t TO u\n"
    "MERGE t using s ON t.id = s.id WHEN matched THEN UPDATE SET a = 1;");

  /* CRLF text gets CRLF line ends. */
  check("select a,\r\nb from t", "SELECT\r\n    a,\r\n    b\r\nFROM\r\n    t");

  check("", "");
  check("   \n", "   \n");
  /* Unterminated text keeps its tokens. */
  check("select 'abc", "SELECT\n    'abc");
  check("select (((a", "SELECT\n    (((a");
  check("select a from t where (b", "SELECT\n    a\nFROM\n    t\nWHERE\n    (b");

  /* Deep nesting beyond the frame limit keeps the statement as it was. */
  {
    char deep[400] = "select ";
    for (int i = 0; i < 70; ++i) strcat(deep, "(");
    strcat(deep, "1");
    for (int i = 0; i < 70; ++i) strcat(deep, ")");
    char *out = NULL;
    size_t n = 0;
    if (!sql_format(deep, strlen(deep), "\t", 1, &out, &n) || strncmp(out, "SELECT ((", 9) != 0) {
      printf("FAIL: deep nesting\n%s\n", out ? out : "(none)");
      ++failures;
    }
    free(out);
  }

  /* Invalid UTF-8 and NUL bytes are text, not errors. */
  {
    const char text[] = "select '\xff\x00', a\xc3 from t";
    char *out = NULL;
    size_t n = 0;
    const char expected[] = "SELECT\n    '\xff\x00',\n    a\xc3\nFROM\n    t";
    if (!sql_format(text, sizeof text - 1, "    ", 4, &out, &n) || n != sizeof expected - 1 ||
        memcmp(out, expected, n) != 0) {
      printf("FAIL: bytes\n");
      ++failures;
    }
    free(out);
  }

  /* Text over the limit gives no result. */
  {
    size_t n = SQL_FORMAT_LIMIT + 1;
    char *big = malloc(n), *out = NULL;
    memset(big, ' ', n);
    size_t on = 0;
    if (sql_format(big, n, "    ", 4, &out, &on)) { printf("FAIL: limit\n"); ++failures; free(out); }
    free(big);
  }

  /* Random token soup keeps its tokens, and a second format changes nothing. */
  {
    static const char *const words[] = { "select", "from", "where", "and", "or", "between", "join", "left", "on",
      "group", "by", "order", "case", "when", "then", "else", "end", "with", "as", "union", "all", "insert", "into",
      "values", "update", "set", "delete", "top", "(", ")", ",", ".", ";", "-", "+", "=", "<>", "a", "b1", "@x",
      "'s''t'", "[q]", "\"d\"", "1", ".5", "-- c\n", "/* b */", "\nGO\n", "\n", " ", "exec", "merge", "over", "::",
      "N'x'", "offset", "fetch", "rows", "distinct", "in", "exists", "is", "not", "null", "begin", "if", "cross",
      "apply", "/* FORMAT_OFF */", "/* FORMAT_ON */", "\r\n" };
    unsigned seed = 12345;
    for (int run = 0; run < 20000; ++run) {
      char text[2048];
      size_t n = 0;
      int count = 1 + (int)((seed = seed * 1103515245u + 12345u) >> 16) % 60;
      for (int i = 0; i < count; ++i) {
        const char *w = words[((seed = seed * 1103515245u + 12345u) >> 16) % (sizeof words / sizeof *words)];
        size_t wn = strlen(w);
        memcpy(text + n, w, wn); n += wn;
        if (((seed = seed * 1103515245u + 12345u) >> 16) % 3) text[n++] = ' ';
      }
      char *once = NULL, *twice = NULL;
      size_t on = 0, tn = 0;
      if (!sql_format(text, n, "  ", 2, &once, &on) || !sql_format(once, on, "  ", 2, &twice, &tn)) {
        printf("FAIL: no result in run %d\n", run); ++failures; break;
      }
      size_t pa = 0, pb = 0, a0, a1, b0, b1;
      SqlTokenKind ka, kb;
      int same = 1;
      for (;;) {
        int ha = sql_format_token(text, n, pa, &a0, &a1, &ka), hb = sql_format_token(once, on, pb, &b0, &b1, &kb);
        if (!ha || !hb) { same = ha == hb; break; }
        if (ka != kb || a1 - a0 != b1 - b0) { same = 0; break; }
        for (size_t j = 0; j < a1 - a0; ++j) {
          char x = text[a0 + j], y = once[b0 + j];
          if (x != y && (x | 32) != (y | 32)) { same = 0; break; }
        }
        if (!same) break;
        pa = a1; pb = b1;
      }
      if (!same || tn != on || memcmp(once, twice, on) != 0) {
        printf("FAIL in run %d (%s):\n%.*s\n--- once:\n%s\n--- twice:\n%s\n", run, same ? "not stable" : "tokens",
          (int)n, text, once, twice);
        ++failures;
        free(once); free(twice);
        break;
      }
      free(once); free(twice);
    }
  }

  if (failures) return 1;
  puts("SQL format passed");
  return 0;
}
