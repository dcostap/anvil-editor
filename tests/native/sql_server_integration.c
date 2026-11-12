#include "sql_server.h"
#include "sql_query.h"
#include <windows.h>
#include <stdio.h>
#include <string.h>

#define CHECK(value) do { if (!(value)) { fprintf(stderr, "SQL execution check failed at line %d: %s\n", __LINE__, result.error); sql_query_free(&result); return 0; } } while (0)
static bool cancel_after_start(void *context) {
  return GetTickCount64() - *(ULONGLONG *)context > 1000;
}
/* One run on a new session, as the first run of a SQL Query does. */
static int run_once(SqlServerOptions *options, const char *sql, unsigned max_rows, unsigned timeout,
                    SqlQueryCancelled cancelled, void *context, SqlQueryResult *result) {
  char error[256];
  unsigned session = sql_session_open(options, error);
  if (!session) { memset(result, 0, sizeof(*result)); snprintf(result->error, sizeof(result->error), "%s", error); return 0; }
  int ok = sql_session_execute(session, 1, 0, sql, strlen(sql), max_rows, timeout, cancelled, context, result);
  sql_session_close(session);
  return ok;
}
static int has_message(SqlQueryResult *result, const char *text) {
  for (size_t i = 0; i < result->message_count; ++i) if (strstr(result->messages[i].text, text)) return 1;
  return 0;
}
static int execution_checks(SqlServerOptions *options) {
  SqlQueryResult result;
  const char *sql = "SELECT CAST(9223372036854775807 AS bigint) AS number, CAST(NULL AS nvarchar(10)) AS absent, "
                    "N'' AS empty_value, N'\xc3\xa9l\xc3\xa8ve' AS name, 0x0001FF AS bytes, N'a'+NCHAR(0)+N'b' AS nul, "
                    "CAST(0x3DD800DE AS nvarchar(2)) AS face, CAST(12345678901234567890.1234567890 AS decimal(30,10)) AS exact_value; SELECT N'end' AS last_value;";
  CHECK(run_once(options, sql, 1000, 30, NULL, NULL, &result));
  CHECK(result.count == 2 && result.tables[0].row_count == 1 && result.tables[0].column_count == 8);
  CHECK(!strcmp(result.tables[0].cells[0].text, "9223372036854775807"));
  CHECK(result.tables[0].cells[1].text == NULL);
  CHECK(result.tables[0].cells[2].text && result.tables[0].cells[2].length == 0);
  CHECK(!strcmp(result.tables[0].cells[3].text, "\xc3\xa9l\xc3\xa8ve"));
  CHECK(!strcmp(result.tables[0].cells[4].text, "0001FF"));
  CHECK(result.tables[0].cells[5].length == 3 && !memcmp(result.tables[0].cells[5].text, "a\0b", 3));
  CHECK(!strcmp(result.tables[0].cells[6].text, "\xf0\x9f\x98\x80"));
  CHECK(!strcmp(result.tables[0].cells[7].text, "12345678901234567890.1234567890"));
  CHECK(!strcmp(result.tables[1].cells[0].text, "end"));
  CHECK(result.transaction_count == 0);
  sql_query_free(&result);

  sql = "SELECT 1 AS id UNION ALL SELECT 2; SELECT REPLICATE(CAST(N'x' AS nvarchar(max)),40000) AS long_value";
  CHECK(run_once(options, sql, 1, 30, NULL, NULL, &result));
  CHECK(result.count == 2 && result.tables[0].row_count == 1 && result.tables[0].truncated);
  CHECK(result.tables[1].truncated && result.tables[1].cells[0].length == 32768);
  sql_query_free(&result);

  /* A result limit cuts only what the run keeps. The later statements still run. */
  static char many[2048], wide_select[8192];
  many[0] = 0;
  for (int i = 0; i < 18; ++i) strcat(many, "SELECT 1 AS n; ");
  strcat(many, "PRINT N'after many';");
  CHECK(run_once(options, many, 1000, 30, NULL, NULL, &result));
  CHECK(result.count == SQL_QUERY_RESULT_LIMIT && result.limited && has_message(&result, "after many"));
  sql_query_free(&result);
  strcpy(wide_select, "SELECT 0 AS c0");
  for (int i = 1; i < 300; ++i) sprintf(wide_select + strlen(wide_select), ", %d AS c%d", i, i);
  strcat(wide_select, "; PRINT N'after wide';");
  CHECK(run_once(options, wide_select, 1000, 30, NULL, NULL, &result));
  CHECK(result.count == 1 && result.tables[0].column_count == 300 && !result.limited && has_message(&result, "after wide"));
  CHECK(result.tables[0].numeric[0]);
  sql_query_free(&result);
  /* Number columns keep their type for sorting. */
  sql = "SELECT CAST(1 AS bigint) AS a, CAST(1.5 AS decimal(38,4)) AS b, CAST(1 AS float) AS c, "
        "CAST(1 AS money) AS d, N'1' AS e, CAST(1 AS bit) AS f, SYSDATETIME() AS g";
  CHECK(run_once(options, sql, 1000, 30, NULL, NULL, &result));
  CHECK(result.count == 1 && result.tables[0].column_count == 7);
  CHECK(!memcmp(result.tables[0].numeric, "\1\1\1\1\0\0\0", 7));
  sql_query_free(&result);
  sql = "SELECT TOP (300) REPLICATE(CAST(N'x' AS nvarchar(max)), 32768) AS big FROM sys.all_objects; "
        "SELECT N'kept' AS value; PRINT N'after big';";
  CHECK(run_once(options, sql, 1000, 30, NULL, NULL, &result));
  CHECK(result.count == 2 && result.limited && result.tables[0].truncated && result.tables[0].row_count == 256);
  CHECK(has_message(&result, "after big"));
  sql_query_free(&result);

  sql = "UPDATE sales.customers SET [na]]me] = N'unchanged' WHERE 1=0; SELECT id FROM sales.customers";
  CHECK(run_once(options, sql, 1000, 30, NULL, NULL, &result));
  CHECK(result.count == 1 && result.tables[0].row_count == 1 && has_message(&result, "(0 rows affected)"));
  sql_query_free(&result);

  /* GO ends a batch, so a variable does not reach the next batch, and an error
   * in one batch does not stop the next. Line numbers count from the text. */
  sql = "PRINT N'first'\nGO\nDECLARE @x int = 1\nSELECT @y\nGO 2\nSELECT N'after' AS value\n";
  CHECK(!run_once(options, sql, 1000, 30, NULL, NULL, &result));
  CHECK(has_message(&result, "first") && has_message(&result, "Line 4\nMust declare the scalar variable \"@y\""));
  CHECK(result.error_line == 4 && result.count == 1 && !strcmp(result.tables[0].cells[0].text, "after"));
  sql_query_free(&result);

  /* An error inside a called procedure names its own line, not a Query line.
   * An error in the batch that creates the procedure keeps its Query line. */
  sql = "CREATE OR ALTER PROCEDURE sales.fail_late AS\nBEGIN\n  SELECT 1/0 AS n\nEND\nGO\n\nEXEC sales.fail_late\n";
  CHECK(!run_once(options, sql, 1000, 30, NULL, NULL, &result));
  CHECK(result.error_line == 0 && has_message(&result, "Procedure fail_late, Line 3\n"));
  sql_query_free(&result);
  sql = "SELECT 1 AS n\nGO\nCREATE OR ALTER PROCEDURE sales.fail_early AS\nSELECT nam FROM sales.customers\n";
  CHECK(!run_once(options, sql, 1000, 30, NULL, NULL, &result));
  CHECK(result.error_line == 4 && has_message(&result, "Procedure fail_early, Line 4\n"));
  sql_query_free(&result);

  sql = "SELECT FROM";
  CHECK(!run_once(options, sql, 1000, 30, NULL, NULL, &result));
  CHECK(result.error[0] && !result.cancelled);
  sql_query_free(&result);

  sql = "WAITFOR DELAY '00:00:03'; SELECT 1";
  CHECK(!run_once(options, sql, 1000, 1, NULL, NULL, &result));
  CHECK(result.error[0] && !result.cancelled);
  sql_query_free(&result);

  /* A large generated script with a GO after each statement runs to its end. */
  {
    size_t size = 2100 * 160 + 64, used = 0;
    char *script = malloc(size);
    CHECK(script);
    for (int i = 1; i <= 2100; ++i)
      used += (size_t)snprintf(script + used, size - used, "-- %0120d\nDECLARE @n int = %d\nGO\n", 0, i);
    used += (size_t)snprintf(script + used, size - used, "PRINT N'after large'\n");
    CHECK(used > 256 * 1024);
    int ran = run_once(options, script, 1000, 0, NULL, NULL, &result);
    free(script);
    CHECK(ran && has_message(&result, "after large"));
    sql_query_free(&result);
  }

  /* A timeout of 0 means none. */
  sql = "WAITFOR DELAY '00:00:02'; SELECT N'waited' AS value";
  CHECK(run_once(options, sql, 1000, 0, NULL, NULL, &result));
  CHECK(result.count == 1 && !strcmp(result.tables[0].cells[0].text, "waited"));
  sql_query_free(&result);

  sql = "WAITFOR DELAY '00:00:20'; SELECT N'late' AS value";
  ULONGLONG started = GetTickCount64();
  CHECK(!run_once(options, sql, 1000, 30, cancel_after_start, &started, &result));
  CHECK(result.cancelled && GetTickCount64() - started < 15000);
  sql_query_free(&result);
  return 1;
}

/* A session keeps temporary tables, and a transaction stays open between runs
 * until Commit or Roll Back. Closing the session rolls it back. */
static int session_checks(SqlServerOptions *options) {
  SqlQueryResult result = {0};
  char error[256];
  int count = -1, ended = 0;
  unsigned session = sql_session_open(options, error);
  CHECK(session);
  const char *sql = "CREATE TABLE #scratch (id int); INSERT #scratch VALUES (1)";
  CHECK(sql_session_execute(session, 1, 0, sql, strlen(sql), 1000, 30, NULL, NULL, &result));
  sql_query_free(&result);
  sql = "SELECT COUNT(*) AS n FROM #scratch";
  CHECK(sql_session_execute(session, 1, 0, sql, strlen(sql), 1000, 30, NULL, NULL, &result));
  CHECK(result.count == 1 && !strcmp(result.tables[0].cells[0].text, "1"));
  sql_query_free(&result);

  sql = "INSERT sales.customers ([na]]me]) VALUES (N'Pending')";
  CHECK(sql_session_execute(session, 0, 0, sql, strlen(sql), 1000, 30, NULL, NULL, &result));
  CHECK(result.transaction_count == 1);
  sql_query_free(&result);
  sql = "SELECT 1 AS one";
  CHECK(!sql_session_execute(session, 1, 0, sql, strlen(sql), 1000, 30, NULL, NULL, &result));
  CHECK(result.transaction_count == 1 && strstr(result.error, "Auto Commit"));
  sql_query_free(&result);
  CHECK(sql_session_end_transaction(session, 0, &count, &ended, error) && count == 0);
  sql = "SELECT COUNT(*) AS n FROM sales.customers WHERE [na]]me] = N'Pending'";
  CHECK(sql_session_execute(session, 1, 0, sql, strlen(sql), 1000, 30, NULL, NULL, &result));
  CHECK(!strcmp(result.tables[0].cells[0].text, "0"));
  sql_query_free(&result);

  sql = "BEGIN TRANSACTION; INSERT sales.customers ([na]]me]) VALUES (N'Kept')";
  CHECK(sql_session_execute(session, 1, 0, sql, strlen(sql), 1000, 30, NULL, NULL, &result));
  CHECK(result.transaction_count == 1);
  sql_query_free(&result);
  CHECK(sql_session_end_transaction(session, 1, &count, &ended, error) && count == 0);
  sql = "DELETE sales.customers WHERE [na]]me] = N'Kept'";
  CHECK(sql_session_execute(session, 1, 0, sql, strlen(sql), 1000, 30, NULL, NULL, &result));
  CHECK(has_message(&result, "(1 row affected)"));
  sql_query_free(&result);

  sql = "SELECT id FROM sales.customers WHERE id = 1";
  CHECK(sql_session_execute(session, 1, 1, sql, strlen(sql), 1000, 30, NULL, NULL, &result));
  CHECK(result.count >= 1 && result.tables[0].column_count > 10 && !strcmp(result.tables[0].columns[0], "StmtText"));
  sql_query_free(&result);
  /* Explain turns SHOWPLAN off again, so the next run returns rows. */
  CHECK(sql_session_execute(session, 1, 0, sql, strlen(sql), 1000, 30, NULL, NULL, &result));
  CHECK(result.count == 1 && !strcmp(result.tables[0].columns[0], "id"));
  sql_query_free(&result);

  sql = "INSERT sales.customers ([na]]me]) VALUES (N'Abandoned')";
  CHECK(sql_session_execute(session, 0, 0, sql, strlen(sql), 1000, 30, NULL, NULL, &result));
  sql_query_free(&result);
  sql_session_close(session);
  CHECK(!sql_session_execute(session, 1, 0, sql, strlen(sql), 1000, 30, NULL, NULL, &result));
  CHECK(result.session_lost);
  sql_query_free(&result);
  CHECK(!sql_session_end_transaction(session, 1, &count, &ended, error) && ended);
  sql = "SELECT COUNT(*) AS n FROM sales.customers WHERE [na]]me] = N'Abandoned'";
  CHECK(run_once(options, sql, 1000, 30, NULL, NULL, &result));
  CHECK(!strcmp(result.tables[0].cells[0].text, "0"));
  sql_query_free(&result);
  return 1;
}

static const char *cell(SqlQueryTable *t, size_t row, const char *column) {
  for (size_t c = 0; c < t->column_count; ++c)
    if (!strcmp(t->columns[c], column)) return t->cells[row * t->column_count + c].text;
  return NULL;
}
/* Result editing: SQL Server describes the source table and its key, and a
 * script that finds a changed row stops and rolls back its earlier statements. */
static int edit_checks(SqlServerOptions *options) {
  SqlQueryResult result = {0};
  const char *sql = "EXEC sys.sp_describe_first_result_set @tsql = N'SELECT [na]]me] AS who FROM sales.customers', "
    "@params = NULL, @browse_information_mode = 1;";
  CHECK(run_once(options, sql, 1000, 30, NULL, NULL, &result));
  CHECK(result.count == 1 && result.tables[0].row_count == 2);
  SqlQueryTable *t = &result.tables[0];
  CHECK(!strcmp(cell(t, 0, "name"), "who") && !strcmp(cell(t, 0, "source_column"), "na]me"));
  CHECK(!strcmp(cell(t, 0, "is_updateable"), "1") && !strcmp(cell(t, 0, "is_hidden"), "0"));
  CHECK(!strcmp(cell(t, 1, "source_column"), "id") && !strcmp(cell(t, 1, "is_hidden"), "1"));
  CHECK(!strcmp(cell(t, 1, "is_part_of_unique_key"), "1") && !strcmp(cell(t, 1, "source_table"), "customers"));
  sql_query_free(&result);

  sql = "INSERT sales.customers ([na]]me]) VALUES (N'Edit me'); SELECT CONVERT(nvarchar(20), SCOPE_IDENTITY()) AS id";
  CHECK(run_once(options, sql, 1000, 30, NULL, NULL, &result));
  char id[32];
  snprintf(id, sizeof(id), "%s", result.tables[0].cells[0].text);
  sql_query_free(&result);
  char script[1024];
  snprintf(script, sizeof(script), "SET XACT_ABORT ON;\nBEGIN TRANSACTION;\n"
    "UPDATE [sales].[customers] SET [na]]me] = N'O''Neil' WHERE [id] = N'%s';\n"
    "IF @@ROWCOUNT <> 1 THROW 50001, N'Row 1 changed or no longer exists.', 1;\nCOMMIT TRANSACTION;\n", id);
  CHECK(run_once(options, script, 1000, 30, NULL, NULL, &result));
  sql_query_free(&result);
  snprintf(script, sizeof(script), "SET XACT_ABORT ON;\nBEGIN TRANSACTION;\n"
    "UPDATE [sales].[customers] SET [na]]me] = N'Lost' WHERE [id] = N'%s';\n"
    "IF @@ROWCOUNT <> 1 THROW 50001, N'Row 1 changed or no longer exists.', 1;\n"
    "DELETE FROM [sales].[customers] WHERE [id] = N'-1';\n"
    "IF @@ROWCOUNT <> 1 THROW 50001, N'Row 2 changed or no longer exists.', 1;\nCOMMIT TRANSACTION;\n", id);
  CHECK(!run_once(options, script, 1000, 30, NULL, NULL, &result));
  CHECK(has_message(&result, "Row 2 changed or no longer exists.") && result.transaction_count == 0);
  sql_query_free(&result);
  snprintf(script, sizeof(script), "SELECT [na]]me] FROM sales.customers WHERE id = %s; DELETE sales.customers WHERE id = %s", id, id);
  CHECK(run_once(options, script, 1000, 30, NULL, NULL, &result));
  CHECK(!strcmp(result.tables[0].cells[0].text, "O'Neil"));
  sql_query_free(&result);
  return 1;
}

/* The fixture's sales.customers columns. */
static int fixture_columns(const SqlServerCatalog *catalog) {
  int id = 0, label = 0;
  for (size_t i = 0; i < catalog->count; ++i) {
    const SqlServerColumn *c = &catalog->columns[i];
    if (strcmp(c->schema, "sales") || strcmp(c->table, "customers")) continue;
    if (!strcmp(c->name, "id") && !strcmp(c->type, "int") && c->identity && c->primary_key && !c->nullable) id = 1;
    if (!strcmp(c->name, "na]me") && !strcmp(c->type, "nvarchar(80)") && c->nullable) label = 1;
  }
  return id && label;
}
/* A database over the column limit lists its objects, and each table reads its own columns. */
static int lazy_column_checks(SqlServerOptions *options) {
  SqlServerCatalog catalog;
  int lazy = sql_server_read_schema_limit(options, 1, &catalog) && !catalog.columns_loaded && catalog.count == 0
    && catalog.object_count > 0 && !catalog.metadata_error[0];
  sql_server_catalog_free(&catalog);
  if (!lazy) { fprintf(stderr, "A large catalog did not load its columns on demand.\n"); return 0; }
  int read = sql_server_read_columns(options, "sales", "customers", &catalog) && fixture_columns(&catalog);
  sql_server_catalog_free(&catalog);
  if (!read) { fprintf(stderr, "One table's columns did not read.\n"); return 0; }
  return 1;
}

int main(int argc, char **argv) {
  const char *prefix = "(localdb)\\AnvilTest_";
  if (argc != 2 || strncmp(argv[1], prefix, strlen(prefix))) {
    fprintf(stderr, "Only an isolated AnvilTest LocalDB instance is permitted.\n"); return 1;
  }
  SqlServerOptions options = { argv[1], "AnvilTest", "", "", 1, 0, 0 };
  SqlServerCatalog catalog;
  if (!sql_server_read_schema(&options, &catalog)) {
    fprintf(stderr, "%s\n", catalog.error); sql_server_catalog_free(&catalog); return 1;
  }
  int valid = catalog.columns_loaded && fixture_columns(&catalog) && !strcmp(catalog.database, "AnvilTest");
  sql_server_catalog_free(&catalog);
  if (!valid) { fprintf(stderr, "Metadata did not match the fixture.\n"); return 1; }
  if (!lazy_column_checks(&options) || !execution_checks(&options) || !session_checks(&options) || !edit_checks(&options)) return 1;
  options.database = "AnvilTest};DATABASE={master";
  int injected = sql_server_read_schema(&options, &catalog);
  sql_server_catalog_free(&catalog);
  if (injected) { fprintf(stderr, "A database name changed the connection settings.\n"); return 1; }
  puts("SQL Server metadata, execution, batches, sessions, transactions, result edits, limits, cancellation and connection-value isolation passed.");
  return 0;
}
