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
  puts("SQL batches passed");
  return 0;
}
