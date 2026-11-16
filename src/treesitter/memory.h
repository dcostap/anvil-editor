#ifndef ANVIL_TS_MEMORY_H
#define ANVIL_TS_MEMORY_H

/* Call once, before any Tree-sitter allocation or worker starts. */
void anvil_ts_memory_init(void);
/* Release arrays that Tree-sitter returns to its caller. */
void anvil_ts_memory_free(void *pointer);

#endif
