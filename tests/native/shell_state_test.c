#include "shell_state.h"
#include <SDL3/SDL.h>
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
#define CHECK(cond, message) do { if (!(cond)) { fprintf(stderr, "FAIL: %s\n", message); failures++; } } while (0)

static AnvilShellWindowState sample[] = {
  {-8, 40, 1200, 800, true, "C:\\Projects\\Front Project"},
  {100, 120, 900, 700, false, NULL},
  {30, 30, 640, 480, false, "D:\\x\\\xc3\xa9t\xc3\xa9"},
};

static void round_trip(void) {
  AnvilShellState state = {sample, 3}, decoded;
  size_t size = 0;
  char *data = anvil_shell_state_encode(&state, &size);
  CHECK(data, "encode failed");
  CHECK(anvil_shell_state_decode(data, size, &decoded), "decode failed");
  CHECK(decoded.count == 3, "Window count changed");
  for (size_t i = 0; i < 3 && i < decoded.count; i++) {
    AnvilShellWindowState *a = &sample[i], *b = &decoded.windows[i];
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
    "anvil-shell-windows 2\n",
    "anvil-shell-windows 1\nwindow 0 0 0 10 0 0 \n",
    "anvil-shell-windows 1\nwindow 0 0 10 10 2 0 \n",
    "anvil-shell-windows 1\nwindow 0 0 10 10 0 5 abc\n",
    "anvil-shell-windows 1\nwindow 0 0 10 10 0 3 abc\ngarbage\n",
  };
  for (size_t i = 0; i < SDL_arraysize(bad); i++) {
    CHECK(!anvil_shell_state_decode(bad[i], strlen(bad[i]), &decoded), "malformed file decoded");
    anvil_shell_state_free(&decoded);
  }
  CHECK(anvil_shell_state_decode("anvil-shell-windows 1\n", 22, &decoded) && decoded.count == 0,
        "empty state rejected");
  anvil_shell_state_free(&decoded);
  AnvilShellWindowState many[ANVIL_SHELL_STATE_MAX_WINDOWS + 1] = {0};
  for (size_t i = 0; i < SDL_arraysize(many); i++) many[i].w = many[i].h = 10;
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

int main(int argc, char **argv) {
  (void)argc; (void)argv;
  round_trip();
  rejects();
  writer();
  if (failures) return 1;
  printf("shell state: ok\n");
  return 0;
}
