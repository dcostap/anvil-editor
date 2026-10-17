#ifndef ANVIL_LAUNCH_MODE_H
#define ANVIL_LAUNCH_MODE_H
#include <stdbool.h>
#include <string.h>
#include "surface_protocol.h"

/* The shell is the default app on Windows. A launch runs the Lua application
 * itself for --direct, a CLI command, an information option, or one of the
 * shell's own Project and Sidebar processes. Removes --direct from argv. */
static inline bool anvil_launch_runs_shell(int *argc, char **argv) {
  if (*argc > 1 && !strcmp(argv[1], ANVIL_SHELL_ARG)) return true;
  bool shell = true;
  for (int i = 1; i < *argc; i++) {
    if (!strcmp(argv[i], "--direct")) {
      for (int j = i; j < *argc; j++) argv[j] = argv[j + 1];
      (*argc)--; i--;
      shell = false;
      continue;
    }
    static const char *options[] = { "--help", "-h", "--version", "-v", "--internal-sidebar" };
    for (unsigned k = 0; k < sizeof(options) / sizeof(options[0]); k++)
      if (!strcmp(argv[i], options[k])) shell = false;
    if (!strncmp(argv[i], ANVIL_SURFACE_PIPE_ARG, strlen(ANVIL_SURFACE_PIPE_ARG))) shell = false;
  }
  if (*argc > 1) {
    static const char *commands[] = { "test", "help", "list", "repl", "run", "edit", ANVIL_PROJECT_ARG };
    for (unsigned k = 0; k < sizeof(commands) / sizeof(commands[0]); k++)
      if (!strcmp(argv[1], commands[k])) shell = false;
  }
  return shell;
}
#endif
