#ifndef ANVIL_SQL_SERVER_H
#define ANVIL_SQL_SERVER_H
#include <stddef.h>

typedef struct {
  const char *server, *database, *user, *password;
  int integrated, trust_certificate, encrypt;
} SqlServerOptions;
typedef struct {
  char *schema, *table, *name, *type;
  int nullable, identity, primary_key;
} SqlServerColumn;
typedef struct {
  SqlServerColumn *columns;
  size_t count;
  char *database, *default_schema;
  int case_sensitive;
  char error[256];
} SqlServerCatalog;

/* Blocking, worker-only. All queries are fixed metadata SELECTs.
 * Connections close before return. No query text or credentials are retained. */
int sql_server_read_schema(const SqlServerOptions *options, SqlServerCatalog *out);
void sql_server_catalog_free(SqlServerCatalog *catalog);
#endif
