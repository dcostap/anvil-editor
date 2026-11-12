#ifndef ANVIL_SQL_BATCH_H
#define ANVIL_SQL_BATCH_H
#include <stddef.h>

#define SQL_BATCH_LIMIT 100000
#define SQL_BATCH_REPEAT_LIMIT 1000

typedef struct {
  /* Byte offsets. End is exclusive. Line is the 1-based line of start. */
  size_t start, end;
  unsigned repeat, line;
} SqlBatch;

/* Splits T-SQL at lines that hold only GO, an optional count and an optional
 * line comment, like SSMS and DbVisualizer. GO in strings, quoted names and
 * block comments is text. Batches with only whitespace are omitted.
 * Returns the batch count, or -1 for too many batches or an invalid count. */
int sql_batch_split(const char *text, size_t length, SqlBatch *out, size_t capacity);
/* Names the procedure, function or trigger that a batch creates or alters.
 * Such a statement must start its batch. Writes the name without its schema
 * or quotes and returns 1, or returns 0. */
int sql_batch_module(const char *text, size_t length, char *name, size_t size);
/* Reports SQL that can change the catalog: CREATE, ALTER or DROP of a table,
 * view, procedure, function, trigger, schema, synonym, type or sequence,
 * sp_rename, and SELECT ... INTO a permanent table. Temporary objects do not
 * count. A false report only costs a catalog read. */
int sql_batch_changes_schema(const char *text, size_t length);
#endif
