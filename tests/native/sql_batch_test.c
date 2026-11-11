#include "sql_batch.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static int split(const char *text, SqlBatch *b, size_t capacity) {
  return sql_batch_split(text, strlen(text), b, capacity);
}

int main(void) {
  SqlBatch b[8];
  const char *text = "SELECT 1\r\ngo\r\n\r\nSELECT 'x\nGO\n' /* \nGO\n */ -- GO\n  Go 3 -- again\nSELECT [a\nGO\n]\nGO";
  assert(split(text, b, 8) == 3);
  assert(b[0].start == 0 && b[0].end == strlen("SELECT 1\r\n") && b[0].repeat == 1 && b[0].line == 1);
  assert(!strncmp(text + b[1].start, "\r\nSELECT 'x", 11) && b[1].repeat == 3 && b[1].line == 3);
  assert(!strncmp(text + b[2].start, "SELECT [a", 9) && b[2].line == 10 && b[2].end == strlen(text) - 2);

  text = "SELECT 1\nGOTO done\nGO-- c\nGO\n  \n";
  assert(split(text, b, 8) == 1 && b[0].end == strlen("SELECT 1\nGOTO done\n"));
  assert(split("GO\nGO", b, 8) == 0);
  assert(split("", b, 8) == 0);
  assert(split("SELECT 1\nGO 0", b, 8) == -1);
  assert(split("SELECT 1\nGO 1001", b, 8) == -1);
  assert(split("A\nGO\nB\nGO\nC", b, 2) == -1);
  text = "SELECT N'unterminated\nGO\n";
  assert(split(text, b, 8) == 1 && b[0].end == strlen(text));
  puts("SQL batches passed");
  return 0;
}
