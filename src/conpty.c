#include "conpty.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

static HMODULE conpty_library;
static HRESULT (WINAPI *conpty_create)(COORD, HANDLE, HANDLE, DWORD, HPCON *);
static HRESULT (WINAPI *conpty_resize)(HPCON, COORD);
static void (WINAPI *conpty_close)(HPCON);

HRESULT anvil_conpty_resize(HPCON console, COORD size) {
  return conpty_resize(console, size);
}

void anvil_conpty_close_console(HPCON console) {
  conpty_close(console);
}

void anvil_conpty_kill(AnvilConPTY *pty) {
  if (pty->job) { CloseHandle(pty->job); pty->job = NULL; }
  else if (pty->process) TerminateProcess(pty->process, 1);
}

void anvil_conpty_close(AnvilConPTY *pty) {
  anvil_conpty_kill(pty);
  if (pty->pseudoconsole) { anvil_conpty_close_console(pty->pseudoconsole); pty->pseudoconsole = NULL; }
  if (pty->input_write) CloseHandle(pty->input_write);
  if (pty->output_read) CloseHandle(pty->output_read);
  if (pty->process) CloseHandle(pty->process);
  if (pty->process_thread) CloseHandle(pty->process_thread);
  memset(pty, 0, sizeof(*pty));
}

static void close_handle(HANDLE *handle) {
  if (*handle && *handle != INVALID_HANDLE_VALUE) {
    CloseHandle(*handle);
    *handle = NULL;
  }
}

static wchar_t *utf8_to_wide(const char *text) {
  if (!text) return NULL;
  int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
  if (count <= 0) return NULL;
  wchar_t *wide = (wchar_t *)HeapAlloc(GetProcessHeap(), 0, (size_t)count * sizeof(wchar_t));
  if (!wide) return NULL;
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, wide, count)) {
    HeapFree(GetProcessHeap(), 0, wide);
    return NULL;
  }
  return wide;
}

static bool create_kill_job(AnvilConPTY *session) {
  session->job = CreateJobObjectW(NULL, NULL);
  if (!session->job) return false;

  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
  memset(&limits, 0, sizeof(limits));
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(
    session->job, JobObjectExtendedLimitInformation, &limits, sizeof(limits)
  )) {
    close_handle(&session->job);
    return false;
  }
  if (!AssignProcessToJobObject(session->job, session->process)) {
    close_handle(&session->job);
    return false;
  }
  return true;
}

#ifndef ANVIL_PROJECT_VERSION_STR
#define ANVIL_PROJECT_VERSION_STR "unknown"
#endif

static bool environment_entry_has_key(const wchar_t *entry, const wchar_t *key) {
  size_t length = wcslen(key);
  return _wcsnicmp(entry, key, length) == 0 && entry[length] == L'=';
}

static wchar_t *terminal_environment(void) {
  LPWCH inherited = GetEnvironmentStringsW();
  if (!inherited) return NULL;
  static const wchar_t *keys[] = {
    L"TERM_PROGRAM", L"TERM_PROGRAM_VERSION", L"TERM", L"COLORTERM",
  };
  static const wchar_t *fixed_prefixes[] = {
    L"TERM_PROGRAM=anvil", L"TERM_PROGRAM_VERSION=", L"TERM=xterm-256color",
    L"COLORTERM=truecolor",
  };
  wchar_t *version = utf8_to_wide(ANVIL_PROJECT_VERSION_STR);
  if (!version) {
    FreeEnvironmentStringsW(inherited);
    return NULL;
  }
  size_t chars = 2;
  for (const wchar_t *entry = inherited; *entry; entry += wcslen(entry) + 1) {
    bool replace = false;
    for (size_t index = 0; index < 4; index++) {
      if (environment_entry_has_key(entry, keys[index])) { replace = true; break; }
    }
    if (!replace) chars += wcslen(entry) + 1;
  }
  chars += wcslen(fixed_prefixes[0]) + 1;
  chars += wcslen(fixed_prefixes[1]) + wcslen(version) + 1;
  chars += wcslen(fixed_prefixes[2]) + 1;
  chars += wcslen(fixed_prefixes[3]) + 1;
  wchar_t *block = (wchar_t *)HeapAlloc(GetProcessHeap(), 0, chars * sizeof(wchar_t));
  if (!block) {
    HeapFree(GetProcessHeap(), 0, version);
    FreeEnvironmentStringsW(inherited);
    return NULL;
  }
  wchar_t *out = block;
  for (const wchar_t *entry = inherited; *entry; entry += wcslen(entry) + 1) {
    bool replace = false;
    for (size_t index = 0; index < 4; index++) {
      if (environment_entry_has_key(entry, keys[index])) { replace = true; break; }
    }
    if (replace) continue;
    size_t length = wcslen(entry) + 1;
    memcpy(out, entry, length * sizeof(wchar_t));
    out += length;
  }
  size_t length = wcslen(fixed_prefixes[0]) + 1;
  memcpy(out, fixed_prefixes[0], length * sizeof(wchar_t)); out += length;
  length = wcslen(fixed_prefixes[1]);
  memcpy(out, fixed_prefixes[1], length * sizeof(wchar_t)); out += length;
  length = wcslen(version);
  memcpy(out, version, length * sizeof(wchar_t)); out += length; *out++ = L'\0';
  for (size_t index = 2; index < 4; index++) {
    length = wcslen(fixed_prefixes[index]) + 1;
    memcpy(out, fixed_prefixes[index], length * sizeof(wchar_t)); out += length;
  }
  *out = L'\0';
  HeapFree(GetProcessHeap(), 0, version);
  FreeEnvironmentStringsW(inherited);
  return block;
}

static bool create_shell_process(
  AnvilConPTY *session, const char *command_utf8, const char *cwd_utf8, DWORD *error_out
) {
  wchar_t *command = utf8_to_wide(command_utf8);
  wchar_t *cwd = cwd_utf8 && cwd_utf8[0] ? utf8_to_wide(cwd_utf8) : NULL;
  if (!command || (cwd_utf8 && cwd_utf8[0] && !cwd)) {
    if (command) HeapFree(GetProcessHeap(), 0, command);
    if (cwd) HeapFree(GetProcessHeap(), 0, cwd);
    *error_out = ERROR_NOT_ENOUGH_MEMORY;
    return false;
  }

  SIZE_T attribute_size = 0;
  InitializeProcThreadAttributeList(NULL, 1, 0, &attribute_size);
  PPROC_THREAD_ATTRIBUTE_LIST attributes =
    (PPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(GetProcessHeap(), 0, attribute_size);
  if (!attributes) {
    HeapFree(GetProcessHeap(), 0, command);
    if (cwd) HeapFree(GetProcessHeap(), 0, cwd);
    *error_out = ERROR_NOT_ENOUGH_MEMORY;
    return false;
  }

  bool initialized = InitializeProcThreadAttributeList(attributes, 1, 0, &attribute_size) != FALSE;
  bool updated = initialized && UpdateProcThreadAttribute(
    attributes, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
    session->pseudoconsole, sizeof(session->pseudoconsole), NULL, NULL
  ) != FALSE;

  STARTUPINFOEXW startup;
  PROCESS_INFORMATION process;
  memset(&startup, 0, sizeof(startup));
  memset(&process, 0, sizeof(process));
  startup.StartupInfo.cb = sizeof(startup);
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  startup.lpAttributeList = attributes;
  wchar_t *environment = terminal_environment();

  bool created = updated && environment && CreateProcessW(
    NULL, command, NULL, NULL, FALSE,
    EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED,
    environment, cwd, &startup.StartupInfo, &process
  ) != FALSE;
  *error_out = created ? ERROR_SUCCESS : environment ? GetLastError() : ERROR_NOT_ENOUGH_MEMORY;

  if (initialized) DeleteProcThreadAttributeList(attributes);
  HeapFree(GetProcessHeap(), 0, attributes);
  HeapFree(GetProcessHeap(), 0, command);
  if (environment) HeapFree(GetProcessHeap(), 0, environment);
  if (cwd) HeapFree(GetProcessHeap(), 0, cwd);

  if (!created) return false;
  session->process = process.hProcess;
  session->process_thread = process.hThread;
  if (!create_kill_job(session)) {
    *error_out = GetLastError();
    TerminateProcess(session->process, 1);
    WaitForSingleObject(session->process, INFINITE);
    close_handle(&session->process_thread);
    close_handle(&session->process);
    return false;
  }
  if (ResumeThread(session->process_thread) == (DWORD)-1) {
    *error_out = GetLastError();
    close_handle(&session->job);
    WaitForSingleObject(session->process, INFINITE);
    close_handle(&session->process_thread);
    close_handle(&session->process);
    return false;
  }
  return true;
}

bool anvil_conpty_start(
  AnvilConPTY *session, const char *shell, const char *cwd, const char *datadir, DWORD *error_out
) {
  if (!conpty_library) {
    size_t length = strlen(datadir) + sizeof("/conpty/conpty.dll");
    char *path = malloc(length);
    if (!path) { *error_out = ERROR_NOT_ENOUGH_MEMORY; return false; }
    snprintf(path, length, "%s/conpty/conpty.dll", datadir);
    wchar_t *wide = utf8_to_wide(path);
    free(path);
    if (!wide) { *error_out = ERROR_NO_UNICODE_TRANSLATION; return false; }
    HMODULE library = LoadLibraryExW(wide, NULL,
      LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    *error_out = GetLastError();
    HeapFree(GetProcessHeap(), 0, wide);
    if (!library) return false;
    conpty_create = (void *)GetProcAddress(library, "ConptyCreatePseudoConsole");
    conpty_resize = (void *)GetProcAddress(library, "ConptyResizePseudoConsole");
    conpty_close = (void *)GetProcAddress(library, "ConptyClosePseudoConsole");
    if (!conpty_create || !conpty_resize || !conpty_close) {
      *error_out = ERROR_PROC_NOT_FOUND;
      FreeLibrary(library);
      return false;
    }
    /* Keep the DLL loaded until this Terminal Session host exits. */
    conpty_library = library;
  }
  HANDLE input_read = NULL;
  HANDLE output_write = NULL;
  SECURITY_ATTRIBUTES security = {
    .nLength = sizeof(SECURITY_ATTRIBUTES),
    .lpSecurityDescriptor = NULL,
    .bInheritHandle = TRUE,
  };

  if (!CreatePipe(&input_read, &session->input_write, &security, 0) ||
      !CreatePipe(&session->output_read, &output_write, &security, 0)) {
    *error_out = GetLastError();
    close_handle(&input_read);
    close_handle(&output_write);
    return false;
  }
  SetHandleInformation(session->input_write, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(session->output_read, HANDLE_FLAG_INHERIT, 0);

  COORD size = { (SHORT)session->cols, (SHORT)session->rows };
  HRESULT result = conpty_create(size, input_read, output_write, 0, &session->pseudoconsole);
  if (FAILED(result)) {
    close_handle(&input_read);
    close_handle(&output_write);
    *error_out = HRESULT_CODE(result);
    return false;
  }

  bool created = false;
  if (shell && shell[0]) {
    created = create_shell_process(session, shell, cwd, error_out);
  } else if (create_shell_process(session, "pwsh.exe -NoLogo", cwd, error_out)) {
    created = true;
  } else {
    created = create_shell_process(session, "powershell.exe -NoLogo", cwd, error_out);
  }
  close_handle(&input_read);
  close_handle(&output_write);
  return created;
}
