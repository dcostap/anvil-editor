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
typedef struct { char *schema, *name, *kind; } SqlServerObject;
typedef struct {
  SqlServerColumn *columns;
  size_t count;
  SqlServerObject *objects;
  size_t object_count;
  char *database, *default_schema;
  int case_sensitive;
  /* 0 when the database has more columns than the limit: each object's columns then load on demand. */
  int columns_loaded;
  /* The object list stops at SQL_SERVER_OBJECT_LIMIT. */
  int objects_truncated;
  /* Set when the login succeeded but a metadata read failed. The catalog is then empty. */
  char metadata_error[256];
  char error[256];
} SqlServerCatalog;

#define SQL_SERVER_OBJECT_LIMIT 200000
#define SQL_SERVER_COLUMN_LIMIT 50000

/* Blocking, worker-only. All queries are fixed metadata SELECTs.
 * Connections close before return. No query text or credentials are retained.
 * Fails only when the connection fails. */
int sql_server_read_schema(const SqlServerOptions *options, SqlServerCatalog *out);
/* The same, with another column limit. Tests use it. */
int sql_server_read_schema_limit(const SqlServerOptions *options, size_t column_limit, SqlServerCatalog *out);
/* The columns of one table or view, in out->columns. */
int sql_server_read_columns(const SqlServerOptions *options, const char *schema, const char *name, SqlServerCatalog *out);
void sql_server_catalog_free(SqlServerCatalog *catalog);
#endif
