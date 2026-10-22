#include "surface_protocol.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include "shell_launch.h"
#endif

static char log_role[16];

static const char *dialog_option_keys[] = {
    SDL_PROP_FILE_DIALOG_TITLE_STRING,
    SDL_PROP_FILE_DIALOG_LOCATION_STRING,
    SDL_PROP_FILE_DIALOG_ACCEPT_STRING,
    SDL_PROP_FILE_DIALOG_CANCEL_STRING,
};

static bool append_dialog_string(char *packet, uint32_t *size, const char *value) {
  if (!value)
    value = "";
  size_t length = SDL_strnlen(value, ANVIL_SURFACE_MAX_PAYLOAD);
  if (length >= ANVIL_SURFACE_MAX_PAYLOAD - *size)
    return false;
#ifdef _WIN32
  if (length && !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, (int)length, NULL, 0))
    return false;
#endif
  memcpy(packet + *size, value, length + 1);
  *size += (uint32_t)length + 1;
  return true;
}

static const char *read_dialog_string(const char **cursor, const char *end) {
  const char *text = *cursor;
  const char *terminator = memchr(text, 0, (size_t)(end - text));
  if (!terminator)
    return NULL;
#ifdef _WIN32
  if (terminator != text &&
      !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, (int)(terminator - text), NULL, 0))
    return NULL;
#endif
  *cursor = terminator + 1;
  return text;
}

void *anvil_surface_dialog_encode(uint32_t id, SDL_FileDialogType type, SDL_PropertiesID props,
                                  uint32_t *size) {
  Sint64 count = SDL_GetNumberProperty(props, SDL_PROP_FILE_DIALOG_NFILTERS_NUMBER, 0);
  SDL_DialogFileFilter *filters =
      SDL_GetPointerProperty(props, SDL_PROP_FILE_DIALOG_FILTERS_POINTER, NULL);
  if (!id || id > INT32_MAX || type < SDL_FILEDIALOG_OPENFILE || type > SDL_FILEDIALOG_OPENFOLDER ||
      count < 0 || count > ANVIL_SURFACE_DIALOG_FILTER_LIMIT || (count && !filters))
    return NULL;
  char *packet = malloc(ANVIL_SURFACE_MAX_PAYLOAD);
  if (!packet)
    return NULL;
  *(AnvilSurfaceDialog *)packet =
      (AnvilSurfaceDialog){id, type, (uint32_t)count,
                           SDL_GetBooleanProperty(props, SDL_PROP_FILE_DIALOG_MANY_BOOLEAN, false)};
  *size = sizeof(AnvilSurfaceDialog);
  for (size_t i = 0; i < SDL_arraysize(dialog_option_keys); i++) {
    if (!append_dialog_string(packet, size,
                              SDL_GetStringProperty(props, dialog_option_keys[i], NULL)))
      goto invalid;
  }
  for (Sint64 i = 0; i < count; i++) {
    if (!filters[i].name || !filters[i].pattern ||
        !append_dialog_string(packet, size, filters[i].name) ||
        !append_dialog_string(packet, size, filters[i].pattern))
      goto invalid;
  }
  return packet;
invalid:
  free(packet);
  return NULL;
}

SDL_PropertiesID
anvil_surface_dialog_decode(const void *packet, uint32_t size,
                            SDL_DialogFileFilter filters[ANVIL_SURFACE_DIALOG_FILTER_LIMIT]) {
  if (size < sizeof(AnvilSurfaceDialog) || size > ANVIL_SURFACE_MAX_PAYLOAD)
    return 0;
  const AnvilSurfaceDialog *request = packet;
  if (!request->id || request->id > INT32_MAX || request->type > SDL_FILEDIALOG_OPENFOLDER ||
      request->filters > ANVIL_SURFACE_DIALOG_FILTER_LIMIT || request->many > 1)
    return 0;
  const char *cursor = (const char *)packet + sizeof(*request), *end = (const char *)packet + size;
  const char *options[4];
  for (size_t i = 0; i < SDL_arraysize(options); i++) {
    if (!(options[i] = read_dialog_string(&cursor, end)))
      return 0;
  }
  for (uint32_t i = 0; i < request->filters; i++) {
    filters[i].name = read_dialog_string(&cursor, end);
    filters[i].pattern = read_dialog_string(&cursor, end);
    if (!filters[i].name || !filters[i].pattern || !*filters[i].pattern)
      return 0;
  }
  if (cursor != end)
    return 0;
  SDL_PropertiesID props = SDL_CreateProperties();
  if (!props)
    return 0;
  bool ok = SDL_SetPointerProperty(props, SDL_PROP_FILE_DIALOG_FILTERS_POINTER,
                                   request->filters ? filters : NULL) &&
            SDL_SetNumberProperty(props, SDL_PROP_FILE_DIALOG_NFILTERS_NUMBER, request->filters) &&
            SDL_SetBooleanProperty(props, SDL_PROP_FILE_DIALOG_MANY_BOOLEAN, request->many != 0);
  for (size_t i = 0; i < SDL_arraysize(options); i++) {
    if (*options[i])
      ok = SDL_SetStringProperty(props, dialog_option_keys[i], options[i]) && ok;
  }
  if (ok)
    return props;
  SDL_DestroyProperties(props);
  return 0;
}

void *anvil_surface_dialog_result(uint32_t id, const char *const *paths, int filter,
                                  uint32_t *size) {
  char *packet = malloc(ANVIL_SURFACE_MAX_PAYLOAD);
  if (!packet)
    return NULL;
  AnvilSurfaceDialogResult *result = (AnvilSurfaceDialogResult *)packet;
  *result = (AnvilSurfaceDialogResult){
      id,
      paths ? (*paths ? ANVIL_SURFACE_DIALOG_ACCEPT : ANVIL_SURFACE_DIALOG_CANCEL)
            : ANVIL_SURFACE_DIALOG_ERROR,
      filter};
  *size = sizeof(*result);
  if (!paths) {
    if (!append_dialog_string(packet, size, SDL_GetError()))
      goto oversized;
  } else if (*paths) {
    size_t count = 0;
    while (*paths) {
      if (++count > ANVIL_SURFACE_DIALOG_PATH_LIMIT || !**paths ||
          !append_dialog_string(packet, size, *paths++))
        goto oversized;
    }
    if (!append_dialog_string(packet, size, ""))
      goto oversized;
  }
  return packet;
oversized:
  result->status = ANVIL_SURFACE_DIALOG_ERROR;
  result->filter = -1;
  *size = sizeof(*result);
  append_dialog_string(packet, size, "The file dialog result exceeds its limit");
  return packet;
}

/* Pane ids such as "pane-3" use letters, digits, '-' and '_'. */
bool anvil_surface_pane_action_valid(const AnvilSurfacePaneAction *action) {
  if (action->action != ANVIL_SURFACE_PANE_FOCUS && action->action != ANVIL_SURFACE_PANE_CLOSE) return false;
  size_t length = strnlen(action->pane, sizeof(action->pane));
  return length && length < sizeof(action->pane) &&
         strspn(action->pane, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_") == length;
}

bool anvil_surface_dialog_result_valid(const void *packet, uint32_t size) {
  if (size < sizeof(AnvilSurfaceDialogResult) || size > ANVIL_SURFACE_MAX_PAYLOAD)
    return false;
  const AnvilSurfaceDialogResult *result = packet;
  if (!result->id || result->id > INT32_MAX || result->filter < -1 ||
      result->filter >= ANVIL_SURFACE_DIALOG_FILTER_LIMIT)
    return false;
  const char *cursor = (const char *)packet + sizeof(*result), *end = (const char *)packet + size;
  if (result->status == ANVIL_SURFACE_DIALOG_CANCEL)
    return cursor == end;
  if (result->status == ANVIL_SURFACE_DIALOG_ERROR)
    return read_dialog_string(&cursor, end) && cursor == end;
  if (result->status != ANVIL_SURFACE_DIALOG_ACCEPT)
    return false;
  size_t count = 0;
  const char *path;
  while ((path = read_dialog_string(&cursor, end))) {
    if (!*path)
      return count > 0 && cursor == end;
    if (++count > ANVIL_SURFACE_DIALOG_PATH_LIMIT)
      return false;
  }
  return false;
}

bool anvil_surface_layout_changed(const AnvilSurfaceConfigure *previous, const AnvilSurfaceConfigure *next) {
  return previous->window_id != next->window_id || previous->origin_x != next->origin_x ||
    previous->origin_y != next->origin_y ||
    previous->pixel_w != next->pixel_w || previous->pixel_h != next->pixel_h ||
    previous->display_scale != next->display_scale || previous->button_width != next->button_width ||
    previous->title_height != next->title_height || previous->resize_border != next->resize_border ||
    previous->controls_x != next->controls_x || previous->controls_y != next->controls_y ||
    previous->controls_w != next->controls_w || previous->controls_h != next->controls_h ||
    previous->content_x != next->content_x;
}

bool anvil_surface_frame_matches(const AnvilSurfaceConfigure *config, const AnvilSurfaceFrame *frame) {
  return frame->configuration == config->configuration && frame->width == config->pixel_w && frame->height == config->pixel_h &&
    (frame->kind == ANVIL_SURFACE_FRAME_D3D11 || frame->kind == ANVIL_SURFACE_FRAME_SHARED_MEMORY) &&
    frame->name[0] && memchr(frame->name, 0, sizeof(frame->name));
}

bool anvil_surface_text_area(const AnvilSurfaceConfigure *config, const AnvilSurfaceTextInput *input, SDL_Rect *area, int *cursor) {
  if (input->configuration != config->configuration || input->w <= 0 || input->h <= 0) return false;
  /* Use 64-bit sums before clipping untrusted coordinates. */
  int64_t right = (int64_t)input->x + input->w;
  int64_t bottom = (int64_t)input->y + input->h;
  int x = SDL_clamp(input->x, 0, config->pixel_w - 1);
  int y = SDL_clamp(input->y, 0, config->pixel_h - 1);
  int w = (int)SDL_clamp(right - x, 1, config->pixel_w - x);
  int h = (int)SDL_clamp(bottom - y, 1, config->pixel_h - y);
  *area = (SDL_Rect){config->origin_x + x, config->origin_y + y, w, h};
  *cursor = (int)SDL_clamp((int64_t)input->x + input->cursor - x, 0, w);
  return true;
}

void anvil_surface_translate_input(const AnvilSurfaceConfigure *config, SDL_Event *event) {
  switch (event->type) {
    case SDL_EVENT_MOUSE_MOTION:
      event->motion.x -= config->origin_x;
      event->motion.y -= config->origin_y;
      break;
    case SDL_EVENT_MOUSE_BUTTON_DOWN:
    case SDL_EVENT_MOUSE_BUTTON_UP:
      event->button.x -= config->origin_x;
      event->button.y -= config->origin_y;
      break;
    case SDL_EVENT_MOUSE_WHEEL:
      event->wheel.mouse_x -= config->origin_x;
      event->wheel.mouse_y -= config->origin_y;
      break;
    case SDL_EVENT_DROP_POSITION:
    case SDL_EVENT_DROP_FILE:
    case SDL_EVENT_DROP_TEXT:
      event->drop.x -= config->origin_x;
      event->drop.y -= config->origin_y;
      break;
    default:
      break;
  }
}

#ifdef _WIN32
static struct {
  HANDLE file;
  SRWLOCK lock;
  wchar_t path[32768], previous[32768];
  uint64_t bytes;
  bool owned;
} native_log = {.file = INVALID_HANDLE_VALUE, .lock = SRWLOCK_INIT};

static HANDLE open_native_log(void) {
  /* Keep active default logs out of the session log cleaner's deletions. */
  return CreateFileW(native_log.path, FILE_APPEND_DATA,
    FILE_SHARE_READ | FILE_SHARE_WRITE | (native_log.owned ? 0 : FILE_SHARE_DELETE),
    NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
}

static bool default_native_log(void) {
  wchar_t userdir[32768], directory[32768];
  char utf8[32768 * 4];
  if (!anvil_shell_user_directory(userdir, SDL_arraysize(userdir)) ||
      _snwprintf(directory, SDL_arraysize(directory), L"%ls\\logs", userdir) < 0 ||
      !WideCharToMultiByte(CP_UTF8, 0, directory, -1, utf8, sizeof(utf8), NULL, NULL) ||
      !SDL_CreateDirectory(utf8)) return false;
  SYSTEMTIME now;
  GetLocalTime(&now);
  /* The existing session log cleaner recognizes this name and its rotated part. */
  if (_snwprintf(native_log.path, SDL_arraysize(native_log.path),
      L"%ls\\anvil-%04u%02u%02u-%02u%02u%02u-p%lu-native.log", directory,
      now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond,
      (unsigned long)GetCurrentProcessId()) < 0) return false;
  size_t length = wcslen(native_log.path);
  return _snwprintf(native_log.previous, SDL_arraysize(native_log.previous), L"%.*ls-part02.log",
                   (int)(length - 4), native_log.path) > 0;
}
#endif

static void SDLCALL write_surface_log(void *userdata, int category, SDL_LogPriority priority,
                                      const char *message) {
  (void)category;
  (void)priority;
#ifdef _WIN32
  (void)userdata;
  char line[4096];
  SYSTEMTIME now;
  GetLocalTime(&now);
  int length;
  if (native_log.owned) {
    length = SDL_snprintf(line, sizeof(line),
      "%04u-%02u-%02u %02u:%02u:%02u.%03u %10.3f %s[%lu] thread=%lu priority=%d %s\n",
      now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond, now.wMilliseconds,
      (double)SDL_GetTicksNS() / 1e9, log_role, (unsigned long)GetCurrentProcessId(),
      (unsigned long)GetCurrentThreadId(), (int)priority, message);
  } else {
    /* Keep the shared probe log's format and append behavior. */
    length = SDL_snprintf(line, sizeof(line), "%10.3f %s[%lu] %s\n", (double)SDL_GetTicksNS() / 1e9,
      log_role, (unsigned long)GetCurrentProcessId(), message);
  }
  DWORD size = (DWORD)SDL_min(length, (int)sizeof(line) - 1);
  line[size - 1] = '\n';
  AcquireSRWLockExclusive(&native_log.lock);
  /* Bound each process to the current part and one previous part. */
  if (native_log.owned && native_log.bytes + size > 10 * 1024 * 1024) {
    CloseHandle(native_log.file);
    if (MoveFileExW(native_log.path, native_log.previous, MOVEFILE_REPLACE_EXISTING))
      native_log.bytes = 0;
    native_log.file = open_native_log();
  }
  DWORD written;
  /* One append-only write keeps concurrent process diagnostics separate. */
  if (WriteFile(native_log.file, line, size, &written, NULL)) native_log.bytes += written;
  else OutputDebugStringA(line);
  ReleaseSRWLockExclusive(&native_log.lock);
#else
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
#endif
}

void anvil_surface_log_init(const char *role) {
  const char *path = SDL_getenv("ANVIL_SURFACE_LOG");
#ifdef _WIN32
  if (native_log.file != INVALID_HANDLE_VALUE) return;
  native_log.owned = !path || !path[0];
  if (native_log.owned ? !default_native_log() :
      !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, native_log.path,
                          SDL_arraysize(native_log.path))) {
    SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Cannot resolve the native diagnostic log path: %s", SDL_GetError());
    return;
  }
  native_log.file = open_native_log();
  if (native_log.file == INVALID_HANDLE_VALUE) {
    SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Cannot open the native diagnostic log: Windows error %lu",
                 (unsigned long)GetLastError());
    return;
  }
  LARGE_INTEGER size;
  if (GetFileSizeEx(native_log.file, &size)) native_log.bytes = size.QuadPart;
  SDL_strlcpy(log_role, role, sizeof(log_role));
  SDL_SetLogOutputFunction(write_surface_log, NULL);
  if (native_log.owned) SDL_Log("Native diagnostics started");
#else
  if (!path || !path[0]) return;
  SDL_strlcpy(log_role, role, sizeof(log_role));
  SDL_SetLogOutputFunction(write_surface_log, SDL_strdup(path));
#endif
}
