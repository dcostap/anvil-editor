#include <stdio.h>
#include <string.h>
#include "launch_mode.h"

#define CHECK(condition) do { \
  if (!(condition)) { \
    fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); \
    return 1; \
  } \
} while (0)

static bool runs_shell(int count, const char **given, int *argc_out, char **argv_out) {
  for (int i = 0; i < count; i++) argv_out[i] = (char *)given[i];
  argv_out[count] = NULL;
  *argc_out = count;
  return anvil_launch_runs_shell(argc_out, argv_out);
}

#define LAUNCH(...) (given = (const char *[]){ "anvil", __VA_ARGS__ }, \
  runs_shell((int)(sizeof((const char *[]){ "anvil", __VA_ARGS__ }) / sizeof(char *)), given, &argc, argv))

int main(void) {
  const char **given; char *argv[16]; int argc;

  /* A plain launch, a path, or a launch option opens the shell. */
  given = (const char *[]){ "anvil" };
  CHECK(runs_shell(1, given, &argc, argv));
  CHECK(LAUNCH("C:\Projects\a"));
  CHECK(LAUNCH("--new-window"));
  CHECK(LAUNCH("--shell", "C:\Projects\a"));

  /* --direct runs the application and is not passed on. */
  CHECK(!LAUNCH("--direct", "notes.md"));
  CHECK(argc == 2 && !strcmp(argv[1], "notes.md") && argv[2] == NULL);

  /* Commands and the application's information options run without a shell. */
  CHECK(!LAUNCH("test", "tests/lua/ui/terminal.lua"));
  CHECK(!LAUNCH("help"));
  CHECK(!LAUNCH("list"));
  CHECK(!LAUNCH("repl"));
  CHECK(!LAUNCH("run", "script.lua"));
  CHECK(!LAUNCH("edit", "notes.md"));
  CHECK(!LAUNCH("--version"));
  CHECK(!LAUNCH("-h"));

  /* The shell's own Project and Sidebar processes run the application. */
  CHECK(!LAUNCH(ANVIL_PROJECT_ARG, "C:\Projects\a", ANVIL_SURFACE_PIPE_ARG "x"));
  CHECK(!LAUNCH("--internal-sidebar", ANVIL_SURFACE_PIPE_ARG "x"));
  return 0;
}
