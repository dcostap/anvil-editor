#include "input_latency_probe.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#endif

#define PROBE_MAX_SAMPLES 4096
#define PROBE_TAG 0x5A000000u
#define PROBE_TAG_MASK 0xFF000000u

static struct {
  bool enabled;
  bool started;
  bool succeeded;
  bool diagnostics;
  char role[16];
  int count;
  int warmup_ms;
  SDL_Window *window;
  void (*finish)(void);
  SDL_Thread *thread;
  Uint32 wake_event;
  Uint64 sent_ns[PROBE_MAX_SAMPLES + 1];
  Uint64 done_ns[PROBE_MAX_SAMPLES + 1];
  Uint64 sent_qpc[PROBE_MAX_SAMPLES + 1];
  Uint64 shown_qpc[PROBE_MAX_SAMPLES + 1];
  unsigned present_count[PROBE_MAX_SAMPLES + 1];
  SDL_AtomicInt last_sent;
  SDL_AtomicInt last_done;
  SDL_AtomicInt last_shown;
  uint64_t consumed_seq;
  bool received[PROBE_MAX_SAMPLES + 1];
} probe;

void anvil_latency_probe_init(const char *role) {
  const char *diagnostics = SDL_getenv("ANVIL_INPUT_LATENCY_DIAGNOSTICS");
  probe.diagnostics = diagnostics && !strcmp(diagnostics, "1");
  const char *value = SDL_getenv("ANVIL_INPUT_LATENCY_PROBE");
  int count = value ? atoi(value) : 0;
  if (count <= 0) return;
  if (count > PROBE_MAX_SAMPLES) count = PROBE_MAX_SAMPLES;
  probe.enabled = true;
  probe.count = count;
  const char *warmup = SDL_getenv("ANVIL_INPUT_LATENCY_WARMUP_MS");
  probe.warmup_ms = warmup && warmup[0] ? atoi(warmup) : 5000;
  SDL_strlcpy(probe.role, role ? role : "unknown", sizeof(probe.role));
}

bool anvil_latency_probe_enabled(void) {
  return probe.enabled;
}
bool anvil_latency_probe_succeeded(void) { return probe.succeeded; }
void anvil_latency_probe_stage(const char *stage) {
  if (probe.enabled && probe.diagnostics)
    SDL_Log("Latency stage: role=%s stage=%s seq=%llu qpc=%llu frequency=%llu", probe.role, stage,
            (unsigned long long)probe.consumed_seq, (unsigned long long)SDL_GetPerformanceCounter(),
            (unsigned long long)SDL_GetPerformanceFrequency());
}

void anvil_latency_probe_note_event(const SDL_Event *event) {
  if (!probe.enabled || event->type != SDL_EVENT_KEY_DOWN) return;
  if ((event->key.which & PROBE_TAG_MASK) != PROBE_TAG) return;
  uint64_t seq = event->key.which & ~PROBE_TAG_MASK;
  if (seq <= PROBE_MAX_SAMPLES) probe.received[seq] = true;
  while (probe.consumed_seq < PROBE_MAX_SAMPLES && probe.received[probe.consumed_seq + 1])
    probe.consumed_seq++;
  anvil_latency_probe_stage("input-queued");
}

uint64_t anvil_latency_probe_consumed_seq(void) {
  return probe.consumed_seq;
}

void anvil_latency_probe_presented(uint64_t consumed_seq, unsigned present_count) {
  if (!probe.started || consumed_seq == 0) return;
  int sent = SDL_GetAtomicInt(&probe.last_sent);
  int done = SDL_GetAtomicInt(&probe.last_done);
  int limit = (int)(consumed_seq < (uint64_t)sent ? consumed_seq : (uint64_t)sent);
  if (limit <= done) return;
  Uint64 now = SDL_GetTicksNS();
  for (int seq = done + 1; seq <= limit; seq++) {
    probe.done_ns[seq] = now;
    probe.present_count[seq] = present_count;
  }
  SDL_SetAtomicInt(&probe.last_done, limit);
  if (probe.diagnostics)
    SDL_Log("Latency presentation: role=%s seq=%d qpc=%llu", probe.role, limit,
            (unsigned long long)SDL_GetPerformanceCounter());
}

/* Statistics name only the newest shown frame. A later frame shown before this call gives earlier frames
 * its time, so frequent calls keep the measurement close. */
void anvil_latency_probe_shown(unsigned present_count, uint64_t qpc) {
  if (!probe.started) return;
  int done = SDL_GetAtomicInt(&probe.last_done);
  int shown = SDL_GetAtomicInt(&probe.last_shown);
  while (shown < done && probe.present_count[shown + 1] && probe.present_count[shown + 1] <= present_count)
    probe.shown_qpc[++shown] = qpc;
  SDL_SetAtomicInt(&probe.last_shown, shown);
}

static void push_key(Uint32 window_id, Uint32 type, Uint32 seq) {
  SDL_Event event;
  SDL_zero(event);
  event.type = type;
  event.key.windowID = window_id;
  event.key.which = PROBE_TAG | seq;
  event.key.scancode = SDL_SCANCODE_A;
  event.key.key = SDLK_A;
  event.key.down = type == SDL_EVENT_KEY_DOWN;
  SDL_PushEvent(&event);
}

static void push_sample(Uint32 window_id, Uint32 seq) {
  push_key(window_id, SDL_EVENT_KEY_DOWN, seq);
  SDL_Event text = {0};
  text.type = SDL_EVENT_TEXT_INPUT;
  text.text.windowID = window_id;
  text.text.text = "a";
  SDL_PushEvent(&text);
  push_key(window_id, SDL_EVENT_KEY_UP, seq);
}

static int compare_double(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return x < y ? -1 : x > y ? 1 : 0;
}

static double percentile(const double *sorted, int n, double p) {
  if (n <= 0) return 0.0;
  int index = (int)(p * (double)(n - 1) + 0.5);
  if (index < 0) index = 0;
  if (index >= n) index = n - 1;
  return sorted[index];
}

static void write_samples(FILE *file, const char *prefix, double *latencies, int n) {
  double sum = 0.0;
  fprintf(file, "%ssamples_ms=", prefix);
  for (int i = 0; i < n; i++) {
    fprintf(file, "%s%.3f", i ? "," : "", latencies[i]);
    sum += latencies[i];
  }
  fprintf(file, "\n");
  qsort(latencies, (size_t)n, sizeof(double), compare_double);
  fprintf(file, "%smin_ms=%.3f\n%sp50_ms=%.3f\n%sp90_ms=%.3f\n%sp99_ms=%.3f\n%smax_ms=%.3f\n%smean_ms=%.3f\n",
          prefix, n ? latencies[0] : 0.0, prefix, percentile(latencies, n, 0.50), prefix,
          percentile(latencies, n, 0.90), prefix, percentile(latencies, n, 0.99), prefix,
          n ? latencies[n - 1] : 0.0, prefix, n ? sum / n : 0.0);
}

static void write_results(void) {
  const char *path = SDL_getenv("ANVIL_INPUT_LATENCY_FILE");
  if (!path || !path[0]) return;
  double *latencies = malloc(sizeof(double) * (size_t)(probe.count + 1));
  double *shown = malloc(sizeof(double) * (size_t)(probe.count + 1));
  if (!latencies || !shown) {
    free(latencies);
    free(shown);
    return;
  }
  int n = 0, shown_n = 0;
  double frequency = (double)SDL_GetPerformanceFrequency();
  for (int seq = 1; seq <= probe.count; seq++) {
    if (!probe.sent_ns[seq] || !probe.done_ns[seq]) continue;
    latencies[n++] = (double)(probe.done_ns[seq] - probe.sent_ns[seq]) / 1000000.0;
    if (probe.shown_qpc[seq] > probe.sent_qpc[seq])
      shown[shown_n++] = (double)(probe.shown_qpc[seq] - probe.sent_qpc[seq]) * 1000.0 / frequency;
  }
  FILE *file = fopen(path, "wb");
  if (file) {
    fprintf(file, "role=%s\n", probe.role);
    const char *renderer = SDL_getenv("ANVIL_RENDERER");
    fprintf(file, "renderer=%s\n", renderer && renderer[0] ? renderer : "d3d11");
    fprintf(file, "requested=%d\ncompleted=%d\n", probe.count, n);
    write_samples(file, "", latencies, n);
    /* Present can return long before the frame reaches the screen, when frames queue in DXGI. */
    fprintf(file, "shown_completed=%d\n", shown_n);
    write_samples(file, "shown_", shown, shown_n);
    probe.succeeded = n == probe.count;
    fprintf(file, "done=%d\nunmatched=%d\n", probe.succeeded ? 1 : 0, probe.count - n);
    fclose(file);
  }
  free(latencies);
  free(shown);
}

/* A shell reads frame statistics after its steps, and they name only the newest shown frame. Wake the
 * shell while a presented sample waits, so a later frame does not lend it a later time. */
static void wait_ms(Uint32 ms) {
  Uint64 until = SDL_GetTicks() + ms;
  bool shell = !strcmp(probe.role, "shell");
  while (SDL_GetTicks() < until) {
    if (shell && probe.wake_event && SDL_GetAtomicInt(&probe.last_shown) < SDL_GetAtomicInt(&probe.last_done)) {
      SDL_Event wake = {0};
      wake.type = probe.wake_event;
      SDL_PushEvent(&wake);
    }
    Uint64 left = until - SDL_GetTicks();
    SDL_Delay(left < 4 ? (Uint32)left : 4);
  }
}

#ifdef _WIN32
static void post_hover(HWND native_window, unsigned *motion) {
  PostMessageW(native_window, ANVIL_ROUTING_PROBE_MESSAGE, 0, ((*motion)++ % 2 ? 250 << 16 : 50 << 16) | 100);
}
#endif

static int SDLCALL generator_thread(void *data) {
  (void)data;
  SDL_Delay((Uint32)(probe.warmup_ms > 0 ? probe.warmup_ms : 0));
  Uint32 window_id = SDL_GetWindowID(probe.window);
  Uint32 random = 0x9E3779B9u;
  bool sidebar_hover = SDL_getenv("ANVIL_INPUT_LATENCY_SIDEBAR_HOVER") != NULL;
  unsigned motion = 0;
#ifdef _WIN32
  /* Native messages expose delays between Windows input polls. SDL_PushEvent bypasses that wait. */
  HWND native_window = sidebar_hover && !strcmp(probe.role, "shell")
    ? SDL_GetPointerProperty(SDL_GetWindowProperties(probe.window), SDL_PROP_WINDOW_WIN32_HWND_POINTER, NULL)
    : NULL;
  if (native_window) {
    /* A Window move presents frames inside its modal loop. Typing after it shows whether frames now queue. */
    PostMessageW(native_window, WM_ENTERSIZEMOVE, 0, 0);
    for (int i = 0; i < 40; i++) {
      post_hover(native_window, &motion);
      SDL_Delay(8);
    }
    PostMessageW(native_window, WM_EXITSIZEMOVE, 0, 0);
    SDL_Delay(250);
  }
#endif
  for (int seq = 1; seq <= probe.count; seq++) {
    probe.sent_ns[seq] = SDL_GetTicksNS();
    probe.sent_qpc[seq] = SDL_GetPerformanceCounter();
    SDL_SetAtomicInt(&probe.last_sent, seq);
    if (probe.diagnostics)
      SDL_Log("Latency generated: role=%s seq=%d qpc=%llu", probe.role, seq,
              (unsigned long long)SDL_GetPerformanceCounter());
    const char *gate = SDL_getenv("ANVIL_SURFACE_FAULT_PROBE");
    const char *skip = SDL_getenv("ANVIL_INPUT_LATENCY_SKIP_AFTER");
    if (gate && !strcmp(gate, "1") && skip && seq > SDL_atoi(skip)) continue;
#ifdef _WIN32
    if (native_window)
      PostMessageW(native_window, ANVIL_ROUTING_PROBE_MESSAGE, 12, seq);
    else
#endif
      push_sample(window_id, (Uint32)seq);

    /* Vary the gap so samples land on every phase of the display refresh. */
    random ^= random << 13;
    random ^= random >> 17;
    random ^= random << 5;
    /* Keep both surfaces active in the Sidebar check. Sparse hover changes do not reproduce the queue delay. */
    Uint32 gap = sidebar_hover ? 25 + random % 25 : 90 + random % 80;
    if (!sidebar_hover) wait_ms(gap);
    else {
      Uint64 until = SDL_GetTicks() + gap;
      while (SDL_GetTicks() < until) {
        SDL_Event hover = {0};
        hover.type = SDL_EVENT_MOUSE_MOTION;
        hover.motion.windowID = window_id;
        hover.motion.x = 100;
        hover.motion.y = motion % 2 ? 250 : 50;
#ifdef _WIN32
        if (native_window)
          post_hover(native_window, &motion);
        else
#endif
        {
          motion++;
          SDL_PushEvent(&hover);
        }
        wait_ms(8);
      }
    }
  }

  bool shell = !strcmp(probe.role, "shell");
  Uint64 deadline = SDL_GetTicksNS() + 3 * SDL_NS_PER_SECOND;
  while ((SDL_GetAtomicInt(&probe.last_done) < probe.count ||
          (shell && SDL_GetAtomicInt(&probe.last_shown) < probe.count)) &&
         SDL_GetTicksNS() < deadline)
    wait_ms(4);
  write_results();
  if (probe.finish) probe.finish();
  return 0;
}

void anvil_latency_probe_start(SDL_Window *window, void (*finish)(void)) {
  if (!probe.enabled || probe.started || !window) return;
  probe.started = true;
  probe.window = window;
  probe.finish = finish;
  probe.wake_event = SDL_RegisterEvents(1);
  probe.thread = SDL_CreateThread(generator_thread, "anvil-latency-probe", NULL);
  if (probe.thread) SDL_DetachThread(probe.thread);
}

bool anvil_routing_probe_message(SDL_Window *window, uint32_t message, uintptr_t action, intptr_t point) {
  if (message == ANVIL_ROUTING_PROBE_MESSAGE && action == 12 && probe.started && point > 0 && point <= probe.count) {
    push_sample(SDL_GetWindowID(window), (Uint32)point);
    return true;
  }
  if (message != ANVIL_ROUTING_PROBE_MESSAGE || action > 11) return false;
  const char *enabled = SDL_getenv("ANVIL_INPUT_ROUTING_PROBE");
  if (!enabled || strcmp(enabled, "1")) return false;
  SDL_Event event = {0};
  float x = (int16_t)(point & 0xffff);
  float y = (int16_t)((point >> 16) & 0xffff);
  if (action == 9 || action == 10) {
    event.type = action == 9 ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP;
    event.key.windowID = SDL_GetWindowID(window);
    event.key.key = (SDL_Keycode)point;
    event.key.scancode = SDL_GetScancodeFromKey(event.key.key, NULL);
    event.key.down = action == 9;
    /* Posted probe keys do not update SDL's modifier state as OS keys do. */
    SDL_Keymod modifier = 0;
    switch (event.key.scancode) {
      case SDL_SCANCODE_LCTRL: modifier = SDL_KMOD_LCTRL; break;
      case SDL_SCANCODE_RCTRL: modifier = SDL_KMOD_RCTRL; break;
      case SDL_SCANCODE_LSHIFT: modifier = SDL_KMOD_LSHIFT; break;
      case SDL_SCANCODE_RSHIFT: modifier = SDL_KMOD_RSHIFT; break;
      case SDL_SCANCODE_LALT: modifier = SDL_KMOD_LALT; break;
      case SDL_SCANCODE_RALT: modifier = SDL_KMOD_RALT; break;
      default: break;
    }
    if (modifier) SDL_SetModState(event.key.down ? SDL_GetModState() | modifier : SDL_GetModState() & ~modifier);
    event.key.mod = SDL_GetModState();
  } else if (action == 11) {
    /* One ASCII character for owned search-routing checks. */
    /* SDL queues the pointer, so each character needs stable storage. */
    static char text[128][2];
    if (point <= 0 || point > 127) return false;
    text[point][0] = (char)point;
    event.type = SDL_EVENT_TEXT_INPUT;
    event.text.windowID = SDL_GetWindowID(window);
    event.text.text = text[point];
  } else if (action == 0) {
    event.type = SDL_EVENT_MOUSE_MOTION;
    event.motion.windowID = SDL_GetWindowID(window);
    event.motion.x = x;
    event.motion.y = y;
  } else if (action == 3) {
    event.type = SDL_EVENT_MOUSE_WHEEL;
    event.wheel.windowID = SDL_GetWindowID(window);
    event.wheel.mouse_x = x;
    event.wheel.mouse_y = y;
    event.wheel.y = -1;
  } else if (action >= 4 && action <= 6) {
    event.type = action == 4 ? SDL_EVENT_DROP_BEGIN : action == 5 ? SDL_EVENT_DROP_TEXT : SDL_EVENT_DROP_COMPLETE;
    event.drop.windowID = SDL_GetWindowID(window);
    event.drop.x = x;
    event.drop.y = y;
    if (action == 5) {
      /* Fixed owned fixture: exceed the old half-packet truncation bound. */
      static char text[40001];
      memset(text, 'z', 40000);
      const char prefix[] = "DROP_λ中\n\n";
      memcpy(text, prefix, sizeof(prefix) - 1);
      text[39998] = text[39999] = '\n';
      text[40000] = 0;
      event.drop.data = text;
    }
  } else {
    bool down = action == 1 || action == 7;
    event.type = down ? SDL_EVENT_MOUSE_BUTTON_DOWN : SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.windowID = SDL_GetWindowID(window);
    event.button.button = action >= 7 ? SDL_BUTTON_RIGHT : SDL_BUTTON_LEFT;
    event.button.down = down;
    event.button.clicks = 1;
    event.button.x = x;
    event.button.y = y;
  }
  SDL_PushEvent(&event);
  return true;
}
