#!/usr/bin/env python3
"""Run deterministic Anvil render benchmarks on an isolated Windows desktop.

The benchmark process receives its own app tree, USERDIR, work directory, and
hidden Win32 desktop. It never kills, focuses, moves, or captures the user's
interactive Anvil window.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import msvcrt
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys
import time
from typing import Any, Iterable

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build-windows-x86_64"
RESULTS_ROOT = ROOT / "tools" / "perf-results" / "render-gate"
BASELINE_PATH = ROOT / "tools" / "baselines" / "render_perf_windows.json"
GOLDEN_ROOT = ROOT / "tools" / "baselines" / "render"
HIDDEN_LAUNCHER = ROOT / "tools" / "run_anvil_hidden_desktop.ps1"
IMAGE_COMPARATOR = ROOT / "tools" / "compare_anvil_screenshot.ps1"
MARKDOWN_LONG_LINK_PAYLOAD_REPETITIONS = 4950

SCENARIOS: dict[str, dict[str, Any]] = {
    "wrapped-document-steady": {
        "start_line": 1700,
        "window_width": 1400,
        "window_height": 1400,
        "visual": True,
        "paced": True,
    },
    "wrapped-document-scroll": {
        "start_line": 1200,
        "scroll_lines": 1,
        "window_width": 1400,
        "window_height": 1400,
        "visual": True,
        "paced": True,
    },
    "tab-heavy-titlebar": {
        "start_line": 1700,
        "tab_count": 40,
        "window_width": 1400,
        "window_height": 900,
        "visual": True,
        "paced": True,
    },
    "caret-repeat": {
        "start_line": 1200,
        "window_width": 1400,
        "window_height": 900,
        "visual": True,
        "paced": True,
    },
    "markdown-long-link-caret-repeat": {
        "fixture": "markdown-long-link",
        "payload_repetitions": MARKDOWN_LONG_LINK_PAYLOAD_REPETITIONS,
        "start_line": 1,
        "window_width": 1400,
        "window_height": 900,
        "visual": True,
        "paced": False,
    },
    "renderer-primitives": {
        "start_line": 1,
        "window_width": 1400,
        "window_height": 900,
        "visual": True,
        "paced": False,
    },
}

SUITES = {
    "quick": ["wrapped-document-steady", "wrapped-document-scroll", "tab-heavy-titlebar"],
    "full": list(SCENARIOS),
    "visual": [name for name, item in SCENARIOS.items() if item["visual"]],
}

LOWER_IS_BETTER = {
    "action_ms_p50": (0.08, 0.10),
    "action_ms_p95": (0.12, 0.20),
    "frame_ms_p50": (0.05, 0.15),
    "frame_ms_p95": (0.08, 0.25),
    "draw_emit_ms_p50": (0.05, 0.12),
    "draw_emit_ms_p95": (0.08, 0.20),
    "renderer_end_ms_p50": (0.05, 0.12),
    "renderer_end_ms_p95": (0.08, 0.20),
    "update_ms_p50": (0.08, 0.10),
    "update_ms_p95": (0.12, 0.20),
    "draw_calls_avg": (0.03, 10.0),
    "rencache_commands_avg": (0.03, 10.0),
    "paced_interval_ms_p95": (0.10, 0.30),
}
HIGHER_IS_BETTER = {
    "active_fps": (0.05, 2.0),
    "quads_per_draw_avg": (0.05, 0.10),
    "paced_active_fps": (0.05, 2.0),
}


def run(command: list[str], *, cwd: Path = ROOT, env: dict[str, str] | None = None,
        timeout: int | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        command, cwd=str(cwd), env=env, timeout=timeout,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    if check and completed.returncode != 0:
        raise RuntimeError(
            f"command failed ({completed.returncode}): {' '.join(command)}\n{completed.stdout}"
        )
    return completed


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_anvil() -> None:
    meson = Path(r"C:\msys64\mingw64\bin\meson.exe")
    if not meson.exists():
        raise RuntimeError(f"Meson not found: {meson}")
    env = os.environ.copy()
    env["PATH"] = str(meson.parent) + os.pathsep + env.get("PATH", "")
    completed = run([str(meson), "compile", "-C", str(BUILD)], env=env, timeout=900)
    if completed.stdout.strip():
        print(completed.stdout.rstrip())


def copy_app_tree(destination: Path) -> Path:
    exe = BUILD / "src" / "anvil.exe"
    start_lua = BUILD / "start.lua"
    if not exe.exists() or not start_lua.exists():
        raise RuntimeError("Anvil build outputs are missing; run without --no-build")

    bindir = destination / "bin"
    datadir = destination / "share" / "anvil"
    bindir.mkdir(parents=True)
    datadir.mkdir(parents=True)
    shutil.copy2(exe, bindir / "anvil.exe")
    for name in ("core", "compat", "plugins", "colors", "fonts", "widget", "treesitter"):
        source = ROOT / "data" / name
        if source.exists():
            shutil.copytree(source, datadir / name)
    shutil.copy2(start_lua, datadir / "core" / "start.lua")
    shutil.copytree(ROOT / "resources" / "icons", datadir / "icons")
    return bindir / "anvil.exe"


def generate_fixture(work: Path) -> tuple[Path, Path, Path]:
    fixture_dir = work / "fixtures"
    tab_dir = fixture_dir / "tabs"
    tab_dir.mkdir(parents=True)
    fixture = fixture_dir / "render-benchmark.lua"
    lines = [
        "-- Deterministic Anvil renderer benchmark fixture.\n",
        "local RenderBenchmark = { values = {} }\n",
        "\n",
    ]
    for i in range(1, 721):
        lines.extend([
            f"function RenderBenchmark:calculate_{i:04d}(input, enabled)\n",
            f"  local label = \"office -> affine [{i:04d}] éλ漢字\"\n",
            "  local description = \"wrapped renderer fixture with syntax colors, repeated words, clipping boundaries, Unicode glyphs éλ漢字, and enough deterministic text to cross the centered Editor width on every generated record\"\n",
            f"  local value = (input * {i % 97 + 3}) + 0x{i % 65535:04x}\n",
            "  if enabled and value > 42 then\n",
            f"    self.values[{i}] = {{ label = label, description = description, value = value, active = true }}\n",
            "  else self.values[#self.values + 1] = { label = label, value = -value } end\n",
            "  return self.values[#self.values]\n",
            "end\n",
            "\n",
        ])
    lines.append("return RenderBenchmark\n")
    fixture.write_text("".join(lines), encoding="utf-8", newline="\n")
    for i in range(1, 41):
        (tab_dir / f"benchmark-tab-{i:03d}.lua").write_text(
            f"-- benchmark tab {i}\nreturn {{ id = {i}, title = 'tab-{i:03d}' }}\n",
            encoding="utf-8", newline="\n",
        )
    markdown_fixture = fixture_dir / "markdown-long-link.md"
    # Match the roughly 59 KiB rich rendered links in the captured workload.
    payload = "A/0123456789" * MARKDOWN_LONG_LINK_PAYLOAD_REPETITIONS
    markdown_fixture.write_text(
        "[embedded](data:image/png;base64," + payload + ")\nnext\n",
        encoding="utf-8", newline="\n",
    )
    return fixture, tab_dir, markdown_fixture


def read_key_values(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        key, separator, value = line.partition("=")
        if separator:
            values[key] = value
    return values


def percentile(values: Iterable[float], quantile: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return 0.0
    position = (len(ordered) - 1) * quantile
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    fraction = position - lower
    return ordered[lower] * (1 - fraction) + ordered[upper] * fraction


def summarize_metrics(path: Path) -> dict[str, float]:
    with path.open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream))
    if not rows:
        raise RuntimeError(f"metrics file has no rows: {path}")

    def numbers(key: str) -> list[float]:
        return [float(row.get(key) or 0) for row in rows]

    result: dict[str, float] = {"frames": float(len(rows))}
    for key in (
        "action_ms", "update_ms", "draw_emit_ms", "renderer_end_ms", "frame_ms",
        "present_ms", "core_step_ms", "total_ms", "draw_calls", "quad_instances",
        "texture_batch_breaks", "quad_batches", "unique_batch_srvs",
        "repeated_batch_srvs", "rencache_commands", "rencache_text_commands",
        "rencache_command_bytes", "display_packet_replays",
        "display_packet_commands_replayed", "display_packet_frame_bytes_copied",
        "display_packet_replay_ms", "text_render_calls", "text_render_glyphs",
        "text_render_hb_shape_ms",
    ):
        vals = numbers(key)
        result[f"{key}_avg"] = statistics.fmean(vals)
        result[f"{key}_p50"] = percentile(vals, 0.50)
        result[f"{key}_p95"] = percentile(vals, 0.95)
        result[f"{key}_p99"] = percentile(vals, 0.99)
    draws = result["draw_calls_avg"]
    result["quads_per_draw_avg"] = result["quad_instances_avg"] / draws if draws else 0.0
    completion = numbers("completion_ms")
    if completion and completion[-1] > 0:
        result["observed_fps"] = len(completion) * 1000.0 / completion[-1]
        intervals = [completion[0]] + [
            current - previous for previous, current in zip(completion, completion[1:])
        ]
        result["interval_ms_p50"] = percentile(intervals, 0.50)
        result["interval_ms_p95"] = percentile(intervals, 0.95)
        result["interval_ms_p99"] = percentile(intervals, 0.99)
        result["interval_ms_max"] = max(intervals)
        result["interval_over_6_06_fraction"] = sum(value > 6.06 for value in intervals) / len(intervals)
    return result


def median_metric_summaries(summaries: list[dict[str, float]]) -> dict[str, float]:
    keys = sorted(set().union(*(summary.keys() for summary in summaries)))
    return {
        key: statistics.median(summary[key] for summary in summaries if key in summary)
        for key in keys
    }


def relative_mad(values: list[float]) -> float:
    if not values:
        return 0.0
    center = statistics.median(values)
    if center == 0:
        return 0.0
    return statistics.median(abs(value - center) for value in values) / abs(center)


def relative_spread(values: list[float]) -> float:
    if not values:
        return 0.0
    center = statistics.median(values)
    if center == 0:
        return 0.0
    if len(values) < 5:
        return (max(values) - min(values)) / abs(center)
    return (percentile(values, 0.90) - percentile(values, 0.10)) / abs(center)


def invoke_hidden(config_path: Path, timeout_seconds: int) -> str:
    completed = run([
        "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", str(HIDDEN_LAUNCHER), "-Config", str(config_path),
        "-TimeoutSeconds", str(timeout_seconds),
    ], timeout=timeout_seconds + 20)
    return completed.stdout.strip()


def run_case(
    *, exe: Path, work: Path, user: Path, fixture: Path, tab_dir: Path,
    scenario: str, settings: dict[str, Any], mode: str, run_dir: Path,
    frames: int, warmup_frames: int, screenshot: bool,
) -> dict[str, Any]:
    run_dir.mkdir(parents=True)
    result_file = run_dir / "result.txt"
    metrics_file = run_dir / "metrics.csv"
    screenshot_file = run_dir / "screenshot.png"
    case_fixture = (
        work / "fixtures" / "markdown-long-link.md"
        if settings.get("fixture") == "markdown-long-link" else fixture
    )
    environment = {
        "ANVIL_USERDIR": str(user),
        "USERPROFILE": str(user),
        "ANVIL_RENDERER": "d3d11",
        # The IPC plugin uses a process-global shared-memory channel. Disable
        # it before startup so a benchmark can never hand its fixture to the
        # user's interactive Anvil instance.
        "ANVIL_TEST_DISABLE_PLUGINS": "ipc,autorestart,autoreload,autosave_fast,autosaveonfocuslost",
        "ANVIL_D3D11_PRESENT_SYNC_INTERVAL": "1" if mode == "paced-metrics" else "0",
        "ANVIL_PERF_BENCHMARK": "1",
        "ANVIL_PERF_BENCHMARK_SCENARIO": scenario,
        "ANVIL_PERF_BENCHMARK_MODE": mode,
        "ANVIL_PERF_BENCHMARK_FILE": str(case_fixture),
        "ANVIL_PERF_BENCHMARK_TAB_DIR": str(tab_dir),
        "ANVIL_PERF_BENCHMARK_RESULT": str(result_file),
        "ANVIL_PERF_BENCHMARK_METRICS": str(metrics_file),
        "ANVIL_PERF_BENCHMARK_SCREENSHOT": str(screenshot_file) if screenshot else "",
        "ANVIL_PERF_BENCHMARK_CAPTURE_FRAMES": "3",
        "ANVIL_PERF_BENCHMARK_CAPTURE_SETTLE_FRAMES": "5",
        "ANVIL_PERF_BENCHMARK_WARMUP_FRAMES": str(warmup_frames),
        "ANVIL_PERF_BENCHMARK_FRAMES": str(frames),
        "ANVIL_PERF_BENCHMARK_START_LINE": str(settings.get("start_line", 1)),
        "ANVIL_PERF_BENCHMARK_SCROLL_LINES": str(settings.get("scroll_lines", 1)),
        "ANVIL_PERF_BENCHMARK_TAB_COUNT": str(settings.get("tab_count", 40)),
        "ANVIL_PERF_BENCHMARK_WINDOW_WIDTH": str(settings["window_width"]),
        "ANVIL_PERF_BENCHMARK_WINDOW_HEIGHT": str(settings["window_height"]),
    }
    launch_config = {
        "exe": str(exe),
        "working_directory": str(work),
        # The benchmark plugin owns file/view activation. Passing the fixture
        # on the command line would enqueue a second deferred open that can
        # steal focus back from custom visual scenes during warmup.
        "arguments": [],
        "environment": environment,
    }
    config_path = run_dir / "launch.json"
    config_path.write_text(json.dumps(launch_config, indent=2), encoding="utf-8")
    timeout_seconds = max(90, int((frames + warmup_frames) / 20) + 60)
    launcher_output = invoke_hidden(config_path, timeout_seconds)
    values = read_key_values(result_file)
    if values.get("done") != "1":
        raise RuntimeError(
            f"benchmark failed: scenario={scenario} mode={mode} "
            f"error={values.get('error', 'missing result')} launcher={launcher_output}"
        )
    result: dict[str, Any] = {
        "scenario": scenario,
        "mode": mode,
        "run_dir": str(run_dir),
        "active_fps": float(values["active_fps"]),
        "elapsed_ms": float(values["elapsed_ms"]),
        "measured_frames": int(values["measured_frames"]),
        "warmup_frames": int(values["warmup_frames"]),
        "action_count": int(values.get("action_count", 0)),
        "renderer_path": values.get("renderer_path", ""),
        "sync_interval": int(float(values.get("sync_interval", 0))),
        "target_fps": float(values.get("target_fps", 0)),
        "scale": float(values.get("scale", 0)),
        "launcher": launcher_output,
    }
    if result["measured_frames"] != frames:
        raise RuntimeError(f"workload mismatch: expected {frames}, got {result['measured_frames']}")
    if result["renderer_path"] != "commands":
        raise RuntimeError(f"expected D3D11 command renderer, got {result['renderer_path']!r}")
    if mode in ("metrics", "paced-metrics"):
        result["metrics"] = summarize_metrics(metrics_file)
        result["metrics_file"] = str(metrics_file)
    if screenshot:
        if not screenshot_file.exists():
            raise RuntimeError(f"screenshot missing: {screenshot_file}")
        stability_files = [
            screenshot_file,
            screenshot_file.with_name(f"{screenshot_file.stem}-stability-2{screenshot_file.suffix}"),
            screenshot_file.with_name(f"{screenshot_file.stem}-stability-3{screenshot_file.suffix}"),
        ]
        for path in stability_files:
            if not path.exists():
                raise RuntimeError(f"stability screenshot missing: {path}")
        hashes = [sha256(path) for path in stability_files]
        if len(set(hashes)) != 1:
            raise RuntimeError(
                f"static frame instability detected for {scenario}: "
                + ", ".join(f"{path.name}={digest}" for path, digest in zip(stability_files, hashes))
            )
        result["screenshot"] = str(screenshot_file)
        result["stability_screenshots"] = [str(path) for path in stability_files]
    return result


def compare_image(baseline: Path, current: Path, output_json: Path) -> dict[str, Any]:
    completed = run([
        "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", str(IMAGE_COMPARATOR), "-Baseline", str(baseline),
        "-Current", str(current), "-OutputJson", str(output_json),
        "-PixelTolerance", "0", "-MaxMismatchedPixels", "0",
        "-IgnoreEdgePixels", "0", "-AllowVisualMismatch",
    ])
    return json.loads(completed.stdout)


def machine_info(exe: Path, fixture: Path) -> dict[str, Any]:
    return {
        "node": platform.node(),
        "platform": platform.platform(),
        "processor": platform.processor(),
        "python": platform.python_version(),
        "exe_sha256": sha256(exe),
        "fixture_sha256": sha256(fixture),
    }


def repository_info() -> dict[str, Any]:
    revision = run(["git", "rev-parse", "HEAD"], check=False).stdout.strip()
    status = run(["git", "status", "--short"], check=False).stdout.splitlines()
    return {"revision": revision, "dirty": bool(status), "changed_paths": status}


def compare_performance(current: dict[str, Any], baseline: dict[str, Any]) -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []
    for scenario, now in current["scenarios"].items():
        before = baseline.get("scenarios", {}).get(scenario)
        if not before:
            findings.append({"scenario": scenario, "metric": "baseline", "status": "missing"})
            continue
        pairs = {"active_fps": (now["active_fps"], before["active_fps"])}
        if now.get("paced") and before.get("paced"):
            pairs["paced_active_fps"] = (
                now["paced"]["active_fps"], before["paced"]["active_fps"]
            )
            pairs["paced_interval_ms_p95"] = (
                now["paced"]["metrics"]["interval_ms_p95"],
                before["paced"]["metrics"]["interval_ms_p95"],
            )
        for metric in LOWER_IS_BETTER:
            if metric in now["metrics"] and metric in before.get("metrics", {}):
                pairs[metric] = (now["metrics"][metric], before["metrics"][metric])
        for metric in HIGHER_IS_BETTER:
            if metric != "active_fps" and metric in now["metrics"] and metric in before.get("metrics", {}):
                pairs[metric] = (now["metrics"][metric], before["metrics"][metric])
        for metric, (value, reference) in pairs.items():
            relative = ((value - reference) / reference) if reference else 0.0
            if metric in LOWER_IS_BETTER:
                rel_limit, abs_limit = LOWER_IS_BETTER[metric]
                failed = value - reference > abs_limit and relative > rel_limit
            else:
                rel_limit, abs_limit = HIGHER_IS_BETTER[metric]
                if metric == "active_fps":
                    rel_limit = max(
                        rel_limit,
                        2 * relative_mad(now.get("active_fps_runs", [])),
                        2 * relative_mad(before.get("active_fps_runs", [])),
                    )
                failed = reference - value > abs_limit and -relative > rel_limit
            findings.append({
                "scenario": scenario,
                "metric": metric,
                "current": value,
                "baseline": reference,
                "relative_change": relative,
                "relative_limit": rel_limit,
                "status": "regression" if failed else "pass",
            })
    for item in findings:
        scenario = current.get("scenarios", {}).get(item.get("scenario"), {})
        if (item.get("metric") == "active_fps"
                and item.get("status") == "regression"
                and not scenario.get("throughput_stable", True)):
            item["status"] = "inconclusive"
    return findings


def markdown_report(report: dict[str, Any]) -> str:
    hard_failure = any(
        item.get("status") in ("regression", "missing")
        for item in report.get("performance_findings", [])
    ) or any(
        scenario.get("visual", {}).get("status") in ("regression", "missing", "not_updated")
        for scenario in report.get("scenarios", {}).values()
    ) or report.get("baseline_status") == "missing" or any(
        value is False for value in report.get("baseline_compatibility", {}).values()
    )
    verdict = (
        "PASS" if report["passed"] else
        "INCONCLUSIVE" if report.get("inconclusive") and not hard_failure else
        "FAIL"
    )
    lines = [
        "# Anvil render performance gate",
        "",
        f"- Suite: `{report['suite']}`",
        f"- Result: **{verdict}**",
        f"- Run directory: `{report['run_dir']}`",
        "",
        "| Scenario | Active FPS | Paced FPS | Metrics tax | Frame p50 | Frame p95 | Draw p50 | Renderer p50 | Draw calls | Quads/draw | Visual |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|",
    ]
    for name, scenario in report["scenarios"].items():
        metrics = scenario["metrics"]
        visual = scenario.get("visual", {}).get("status", "n/a")
        lines.append(
            f"| {name} | {scenario['active_fps']:.1f} | "
            f"{scenario.get('paced', {}).get('active_fps', 0):.1f} | "
            f"{scenario['telemetry_overhead_fraction']:.1%} | "
            f"{metrics['frame_ms_p50']:.3f} | "
            f"{metrics['frame_ms_p95']:.3f} | {metrics['draw_emit_ms_p50']:.3f} | "
            f"{metrics['renderer_end_ms_p50']:.3f} | {metrics['draw_calls_avg']:.1f} | "
            f"{metrics['quads_per_draw_avg']:.2f} | {visual} |"
        )
    regressions = [item for item in report.get("performance_findings", []) if item["status"] == "regression"]
    if regressions:
        lines.extend(["", "## Regressions", ""])
        for item in regressions:
            lines.append(
                f"- `{item['scenario']}` `{item['metric']}`: {item['baseline']:.3f} -> "
                f"{item['current']:.3f} ({item['relative_change']:+.1%})"
            )
    inconclusive = [
        item for item in report.get("performance_findings", [])
        if item["status"] == "inconclusive"
    ]
    if inconclusive:
        lines.extend(["", "## Inconclusive under system load", ""])
        for item in inconclusive:
            lines.append(
                f"- `{item['scenario']}` `{item['metric']}`: {item['baseline']:.3f} -> "
                f"{item['current']:.3f} ({item['relative_change']:+.1%})"
            )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--suite", choices=sorted(SUITES), default="quick")
    parser.add_argument("--scenario", choices=sorted(SCENARIOS))
    parser.add_argument("--runs", type=int)
    parser.add_argument("--metrics-runs", type=int)
    parser.add_argument("--paced-runs", type=int)
    parser.add_argument("--max-runs", type=int, default=9)
    parser.add_argument("--frames", type=int)
    parser.add_argument("--warmup-frames", type=int)
    parser.add_argument("--baseline", type=Path, default=BASELINE_PATH)
    parser.add_argument("--update-baseline", action="store_true")
    parser.add_argument("--update-goldens", action="store_true")
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--no-visual", action="store_true")
    args = parser.parse_args()

    if os.name != "nt":
        raise RuntimeError("the isolated D3D11 gate requires Windows")
    full = args.suite == "full"
    runs = args.runs if args.runs is not None else (5 if full else 3)
    metrics_runs = args.metrics_runs if args.metrics_runs is not None else 2
    paced_runs = args.paced_runs if args.paced_runs is not None else 1
    # Quick and full suites use identical per-scenario workloads so both can
    # compare against one full-suite baseline. Quick is faster by selecting
    # fewer scenarios and repetitions, not by changing the workload.
    frames = args.frames if args.frames is not None else 600
    warmup_frames = args.warmup_frames if args.warmup_frames is not None else 180
    if (runs < 1 or metrics_runs < 1 or paced_runs < 1 or frames < 2
            or warmup_frames < 1 or args.max_runs < 1):
        parser.error("run and frame counts must be positive")
    if args.max_runs < runs:
        parser.error("--max-runs must be greater than or equal to --runs")

    baseline = None
    if args.baseline.exists():
        baseline = json.loads(args.baseline.read_text(encoding="utf-8"))
    selected_scenarios = [args.scenario] if args.scenario else SUITES[args.suite]
    partial_baseline_update = set(selected_scenarios) != set(SCENARIOS)
    if args.update_baseline and partial_baseline_update and not baseline:
        parser.error("partial baseline updates require an existing full baseline")

    if not args.no_build:
        build_anvil()

    run_id = time.strftime("%Y%m%d_%H%M%S") + f"_{os.getpid()}"
    run_root = RESULTS_ROOT / run_id
    app_root = run_root / "app"
    work = run_root / "work"
    user = run_root / "user"
    work.mkdir(parents=True)
    user.mkdir(parents=True)
    exe = copy_app_tree(app_root)
    fixture, tab_dir, _markdown_fixture = generate_fixture(work)

    report: dict[str, Any] = {
        "schema": 1,
        "suite": args.suite,
        "run_id": run_id,
        "run_dir": str(run_root),
        "runs": runs,
        "metrics_runs": metrics_runs,
        "paced_runs": paced_runs,
        "frames": frames,
        "warmup_frames": warmup_frames,
        "machine": machine_info(exe, fixture),
        "repository": repository_info(),
        "scenarios": {},
        "passed": True,
    }

    if args.update_baseline and partial_baseline_update:
        baseline_scenarios = baseline.get("scenarios", {})
        untouched_scenarios = set(baseline_scenarios) - set(selected_scenarios)
        incompatible = []
        missing_scenarios = set(SCENARIOS) - set(baseline_scenarios)
        if missing_scenarios - set(selected_scenarios):
            incompatible.append("the existing baseline is missing untouched scenarios")
        if baseline.get("machine", {}).get("node") != report["machine"]["node"]:
            incompatible.append("machine")
        if (baseline.get("machine", {}).get("fixture_sha256")
                != report["machine"]["fixture_sha256"]):
            incompatible.append("fixture")
        if baseline.get("frames") != frames or baseline.get("warmup_frames") != warmup_frames:
            incompatible.append("frame counts")
        if any(
            baseline_scenarios.get(name, {}).get("settings") != SCENARIOS[name]
            for name in untouched_scenarios
        ):
            incompatible.append("untouched scenario settings")
        if incompatible:
            parser.error(
                "partial baseline update is incompatible with the existing baseline: "
                + ", ".join(incompatible)
            )

    for scenario in selected_scenarios:
        settings = SCENARIOS[scenario]
        print(f"[{scenario}] throughput runs: {runs} minimum", flush=True)
        throughput_runs = []
        while True:
            index = len(throughput_runs) + 1
            case = run_case(
                exe=exe, work=work, user=user / f"{scenario}-throughput-{index}",
                fixture=fixture, tab_dir=tab_dir, scenario=scenario, settings=settings,
                mode="throughput", run_dir=run_root / scenario / f"throughput-{index}",
                frames=frames, warmup_frames=warmup_frames, screenshot=False,
            )
            throughput_runs.append(case)
            print(f"  run {index}: {case['active_fps']:.1f} fps", flush=True)
            if len(throughput_runs) < runs:
                continue
            noise = relative_mad([item["active_fps"] for item in throughput_runs])
            if noise <= 0.06 or len(throughput_runs) >= args.max_runs:
                break
            print(f"  throughput noise {noise:.1%}; automatically adding a repetition", flush=True)

        print(f"[{scenario}] metrics runs: {metrics_runs}", flush=True)
        metric_runs = []
        visual_run: dict[str, Any] | None = None
        for index in range(1, metrics_runs + 1):
            take_screenshot = (
                index == metrics_runs and settings["visual"] and not args.no_visual
            )
            case = run_case(
                exe=exe, work=work, user=user / f"{scenario}-metrics-{index}",
                fixture=fixture, tab_dir=tab_dir, scenario=scenario, settings=settings,
                mode="metrics", run_dir=run_root / scenario / f"metrics-{index}",
                frames=frames, warmup_frames=warmup_frames,
                screenshot=take_screenshot,
            )
            metric_runs.append(case)
            if take_screenshot:
                visual_run = case
            print(
                f"  run {index}: frame p50={case['metrics']['frame_ms_p50']:.3f}ms "
                f"p95={case['metrics']['frame_ms_p95']:.3f}ms",
                flush=True,
            )

        scenario_report = {
            "active_fps": statistics.median(item["active_fps"] for item in throughput_runs),
            "active_fps_runs": [item["active_fps"] for item in throughput_runs],
            "metrics_active_fps": statistics.median(item["active_fps"] for item in metric_runs),
            "metrics": median_metric_summaries([item["metrics"] for item in metric_runs]),
            "throughput_runs": throughput_runs,
            "metric_runs": metric_runs,
            "settings": settings,
        }
        scenario_report["throughput_relative_mad"] = relative_mad(
            scenario_report["active_fps_runs"]
        )
        scenario_report["throughput_relative_spread"] = relative_spread(
            scenario_report["active_fps_runs"]
        )
        scenario_report["throughput_stable"] = scenario_report["throughput_relative_mad"] <= 0.06
        if not scenario_report["throughput_stable"]:
            report["passed"] = False
        scenario_report["telemetry_overhead_fraction"] = (
            (scenario_report["active_fps"] - scenario_report["metrics_active_fps"])
            / scenario_report["active_fps"]
            if scenario_report["active_fps"] else 0.0
        )
        if settings.get("paced"):
            print(f"[{scenario}] present-paced runs: {paced_runs}", flush=True)
            paced_results = []
            for index in range(1, paced_runs + 1):
                case = run_case(
                    exe=exe, work=work, user=user / f"{scenario}-paced-{index}",
                    fixture=fixture, tab_dir=tab_dir, scenario=scenario, settings=settings,
                    mode="paced-metrics", run_dir=run_root / scenario / f"paced-{index}",
                    frames=frames, warmup_frames=warmup_frames, screenshot=False,
                )
                paced_results.append(case)
                print(
                    f"  run {index}: {case['active_fps']:.1f} fps, "
                    f"interval p95={case['metrics']['interval_ms_p95']:.3f}ms",
                    flush=True,
                )
            scenario_report["paced"] = {
                "active_fps": statistics.median(item["active_fps"] for item in paced_results),
                "active_fps_runs": [item["active_fps"] for item in paced_results],
                "target_fps": statistics.median(item["target_fps"] for item in paced_results),
                "metrics": median_metric_summaries([item["metrics"] for item in paced_results]),
                "runs": paced_results,
            }
            scenario_report["paced"]["target_attainment"] = (
                scenario_report["paced"]["active_fps"]
                / scenario_report["paced"]["target_fps"]
                if scenario_report["paced"]["target_fps"] else 0.0
            )
        if visual_run:
            current = Path(visual_run["screenshot"])
            golden = GOLDEN_ROOT / f"{scenario}-d3d11.png"
            if args.update_goldens:
                scenario_report["visual"] = {
                    "status": "pending_update",
                    "golden": str(golden), "current": str(current),
                }
            elif not golden.exists():
                scenario_report["visual"] = {
                    "status": "missing",
                    "golden": str(golden), "current": str(current),
                }
                report["passed"] = False
            else:
                diff_path = Path(visual_run["run_dir"]) / "visual_diff.json"
                diff = compare_image(golden, current, diff_path)
                passed = bool(diff["visual_pass"])
                scenario_report["visual"] = {
                    "status": "pass" if passed else "regression",
                    "golden": str(golden), "current": str(current), "diff": diff,
                }
                if not passed:
                    report["passed"] = False
        report["scenarios"][scenario] = scenario_report

    report["inconclusive"] = any(
        not scenario.get("throughput_stable", True)
        for scenario in report["scenarios"].values()
    )

    if baseline and not args.update_baseline:
        same_machine = baseline.get("machine", {}).get("node") == report["machine"]["node"]
        same_fixture = (
            baseline.get("machine", {}).get("fixture_sha256")
            == report["machine"]["fixture_sha256"]
        )
        same_frame_counts = (
            baseline.get("frames") == report["frames"]
            and baseline.get("warmup_frames") == report["warmup_frames"]
        )
        same_scenario_settings = all(
            baseline.get("scenarios", {}).get(name, {}).get("settings")
            == scenario.get("settings")
            for name, scenario in report["scenarios"].items()
        )
        same_workload = same_frame_counts and same_scenario_settings
        report["baseline_compatibility"] = {
            "same_machine": same_machine,
            "same_fixture": same_fixture,
            "same_frame_counts": same_frame_counts,
            "same_scenario_settings": same_scenario_settings,
            "same_workload": same_workload,
        }
        findings = (
            compare_performance(report, baseline)
            if same_machine and same_fixture and same_workload else []
        )
        report["performance_findings"] = findings
        if (not same_machine or not same_fixture or not same_workload
                or any(item["status"] in ("regression", "missing", "inconclusive")
                       for item in findings)):
            report["passed"] = False
    else:
        report["performance_findings"] = []
        report["baseline_status"] = "updated" if args.update_baseline else "missing"
        if not args.update_baseline:
            report["passed"] = False

    if args.update_goldens:
        for scenario in report["scenarios"].values():
            visual = scenario.get("visual")
            if not visual or visual.get("status") != "pending_update":
                continue
            if report["passed"]:
                golden = Path(visual["golden"])
                golden.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(Path(visual["current"]), golden)
                visual["status"] = "updated"
            else:
                visual["status"] = "not_updated"

    report_path = run_root / "report.json"
    report_md_path = run_root / "report.md"
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    report_md_path.write_text(markdown_report(report), encoding="utf-8")

    if args.update_baseline and report["passed"]:
        args.baseline.parent.mkdir(parents=True, exist_ok=True)
        baseline_document = {
            "schema": report["schema"],
            "created": run_id,
            "machine": report["machine"],
            "repository": {
                "revision": report["repository"]["revision"],
                "dirty": report["repository"]["dirty"],
            },
            "suite": report["suite"],
            "runs": runs,
            "metrics_runs": metrics_runs,
            "paced_runs": paced_runs,
            "frames": frames,
            "warmup_frames": warmup_frames,
            "scenarios": {
                name: {
                    "active_fps": item["active_fps"],
                    "active_fps_runs": item["active_fps_runs"],
                    "metrics_active_fps": item["metrics_active_fps"],
                    "telemetry_overhead_fraction": item["telemetry_overhead_fraction"],
                    "paced": ({
                        "active_fps": item["paced"]["active_fps"],
                        "active_fps_runs": item["paced"]["active_fps_runs"],
                        "target_fps": item["paced"]["target_fps"],
                        "target_attainment": item["paced"]["target_attainment"],
                        "metrics": item["paced"]["metrics"],
                    } if item.get("paced") else None),
                    "metrics": item["metrics"],
                    "settings": item["settings"],
                }
                for name, item in report["scenarios"].items()
            },
        }
        if partial_baseline_update and baseline:
            merged = dict(baseline.get("scenarios", {}))
            merged.update(baseline_document["scenarios"])
            baseline_document["scenarios"] = merged
            for key in ("suite", "runs", "metrics_runs", "paced_runs"):
                baseline_document[key] = baseline.get(key, baseline_document[key])
        args.baseline.write_text(json.dumps(baseline_document, indent=2), encoding="utf-8")
        print(f"Updated performance baseline: {args.baseline}")
    elif args.update_baseline:
        print("Performance baseline was not updated because the gate was not stable and passing.")

    print(report_md_path.read_text(encoding="utf-8"))
    print(f"JSON report: {report_path}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    lock_stream = None
    try:
        RESULTS_ROOT.parent.mkdir(parents=True, exist_ok=True)
        lock_path = RESULTS_ROOT.parent / "render-gate.lock"
        lock_stream = lock_path.open("a+b")
        lock_stream.seek(0)
        if lock_stream.tell() == 0:
            lock_stream.write(b"0")
            lock_stream.flush()
        lock_stream.seek(0)
        try:
            msvcrt.locking(lock_stream.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError as exc:
            raise RuntimeError("another render performance gate is already running") from exc
        raise SystemExit(main())
    except Exception as exc:
        print(f"render performance gate failed: {exc}", file=sys.stderr)
        raise SystemExit(2)
    finally:
        if lock_stream is not None:
            try:
                lock_stream.seek(0)
                msvcrt.locking(lock_stream.fileno(), msvcrt.LK_UNLCK, 1)
            except OSError:
                pass
            lock_stream.close()
