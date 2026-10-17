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
- **Budgets**: absolute limits. A frame budget of 6.06 ms is one frame at
  165 Hz. Each scenario sets its action latency budget.

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

When a scenario is over budget, one more run records the per-frame detail
timers (`ANVIL_DOCVIEW_STATS`). The report lists the costliest timers per
measured frame. Nested timers overlap, so read them as a tree. `--attribute`
records them for passing scenarios too. `--diagnose` adds a LuaJIT sampling
run with draw scopes and a Speedscope profile.

## Scenes are shared with Lua tests

`tests/scenes/support.lua` holds setup and readiness helpers such as
`open_file_tree`, `expand_file_tree`, `git_settled`, `hover`, and `wheel`.
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

`context.settings` holds the scenario settings, and `context.root` is the
fixture root.

## Adding a scenario

1. Write or reuse a scene in `tests/scenes`.
2. Add a `Scenario` to `SCENARIOS` in `tools/run_scenarios.py`. Choose a
   fixture that exposes the cost, such as a large repository, a folder outside
   Git, or background churn.
3. Run it with `--runs 1 --attribute` and check that its actions do what they
   claim, for example that the scroll position changes.
4. Put fast scenarios in `smoke` and long ones in `scale`.
