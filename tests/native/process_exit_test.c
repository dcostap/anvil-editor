#include <windows.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "process_exit.h"

/* Seam: ending a process whose idle-priority threads compete with a saturated CPU.
 * GPU drivers create such threads. Without help they exit only after the ~4 s starvation boost. */
#define CHECK(value) do { if (!(value)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #value); return 1; } } while (0)
#define IDLE_THREADS 12

static volatile LONG ready, stop;
static DWORD WINAPI idle_thread(void *data) {
  (void)data;
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_IDLE);
  InterlockedIncrement(&ready);
  Sleep(INFINITE);
  return 0;
}
static DWORD WINAPI busy_thread(void *data) {
  (void)data;
  while (!stop) YieldProcessor();
  return 0;
}
static int child(HANDLE started, HANDLE exit_request) {
  /* Anvil registers this hook at startup. */
  if (exit_request) atexit(anvil_process_prepare_exit);
  for (int i = 0; i < IDLE_THREADS; i++) CloseHandle(CreateThread(NULL, 0, idle_thread, NULL, 0, NULL));
  while (ready < IDLE_THREADS) Sleep(1);
  Sleep(50); /* Let each thread enter its wait. */
  SetEvent(started);
  WaitForSingleObject(exit_request ? exit_request : GetCurrentProcess(), INFINITE);
  exit(7);
}
/* Returns the time from the exit request until the process object is signaled.
 * A normal exit runs the child's exit path; otherwise the parent terminates the child. */
static DWORD exit_under_load(bool normal_exit, bool *ok) {
  SECURITY_ATTRIBUTES inherit = {sizeof(inherit), NULL, TRUE};
  HANDLE started = CreateEventW(&inherit, TRUE, FALSE, NULL);
  HANDLE exit_request = normal_exit ? CreateEventW(&inherit, TRUE, FALSE, NULL) : NULL;
  wchar_t exe[MAX_PATH], command[MAX_PATH + 96];
  GetModuleFileNameW(NULL, exe, MAX_PATH);
  _snwprintf(command, sizeof(command) / sizeof(*command), L"\"%ls\" child %llu %llu", exe,
             (unsigned long long)(uintptr_t)started, (unsigned long long)(uintptr_t)exit_request);
  STARTUPINFOW startup = {sizeof(startup)};
  PROCESS_INFORMATION info;
  ready = 0;
  *ok = started && CreateProcessW(exe, command, NULL, NULL, TRUE, 0, NULL, NULL, &startup, &info);
  if (!*ok) return 0;
  *ok = WaitForSingleObject(started, 10000) == WAIT_OBJECT_0;
  CloseHandle(started);
  /* Saturate every logical processor with normal-priority work. */
  SYSTEM_INFO system;
  GetSystemInfo(&system);
  HANDLE busy[256];
  DWORD count = system.dwNumberOfProcessors < 256 ? system.dwNumberOfProcessors : 256;
  stop = 0;
  for (DWORD i = 0; i < count; i++) busy[i] = CreateThread(NULL, 0, busy_thread, NULL, 0, NULL);
  Sleep(100);
  DWORD begin = GetTickCount();
  *ok = *ok && (normal_exit ? SetEvent(exit_request) : anvil_process_terminate(info.hProcess, 7));
  *ok = *ok && WaitForSingleObject(info.hProcess, 15000) == WAIT_OBJECT_0;
  DWORD elapsed = GetTickCount() - begin;
  stop = 1;
  WaitForMultipleObjects(count, busy, TRUE, INFINITE);
  for (DWORD i = 0; i < count; i++) CloseHandle(busy[i]);
  DWORD code = 0;
  *ok = *ok && GetExitCodeProcess(info.hProcess, &code) && code == 7;
  if (exit_request) CloseHandle(exit_request);
  CloseHandle(info.hThread);
  CloseHandle(info.hProcess);
  return elapsed;
}
int main(int argc, char **argv) {
  if (argc == 4 && !strcmp(argv[1], "child"))
    return child((HANDLE)(uintptr_t)_strtoui64(argv[2], NULL, 10), (HANDLE)(uintptr_t)_strtoui64(argv[3], NULL, 10));
  /* The measuring thread must not compete with the load it creates. */
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST);
  /* The starvation boost alone takes about 4 s. */
  bool ok;
  DWORD elapsed = exit_under_load(false, &ok);
  printf("terminated idle-thread process exit under load: %lu ms\n", (unsigned long)elapsed);
  CHECK(ok);
  elapsed = exit_under_load(true, &ok);
  printf("normal idle-thread process exit under load: %lu ms\n", (unsigned long)elapsed);
  CHECK(ok);
  return 0;
}
