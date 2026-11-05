#include "terminal_recovery.h"
#include <stddef.h>
#include <string.h>

/* These keys begin physical lines. The writer escapes newlines inside every value. */
static bool string_field(const char *record, const char *key, char *out, size_t capacity) {
  const char *value = strstr(record, key);
  *out = 0;
  if (!value) return true; /* Older records have no saved agent report. */
  value += strlen(key);
  if (*value++ != '"') return false;
  size_t length = 0;
  while (*value && *value != '"') {
    unsigned char byte = (unsigned char)*value++;
    if (byte == '\\') {
      unsigned number = 0;
      for (int i = 0; i < 3; i++) {
        if (*value < '0' || *value > '9') return false;
        number = number * 10 + (unsigned)(*value++ - '0');
      }
      if (!number || number > 255) return false;
      byte = (unsigned char)number;
    } else if (byte < 32) return false;
    if (length + 1 >= capacity) return false;
    out[length++] = (char)byte;
  }
  out[length] = 0;
  return *value == '"' && value[1] == ',';
}

static bool number(const char **text, uint32_t *result) {
  const char *p = *text;
  uint32_t value = 0;
  if (*p < '0' || *p > '9') return false;
  do {
    unsigned digit = (unsigned)(*p++ - '0');
    if (value > (UINT32_MAX - digit) / 10) return false;
    value = value * 10 + digit;
  } while (*p >= '0' && *p <= '9');
  *result = value;
  *text = p;
  return true;
}

bool anvil_terminal_recovery_parse(const char *record, AnvilTerminalRecovery *recovery) {
  memset(recovery, 0, sizeof(*recovery));
  if (!record || !string_field(record, "\n  interrupted_command = ", recovery->command, sizeof(recovery->command)) ||
      !string_field(record, "\n  interrupted_input = ", recovery->input, sizeof(recovery->input)) ||
      !string_field(record, "\n  recovery_agent = ", recovery->agent, sizeof(recovery->agent))) return false;
  recovery->has_agent = strstr(record, "\n  recovery_agent = ") != NULL;
  const char *pid = strstr(record, "\n  interrupted_pid = ");
  if (pid) {
    pid += strlen("\n  interrupted_pid = ");
    if (!number(&pid, &recovery->pid) || *pid != ',') return false;
  }
  return true;
}

bool anvil_terminal_agent_matches(const char *report, uint32_t pid) {
  if (!report || !pid) return false;
  for (const char *line = report; *line;) {
    const char *value = !strncmp(line, "pid=", 4) ? line + 4 : !strncmp(line, "ppid=", 5) ? line + 5 : NULL;
    uint32_t found;
    if (value && number(&value, &found) && (*value == '\n' || *value == '\r' || !*value) && found == pid) return true;
    line = strchr(line, '\n');
    if (!line) break;
    line++;
  }
  return false;
}
