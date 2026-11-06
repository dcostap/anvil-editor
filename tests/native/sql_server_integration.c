#include "sql_server.h"
#include "sql_query.h"
#include <windows.h>
#include <stdio.h>
#include <string.h>

#define CHECK(value) do { if (!(value)) { fprintf(stderr, "SQL execution check failed at line %d: %s\n", __LINE__, result.error); sql_query_free(&result); return 0; } } while (0)
static bool cancel_after_start(void *context) {
  return GetTickCount64() - *(ULONGLONG *)context > 1000;
}
static int execution_checks(SqlServerOptions *options) {
  SqlQueryResult result;
  const char *sql = "SELECT CAST(9223372036854775807 AS bigint) AS number, CAST(NULL AS nvarchar(10)) AS absent, "
                    "N'' AS empty_value, N'\xc3\xa9l\xc3\xa8ve' AS name, 0x0001FF AS bytes, N'a'+NCHAR(0)+N'b' AS nul, "
                    "CAST(0x3DD800DE AS nvarchar(2)) AS face, CAST(12345678901234567890.1234567890 AS decimal(30,10)) AS exact_value; SELECT N'end' AS last_value;";
  CHECK(sql_query_execute(options, sql, strlen(sql), 1000, 30, NULL, NULL, &result));
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
  sql_query_free(&result);

  sql = "SELECT 1 AS id UNION ALL SELECT 2; SELECT REPLICATE(CAST(N'x' AS nvarchar(max)),40000) AS long_value";
  CHECK(sql_query_execute(options, sql, strlen(sql), 1, 30, NULL, NULL, &result));
  CHECK(result.count == 2 && result.tables[0].row_count == 1 && result.tables[0].truncated);
  CHECK(result.tables[1].truncated && result.tables[1].cells[0].length == 32768);
  sql_query_free(&result);

  sql = "UPDATE sales.customers SET [na]]me] = N'unchanged' WHERE 1=0; SELECT id FROM sales.customers";
  CHECK(sql_query_execute(options, sql, strlen(sql), 1000, 30, NULL, NULL, &result));
  CHECK(result.count == 2 && !result.tables[0].column_count && result.tables[0].affected_rows == 0);
  CHECK(result.tables[1].row_count == 1);
  sql_query_free(&result);

  sql = "SELECT FROM";
  CHECK(!sql_query_execute(options, sql, strlen(sql), 1000, 30, NULL, NULL, &result));
  CHECK(result.error[0] && !result.cancelled);
  sql_query_free(&result);

  sql = "WAITFOR DELAY '00:00:03'; SELECT 1";
  CHECK(!sql_query_execute(options, sql, strlen(sql), 1000, 1, NULL, NULL, &result));
  CHECK(result.error[0] && !result.cancelled);
  sql_query_free(&result);

  sql = "WAITFOR DELAY '00:00:20'; SELECT N'late' AS value";
  ULONGLONG started = GetTickCount64();
  CHECK(!sql_query_execute(options, sql, strlen(sql), 1000, 30, cancel_after_start, &started, &result));
  CHECK(result.cancelled && GetTickCount64() - started < 15000);
  sql_query_free(&result);
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
  int id = 0, label = 0;
  for (size_t i = 0; i < catalog.count; ++i) {
    const SqlServerColumn *c = &catalog.columns[i];
    if (strcmp(c->schema, "sales") || strcmp(c->table, "customers")) continue;
    if (!strcmp(c->name, "id") && !strcmp(c->type, "int") && c->identity && c->primary_key && !c->nullable) id = 1;
    if (!strcmp(c->name, "na]me") && !strcmp(c->type, "nvarchar(80)") && c->nullable) label = 1;
  }
  int valid = id && label && !strcmp(catalog.database, "AnvilTest");
  sql_server_catalog_free(&catalog);
  if (!valid) { fprintf(stderr, "Metadata did not match the fixture.\n"); return 1; }
  if (!execution_checks(&options)) return 1;
  options.database = "AnvilTest};DATABASE={master";
  int injected = sql_server_read_schema(&options, &catalog);
  sql_server_catalog_free(&catalog);
  if (injected) { fprintf(stderr, "A database name changed the connection settings.\n"); return 1; }
  puts("SQL Server metadata, execution, limits, cancellation and connection-value isolation passed.");
  return 0;
}
