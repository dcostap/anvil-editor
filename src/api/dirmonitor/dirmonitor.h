#ifndef DIRMONITOR_H
#define DIRMONITOR_H

enum dirmonitor_change_kind {
  DIRMONITOR_CHANGE_UNKNOWN = 0,
  DIRMONITOR_CHANGE_CONTENT = 1,
  DIRMONITOR_CHANGE_MEMBERSHIP = 2,
  DIRMONITOR_CHANGE_RESCAN = 3,
};

struct dirmonitor_backend {
  const char* name;
  struct dirmonitor_internal* (*init)(void);
  void (*deinit)(struct dirmonitor_internal*);
  int (*get_changes)(struct dirmonitor_internal*, char*, int);
  int (*translate_changes)(struct dirmonitor_internal*, char*, int, int (*)(int, const char*, int, void*), void*);
  int (*add)(struct dirmonitor_internal*, const char*);
  void (*remove)(struct dirmonitor_internal*, int);
  int (*get_mode)();
};

extern struct dirmonitor_backend dirmonitor_dummy;
extern struct dirmonitor_backend dirmonitor_fsevents;
extern struct dirmonitor_backend dirmonitor_inodewatcher;
extern struct dirmonitor_backend dirmonitor_inotify;
extern struct dirmonitor_backend dirmonitor_kqueue;
extern struct dirmonitor_backend dirmonitor_win32;

#endif
