#ifndef ANVIL_SQL_FORMAT_H
#define ANVIL_SQL_FORMAT_H
#include <stddef.h>

#define SQL_FORMAT_LIMIT (4u * 1024u * 1024u)

typedef enum {
  SQL_TOKEN_WORD, SQL_TOKEN_STRING, SQL_TOKEN_QUOTED, SQL_TOKEN_LINE_COMMENT, SQL_TOKEN_BLOCK_COMMENT,
  SQL_TOKEN_OPEN, SQL_TOKEN_CLOSE, SQL_TOKEN_COMMA, SQL_TOKEN_DOT, SQL_TOKEN_SEMICOLON, SQL_TOKEN_OPERATOR,
  SQL_TOKEN_GO
} SqlTokenKind;

/* Finds the first T-SQL token at or after `pos`. A GO token is a whole batch separator line without its line
 * end, as sql_batch.c reads it. Returns 0 at the end of the text. */
int sql_format_token(const char *text, size_t length, size_t pos, size_t *start, size_t *end, SqlTokenKind *kind);

/* Formats T-SQL in DbVisualizer's default layout: each main keyword on its own line, its content one `indent`
 * deeper, one list item on each line, and AND and OR at the start of a line. Reserved keywords become
 * uppercase. SELECT, INSERT, UPDATE, DELETE and WITH statements get the layout; other text keeps its lines.
 * Text from a comment that holds FORMAT_OFF to a comment that holds FORMAT_ON stays as it is.
 * Only whitespace between tokens and the case of reserved keywords change. A statement whose result does not
 * have the same tokens stays as it was. New lines use CRLF when the text has CRLF. Returns 1 and a malloc'd
 * text, or 0 when memory runs out or the text exceeds SQL_FORMAT_LIMIT. */
int sql_format(const char *text, size_t length, const char *indent, size_t indent_length, char **out,
  size_t *out_length);
#endif
