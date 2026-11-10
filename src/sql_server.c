#include "sql_server.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

void sql_server_catalog_free(SqlServerCatalog *c) {
  for (size_t i = 0; i < c->object_count; ++i) {
    free(c->objects[i].schema); free(c->objects[i].name); free(c->objects[i].kind);
  }
  free(c->objects);
  for (size_t i = 0; i < c->count; ++i) {
    free(c->columns[i].schema); free(c->columns[i].table);
    free(c->columns[i].name); free(c->columns[i].type);
  }
  free(c->columns); free(c->database); free(c->default_schema);
  memset(c, 0, sizeof(*c));
}

#ifdef _WIN32
#include "sql_server_internal.h"
#include <wchar.h>

/* Keep credentials and server-controlled text out of logs and error messages. */
void sql_server_diagnostic(char error[256], SQLSMALLINT type, SQLHANDLE handle, const char *action) {
  SQLWCHAR state[6] = {0};
  SQLINTEGER native = 0;
  SQLSMALLINT length = 0;
  SQLWCHAR message[2];
  SQLGetDiagRecW(type, handle, 1, state, &native, message, 2, &length);
  char ascii[6] = {0};
  for (int i = 0; i < 5; ++i) ascii[i] = (char)state[i];
  if (!strcmp(ascii, "IM002"))
    snprintf(error, 256, "Install Microsoft ODBC Driver 18 or 17 for SQL Server.");
  else if (!strcmp(ascii, "28000"))
    snprintf(error, 256, "SQL Server rejected the login. Check authentication and database access.");
  else
    snprintf(error, 256, "%s failed (SQLSTATE %.5s, error %ld).", action, ascii, (long)native);
}
static int append_value(char *s, size_t cap, const char *key, const char *value) {
  size_t n = strlen(s);
  int count = snprintf(s + n, cap - n, "%s={", key);
  if (count < 0 || (size_t)count >= cap - n) return 0;
  n += (size_t)count;
  for (; *value; ++value) {
    if (n + 4 >= cap) return 0;
    s[n++] = *value;
    if (*value == '}') s[n++] = '}';
  }
  s[n++] = '}'; s[n++] = ';'; s[n] = 0;
  return 1;
}
static char *cell(SQLHSTMT stmt, int index) {
  SQLWCHAR value[1024];
  SQLLEN length = 0;
  SQLRETURN rc = SQLGetData(stmt, (SQLUSMALLINT)index, SQL_C_WCHAR, value, sizeof(value), &length);
  if (!SQL_SUCCEEDED(rc) || length == SQL_NO_TOTAL || length >= (SQLLEN)sizeof(value)) return NULL;
  if (length == SQL_NULL_DATA) value[0] = 0;
  int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, (wchar_t *)value, -1, NULL, 0, NULL, NULL);
  if (!size) return NULL;
  char *text = malloc((size_t)size);
  if (text && !WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, (wchar_t *)value, -1, text, size, NULL, NULL)) {
    free(text); return NULL;
  }
  return text;
}
static int execute(SQLHDBC dbc, SQLHSTMT *stmt, const wchar_t *query, SqlServerCatalog *out) {
  if (!SQL_SUCCEEDED(SQLAllocHandle(SQL_HANDLE_STMT, dbc, stmt))) return 0;
  if (!SQL_SUCCEEDED(SQLSetStmtAttr(*stmt, SQL_ATTR_QUERY_TIMEOUT, (SQLPOINTER)15, 0))) return 0;
  if (!SQL_SUCCEEDED(SQLExecDirectW(*stmt, (SQLWCHAR *)query, SQL_NTS))) {
    sql_server_diagnostic(out->error, SQL_HANDLE_STMT, *stmt, "Metadata read"); return 0;
  }
  return 1;
}
int sql_server_open(const SqlServerOptions *o, int read_only, SqlServerConnection *session, char error[256]) {
  memset(session, 0, sizeof(*session));
  SQLHENV env = SQL_NULL_HENV;
  SQLHDBC dbc = SQL_NULL_HDBC;
  char connection[8192] = "";
  SQLWCHAR wide[8192] = {0};
  int success = 0;
  if (!o->server || !*o->server || !o->database || !*o->database) {
    snprintf(error, 256, "Enter a server and database."); goto done;
  }
  if (!SQL_SUCCEEDED(SQLAllocHandle(SQL_HANDLE_ENV, SQL_NULL_HANDLE, &env)) ||
      !SQL_SUCCEEDED(SQLSetEnvAttr(env, SQL_ATTR_ODBC_VERSION, (SQLPOINTER)SQL_OV_ODBC3, 0))) goto done;
  const char *driver = NULL;
  SQLWCHAR description[256], attributes[2048];
  SQLSMALLINT description_length, attributes_length;
  SQLUSMALLINT direction = SQL_FETCH_FIRST;
  while (SQL_SUCCEEDED(SQLDriversW(env, direction, description, 256, &description_length,
                                  attributes, 2048, &attributes_length))) {
    direction = SQL_FETCH_NEXT;
    if (!wcscmp((wchar_t *)description, L"ODBC Driver 18 for SQL Server")) { driver = "ODBC Driver 18 for SQL Server"; break; }
    if (!wcscmp((wchar_t *)description, L"ODBC Driver 17 for SQL Server")) driver = "ODBC Driver 17 for SQL Server";
  }
  if (!driver) { snprintf(error, 256, "Install Microsoft ODBC Driver 18 or 17 for SQL Server."); goto done; }
  if (!append_value(connection, sizeof(connection), "DRIVER", driver)) goto done;
  if (!append_value(connection, sizeof(connection), "SERVER", o->server) ||
      !append_value(connection, sizeof(connection), "Encrypt", o->encrypt ? "yes" : "no") ||
      !append_value(connection, sizeof(connection), "DATABASE", o->database) ||
      !append_value(connection, sizeof(connection), "TrustServerCertificate", o->trust_certificate ? "yes" : "no") ||
      !append_value(connection, sizeof(connection), "Trusted_Connection", o->integrated ? "yes" : "no") ||
      (!o->integrated && (!append_value(connection, sizeof(connection), "UID", o->user ? o->user : "") ||
                        !append_value(connection, sizeof(connection), "PWD", o->password ? o->password : "")))) {
    snprintf(error, 256, "Connection settings are too long."); goto done;
  }
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, connection, -1, (wchar_t *)wide, 8192)) {
    snprintf(error, 256, "Connection settings contain invalid UTF-8."); goto done;
  }
  if (!SQL_SUCCEEDED(SQLAllocHandle(SQL_HANDLE_DBC, env, &dbc))) goto done;
  if (!SQL_SUCCEEDED(SQLSetConnectAttr(dbc, SQL_ATTR_LOGIN_TIMEOUT, (SQLPOINTER)15, 0)) ||
      !SQL_SUCCEEDED(SQLSetConnectAttr(dbc, SQL_ATTR_ACCESS_MODE, (SQLPOINTER)(uintptr_t)(read_only ? SQL_MODE_READ_ONLY : SQL_MODE_READ_WRITE), 0))) goto done;
  if (!SQL_SUCCEEDED(SQLDriverConnectW(dbc, NULL, wide, SQL_NTS, NULL, 0, NULL, SQL_DRIVER_NOPROMPT))) {
    sql_server_diagnostic(error, SQL_HANDLE_DBC, dbc, "Connection"); goto done;
  }
  success = 1;
done:
  SecureZeroMemory(connection, sizeof(connection)); SecureZeroMemory(wide, sizeof(wide));
  session->env = env; session->dbc = dbc; session->connected = success;
  if (!success) {
    sql_server_close(session);
    if (!error[0]) snprintf(error, 256, "Could not open SQL Server connection.");
  }
  return success;
}

void sql_server_close(SqlServerConnection *session) {
  if (session->dbc) {
    if (session->connected) SQLDisconnect(session->dbc);
    SQLFreeHandle(SQL_HANDLE_DBC, session->dbc);
  }
  if (session->env) SQLFreeHandle(SQL_HANDLE_ENV, session->env);
  memset(session, 0, sizeof(*session));
}

int sql_server_read_schema(const SqlServerOptions *o, SqlServerCatalog *out) {
  memset(out, 0, sizeof(*out));
  SqlServerConnection session = {0};
  SQLHSTMT stmt = SQL_NULL_HSTMT;
  int success = 0;
  if (!sql_server_open(o, 1, &session, out->error)) goto done;
  SQLHDBC dbc = session.dbc;
  if (!execute(dbc, &stmt, L"SELECT DB_NAME(), SCHEMA_NAME(), CASE WHEN N'a'=N'A' THEN N'0' ELSE N'1' END", out)) goto done;
  if (!SQL_SUCCEEDED(SQLFetch(stmt))) goto done;
  out->database = cell(stmt, 1); out->default_schema = cell(stmt, 2);
  char *sensitive = cell(stmt, 3);
  if (!out->database || !out->default_schema || !sensitive) { free(sensitive); goto done; }
  out->case_sensitive = !strcmp(sensitive, "1"); free(sensitive);
  SQLFreeHandle(SQL_HANDLE_STMT, stmt); stmt = SQL_NULL_HSTMT;
  if (!execute(dbc, &stmt, L"SELECT s.name,o.name,CASE o.type WHEN 'U' THEN 'table' WHEN 'V' THEN 'view' WHEN 'P' THEN 'procedure' ELSE 'function' END "
      L"FROM sys.objects o JOIN sys.schemas s ON s.schema_id=o.schema_id "
      L"WHERE o.type IN('U','V','P','FN','IF','TF') AND o.is_ms_shipped=0 ORDER BY s.name,o.name", out)) goto done;
  size_t object_capacity = 0;
  for (;;) {
    SQLRETURN rc = SQLFetch(stmt);
    if (rc == SQL_NO_DATA) break;
    if (!SQL_SUCCEEDED(rc)) { sql_server_diagnostic(out->error, SQL_HANDLE_STMT, stmt, "Object read"); goto done; }
    if (out->object_count == 10000) { snprintf(out->error,sizeof(out->error),"Database metadata exceeds 10000 objects."); goto done; }
    if (out->object_count == object_capacity) {
      object_capacity = object_capacity ? object_capacity * 2 : 256;
      SqlServerObject *p = realloc(out->objects,object_capacity*sizeof(*p));
      if (!p) goto done;
      out->objects=p;
    }
    SqlServerObject *object=&out->objects[out->object_count++];
    object->schema=cell(stmt,1); object->name=cell(stmt,2); object->kind=cell(stmt,3);
    if (!object->schema || !object->name || !object->kind) goto done;
  }
  SQLFreeHandle(SQL_HANDLE_STMT, stmt); stmt = SQL_NULL_HSTMT;
  const wchar_t *query =
    L"SELECT s.name, o.name, c.name, "
    L"t.name + CASE WHEN t.name IN ('varchar','char','varbinary','binary','nvarchar','nchar') "
    L"THEN '(' + CASE WHEN c.max_length=-1 THEN 'max' ELSE CONVERT(varchar(10), "
    L"CASE WHEN t.name IN ('nvarchar','nchar') THEN c.max_length/2 ELSE c.max_length END) END + ')' "
    L"WHEN t.name IN ('decimal','numeric') THEN '(' + CONVERT(varchar(10),c.precision) + ',' + CONVERT(varchar(10),c.scale) + ')' "
    L"WHEN t.name IN ('time','datetime2','datetimeoffset') THEN '(' + CONVERT(varchar(10),c.scale) + ')' ELSE '' END, "
    L"CONVERT(nvarchar(1),c.is_nullable), CONVERT(nvarchar(1),c.is_identity), "
    L"CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i JOIN sys.index_columns ic ON ic.object_id=i.object_id AND ic.index_id=i.index_id "
    L"WHERE i.object_id=o.object_id AND i.is_primary_key=1 AND ic.column_id=c.column_id) THEN N'1' ELSE N'0' END "
    L"FROM sys.objects o JOIN sys.schemas s ON s.schema_id=o.schema_id "
    L"JOIN sys.columns c ON c.object_id=o.object_id JOIN sys.types t ON t.user_type_id=c.user_type_id "
    L"WHERE o.type IN ('U','V') AND o.is_ms_shipped=0 AND c.is_hidden=0 ORDER BY s.name,o.name,c.column_id";
  if (!execute(dbc, &stmt, query, out)) goto done;
  size_t capacity = 0;
  for (;;) {
    SQLRETURN rc = SQLFetch(stmt);
    if (rc == SQL_NO_DATA) break;
    if (!SQL_SUCCEEDED(rc)) { sql_server_diagnostic(out->error, SQL_HANDLE_STMT, stmt, "Metadata read"); goto done; }
    if (out->count == 50000) { snprintf(out->error, sizeof(out->error), "Database metadata exceeds 50000 columns."); goto done; }
    if (out->count == capacity) {
      capacity = capacity ? capacity * 2 : 256;
      SqlServerColumn *p = realloc(out->columns, capacity * sizeof(*p));
      if (!p) goto done;
      out->columns = p;
    }
    SqlServerColumn *c = &out->columns[out->count++];
    memset(c, 0, sizeof(*c));
    c->schema = cell(stmt, 1); c->table = cell(stmt, 2); c->name = cell(stmt, 3); c->type = cell(stmt, 4);
    char *nullable = cell(stmt, 5), *identity = cell(stmt, 6), *key = cell(stmt, 7);
    int valid = c->schema && c->table && c->name && c->type && nullable && identity && key;
    c->nullable = nullable && !strcmp(nullable, "1");
    c->identity = identity && !strcmp(identity, "1");
    c->primary_key = key && !strcmp(key, "1");
    free(nullable); free(identity); free(key);
    if (!valid) goto done;
  }
  success = 1;
done:
  if (stmt != SQL_NULL_HSTMT) SQLFreeHandle(SQL_HANDLE_STMT, stmt);
  sql_server_close(&session);
  if (!success && !out->error[0]) snprintf(out->error, sizeof(out->error), "Could not read complete SQL Server metadata.");
  return success;
}
#else
int sql_server_read_schema(const SqlServerOptions *o, SqlServerCatalog *out) {
  (void)o; memset(out, 0, sizeof(*out));
  snprintf(out->error, sizeof(out->error), "SQL Server connections currently require Windows.");
  return 0;
}
#endif
