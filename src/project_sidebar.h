#ifndef ANVIL_PROJECT_SIDEBAR_H
#define ANVIL_PROJECT_SIDEBAR_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <wchar.h>

#define ANVIL_SIDEBAR_PROJECT_LIMIT 256
#define ANVIL_SIDEBAR_TERMINAL_LIMIT 32

typedef enum {
  ANVIL_SIDEBAR_DORMANT,
  ANVIL_SIDEBAR_STARTING,
  ANVIL_SIDEBAR_READY,
  ANVIL_SIDEBAR_CLOSING,
  ANVIL_SIDEBAR_FAILED
} AnvilSidebarState;
typedef struct {
  char id[33];
  char *title, *cwd;
  uint32_t host_pid;
  int busy; /* -1 means unknown. */
  int bell; /* -1 means unavailable. */
  bool attached;
  enum {
    ANVIL_SIDEBAR_TERMINAL_RUNNING,
    ANVIL_SIDEBAR_TERMINAL_EXITED,
    ANVIL_SIDEBAR_TERMINAL_LOST
  } state;
} AnvilSidebarTerminal;
typedef struct {
  char *path;
  wchar_t *identity;
  uint32_t row_id, id, pid;
  AnvilSidebarState state;
  bool exists, selected, deferred_dialog, close_choice;
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
} AnvilSidebarModel;

/* Source order initializes the list. Later sources add new Projects first.
 * Selecting, loading, and unloading existing Projects never change order. */
bool anvil_sidebar_merge_recents(AnvilSidebarModel *model, const char *const *paths, size_t count);
AnvilSidebarProject *anvil_sidebar_find(const AnvilSidebarModel *model, const char *path);
const AnvilSidebarProject *anvil_sidebar_at(const AnvilSidebarModel *model, size_t index);
void anvil_sidebar_set_runtime(AnvilSidebarModel *model, AnvilSidebarProject *project, uint32_t id,
                               uint32_t pid, AnvilSidebarState state, bool selected,
                               bool deferred_dialog, bool close_choice);
bool anvil_sidebar_set_terminals(AnvilSidebarModel *model, AnvilSidebarProject *project,
                                 const AnvilSidebarTerminal *terminals, size_t count);
/* Pages contain Project records followed by their Terminal records. */
char *anvil_sidebar_snapshot(const AnvilSidebarModel *model, size_t offset);
void anvil_sidebar_destroy(AnvilSidebarModel *model);
#endif
