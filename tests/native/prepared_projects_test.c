#include <assert.h>
#include "prepared_projects.h"

int main(void) {
  AnvilPreparedProjects projects = {0};
  assert(!anvil_prepared_projects_contains(&projects, 1));
  for (unsigned id = 1; id <= ANVIL_PREPARED_PROJECT_LIMIT; id++)
    anvil_prepared_projects_visit(&projects, id);
  /* A revisit protects the oldest Project from the next eviction. */
  anvil_prepared_projects_visit(&projects, 1);
  unsigned next = ANVIL_PREPARED_PROJECT_LIMIT + 1;
  anvil_prepared_projects_visit(&projects, next);
  assert(anvil_prepared_projects_contains(&projects, 1));
  assert(!anvil_prepared_projects_contains(&projects, 2));
  assert(anvil_prepared_projects_contains(&projects, next));
  /* A visit restores an evicted Project. Removing it releases its slot. */
  anvil_prepared_projects_visit(&projects, 2);
  assert(anvil_prepared_projects_contains(&projects, 2));
  anvil_prepared_projects_remove(&projects, 2);
  assert(!anvil_prepared_projects_contains(&projects, 2));
  anvil_prepared_projects_visit(&projects, next + 1);
  assert(anvil_prepared_projects_contains(&projects, 1));
  assert(anvil_prepared_projects_contains(&projects, next));
  assert(anvil_prepared_projects_contains(&projects, next + 1));
  /* Empty shell placeholders cannot occupy a slot. */
  anvil_prepared_projects_visit(&projects, 0);
  assert(!anvil_prepared_projects_contains(&projects, 0));
  return 0;
}
