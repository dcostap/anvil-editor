#include "terminal_recovery.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
  AnvilTerminalRecovery recovery;
  const char *record = "return {\n  interrupted_command = \"\\034C:\\092Pi\\034 --session note\",\n"
    "  interrupted_input = \"pi café\",\n  interrupted_pid = 123,\n"
    "  recovery_agent = \"pid=123\\010ppid=42\\010session=note.jsonl\\010\",\n}\n";
  assert(anvil_terminal_recovery_parse(record, &recovery));
  assert(!strcmp(recovery.command, "\"C:\\Pi\" --session note"));
  assert(!strcmp(recovery.input, "pi café"));
  assert(recovery.pid == 123);
  assert(anvil_terminal_agent_matches(recovery.agent, 123));
  assert(anvil_terminal_agent_matches(recovery.agent, 42));
  assert(!anvil_terminal_agent_matches(recovery.agent, 12));
  assert(!anvil_terminal_agent_matches("notpid=123\npid=123x\nppid=-123\n", 123));
  assert(!anvil_terminal_agent_matches("pid=4294967419\n", 123));
  assert(!anvil_terminal_agent_matches("pid=0\n", 0));
  assert(anvil_terminal_recovery_parse("return {}", &recovery));
  assert(!recovery.pid && !recovery.command[0] && !recovery.agent[0]);
  assert(anvil_terminal_recovery_parse("\n  interrupted_command = \"\xff\",", &recovery));
  assert((unsigned char)recovery.command[0] == 255 && !recovery.command[1]);
  const char *invalid[] = {
    "\n  interrupted_command = \"unterminated", "\n  interrupted_command = \"\\",
    "\n  interrupted_command = \"\\0", "\n  interrupted_command = \"\\01",
    "\n  interrupted_command = \"\\000\",", "\n  interrupted_command = \"\\999\",",
    "\n  interrupted_command = \"a\n\",", "\n  interrupted_pid = 4294967296,",
    "\n  interrupted_pid = -1,", "\n  interrupted_pid = 1x,",
  };
  for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++)
    assert(!anvil_terminal_recovery_parse(invalid[i], &recovery));
  size_t capacity = sizeof(recovery.command);
  char *long_record = malloc(capacity + 64);
  assert(long_record);
  size_t offset = (size_t)sprintf(long_record, "\n  interrupted_command = \"");
  memset(long_record + offset, 'x', capacity);
  strcpy(long_record + offset + capacity, "\",");
  assert(!anvil_terminal_recovery_parse(long_record, &recovery));
  free(long_record);
  puts("Terminal recovery parser passed");
  return 0;
}
