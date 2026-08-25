#include "win32_window_handoff.h"

#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ANVIL_HANDOFF_MESSAGE_NAME L"Anvil.WindowHandoff.Probe.V1"
#define ANVIL_HANDOFF_FRAME_PROP L"AnvilWindowHandoffFrameGeneration"
#define ANVIL_HANDOFF_PING 0u
#define ANVIL_HANDOFF_DEACTIVATE 1u
#define ANVIL_HANDOFF_PREPARE 2u
#define ANVIL_HANDOFF_ACTIVATE 3u
#define ANVIL_HANDOFF_STOP 4u
#define ANVIL_HANDOFF_FOCUS_READY 5u
#define ANVIL_HANDOFF_PING_RESULT ((intptr_t)0x41564850u)
#define ANVIL_HANDOFF_START_TIMEOUT_MS 20000u
#define ANVIL_HANDOFF_FRAME_TIMEOUT_MS 5000u
#define ANVIL_HANDOFF_MAX_COMMAND 64u

static bool probe_child = false;
static volatile LONG project_selected = 1;
static volatile LONG show_allowed = 1;
static volatile LONG frame_generation = 0;
static SDL_Window *project_window = NULL;
static HWND project_hwnd = NULL;
static UINT handoff_message = 0;

typedef struct ProbeProject {
  PROCESS_INFORMATION process;
  HWND hwnd;
  char name;
} ProbeProject;

typedef struct FindWindowData {
  DWORD pid;
  HWND hwnd;
} FindWindowData;

static UINT get_handoff_message(void) {
  if (!handoff_message) handoff_message = RegisterWindowMessageW(ANVIL_HANDOFF_MESSAGE_NAME);
  return handoff_message;
}

static bool env_is_true(const char *name) {
  const char *value = getenv(name);
  if (!value || !value[0]) return false;
  return value[0] == '1' || _stricmp(value, "true") == 0 || _stricmp(value, "yes") == 0;
}

static bool utf8_to_wide(const char *text, wchar_t *wide, int count) {
  if (!text || !wide || count <= 0) return false;
  return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, wide, count) > 0;
}

void anvil_window_handoff_init_child(void) {
  probe_child = env_is_true("ANVIL_WINDOW_HANDOFF_PROBE_CHILD");
  project_selected = 1;
  show_allowed = !probe_child || env_is_true("ANVIL_WINDOW_HANDOFF_PROBE_ACTIVE");
  if (probe_child) get_handoff_message();
}

bool anvil_window_handoff_is_probe_child(void) {
  return probe_child;
}

bool anvil_window_handoff_project_is_selected(void) {
  return !probe_child || InterlockedCompareExchange(&project_selected, 0, 0) != 0;
}

bool anvil_window_handoff_allow_show(SDL_Window *window) {
  (void)window;
  return !probe_child || InterlockedCompareExchange(&show_allowed, 0, 0) != 0;
}

void anvil_window_handoff_register_window(SDL_Window *window) {
  if (!probe_child || !window) return;
  project_window = window;
  SDL_PropertiesID props = SDL_GetWindowProperties(window);
  project_hwnd = (HWND)SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WIN32_HWND_POINTER, NULL);
}

void anvil_window_handoff_frame_presented(SDL_Window *window) {
  if (!probe_child || !window || window != project_window || !project_hwnd) return;
  LONG generation = InterlockedIncrement(&frame_generation);
  SetPropW(project_hwnd, ANVIL_HANDOFF_FRAME_PROP, (HANDLE)(intptr_t)generation);
}

static void request_project_frame(void) {
  if (!project_window) return;
  SDL_Event event;
  SDL_zero(event);
  event.type = SDL_EVENT_WINDOW_EXPOSED;
  event.window.windowID = SDL_GetWindowID(project_window);
  SDL_PushEvent(&event);
}

bool anvil_window_handoff_handle_message(
  void *native_window,
  unsigned int message,
  uintptr_t wparam,
  intptr_t lparam,
  intptr_t *result
) {
  if (!probe_child || message != get_handoff_message()) return false;

  HWND hwnd = (HWND)native_window;
  switch ((unsigned int)wparam) {
    case ANVIL_HANDOFF_PING:
      if (result) *result = ANVIL_HANDOFF_PING_RESULT;
      return true;

    case ANVIL_HANDOFF_DEACTIVATE:
      InterlockedExchange(&show_allowed, 0);
      InterlockedExchange(&project_selected, 0);
      if (project_window) SDL_HideWindow(project_window);
      else ShowWindow(hwnd, SW_HIDE);
      if (result) *result = 1;
      return true;

    case ANVIL_HANDOFF_PREPARE:
      InterlockedExchange(&show_allowed, 0);
      InterlockedExchange(&project_selected, 1);
      request_project_frame();
      if (result) *result = 1;
      return true;

    case ANVIL_HANDOFF_ACTIVATE: {
      int show_command = (int)lparam == SW_MAXIMIZE ? SW_MAXIMIZE : SW_RESTORE;
      InterlockedExchange(&project_selected, 1);
      InterlockedExchange(&show_allowed, 1);
      if (show_command == SW_MAXIMIZE || !IsWindowVisible(hwnd)) {
        ShowWindow(hwnd, show_command);
      }
      BringWindowToTop(hwnd);
      SetForegroundWindow(hwnd);
      request_project_frame();
      if (result) *result = 1;
      return true;
    }

    case ANVIL_HANDOFF_FOCUS_READY:
      if (result) {
        unsigned int flags = project_window ? SDL_GetWindowFlags(project_window) : 0;
        *result = GetForegroundWindow() == hwnd &&
                  (flags & SDL_WINDOW_INPUT_FOCUS) != 0 &&
                  project_window && SDL_TextInputActive(project_window);
      }
      return true;

    case ANVIL_HANDOFF_STOP:
      PostMessageW(hwnd, WM_CLOSE, 0, 0);
      if (result) *result = 1;
      return true;
  }

  return false;
}

static BOOL CALLBACK find_project_window(HWND hwnd, LPARAM lparam) {
  FindWindowData *data = (FindWindowData *)lparam;
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  if (pid != data->pid || GetWindow(hwnd, GW_OWNER) != NULL) return TRUE;

  LONG_PTR style = GetWindowLongPtrW(hwnd, GWL_STYLE);
  RECT rect = {0};
  if ((style & WS_CHILD) || !GetWindowRect(hwnd, &rect) ||
      rect.right <= rect.left || rect.bottom <= rect.top) {
    return TRUE;
  }

  data->hwnd = hwnd;
  return FALSE;
}

static HWND find_window_for_process(DWORD pid) {
  FindWindowData data = { .pid = pid, .hwnd = NULL };
  EnumWindows(find_project_window, (LPARAM)&data);
  return data.hwnd;
}

static bool send_handoff_message(HWND hwnd, unsigned int action, intptr_t value, intptr_t *result) {
  DWORD_PTR message_result = 0;
  if (!hwnd || !SendMessageTimeoutW(
        hwnd,
        get_handoff_message(),
        (WPARAM)action,
        (LPARAM)value,
        SMTO_ABORTIFHUNG | SMTO_BLOCK,
        2000,
        &message_result)) {
    return false;
  }
  if (result) *result = (intptr_t)message_result;
  return true;
}

static bool project_window_ready(ProbeProject *project) {
  if (!project || !project->process.hProcess) return false;
  if (WaitForSingleObject(project->process.hProcess, 0) == WAIT_OBJECT_0) {
    DWORD exit_code = 0;
    GetExitCodeProcess(project->process.hProcess, &exit_code);
    fprintf(stderr, "Handoff probe Project %c exited during startup with code %lu.\n",
            project->name, (unsigned long)exit_code);
    return false;
  }
  project->hwnd = find_window_for_process(project->process.dwProcessId);
  intptr_t result = 0;
  return project->hwnd &&
         send_handoff_message(project->hwnd, ANVIL_HANDOFF_PING, 0, &result) &&
         result == ANVIL_HANDOFF_PING_RESULT;
}

static LONG window_frame_generation(HWND hwnd) {
  return (LONG)(intptr_t)GetPropW(hwnd, ANVIL_HANDOFF_FRAME_PROP);
}

static bool wait_for_frame_after(HWND hwnd, LONG generation, DWORD timeout_ms) {
  DWORD start = GetTickCount();
  while (GetTickCount() - start < timeout_ms) {
    if (window_frame_generation(hwnd) > generation) return true;
    Sleep(10);
  }
  return false;
}

static bool wait_for_project_ready(ProbeProject *project, DWORD timeout_ms) {
  DWORD start = GetTickCount();
  while (GetTickCount() - start < timeout_ms) {
    if (project_window_ready(project) && window_frame_generation(project->hwnd) > 0) return true;
    if (project->process.hProcess &&
        WaitForSingleObject(project->process.hProcess, 0) == WAIT_OBJECT_0) {
      return false;
    }
    Sleep(20);
  }
  fprintf(stderr, "Handoff probe Project %c did not become ready.\n", project->name);
  return false;
}

static wchar_t *saved_environment_value(const wchar_t *name) {
  DWORD size = GetEnvironmentVariableW(name, NULL, 0);
  if (!size) return NULL;
  wchar_t *value = (wchar_t *)malloc(sizeof(wchar_t) * size);
  if (!value) return NULL;
  if (!GetEnvironmentVariableW(name, value, size)) {
    free(value);
    return NULL;
  }
  return value;
}

static void restore_environment_value(const wchar_t *name, wchar_t *value) {
  SetEnvironmentVariableW(name, value);
  free(value);
}

static bool make_child_user_dir(const wchar_t *base, char role, wchar_t *out, size_t count) {
  if (!base || !base[0] || !out || count == 0) return false;
  int written = swprintf(out, count, L"%ls\\project-%lc", base, (wchar_t)role);
  if (written <= 0 || (size_t)written >= count) return false;
  return CreateDirectoryW(out, NULL) || GetLastError() == ERROR_ALREADY_EXISTS;
}

static bool path_has_quote(const wchar_t *path) {
  return path && wcschr(path, L'"') != NULL;
}

static bool launch_project(
  const wchar_t *exe,
  const wchar_t *project_path,
  const wchar_t *base_user_dir,
  char role,
  bool active,
  HANDLE job,
  ProbeProject *out
) {
  if (!exe || !project_path || !out || path_has_quote(exe) || path_has_quote(project_path)) return false;

  wchar_t file_path[32768];
  wchar_t child_user_dir[32768];
  wchar_t command_line[65536];
  if (swprintf(file_path, sizeof(file_path) / sizeof(file_path[0]),
               L"%ls\\handoff.txt", project_path) <= 0 ||
      !make_child_user_dir(base_user_dir, role, child_user_dir,
                           sizeof(child_user_dir) / sizeof(child_user_dir[0])) ||
      swprintf(command_line, sizeof(command_line) / sizeof(command_line[0]),
               L"\"%ls\" \"%ls\"", exe, file_path) <= 0) {
    return false;
  }

  wchar_t *old_child = saved_environment_value(L"ANVIL_WINDOW_HANDOFF_PROBE_CHILD");
  wchar_t *old_active = saved_environment_value(L"ANVIL_WINDOW_HANDOFF_PROBE_ACTIVE");
  wchar_t *old_user = saved_environment_value(L"ANVIL_USERDIR");
  SetEnvironmentVariableW(L"ANVIL_WINDOW_HANDOFF_PROBE_CHILD", L"1");
  SetEnvironmentVariableW(L"ANVIL_WINDOW_HANDOFF_PROBE_ACTIVE", active ? L"1" : L"0");
  SetEnvironmentVariableW(L"ANVIL_USERDIR", child_user_dir);

  STARTUPINFOW startup;
  ZeroMemory(&startup, sizeof(startup));
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process;
  ZeroMemory(&process, sizeof(process));
  BOOL created = CreateProcessW(
    exe,
    command_line,
    NULL,
    NULL,
    FALSE,
    0,
    NULL,
    project_path,
    &startup,
    &process
  );

  restore_environment_value(L"ANVIL_WINDOW_HANDOFF_PROBE_CHILD", old_child);
  restore_environment_value(L"ANVIL_WINDOW_HANDOFF_PROBE_ACTIVE", old_active);
  restore_environment_value(L"ANVIL_USERDIR", old_user);

  if (!created) return false;
  if (job && !AssignProcessToJobObject(job, process.hProcess)) {
    fprintf(stderr, "Could not add handoff probe Project %c to the Job Object: %lu.\n",
            role, (unsigned long)GetLastError());
    TerminateProcess(process.hProcess, 1);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return false;
  }

  out->process = process;
  out->hwnd = NULL;
  out->name = role;
  return true;
}

static HANDLE create_child_job(void) {
  HANDLE job = CreateJobObjectW(NULL, NULL);
  if (!job) return NULL;
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION info;
  ZeroMemory(&info, sizeof(info));
  info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &info, sizeof(info))) {
    CloseHandle(job);
    return NULL;
  }
  return job;
}

static void stop_project(ProbeProject *project) {
  if (!project || !project->process.hProcess) return;
  if (project->hwnd) send_handoff_message(project->hwnd, ANVIL_HANDOFF_STOP, 0, NULL);
  if (WaitForSingleObject(project->process.hProcess, 5000) != WAIT_OBJECT_0) {
    TerminateProcess(project->process.hProcess, 1);
    WaitForSingleObject(project->process.hProcess, 1000);
  }
  CloseHandle(project->process.hThread);
  CloseHandle(project->process.hProcess);
  ZeroMemory(&project->process, sizeof(project->process));
}

static bool write_probe_state(
  const char *path,
  const ProbeProject *a,
  const ProbeProject *b,
  char active
) {
  if (!path || !path[0] || !a || !b) return false;
  FILE *file = fopen(path, "wb");
  if (!file) return false;
  fprintf(file,
    "manager_pid=%lu\n"
    "child_a_pid=%lu\n"
    "child_b_pid=%lu\n"
    "hwnd_a=%llu\n"
    "hwnd_b=%llu\n"
    "active=%c\n",
    (unsigned long)GetCurrentProcessId(),
    (unsigned long)a->process.dwProcessId,
    (unsigned long)b->process.dwProcessId,
    (unsigned long long)(uintptr_t)a->hwnd,
    (unsigned long long)(uintptr_t)b->hwnd,
    active);
  bool ok = fclose(file) == 0;
  return ok;
}

static bool focus_project_window(HWND hwnd) {
  if (!hwnd) return false;
  if (GetForegroundWindow() == hwnd) return true;

  HWND foreground = GetForegroundWindow();
  DWORD target_thread = GetWindowThreadProcessId(hwnd, NULL);
  DWORD foreground_thread = foreground ? GetWindowThreadProcessId(foreground, NULL) : 0;
  DWORD current_thread = GetCurrentThreadId();
  bool attached_foreground = false;
  bool attached_target = false;

  if (foreground_thread && foreground_thread != current_thread) {
    attached_foreground = AttachThreadInput(current_thread, foreground_thread, TRUE) != FALSE;
  }
  if (target_thread && target_thread != current_thread) {
    attached_target = AttachThreadInput(current_thread, target_thread, TRUE) != FALSE;
  }

  BringWindowToTop(hwnd);
  SetForegroundWindow(hwnd);
  SetFocus(hwnd);

  if (attached_target) AttachThreadInput(current_thread, target_thread, FALSE);
  if (attached_foreground) AttachThreadInput(current_thread, foreground_thread, FALSE);
  return GetForegroundWindow() == hwnd;
}

static bool set_hidden_window_bounds_stable(HWND hwnd, const RECT *bounds, DWORD timeout_ms) {
  if (!hwnd || !bounds) return false;
  int width = bounds->right - bounds->left;
  int height = bounds->bottom - bounds->top;
  DWORD start = GetTickCount();
  int stable_reads = 0;
  while (GetTickCount() - start < timeout_ms) {
    if (!SetWindowPos(hwnd, NULL,
                      bounds->left, bounds->top, width, height,
                      SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED)) {
      return false;
    }
    Sleep(20);
    RECT actual;
    if (GetWindowRect(hwnd, &actual) &&
        actual.left == bounds->left && actual.top == bounds->top &&
        actual.right == bounds->right && actual.bottom == bounds->bottom) {
      stable_reads++;
      if (stable_reads >= 3) return true;
    } else {
      stable_reads = 0;
    }
  }
  return false;
}

static bool wait_for_project_focus(ProbeProject *project, DWORD timeout_ms) {
  DWORD start = GetTickCount();
  while (GetTickCount() - start < timeout_ms) {
    intptr_t ready = 0;
    if (send_handoff_message(project->hwnd, ANVIL_HANDOFF_FOCUS_READY, 0, &ready) && ready) {
      return true;
    }
    focus_project_window(project->hwnd);
    Sleep(10);
  }
  return false;
}

static bool switch_project(ProbeProject **active, ProbeProject **inactive) {
  ProbeProject *old_project = *active;
  ProbeProject *target_project = *inactive;
  RECT bounds;
  if (!GetWindowRect(old_project->hwnd, &bounds)) {
    fprintf(stderr, "Handoff could not read the selected Project placement.\n");
    return false;
  }
  int width = bounds.right - bounds.left;
  int height = bounds.bottom - bounds.top;
  bool was_maximized = IsZoomed(old_project->hwnd) != FALSE;
  RECT original_target_bounds;
  WINDOWPLACEMENT target_placement;
  target_placement.length = sizeof(target_placement);
  if (!GetWindowRect(target_project->hwnd, &original_target_bounds) ||
      !GetWindowPlacement(target_project->hwnd, &target_placement)) {
    fprintf(stderr, "Handoff could not read the target Project placement.\n");
    return false;
  }
  int workspace_offset_x = original_target_bounds.left - target_placement.rcNormalPosition.left;
  int workspace_offset_y = original_target_bounds.top - target_placement.rcNormalPosition.top;
  ShowWindow(target_project->hwnd, SW_HIDE);
  LONG_PTR target_style = GetWindowLongPtrW(target_project->hwnd, GWL_STYLE);
  target_style &= ~(WS_MAXIMIZE | WS_MINIMIZE);
  SetWindowLongPtrW(target_project->hwnd, GWL_STYLE, target_style);
  if (!set_hidden_window_bounds_stable(target_project->hwnd, &bounds, 1500)) {
    fprintf(stderr, "Handoff target Project placement did not settle while hidden.\n");
    return false;
  }
  target_placement.flags = 0;
  target_placement.showCmd = SW_HIDE;
  target_placement.rcNormalPosition.left = bounds.left - workspace_offset_x;
  target_placement.rcNormalPosition.top = bounds.top - workspace_offset_y;
  target_placement.rcNormalPosition.right = target_placement.rcNormalPosition.left + width;
  target_placement.rcNormalPosition.bottom = target_placement.rcNormalPosition.top + height;
  if (!SetWindowPlacement(target_project->hwnd, &target_placement)) {
    fprintf(stderr, "Handoff could not set the target Project restore placement.\n");
    return false;
  }
  LONG generation = window_frame_generation(target_project->hwnd);
  if (!send_handoff_message(target_project->hwnd, ANVIL_HANDOFF_PREPARE, 0, NULL) ||
      !wait_for_frame_after(target_project->hwnd, generation, ANVIL_HANDOFF_FRAME_TIMEOUT_MS)) {
    fprintf(stderr, "Handoff target Project did not prepare a frame.\n");
    return false;
  }

  if (!send_handoff_message(old_project->hwnd, ANVIL_HANDOFF_DEACTIVATE, 0, NULL)) {
    fprintf(stderr, "Handoff could not deactivate the old Project.\n");
    return false;
  }

  int show_command = was_maximized ? SW_MAXIMIZE : SW_SHOWNORMAL;
  AllowSetForegroundWindow(target_project->process.dwProcessId);
  if (!send_handoff_message(target_project->hwnd, ANVIL_HANDOFF_ACTIVATE, show_command, NULL)) {
    fprintf(stderr, "Handoff could not activate the target Project.\n");
    return false;
  }
  if (!SetWindowPos(target_project->hwnd, HWND_TOP,
                    bounds.left, bounds.top, width, height,
                    SWP_NOACTIVATE)) {
    fprintf(stderr, "Handoff could not finalize the target Project placement.\n");
    return false;
  }
  if (was_maximized) {
    if (!send_handoff_message(target_project->hwnd, ANVIL_HANDOFF_ACTIVATE, SW_MAXIMIZE, NULL) ||
        !SetWindowPos(target_project->hwnd, HWND_TOP,
                      bounds.left, bounds.top, width, height,
                      SWP_NOACTIVATE)) {
      fprintf(stderr, "Handoff could not finalize the target Project maximized mode.\n");
      return false;
    }
  }
  focus_project_window(target_project->hwnd);
  if (!wait_for_project_focus(target_project, 2000)) {
    fprintf(stderr, "Handoff target Project did not receive SDL keyboard focus.\n");
    return false;
  }
  *active = target_project;
  *inactive = old_project;
  return true;
}

static bool read_pipe_command(HANDLE pipe, char *command, DWORD size) {
  DWORD used = 0;
  while (used + 1 < size) {
    char ch = 0;
    DWORD got = 0;
    if (!ReadFile(pipe, &ch, 1, &got, NULL) || got != 1) return false;
    if (ch == '\n' || ch == '\r') break;
    command[used++] = ch;
  }
  command[used] = '\0';
  return used > 0;
}

static void write_pipe_reply(HANDLE pipe, const char *reply) {
  DWORD written = 0;
  WriteFile(pipe, reply, (DWORD)strlen(reply), &written, NULL);
  FlushFileBuffers(pipe);
}

static int run_probe_server(
  const char *state_path,
  ProbeProject *project_a,
  ProbeProject *project_b
) {
  char pipe_name[128];
  snprintf(pipe_name, sizeof(pipe_name), "\\\\.\\pipe\\AnvilWindowHandoffProbe-%lu",
           (unsigned long)GetCurrentProcessId());

  ProbeProject *active = project_a;
  ProbeProject *inactive = project_b;
  if (!write_probe_state(state_path, project_a, project_b, active->name)) return 1;

  bool running = true;
  int result = 0;
  while (running) {
    HANDLE pipe = CreateNamedPipeA(
      pipe_name,
      PIPE_ACCESS_DUPLEX,
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
      1,
      1024,
      1024,
      0,
      NULL
    );
    if (pipe == INVALID_HANDLE_VALUE) return 1;

    BOOL connected = ConnectNamedPipe(pipe, NULL) ? TRUE : GetLastError() == ERROR_PIPE_CONNECTED;
    char command[ANVIL_HANDOFF_MAX_COMMAND] = {0};
    if (!connected || !read_pipe_command(pipe, command, sizeof(command))) {
      write_pipe_reply(pipe, "ERROR invalid-command\n");
    } else if (strcmp(command, "switch") == 0) {
      if (switch_project(&active, &inactive)) {
        write_probe_state(state_path, project_a, project_b, active->name);
        char reply[64];
        snprintf(reply, sizeof(reply), "OK active=%c\n", active->name);
        write_pipe_reply(pipe, reply);
      } else {
        write_pipe_reply(pipe, "ERROR switch-failed\n");
        result = 1;
      }
    } else if (strcmp(command, "stop") == 0) {
      write_pipe_reply(pipe, "OK stopping\n");
      running = false;
    } else if (strcmp(command, "status") == 0) {
      char reply[64];
      snprintf(reply, sizeof(reply), "OK active=%c\n", active->name);
      write_pipe_reply(pipe, reply);
    } else {
      write_pipe_reply(pipe, "ERROR unknown-command\n");
    }

    DisconnectNamedPipe(pipe);
    CloseHandle(pipe);
    if (result != 0) running = false;
  }
  return result;
}

int anvil_window_handoff_run_probe_manager(int argc, char **argv) {
  if (argc < 2 || strcmp(argv[1], "--window-handoff-probe-manager") != 0) return -1;
  if (argc != 4) {
    fprintf(stderr, "Usage: anvil --window-handoff-probe-manager <project-a> <project-b>\n");
    return 1;
  }

  const char *state_path = getenv("ANVIL_WINDOW_HANDOFF_PROBE_STATE_FILE");
  const char *base_user_utf8 = getenv("ANVIL_USERDIR");
  if (!state_path || !state_path[0] || !base_user_utf8 || !base_user_utf8[0]) {
    fprintf(stderr, "The handoff probe needs ANVIL_USERDIR and ANVIL_WINDOW_HANDOFF_PROBE_STATE_FILE.\n");
    return 1;
  }

  wchar_t exe[32768];
  wchar_t project_a_path[32768];
  wchar_t project_b_path[32768];
  wchar_t base_user_dir[32768];
  DWORD exe_length = GetModuleFileNameW(NULL, exe, (DWORD)(sizeof(exe) / sizeof(exe[0])));
  if (!exe_length || exe_length >= (DWORD)(sizeof(exe) / sizeof(exe[0])) ||
      !utf8_to_wide(argv[2], project_a_path, (int)(sizeof(project_a_path) / sizeof(project_a_path[0]))) ||
      !utf8_to_wide(argv[3], project_b_path, (int)(sizeof(project_b_path) / sizeof(project_b_path[0]))) ||
      !utf8_to_wide(base_user_utf8, base_user_dir, (int)(sizeof(base_user_dir) / sizeof(base_user_dir[0])))) {
    return 1;
  }

  HANDLE job = create_child_job();
  ProbeProject project_a;
  ProbeProject project_b;
  ZeroMemory(&project_a, sizeof(project_a));
  ZeroMemory(&project_b, sizeof(project_b));
  int result = 1;

  if (!job ||
      !launch_project(exe, project_a_path, base_user_dir, 'a', true, job, &project_a) ||
      !launch_project(exe, project_b_path, base_user_dir, 'b', false, job, &project_b)) {
    fprintf(stderr, "Could not start both handoff probe Projects. Error=%lu.\n",
            (unsigned long)GetLastError());
    goto cleanup;
  }

  if (!wait_for_project_ready(&project_a, ANVIL_HANDOFF_START_TIMEOUT_MS) ||
      !wait_for_project_ready(&project_b, ANVIL_HANDOFF_START_TIMEOUT_MS)) {
    goto cleanup;
  }

  if (!send_handoff_message(project_b.hwnd, ANVIL_HANDOFF_DEACTIVATE, 0, NULL) ||
      !send_handoff_message(project_a.hwnd, ANVIL_HANDOFF_ACTIVATE, SW_SHOWNORMAL, NULL)) {
    goto cleanup;
  }
  focus_project_window(project_a.hwnd);
  if (!wait_for_project_focus(&project_a, 2000)) goto cleanup;

  result = run_probe_server(state_path, &project_a, &project_b);

cleanup:
  stop_project(&project_a);
  stop_project(&project_b);
  if (job) CloseHandle(job);
  return result;
}

#else

void anvil_window_handoff_init_child(void) {}
bool anvil_window_handoff_is_probe_child(void) { return false; }
bool anvil_window_handoff_project_is_selected(void) { return true; }
bool anvil_window_handoff_allow_show(SDL_Window *window) { (void)window; return true; }
void anvil_window_handoff_register_window(SDL_Window *window) { (void)window; }
void anvil_window_handoff_frame_presented(SDL_Window *window) { (void)window; }
bool anvil_window_handoff_handle_message(
  void *native_window,
  unsigned int message,
  uintptr_t wparam,
  intptr_t lparam,
  intptr_t *result
) {
  (void)native_window;
  (void)message;
  (void)wparam;
  (void)lparam;
  (void)result;
  return false;
}
int anvil_window_handoff_run_probe_manager(int argc, char **argv) {
  (void)argc;
  (void)argv;
  return -1;
}

#endif
