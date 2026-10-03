#include "surface_protocol.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char log_role[16];

static void SDLCALL write_surface_log(void *userdata, int category, SDL_LogPriority priority,
                                      const char *message) {
  (void)category;
  (void)priority;
  FILE *file = fopen((const char *)userdata, "ab");
  if (!file) return;
  fprintf(file, "%10.3f %s[%lu] %s\n", (double)SDL_GetTicksNS() / 1e9, log_role,
#ifdef _WIN32
          (unsigned long)GetCurrentProcessId(),
#else
          0ul,
#endif
          message);
  fclose(file);
}

void anvil_surface_log_init(const char *role) {
  const char *path = SDL_getenv("ANVIL_SURFACE_LOG");
  if (!path || !path[0]) return;
  SDL_strlcpy(log_role, role, sizeof(log_role));
  SDL_SetLogOutputFunction(write_surface_log, SDL_strdup(path));
}
