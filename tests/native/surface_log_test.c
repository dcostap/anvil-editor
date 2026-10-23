#include "surface_protocol.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

/* Seam: native SDL diagnostics persist without an environment switch.
 * Each child uses the real user-directory resolver and log output callback. */
#define CHECK(value) do { if (!(value)) { fprintf(stderr, "FAIL line %d: %s (Windows error %lu)\n", __LINE__, #value, GetLastError()); return 1; } } while (0)

static int run_child(const wchar_t *role) {
  wchar_t exe[32768], command[32832];
  CHECK(GetModuleFileNameW(NULL, exe, SDL_arraysize(exe)));
  _snwprintf(command, SDL_arraysize(command), L"\"%ls\" child %ls", exe, role);
  STARTUPINFOW startup = {.cb = sizeof(startup)};
  PROCESS_INFORMATION process;
  CHECK(CreateProcessW(exe, command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &process));
  DWORD wait = WaitForSingleObject(process.hProcess, 30000), code = 1;
  if (wait != WAIT_OBJECT_0) TerminateProcess(process.hProcess, 1);
  GetExitCodeProcess(process.hProcess, &code);
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  CHECK(wait == WAIT_OBJECT_0 && code == 0);
  return 0;
}

static int check_log(const wchar_t *path, bool shared, unsigned *roles) {
  FILE *file = _wfopen(path, L"rb");
  CHECK(file);
  char text[16384];
  size_t length = fread(text, 1, sizeof(text) - 1, file);
  fclose(file);
  text[length] = 0;
  if (strstr(text, "shell[")) *roles |= 1;
  if (strstr(text, "hosted[")) *roles |= 2;
  if (!shared) CHECK(strstr(text, "thread="));
  CHECK(strstr(text, "native test: connection failed"));
  CHECK(strstr(text, "native test: shell connection lost"));
  CHECK(DeleteFileW(path));
  return 0;
}

int main(int argc, char **argv) {
  if (argc == 3 && !strcmp(argv[1], "child")) {
    anvil_surface_log_init(argv[2]);
    SDL_Log("native test: connection failed");
    SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "native test: shell connection lost");
    return 0;
  }
  wchar_t temp[MAX_PATH], root[MAX_PATH], user[MAX_PATH], logs[MAX_PATH], pattern[MAX_PATH], path[MAX_PATH];
  CHECK(GetTempPathW(SDL_arraysize(temp), temp));
  CHECK(GetTempFileNameW(temp, L"avl", 0, root));
  CHECK(DeleteFileW(root) && CreateDirectoryW(root, NULL));
  /* Timing capture stays off disk until stopped and starts each run empty. */
  _snwprintf(path, SDL_arraysize(path), L"%ls\\timing.csv", root);
  char *timing_path = SDL_iconv_string("UTF-8", "UTF-16LE", (char *)path,
                                     (wcslen(path) + 1) * sizeof(wchar_t));
  CHECK(timing_path);
  anvil_timing_note("outside", 0, 0, 0);
  CHECK(anvil_timing_capture(timing_path));
  anvil_timing_note("input", 42, 7, 9);
  CHECK(GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES);
  CHECK(anvil_timing_capture(""));
  FILE *timing = _wfopen(path, L"rb");
  CHECK(timing);
  char timing_text[4096] = {0};
  fread(timing_text, 1, sizeof(timing_text) - 1, timing);
  fclose(timing);
  CHECK(strstr(timing_text, ",input,42,7,9"));
  CHECK(!strstr(timing_text, "outside"));
  CHECK(DeleteFileW(path));
  CHECK(anvil_timing_capture(timing_path));
  CHECK(anvil_timing_capture(""));
  timing = _wfopen(path, L"rb");
  CHECK(timing);
  memset(timing_text, 0, sizeof(timing_text));
  fread(timing_text, 1, sizeof(timing_text) - 1, timing);
  fclose(timing);
  CHECK(!strstr(timing_text, ",input,"));
  CHECK(DeleteFileW(path));
  SDL_free(timing_path);
  _snwprintf(user, SDL_arraysize(user), L"%ls\\usu\x00e1rio", root);
  _snwprintf(logs, SDL_arraysize(logs), L"%ls\\logs", user);
  CHECK(SetEnvironmentVariableW(L"ANVIL_USERDIR", user));
  CHECK(SetEnvironmentVariableW(L"ANVIL_SURFACE_LOG", NULL));
  CHECK(run_child(L"shell") == 0);
  CHECK(run_child(L"hosted") == 0);
  _snwprintf(pattern, SDL_arraysize(pattern), L"%ls\\anvil-*-native.log", logs);
  WIN32_FIND_DATAW entry;
  HANDLE scan = FindFirstFileW(pattern, &entry);
  CHECK(scan != INVALID_HANDLE_VALUE);
  unsigned count = 0, roles = 0;
  do {
    _snwprintf(path, SDL_arraysize(path), L"%ls\\%ls", logs, entry.cFileName);
    CHECK(check_log(path, false, &roles) == 0);
    count++;
  } while (FindNextFileW(scan, &entry));
  FindClose(scan);
  CHECK(count == 2 && roles == 3);
  CHECK(RemoveDirectoryW(logs) && RemoveDirectoryW(user));

  /* An explicit shared path remains available to existing probes. */
  _snwprintf(path, SDL_arraysize(path), L"%ls\\override.log", root);
  CHECK(SetEnvironmentVariableW(L"ANVIL_SURFACE_LOG", path));
  CHECK(run_child(L"shell") == 0);
  CHECK(run_child(L"hosted") == 0);
  roles = 0;
  CHECK(check_log(path, true, &roles) == 0 && roles == 3);
  CHECK(GetFileAttributesW(logs) == INVALID_FILE_ATTRIBUTES);
  CHECK(RemoveDirectoryW(root));
  puts("native diagnostics persist by default; explicit shared logs still work");
  return 0;
}
