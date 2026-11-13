#include "sql_batch.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static int split(const char *text, SqlBatch *b, size_t capacity) {
  return sql_batch_split(text, strlen(text), b, capacity);
}

int main(void) {
  SqlBatch b[8];
  const char *text = "SELECT 1\r\ngo\r\n\r\nSELECT 'x\nGO\n' /* \nGO\n */ -- GO\n  Go 3 -- again\nSELECT [a\nGO\n]\nGO";
  assert(split(text, b, 8) == 3);
  assert(b[0].start == 0 && b[0].end == strlen("SELECT 1\r\n") && b[0].repeat == 1 && b[0].line == 1);
  assert(!strncmp(text + b[1].start, "\r\nSELECT 'x", 11) && b[1].repeat == 3 && b[1].line == 3);
  assert(!strncmp(text + b[2].start, "SELECT [a", 9) && b[2].line == 10 && b[2].end == strlen(text) - 2);

  text = "SELECT 1\nGOTO done\nGO-- c\nGO\n  \n";
  assert(split(text, b, 8) == 1 && b[0].end == strlen("SELECT 1\nGOTO done\n"));
  assert(split("GO\nGO", b, 8) == 0);
  assert(split("", b, 8) == 0);
  assert(split("SELECT 1\nGO 0", b, 8) == -1);
  assert(split("SELECT 1\nGO 1001", b, 8) == -1);
  assert(split("A\nGO\nB\nGO\nC", b, 2) == -1);
  text = "SELECT N'unterminated\nGO\n";
  assert(split(text, b, 8) == 1 && b[0].end == strlen(text));

  char name[129];
  text = "-- note\n/* a /* nested */ b */\ncreate OR ALTER procedure [sales].[fail]]s] AS SELECT 1";
  assert(sql_batch_module(text, strlen(text), name, sizeof(name)) && !strcmp(name, "fail]s"));
  text = "ALTER FUNCTION dbo.total(@x int) RETURNS int AS BEGIN RETURN @x END";
  assert(sql_batch_module(text, strlen(text), name, sizeof(name)) && !strcmp(name, "total"));
  text = "CREATE PROC \"quoted\" AS SELECT 1";
  assert(sql_batch_module(text, strlen(text), name, sizeof(name)) && !strcmp(name, "quoted"));
  text = "CREATE TRIGGER t_audit ON sales.customers AFTER INSERT AS SELECT 1";
  assert(sql_batch_module(text, strlen(text), name, sizeof(name)) && !strcmp(name, "t_audit"));
  text = "CREATE PROCEDURE dbo . [p] AS SELECT 1";
  assert(sql_batch_module(text, strlen(text), name, sizeof(name)) && !strcmp(name, "p"));
  text = "SELECT 1; CREATE PROCEDURE p AS SELECT 1";
  assert(!sql_batch_module(text, strlen(text), name, sizeof(name)));
  text = "CREATE TABLE p (id int)";
  assert(!sql_batch_module(text, strlen(text), name, sizeof(name)));
  assert(!sql_batch_module("CREATE PROCEDURE", 16, name, sizeof(name)));
  assert(!sql_batch_module("", 0, name, sizeof(name)));
  assert(!sql_batch_module("CREATE PROCEDURE abcdef AS", 26, name, 4));

  const char *changes[] = { "CREATE TABLE sales.notes (id int)", "create or alter procedure [p] as select 1",
    "ALTER TABLE t ADD c int", "DROP VIEW IF EXISTS dbo.v", "EXEC sys.sp_rename 'a', 'b'",
    "SELECT * INTO backup_orders FROM sales.orders", "PRINT 1\nGO\nCREATE SCHEMA audit",
    "CREATE EXTERNAL TABLE dbo.ext (id int) WITH (LOCATION = 'x')",
    "DELETE FROM t OUTPUT deleted.id INTO @log;\nSELECT * INTO dbo.copy FROM t",
    "EXEC p @x OUTPUT\nSELECT 1 AS a INTO dbo.copy" };
  for (size_t i = 0; i < sizeof(changes) / sizeof(changes[0]); ++i)
    assert(sql_batch_changes_schema(changes[i], strlen(changes[i])));
  const char *same[] = { "CREATE TABLE #t (id int)", "DROP TABLE IF EXISTS #t", "INSERT INTO dbo.t VALUES (1)",
    "SELECT 'CREATE TABLE x' AS text", "-- DROP TABLE t\nSELECT 1", "/* ALTER /* VIEW */ v */ SELECT 1",
    "FETCH NEXT FROM c INTO @a", "SELECT 1 INTO #copy", "CREATE INDEX ix ON t (c)", "MERGE INTO t USING s ON 1 = 0",
    "DELETE FROM t OUTPUT deleted.* INTO dbo.archive", "UPDATE t SET a = 1 OUTPUT inserted.a, deleted.a INTO dbo.audit (new, old)",
    "CREATE TABLE [#t] (id int)", "DROP TABLE \"#t\"", "" };
  for (size_t i = 0; i < sizeof(same) / sizeof(same[0]); ++i)
    assert(!sql_batch_changes_schema(same[i], strlen(same[i])));

  /* An UPDATE or DELETE of a table that has no WHERE, or no inner JOIN, at its own level. */
  static const struct { const char *sql, *verb; unsigned line; } unfiltered[] = {
    { "DELETE FROM sales.orders", "DELETE", 1 }, { "update t set a = 1", "UPDATE", 1 },
    { "SELECT 1;\nUPDATE t SET a = CASE WHEN b = 1 THEN 2 END\nSELECT 2 WHERE 1 = 1", "UPDATE", 2 },
    { "DELETE TOP (10) FROM t", "DELETE", 1 }, { "UPDATE t SET a = 1 FROM t LEFT JOIN u ON u.id = t.id", "UPDATE", 1 },
    { "IF 1 = 1 DELETE FROM t", "DELETE", 1 }, { "WITH x AS (SELECT * FROM t WHERE 1 = 1) DELETE FROM x", "DELETE", 1 },
    { "UPDATE t SET a = (SELECT b FROM u WHERE u.id = t.id)", "UPDATE", 1 },
    { "PRINT 1\nGO\nDELETE FROM t WHERE (id = 1)\nDELETE FROM [dbo].[u]", "DELETE", 4 },
    { "BEGIN UPDATE t WITH (TABLOCK) SET a = 1 END", "UPDATE", 1 } };
  for (size_t i = 0; i < sizeof(unfiltered) / sizeof(unfiltered[0]); ++i) {
    SqlBatchRisk risk;
    sql_batch_risk(unfiltered[i].sql, strlen(unfiltered[i].sql), &risk);
    if (!risk.changes || risk.unfiltered_line != unfiltered[i].line || strcmp(risk.unfiltered_verb, unfiltered[i].verb)) {
      fprintf(stderr, "%s: line %u %s\n", unfiltered[i].sql, risk.unfiltered_line, risk.unfiltered_verb); return 1;
    }
  }
  /* Changes to data, schema or the server. Temporary tables and variables do not count. */
  static const struct { const char *sql; int changes; } kinds[] = {
    { "DELETE FROM t WHERE id = 1", 1 }, { "UPDATE t SET a = 1 WHERE CURRENT OF c", 1 },
    { "UPDATE c SET a = 1 FROM sales.customers c JOIN dbo.orders o ON o.customer_id = c.id", 1 },
    { "DELETE o FROM dbo.orders o INNER JOIN x ON 1 = 1", 1 },
    { "MERGE t USING s ON t.id = s.id WHEN MATCHED THEN DELETE;", 1 },
    { "CREATE TRIGGER tr ON t AFTER DELETE AS DELETE FROM log", 1 }, { "INSERT INTO dbo.t VALUES (1)", 1 },
    { "TRUNCATE TABLE t", 1 }, { "CREATE INDEX ix ON t (c)", 1 }, { "DROP TABLE t", 1 }, { "EXEC dbo.p", 1 },
    { "EXECUTE sp_who", 1 }, { "sp_who", 1 }, { "GRANT SELECT ON t TO u", 1 }, { "SELECT * INTO dbo.copy FROM t", 1 },
    { "DBCC CHECKDB", 1 }, { "UPDATE STATISTICS dbo.t", 1 }, { "BEGIN TRAN; DELETE FROM t WHERE id = 1; COMMIT", 1 },
    { "ALTER TABLE t ADD CONSTRAINT f FOREIGN KEY (a) REFERENCES u (id) ON DELETE CASCADE", 1 },
    { "SELECT * FROM t", 0 }, { "WITH x AS (SELECT 1 AS a) SELECT * FROM x", 0 },
    { "DECLARE @a int = 1; SET @a = 2; PRINT @a", 0 }, { "SELECT * INTO #copy FROM t", 0 },
    { "INSERT INTO #t VALUES (1)", 0 }, { "CREATE TABLE #t (id int)", 0 }, { "DROP TABLE IF EXISTS #t", 0 },
    { "DELETE FROM @t", 0 }, { "UPDATE [#t] SET a = 1", 0 }, { "TRUNCATE TABLE #t", 0 }, { "SET NOCOUNT ON; SELECT 1", 0 },
    { "USE AnvilTest", 0 }, { "IF EXISTS (SELECT 1 FROM t) PRINT 1", 0 }, { "SELECT 'DELETE FROM t'", 0 },
    { "-- DELETE FROM t\nSELECT 1", 0 }, { "FETCH NEXT FROM c INTO @a", 0 }, { "", 0 },
    { "BEGIN TRANSACTION; SELECT 1; COMMIT", 0 } };
  for (size_t i = 0; i < sizeof(kinds) / sizeof(kinds[0]); ++i) {
    SqlBatchRisk risk;
    sql_batch_risk(kinds[i].sql, strlen(kinds[i].sql), &risk);
    if (risk.changes != kinds[i].changes || risk.unfiltered_line) {
      fprintf(stderr, "%s: changes %d line %u\n", kinds[i].sql, risk.changes, risk.unfiltered_line); return 1;
    }
  }
  puts("SQL batches passed");
  return 0;
}
