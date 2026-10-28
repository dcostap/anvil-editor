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

A scenario can set `targets` to pass that many clean tracked files to its scene
as `settings.targets`. A scene that edits them sets `writes`, and the next run
restores them.

A scenario can also set `churn_interval`. A background thread then edits
modified files in the fixture during the run, as a build or a coding agent
does. File watchers and Git status refreshes stay busy during measurement.

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

Response scenes set `settings.cadence = "normal"`.
The benchmark keeps normal frame limits and enables D3D11 vsync.
Setup and warmup can request redraws. Measured dispatch and pending actions receive no harness redraw requests.
The production command or result handler must request the redraw.

Reports label cadence explicitly. Response scenes score completed-redraw latency, not frame-work throughput.
Their raw metrics can include a presentation wait, so uncapped frame-work budgets do not apply.
Existing scenarios keep their uncapped rendering-cost measurements.
Latency excludes native input delivery, shell composition, and physical display scanout.

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

`--allocation` adds two runs that stop the GC for the measured frames. The heap then grows by each allocation.
The first run reports the allocation of each main loop phase in KiB per frame, with the JIT on.
The second run uses a line hook and reports the allocation of each source line and its callers. A C function counts on the line that called it.
The hook turns off the JIT, and compiled traces can sink some allocations, so read its sizes as an upper limit.
LuaJIT's GC work grows with allocation. Use this option after changes to code that runs in each frame.

`--heap` adds a run that writes a Heap Census (`core.heap_census`) after the measured frames. It groups the live Lua heap by the data that holds it.
Each GC cycle marks all live objects again, so large live data makes each cycle longer.
The `core:record_heap_census` command writes the same report for the running editor and copies its path.

Frame details include worker-result callbacks before the UI step. Scripted input runs after a frame snapshot.
The next measured frame includes its counters and dispatch time. Each dispatch counts once, including the first one.

## Scenes are shared with Lua tests

`tests/scenes/support.lua` holds setup and readiness helpers such as
`open_file_tree`, `expand_file_tree`, `git_settled`, `background_settled`,
`hover`, and `wheel`. `background_settled` waits until no worker job has run
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
- `action_ready(context, index)` returns `true, result` when the action's
  effect is visible.
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
