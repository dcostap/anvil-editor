#include "sql_server.h"
#include <stdio.h>
#include <string.h>

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
  options.database = "AnvilTest};DATABASE={master";
  int injected = sql_server_read_schema(&options, &catalog);
  sql_server_catalog_free(&catalog);
  if (injected) { fprintf(stderr, "A database name changed the connection settings.\n"); return 1; }
  puts("SQL Server metadata and connection-value isolation passed.");
  return 0;
}
