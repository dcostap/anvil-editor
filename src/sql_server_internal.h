#ifndef ANVIL_SQL_SERVER_INTERNAL_H
#define ANVIL_SQL_SERVER_INTERNAL_H
#ifdef _WIN32
#include <windows.h>
#include <sql.h>
#include <sqlext.h>
#include "sql_server.h"
typedef struct { SQLHENV env; SQLHDBC dbc; int connected; } SqlServerConnection;
int sql_server_open(const SqlServerOptions *options, int read_only, SqlServerConnection *connection, char error[256]);
void sql_server_close(SqlServerConnection *connection);
void sql_server_diagnostic(char error[256], SQLSMALLINT type, SQLHANDLE handle, const char *action);
#endif
#endif
