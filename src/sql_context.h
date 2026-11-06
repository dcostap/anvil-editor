#ifndef ANVIL_SQL_CONTEXT_H
#define ANVIL_SQL_CONTEXT_H

#include <stddef.h>

#define SQL_CONTEXT_NAME 513
#define SQL_CONTEXT_SOURCES 64

typedef struct {
  char schema[SQL_CONTEXT_NAME], name[SQL_CONTEXT_NAME], alias[SQL_CONTEXT_NAME];
} SqlSource;

typedef struct {
  /* Byte offsets, like Anvil's Buffer columns. End is exclusive. */
  size_t start, end;
  enum { SQL_CONTEXT_NONE, SQL_CONTEXT_TABLE, SQL_CONTEXT_COLUMN } mode;
  char prefix[SQL_CONTEXT_NAME], qualifier[SQL_CONTEXT_NAME];
  SqlSource sources[SQL_CONTEXT_SOURCES];
  size_t count;
} SqlContext;

/* Returns zero for oversized input or allocation failure. No partial result. */
int sql_context_parse(const char *text, size_t length, size_t caret, SqlContext *out);
#endif
