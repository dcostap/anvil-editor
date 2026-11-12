#include "sql_query.h"
#include "sql_batch.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

void sql_query_free(SqlQueryResult *result) {
  for (size_t i = 0; i < result->count; ++i) {
    SqlQueryTable *t = &result->tables[i];
    if (t->columns) for (size_t j = 0; j < t->column_count; ++j) free(t->columns[j]);
    if (t->cells) for (size_t j = 0; j < t->capacity * t->column_count; ++j) free(t->cells[j].text);
    free(t->columns); free(t->cells); free(t->numeric);
  }
  for (size_t i = 0; i < result->message_count; ++i) free(result->messages[i].text);
  free(result->messages);
  memset(result, 0, sizeof(*result));
}
#ifdef _WIN32
#include "sql_server_internal.h"
#include <wchar.h>
#include <limits.h>
#define CELL_UNITS 32768
#define RESULT_BYTES (8 * 1024 * 1024)
#define RESULT_CELLS 262144
#define MESSAGE_LIMIT 4096
#define MESSAGE_BYTES (1024 * 1024)
/* SQL Server driver fields from msodbcsql.h. */
#define SQL_DIAG_SS_SEVERITY (-1151)
#define SQL_DIAG_SS_MSGSTATE (-1150)
#define SQL_DIAG_SS_LINE (-1154)
#define SQL_DIAG_SS_PROCNAME (-1153)

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
static int stopped(QueryWatch *w) { return InterlockedCompareExchange(&w->requested, 0, 0) != 0; }

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
static SQLWCHAR *wide(const char *sql, size_t length, int *units) {
  *units = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, sql, (int)length, NULL, 0);
  if (!*units) return NULL;
  SQLWCHAR *out = malloc(((size_t)*units + 1) * sizeof(SQLWCHAR));
  if (!out) return NULL;
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, sql, (int)length, (wchar_t *)out, *units);
  out[*units] = 0;
  return out;
}

static void add_message(SqlQueryResult *out, const char *text, unsigned line, int error) {
  size_t length = strlen(text);
  if (error && !out->error[0]) {
    if (line) snprintf(out->error, sizeof(out->error), "Line %u: %s", line, text);
    else snprintf(out->error, sizeof(out->error), "%s", text);
    out->error_line = line;
  }
  if (out->message_count == MESSAGE_LIMIT || out->message_bytes + length > MESSAGE_BYTES) { out->limited = 1; return; }
  if (out->message_count == out->message_capacity) {
    size_t capacity = out->message_capacity ? out->message_capacity * 2 : 16;
    SqlQueryMessage *p = realloc(out->messages, capacity * sizeof(*p));
    if (!p) { out->limited = 1; return; }
    out->messages = p; out->message_capacity = capacity;
  }
  char *copy = malloc(length + 1);
  if (!copy) { out->limited = 1; return; }
  memcpy(copy, text, length + 1);
  out->messages[out->message_count++] = (SqlQueryMessage){ copy, line, error };
  out->message_bytes += length;
}
static void count_message(SqlQueryResult *out, long long rows, const char *suffix) {
  char text[96];
  snprintf(text, sizeof(text), "(%lld row%s %s)", rows, rows == 1 ? "" : "s", suffix);
  add_message(out, text, 0, 0);
}

/* Reads every diagnostic record of the last call. SQLSTATE class 01 is a
 * warning or PRINT text. Class 08 means the connection is gone. */
/* Module is the procedure that the batch creates, or NULL. A line inside
 * another procedure is a line of that procedure, not of the Query. */
static void collect(SqlQueryResult *out, SQLSMALLINT type, SQLHANDLE handle, unsigned base_line,
                    const char *module, int cancelling, int *lost) {
  for (SQLSMALLINT record = 1; record < 512; ++record) {
    SQLWCHAR state[6] = {0};
    SQLINTEGER native = 0;
    SQLSMALLINT length = 0;
    SQLRETURN rc = SQLGetDiagRecW(type, handle, record, state, &native, NULL, 0, &length);
    if (rc == SQL_NO_DATA || !SQL_SUCCEEDED(rc)) break;
    SQLWCHAR *message = calloc((size_t)length + 1, sizeof(SQLWCHAR));
    if (!message) break;
    rc = SQLGetDiagRecW(type, handle, record, state, &native, message, (SQLSMALLINT)(length + 1), &length);
    char code[6];
    for (int i = 0; i < 6; ++i) code[i] = (char)state[i];
    SQLINTEGER severity = 0, message_state = 0, line = 0;
    SQLGetDiagFieldW(type, handle, record, SQL_DIAG_SS_SEVERITY, &severity, SQL_IS_INTEGER, NULL);
    SQLGetDiagFieldW(type, handle, record, SQL_DIAG_SS_MSGSTATE, &message_state, SQL_IS_INTEGER, NULL);
    SQLGetDiagFieldW(type, handle, record, SQL_DIAG_SS_LINE, &line, SQL_IS_INTEGER, NULL);
    line &= 0xffff;
    SQLWCHAR procedure_wide[129] = {0};
    SQLSMALLINT procedure_bytes = 0;
    char *procedure = NULL;
    if (SQL_SUCCEEDED(SQLGetDiagFieldW(type, handle, record, SQL_DIAG_SS_PROCNAME, procedure_wide,
                                       sizeof(procedure_wide) - sizeof(SQLWCHAR), &procedure_bytes)) && procedure_wide[0])
      procedure = utf8(procedure_wide, (int)wcslen((const wchar_t *)procedure_wide), NULL);
    char *text = SQL_SUCCEEDED(rc) ? utf8(message, length, NULL) : NULL;
    free(message);
    if (!text) { free(procedure); continue; }
    /* The driver prefixes each message with its component names. */
    const char *body = text;
    while (*body == '[') {
      const char *close = strchr(body, ']');
      if (!close) break;
      body = close + 1;
    }
    if (!strncmp(code, "08", 2)) *lost = 1;
    int error = strncmp(code, "01", 2) != 0;
    if (!strcmp(code, "HY008") && cancelling) error = -1;
    if (error > 0 && native > 0) {
      /* Newer servers can name the schema too. */
      const char *dot = procedure ? strrchr(procedure, '.') : NULL;
      const char *short_name = dot ? dot + 1 : procedure;
      int own = !procedure || (module && base_line && !_stricmp(short_name, module));
      unsigned shown = own ? (line ? base_line + (unsigned)line - 1 : 0) : (unsigned)line;
      unsigned absolute = own ? shown : 0;
      char place[192];
      if (procedure) snprintf(place, sizeof(place), "Procedure %s, Line %u", short_name, shown);
      else snprintf(place, sizeof(place), "Line %u", shown);
      if (!out->error[0]) {
        if (shown) snprintf(out->error, sizeof(out->error), "%s: %s", place, body);
        else snprintf(out->error, sizeof(out->error), "%s", body);
        out->error_line = absolute;
      }
      size_t size = strlen(body) + sizeof(place) + 64;
      char *formatted = malloc(size);
      if (formatted) {
        snprintf(formatted, size, "Msg %ld, Level %ld, State %ld, %s\n%s", (long)native, (long)severity,
                 (long)message_state, place, body);
        add_message(out, formatted, absolute, 1);
        free(formatted);
      }
    } else if (error >= 0) add_message(out, body, 0, error);
    free(text);
    free(procedure);
  }
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

typedef struct {
  SqlQueryResult *out;
  QueryWatch *watch;
  unsigned max_rows;
  size_t bytes, cells;
  int lost;
  /* The procedure that the current batch creates, or empty. */
  char module[129];
} Run;

/* Returns 0 when the run must stop: a lost connection or a failure. A result
 * limit only cuts what the run keeps. SQLMoreResults then discards the rest of
 * the result, so the later statements of the batch still run. */
static int read_result(Run *run, SQLHSTMT statement, SQLSMALLINT columns, unsigned base_line) {
  SqlQueryResult *out = run->out;
  if (out->count == SQL_QUERY_RESULT_LIMIT || columns > SQL_QUERY_COLUMN_LIMIT) {
    out->limited = 1;
    add_message(out, out->count == SQL_QUERY_RESULT_LIMIT ? "(Result not shown. A run shows at most 16 results.)"
                                                           : "(Result not shown. It has more than 4,096 columns.)", 0, 0);
    return 1;
  }
  SqlQueryTable *t = &out->tables[out->count++];
  t->column_count = (size_t)columns;
  t->columns = calloc((size_t)columns, sizeof(char *));
  t->numeric = calloc((size_t)columns, 1);
  if (!t->columns || !t->numeric) return 0;
  for (SQLSMALLINT column = 0; column < columns; ++column) {
    SQLWCHAR name[1024]; SQLSMALLINT name_length, type, decimals, nullable; SQLULEN size;
    if (!SQL_SUCCEEDED(SQLDescribeColW(statement, (SQLUSMALLINT)(column + 1), name, 1024,
                                      &name_length, &type, &size, &decimals, &nullable)) || name_length >= 1024) return 0;
    t->columns[column] = utf8(name, name_length, NULL);
    if (!t->columns[column]) return 0;
    t->numeric[column] = type == SQL_TINYINT || type == SQL_SMALLINT || type == SQL_INTEGER || type == SQL_BIGINT ||
                         type == SQL_DECIMAL || type == SQL_NUMERIC || type == SQL_REAL || type == SQL_FLOAT ||
                         type == SQL_DOUBLE;
  }
  int cut = 0;
  for (;;) {
    if (stopped(run->watch)) return 0;
    SQLRETURN rc = SQLFetch(statement);
    if (rc == SQL_NO_DATA) break;
    if (rc == SQL_SUCCESS_WITH_INFO || rc == SQL_ERROR)
      collect(out, SQL_HANDLE_STMT, statement, base_line, run->module, stopped(run->watch), &run->lost);
    if (!SQL_SUCCEEDED(rc)) { if (run->lost || stopped(run->watch)) return 0; break; }
    if (t->row_count == run->max_rows) { t->truncated = 1; break; }
    if (run->cells + (size_t)columns > RESULT_CELLS || run->bytes > RESULT_BYTES) { cut = 1; break; }
    if (t->row_count == t->capacity) {
      size_t capacity = t->capacity ? t->capacity * 2 : 16;
      SqlQueryCell *p = realloc(t->cells, capacity * (size_t)columns * sizeof(*p));
      if (!p) return 0;
      memset(p + t->capacity * columns, 0, (capacity - t->capacity) * columns * sizeof(*p));
      t->cells = p; t->capacity = capacity;
    }
    for (unsigned column = 0; column < (unsigned)columns; ++column) {
      SqlQueryCell *value = &t->cells[t->row_count * columns + column];
      if (!read_value(statement, column + 1, value, &t->truncated, &run->bytes)) {
        collect(out, SQL_HANDLE_STMT, statement, base_line, run->module, stopped(run->watch), &run->lost);
        return 0;
      }
      if (run->bytes > RESULT_BYTES) { cut = 1; break; }
    }
    /* A row that passes the text limit is not kept. */
    if (cut) break;
    ++t->row_count; run->cells += (size_t)columns;
  }
  if (cut) {
    out->limited = t->truncated = 1;
    char text[128];
    snprintf(text, sizeof(text), "(%zu rows shown. A run keeps at most 262,144 values and 8 MiB of text.)", t->row_count);
    add_message(out, text, 0, 0);
  } else if (t->truncated) {
    char text[128];
    snprintf(text, sizeof(text), "(%zu rows shown. The row limit stopped the read.)", t->row_count);
    add_message(out, text, 0, 0);
  } else count_message(out, (long long)t->row_count, "affected");
  return 1;
}

/* Runs one batch and reads all of its results. A statement error does not end
 * the batch: SQL Server can run the statements after it. */
static int run_batch(Run *run, SQLHSTMT statement, const SQLWCHAR *text, int units, unsigned base_line) {
  SQLRETURN rc = SQLExecDirectW(statement, (SQLWCHAR *)text, units);
  int first = 1;
  for (int guard = 0; guard < 100000; ++guard, first = 0) {
    if (stopped(run->watch)) return 0;
    if (rc == SQL_SUCCESS_WITH_INFO || rc == SQL_ERROR)
      collect(run->out, SQL_HANDLE_STMT, statement, base_line, run->module, stopped(run->watch), &run->lost);
    if (run->lost) return 0;
    if (rc == SQL_NO_DATA && !first) break;
    if (SQL_SUCCEEDED(rc) || rc == SQL_NO_DATA) {
      SQLSMALLINT columns = 0;
      if (rc != SQL_NO_DATA && !SQL_SUCCEEDED(SQLNumResultCols(statement, &columns))) return 0;
      if (columns) {
        if (!read_result(run, statement, columns, base_line)) return 0;
      } else {
        SQLLEN affected = -1;
        if (rc == SQL_NO_DATA) affected = 0;
        else SQLRowCount(statement, &affected);
        if (affected >= 0) count_message(run->out, (long long)affected, "affected");
      }
    }
    rc = SQLMoreResults(statement);
    if (rc == SQL_NO_DATA) break;
  }
  SQLFreeStmt(statement, SQL_CLOSE);
  return 1;
}

/* Runs fixed text that returns no rows, such as SET or COMMIT statements. */
static int run_fixed(SQLHDBC dbc, const wchar_t *text, SqlQueryResult *out, int *lost) {
  SQLHSTMT statement = SQL_NULL_HSTMT;
  if (!SQL_SUCCEEDED(SQLAllocHandle(SQL_HANDLE_STMT, dbc, &statement))) return 0;
  SQLRETURN rc = SQLExecDirectW(statement, (SQLWCHAR *)text, SQL_NTS);
  if (rc == SQL_ERROR || rc == SQL_SUCCESS_WITH_INFO) collect(out, SQL_HANDLE_STMT, statement, 0, NULL, 0, lost);
  while (SQL_SUCCEEDED(rc)) rc = SQLMoreResults(statement);
  SQLFreeHandle(SQL_HANDLE_STMT, statement);
  return rc == SQL_NO_DATA || SQL_SUCCEEDED(rc);
}
static int transaction_count(SQLHDBC dbc, int *lost) {
  SQLHSTMT statement = SQL_NULL_HSTMT;
  SQLINTEGER count = -1;
  SQLLEN length = 0;
  if (!SQL_SUCCEEDED(SQLAllocHandle(SQL_HANDLE_STMT, dbc, &statement))) return -1;
  SQLRETURN rc = SQLExecDirectW(statement, (SQLWCHAR *)L"SELECT @@TRANCOUNT", SQL_NTS);
  if (SQL_SUCCEEDED(rc) && SQL_SUCCEEDED(SQLFetch(statement)) &&
      SQL_SUCCEEDED(SQLGetData(statement, 1, SQL_C_SLONG, &count, sizeof(count), &length))) {}
  else {
    SqlQueryResult ignored = {0};
    collect(&ignored, SQL_HANDLE_STMT, statement, 0, NULL, 0, lost);
    sql_query_free(&ignored);
    count = -1;
  }
  SQLFreeHandle(SQL_HANDLE_STMT, statement);
  return (int)count;
}

int sql_query_check(const char *sql, size_t length, unsigned max_rows, unsigned timeout_seconds,
                    char *error, size_t size) {
  int units = 0;
  if (!max_rows || max_rows > SQL_QUERY_ROW_LIMIT || timeout_seconds > SQL_QUERY_TIMEOUT_MAX)
    snprintf(error, size, "Invalid SQL execution limits.");
  else if (!sql || !length || length > 256 * 1024 || memchr(sql, 0, length))
    snprintf(error, size, "SQL text must be 1 byte to 256 KiB, without NUL characters.");
  else if (length > INT_MAX || !(units = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, sql, (int)length, NULL, 0)))
    snprintf(error, size, "SQL text contains invalid UTF-8.");
  else return 1;
  return 0;
}

static int run_text(SQLHDBC dbc, const char *sql, size_t length, int split, int explain, unsigned max_rows,
                    unsigned timeout_seconds, SqlQueryCancelled cancelled, void *context, SqlQueryResult *out, int *lost) {
  SQLHSTMT statement = SQL_NULL_HSTMT;
  QueryWatch watch = {0};
  HANDLE thread = NULL;
  SqlBatch *batches = NULL;
  Run run = { out, &watch, max_rows, 0, 0, 0 };
  int success = 0, explaining = 0, complete = 0;
  if (!sql_query_check(sql, length, max_rows, timeout_seconds, out->error, sizeof(out->error))) goto done;
  int units = 0;
  batches = malloc(SQL_BATCH_LIMIT * sizeof(*batches));
  if (!batches) goto done;
  int count = 1;
  if (split) count = sql_batch_split(sql, length, batches, SQL_BATCH_LIMIT);
  else batches[0] = (SqlBatch){ 0, length, 1, 1 };
  if (count < 0) {
    snprintf(out->error, sizeof(out->error), "The SQL has more than %d batches or an invalid GO count.", SQL_BATCH_LIMIT);
    goto done;
  }
  if (cancelled && cancelled(context)) { out->cancelled = 1; goto done; }
  if (!SQL_SUCCEEDED(SQLAllocHandle(SQL_HANDLE_STMT, dbc, &statement)) ||
      !SQL_SUCCEEDED(SQLSetStmtAttr(statement, SQL_ATTR_QUERY_TIMEOUT, (SQLPOINTER)(uintptr_t)timeout_seconds, 0))) goto done;
  watch.statement = statement; watch.cancelled = cancelled; watch.context = context;
  /* A timeout of 0 means none, for ODBC and for the watch. */
  watch.deadline = timeout_seconds ? GetTickCount64() + (ULONGLONG)timeout_seconds * 1000 : ~0ULL;
  watch.stop = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (!watch.stop) goto done;
  thread = CreateThread(NULL, 0, watch_query, &watch, 0, NULL);
  if (!thread) goto done;
  if (explain) {
    if (!run_fixed(dbc, L"SET SHOWPLAN_ALL ON", out, &run.lost)) goto done;
    explaining = 1;
  }
  for (int i = 0; i < count; ++i) {
    SQLWCHAR *text = wide(sql + batches[i].start, batches[i].end - batches[i].start, &units);
    if (!text) goto done;
    if (!sql_batch_module(sql + batches[i].start, batches[i].end - batches[i].start, run.module, sizeof(run.module)))
      run.module[0] = 0;
    for (unsigned r = 0; r < batches[i].repeat; ++r) {
      int ok = run_batch(&run, statement, text, units, batches[i].line);
      if (!ok) { free(text); goto finish; }
    }
    free(text);
  }
  complete = 1;
finish:
  success = !stopped(&watch) && !run.lost && !out->error[0];
done:
  if (thread) { SetEvent(watch.stop); WaitForSingleObject(thread, INFINITE); CloseHandle(thread); }
  if (watch.stop) CloseHandle(watch.stop);
  if (watch.requested) {
    success = 0;
    if (watch.timed_out) snprintf(out->error, sizeof(out->error), "SQL execution exceeded its time limit.");
    else { out->cancelled = 1; out->error[0] = 0; out->error_line = 0; }
  }
  if (statement) {
    /* A run that stopped early must not wait while the driver reads the rest. */
    if (!complete) SQLCancel(statement);
    SQLFreeHandle(SQL_HANDLE_STMT, statement);
  }
  if (explaining && !run.lost) run_fixed(dbc, L"SET SHOWPLAN_ALL OFF", out, &run.lost);
  free(batches);
  if (run.lost) {
    *lost = 1; success = 0;
    snprintf(out->error, sizeof(out->error), "The connection to SQL Server was lost. The server rolled back any open transaction.");
  }
  if (!success && !out->cancelled && !out->error[0]) snprintf(out->error, sizeof(out->error), "Could not complete SQL execution.");
  return success;
}

int sql_query_read(const SqlServerOptions *options, const char *sql, size_t length,
                   SqlQueryCancelled cancelled, void *context, SqlQueryResult *out) {
  memset(out, 0, sizeof(*out));
  out->transaction_count = -1;
  char error[256] = "";
  SqlServerConnection connection = {0};
  if (!sql_server_open(options, 1, &connection, error)) {
    snprintf(out->error, sizeof(out->error), "%s", error); return 0;
  }
  int lost = 0;
  int ok = run_text(connection.dbc, sql, length, 0, 0, 10000, 30, cancelled, context, out, &lost);
  sql_server_close(&connection);
  return ok;
}

typedef struct { SqlServerConnection connection; unsigned id; int busy, closing, autocommit; } Session;
static Session sessions[SQL_SESSION_LIMIT];
static SRWLOCK sessions_lock = SRWLOCK_INIT;
static CONDITION_VARIABLE sessions_released = CONDITION_VARIABLE_INIT;
static unsigned session_serial;

/* A cancelled job can still hold its session for a moment after the UI
 * moves on, so a new job waits a short time for it. */
static Session *acquire(unsigned id, int *missing) {
  Session *found = NULL;
  *missing = 0;
  ULONGLONG deadline = GetTickCount64() + 10000;
  AcquireSRWLockExclusive(&sessions_lock);
  for (;;) {
    Session *match = NULL;
    for (int i = 0; id && i < SQL_SESSION_LIMIT; ++i)
      if (sessions[i].id == id && !sessions[i].closing) match = &sessions[i];
    if (match && !match->busy) { found = match; found->busy = 1; break; }
    ULONGLONG now = GetTickCount64();
    if (!match) { *missing = 1; break; }
    if (now >= deadline) break;
    SleepConditionVariableSRW(&sessions_released, &sessions_lock, (DWORD)(deadline - now), 0);
  }
  ReleaseSRWLockExclusive(&sessions_lock);
  return found;
}
static void release(Session *s, int close) {
  SqlServerConnection connection = {0};
  AcquireSRWLockExclusive(&sessions_lock);
  if (close || s->closing) { connection = s->connection; memset(s, 0, sizeof(*s)); }
  else s->busy = 0;
  ReleaseSRWLockExclusive(&sessions_lock);
  WakeAllConditionVariable(&sessions_released);
  sql_server_close(&connection);
}

unsigned sql_session_open(const SqlServerOptions *options, char error[256]) {
  error[0] = 0;
  SqlServerConnection connection = {0};
  if (!sql_server_open(options, 0, &connection, error)) return 0;
  unsigned id = 0;
  AcquireSRWLockExclusive(&sessions_lock);
  for (int i = 0; i < SQL_SESSION_LIMIT; ++i) {
    if (sessions[i].id) continue;
    if (!++session_serial) ++session_serial;
    id = session_serial;
    sessions[i] = (Session){ connection, id, 0, 0, 1 };
    break;
  }
  ReleaseSRWLockExclusive(&sessions_lock);
  if (!id) {
    sql_server_close(&connection);
    snprintf(error, 256, "Anvil has %d open SQL sessions. Close a SQL Query first.", SQL_SESSION_LIMIT);
  }
  return id;
}

int sql_session_execute(unsigned id, int autocommit, int explain, const char *sql, size_t length,
                        unsigned max_rows, unsigned timeout_seconds,
                        SqlQueryCancelled cancelled, void *context, SqlQueryResult *out) {
  memset(out, 0, sizeof(*out));
  out->transaction_count = -1;
  int missing = 0;
  Session *s = acquire(id, &missing);
  if (!s) {
    out->session_lost = missing;
    snprintf(out->error, sizeof(out->error), missing ? "The SQL session has ended. Run again to open a new one." : "The SQL session is busy.");
    return 0;
  }
  int lost = 0, ok = 0;
  SQLHDBC dbc = s->connection.dbc;
  autocommit = autocommit != 0;
  if (autocommit != s->autocommit) {
    int open = transaction_count(dbc, &lost);
    if (autocommit && open != 0) {
      snprintf(out->error, sizeof(out->error), "Commit or roll back the open transaction before Auto Commit turns on.");
      out->transaction_count = open;
      goto done;
    }
    /* Like SSMS, Auto Commit off is IMPLICIT_TRANSACTIONS. ODBC manual commit
     * would start a new transaction after each Commit, so @@TRANCOUNT could
     * not tell whether one is open. */
    if (!run_fixed(dbc, autocommit ? L"SET IMPLICIT_TRANSACTIONS OFF" : L"SET IMPLICIT_TRANSACTIONS ON", out, &lost)) {
      if (!out->error[0]) snprintf(out->error, sizeof(out->error), "Could not change Auto Commit.");
      goto done;
    }
    s->autocommit = autocommit;
  }
  ok = run_text(dbc, sql, length, 1, explain, max_rows, timeout_seconds, cancelled, context, out, &lost);
  if (!lost) out->transaction_count = transaction_count(dbc, &lost);
done:
  if (lost) {
    out->session_lost = 1; ok = 0;
    if (!out->error[0] || out->cancelled)
      snprintf(out->error, sizeof(out->error), "The connection to SQL Server was lost. The server rolled back any open transaction.");
  }
  release(s, lost);
  return ok;
}

int sql_session_end_transaction(unsigned id, int commit, int *count, int *ended, char error[256]) {
  error[0] = 0;
  *count = -1;
  Session *s = acquire(id, ended);
  if (!s) { snprintf(error, 256, *ended ? "The SQL session has ended. The server rolled back its transaction." : "The SQL session is busy."); return 0; }
  SqlQueryResult messages = {0};
  int lost = 0;
  SQLHDBC dbc = s->connection.dbc;
  run_fixed(dbc, commit ? L"WHILE @@TRANCOUNT > 0 COMMIT TRANSACTION" : L"IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION", &messages, &lost);
  if (!lost) *count = transaction_count(dbc, &lost);
  *ended = lost;
  if (lost) snprintf(error, 256, "The connection to SQL Server was lost. The server rolled back any open transaction.");
  else if (messages.error[0]) snprintf(error, 256, "%.255s", messages.error);
  sql_query_free(&messages);
  release(s, lost);
  return !error[0];
}

void sql_session_close(unsigned id) {
  SqlServerConnection connection = {0};
  AcquireSRWLockExclusive(&sessions_lock);
  for (int i = 0; id && i < SQL_SESSION_LIMIT; ++i) {
    if (sessions[i].id != id) continue;
    if (sessions[i].busy) sessions[i].closing = 1;
    else { connection = sessions[i].connection; memset(&sessions[i], 0, sizeof(sessions[i])); }
  }
  ReleaseSRWLockExclusive(&sessions_lock);
  WakeAllConditionVariable(&sessions_released);
  sql_server_close(&connection);
}
#else
int sql_query_check(const char *sql, size_t length, unsigned max_rows, unsigned timeout_seconds,
                    char *error, size_t size) {
  (void)sql; (void)length; (void)max_rows; (void)timeout_seconds;
  snprintf(error, size, "SQL Server connections currently require Windows."); return 0;
}
int sql_query_read(const SqlServerOptions *options, const char *sql, size_t length,
                   SqlQueryCancelled cancelled, void *context, SqlQueryResult *out) {
  (void)options; (void)sql; (void)length; (void)cancelled; (void)context;
  memset(out, 0, sizeof(*out));
  snprintf(out->error, sizeof(out->error), "SQL Server connections currently require Windows.");
  return 0;
}
unsigned sql_session_open(const SqlServerOptions *options, char error[256]) {
  (void)options; snprintf(error, 256, "SQL Server connections currently require Windows."); return 0;
}
int sql_session_execute(unsigned id, int autocommit, int explain, const char *sql, size_t length,
                        unsigned max_rows, unsigned timeout_seconds,
                        SqlQueryCancelled cancelled, void *context, SqlQueryResult *out) {
  (void)id; (void)autocommit; (void)explain; (void)sql; (void)length; (void)max_rows; (void)timeout_seconds;
  (void)cancelled; (void)context;
  memset(out, 0, sizeof(*out));
  snprintf(out->error, sizeof(out->error), "SQL Server connections currently require Windows.");
  return 0;
}
int sql_session_end_transaction(unsigned id, int commit, int *count, int *ended, char error[256]) {
  (void)id; (void)commit; *count = -1; *ended = 1;
  snprintf(error, 256, "SQL Server connections currently require Windows."); return 0;
}
void sql_session_close(unsigned id) { (void)id; }
#endif
