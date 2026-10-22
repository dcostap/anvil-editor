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
  anvil_sidebar_set_runtime(&model, a, 1, 10, 3, ANVIL_SIDEBAR_READY, false, true, false);
  anvil_sidebar_set_runtime(&model, b, 2, 20, 4, ANVIL_SIDEBAR_CLOSING, true, false, true);
  CHECK(a->deferred_dialog && !a->selected && b->selected && b->close_choice &&
            b->state == ANVIL_SIDEBAR_CLOSING,
        "Project choices or selection are missing from the model");
  anvil_sidebar_set_runtime(&model, b, 2, 20, 4, ANVIL_SIDEBAR_FAILED, true, false, false);
  CHECK(b->state == ANVIL_SIDEBAR_FAILED && !b->close_choice, "Failure retained a Close choice");
  anvil_sidebar_set_runtime(&model, b, 2, 0, 0, ANVIL_SIDEBAR_DORMANT, false, false, false);
  anvil_sidebar_set_runtime(&model, a, 1, 0, 0, ANVIL_SIDEBAR_DORMANT, false, false, false);
  CHECK(model.count == 3 && a->pid == 0 && b->pid == 0 && a->state == ANVIL_SIDEBAR_DORMANT &&
            b->state == ANVIL_SIDEBAR_DORMANT &&
            anvil_sidebar_at(&model, 2)->state == ANVIL_SIDEBAR_DORMANT,
        "The model lost a Dormant Project");
  anvil_sidebar_set_runtime(&model, b, 2, 30, 4, ANVIL_SIDEBAR_STARTING, true, false, false);
  anvil_sidebar_set_runtime(&model, b, 2, 30, 4, ANVIL_SIDEBAR_READY, true, false, false);
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
  anvil_sidebar_set_runtime(&model, live, 7, 0, 3, ANVIL_SIDEBAR_STARTING, false, false, false);
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
/* The Sidebar shows the Pane report a Project sends, unchanged. */
static void panes(void) {
  AnvilSidebarModel model = {0};
  const char *paths[] = {"C:/B"};
  CHECK(anvil_sidebar_merge_recents(&model, paths, 1), "Recent source failed");
  AnvilSidebarProject *b = anvil_sidebar_find(&model, "C:/B");
  uint32_t revision = model.revision;
  const char *report = "{active=1,{id=\"pane-1\",group=1,name=\"init \\\"λ\\\".lua\"}}";
  CHECK(anvil_sidebar_set_panes(&model, b, report) && model.revision != revision,
        "A Pane report did not publish a revision");
  revision = model.revision;
  CHECK(anvil_sidebar_set_panes(&model, b, report) && model.revision == revision,
        "An unchanged Pane report published a revision");
  char *page = anvil_sidebar_snapshot(&model, 0);
  CHECK(page, "Snapshot failed");
  lua_State *L = luaL_newstate();
  CHECK(L && !luaL_loadbuffer(L, page, strlen(page), "=Sidebar page") && !lua_pcall(L, 0, 1, 0),
        "Invalid snapshot encoding");
  free(page);
  lua_getfield(L, 1, "items");
  lua_rawgeti(L, -1, 1);
  lua_getfield(L, -1, "panes");
  CHECK(lua_isstring(L, -1) && !strcmp(lua_tostring(L, -1), report), "The snapshot changed the Pane report");
  lua_close(L);
  /* A report that cannot fit one snapshot page leaves the last one. */
  char *oversized = malloc(ANVIL_SIDEBAR_PANES_QUOTED_LIMIT / 4 + 2);
  CHECK(oversized, "Allocation failed");
  memset(oversized, '"', ANVIL_SIDEBAR_PANES_QUOTED_LIMIT / 4 + 1);
  oversized[ANVIL_SIDEBAR_PANES_QUOTED_LIMIT / 4 + 1] = 0;
  CHECK(!anvil_sidebar_set_panes(&model, b, oversized) && !strcmp(b->panes, report) && model.revision == revision,
        "An oversized Pane report replaced the last one");
  free(oversized);
  CHECK(anvil_sidebar_set_panes(&model, b, "") && model.revision != revision && !b->panes,
        "Clearing the Pane report did not publish");
  anvil_sidebar_destroy(&model);
}
static void agent_status(void) {
  AnvilSidebarModel model = {0};
  const char *paths[] = {"C:/B"};
  CHECK(anvil_sidebar_merge_recents(&model, paths, 1), "Recent source failed");
  AnvilSidebarProject *b = anvil_sidebar_find(&model, "C:/B");
  AnvilSidebarTerminal session = {.id = "0123456789abcdef0123456789abcdef", .title = "pi", .cwd = "C:/B",
                                  .busy = 1, .bell = -1};
  CHECK(anvil_sidebar_set_terminals(&model, b, &session, 1), "Terminal source failed");
  uint32_t revision = model.revision;
  snprintf(session.agent.state, sizeof(session.agent.state), "working");
  snprintf(session.agent.app, sizeof(session.agent.app), "pi");
  snprintf(session.agent.model, sizeof(session.agent.model), "GPT Test");
  snprintf(session.agent.step, sizeof(session.agent.step), "bash: npm \"test\"");
  session.agent.since = 100;
  session.agent.step_since = 120;
  CHECK(anvil_sidebar_set_terminals(&model, b, &session, 1) && model.revision != revision,
        "A new agent step did not publish a revision");
  char *page = anvil_sidebar_snapshot(&model, 0);
  CHECK(page, "Snapshot failed");
  lua_State *L = luaL_newstate();
  CHECK(L && !luaL_loadbuffer(L, page, strlen(page), "=Sidebar page") && !lua_pcall(L, 0, 1, 0),
        "Invalid snapshot encoding");
  free(page);
  lua_getfield(L, 1, "items");
  lua_rawgeti(L, -1, 2);
  lua_getfield(L, -1, "agent_state");
  lua_getfield(L, -2, "agent_step");
  lua_getfield(L, -3, "agent_step_since");
  CHECK(!strcmp(lua_tostring(L, -3), "working") && !strcmp(lua_tostring(L, -2), "bash: npm \"test\"") &&
            lua_tonumber(L, -1) == 120,
        "The snapshot changed the agent status");
  lua_getfield(L, -4, "agent_app");
  CHECK(lua_isstring(L, -1) && !strcmp(lua_tostring(L, -1), "pi"), "The snapshot lost the program identity");
  lua_getfield(L, -5, "agent_model");
  CHECK(lua_isstring(L, -1) && !strcmp(lua_tostring(L, -1), "GPT Test"), "The snapshot lost the selected model");
  lua_close(L);
  revision = model.revision;
  snprintf(session.agent.model, sizeof(session.agent.model), "Claude Test");
  CHECK(anvil_sidebar_set_terminals(&model, b, &session, 1) && model.revision != revision,
        "Changing only the selected model did not publish a revision");
  anvil_sidebar_destroy(&model);
}
static void trailing_separator(void) {
  AnvilSidebarModel model = {0};
  const char *paths[] = {"C:\\Projects\\GLP4", "C:\\"};
  CHECK(anvil_sidebar_merge_recents(&model, paths, 2), "Recent source failed");
  AnvilSidebarProject *project = anvil_sidebar_find(&model, "C:\\Projects\\GLP4");
  CHECK(anvil_sidebar_find(&model, "C:\\Projects\\GLP4\\") == project &&
            anvil_sidebar_find(&model, "C:/Projects/GLP4/") == project,
        "A trailing separator named another Project");
  const char *restarted[] = {"C:\\Projects\\GLP4\\"};
  CHECK(anvil_sidebar_merge_recents(&model, restarted, 1) && model.count == 2,
        "A trailing separator duplicated a Project");
  CHECK(anvil_sidebar_find(&model, "C:\\") && !anvil_sidebar_find(&model, "C:"),
        "A drive root matched its drive-relative path");
  anvil_sidebar_destroy(&model);
}
int main(void) {
  trailing_separator();
  panes();
  agent_status();
  order();
  capacity();
  lifecycle();
  terminals();
  pages();
  return 0;
}
