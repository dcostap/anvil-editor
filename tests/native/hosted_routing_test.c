#include <SDL3/SDL.h>
#include <stdio.h>
#include "hosted_surface.h"
#include "system_events.h"

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); return 1; } } while (0)

/* These callbacks belong to the app loop, not the transport being tested. */
void anvil_set_live_resize(bool value) { (void)value; }
void anvil_request_resize_frame_for_window(SDL_Window *window, const char *reason) { (void)window; (void)reason; }

static HANDLE ready, sent, finish;
static AnvilIPCPipe pipe;
static AnvilSurfaceConfigure config;
static SDL_AtomicInt frame_checked;
static SDL_AtomicInt motions_written;
static bool motion_stall;
static bool dialogs;
static SDL_AtomicInt dialogs_checked;
static struct { int status, filter, count; char paths[2][128]; } dialog_results[3];
static void SDLCALL dialog_result(void *userdata, const char *const *paths, int filter) {
  int index = (int)(intptr_t)userdata;
  dialog_results[index].status = !paths ? 3 : !*paths ? 2 : 1;
  dialog_results[index].filter = filter;
  if (paths) for (int i = 0; paths[i] && i < 2; i++) {
    SDL_strlcpy(dialog_results[index].paths[i], paths[i], sizeof(dialog_results[index].paths[i]));
    dialog_results[index].count++;
  }
}

static int SDLCALL server(void *data) {
  (void)data;
  OVERLAPPED connect = {0};
  connect.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
  DWORD error = ConnectNamedPipe(pipe.handle, &connect) ? 0 : GetLastError();
  if (error == ERROR_IO_PENDING) {
    DWORD count;
    WaitForSingleObject(connect.hEvent, 5000);
    GetOverlappedResult(pipe.handle, &connect, &count, TRUE);
  }
  CloseHandle(connect.hEvent);
  AnvilIPCHeader header;
  unsigned char bytes[ANVIL_SURFACE_MAX_PAYLOAD];
  if (!anvil_ipc_pipe_read(&pipe, &header, bytes, sizeof(bytes))) return 1;
  if (!anvil_ipc_pipe_write(&pipe, ANVIL_SURFACE_MSG_CONFIGURE, &config, sizeof(config), NULL, 0)) return 1;
  WaitForSingleObject(ready, 5000);
  AnvilSurfaceInt focus = {1};
  anvil_ipc_pipe_write(&pipe, ANVIL_SURFACE_MSG_FOCUS, &focus, sizeof(focus), NULL, 0);
  if (dialogs) {
    for (int i = 0; i < 3; i++) {
      do {
        if (!anvil_ipc_pipe_read(&pipe, &header, bytes, sizeof(bytes))) return 1;
      } while (header.type != ANVIL_SURFACE_MSG_DIALOG);
      SDL_DialogFileFilter filters[ANVIL_SURFACE_DIALOG_FILTER_LIMIT];
      SDL_PropertiesID props = anvil_surface_dialog_decode(bytes, header.size, filters);
      if (!props || ((AnvilSurfaceDialog *)bytes)->id != (uint32_t)(41 + i) ||
          ((AnvilSurfaceDialog *)bytes)->type != (uint32_t)i ||
          strcmp(SDL_GetStringProperty(props, SDL_PROP_FILE_DIALOG_TITLE_STRING, ""), "选择 files") ||
          strcmp(filters[1].pattern, "lua") || !SDL_GetBooleanProperty(props, SDL_PROP_FILE_DIALOG_MANY_BOOLEAN, false)) return 1;
      SDL_DestroyProperties(props);
      const char *accepted[] = {"C:/中/a.txt", "C:/b λ.lua", NULL};
      const char *cancelled[] = {NULL};
      uint32_t size;
      SDL_SetError("Owned native dialog failed");
      void *result = anvil_surface_dialog_result(41 + i, i == 0 ? accepted : i == 1 ? cancelled : NULL, i == 0 ? 1 : -1, &size);
      if (!result || !anvil_surface_dialog_result_valid(result, size)) return 1;
      if (i == 0 && anvil_surface_dialog_result_valid(result, size - 1)) return 1;
      if (!anvil_ipc_pipe_write(&pipe, ANVIL_SURFACE_MSG_DIALOG_RESULT, result, size, NULL, 0)) return 1;
      free(result);
    }
    SDL_SetAtomicInt(&dialogs_checked, 1);
    SetEvent(sent);
    WaitForSingleObject(finish, 5000);
    return 0;
  }
  if (motion_stall) {
    AnvilSurfaceInput motion = {.configuration = config.configuration};
    motion.event.type = SDL_EVENT_MOUSE_MOTION;
    motion.event.motion.xrel = 1;
    for (int i = 1; i <= 100001; i++) {
      motion.event.motion.x = (float)i;
      motion.event.motion.y = (float)-i;
      if (!anvil_ipc_pipe_write(&pipe, ANVIL_SURFACE_MSG_INPUT, &motion, sizeof(motion), NULL, 0)) break;
      SDL_SetAtomicInt(&motions_written, i);
    }
    motion.event.type = SDL_EVENT_TEXT_INPUT;
    motion.text_len = 4;
    anvil_ipc_pipe_write(&pipe, ANVIL_SURFACE_MSG_INPUT, &motion, sizeof(motion), "done", 4);
    SetEvent(sent);
    WaitForSingleObject(finish, 5000);
    return 0;
  }
  const Uint32 types[] = {SDL_EVENT_TEXT_EDITING, SDL_EVENT_TEXT_INPUT, SDL_EVENT_DROP_TEXT};
  for (unsigned i = 0; i < SDL_arraysize(types); i++) {
    AnvilSurfaceInput input = {0};
    input.configuration = config.configuration;
    input.event.type = types[i];
    input.event.edit.start = 1;
    input.event.edit.length = 2;
    const char *text = "first\r\n\r\nlast\r\n";
    input.text_len = (uint32_t)SDL_strlen(text);
    anvil_ipc_pipe_write(&pipe, ANVIL_SURFACE_MSG_INPUT, &input, sizeof(input), text, input.text_len);
  }
  AnvilSurfaceConfigure old = config;
  config.configuration++;
  config.display_scale = 1.5f;
  config.origin_x = 48;
  config.origin_y = 24;
  anvil_ipc_pipe_write(&pipe, ANVIL_SURFACE_MSG_CONFIGURE, &config, sizeof(config), NULL, 0);
  AnvilSurfaceInput input = {.configuration = old.configuration};
  input.event.type = SDL_EVENT_TEXT_INPUT;
  input.text_len = 5;
  anvil_ipc_pipe_write(&pipe, ANVIL_SURFACE_MSG_INPUT, &input, sizeof(input), "stale", 5);
  const char *unicode = "中λ🙂";
  input.configuration = config.configuration;
  input.text_len = (uint32_t)SDL_strlen(unicode);
  anvil_ipc_pipe_write(&pipe, ANVIL_SURFACE_MSG_INPUT, &input, sizeof(input), unicode, input.text_len);
  anvil_ipc_pipe_write(&pipe, ANVIL_SURFACE_MSG_CONFIGURE, &old, sizeof(old), NULL, 0);
  SetEvent(sent);
  while (anvil_ipc_pipe_read(&pipe, &header, bytes, sizeof(bytes))) {
    if (header.type != ANVIL_SURFACE_MSG_FRAME) continue;
    AnvilSurfaceFrame *frame = (AnvilSurfaceFrame *)bytes;
    SDL_SetAtomicInt(&frame_checked, frame->configuration == config.configuration &&
      frame->width == 320 && frame->height == 240 ? 1 : -1);
    break;
  }
  WaitForSingleObject(finish, 5000);
  return 0;
}

int main(int test_argc, char **test_argv) {
  motion_stall = test_argc > 1 && !strcmp(test_argv[1], "motion");
  dialogs = test_argc > 1 && !strcmp(test_argv[1], "dialogs");
  AnvilSurfaceConfigure geometry = {.configuration = 7, .origin_x = 48, .origin_y = 24,
    .pixel_w = 320, .pixel_h = 240, .display_scale = 1.25f};
  AnvilSurfaceConfigure moved = geometry;
  moved.window_x = 180;
  moved.window_y = -70;
  moved.refresh_hz = 144;
  moved.window_mode = ANVIL_SURFACE_WINDOW_MAXIMIZED;
  CHECK(!anvil_surface_layout_changed(&geometry, &moved));
  moved.pixel_w++;
  CHECK(anvil_surface_layout_changed(&geometry, &moved));
  AnvilSurfaceFrame frame = {.configuration = 6, .kind = ANVIL_SURFACE_FRAME_D3D11,
    .width = 320, .height = 240, .name = "owned-surface"};
  CHECK(!anvil_surface_frame_matches(&geometry, &frame));
  frame.configuration = 7;
  CHECK(anvil_surface_frame_matches(&geometry, &frame));
  AnvilSurfaceTextInput area_input = {.active = -1, .x = -10, .y = 230, .w = 30, .h = 40, .cursor = 25, .configuration = 7};
  SDL_Rect area;
  int cursor;
  CHECK(anvil_surface_text_area(&geometry, &area_input, &area, &cursor));
  CHECK(area.x == 48 && area.y == 254 && area.w == 20 && area.h == 10);
  CHECK(cursor == 15);
  area_input.configuration = 6;
  CHECK(!anvil_surface_text_area(&geometry, &area_input, &area, &cursor));
  const Uint32 pointer_types[] = {SDL_EVENT_MOUSE_MOTION, SDL_EVENT_MOUSE_BUTTON_DOWN,
    SDL_EVENT_MOUSE_BUTTON_UP, SDL_EVENT_MOUSE_WHEEL, SDL_EVENT_DROP_TEXT};
  for (unsigned i = 0; i < SDL_arraysize(pointer_types); i++) {
    SDL_Event point = {0};
    point.type = pointer_types[i];
    if (point.type == SDL_EVENT_MOUSE_MOTION) { point.motion.x = 78.5f; point.motion.y = 64.25f; }
    else if (point.type == SDL_EVENT_MOUSE_WHEEL) { point.wheel.mouse_x = 78.5f; point.wheel.mouse_y = 64.25f; }
    else if (point.type == SDL_EVENT_DROP_TEXT) { point.drop.x = 78.5f; point.drop.y = 64.25f; }
    else { point.button.x = 78.5f; point.button.y = 64.25f; }
    anvil_surface_translate_input(&geometry, &point);
    float x = point.type == SDL_EVENT_MOUSE_MOTION ? point.motion.x : point.type == SDL_EVENT_MOUSE_WHEEL ? point.wheel.mouse_x
            : point.type == SDL_EVENT_DROP_TEXT ? point.drop.x : point.button.x;
    float y = point.type == SDL_EVENT_MOUSE_MOTION ? point.motion.y : point.type == SDL_EVENT_MOUSE_WHEEL ? point.wheel.mouse_y
            : point.type == SDL_EVENT_DROP_TEXT ? point.drop.y : point.button.y;
    CHECK(x == 30.5f && y == 40.25f);
  }
  CHECK(SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS));
  if (dialogs) {
    SDL_PropertiesID props = SDL_CreateProperties();
    SDL_SetStringProperty(props, SDL_PROP_FILE_DIALOG_TITLE_STRING, "title");
    uint32_t size;
    void *packet = anvil_surface_dialog_encode(1, SDL_FILEDIALOG_OPENFILE, props, &size);
    CHECK(packet);
    SDL_DialogFileFilter filters[ANVIL_SURFACE_DIALOG_FILTER_LIMIT];
    CHECK(!anvil_surface_dialog_decode(packet, size - 1, filters));
    ((char *)packet)[sizeof(AnvilSurfaceDialog)] = (char)0xff;
    CHECK(!anvil_surface_dialog_decode(packet, size, filters));
    free(packet);
    SDL_SetNumberProperty(props, SDL_PROP_FILE_DIALOG_NFILTERS_NUMBER, ANVIL_SURFACE_DIALOG_FILTER_LIMIT + 1);
    CHECK(!anvil_surface_dialog_encode(1, SDL_FILEDIALOG_OPENFILE, props, &size));
    SDL_DestroyProperties(props);
  }
  ready = CreateEventW(NULL, TRUE, FALSE, NULL);
  sent = CreateEventW(NULL, TRUE, FALSE, NULL);
  finish = CreateEventW(NULL, TRUE, FALSE, NULL);
  char name[128];
  SDL_snprintf(name, sizeof(name), "\\\\.\\pipe\\anvil-surface-%lu-routing", GetCurrentProcessId());
  HANDLE handle = CreateNamedPipeA(name, PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
    PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_REJECT_REMOTE_CLIENTS, 1, 65536, 65536, 0, NULL);
  CHECK(handle != INVALID_HANDLE_VALUE);
  CHECK(anvil_ipc_pipe_init(&pipe, handle, ANVIL_SURFACE_PROTOCOL_VERSION, ANVIL_SURFACE_MAX_PAYLOAD));
  config = (AnvilSurfaceConfigure){.configuration = 7, .pixel_w = 320, .pixel_h = 240, .window_w = 400, .window_h = 300,
    .render_enabled = 1, .display_scale = 1.25f, .controls_x = 182, .controls_w = 138, .controls_h = 32};
  SDL_Thread *thread = SDL_CreateThread(server, "test-shell", NULL);
  CHECK(thread);
  char argument[256];
  SDL_snprintf(argument, sizeof(argument), "%s%s", ANVIL_SURFACE_PIPE_ARG, name);
  char *argv[] = {"anvil", "--project", ".", argument, NULL};
  int argc = 4;
  CHECK(anvil_hosted_surface_parse_args(&argc, argv));
  CHECK(anvil_hosted_surface_connect());
  SDL_Window *window = SDL_CreateWindow("owned render window", 320, 240, SDL_WINDOW_HIDDEN);
  CHECK(window);
  anvil_hosted_surface_register_window(window);
  SDL_Event event;
  while (SDL_PollEvent(&event)) {}
  if (dialogs) {
    SDL_PropertiesID props = SDL_CreateProperties();
    SDL_DialogFileFilter filters[] = {{"Text files", "txt"}, {"Lua files", "lua"}};
    SDL_SetPointerProperty(props, SDL_PROP_FILE_DIALOG_FILTERS_POINTER, filters);
    SDL_SetNumberProperty(props, SDL_PROP_FILE_DIALOG_NFILTERS_NUMBER, 2);
    SDL_SetStringProperty(props, SDL_PROP_FILE_DIALOG_TITLE_STRING, "选择 files");
    SDL_SetStringProperty(props, SDL_PROP_FILE_DIALOG_LOCATION_STRING, "C:/中");
    SDL_SetBooleanProperty(props, SDL_PROP_FILE_DIALOG_MANY_BOOLEAN, true);
    for (int i = 0; i < 3; i++) CHECK(anvil_hosted_surface_show_dialog(41 + i, i, props, dialog_result, (void *)(intptr_t)i));
    SDL_DestroyProperties(props);
  }
  SetEvent(ready);
  CHECK(WaitForSingleObject(sent, 5000) == WAIT_OBJECT_0);
  SDL_Delay(50);
  if (dialogs) {
    CHECK(SDL_GetAtomicInt(&dialogs_checked) == 1);
    Uint64 deadline = SDL_GetTicks() + 2000;
    while (!dialog_results[2].status && SDL_GetTicks() < deadline) {
      while (SDL_PollEvent(&event)) {
        CHECK(!anvil_hosted_surface_loss_event(event.type));
        if (!anvil_hosted_surface_dispatch(&event)) system_push_event(&event);
      }
      anvil_hosted_surface_poll();
      system_event_pop(&event);
    }
    CHECK(dialog_results[0].status == 1 && dialog_results[0].filter == 1 && dialog_results[0].count == 2);
    CHECK(!strcmp(dialog_results[0].paths[0], "C:/中/a.txt") && !strcmp(dialog_results[0].paths[1], "C:/b λ.lua"));
    CHECK(dialog_results[1].status == 2 && dialog_results[1].count == 0);
    CHECK(dialog_results[2].status == 3);
    CHECK(!strcmp(SDL_GetError(), "Owned native dialog failed"));
    anvil_hosted_surface_exit_intent(NULL);
    SetEvent(finish);
    SDL_WaitThread(thread, NULL);
    puts("PASS asynchronous native dialog requests, complete paths, filter, cancel, and failure");
    return 0;
  }
  if (motion_stall) {
    CHECK(SDL_GetAtomicInt(&motions_written) == 100001);
    bool final_position = false, barrier = false;
    Uint64 deadline = SDL_GetTicks() + 2000;
    while (!barrier && SDL_GetTicks() < deadline) {
      while (SDL_PollEvent(&event)) {
        CHECK(!anvil_hosted_surface_loss_event(event.type));
        if (!anvil_hosted_surface_dispatch(&event)) system_push_event(&event);
      }
      anvil_hosted_surface_poll();
      if (system_event_pop(&event)) {
        if (event.type == SDL_EVENT_MOUSE_MOTION) {
          final_position = event.motion.x == 100001 && event.motion.y == -100001 && event.motion.xrel == 100001;
        }
        if (event.type == SDL_EVENT_TEXT_INPUT) barrier = !strcmp(event.text.text, "done");
      } else SDL_Delay(1);
    }
    CHECK(final_position && barrier);
    anvil_hosted_surface_exit_intent(NULL);
    SetEvent(finish);
    SDL_WaitThread(thread, NULL);
    puts("PASS stalled UI retains 100001 motion packets and the final position");
    return 0;
  }
  /* Worker receipt must not change the UI state ahead of queued events. */
  CHECK(!anvil_hosted_surface_has_focus());
  while (SDL_PollEvent(&event)) {
    if (!anvil_hosted_surface_dispatch(&event)) system_push_event(&event);
  }
  CHECK(anvil_hosted_surface_has_focus());
  CHECK(anvil_hosted_surface_display_scale() == 1.25f);
  unsigned text_count = 0;
  for (;;) {
    anvil_hosted_surface_poll();
    if (!system_event_pop(&event)) break;
    const char *text = event.type == SDL_EVENT_TEXT_INPUT ? event.text.text
                     : event.type == SDL_EVENT_TEXT_EDITING ? event.edit.text
                     : event.type == SDL_EVENT_DROP_TEXT ? event.drop.data : NULL;
    if (text) {
      CHECK(anvil_hosted_surface_display_scale() == (text_count == 3 ? 1.5f : 1.25f));
      CHECK(SDL_strcmp(text, text_count == 3 ? "中λ🙂" : "first\r\n\r\nlast\r\n") == 0);
      if (event.type == SDL_EVENT_TEXT_EDITING) CHECK(event.edit.start == 1 && event.edit.length == 2);
      text_count++;
    }
  }
  CHECK(text_count == 4);
  CHECK(anvil_hosted_surface_display_scale() == 1.5f);
  SDL_Surface *surface = SDL_CreateSurface(320, 240, SDL_PIXELFORMAT_BGRA32);
  CHECK(surface);
  CHECK(anvil_hosted_surface_publish_software(window, surface, NULL, 0));
  Uint64 deadline = SDL_GetTicks() + 2000;
  while (!SDL_GetAtomicInt(&frame_checked) && SDL_GetTicks() < deadline) SDL_Delay(1);
  CHECK(SDL_GetAtomicInt(&frame_checked) == 1);
  SDL_DestroySurface(surface);
  anvil_hosted_surface_exit_intent(NULL);
  SetEvent(finish);
  SDL_WaitThread(thread, NULL);
  puts("PASS ordered native focus and complete UTF-8 input payloads");
  return 0;
}
