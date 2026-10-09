#include "project_sidebar_scan.h"
#include "terminal_host.h"
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(c)                                                                                   \
  do {                                                                                             \
    if (!(c)) {                                                                                    \
      fprintf(stderr, "FAIL: %s\n", #c);                                                           \
      exit(1);                                                                                     \
    }                                                                                              \
  } while (0)
/* External process identity boundary. These fixtures are exited records. */
bool anvil_terminal_host_identity(HANDLE p, DWORD pid, const char *time) { return false; }
bool anvil_terminal_id_valid(const char *id) {
  return strlen(id) == 32 && strspn(id, "0123456789abcdef") == 32;
}
static wchar_t *resolve(const char *path) {
  int n = MultiByteToWideChar(CP_UTF8, 0, path, -1, NULL, 0);
  wchar_t *w = malloc(n * sizeof(*w));
  if (w)
    MultiByteToWideChar(CP_UTF8, 0, path, -1, w, n);
  return w;
}
int main(void) {
  CHECK(SDL_Init(SDL_INIT_EVENTS));
  char root[MAX_PATH], dir[MAX_PATH + 40], path[MAX_PATH + 100];
  CHECK(GetTempPathA(sizeof(root), root));
  snprintf(dir, sizeof(dir), "%sanvil-sidebar-scan-%lu", root, GetCurrentProcessId());
  CHECK(CreateDirectoryA(dir, NULL));
  for (char *p = dir; *p; p++)
    if (*p == '\\')
      *p = '/';
  snprintf(path, sizeof(path), "%s/terminal-sessions", dir);
  CHECK(CreateDirectoryA(path, NULL));
  for (unsigned i = 0; i < 32; i++) {
    snprintf(path, sizeof(path), "%s/terminal-sessions/%032x.lua", dir, i);
    FILE *f = fopen(path, "wb");
    CHECK(f);
    fputs("local garbage = {}; for i=1,390 do garbage[i]='", f);
    for (int j = 0; j < 6500; j++)
      fputc('x', f);
    fprintf(f,
            "'..i end; return "
            "{version=1,session_id='%032x',project_path='%s',host_creation_time='0000000000000000',"
            "status='exited',host_pid=1,cwd='%s',shell='fixture'}",
            i, dir, dir);
    fclose(f);
  }
  char source[32768];
  size_t used = 0;
  source[used++] = '{';
  for (int i = 0; i < 260; i++)
    used +=
        snprintf(source + used, sizeof(source) - used, "'%s%s%d',", dir, i ? "/Recent-" : "/", i);
  strcpy(source + used, "}");
  /* The source is larger than the list. The known runtime must also survive. */
  AnvilSidebarModel known = {0};
  const char *known_path = dir;
  CHECK(anvil_sidebar_merge_recents(&known, &known_path, 1));
  anvil_sidebar_set_runtime(&known, known.projects[0], 1, 1, ANVIL_SIDEBAR_READY, true, false,
                            false);
  AnvilSidebarScan *job = anvil_sidebar_scan_start(dir, source, &known, resolve, false);
  CHECK(job);
  Uint64 deadline = SDL_GetTicks() + 10000;
  while (!anvil_sidebar_scan_done(job) && SDL_GetTicks() < deadline)
    SDL_Delay(1);
  CHECK(anvil_sidebar_scan_done(job));
  bool limited = true;
  const AnvilSidebarModel *result = anvil_sidebar_scan_result(job, &limited);
  CHECK(result && result->count == 256 && !limited);
  AnvilSidebarProject *project = anvil_sidebar_find(result, dir);
  CHECK(project && project->terminal_count == 32);
  CHECK(anvil_sidebar_find(result, strcat(strcpy(path, dir), "/Recent-1")));
  CHECK(!anvil_sidebar_find(result, strcat(strcpy(path, dir), "/Recent-259")));
  anvil_sidebar_scan_free(job);
  anvil_sidebar_destroy(&known);
  for (unsigned i = 0; i < 32; i++) {
    snprintf(path, sizeof(path), "%s/terminal-sessions/%032x.lua", dir, i);
    DeleteFileA(path);
  }
  snprintf(path, sizeof(path), "%s/terminal-sessions", dir);
  RemoveDirectoryA(path);
  RemoveDirectoryA(dir);
  SDL_Quit();
  puts("PASS newest paths and independent bounded record decodes");
  return 0;
}
