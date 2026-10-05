#ifndef ANVIL_CLI_ARGS_H
#define ANVIL_CLI_ARGS_H
#include <stdbool.h>
#include <string.h>

/* Startup path selection cannot load plugin flag definitions. Known switches
 * take no value. Other options use one value, or an inline '=value'. */
static inline bool anvil_cli_option_value(const char *arg) {
  static const char *switches[] = {
    "--new-window", "--help", "--version", "--fork", "-h", "-v", "-f",
    "--no-quit", "-n", "--eval", "-e"
  };
  if (strchr(arg, '=') || !strncmp(arg, "-psn", 4)) return false;
  for (unsigned i = 0; i < sizeof(switches) / sizeof(switches[0]); i++)
    if (!strcmp(arg, switches[i])) return false;
  return true;
}
#endif
