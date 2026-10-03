#include "input_latency_probe.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PROBE_MAX_SAMPLES 4096
#define PROBE_TAG 0x5A000000u
#define PROBE_TAG_MASK 0xFF000000u

static struct {
  bool enabled;
  bool started;
  char role[16];
  int count;
  int warmup_ms;
  SDL_Window *window;
  void (*finish)(void);
  SDL_Thread *thread;
  Uint64 sent_ns[PROBE_MAX_SAMPLES + 1];
  Uint64 done_ns[PROBE_MAX_SAMPLES + 1];
  SDL_AtomicInt last_sent;
  SDL_AtomicInt last_done;
  uint64_t consumed_seq;
} probe;

void anvil_latency_probe_init(const char *role) {
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

void anvil_latency_probe_note_event(const SDL_Event *event) {
  if (!probe.enabled || event->type != SDL_EVENT_KEY_DOWN) return;
  if ((event->key.which & PROBE_TAG_MASK) != PROBE_TAG) return;
  uint64_t seq = event->key.which & ~PROBE_TAG_MASK;
  if (seq > probe.consumed_seq) probe.consumed_seq = seq;
}

uint64_t anvil_latency_probe_consumed_seq(void) {
  return probe.consumed_seq;
}

void anvil_latency_probe_presented(uint64_t consumed_seq) {
  if (!probe.started || consumed_seq == 0) return;
  int sent = SDL_GetAtomicInt(&probe.last_sent);
  int done = SDL_GetAtomicInt(&probe.last_done);
  int limit = (int)(consumed_seq < (uint64_t)sent ? consumed_seq : (uint64_t)sent);
  if (limit <= done) return;
  Uint64 now = SDL_GetTicksNS();
  for (int seq = done + 1; seq <= limit; seq++) probe.done_ns[seq] = now;
  SDL_SetAtomicInt(&probe.last_done, limit);
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

static void write_results(void) {
  const char *path = SDL_getenv("ANVIL_INPUT_LATENCY_FILE");
  if (!path || !path[0]) return;
  double *latencies = malloc(sizeof(double) * (size_t)(probe.count + 1));
  if (!latencies) return;
  int n = 0;
  double sum = 0.0;
  for (int seq = 1; seq <= probe.count; seq++) {
    if (!probe.sent_ns[seq] || !probe.done_ns[seq]) continue;
    double ms = (double)(probe.done_ns[seq] - probe.sent_ns[seq]) / 1000000.0;
    latencies[n++] = ms;
    sum += ms;
  }
  FILE *file = fopen(path, "wb");
  if (file) {
    fprintf(file, "role=%s\n", probe.role);
    const char *renderer = SDL_getenv("ANVIL_RENDERER");
    fprintf(file, "renderer=%s\n", renderer && renderer[0] ? renderer : "d3d11");
    fprintf(file, "requested=%d\ncompleted=%d\n", probe.count, n);
    fprintf(file, "samples_ms=");
    for (int i = 0; i < n; i++) fprintf(file, "%s%.3f", i ? "," : "", latencies[i]);
    fprintf(file, "\n");
    qsort(latencies, (size_t)n, sizeof(double), compare_double);
    fprintf(file, "min_ms=%.3f\np50_ms=%.3f\np90_ms=%.3f\np99_ms=%.3f\nmax_ms=%.3f\nmean_ms=%.3f\n",
            n ? latencies[0] : 0.0, percentile(latencies, n, 0.50),
            percentile(latencies, n, 0.90), percentile(latencies, n, 0.99),
            n ? latencies[n - 1] : 0.0, n ? sum / n : 0.0);
    fprintf(file, "done=1\n");
    fclose(file);
  }
  free(latencies);
}

static int SDLCALL generator_thread(void *data) {
  (void)data;
  SDL_Delay((Uint32)(probe.warmup_ms > 0 ? probe.warmup_ms : 0));
  Uint32 window_id = SDL_GetWindowID(probe.window);
  Uint32 random = 0x9E3779B9u;
  for (int seq = 1; seq <= probe.count; seq++) {
    probe.sent_ns[seq] = SDL_GetTicksNS();
    SDL_SetAtomicInt(&probe.last_sent, seq);
    push_key(window_id, SDL_EVENT_KEY_DOWN, (Uint32)seq);

    SDL_Event text;
    SDL_zero(text);
    text.type = SDL_EVENT_TEXT_INPUT;
    text.text.windowID = window_id;
    text.text.text = "a";
    SDL_PushEvent(&text);

    push_key(window_id, SDL_EVENT_KEY_UP, (Uint32)seq);

    /* Vary the gap so samples land on every phase of the display refresh. */
    random ^= random << 13;
    random ^= random >> 17;
    random ^= random << 5;
    SDL_Delay(90 + random % 80);
  }

  Uint64 deadline = SDL_GetTicksNS() + 3 * SDL_NS_PER_SECOND;
  while (SDL_GetAtomicInt(&probe.last_done) < probe.count && SDL_GetTicksNS() < deadline) {
    SDL_Delay(10);
  }
  write_results();
  if (probe.finish) probe.finish();
  return 0;
}

void anvil_latency_probe_start(SDL_Window *window, void (*finish)(void)) {
  if (!probe.enabled || probe.started || !window) return;
  probe.started = true;
  probe.window = window;
  probe.finish = finish;
  probe.thread = SDL_CreateThread(generator_thread, "anvil-latency-probe", NULL);
  if (probe.thread) SDL_DetachThread(probe.thread);
}
