#include "sql_context.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
  SqlContext c;
  const char *text = "SELECT c.na FROM sales.customers AS c WHERE c.id = 1";
  assert(sql_context_parse(text, strlen(text), strlen("SELECT c.na"), &c));
  assert(c.mode == SQL_CONTEXT_COLUMN);
  assert(strcmp(c.prefix, "na") == 0);
  assert(strcmp(c.qualifier, "c") == 0);
  assert(c.count == 1);
  assert(strcmp(c.sources[0].schema, "sales") == 0);
  assert(strcmp(c.sources[0].name, "customers") == 0);
  assert(strcmp(c.sources[0].alias, "c") == 0);
  text = "SELECT outer_c.id FROM old.customers outer_c WHERE EXISTS (SELECT c.na FROM sales.clients c)";
  const char *caret = strstr(text, "c.na") + 4;
  assert(sql_context_parse(text, strlen(text), (size_t)(caret - text), &c));
  assert(c.count == 1 && !strcmp(c.sources[0].name, "clients"));
  text = "SELECT * FROM old_table; SELECT c.na FROM [odd schema].[customer]]names] c";
  caret = strstr(text, "c.na") + 4;
  assert(sql_context_parse(text, strlen(text), (size_t)(caret - text), &c));
  assert(c.count == 1 && !strcmp(c.sources[0].schema, "odd schema"));
  assert(!strcmp(c.sources[0].name, "customer]names"));
  text = "SELECT c.na FROM dbo.customers c JOIN dbo.orders o ON c.id=o.customer_id";
  assert(sql_context_parse(text, strlen(text), 11, &c));
  assert(c.count == 2 && !strcmp(c.sources[1].alias, "o"));
  const char *blocked[] = { "SELECT 'FROM secret", "SELECT 1 -- FROM secret", "SELECT /* nested /* comment */ still comment",
    "WITH c AS (SELECT * FROM dbo.customers) SELECT c.na FROM c", "SELECT c.na FROM (SELECT * FROM dbo.customers) c" };
  for (size_t i = 0; i < sizeof(blocked) / sizeof(blocked[0]); ++i) {
    assert(sql_context_parse(blocked[i], strlen(blocked[i]), strlen(blocked[i]), &c));
    assert(c.mode == SQL_CONTEXT_NONE);
  }
  assert(sql_context_parse("", 0, 0, &c) && c.mode == SQL_CONTEXT_NONE);
  assert(!sql_context_parse("", 0, 1, &c));
  assert(!sql_context_parse("", 256 * 1024 + 1, 0, &c));
  text = "SELECT \xff FROM dbo.t";
  assert(sql_context_parse(text, strlen(text), 8, &c));
  puts("SQL context passed");
  return 0;
}
