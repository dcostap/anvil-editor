#!/usr/bin/env python3
"""Run editor scenarios on generated codebases and fail when one is over budget.

A scenario combines a fixture (a generated Git repository or a set of
Projects), a shared scene module from `tests/scenes`, a launch mode, and
absolute budgets. Lua tests use the same scene modules, so a test and a
scenario reach the same editor state the same way.

Each scenario runs in a private app copy on a hidden desktop through the render
gate's launcher. Scoring runs carry no detail instrumentation. When a scenario
is over budget, one attribution run records the per-frame detail timers and
reports where the frame time went. `--diagnose` adds a LuaJIT sampling run.

See tools/SCENARIOS.md.
"""
from __future__ import annotations

import argparse
import contextlib
import csv
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import shutil
import statistics
import sys
import time
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import perf_diagnostics  # noqa: E402
import perf_fixtures  # noqa: E402
from perf_fixtures import FolderSpec, ProjectSetSpec, RepoSpec  # noqa: E402
import run_render_perf_gate as gate  # noqa: E402

RESULTS_ROOT = gate.ROOT / "tools" / "perf-results" / "scenarios"
# A steady interaction should draw a frame in well under one 165 Hz frame (6.06 ms).
FRAME_BUDGET_MS = 4.0
# No frame may miss 60 Hz. p95 hides single hitches, such as one slow frame per action.
FRAME_SPIKE_MS = 16.7
ACTION_BUDGET_MS = 100.0

REPO_MEDIUM = RepoSpec("repo-medium", files=6000, commits=20, modified=120, staged=20,
                       deleted=10, untracked=40, ignored=2000)
REPO_HUGE = RepoSpec("repo-huge", files=100000, commits=40, modified=800, staged=60,
                     deleted=40, untracked=200, ignored=30000)
FOLDER_MEDIUM = FolderSpec("folder-medium", files=6000)
# A folder that holds several repositories, like a directory of checkouts.
WORKSPACE = ProjectSetSpec("workspace", projects=12,
                           repo=RepoSpec("member", files=400, modified=20, untracked=5))
PROJECTS_MANY = ProjectSetSpec("projects-many", projects=24)


@dataclass(frozen=True)
class Scenario:
    scene: str
    fixture: RepoSpec | FolderSpec | ProjectSetSpec
    actions: int
    suites: tuple[str, ...]
    settings: dict[str, Any] = field(default_factory=dict)
    launch: str = "direct"  # "direct" runs one Project process; "shell" runs the native shell.
    frame_budget_ms: float = FRAME_BUDGET_MS
    frame_spike_ms: float = FRAME_SPIKE_MS
    action_budget_ms: float = ACTION_BUDGET_MS
    # Budgets for named actions, such as cold and warm Project switches.
    action_budgets: dict[str, float] = field(default_factory=dict)
    # Scenes that edit files cannot run against a user's own `--project`.
    writes: bool = False
    # Seconds between background file edits in the fixture; 0 disables churn.
    churn_interval: float = 0.0
    # Number of clean tracked files passed to the scene as `settings.targets`.
    targets: int = 0
    timeout_seconds: int = 240
    window: tuple[int, int] = (1400, 900)

    @property
    def self_driven(self) -> bool:
        """Self-driven scenes measure flows in other processes, so they record no frames here."""
        return self.scene.startswith("shell_")


SCENARIOS: dict[str, Scenario] = {
    # The baseline: typing in a small file with nothing else open.
    "editor-type-baseline": Scenario(
        "editor_type", REPO_MEDIUM, actions=300, suites=("smoke",), targets=1, writes=True,
        timeout_seconds=300),
    # Typing right after the Project opens, while its file scan and indexes run.
    "editor-type-startup": Scenario(
        "editor_type", REPO_MEDIUM, actions=600, suites=("smoke",), targets=1, writes=True,
        settings={"during_startup": True}),
    "filetree-scroll-medium": Scenario(
        "filetree_scroll", REPO_MEDIUM, actions=40, suites=("smoke",),
        settings={"rows": 600, "max_level": 3},
        # Each wheel action includes the smooth-scroll animation.
        action_budget_ms=400.0),
    "filetree-scroll-huge": Scenario(
        "filetree_scroll", REPO_HUGE, actions=40, suites=("scale",),
        settings={"rows": 2000, "max_level": 3}, action_budget_ms=400.0, timeout_seconds=420),
    # Rows outside any Git repository.
    "filetree-scroll-folder": Scenario(
        "filetree_scroll", FOLDER_MEDIUM, actions=40, suites=("smoke",),
        settings={"rows": 600, "max_level": 3}, action_budget_ms=400.0),
    "filetree-scroll-workspace": Scenario(
        "filetree_scroll", WORKSPACE, actions=40, suites=("smoke",),
        settings={"rows": 600, "max_level": 2}, action_budget_ms=400.0),
    # Files change while the user scrolls, as during a build or an agent's edits.
    "filetree-scroll-churn-medium": Scenario(
        "filetree_scroll", REPO_MEDIUM, actions=40, suites=("smoke",),
        settings={"rows": 600, "max_level": 3}, action_budget_ms=400.0, churn_interval=0.25),
    # The same File Tree scroll in a hosted Project of the native shell.
    "filetree-scroll-shell": Scenario(
        "filetree_scroll", REPO_MEDIUM, actions=40, suites=("shell",), launch="shell",
        settings={"rows": 600, "max_level": 3}, action_budget_ms=400.0),
    "fuzzy-files-medium": Scenario(
        "fuzzy_files", REPO_MEDIUM, actions=24, suites=("smoke",), targets=24,
        action_budgets={"first-query": 1000.0}),
    "fuzzy-files-huge": Scenario(
        "fuzzy_files", REPO_HUGE, actions=24, suites=("scale",), targets=24, timeout_seconds=420,
        action_budgets={"first-query": 3000.0}),
    # Status follows an edit from outside the editor within about a second.
    "git-refresh-medium": Scenario(
        "git_refresh", REPO_MEDIUM, actions=12, suites=("smoke",), targets=6, writes=True,
        action_budget_ms=1000.0),
    "git-refresh-huge": Scenario(
        "git_refresh", REPO_HUGE, actions=8, suites=("scale",), targets=4, writes=True,
        action_budget_ms=1000.0, timeout_seconds=420),
    # Start 6 Projects in one Window, then switch between them 24 times.
    "shell-project-switch": Scenario(
        "shell_project_switch", PROJECTS_MANY, actions=29, suites=("shell", "smoke"), launch="shell",
        settings={"loaded": 6, "warm": 24},
        # A loaded Project shows within a few frames. The shell stops holding the
        # previous frame after 1.5 s, and a starting Project usually presents within 1 s.
        action_budgets={"warm-switch": 50.0, "cold-switch": 1000.0}),
}
SUITES = sorted({suite for scenario in SCENARIOS.values() for suite in scenario.suites} | {"all"})


def suite_scenarios(suite: str) -> list[str]:
    return [name for name, scenario in SCENARIOS.items() if suite == "all" or suite in scenario.suites]


def scenario_targets(scenario: Scenario) -> list[str]:
    return perf_fixtures.clean_files(scenario.fixture, scenario.targets) if scenario.targets else []


def scenario_root(scenario: Scenario, project: Path | None, cache: Path, log) -> Path:
    if project:
        if scenario.writes or scenario.churn_interval:
            raise RuntimeError("this scenario edits files and cannot run on --project")
        return project
    if scenario.targets and project:
        raise RuntimeError("this scenario needs fixture target files and cannot run on --project")
    started = time.perf_counter()
    touched = scenario_targets(scenario) if scenario.writes else None
    root = perf_fixtures.materialize(scenario.fixture, cache, touched=touched)
    log(f"  fixture {scenario.fixture.key} ready in {time.perf_counter() - started:.1f} s")
    return root


def project_roots(scenario: Scenario, root: Path) -> list[Path]:
    """Return the Projects a scene can open. The first one is the measured Project."""
    if scenario.launch == "shell" and isinstance(scenario.fixture, ProjectSetSpec):
        return [root / name for name, _ in perf_fixtures.members(scenario.fixture)]
    return [root]


def launch_options(scenario: Scenario, project: Path, run_dir: Path) -> dict[str, Any]:
    if scenario.launch == "direct":
        return {"launch_arguments": ["--direct"]}
    if scenario.launch == "shell":
        # The benchmark runs inside the measured Project process. Other Project
        # processes and the Sidebar load the plugin but stay inert.
        return {"launch_arguments": ["--shell", gate.native_path(project)],
                "extra_environment": {"ANVIL_PERF_BENCHMARK_PROJECT": gate.native_path(project),
                                      "ANVIL_SURFACE_LOG": gate.native_path(run_dir / "surface.log")},
                "end_phases": ["finished", "failed"]}
    raise ValueError(f"unknown launch mode: {scenario.launch}")


def run_one(name: str, scenario: Scenario, *, exe: Path, work: Path, root: Path, run_dir: Path,
            renderer: str, mode: str, details: bool) -> dict[str, Any]:
    user = run_dir.with_name(run_dir.name + "-user")
    shutil.rmtree(user, ignore_errors=True)
    user.mkdir(parents=True)
    projects = project_roots(scenario, root)
    options = launch_options(scenario, projects[0], run_dir)
    environment = dict(options.pop("extra_environment", {}))
    environment["GIT_CEILING_DIRECTORIES"] = os.pathsep.join(
        gate.native_path(path) for path in (work.parent, root.parent))
    if details:
        environment["ANVIL_DOCVIEW_STATS"] = "1"
        environment["ANVIL_PERF_BENCHMARK_DETAILS"] = gate.native_path(run_dir / "details.csv")
    settings = dict(scenario.settings, kind="scene", scene=scenario.scene, actions=scenario.actions,
                    root=gate.native_path(projects[0]), window_width=scenario.window[0],
                    window_height=scenario.window[1],
                    projects=[gate.native_path(path) for path in projects],
                    targets=scenario_targets(scenario))
    churn = (perf_fixtures.Churn(scenario.fixture, root, scenario.churn_interval)
             if scenario.churn_interval else contextlib.nullcontext())
    with churn:
        return gate.run_case(
            exe=exe, work=work, user=user, fixture=projects[0], tab_dir=work,
            scenario=name, settings=settings, mode=mode, run_dir=run_dir, renderer=renderer,
            frames=100000, warmup_frames=30, screenshot=False,
            total_timeout_seconds=scenario.timeout_seconds, startup_timeout_seconds=90,
            heartbeat_timeout_seconds=60, action_timeout_seconds=60,
            extra_environment=environment, **options)


def read_details(path: Path, limit: int = 15) -> list[dict[str, Any]]:
    """Return the costliest per-frame detail timers. Nested timers overlap."""
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream))
    timers = []
    for row in rows:
        if not row["key"].endswith("_ms"):
            continue
        frames = max(1, int(row["measured_frames"]))
        timers.append({"key": row["key"], "ms_per_frame": float(row["total"]) / frames,
                       "max_ms": float(row["max"]), "frames": int(row["frames"])})
    calls = {row["key"]: float(row["total"]) / max(1, int(row["measured_frames"]))
             for row in rows if row["key"].endswith("_calls")}
    for timer in timers:
        timer["calls_per_frame"] = calls.get(timer["key"].removesuffix("_ms") + "_calls")
    return sorted(timers, key=lambda item: item["ms_per_frame"], reverse=True)[:limit]


def score(scenario: Scenario, runs: list[dict[str, Any]]) -> dict[str, Any]:
    """Score with the median of each run's p95, so one noisy run cannot pass or fail alone."""
    def median(values: list[float]) -> float:
        return statistics.median(values) if values else 0.0
    frame = None if scenario.self_driven else {
        key: median([run["metrics"].get(key, 0.0) for run in runs])
        for key in ("work_ms_p50", "work_ms_p95", "work_ms_p99", "work_ms_max",
                    "lua_heap_kib_avg", "gc_ms_p95", "frames")}
    actions = {}
    for action in sorted({name for run in runs for name in run.get("actions", {})}):
        values = [run["actions"][action] for run in runs if action in run.get("actions", {})]
        actions[action] = {key: median([value[key] for value in values])
                           for key in ("latency_ms_p50", "latency_ms_p95", "latency_ms_max", "redraws_p50")}
    findings = []
    if frame and frame["work_ms_p95"] > scenario.frame_budget_ms:
        findings.append({"metric": "frame work_ms p95", "value": frame["work_ms_p95"],
                         "budget": scenario.frame_budget_ms})
    if frame and frame["work_ms_max"] > scenario.frame_spike_ms:
        findings.append({"metric": "frame work_ms max", "value": frame["work_ms_max"],
                         "budget": scenario.frame_spike_ms})
    for action, values in actions.items():
        budget = scenario.action_budgets.get(action, scenario.action_budget_ms)
        values["budget_ms"] = budget
        if values["latency_ms_p95"] > budget:
            findings.append({"metric": f"{action} latency p95", "value": values["latency_ms_p95"],
                             "budget": budget})
    for finding in findings:
        finding["ratio"] = finding["value"] / finding["budget"]
    return {"frame": frame, "actions": actions, "findings": findings,
            "state": runs[-1].get("state", {})}


def markdown(report: dict[str, Any]) -> str:
    lines = [f"# Scenario report {report['run_id']}", "",
             f"Renderer: {report['renderer']}. Runs per scenario: {report['runs']}.", ""]
    for name, case in report["scenarios"].items():
        lines.append(f"## {name}: {case['verdict']}")
        lines.append("")
        if case.get("error"):
            lines += [f"Error: {case['error']}", ""]
            continue
        frame = case["frame"]
        if frame:
            lines.append(f"Frame work ms: p50 {frame['work_ms_p50']:.2f}, p95 {frame['work_ms_p95']:.2f}, "
                         f"max {frame['work_ms_max']:.2f} (budgets: p95 {case['frame_budget_ms']:.2f}, "
                         f"max {case['frame_spike_ms']:.1f}). "
                         f"Lua heap {frame['lua_heap_kib_avg'] / 1024:.1f} MiB.")
            lines.append("")
        lines.append("| Action | p50 ms | p95 ms | max ms | budget ms | redraws |")
        lines.append("| --- | ---: | ---: | ---: | ---: | ---: |")
        for action, values in case["actions"].items():
            lines.append(f"| {action} | {values['latency_ms_p50']:.1f} | {values['latency_ms_p95']:.1f} "
                         f"| {values['latency_ms_max']:.1f} | {values['budget_ms']:.0f} "
                         f"| {values['redraws_p50']:.0f} |")
        lines.append("")
        for finding in case["findings"]:
            lines.append(f"- Over budget: {finding['metric']} {finding['value']:.2f} ms "
                         f"> {finding['budget']:.2f} ms ({finding['ratio']:.1f}x)")
        if case.get("attribution"):
            lines += ["", "Detail timers in the attribution run (nested timers overlap):", "",
                      "| Timer | ms/frame | max ms | calls/frame |", "| --- | ---: | ---: | ---: |"]
            for timer in case["attribution"]:
                calls = timer["calls_per_frame"]
                lines.append(f"| {timer['key']} | {timer['ms_per_frame']:.2f} | {timer['max_ms']:.2f} "
                             f"| {'' if calls is None else f'{calls:.0f}'} |")
        if case.get("hotspots"):
            lines += ["", "Draw-scope hotspots in the diagnostic run:", ""]
            for item in case["hotspots"]:
                lines.append(f"- {item['path']}: {item['exclusive_ms_per_captured_frame']:.2f} ms/frame")
        lines.append("")
    return "\n".join(lines)


def run_scenario(name: str, scenario: Scenario, args, exe: Path, work: Path, log) -> dict[str, Any]:
    case: dict[str, Any] = {"scene": scenario.scene, "launch": scenario.launch,
                            "fixture": None if args.project else scenario.fixture.key,
                            "frame_budget_ms": scenario.frame_budget_ms,
                            "frame_spike_ms": scenario.frame_spike_ms,
                            "action_budget_ms": scenario.action_budget_ms}
    root = scenario_root(scenario, args.project, args.fixture_cache, log)
    mode = "throughput" if scenario.self_driven else "metrics"
    runs = []
    for index in range(args.runs):
        if index and (scenario.writes or scenario.churn_interval):
            root = scenario_root(scenario, args.project, args.fixture_cache, log)
        run = run_one(name, scenario, exe=exe, work=work, root=root,
                      run_dir=work / name / f"run-{index + 1}", renderer=args.renderer,
                      mode=mode, details=False)
        if "metrics" in run:
            log(f"  run {index + 1}: work p95 {run['metrics']['work_ms_p95']:.2f} ms, "
                f"{int(run['metrics']['frames'])} frames")
        for action, values in run.get("actions", {}).items():
            log(f"  run {index + 1}: {action} p50 {values['latency_ms_p50']:.1f} ms, "
                f"p95 {values['latency_ms_p95']:.1f} ms")
        runs.append(run)
    case.update(score(scenario, runs))
    case["verdict"] = "over budget" if case["findings"] else "passed"
    # Detail timers and samples attribute frame time in the measured process.
    if scenario.self_driven:
        return case
    if case["findings"] or args.attribute:
        if scenario.writes or scenario.churn_interval:
            root = scenario_root(scenario, args.project, args.fixture_cache, log)
        run = run_one(name, scenario, exe=exe, work=work, root=root, run_dir=work / name / "attribution",
                      renderer=args.renderer, mode="metrics", details=True)
        case["attribution"] = read_details(Path(run["run_dir"]) / "details.csv")
    if args.diagnose:
        if scenario.writes or scenario.churn_interval:
            root = scenario_root(scenario, args.project, args.fixture_cache, log)
        run = run_one(name, scenario, exe=exe, work=work, root=root, run_dir=work / name / "diagnostic",
                      renderer=args.renderer, mode="diagnostic", details=False)
        case["hotspots"] = run["diagnostics"]["hotspots"][:12]
        case["profile"] = run["diagnostics"]["html"]
    return case


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--suite", choices=SUITES, default="smoke")
    parser.add_argument("--scenario", action="append", choices=sorted(SCENARIOS),
                        help="run this scenario instead of a suite; repeatable")
    parser.add_argument("--list", action="store_true", help="list scenarios and exit")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--renderer", choices=("d3d11", "software"), default="d3d11")
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--attribute", action="store_true",
                        help="record detail timers even when a scenario is within budget")
    parser.add_argument("--diagnose", action="store_true", help="add a LuaJIT sampling run")
    parser.add_argument("--project", type=Path,
                        help="run read-only scenarios on this directory instead of a fixture")
    parser.add_argument("--fixture-cache", type=Path, default=perf_fixtures.default_cache_root())
    args = parser.parse_args()
    if args.list:
        for name, scenario in SCENARIOS.items():
            print(f"{name:28} {scenario.launch:6} {','.join(scenario.suites):10} {scenario.scene}")
        return 0
    names = args.scenario or suite_scenarios(args.suite)
    if args.project:
        args.project = args.project.resolve()
    if not args.no_build:
        gate.build_anvil()
    run_id = time.strftime("%Y%m%d-%H%M%S")
    work = RESULTS_ROOT / run_id
    work.mkdir(parents=True)
    exe = gate.copy_app_tree(work / "app")
    log_file = (work / "run.log").open("w", encoding="utf-8")

    def log(message: str) -> None:
        print(message, flush=True)
        log_file.write(message + "\n")

    report = {"run_id": run_id, "renderer": args.renderer, "runs": args.runs,
              "repository": gate.repository_info(), "scenarios": {}}
    for name in names:
        log(f"{name}:")
        try:
            case = run_scenario(name, SCENARIOS[name], args, exe, work, log)
        except Exception as exc:  # Report every scenario, then fail.
            case = {"verdict": "error", "error": str(exc),
                    "details": getattr(exc, "details", None)}
        log(f"  {case['verdict']}")
        for finding in case.get("findings", []):
            log(f"    {finding['metric']}: {finding['value']:.2f} ms > {finding['budget']:.2f} ms")
        for timer in case.get("attribution", [])[:6]:
            log(f"    {timer['key']}: {timer['ms_per_frame']:.2f} ms/frame")
        report["scenarios"][name] = case
    (work / "report.json").write_text(json.dumps(report, indent=2, default=str), encoding="utf-8")
    (work / "report.md").write_text(markdown(report), encoding="utf-8")
    log(f"report: {work / 'report.md'}")
    log_file.close()
    verdicts = {case["verdict"] for case in report["scenarios"].values()}
    return 2 if "error" in verdicts else 1 if "over budget" in verdicts else 0


if __name__ == "__main__":
    RESULTS_ROOT.mkdir(parents=True, exist_ok=True)
    # Share the render gate's lock: both use the hidden desktop launcher.
    lock_stream = (RESULTS_ROOT.parent / "render-gate.lock").open("a+b")
    try:
        lock_stream.seek(0)
        if lock_stream.tell() == 0:
            lock_stream.write(b"0")
            lock_stream.flush()
        lock_stream.seek(0)
        try:
            gate.msvcrt.locking(lock_stream.fileno(), gate.msvcrt.LK_NBLCK, 1)
        except OSError as exc:
            raise SystemExit("another render gate or scenario run is already running") from exc
        raise SystemExit(main())
    finally:
        lock_stream.close()
