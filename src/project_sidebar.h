#ifndef ANVIL_PROJECT_SIDEBAR_H
#define ANVIL_PROJECT_SIDEBAR_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <wchar.h>

#define ANVIL_SIDEBAR_PROJECT_LIMIT 256
#define ANVIL_SIDEBAR_TERMINAL_LIMIT 32
#define ANVIL_SIDEBAR_WINDOW_LIMIT 64
/* The largest Pane report after snapshot quoting. */
#define ANVIL_SIDEBAR_PANES_QUOTED_LIMIT (32 * 1024)

typedef struct { uint32_t id, selected_project; } AnvilSidebarWindow;

typedef enum {
  ANVIL_SIDEBAR_DORMANT,
  ANVIL_SIDEBAR_STARTING,
  ANVIL_SIDEBAR_READY,
  ANVIL_SIDEBAR_CLOSING,
  ANVIL_SIDEBAR_FAILED
} AnvilSidebarState;
/* The longest agent status text, in bytes. */
#define ANVIL_SIDEBAR_AGENT_TEXT_MAX 256
/* An agent's program status from its Terminal Session record: the state that the agent reports and the step that
 * Anvil's Pi extension reports. An empty state or step means none. Times are Unix seconds. */
typedef struct {
  char state[8], kind[16], app[32];
  char message[ANVIL_SIDEBAR_AGENT_TEXT_MAX + 1], step[ANVIL_SIDEBAR_AGENT_TEXT_MAX + 1];
  int64_t since, step_since;
} AnvilSidebarAgent;
typedef struct {
  char id[33];
  char *title, *cwd;
  uint32_t host_pid;
  int busy; /* -1 means unknown. */
  int bell; /* -1 means unavailable. */
  bool attached;
  /* The last time the user typed into it, or a command started or ended, or its title changed. Unix seconds; 0 means
   * unknown. */
  int64_t activity;
  int64_t command_started, command_finished;
  int command_exit;
  AnvilSidebarAgent agent;
  enum {
    ANVIL_SIDEBAR_TERMINAL_RUNNING,
    ANVIL_SIDEBAR_TERMINAL_EXITED,
    ANVIL_SIDEBAR_TERMINAL_LOST
  } state;
} AnvilSidebarTerminal;
typedef struct {
  char *path;
  wchar_t *identity;
  uint32_t row_id, id, pid, window_id;
  AnvilSidebarState state;
  bool exists, selected, deferred_dialog, close_choice;
  /* The last time the user worked in it, in Unix seconds; 0 means unknown. The shell sets and saves it. */
  int64_t activity;
  /* The Project's own Pane report: Lua table text, or empty while it has not reported. */
  char *panes;
  AnvilSidebarTerminal *terminals;
  size_t terminal_count;
} AnvilSidebarProject;
typedef struct {
  AnvilSidebarProject *projects[ANVIL_SIDEBAR_PROJECT_LIMIT];
  size_t count;
  bool seeded;
  uint32_t next_row;
  uint32_t revision;
  bool status_limited;
  AnvilSidebarWindow windows[ANVIL_SIDEBAR_WINDOW_LIMIT];
  size_t window_count;
} AnvilSidebarModel;

/* Source order initializes the list. Later sources add new Projects first.
 * Selecting, loading, and unloading existing Projects never change order. */
bool anvil_sidebar_merge_recents(AnvilSidebarModel *model, const char *const *paths, size_t count);
AnvilSidebarProject *anvil_sidebar_find(const AnvilSidebarModel *model, const char *path);
const AnvilSidebarProject *anvil_sidebar_at(const AnvilSidebarModel *model, size_t index);
void anvil_sidebar_set_runtime(AnvilSidebarModel *model, AnvilSidebarProject *project, uint32_t id,
                               uint32_t pid, uint32_t window_id, AnvilSidebarState state, bool selected,
                               bool deferred_dialog, bool close_choice);
/* panes is the Project's Pane report, or empty. Returns false and keeps the old report when it cannot store
 * the new one, for example when it exceeds ANVIL_SIDEBAR_PANES_QUOTED_LIMIT after quoting. */
bool anvil_sidebar_set_panes(AnvilSidebarModel *model, AnvilSidebarProject *project, const char *panes);
bool anvil_sidebar_set_terminals(AnvilSidebarModel *model, AnvilSidebarProject *project,
                                 const AnvilSidebarTerminal *terminals, size_t count);
/* Pages contain Project records followed by their Terminal records. */
char *anvil_sidebar_snapshot(const AnvilSidebarModel *model, size_t offset);
bool anvil_sidebar_set_windows(AnvilSidebarModel *model, const AnvilSidebarWindow *windows, size_t count);
void anvil_sidebar_destroy(AnvilSidebarModel *model);
#endif
