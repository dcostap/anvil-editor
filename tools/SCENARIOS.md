# Scenario runs

`tools/run_scenarios.py` measures editor workflows on generated codebases and
fails when a scenario is over its budget. Use it to find performance problems.
Use the [render performance gate](RENDER_PERF_GATE.md) to compare a renderer
change with a baseline and to check pixels.

```sh
python tools/run_scenarios.py                    # smoke suite, 3 scoring runs each
python tools/run_scenarios.py --suite scale      # 100,000-file repository
python tools/run_scenarios.py --list
python tools/run_scenarios.py --scenario filetree-scroll-folder --runs 1 --no-build
```

The exit code is 0 when every scenario is within budget, 1 when one is over
budget, and 2 when a scenario could not run. Reports go to
`tools/perf-results/scenarios/<run id>/report.md` and `report.json`.

## What a scenario is

A scenario names four things:

- **Fixture**: generated content from `tools/perf_fixtures.py`.
  - `RepoSpec`: a Git repository with history, modified, staged, deleted,
    untracked, and ignored files.
  - `FolderSpec`: generated code outside any Git repository.
  - `ProjectSetSpec`: a folder that holds several repositories.
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

## Scoring and attribution

Each scoring run records frames without detail instrumentation. The verdict
uses the median of each run's p95 frame work time (frame time minus sleep) and
each action's p95 latency.

`editor-type-baseline` types short lines into a small file after the
Project's startup scans and indexes finish. It shows the cost of the cheapest
real input frame. `editor-type-startup` types while that startup work runs.

When a scenario is over budget, one more run records the per-frame detail
timers (`ANVIL_DOCVIEW_STATS`). The report lists the costliest timers per
measured frame. Nested timers overlap, so read them as a tree. Scheduler
threads appear as `thread <file>:<line>_ms`, named by the code that started
them. `--attribute`
records them for passing scenarios too. `--diagnose` adds a LuaJIT sampling
run with draw scopes and a Speedscope profile.

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
