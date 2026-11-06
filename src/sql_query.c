#include "sql_query.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

void sql_query_free(SqlQueryResult *result) {
  for (size_t i = 0; i < result->count; ++i) {
    SqlQueryTable *t = &result->tables[i];
    if (t->columns) for (size_t j = 0; j < t->column_count; ++j) free(t->columns[j]);
    if (t->cells) for (size_t j = 0; j < t->capacity * t->column_count; ++j) free(t->cells[j].text);
    free(t->columns); free(t->cells);
  }
  memset(result, 0, sizeof(*result));
}
#ifdef _WIN32
#include "sql_server_internal.h"
#include <wchar.h>
#define CELL_UNITS 32768
#define RESULT_BYTES (8 * 1024 * 1024)
#define RESULT_CELLS 262144

typedef struct {
  HANDLE stop;
  SQLHSTMT statement;
  SqlQueryCancelled cancelled;
  void *context;
  ULONGLONG deadline;
  LONG requested, timed_out;
} QueryWatch;

/* ODBC permits cancelling a statement from another thread. The execution
 * thread joins this thread before releasing the statement or cancel token. */
static DWORD WINAPI watch_query(void *pointer) {
  QueryWatch *w = pointer;
  while (WaitForSingleObject(w->stop, 10) == WAIT_TIMEOUT) {
    int timeout = GetTickCount64() >= w->deadline;
    if (timeout || (w->cancelled && w->cancelled(w->context))) {
      InterlockedExchange(&w->requested, 1);
      InterlockedExchange(&w->timed_out, timeout);
      SQLCancel(w->statement);
      break;
    }
  }
  return 0;
}
static char *utf8(const SQLWCHAR *text, int length, size_t *bytes) {
  int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, (const wchar_t *)text, length, NULL, 0, NULL, NULL);
  if (!n && length) return NULL;
  char *out = malloc((size_t)n + 1);
  if (!out) return NULL;
  if (n && !WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, (const wchar_t *)text, length, out, n, NULL, NULL)) {
    free(out); return NULL;
  }
  out[n] = 0;
  if (bytes) *bytes = (size_t)n;
  return out;
}
static void query_error(SqlQueryResult *out, SQLHSTMT statement, const char *action) {
  SQLWCHAR state[6], message[128]; SQLINTEGER native; SQLSMALLINT length;
  SQLRETURN rc = SQLGetDiagRecW(SQL_HANDLE_STMT, statement, 1, state, &native, message, 128, &length);
  if (!SQL_SUCCEEDED(rc)) { snprintf(out->error, sizeof(out->error), "%s failed.", action); return; }
  if (length > 127) length = 127;
  if (length > 0 && message[length - 1] >= 0xd800 && message[length - 1] <= 0xdbff) --length;
  char *detail = utf8(message, length, NULL);
  char code[6]; for (int i = 0; i < 6; ++i) code[i] = (char)state[i];
  snprintf(out->error, sizeof(out->error), "%s [%s]: %s", action, code, detail ? detail : "Server error");
  free(detail);
}
/* Read text in chunks. This also preserves exact decimals and large integers.
 * ODBC represents binary values as hexadecimal when converted to SQL_C_WCHAR. */
static int read_value(SQLHSTMT statement, unsigned column, SqlQueryCell *out, int *truncated, size_t *bytes) {
  SQLWCHAR chunk[1024];
  SQLWCHAR *text = malloc((CELL_UNITS + 1) * sizeof(SQLWCHAR));
  if (!text) return 0;
  size_t used = 0;
  int ok = 0, capped = 0;
  for (;;) {
    SQLLEN length = 0;
    SQLRETURN rc = SQLGetData(statement, (SQLUSMALLINT)column, SQL_C_WCHAR, chunk, sizeof(chunk), &length);
    if (!SQL_SUCCEEDED(rc)) goto done;
    if (length == SQL_NULL_DATA) { ok = 1; goto done; }
    if (length < 0 && (length != SQL_NO_TOTAL || rc == SQL_SUCCESS)) goto done;
    size_t n = length >= 0 && length < (SQLLEN)sizeof(chunk) ? (size_t)length / sizeof(SQLWCHAR) : 1023;
    size_t keep = n < CELL_UNITS - used ? n : CELL_UNITS - used;
    memcpy(text + used, chunk, keep * sizeof(SQLWCHAR)); used += keep;
    if (keep < n || (used == CELL_UNITS && rc == SQL_SUCCESS_WITH_INFO)) { capped = *truncated = 1; break; }
    if (rc == SQL_SUCCESS || n < 1023) break;
  }
  /* A capped value must not end between UTF-16 surrogate units. */
  if (capped && used && text[used - 1] >= 0xd800 && text[used - 1] <= 0xdbff) --used;
  out->text = utf8(text, (int)used, &out->length);
  if (!out->text) goto done;
  *bytes += out->length;
  ok = 1;
done:
  free(text);
  return ok;
}
int sql_query_execute(const SqlServerOptions *options, const char *sql, size_t length,
                      unsigned max_rows, unsigned timeout_seconds,
                      SqlQueryCancelled cancelled, void *context, SqlQueryResult *out) {
  memset(out, 0, sizeof(*out));
  SqlServerConnection connection = {0};
  SQLHSTMT statement = SQL_NULL_HSTMT;
  SQLWCHAR *wide = NULL;
  QueryWatch watch = {0};
  HANDLE thread = NULL;
  int success = 0;
  size_t bytes = 0, cells = 0;
  if (!sql || !length || length > 256 * 1024 || memchr(sql, 0, length) ||
      !max_rows || max_rows > 10000 || !timeout_seconds || timeout_seconds > 300) {
    snprintf(out->error, sizeof(out->error), "Invalid SQL text or execution limits."); goto done;
  }
  int units = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, sql, (int)length, NULL, 0);
  if (!units) { snprintf(out->error, sizeof(out->error), "SQL text contains invalid UTF-8."); goto done; }
  wide = malloc(((size_t)units + 1) * sizeof(SQLWCHAR));
  if (!wide) goto done;
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, sql, (int)length, (wchar_t *)wide, units);
  wide[units] = 0;
  if (cancelled && cancelled(context)) { out->cancelled = 1; goto done; }
  if (!sql_server_open(options, 0, &connection, out->error)) goto done;
  if (cancelled && cancelled(context)) { out->cancelled = 1; goto done; }
  if (!SQL_SUCCEEDED(SQLAllocHandle(SQL_HANDLE_STMT, connection.dbc, &statement)) ||
      !SQL_SUCCEEDED(SQLSetStmtAttr(statement, SQL_ATTR_QUERY_TIMEOUT, (SQLPOINTER)(uintptr_t)timeout_seconds, 0))) goto done;
  watch.statement = statement; watch.cancelled = cancelled; watch.context = context;
  watch.deadline = GetTickCount64() + (ULONGLONG)timeout_seconds * 1000;
  watch.stop = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (!watch.stop) goto done;
  thread = CreateThread(NULL, 0, watch_query, &watch, 0, NULL);
  if (!thread) goto done;
  SQLRETURN rc = SQLExecDirectW(statement, wide, units);
  for (;;) {
    if (InterlockedCompareExchange(&watch.requested, 0, 0)) goto done;
    if (!SQL_SUCCEEDED(rc) && rc != SQL_NO_DATA) { query_error(out, statement, "SQL execution"); goto done; }
    SQLSMALLINT columns = 0;
    if (!SQL_SUCCEEDED(SQLNumResultCols(statement, &columns))) goto done;
    SQLLEN affected = -1;
    if (!columns && !SQL_SUCCEEDED(SQLRowCount(statement, &affected))) goto done;
    if (columns || affected >= 0) {
      if (out->count == SQL_QUERY_RESULT_LIMIT || columns > 128) { out->limited = 1; break; }
      SqlQueryTable *t = &out->tables[out->count++];
      t->column_count = (size_t)columns; t->affected_rows = (long long)affected;
      if (columns) {
        t->columns = calloc((size_t)columns, sizeof(char *));
        if (!t->columns) goto done;
        for (SQLSMALLINT column = 0; column < columns; ++column) {
          SQLWCHAR name[1024]; SQLSMALLINT name_length, type, decimals, nullable; SQLULEN size;
          if (!SQL_SUCCEEDED(SQLDescribeColW(statement, (SQLUSMALLINT)(column + 1), name, 1024,
                                            &name_length, &type, &size, &decimals, &nullable)) || name_length >= 1024) goto done;
          t->columns[column] = utf8(name, name_length, NULL);
          if (!t->columns[column]) goto done;
        }
        for (;;) {
          if (InterlockedCompareExchange(&watch.requested, 0, 0)) goto done;
          rc = SQLFetch(statement);
          if (rc == SQL_NO_DATA) break;
          if (!SQL_SUCCEEDED(rc)) { query_error(out, statement, "Result read"); goto done; }
          if (t->row_count == max_rows) { t->truncated = 1; break; }
          if (cells + (size_t)columns > RESULT_CELLS) { out->limited = 1; goto complete; }
          if (t->row_count == t->capacity) {
            size_t capacity = t->capacity ? t->capacity * 2 : 16;
            SqlQueryCell *p = realloc(t->cells, capacity * (size_t)columns * sizeof(*p));
            if (!p) goto done;
            memset(p + t->capacity * columns, 0, (capacity - t->capacity) * columns * sizeof(*p));
            t->cells = p; t->capacity = capacity;
          }
          for (unsigned column = 0; column < (unsigned)columns; ++column) {
            SqlQueryCell *value = &t->cells[t->row_count * columns + column];
            if (!read_value(statement, column + 1, value, &t->truncated, &bytes)) {
              query_error(out, statement, "Cell read"); goto done;
            }
            if (bytes > RESULT_BYTES) { out->limited = 1; goto complete; }
          }
          ++t->row_count; cells += (size_t)columns;
        }
      }
    }
    rc = SQLMoreResults(statement);
    if (rc == SQL_NO_DATA) break;
  }
complete:
  success = 1;
done:
  if (thread) { SetEvent(watch.stop); WaitForSingleObject(thread, INFINITE); CloseHandle(thread); }
  if (watch.stop) CloseHandle(watch.stop);
  if (watch.requested) {
    success = 0;
    if (watch.timed_out) snprintf(out->error, sizeof(out->error), "SQL execution exceeded its time limit.");
    else { out->cancelled = 1; out->error[0] = 0; }
  }
  if (statement) {
    if (out->limited) SQLCancel(statement);
    SQLFreeHandle(SQL_HANDLE_STMT, statement);
  }
  sql_server_close(&connection);
  free(wide);
  if (!success && !out->cancelled && !out->error[0]) snprintf(out->error, sizeof(out->error), "Could not complete SQL execution.");
  return success;
}
#else
int sql_query_execute(const SqlServerOptions *options, const char *sql, size_t length,
                      unsigned max_rows, unsigned timeout_seconds,
                      SqlQueryCancelled cancelled, void *context, SqlQueryResult *out) {
  (void)options; (void)sql; (void)length; (void)max_rows; (void)timeout_seconds; (void)cancelled; (void)context;
  memset(out, 0, sizeof(*out));
  snprintf(out->error, sizeof(out->error), "SQL Server execution currently requires Windows.");
  return 0;
}
#endif
