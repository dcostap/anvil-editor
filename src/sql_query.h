#ifndef ANVIL_SQL_QUERY_H
#define ANVIL_SQL_QUERY_H
#include <stdbool.h>
#include "sql_server.h"
#define SQL_QUERY_RESULT_LIMIT 16

typedef struct {
  char *text;
  size_t length;
} SqlQueryCell;
typedef struct {
  char **columns;
  SqlQueryCell *cells;
  size_t column_count, row_count, capacity;
  long long affected_rows;
  int truncated;
} SqlQueryTable;
typedef struct {
  SqlQueryTable tables[SQL_QUERY_RESULT_LIMIT];
  size_t count;
  int cancelled, limited;
  char error[512];
} SqlQueryResult;
typedef bool (*SqlQueryCancelled)(void *context);

/* Blocking, worker-only. Executes the supplied batch as written, in a fresh
 * connection with normal autocommit. Cancellation does not undo committed work.
 * Strings preserve server values; a NULL cell pointer is SQL NULL. */
int sql_query_execute(const SqlServerOptions *options, const char *sql, size_t length,
                      unsigned max_rows, unsigned timeout_seconds,
                      SqlQueryCancelled cancelled, void *context, SqlQueryResult *out);
void sql_query_free(SqlQueryResult *result);
/* For fixed catalog queries only. Opens with read-only access. */
int sql_query_read(const SqlServerOptions *options, const char *sql, size_t length,
                   SqlQueryCancelled cancelled, void *context, SqlQueryResult *out);
#endif
