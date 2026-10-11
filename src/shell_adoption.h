#ifndef ANVIL_SHELL_ADOPTION_H
#define ANVIL_SHELL_ADOPTION_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* A Project that lost its shell offers itself to the next shell for a bounded period. It publishes a record
 * under USERDIR and listens on its own pipe. The next shell checks the record's process, asks it to connect,
 * and the Project accepts only a shell that runs the same executable as the same user in the same session.
 * The request names one surface pipe. It is not a general remote call. */
#define ANVIL_ADOPTION_PERIOD_MS 60000
#define ANVIL_ADOPTION_MAX_RECORDS 64
#define ANVIL_ADOPTION_MAX_PATH 32768

typedef struct {
  uint32_t pid;
  /* The process creation time. A record whose PID now names another process is stale. */
  uint64_t created;
  /* The Project's Window in the shell that ended, as that shell's Window state names it. */
  uint32_t window_id;
  char *path;
} AnvilAdoptionRecord;

char *anvil_adoption_encode(const AnvilAdoptionRecord *record, size_t *size);
bool anvil_adoption_decode(const char *data, size_t size, AnvilAdoptionRecord *record);
void anvil_adoption_free(AnvilAdoptionRecord *record);

#ifdef _WIN32
#include <windows.h>

/* Project side. */
typedef struct AnvilAdoptionOffer AnvilAdoptionOffer;
/* Creates the pipe, then publishes the record. Returns NULL when either fails; the Project then exits as before. */
AnvilAdoptionOffer *anvil_adoption_offer_open(const char *project_path, uint32_t window_id);
/* Waits until `deadline` (GetTickCount64) for a shell that passes the identity checks. On success, returns
 * the shell's surface pipe name and PID. The caller still checks that the name belongs to that PID. */
bool anvil_adoption_offer_accept(AnvilAdoptionOffer *offer, uint64_t deadline, char *shell_pipe, size_t capacity,
                                 DWORD *shell_pid);
/* Removes the record and closes the pipe. */
void anvil_adoption_offer_close(AnvilAdoptionOffer *offer);

/* Shell side. */
/* Reads valid records from USERDIR and deletes stale ones. Returns the count. */
size_t anvil_adoption_scan(AnvilAdoptionRecord *records, size_t capacity);
/* Asks the record's Project to connect to `shell_pipe`. Returns true when it accepted within `timeout_ms`. */
bool anvil_adoption_request(const AnvilAdoptionRecord *record, const char *shell_pipe, DWORD timeout_ms);
#endif
#endif
