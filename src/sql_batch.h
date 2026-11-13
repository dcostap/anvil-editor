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
/* What a run can change, for a question before it runs. changes: a statement
 * that can change data, the schema or the server, such as INSERT, UPDATE,
 * DELETE, MERGE, TRUNCATE, CREATE, ALTER, DROP, GRANT, a procedure call or
 * SELECT ... INTO. unfiltered_line: the 1-based line of the first UPDATE or
 * DELETE without a WHERE or an inner JOIN at its own level, or 0. Temporary
 * tables and table variables do not count. A batch that creates a procedure,
 * function or trigger runs none of its statements. This reads keywords; it
 * cannot see what a procedure or dynamic SQL does. */
typedef struct { int changes; unsigned unfiltered_line; char unfiltered_verb[8]; } SqlBatchRisk;
void sql_batch_risk(const char *text, size_t length, SqlBatchRisk *out);
#endif
