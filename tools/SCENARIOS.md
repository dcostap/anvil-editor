# Scenario runs

`tools/run_scenarios.py` measures editor workflows on generated codebases and
fails when a scenario is over its budget. Use it to find performance problems.
Use the [render performance gate](RENDER_PERF_GATE.md) to compare a renderer
change with a baseline and to check pixels.

```sh
python tools/run_scenarios.py                    # smoke suite, 3 scoring runs each
python tools/run_scenarios.py --suite scale      # 100,000-file repository
python tools/run_scenarios.py --suite markdown   # the 19,000-line gallery and a linked vault
python tools/run_scenarios.py --list
python tools/run_scenarios.py --scenario filetree-scroll-folder --runs 1 --no-build
```

The exit code is 0 when every scenario is within budget, 1 when one is over
budget, and 2 when a scenario could not run. Reports go to
`tools/perf-results/scenarios/<run id>/report.md` and `report.json`.
Each run deletes old runs first. It keeps the newest 20 and every run from the last 14 days.

## What a scenario is

A scenario names four things:

- **Fixture**: generated content from `tools/perf_fixtures.py`.
  - `RepoSpec`: a Git repository with history, modified, staged, deleted,
    untracked, and ignored files.
  - `FolderSpec`: generated code outside any Git repository.
  - `CompletionSpec`: a small Odin file and a large symbol library.
  - `ProjectSetSpec`: a folder that holds several repositories.
  - `MarkdownSpec`: a generated note with an embedded image and tables.
  - `NoteSpec`: a checked-in note from `tests/fixtures`, for a hand-written
    specimen that a generator cannot reproduce.
  - `VaultSpec`: a Markdown vault of linked notes with task lists.
- **Scene**: a Lua module in `tests/scenes`. It sets up the editor, reports
  when the setup is ready, and dispatches each action.
- **Launch mode**: `direct` runs one Project process. `shell` runs the native
  shell, and the benchmark runs in the named Project's process.
- **Budgets**: absolute limits. The p95 frame work time must stay within
  4 ms, well under one 165 Hz frame (6.06 ms). No frame may take more than
16.7 ms, one 60 Hz frame. Each scenario sets its action latency budget.

Scenarios use a 1400×900 window. Scenarios named `-large` use 2560×1440, the
window of a large monitor. A larger window draws more rows, so some costs show
only there.

A scenario can set `targets` to pass that many clean tracked files to its scene
as `settings.targets`. A scene that edits them sets `writes`, and the next run
restores them.

A scenario can also set `churn_interval`. A background thread then edits
modified files in the fixture during the run, as a build or a coding agent
does. File watchers and Git status refreshes stay busy during measurement.

## Heading Outline navigation

`markdown-gallery-outline-sections` moves between adjacent and distant sections in the complete gallery. `markdown-gallery-outline-click` clicks visible headings in both directions. Both keep transitions enabled and require an outline longer than its visible area.

`markdown-gallery-outline-response` repeats the section changes with normal frame pacing. It receives no harness redraw requests during measurement, so a missing animation redraw cannot pass.

Each action waits for the caret, document scroll, outline scroll, and a drawn selection marker at the requested heading. A missing outline or an unfinished transition cannot pass as completed navigation. The scene observes the marker through renderer calls, not private animation fields. Its extra layout query adds measurement overhead.

Run these cases before changing Heading Outline navigation or animation:

```sh
python tools/run_scenarios.py --scenario markdown-gallery-outline-sections --scenario markdown-gallery-outline-click --runs 1 --diagnose
python tools/run_scenarios.py --scenario markdown-gallery-outline-response --runs 1
```

The standard frame-work budgets apply to the uncapped cases. The response case scores completed-action latency instead, because presentation waits can dominate its frame times. All three have a 400 ms completed-action budget, including intentional animation. These cases measure direct-mode frame work and completed draws, not native input delivery or physical display smoothness.

## Focused runtime workloads

`fuzzy-text-accents` runs in the default `smoke` suite and the focused `search` suite. It searches a generated 6,000-file Project with 2,400 accented lines. It checks composed and combining accents, quoted phrases, multiple terms, `ñ`, no matches, and query replacement before scanner startup. Each action waits for completion, not only the first rows. It edits only a fixture-owned file and refuses `--project`.

`ui/fuzzy_searcher_exact_grep.lua` tests replacement after a running scan publishes partial results. A controlled process stream keeps that test independent of machine speed. It checks cancellation and rejects queued results from the old query.

`fuzzy-terminal-history` runs in `smoke`, `search`, and `terminal`. It searches 12,000 lines from a real, private Terminal, with 1,200 accented matches. It measures composed and combining accents, multiple terms, `ñ`, and completed no-match scans. It closes only its own Terminal when the benchmark exits.

Run the scanner comparison separately from frame measurements:

```sh
gcc -O2 -Isrc tools/accent_search_probe.c src/fuzzy.c -o build-windows-x86_64/accent_search_probe.exe
python tools/benchmark_accent_search.py --output tools/perf-results/accent-scan.json
python tools/benchmark_accent_search.py --files 2048 --lines 2048 --output tools/perf-results/accent-scan-large.json
```

The probe uses the editor's candidate patterns. The script checks Latin variants and multi-character NFC decompositions against Python's Unicode data. It also checks literal matches for canonical forms that NFC does not compose. It checks candidate retention, not native verification or selection positions. It alternates literal and accent-equivalent scans over private temporary Projects, then deletes them. Times include ripgrep output formatting, but not editor ranking or drawing. An accent-equivalent query can return more lines, so compare result counts as well as time. Query preparation time is separate from scan time.

`text-poi-long-field` parses a 16,000-byte field followed by a file location. `text-poi-many-locations` parses 22,000 locations. `text-poi-limited-locations` uses the same input but requests only 32 results. Keep the limited case: limiting returned rows must also stop unnecessary scanning.

`process-finalize-handles` drops eight process wrappers and requests two large GC steps. It measures GC and finalization together. Run `process-finalize-gc-control` beside it to measure the same GC requests without process wrappers. Separate runs do not give an exact native-finalizer subtraction.

These cases measure one action per process. Their frame p95 describes that heavy frame, not sustained editing.

`quick-command-output` navigates from a Terminal capture with 22,000 missing-file references to one valid target. `editor-file-locations` edits a line with 2,000 missing-file references and checks the new target. These cases include path resolution and result publication, not only parsing. Worker results can span several frames. Compare completed-action latency and maximum frame work as well as p95.

The Quick Command fixture supplies a fixed capture at the Terminal API boundary. It does not measure shell execution or native screen extraction.

`benchmark-idle-setup` checks that setup continues while its private Window is idle and unfocused. It models loss of focus at the system API boundary; it does not change desktop focus. Run it after benchmark scheduling changes:

```sh
python tools/run_scenarios.py --scenario benchmark-idle-setup --runs 1 --no-build
```

Setup uses a background coroutine so it can continue while the Window is unfocused. This is still the UI thread. Setup must yield while waiting and use workers for expensive work.

## Fixtures

Fixtures are deterministic. The first build of a spec is cached under
`%LOCALAPPDATA%\anvil-perf-fixtures\<name>-<hash>`. The 100,000-file
repository takes a few minutes to build once. Each run then restores the
committed files and applies the same working-tree changes again, in a few
seconds. Bump `GENERATOR_VERSION` when generated content changes.

`--project PATH` runs read-only scenarios on an existing folder, such as this
repository. Scenarios that edit files refuse `--project`.

## Response latency

Run the response check separately from uncapped rendering-cost measurements:

```sh
python tools/run_scenarios.py --suite response --runs 3
python tools/run_scenarios.py --scenario autocomplete-navigation-latency --runs 1 --attribute
```

`autocomplete-navigation-latency` alternates Next and Previous commands in a real autocomplete popup.
It checks the selected suggestion and observes its overlay draw before completing each action.
Its p95 action budget is 50 ms. A missing redraw fails the action deadline.

### Large-index autocomplete

Run the focused suite to check completion searches, not only popup navigation:

```sh
python tools/run_scenarios.py --suite autocomplete --runs 3
```

The large-index scenes use a small Odin file and a generated library with 75,000 procedures. The small-index control uses 200 procedures. Setup rejects skipped source files and an incomplete native symbol index. Each library also supplies distinct completion targets and an enum. No fake completion provider or LSP supplies the results.

| Scenario | Measured behavior |
| --- | --- |
| `autocomplete-project-small` | Repeat single-character completion against 200 generated procedures as a small-index control. |
| `autocomplete-project-type` | Type and delete one character while Project symbol completion stays active. |
| `autocomplete-project-members` | Type a receiver dot and member prefix, then delete them. The dot starts an empty-query member search. |
| `autocomplete-project-refresh` | Dismiss completion before each typed character. Require a Project completion result after parsing finishes. |
| `autocomplete-project-burst` | Send 30 separate text-input events without a redraw, then delete them. Repeat with no matching symbols. |
| `autocomplete-project-response` | Repeat single-character completion with normal frame pacing and a 50 ms completed-action budget. |

The small-index control and four uncapped large-index scenarios also run in `smoke`. They enforce the standard frame-work and action budgets. The normal-paced case also runs in `response`; presentation waits do not count as uncapped frame-work failures.

Each action checks the typed text and waits for parsing and pending completion searches. This includes no-match actions: an empty popup does not prove that a search finished. Completion actions require the expected symbol, icon, source path, and popup draw. Disabling completion cannot pass these checks. Visible latency ends when the edited line draws; completed latency also includes the verified completion draw.

Burst events use `core.on_event` and editor commands. They cover repeated handler work before a redraw, not native OS delivery or queue delay. Setup and fixture generation stay outside measurement. Each run restores the fixture-owned edited file. These scenarios refuse `--project`.

Fixture setup gives outline and usage queries a longer deadline, so worker scheduling does not leave an incomplete index. The scene restores the normal deadlines before measurement. Frame and completion budgets do not change. Skipped files still fail setup, with their path and reason.

A failed scene readiness check reports its original error. It does not wait for the external timeout or record a performance score.

Check fixture restoration and input-cost scoring with:

```sh
python -m unittest tests.tools.test_completion_scenarios -v
```

Response scenes set `settings.cadence = "normal"`.
The benchmark keeps normal frame limits and enables D3D11 vsync.
Setup and warmup can request redraws. Measured dispatch and pending actions receive no harness redraw requests.
The production command or result handler must request the redraw.

Reports label cadence explicitly. Response scenes score completed-redraw latency, not frame-work throughput.
Their raw metrics can include a presentation wait, so uncapped frame-work budgets do not apply.
Existing scenarios keep their uncapped rendering-cost measurements.
Latency excludes native input delivery, shell composition, and physical display scanout.

`quick-command-response` repeats the output-navigation case with normal cadence. Keep its score separate from the uncapped case. A private-desktop presentation wait can dominate this result. Inspect `renderer_end_ms` and `present_ms` before attributing that wait to Lua. Disabling vsync is a diagnostic control, not a passing result for normal cadence.

`quick-command-hosted` runs that case in a hosted Project, as the normal Windows app does. It measures completion of the Project's redraw, not the shell's presentation. Compare it with a hosted baseline, not a direct-window baseline. Keep both cases: direct-window presentation waits must not hide a slow Project or suggest that every hosted redraw blocks there.

`quick-command-valid` uses 22,000 valid references. It checks result transfer and navigation when every reference resolves. These scenes check the complete location count after scoring. They do not include that full-list request in navigation latency.

The harness guards use the private desktop launcher:

```sh
python -m unittest tests.tools.test_response_latency -v
```

See [redraw ownership](REDRAW_SCHEDULING.md) for the background publication audit and regression tests.

## Scoring and attribution

Each scoring run records frames without detail instrumentation. The verdict
uses the median of each run's p95 frame work time (frame time minus sleep) and
each action's p95 latency.

The gallery typing and newline scenes report two latencies:

- **Completed** (`latency_ms`): input dispatch to the redraw that shows the current semantic publication. This metric is unchanged.
- **Visible** (`visible_ms`): input dispatch to the end of the first redraw that draws the edited line.

The scene observes text drawing. It does not wait for the semantic worker to measure visible latency.
Both metrics exclude OS input delivery and physical display scanout. The report gives p50 and p95 for each.

The `fuzzy_picker` scene opens the Fuzzy Searcher with its preview over the
File Tree or the editor. Its `mode` setting selects Project File Search,
Project Symbol Search, Text Search, or Path Search. A `navigate` action moves the selection
and ends when the preview shows the new result. A `type` action types the next
character of the query and ends when the search for the new text has ended.
Text Search ends the action at its first rows, because it can search for a
long time.

Path Search asks Everything for files anywhere on the PC. A scenario with the
`everything` setting starts a fake Everything (`tools/fake_everything.py`) that
answers from the fixture, and points `EVERYTHING_HOST` and `EVERYTHING_PORT` at it.

## UI-thread blocking calls

A busy disk or a virus scan can make one file call take seconds. On the UI thread,
that call stops every frame. Fixture files are warm in the cache, so frame times
do not show the risk. Each run therefore counts the calls that can block
(`core.blocking_calls`): file opens, reads and writes, file information, folder
lists, process starts, and module loads. It counts them in measured frames only
and names the code that made them, with three stack frames.

- The report lists the call sites, and `blocking-calls.csv` in each run folder
  has them. `actions.csv` has the count for each action.
- A scenario with `blocking_call_budget` fails when the median run makes more
  calls. The fuzzy navigate scenarios have a budget of 0.
- `--slow-io MS` makes each UI-thread call wait first, as a busy disk does. Use
  it to see what a remaining call costs. Worker calls do not wait.

A Lua test can use the same counter. `blocking_calls.start()` begins a
recording and `blocking_calls.callers()` lists its call sites. The Machine guard
refuses a call before it reaches the counter. When the guard turns off, it
restores the functions it wrapped. The counter goes on if it was installed
before the guard turned on. Otherwise the next `start` installs it again.

`filetree_scroll` and `editor_scroll` scroll with the wheel, or with `input =
"keys"` move the caret one line at a time from the bottom row. Each move then
scrolls, as when the user holds an arrow key. `editor_scroll` uses the
`repo-long` fixture, whose files have 3000 to 6000 lines.

`editor-type-baseline` types short lines into a small file after the
Project's startup scans and indexes finish. It shows the cost of the cheapest
real input frame. `editor-type-startup` types while that startup work runs.

`markdown-vault-type` types into a task note while 8 other notes from the
vault stay open. Each other note is shown once first, as a user visits it, so
it holds a laid-out presentation. Each keystroke waits until the vault index
publishes the edited note. Compare it with the same scene and no other notes:
the other notes should add almost no frame time.

When a scenario is over budget, one more run records the per-frame detail
timers (`ANVIL_DOCVIEW_STATS`). The report lists the costliest timers per
measured frame. Nested timers overlap, so read them as a tree. Scheduler
threads appear as `thread <file>:<line>_ms`, named by the code that started
them. `--attribute`
records them for passing scenarios too. `--diagnose` adds a LuaJIT sampling
run with draw scopes and a Speedscope profile.

Allocation profiling is disabled. `--allocation` fails before a build or launch. Normal runs keep garbage collection enabled and do not report allocation budgets.

The removed profiler stopped garbage collection and allocated tables and strings in a hook on each Lua line. Its own garbage stayed in memory. A gallery diagnostic reached 23.8 GiB and exhausted system commit memory. Do not use stopped-GC runs to measure allocation. Use the existing timers, `--diagnose`, and `--heap` instead. A heap census measures retained objects, not allocation rate.

The shared Windows launcher limits each benchmark process tree to 4 GiB of committed memory. The kernel applies the limit before the app starts, including child processes. On a refused allocation, the launcher stops the tree and reports `memory_limit`, not a timeout or a passing measurement. Each run saves `launcher.json`, with `memory_limit_bytes` and `peak_job_memory_bytes`. Windows' peak counter can include a refused allocation.

An explicit launch JSON can set a positive `memory_limit_mb`. It cannot disable the limit. Raise it only for a measured workload that needs more memory, not to keep a failed diagnostic running. The limit applies per launched tree, not to all programs on the machine. Old launch files that request allocation profiling fail before launch.

`--heap` adds a run that writes a Heap Census (`core.heap_census`) after the measured frames. It groups the live Lua heap by the data that holds it.
Each GC cycle marks all live objects again, so large live data makes each cycle longer.
The `core:record_heap_census` command writes the same report for the running editor and copies its path.

Frame details include worker-result callbacks before the UI step. Scripted input runs after a frame snapshot.
The next measured frame includes its counters and dispatch time. Each dispatch counts once, including the first one.

## Scenes are shared with Lua tests

`tests/scenes/support.lua` holds setup and readiness helpers such as
`open_file_tree`, `expand_file_tree`, `git_settled`, `background_settled`,
`hover`, `wheel`, `caret_to_bottom`, and `move_caret`. `background_settled` waits until no worker job has run
for 2 seconds.
Scenario runs load scenes through `data/core/perf_scene.lua`.
`tests/run-lua-tests.sh` copies `tests/scenes` into the test app, so a Lua test
can `require "scenes.support"` and reach the same state. In a test, wait with
`support.wait_until(predicate)`.

A scene module returns a table with these functions:

- `setup(context)` returns the measured View.
- `ready(context)` is optional. It returns true when setup has settled.
- `action_name(context, index)` is optional.
- `dispatch(context, index)` performs one action.
- `action_ready(context, index)` returns `true, result` when the action's state is ready to draw.
- `action_drawn(context)` is optional. It verifies the result's draw after the frame finishes. Use it when the scene observes a draw method. Keep `action_ready` as the pre-draw state check, so completion does not wait for an extra frame.
- `action_visible(context)` is optional. It returns true after the scene observes the first draw of the edited text.
  Return false while waiting, or nil for actions without this measurement. Completion still uses `action_ready`.
- `state(context)` is optional. Its values appear in the report state.
- `run(context)` replaces `dispatch` and `action_ready` in a self-driven
  scene. See [Shell scenarios](#shell-scenarios).

`context.settings` holds the scenario settings, and `context.root` is the
measured Project's root.

## Shell scenarios

A `shell` scenario starts `anvil --shell <Project>` on the hidden desktop. With
a `ProjectSetSpec` fixture, the first repository is the measured Project, and
`settings.projects` lists every repository. The shell writes its events to
`surface.log` in the run directory. The run ends when the measured Project
reaches the `finished` or `failed` phase, because the shell keeps running.

Frame scenes, such as `filetree_scroll`, run unchanged in the hosted Project.
A flow that another process presents, such as a Project switch, uses a
self-driven scene instead. Its `run(context)` function runs in a background
coroutine and calls `context.record { name = ..., latency_ms = ... }` once for
each action. A Project keeps running background coroutines after another
Project is selected. Self-driven scenes record no frames, so their scenarios
have only action budgets.

`tests/scenes/shell.lua` reads the surface log. `shell.select_project` selects
a Project and returns the shell's time from the selection to that Project's
first composited frame. Cold switches start the Project's process. Warm
switches show a loaded Project again.

## Adding a scenario

1. Write or reuse a scene in `tests/scenes`.
2. Add a `Scenario` to `SCENARIOS` in `tools/run_scenarios.py`. Choose a
   fixture that exposes the cost, such as a large repository, a folder outside
   Git, or background churn.
3. Run it with `--runs 1 --attribute` and check that its actions do what they
   claim, for example that the scroll position changes.
4. Put fast scenarios in `smoke` and long ones in `scale`.
