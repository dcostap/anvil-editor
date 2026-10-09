#include <windows.h>
#include <SDL3/SDL.h>
#include <stdio.h>
#include "sidebar_registry_watch.h"

#define CHECK(value) do { if (!(value)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #value); return 1; } } while (0)
static unsigned changes;
static LRESULT CALLBACK window_proc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_APP + 1) { changes++; return 0; }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}
static void drain(void) {
  MSG message;
  while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) DispatchMessageW(&message);
}
static void write_record(const char *path) {
  FILE *file = fopen(path, "wb");
  if (file) { fputs("return {}", file); fclose(file); }
}
int main(void) {
  CHECK(SDL_Init(0));
  WNDCLASSW cls = {.lpfnWndProc = window_proc, .hInstance = GetModuleHandleW(NULL), .lpszClassName = L"AnvilRegistryWatchTest"};
  CHECK(RegisterClassW(&cls));
  HWND window = CreateWindowW(cls.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, NULL, cls.hInstance, NULL);
  CHECK(window);
  char temporary[MAX_PATH], root[MAX_PATH], sessions[MAX_PATH], nested[MAX_PATH], record[MAX_PATH], child[MAX_PATH];
  CHECK(GetTempPathA(sizeof(temporary), temporary));
  SDL_snprintf(root, sizeof(root), "%sanvil-registry-watch-%lu", temporary, GetCurrentProcessId());
  SDL_snprintf(sessions, sizeof(sessions), "%s\\terminal-sessions", root);
  SDL_snprintf(nested, sizeof(nested), "%s\\nested", sessions);
  SDL_snprintf(record, sizeof(record), "%s\\record.lua", sessions);
  SDL_snprintf(child, sizeof(child), "%s\\record.lua", nested);
  CHECK(CreateDirectoryA(root, NULL));
  CHECK(CreateDirectoryA(sessions, NULL));
  CHECK(CreateDirectoryA(nested, NULL));
  AnvilSidebarWatch *watch = anvil_sidebar_watch_start(root, window, WM_APP + 1);
  CHECK(watch);
  /* A real record notification proves that the worker has armed its watch. */
  Uint64 deadline = SDL_GetTicks() + 3000;
  while (!changes && SDL_GetTicks() < deadline) { write_record(record); SDL_Delay(20); drain(); }
  CHECK(changes);
  SDL_Delay(100); drain();
  changes = 0;
  write_record(child);
  deadline = SDL_GetTicks() + 300;
  while (SDL_GetTicks() < deadline) { drain(); SDL_Delay(1); }
  CHECK(changes == 0);
  write_record(record);
  deadline = SDL_GetTicks() + 3000;
  while (!changes && SDL_GetTicks() < deadline) { drain(); SDL_Delay(1); }
  CHECK(changes);
  CHECK(anvil_sidebar_watch_stop(watch, SDL_GetTicks() + 1000));
  DeleteFileA(child); DeleteFileA(record);
  RemoveDirectoryA(nested); RemoveDirectoryA(sessions); RemoveDirectoryA(root);
  DestroyWindow(window);
  SDL_Quit();
  puts("PASS only direct Terminal Session records request Sidebar refresh");
  return 0;
}
