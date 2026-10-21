#ifndef ANVIL_SHELL_LAUNCH_H
#define ANVIL_SHELL_LAUNCH_H
#include <stdbool.h>
#include <stdint.h>
#include <windows.h>

/* External hosted launches reach the running shell for the same executable, user directory, and session.
 * The request carries only one bounded launch. It is not a general remote call. */
typedef enum {
  ANVIL_SHELL_LAUNCH_OWN,       /* This process owns the shell for its key. */
  ANVIL_SHELL_LAUNCH_FORWARDED, /* The running shell accepted the launch. */
  ANVIL_SHELL_LAUNCH_FAILED,    /* A running shell exists but did not accept the launch in time. */
} AnvilShellLaunchResult;

typedef enum {
  ANVIL_SHELL_LAUNCH_ACCEPTED = 1,
  ANVIL_SHELL_LAUNCH_REJECTED, /* The shell could not resolve or start the Project. */
  ANVIL_SHELL_LAUNCH_BUSY,     /* The shell is ending or cannot take another request now. */
} AnvilShellLaunchStatus;

typedef struct AnvilShellLaunchRequest AnvilShellLaunchRequest;

/* Takes ownership or forwards argv[2..] to the running shell. Runs before the shell creates any Window. */
AnvilShellLaunchResult anvil_shell_launch_own_or_forward(int argc, char **argv);
/* Starts the request server. `notify` runs on a server thread and must hand the request to the UI thread.
 * It returns false when it cannot. */
bool anvil_shell_launch_start(bool (*notify)(AnvilShellLaunchRequest *request));
/* Stops accepting launches and releases shell ownership. Call on the thread that took ownership. */
void anvil_shell_launch_stop(void);

/* Names one shell's mutex and pipe. Linked spellings of one executable and user directory share a key. */
uint32_t anvil_shell_launch_key(const wchar_t *exe, const wchar_t *userdir);
/* The user directory that keys this shell, without a trailing separator. NULL when the key is unavailable. */
const wchar_t *anvil_shell_launch_user_directory(void);

/* Helpers shared with Project adoption. */
/* USERDIR as data/core/start.lua computes it, without a trailing separator. */
bool anvil_shell_user_directory(wchar_t *out, DWORD size);
/* True when `pid` runs this executable as this user in this session. */
bool anvil_shell_same_identity(DWORD pid);
/* Completes one overlapped pipe transfer, bounded by `timeout` and the optional stop event. */
bool anvil_shell_transfer(HANDLE pipe, bool write, void *data, DWORD size, DWORD timeout, HANDLE stop);
/* A security descriptor that admits only the current user. */
PSECURITY_DESCRIPTOR anvil_shell_user_security(void);

/* Request arguments use the shell's layout: argv[0] is the executable, argv[1] is `--shell`.
 * Path arguments are absolute. */
int anvil_shell_launch_argc(const AnvilShellLaunchRequest *request);
char **anvil_shell_launch_argv(const AnvilShellLaunchRequest *request);
const char *anvil_shell_launch_cwd(const AnvilShellLaunchRequest *request);
DWORD anvil_shell_launch_client_pid(const AnvilShellLaunchRequest *request);
bool anvil_shell_launch_foreground_granted(const AnvilShellLaunchRequest *request);
/* Replies once and releases the UI thread's reference. */
void anvil_shell_launch_finish(AnvilShellLaunchRequest *request, AnvilShellLaunchStatus status);
#endif
