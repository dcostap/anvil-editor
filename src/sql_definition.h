#ifndef ANVIL_SQL_DEFINITION_H
#define ANVIL_SQL_DEFINITION_H
#include "sql_query.h"

typedef struct {
  char *source_sql, *create_sql, *alter_sql, *select_sql, *insert_sql, *update_sql, *delete_sql;
  char error[512];
} SqlDefinition;

/* Changes only a module's opening declaration, after comments. Caller frees the result. */
char *sql_module_script(const char *text, size_t length, int alter);
/* Fixed catalog reads on a worker. No generated statement is executed. */
int sql_definition_read(const SqlServerOptions *options, const char *schema, const char *name,
                        SqlQueryCancelled cancelled, void *context, SqlDefinition *out);
void sql_definition_free(SqlDefinition *out);
#endif
