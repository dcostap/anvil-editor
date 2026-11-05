#ifndef ANVIL_TERMINAL_RECOVERY_H
#define ANVIL_TERMINAL_RECOVERY_H
#include <stdbool.h>
#include <stdint.h>

typedef struct {
  char command[16384], input[4096], agent[65536];
  uint32_t pid;
  bool has_agent;
} AnvilTerminalRecovery;

/* Read only the recovery fields of the host's generated Lua record. Never execute it. */
bool anvil_terminal_recovery_parse(const char *record, AnvilTerminalRecovery *recovery);
bool anvil_terminal_agent_matches(const char *report, uint32_t pid);
#endif
