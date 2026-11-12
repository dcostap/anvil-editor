#ifndef ANVIL_SQL_QUERY_H
#define ANVIL_SQL_QUERY_H
#include <stdbool.h>
#include "sql_server.h"
#define SQL_QUERY_RESULT_LIMIT 16
/* SQL Server's own limit for the columns of a SELECT. */
#define SQL_QUERY_COLUMN_LIMIT 4096
#define SQL_SESSION_LIMIT 64
/* The largest row limit. The cell and byte limits of a run still apply. */
#define SQL_QUERY_ROW_LIMIT 100000

typedef struct {
  char *text;
  size_t length;
} SqlQueryCell;
typedef struct {
  char **columns;
  SqlQueryCell *cells;
  size_t column_count, row_count, capacity;
  int truncated;
} SqlQueryTable;
/* Messages keep the order of the server's output, like SSMS's Messages tab:
 * PRINT text, warnings, errors and row counts. Line is a line of the submitted
 * text, or 0 when the message names none. */
typedef struct {
  char *text;
  unsigned line;
  int error;
} SqlQueryMessage;
typedef struct {
  SqlQueryTable tables[SQL_QUERY_RESULT_LIMIT];
  size_t count;
  SqlQueryMessage *messages;
  size_t message_count, message_capacity, message_bytes;
  int cancelled, limited, session_lost;
  /* @@TRANCOUNT after the run, or -1 when it is unknown. */
  int transaction_count;
  /* The first error, for a status line. */
  char error[512];
  unsigned error_line;
} SqlQueryResult;
typedef bool (*SqlQueryCancelled)(void *context);

void sql_query_free(SqlQueryResult *result);
/* Checks text and limits without a connection. Writes a message on failure. */
int sql_query_check(const char *sql, size_t length, unsigned max_rows, unsigned timeout_seconds,
                    char *error, size_t size);
/* For fixed catalog queries only. Opens a read-only connection for one batch. */
int sql_query_read(const SqlServerOptions *options, const char *sql, size_t length,
                   SqlQueryCancelled cancelled, void *context, SqlQueryResult *out);

/* A SQL Session is one server connection that stays open between worker jobs,
 * like a DbVisualizer SQL Commander editor connection. Temporary tables, SET
 * options and transactions carry from one run to the next. Each call is blocking
 * and worker-only. One job uses a session at a time.
 * Returns the session ID, or 0 with an error. */
unsigned sql_session_open(const SqlServerOptions *options, char error[256]);
/* Splits the text at GO lines and runs each batch. A failed batch does not stop
 * later batches. With explain, SHOWPLAN_ALL returns plans instead of running SQL.
 * Auto Commit cannot turn on while a transaction is open. A lost connection
 * closes the session and sets session_lost. */
int sql_session_execute(unsigned id, int autocommit, int explain, const char *sql, size_t length,
                        unsigned max_rows, unsigned timeout_seconds,
                        SqlQueryCancelled cancelled, void *context, SqlQueryResult *out);
/* Commits or rolls back all open transactions. Reports the new @@TRANCOUNT.
 * Ended reports that the session no longer exists. */
int sql_session_end_transaction(unsigned id, int commit, int *transaction_count, int *ended, char error[256]);
/* Closes the connection. The server rolls back an open transaction. */
void sql_session_close(unsigned id);
#endif
