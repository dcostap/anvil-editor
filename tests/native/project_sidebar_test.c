#include "project_sidebar.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>
#define CHECK(value, message)                                                                      \
  do {                                                                                             \
    if (!(value)) {                                                                                \
      fprintf(stderr, "%s\n", message);                                                            \
      exit(1);                                                                                     \
    }                                                                                              \
  } while (0)
static void order(void) {
  AnvilSidebarModel model = {0};
  const char *initial[] = {"C:/B", "C:/A"};
  CHECK(anvil_sidebar_merge_recents(&model, initial, 2),
        "Recent Projects did not initialize the list");
  CHECK(model.count == 2 && !strcmp(anvil_sidebar_at(&model, 0)->path, "C:/B") &&
            !strcmp(anvil_sidebar_at(&model, 1)->path, "C:/A"),
        "Initial recent order changed");
  const char *selected[] = {"C:/A", "C:/B"};
  CHECK(anvil_sidebar_merge_recents(&model, selected, 2), "Existing recent source failed");
  CHECK(!strcmp(anvil_sidebar_at(&model, 0)->path, "C:/B"),
        "Selecting an existing Project changed order");
  const char *added[] = {"C:/D", "C:/C", "C:/A", "C:/B", "C:/D"};
  CHECK(anvil_sidebar_merge_recents(&model, added, 5), "New recent source failed");
  const char *expected[] = {"C:/D", "C:/C", "C:/B", "C:/A"};
  CHECK(model.count == 4, "Recent source duplicated a Project");
  for (size_t i = 0; i < 4; i++)
    CHECK(!strcmp(anvil_sidebar_at(&model, i)->path, expected[i]),
          "New Projects are not first in source order");
  anvil_sidebar_destroy(&model);
}
static void lifecycle(void) {
  AnvilSidebarModel model = {0};
  const char *paths[] = {"C:/B", "C:/A", "C:/Older"};
  CHECK(anvil_sidebar_merge_recents(&model, paths, 3), "Recent source failed");
  AnvilSidebarProject *b = anvil_sidebar_find(&model, "C:/B");
  AnvilSidebarProject *a = anvil_sidebar_find(&model, "C:/A");
  anvil_sidebar_set_runtime(&model, a, 1, 10, ANVIL_SIDEBAR_READY, false, true, false);
  anvil_sidebar_set_runtime(&model, b, 2, 20, ANVIL_SIDEBAR_CLOSING, true, false, true);
  CHECK(a->deferred_dialog && !a->selected && b->selected && b->close_choice &&
            b->state == ANVIL_SIDEBAR_CLOSING,
        "Project choices or selection are missing from the model");
  anvil_sidebar_set_runtime(&model, b, 2, 20, ANVIL_SIDEBAR_FAILED, true, false, false);
  CHECK(b->state == ANVIL_SIDEBAR_FAILED && !b->close_choice, "Failure retained a Close choice");
  anvil_sidebar_set_runtime(&model, b, 2, 0, ANVIL_SIDEBAR_DORMANT, false, false, false);
  anvil_sidebar_set_runtime(&model, a, 1, 0, ANVIL_SIDEBAR_DORMANT, false, false, false);
  CHECK(model.count == 3 && a->pid == 0 && b->pid == 0 && a->state == ANVIL_SIDEBAR_DORMANT &&
            b->state == ANVIL_SIDEBAR_DORMANT &&
            anvil_sidebar_at(&model, 2)->state == ANVIL_SIDEBAR_DORMANT,
        "The model lost a Dormant Project");
  anvil_sidebar_set_runtime(&model, b, 2, 30, ANVIL_SIDEBAR_STARTING, true, false, false);
  anvil_sidebar_set_runtime(&model, b, 2, 30, ANVIL_SIDEBAR_READY, true, false, false);
  CHECK(b->id == 2 && b->pid == 30 && b->state == ANVIL_SIDEBAR_READY &&
            !strcmp(anvil_sidebar_at(&model, 0)->path, "C:/B"),
        "Load changed identity or list order");
  anvil_sidebar_destroy(&model);
}
static void capacity(void) {
  AnvilSidebarModel model = {0};
  char names[260][32];
  const char *paths[260];
  for (size_t i = 0; i < 260; i++) {
    snprintf(names[i], sizeof(names[i]), "C:/Recent-%zu", i);
    paths[i] = names[i];
  }
  CHECK(anvil_sidebar_merge_recents(&model, paths, 260), "Large recent source was rejected");
  CHECK(model.count == 256 && anvil_sidebar_find(&model, paths[0]) &&
            anvil_sidebar_find(&model, paths[255]) && !anvil_sidebar_find(&model, paths[256]),
        "Large source did not keep its newest entries");
  AnvilSidebarProject *live = anvil_sidebar_find(&model, paths[255]);
  anvil_sidebar_set_runtime(&model, live, 7, 0, ANVIL_SIDEBAR_STARTING, false, false, false);
  const char *next = "C:/New";
  CHECK(anvil_sidebar_merge_recents(&model, &next, 1), "Full list refused a new Project");
  CHECK(anvil_sidebar_at(&model, 0) == anvil_sidebar_find(&model, next) &&
            anvil_sidebar_find(&model, paths[255]) == live &&
            !anvil_sidebar_find(&model, paths[254]) && model.count == 256,
        "Eviction lost a runtime or retained the oldest Dormant row");
  anvil_sidebar_destroy(&model);
}
static void terminals(void) {
  AnvilSidebarModel model = {0};
  const char *paths[] = {"C:/B"};
  CHECK(anvil_sidebar_merge_recents(&model, paths, 1), "Recent source failed");
  AnvilSidebarTerminal sessions[] = {{.id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                                      .title = "cmd",
                                      .cwd = "C:/B",
                                      .host_pid = 123,
                                      .busy = 1,
                                      .attached = true,
                                      .state = ANVIL_SIDEBAR_TERMINAL_RUNNING},
                                     {.id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                                      .title = "powershell",
                                      .cwd = "C:/B/sub",
                                      .busy = -1,
                                      .state = ANVIL_SIDEBAR_TERMINAL_LOST}};
  AnvilSidebarProject *b = anvil_sidebar_find(&model, "C:/B");
  CHECK(anvil_sidebar_set_terminals(&model, b, sessions, 2),
        "Terminal status did not enter the model");
  CHECK(b->terminal_count == 2 && b->terminals[0].busy == 1 && b->terminals[0].attached &&
            !strcmp(b->terminals[1].cwd, "C:/B/sub") &&
            b->terminals[1].state == ANVIL_SIDEBAR_TERMINAL_LOST,
        "Terminal status changed during publication");
  sessions[0].busy = 0;
  sessions[0].attached = false;
  CHECK(b->terminals[0].busy == 1, "The model borrowed worker status");
  CHECK(anvil_sidebar_set_terminals(&model, b, sessions, 2) && b->terminals[0].busy == 0 &&
            !b->terminals[0].attached,
        "Detached Terminal status did not update");
  CHECK(anvil_sidebar_set_terminals(&model, b, NULL, 0) && b->terminal_count == 0,
        "Removed Terminal stayed in the list");
  anvil_sidebar_destroy(&model);
}
static void pages(void) {
  AnvilSidebarModel model = {0};
  const char *paths[] = {"C:/B"};
  CHECK(anvil_sidebar_merge_recents(&model, paths, 1), "Recent source failed");
  AnvilSidebarProject *b = anvil_sidebar_find(&model, "C:/B");
  char cwd[4096];
  memset(cwd, 'x', sizeof(cwd) - 1);
  cwd[sizeof(cwd) - 1] = 0;
  AnvilSidebarTerminal sessions[32] = {0};
  for (size_t i = 0; i < 32; i++) {
    snprintf(sessions[i].id, sizeof(sessions[i].id), "%032zu", i);
    sessions[i].title = "cmd \"quoted\"\nλ";
    sessions[i].cwd = cwd;
    sessions[i].busy = 1;
    sessions[i].state = ANVIL_SIDEBAR_TERMINAL_RUNNING;
  }
  CHECK(anvil_sidebar_set_terminals(&model, b, sessions, 32), "Terminal source failed");
  lua_State *L = luaL_newstate();
  CHECK(L, "Cannot decode the public snapshot");
  size_t offset = 0, seen = 0, page_count = 0;
  do {
    char *page = anvil_sidebar_snapshot(&model, offset);
    CHECK(page, "The model cannot publish a bounded snapshot page");
    CHECK(strlen(page) + 1 <= 64 * 1024, "Snapshot exceeds the surface packet bound");
    lua_settop(L, 0);
    CHECK(!luaL_loadbuffer(L, page, strlen(page), "=Sidebar page") && !lua_pcall(L, 0, 1, 0),
          "Invalid snapshot encoding");
    free(page);
    lua_getfield(L, 1, "offset");
    CHECK(lua_tonumber(L, -1) == offset, "Snapshot resumed at the wrong record");
    lua_pop(L, 1);
    lua_getfield(L, 1, "total");
    CHECK(lua_tonumber(L, -1) == 33, "Snapshot omitted records");
    lua_pop(L, 1);
    lua_getfield(L, 1, "next");
    size_t next = (size_t)lua_tonumber(L, -1);
    lua_pop(L, 1);
    CHECK(next > offset && next <= 33, "Snapshot made no progress");
    lua_getfield(L, 1, "items");
    for (size_t i = 1; i <= next - offset; i++) {
      lua_rawgeti(L, -1, (int)i);
      if (seen) {
        lua_getfield(L, -1, "id");
        CHECK(!strcmp(lua_tostring(L, -1), sessions[seen - 1].id), "Page changed Terminal order");
        lua_pop(L, 1);
        lua_getfield(L, -1, "title");
        CHECK(!strcmp(lua_tostring(L, -1), "cmd \"quoted\"\nλ"), "Page changed quoted UTF-8 text");
        lua_pop(L, 1);
        lua_getfield(L, -1, "cwd");
        CHECK(!strcmp(lua_tostring(L, -1), cwd), "Page changed cwd");
        lua_pop(L, 1);
      }
      seen++;
      lua_pop(L, 1);
    }
    offset = next;
    page_count++;
  } while (offset < 33);
  CHECK(seen == 33 && page_count > 1, "Large model was not published in complete pages");
  lua_close(L);
  anvil_sidebar_destroy(&model);
}
int main(void) {
  order();
  capacity();
  lifecycle();
  terminals();
  pages();
  return 0;
}
