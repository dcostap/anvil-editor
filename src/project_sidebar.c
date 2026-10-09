#include "project_sidebar.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#ifdef _WIN32
#include <windows.h>
#endif

static wchar_t *identity(const char *path) {
#ifdef _WIN32
  int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
  wchar_t *value = count > 0 ? malloc(count * sizeof(*value)) : NULL;
  if (value)
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, value, count);
  return value;
#else
  size_t count = strlen(path) + 1;
  wchar_t *value = malloc(count * sizeof(*value));
  if (value)
    for (size_t i = 0; i < count; i++)
      value[i] = (unsigned char)path[i];
  return value;
#endif
}
static bool equal(const wchar_t *a, const wchar_t *b) {
#ifdef _WIN32
  return CompareStringOrdinal(a, -1, b, -1, TRUE) == CSTR_EQUAL;
#else
  return !wcscmp(a, b);
#endif
}
AnvilSidebarProject *anvil_sidebar_find(const AnvilSidebarModel *model, const char *path) {
  wchar_t *key = identity(path);
  if (!key)
    return NULL;
  AnvilSidebarProject *found = NULL;
  for (size_t i = 0; i < model->count; i++)
    if (equal(model->projects[i]->identity, key)) {
      found = model->projects[i];
      break;
    }
  free(key);
  return found;
}
const AnvilSidebarProject *anvil_sidebar_at(const AnvilSidebarModel *model, size_t index) {
  return index < model->count ? model->projects[index] : NULL;
}
static void free_terminals(AnvilSidebarProject *project) {
  for (size_t i = 0; i < project->terminal_count; i++) {
    free(project->terminals[i].title);
    free(project->terminals[i].cwd);
  }
  free(project->terminals);
  project->terminals = NULL;
  project->terminal_count = 0;
}
static void free_project(AnvilSidebarProject *project) {
  free_terminals(project);
  free(project->path);
  free(project->identity);
  free(project);
}
bool anvil_sidebar_merge_recents(AnvilSidebarModel *model, const char *const *paths, size_t count) {
  if (count > ANVIL_SIDEBAR_PROJECT_LIMIT)
    count = ANVIL_SIDEBAR_PROJECT_LIMIT;
  AnvilSidebarModel pending = *model;
  AnvilSidebarProject *created_rows[ANVIL_SIDEBAR_PROJECT_LIMIT];
  AnvilSidebarProject *removed[ANVIL_SIDEBAR_PROJECT_LIMIT];
  size_t created_count = 0, removed_count = 0;
  AnvilSidebarProject *front[ANVIL_SIDEBAR_PROJECT_LIMIT];
  size_t front_count = 0;
  for (size_t i = 0; i < count; i++) {
    if (!paths[i] || !*paths[i] || strlen(paths[i]) >= 32768)
      goto failed;
    AnvilSidebarProject *row = anvil_sidebar_find(&pending, paths[i]);
    bool created = !row;
    if (created) {
      if (pending.count == ANVIL_SIDEBAR_PROJECT_LIMIT) {
        size_t victim = pending.count;
        while (victim) {
          AnvilSidebarProject *old = pending.projects[--victim];
          bool in_source = false;
          for (size_t j = 0; j < front_count; j++)
            in_source |= front[j] == old;
          if (old->state == ANVIL_SIDEBAR_DORMANT && !old->pid && !old->selected && !in_source)
            break;
        }
        AnvilSidebarProject *old = pending.projects[victim];
        bool protected = old->state != ANVIL_SIDEBAR_DORMANT || old->pid || old->selected;
        for (size_t j = 0; j < front_count; j++)
          protected |= front[j] == old;
        if (protected)
          goto failed;
        removed[removed_count++] = old;
        memmove(pending.projects + victim, pending.projects + victim + 1,
                (--pending.count - victim) * sizeof(*pending.projects));
      }
      row = calloc(1, sizeof(*row));
      if (!row)
        goto failed;
      row->path = strdup(paths[i]);
      row->identity = identity(paths[i]);
      if (!row->path || !row->identity) {
        free_project(row);
        goto failed;
      }
      row->state = ANVIL_SIDEBAR_DORMANT;
      row->row_id = ++pending.next_row;
      pending.projects[pending.count++] = row;
      created_rows[created_count++] = row;
    }
    bool included = false;
    for (size_t j = 0; j < front_count; j++)
      included |= front[j] == row;
    if (!included && (!model->seeded || created))
      front[front_count++] = row;
  }
  for (size_t i = 0; i < pending.count; i++) {
    bool included = false;
    for (size_t j = 0; j < front_count; j++)
      included |= front[j] == pending.projects[i];
    if (!included)
      front[front_count++] = pending.projects[i];
  }
  if (model->count != pending.count || memcmp(model->projects, front, front_count * sizeof(*front)))
    pending.revision++;
  memcpy(pending.projects, front, front_count * sizeof(*front));
  pending.seeded = true;
  *model = pending;
  for (size_t i = 0; i < removed_count; i++)
    free_project(removed[i]);
  return true;
failed:
  for (size_t i = 0; i < created_count; i++)
    free_project(created_rows[i]);
  return false;
}
void anvil_sidebar_set_runtime(AnvilSidebarModel *model, AnvilSidebarProject *project, uint32_t id,
                               uint32_t pid, AnvilSidebarState state, bool selected,
                               bool deferred_dialog, bool close_choice) {
  if (project->id != id || project->pid != pid || project->state != state ||
      project->selected != selected || project->deferred_dialog != deferred_dialog ||
      project->close_choice != close_choice)
    model->revision++;
  project->id = id;
  project->pid = pid;
  project->state = state;
  project->selected = selected;
  project->deferred_dialog = deferred_dialog;
  project->close_choice = close_choice;
}
void anvil_sidebar_destroy(AnvilSidebarModel *model) {
  for (size_t i = 0; i < model->count; i++)
    free_project(model->projects[i]);
  *model = (AnvilSidebarModel){0};
}
bool anvil_sidebar_set_terminals(AnvilSidebarModel *model, AnvilSidebarProject *project,
                                 const AnvilSidebarTerminal *terminals, size_t count) {
  if (count > ANVIL_SIDEBAR_TERMINAL_LIMIT)
    return false;
  bool changed = count != project->terminal_count;
  for (size_t i = 0; !changed && i < count; i++) {
    const AnvilSidebarTerminal *a = &project->terminals[i], *b = &terminals[i];
    changed = strcmp(a->id, b->id) || strcmp(a->title, b->title ? b->title : "") ||
              strcmp(a->cwd, b->cwd ? b->cwd : "") || a->busy != b->busy || a->bell != b->bell ||
              a->state != b->state || a->attached != b->attached || a->host_pid != b->host_pid;
  }
  if (!changed)
    return true;
  AnvilSidebarProject copy = {0};
  copy.terminals = count ? calloc(count, sizeof(*copy.terminals)) : NULL;
  if (count && !copy.terminals)
    return false;
  copy.terminal_count = count;
  for (size_t i = 0; i < count; i++) {
    copy.terminals[i] = terminals[i];
    copy.terminals[i].title = strdup(terminals[i].title ? terminals[i].title : "");
    copy.terminals[i].cwd = strdup(terminals[i].cwd ? terminals[i].cwd : "");
    if (!copy.terminals[i].title || !copy.terminals[i].cwd) {
      free_terminals(&copy);
      return false;
    }
  }
  free_terminals(project);
  project->terminals = copy.terminals;
  project->terminal_count = count;
  model->revision++;
  return true;
}

typedef struct {
  char *text;
  size_t used;
  bool failed;
} SidebarText;
#define SIDEBAR_PAGE_BYTES 60000
static void append(SidebarText *text, const char *format, ...) {
  if (text->failed)
    return;
  va_list args;
  va_start(args, format);
  int size = vsnprintf(text->text + text->used, SIDEBAR_PAGE_BYTES - text->used, format, args);
  va_end(args);
  if (size < 0 || (size_t)size >= SIDEBAR_PAGE_BYTES - text->used)
    text->failed = true;
  else
    text->used += size;
}
static void quoted(SidebarText *text, const char *value) {
  append(text, "\"");
  for (const unsigned char *p = (const unsigned char *)value; *p; p++) {
    if (*p < 32 || *p == '\\' || *p == '"')
      append(text, "\\%03u", *p);
    else
      append(text, "%c", *p);
  }
  append(text, "\"");
}
char *anvil_sidebar_snapshot(const AnvilSidebarModel *model, size_t offset) {
  const char *states[] = {"dormant", "starting", "ready", "closing", "failed"};
  const char *terminal_states[] = {"running", "exited", "lost"};
  SidebarText body = {.text = malloc(SIDEBAR_PAGE_BYTES)};
  SidebarText item = {.text = malloc(SIDEBAR_PAGE_BYTES)};
  if (!body.text || !item.text) {
    free(body.text);
    free(item.text);
    return NULL;
  }
  body.text[0] = 0;
  size_t index = 0, next = offset, total = 0;
  for (size_t i = 0; i < model->count; i++)
    total += 1 + model->projects[i]->terminal_count;
  if (offset > total)
    goto failed;
  for (size_t i = 0; i < model->count; i++) {
    const AnvilSidebarProject *row = model->projects[i];
    for (size_t j = 0; j <= row->terminal_count; j++, index++) {
      if (index < offset)
        continue;
      item.used = 0;
      item.failed = false;
      if (!j) {
        append(&item,
               "{kind=\"project\",row_id=%u,id=%u,pid=%u,state=\"%s\",selected=%s,exists=%s,"
               "deferred_dialog=%s,close_choice=%s,path=",
               row->row_id, row->id, row->pid, states[row->state], row->selected ? "true" : "false",
               row->exists ? "true" : "false", row->deferred_dialog ? "true" : "false",
               row->close_choice ? "true" : "false");
        quoted(&item, row->path);
        append(&item, "},");
      } else {
        const AnvilSidebarTerminal *terminal = &row->terminals[j - 1];
        append(&item,
               "{kind=\"terminal\",row_id=%u,id=\"%s\",host_pid=%u,state=\"%s\",busy=%d,bell=%d,"
               "attached=%s,title=",
               row->row_id, terminal->id, terminal->host_pid, terminal_states[terminal->state],
               terminal->busy, terminal->bell, terminal->attached ? "true" : "false");
        quoted(&item, terminal->title);
        append(&item, ",cwd=");
        quoted(&item, terminal->cwd);
        append(&item, "},");
      }
      if (item.failed)
        goto failed;
      /* Leave room for the page header and terminator. Never split a record. */
      if (body.used + item.used + 256 >= SIDEBAR_PAGE_BYTES)
        goto finished;
      append(&body, "%s", item.text);
      next = index + 1;
    }
  }
finished:
  if (next == offset && offset < total)
    goto failed;
  char *result = malloc(body.used + 256);
  if (result)
    snprintf(result, body.used + 256,
             "return {revision=%u,offset=%zu,next=%zu,total=%zu,status_limited=%s,items={%s}}",
             model->revision, offset, next, total, model->status_limited ? "true" : "false",
             body.text);
  free(body.text);
  free(item.text);
  return result;
failed:
  free(body.text);
  free(item.text);
  return NULL;
}
