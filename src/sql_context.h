#ifndef ANVIL_SQL_CONTEXT_H
#define ANVIL_SQL_CONTEXT_H

#include <stddef.h>

#define SQL_CONTEXT_NAME 513
#define SQL_CONTEXT_SOURCES 64
#define SQL_CONTEXT_LOCALS 64
#define SQL_CONTEXT_COLUMNS 2048

typedef struct {
  char schema[SQL_CONTEXT_NAME], name[SQL_CONTEXT_NAME], alias[SQL_CONTEXT_NAME];
  /* One-based index of the Local Source that this name means, or 0 for a catalog object. */
  size_t local;
} SqlSource;

/* A source that the text itself defines. Its columns are names in the text: a
 * column list, or the names of a SELECT's columns. With star set, a `*` or a
 * limit leaves the list incomplete. */
enum { SQL_LOCAL_CTE = 1, SQL_LOCAL_DERIVED, SQL_LOCAL_TEMP, SQL_LOCAL_VARIABLE };
typedef struct { char name[SQL_CONTEXT_NAME], type[64]; } SqlVariable;
typedef struct {
  char name[SQL_CONTEXT_NAME];
  int kind, star;
  size_t first, count; /* Range in SqlContext.columns. */
} SqlLocal;

typedef struct {
  /* Byte offsets, like Anvil's Buffer columns. End is exclusive. */
  size_t start, end;
  enum { SQL_CONTEXT_NONE, SQL_CONTEXT_TABLE, SQL_CONTEXT_COLUMN, SQL_CONTEXT_OBJECT } mode;
  int star;
  /* What usually follows the token before the caret: a name; a value, such as
   * after `=` or LIKE; or no existing name, such as after a complete name or AS.
   * Completion reads it. The other fields still describe the query. */
  enum { SQL_SLOT_NAME, SQL_SLOT_VALUE, SQL_SLOT_NONE } slot;
  /* With slot none: the group of keywords that can follow, named by the
   * caret's clause, such as "where" or "order", or empty for none. Lower tells
   * that the clause's keyword is in lowercase. Alias tells that the term before
   * the caret can still take an alias, so a typed name can be one. */
  char keywords[16];
  int lower, alias;
  /* At the start of a JOIN's ON, such as `JOIN b ON |`: 1 + the index of the
   * source that the JOIN names, so completion can offer its join conditions.
   * Otherwise 0. */
  size_t join;
  /* The scalar variables and parameters that the caret's batch declares before
   * the caret, in order, without table variables. Declaring tells that the
   * caret is in a new declaration's name. */
  SqlVariable *variables;
  size_t variable_count;
  int declaring;
  /* Empty means any object; table also permits a view for DML. */
  char object_kind[16];
  char prefix[SQL_CONTEXT_NAME], qualifier[SQL_CONTEXT_NAME];
  SqlSource sources[SQL_CONTEXT_SOURCES];
  size_t count;
  /* CTEs of the caret's statement, derived tables of its scope, and the temporary
   * tables and table variables of the whole text. */
  SqlLocal *locals;
  size_t local_count;
  char (*columns)[SQL_CONTEXT_NAME];
  size_t column_count, column_capacity;
} SqlContext;

/* Returns zero for oversized input or allocation failure. No partial result.
 * Call sql_context_free after each successful parse. */
int sql_context_parse(const char *text, size_t length, size_t caret, SqlContext *out);
void sql_context_free(SqlContext *context);
#endif
