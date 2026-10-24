#include "shell_state.h"
#include "shell_adoption.h"
#include "shell_launch.h"
#include <SDL3/SDL.h>
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
#define CHECK(cond, message) do { if (!(cond)) { fprintf(stderr, "FAIL: %s\n", message); failures++; } } while (0)

static AnvilShellWindowState sample[] = {
  {3, -8, 40, 1200, 800, true, "C:\\Projects\\Front Project"},
  {1, 100, 120, 900, 700, false, NULL},
  {7, 30, 30, 640, 480, false, "D:\\x\\\xc3\xa9t\xc3\xa9"},
};

static AnvilShellProjectActivity activity[] = {
  {"C:\\Projects\\Front Project", 1760000000},
  {"D:\\x\\\xc3\xa9t\xc3\xa9", 1750000000},
};

static void loaded_projects(void) {
  char *background[] = {"C:\\Projects\\Background", "D:\\x\\\xc3\xa9t\xc3\xa9"};
  AnvilShellWindowState windows[] = {
    {3, 0, 0, 900, 700, false, "C:\\Projects\\Selected", background, 2},
    {7, 0, 0, 900, 700, false, "C:\\Projects\\Other"},
  };
  AnvilShellState state = {windows, 2, activity, 2}, decoded = {0};
  size_t size = 0;
  char *data = anvil_shell_state_encode(&state, &size);
  CHECK(data && anvil_shell_state_decode(data, size, &decoded), "loaded Projects did not round-trip");
  CHECK(decoded.count == 2 && decoded.windows[0].project_count == 2,
        "the Window lost its background Projects");
  if (decoded.count == 2) {
    CHECK(!strcmp(decoded.windows[0].path, "C:\\Projects\\Selected"), "Selected Project changed");
    CHECK(decoded.windows[1].project_count == 0, "background Projects moved to another Window");
    for (size_t i = 0; i < decoded.windows[0].project_count && i < 2; i++)
      CHECK(!strcmp(decoded.windows[0].projects[i], background[i]), "background Project path changed");
  }
  anvil_shell_state_free(&decoded);
  free(data);
  const char *old = "anvil-shell-windows 4\nwindow 1 0 0 10 10 0 3 abc\n";
  CHECK(anvil_shell_state_decode(old, strlen(old), &decoded) && decoded.count == 1 &&
        decoded.windows[0].project_count == 0 && !strcmp(decoded.windows[0].path, "abc"),
        "existing Selected Project state did not restore");
  anvil_shell_state_free(&decoded);
}

/* The Project Sidebar groups Projects by the last time the user worked in them. */
static void project_activity(void) {
  AnvilShellState state = {sample, 3, activity, 2}, decoded;
  size_t size = 0;
  char *data = anvil_shell_state_encode(&state, &size);
  CHECK(data && anvil_shell_state_decode(data, size, &decoded), "Project activity did not round-trip");
  CHECK(decoded.count == 3 && decoded.project_count == 2, "Project activity count changed");
  for (size_t i = 0; i < 2 && i < decoded.project_count; i++)
    CHECK(!strcmp(decoded.projects[i].path, activity[i].path) && decoded.projects[i].activity == activity[i].activity,
          "Project activity changed");
  anvil_shell_state_free(&decoded);
  free(data);
  /* A file from before Project activity still restores its Windows. */
  const char *old = "anvil-shell-windows 2\nwindow 1 0 0 10 10 0 3 abc\n";
  CHECK(anvil_shell_state_decode(old, strlen(old), &decoded) && decoded.count == 1 && decoded.project_count == 0,
        "Window state without Project activity rejected");
  anvil_shell_state_free(&decoded);
}

/* Windows share a Sidebar width, but save their visibility independently. */
static void sidebar_layout(void) {
  AnvilShellWindowState windows[] = {sample[0], sample[1], sample[2]};
  windows[0].sidebar_hidden = true;
  windows[2].sidebar_hidden = true;
  AnvilShellState state = {windows, 3, NULL, 0, 320}, decoded;
  size_t size = 0;
  char *data = anvil_shell_state_encode(&state, &size);
  CHECK(data && anvil_shell_state_decode(data, size, &decoded), "Sidebar layout did not round-trip");
  CHECK(decoded.count == 3 && decoded.sidebar_points == 320,
        "Sidebar layout changed");
  if (decoded.count == 3)
    CHECK(decoded.windows[0].sidebar_hidden && !decoded.windows[1].sidebar_hidden && decoded.windows[2].sidebar_hidden,
          "Windows lost their independent Sidebar visibility");
  anvil_shell_state_free(&decoded);
  free(data);
  /* A file from before the Sidebar layout keeps its Windows and uses the default layout. */
  const char *old = "anvil-shell-windows 3\nwindow 1 0 0 10 10 0 3 abc\nproject 5 3 abc\n";
  CHECK(anvil_shell_state_decode(old, strlen(old), &decoded) && decoded.count == 1 && decoded.project_count == 1 &&
            decoded.sidebar_points == 0 && !decoded.windows[0].sidebar_hidden,
        "Window state without a Sidebar layout rejected");
  anvil_shell_state_free(&decoded);
  /* Existing saved Windows retain their old shared visibility, including an empty Window. */
  const char *legacy[] = {
    "anvil-shell-windows 4\nsidebar 320 0\nwindow 1 0 0 10 10 0 3 abc\nwindow 2 0 0 10 10 0 0 \n",
    "anvil-shell-windows 5\nwindow 1 0 0 10 10 0 3 abc\nloaded 1 3 def\nwindow 2 0 0 10 10 0 0 \nsidebar 320 1\n",
  };
  for (size_t i = 0; i < SDL_arraysize(legacy); i++) {
    CHECK(anvil_shell_state_decode(legacy[i], strlen(legacy[i]), &decoded) && decoded.count == 2,
          "existing Sidebar layout did not load");
    if (decoded.count == 2)
      CHECK(decoded.sidebar_points == 320 && decoded.windows[0].sidebar_hidden == (i == 1) &&
            decoded.windows[1].sidebar_hidden == (i == 1), "existing Windows lost their Sidebar visibility");
    anvil_shell_state_free(&decoded);
  }
}

static void round_trip(void) {
  AnvilShellState state = {sample, 3}, decoded;
  size_t size = 0;
  char *data = anvil_shell_state_encode(&state, &size);
  CHECK(data, "encode failed");
  CHECK(anvil_shell_state_decode(data, size, &decoded), "decode failed");
  CHECK(decoded.count == 3, "Window count changed");
  for (size_t i = 0; i < 3 && i < decoded.count; i++) {
    AnvilShellWindowState *a = &sample[i], *b = &decoded.windows[i];
    CHECK(a->id == b->id, "Window id changed");
    CHECK(a->x == b->x && a->y == b->y && a->w == b->w && a->h == b->h && a->maximized == b->maximized,
          "Window placement changed");
    CHECK((!a->path && !b->path) || (a->path && b->path && !strcmp(a->path, b->path)), "Selected Project changed");
  }
  anvil_shell_state_free(&decoded);
  /* A write cut short restores nothing rather than a guess. */
  for (size_t cut = 1; cut < size; cut++)
    if (data[cut - 1] != '\n') {
      CHECK(!anvil_shell_state_decode(data, cut, &decoded), "partial file decoded");
      anvil_shell_state_free(&decoded);
    }
  free(data);
}

static void rejects(void) {
  AnvilShellState decoded;
  const char *bad[] = {
    "anvil-shell-windows 1\nwindow 0 0 10 10 0 0 \n",
    "anvil-shell-windows 7\n",
    "anvil-shell-windows 6\nwindow 1 0 0 10 10 0 2 0 \n",
    "anvil-shell-windows 6\nwindow 1 0 0 10 10 0 0 \n",
    "anvil-shell-windows 6\nsidebar 320 1\n",
    "anvil-shell-windows 6\nsidebar 0\n",
    "anvil-shell-windows 6\nsidebar 240\nsidebar 240\n",
    "anvil-shell-windows 5\nloaded 1 3 abc\n",
    "anvil-shell-windows 5\nwindow 1 0 0 10 10 0 3 abc\nloaded 2 3 def\n",
    "anvil-shell-windows 5\nwindow 1 0 0 10 10 0 3 abc\nloaded 1 0 \n",
    "anvil-shell-windows 4\nsidebar 0 0\n",
    "anvil-shell-windows 4\nsidebar 240 2\n",
    "anvil-shell-windows 4\nsidebar 240 0\nsidebar 240 0\n",
    "anvil-shell-windows 3\nsidebar 240 0\n",
    "anvil-shell-windows 3\nproject -1 3 abc\n",
    "anvil-shell-windows 3\nproject 5 0 \n",
    "anvil-shell-windows 2\nwindow 0 0 0 10 10 0 0 \n",
    "anvil-shell-windows 2\nwindow 1 0 0 0 10 0 0 \n",
    "anvil-shell-windows 2\nwindow 1 0 0 10 10 2 0 \n",
    "anvil-shell-windows 2\nwindow 1 0 0 10 10 0 5 abc\n",
    "anvil-shell-windows 2\nwindow 1 0 0 10 10 0 3 abc\ngarbage\n",
  };
  for (size_t i = 0; i < SDL_arraysize(bad); i++) {
    CHECK(!anvil_shell_state_decode(bad[i], strlen(bad[i]), &decoded), "malformed file decoded");
    anvil_shell_state_free(&decoded);
  }
  CHECK(anvil_shell_state_decode("anvil-shell-windows 2\n", 22, &decoded) && decoded.count == 0,
        "empty state rejected");
  anvil_shell_state_free(&decoded);
  AnvilShellWindowState many[ANVIL_SHELL_STATE_MAX_WINDOWS + 1] = {0};
  for (size_t i = 0; i < SDL_arraysize(many); i++) many[i].id = 1, many[i].w = many[i].h = 10;
  AnvilShellState too_many = {many, SDL_arraysize(many)};
  size_t size;
  CHECK(!anvil_shell_state_encode(&too_many, &size), "Window bound not enforced");
}

static void writer(void) {
  wchar_t dir[MAX_PATH], file[MAX_PATH];
  GetTempPathW(MAX_PATH, dir);
  _snwprintf(file, MAX_PATH, L"%lsanvil-shell-state-test-%lu.state", dir, GetCurrentProcessId());
  DeleteFileW(file);
  AnvilShellState decoded;
  CHECK(!anvil_shell_state_load(file, &decoded), "missing file loaded");
  CHECK(anvil_shell_state_writer_start(file), "writer did not start");
  size_t size;
  AnvilShellState first = {sample, 1}, last = {sample, 3};
  char *data = anvil_shell_state_encode(&first, &size);
  anvil_shell_state_submit(data, size);
  data = anvil_shell_state_encode(&last, &size);
  anvil_shell_state_submit(data, size);
  CHECK(anvil_shell_state_writer_stop(5000), "writer did not finish");
  CHECK(anvil_shell_state_load(file, &decoded) && decoded.count == 3, "latest state was not written");
  anvil_shell_state_free(&decoded);
  DeleteFileW(file);
}

/* An adoption record names one Project process. A damaged record adopts nothing. */
static void adoption_records(void) {
  AnvilAdoptionRecord record = {4242, 0x01dc1234abcd5678ull, 9, "C:\\Projects\\R\xc3\xa9cord"}, decoded;
  size_t size = 0;
  char *data = anvil_adoption_encode(&record, &size);
  CHECK(data, "record encode failed");
  CHECK(data && anvil_adoption_decode(data, size, &decoded), "record decode failed");
  CHECK(decoded.pid == record.pid && decoded.created == record.created && decoded.window_id == record.window_id &&
        decoded.path && !strcmp(decoded.path, record.path), "record changed");
  anvil_adoption_free(&decoded);
  for (size_t cut = 0; data && cut < size; cut++) {
    CHECK(!anvil_adoption_decode(data, cut, &decoded), "partial record decoded");
    anvil_adoption_free(&decoded);
  }
  free(data);
  const char *bad[] = {
    "anvil-adoption 2\n1 1 1 1 a\n",
    "anvil-adoption 1\n0 1 1 1 a\n",
    "anvil-adoption 1\n1 1 1 0 \n",
    "anvil-adoption 1\n4294967296 1 1 1 a\n",
    "anvil-adoption 1\n1 1 1 1 ab\n",
    "anvil-adoption 1\n1 1 1 1 a\nextra",
  };
  for (size_t i = 0; i < SDL_arraysize(bad); i++) {
    CHECK(!anvil_adoption_decode(bad[i], strlen(bad[i]), &decoded), "malformed record decoded");
    anvil_adoption_free(&decoded);
  }
  AnvilAdoptionRecord empty = {1, 1, 1, NULL};
  CHECK(!anvil_adoption_encode(&empty, &size), "record without a Project encoded");
}

static bool run_wait(wchar_t *command, DWORD *exit_code) {
  STARTUPINFOW startup = {sizeof(startup)};
  PROCESS_INFORMATION process;
  if (!CreateProcessW(NULL, command, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &startup, &process))
    return false;
  WaitForSingleObject(process.hProcess, 10000);
  GetExitCodeProcess(process.hProcess, exit_code);
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  return true;
}

/* C:\Projects can be a link to D:\Projects. Both spellings of one install share one shell. */
static void linked_spellings(void) {
  wchar_t exe[MAX_PATH], dir[MAX_PATH], temp[MAX_PATH], link[MAX_PATH], linked_exe[MAX_PATH], command[MAX_PATH * 3];
  GetModuleFileNameW(NULL, exe, MAX_PATH);
  wcscpy(dir, exe);
  wchar_t *slash = wcsrchr(dir, L'\\');
  CHECK(slash, "test executable has no folder");
  if (!slash) return;
  *slash = 0;
  GetTempPathW(MAX_PATH, temp);
  _snwprintf(link, MAX_PATH, L"%lsanvil-shell-link-%lu", temp, GetCurrentProcessId());
  _snwprintf(linked_exe, MAX_PATH, L"%ls\\%ls", link, wcsrchr(exe, L'\\') + 1);
  _snwprintf(command, SDL_arraysize(command), L"cmd.exe /D /C mklink /J \"%ls\" \"%ls\" >NUL", link, dir);
  DWORD code = 1;
  CHECK(run_wait(command, &code) && code == 0, "could not create the folder link");
  if (code) return;
  CHECK(anvil_shell_launch_key(exe, dir) == anvil_shell_launch_key(linked_exe, link),
        "linked spelling has another shell key");
  /* A launcher started through the link checks the shell that runs from the resolved folder. */
  _snwprintf(command, SDL_arraysize(command), L"\"%ls\" identity %lu", linked_exe, GetCurrentProcessId());
  code = 1;
  CHECK(run_wait(command, &code), "could not start the test executable through the link");
  CHECK(code == 0, "linked spelling is not the same shell identity");
  /* Removes the link only, never the folder it points to. */
  CHECK(RemoveDirectoryW(link), "could not remove the folder link");
}

int main(int argc, char **argv) {
  loaded_projects();
  if (argc > 2 && !strcmp(argv[1], "identity"))
    return anvil_shell_same_identity(strtoul(argv[2], NULL, 10)) ? 0 : 1;
  round_trip();
  project_activity();
  sidebar_layout();
  rejects();
  writer();
  adoption_records();
  linked_spellings();
  if (failures) return 1;
  printf("shell state: ok\n");
  return 0;
}
