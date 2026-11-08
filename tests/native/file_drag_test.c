#include <stdio.h>
#include <string.h>
#include "file_drag.h"

#define CHECK(condition) do { \
  if (!(condition)) { \
    fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); \
    return 1; \
  } \
} while (0)

#define LIST(text) text, sizeof(text) - 1

int main(void) {
  CHECK(anvil_file_drag_list_valid(LIST("C:\a.txt\0")));
  CHECK(anvil_file_drag_list_valid(LIST("C:\a.txt\0D:\b c\\xc3\xb1.md\0")));
  CHECK(!anvil_file_drag_list_valid(NULL, 0));
  CHECK(!anvil_file_drag_list_valid(LIST("")));
  CHECK(!anvil_file_drag_list_valid(LIST("\0")));
  CHECK(!anvil_file_drag_list_valid(LIST("C:\a.txt")));
  CHECK(!anvil_file_drag_list_valid(LIST("\0C:\a.txt\0")));
  CHECK(!anvil_file_drag_list_valid(LIST("C:\a.txt\0\0D:\b.txt\0")));
  CHECK(!anvil_file_drag_list_valid(LIST("C:\a.txt\0\0")));
  puts("file drag tests passed");
  return 0;
}
