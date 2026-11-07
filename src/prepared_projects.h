#ifndef ANVIL_PREPARED_PROJECTS_H
#define ANVIL_PREPARED_PROJECTS_H

#include <stdbool.h>
#include <stdint.h>

#define ANVIL_PREPARED_PROJECT_LIMIT 4
#define ANVIL_PREPARED_SHELL 1u
#define ANVIL_PREPARED_PI 2u
#define ANVIL_PREPARED_ALL (ANVIL_PREPARED_SHELL | ANVIL_PREPARED_PI)

/* The shell visits only eligible Projects. Both spare types share this list.
 * Eligibility belongs to the loaded Project, not to its place in the list. */
typedef struct {
  uint32_t ids[ANVIL_PREPARED_PROJECT_LIMIT];
} AnvilPreparedProjects;

static inline bool anvil_prepared_projects_contains(const AnvilPreparedProjects *projects, uint32_t id) {
  if (!id) return false;
  for (unsigned i = 0; i < ANVIL_PREPARED_PROJECT_LIMIT; i++)
    if (projects->ids[i] == id) return true;
  return false;
}

static inline void anvil_prepared_projects_remove(AnvilPreparedProjects *projects, uint32_t id) {
  for (unsigned i = 0; i < ANVIL_PREPARED_PROJECT_LIMIT; i++) {
    if (projects->ids[i] != id) continue;
    for (unsigned j = i + 1; j < ANVIL_PREPARED_PROJECT_LIMIT; j++) projects->ids[j - 1] = projects->ids[j];
    projects->ids[ANVIL_PREPARED_PROJECT_LIMIT - 1] = 0;
    return;
  }
}

static inline void anvil_prepared_projects_visit(AnvilPreparedProjects *projects, uint32_t id) {
  if (!id) return;
  anvil_prepared_projects_remove(projects, id);
  for (unsigned i = ANVIL_PREPARED_PROJECT_LIMIT - 1; i > 0; i--) projects->ids[i] = projects->ids[i - 1];
  projects->ids[0] = id;
}

#endif
