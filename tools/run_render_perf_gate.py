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
import math
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys
import time
from typing import Any, Iterable

try:
    import msvcrt
except ImportError:  # Unit-testable metric/specimen helpers on non-Windows hosts.
    msvcrt = None  # type: ignore[assignment]

try:
    from PIL import Image
except ImportError:  # The non-visual harness remains usable without Pillow.
    Image = None  # type: ignore[assignment]

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
    "font-raster-correctness": {
        "start_line": 1,
        "window_width": 1400,
        "window_height": 1400,
        "visual": True,
        "paced": False,
        # This limit is a continuity limit. It does not lock one theme color.
        "seam_channel_threshold": 12,
        "directwrite_reference": {
            "source": "recorded Edge comparison; not repeated by this gate",
            "continuous_at_ppem": [15, 16, 18, 24],
            "first_stable_stroke_ppem": 15,
        },
    },
}

STANDARD_SCENARIOS = tuple(SCENARIOS)
SPECIMEN_SCENARIOS: dict[str, dict[str, Any]] = {
    "specimen-startup": {
        "fixture": "external",
        "start_line": 1,
        "window_width": 1400,
        "window_height": 900,
        "visual": True,
        "paced": False,
    },
    "specimen-scroll": {
        "fixture": "external",
        "start_line": 1,
        "scroll_lines": 1,
        "window_width": 1400,
        "window_height": 900,
        "visual": True,
        "paced": True,
    },
    "specimen-caret-repeat": {
        "fixture": "external",
        "start_line": 1,
        "window_width": 1400,
        "window_height": 900,
        "visual": True,
        "paced": True,
    },
    "specimen-soak": {
        "fixture": "external",
        "start_line": 1,
        "window_width": 1400,
        "window_height": 900,
        "visual": True,
        "paced": True,
    },
}
SCENARIOS.update(SPECIMEN_SCENARIOS)

SUITES = {
    "quick": ["wrapped-document-steady", "wrapped-document-scroll", "tab-heavy-titlebar"],
    "full": list(STANDARD_SCENARIOS),
    "visual": [name for name in STANDARD_SCENARIOS if SCENARIOS[name]["visual"]],
    "specimen": list(SPECIMEN_SCENARIOS),
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
    "paced_interval_ms_max": (0.20, 2.0),
    "paced_interval_over_33_33_fraction": (0.25, 0.01),
    "startup_total_ms": (0.10, 20.0),
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


def read_font_raster_metadata(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        raise RuntimeError(f"font raster metadata missing: {path}")
    with path.open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream))
    numeric_float = {"origin_x", "text_top", "baseline", "requested_size", "advance"}
    numeric_int = {
        "run_length", "background_r", "background_g", "background_b",
        "foreground_r", "foreground_g", "foreground_b",
        "assert_continuity",
    }
    for row in rows:
        for key in numeric_float:
            row[key] = float(row[key])
        for key in numeric_int:
            row[key] = int(row[key])
    return rows


def analyze_font_raster_seams(
    screenshot: Path, fixtures: list[dict[str, Any]], threshold: int,
) -> dict[str, Any]:
    """Measure connected-line continuity without requiring exact pixels."""
    if Image is None:
        raise RuntimeError("Pillow is required for font raster seam analysis")
    image = Image.open(screenshot).convert("RGB")
    width, height = image.size
    analyses: list[dict[str, Any]] = []
    failures: list[dict[str, Any]] = []

    for fixture in fixtures:
        if fixture.get("kind") != "connected-line":
            continue
        origin = float(fixture["origin_x"])
        advance = float(fixture["advance"])
        run_length = int(fixture["run_length"])
        background = tuple(int(fixture[f"background_{channel}"]) for channel in "rgb")
        top = max(0, int(float(fixture["text_top"]) - 2))
        bottom = min(height, int(float(fixture["baseline"]) + float(fixture["requested_size"]) * 0.5 + 3))
        first_x = max(0, int(origin + advance))
        last_x = min(width - 1, int(origin + advance * (run_length - 1)))
        if last_x <= first_x or bottom <= top:
            raise RuntimeError(f"invalid font raster fixture geometry: {fixture}")

        stroke_rows = []
        for y in range(top, bottom):
            covered = 0
            for x in range(first_x, last_x + 1):
                pixel = image.getpixel((x, y))
                if max(abs(pixel[channel] - background[channel]) for channel in range(3)) > 4:
                    covered += 1
            if covered >= max(2, int((last_x - first_x + 1) * 0.75)):
                stroke_rows.append(y)

        row_results = []
        for y in stroke_rows:
            boundary_differences = []
            boundary_pixels = []
            control_pixels = []
            for index in range(2, run_length - 2):
                boundary_x = min(width - 1, max(0, int(math.floor(origin + index * advance + 0.5))))
                control_x = min(width - 1, max(0, int(math.floor(origin + (index + 0.5) * advance + 0.5))))
                boundary = image.getpixel((boundary_x, y))
                control = image.getpixel((control_x, y))
                boundary_pixels.append(boundary)
                control_pixels.append(control)
                boundary_differences.append(max(
                    abs(boundary[channel] - control[channel]) for channel in range(3)
                ))
            max_contrast = max(boundary_differences, default=0)
            shift = max(1, int(math.floor(advance + 0.5)))
            periodic_differences = []
            for x in range(first_x, last_x - shift + 1):
                first = image.getpixel((x, y))
                second = image.getpixel((x + shift, y))
                periodic_differences.append(sum(
                    abs(first[channel] - second[channel]) for channel in range(3)
                ) / 3.0)
            periodic_energy = (
                sum(periodic_differences) / len(periodic_differences)
                if periodic_differences else 0.0
            )
            row_result = {
                "y": y,
                "max_boundary_contrast": max_contrast,
                "periodic_energy": periodic_energy,
                "boundary_channel_range": [
                    min((pixel[channel] for pixel in boundary_pixels), default=0)
                    for channel in range(3)
                ] + [
                    max((pixel[channel] for pixel in boundary_pixels), default=0)
                    for channel in range(3)
                ],
            }
            row_results.append(row_result)
        asserted = bool(int(fixture.get("assert_continuity", 1)))
        analysis = {
            "fixture": fixture["id"],
            "renderer": fixture.get("renderer", ""),
            "asserted": asserted,
            "stroke_rows": row_results,
            "max_boundary_contrast": max(
                (row["max_boundary_contrast"] for row in row_results), default=0
            ),
            "passed": bool(row_results) and all(
                row["max_boundary_contrast"] <= threshold for row in row_results
            ),
        }
        if not row_results and asserted:
            failures.append({"fixture": fixture["id"], "error": "no stroke rows found"})
        elif asserted:
            for row in row_results:
                if row["max_boundary_contrast"] > threshold:
                    failures.append({
                        "fixture": fixture["id"], "row": row["y"],
                        "max_boundary_contrast": row["max_boundary_contrast"],
                    })
        analyses.append(analysis)

    stable_sizes = []
    for requested_size in sorted({
        int(float(fixture["requested_size"]))
        for fixture in fixtures
        if str(fixture.get("id", "")).startswith("size-")
    }):
        size_results = [
            analysis for analysis in analyses
            if analysis["fixture"].startswith(f"size-{requested_size}-")
        ]
        if len(size_results) >= 2 and all(result["passed"] for result in size_results):
            stable_sizes.append(requested_size)

    return {
        "threshold": threshold,
        "passed": bool(analyses) and not failures,
        "first_stable_stroke_ppem": min(stable_sizes) if stable_sizes else None,
        "fixtures": analyses,
        "failures": failures,
    }


def copy_external_specimen(source: Path, destination: Path) -> tuple[Path, dict[str, Any]]:
    """Copy a private specimen into an isolated run without retaining its path."""
    source = source.expanduser().resolve()
    if not source.is_file():
        raise RuntimeError(f"specimen is not a regular file: {source}")
    destination.mkdir(parents=True, exist_ok=True)
    suffix = source.suffix.lower()
    if not suffix or len(suffix) > 16:
        suffix = ".txt"
    copied = destination / f"specimen{suffix}"
    shutil.copy2(source, copied)

    byte_count = 0
    line_count = 0
    max_line_bytes = 0
    with copied.open("rb") as stream:
        for line in stream:
            byte_count += len(line)
            line_count += 1
            logical = line[:-1] if line.endswith(b"\n") else line
            if logical.endswith(b"\r"):
                logical = logical[:-1]
            max_line_bytes = max(max_line_bytes, len(logical))
    metadata = {
        "sha256": sha256(copied),
        "bytes": byte_count,
        "lines": line_count,
        "max_line_bytes": max_line_bytes,
        "extension": suffix,
    }
    return copied, metadata


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


def longest_run_over(values: Iterable[float], threshold: float) -> int:
    longest = current = 0
    for value in values:
        if value > threshold:
            current += 1
            longest = max(longest, current)
        else:
            current = 0
    return longest


def progression_slope(values: list[float]) -> float:
    """Return the least-squares per-sample slope without duplicating the workload."""
    count = len(values)
    if count < 2:
        return 0.0
    mean_x = (count - 1) / 2
    mean_y = statistics.fmean(values)
    numerator = sum((index - mean_x) * (value - mean_y) for index, value in enumerate(values))
    denominator = sum((index - mean_x) ** 2 for index in range(count))
    return numerator / denominator if denominator else 0.0


def add_progression_metrics(result: dict[str, float], key: str, values: list[float]) -> None:
    if not values:
        return
    quarter = max(1, len(values) // 4)
    result[f"{key}_max"] = max(values)
    result[f"{key}_first_quarter_avg"] = statistics.fmean(values[:quarter])
    result[f"{key}_last_quarter_avg"] = statistics.fmean(values[-quarter:])
    result[f"{key}_progression_slope"] = progression_slope(values)
    window = min(60, len(values))
    rolling_p95 = [
        percentile(values[start:start + window], 0.95)
        for start in range(0, len(values) - window + 1)
    ]
    result[f"{key}_rolling_p95_max"] = max(rolling_p95 or [percentile(values, 0.95)])


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
        "repeated_batch_srvs", "texture_uploads", "rencache_commands", "rencache_text_commands",
        "rencache_command_bytes", "display_packet_replays",
        "display_packet_commands_replayed", "display_packet_frame_bytes_copied",
        "display_packet_replay_ms", "text_render_calls", "text_render_glyphs",
        "text_render_hb_shape_ms", "lua_heap_kib",
    ):
        vals = numbers(key)
        result[f"{key}_avg"] = statistics.fmean(vals)
        result[f"{key}_p50"] = percentile(vals, 0.50)
        result[f"{key}_p95"] = percentile(vals, 0.95)
        result[f"{key}_p99"] = percentile(vals, 0.99)
        if key == "texture_uploads":
            result["texture_uploads_max"] = max(vals)
        if key.endswith("_ms") or key.endswith("_kib"):
            add_progression_metrics(result, key, vals)
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
        for label, threshold in (
            ("16_67", 16.67), ("33_33", 33.33), ("50", 50.0),
            ("100", 100.0), ("250", 250.0),
        ):
            count = sum(value > threshold for value in intervals)
            result[f"interval_over_{label}_count"] = float(count)
            result[f"interval_over_{label}_fraction"] = count / len(intervals)
        result["interval_longest_over_16_67_run"] = float(longest_run_over(intervals, 16.67))
        add_progression_metrics(result, "interval_ms", intervals)
    return result


def parse_launcher_output(output: str) -> dict[str, Any]:
    for line in reversed(output.splitlines()):
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and "exit_code" in value:
            value["raw_output"] = output
            return value
    raise RuntimeError(f"hidden desktop launcher produced no structured result: {output!r}")


def classify_case_failure(
    launcher: dict[str, Any], heartbeat: dict[str, str] | None = None,
) -> dict[str, Any]:
    heartbeat = heartbeat or {}
    reason = str(launcher.get("termination_reason") or "")
    timed_out = bool(launcher.get("timed_out")) or int(launcher.get("exit_code", 0)) == 124
    if timed_out and not reason:
        reason = "wall_timeout"
    return {
        "status": "timeout" if timed_out else "failed",
        "failure_kind": reason or "process_exit",
        "exit_code": int(launcher.get("exit_code", -1)),
        "last_phase": str(launcher.get("last_phase") or heartbeat.get("phase") or "not_started"),
        "elapsed_ms": float(launcher.get("elapsed_ms") or 0),
        "process_tree_terminated": bool(launcher.get("process_tree_terminated", False)),
        "performance_penalty": "infinite" if timed_out else "invalid",
        "launcher": launcher,
    }


def read_lifecycle(path: Path) -> dict[str, float]:
    if not path.exists():
        return {}
    milestones: dict[str, float] = {}
    with path.open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream):
            name = str(row.get("milestone") or "").strip()
            if name:
                milestones[f"{name}_ms"] = float(row.get("elapsed_ms") or 0)
    return milestones


def summarize_resource_samples(path: Path) -> dict[str, float]:
    if not path.exists():
        return {}
    with path.open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream))
    if not rows:
        return {}
    working_set = [float(row.get("working_set_bytes") or 0) for row in rows]
    private_bytes = [float(row.get("private_bytes") or 0) for row in rows]
    result = {
        "samples": float(len(rows)),
        "working_set_peak_bytes": max(working_set),
        "working_set_growth": working_set[-1] - working_set[0],
        "working_set_progression_slope": progression_slope(working_set),
        "private_bytes_peak_bytes": max(private_bytes),
        "private_bytes_growth": private_bytes[-1] - private_bytes[0],
        "private_bytes_progression_slope": progression_slope(private_bytes),
    }
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


def invoke_hidden(config_path: Path, timeout_seconds: int) -> dict[str, Any]:
    command = [
        "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", str(HIDDEN_LAUNCHER), "-Config", str(config_path),
        "-TimeoutSeconds", str(timeout_seconds),
    ]
    try:
        completed = run(command, timeout=timeout_seconds + 20, check=False)
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout or ""
        if isinstance(output, bytes):
            output = output.decode("utf-8", errors="replace")
        return {
            "exit_code": 124,
            "timed_out": True,
            "termination_reason": "launcher_timeout",
            "last_phase": "unknown",
            "elapsed_ms": float((timeout_seconds + 20) * 1000),
            "process_tree_terminated": True,
            "raw_output": output,
        }
    result = parse_launcher_output(completed.stdout.strip())
    result["launcher_exit_code"] = completed.returncode
    return result


class BenchmarkCaseError(RuntimeError):
    def __init__(self, message: str, details: dict[str, Any]):
        super().__init__(message)
        self.details = details


def run_case(
    *, exe: Path, work: Path, user: Path, fixture: Path, tab_dir: Path,
    external_fixture: Path | None = None,
    scenario: str, settings: dict[str, Any], mode: str, run_dir: Path,
    renderer: str,
    frames: int, warmup_frames: int, screenshot: bool,
    total_timeout_seconds: int | None = None, startup_timeout_seconds: int = 30,
    heartbeat_timeout_seconds: int = 15,
) -> dict[str, Any]:
    run_dir.mkdir(parents=True)
    result_file = run_dir / "result.txt"
    metrics_file = run_dir / "metrics.csv"
    heartbeat_file = run_dir / "heartbeat.txt"
    lifecycle_file = run_dir / "lifecycle.csv"
    resource_samples_file = run_dir / "resources.csv"
    timeout_dump_file = run_dir / "timeout.dmp"
    screenshot_file = run_dir / "screenshot.png"
    raster_metadata_file = run_dir / "font-raster-metadata.csv"
    case_fixture = (
        work / "fixtures" / "markdown-long-link.md"
        if settings.get("fixture") == "markdown-long-link" else fixture
    )
    if settings.get("fixture") == "external":
        if not external_fixture:
            raise RuntimeError(f"scenario {scenario} requires an external specimen")
        case_fixture = external_fixture
    environment = {
        "ANVIL_USERDIR": str(user),
        "USERPROFILE": str(user),
        "ANVIL_RENDERER": renderer,
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
        "ANVIL_PERF_BENCHMARK_HEARTBEAT": str(heartbeat_file),
        "ANVIL_PERF_BENCHMARK_LIFECYCLE": str(lifecycle_file),
        "ANVIL_PERF_BENCHMARK_SCREENSHOT": str(screenshot_file) if screenshot else "",
        "ANVIL_PERF_BENCHMARK_RASTER_METADATA": str(raster_metadata_file),
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
        "heartbeat_path": str(heartbeat_file),
        "resource_samples_path": str(resource_samples_file),
        "timeout_dump_path": str(timeout_dump_file),
        "startup_timeout_seconds": startup_timeout_seconds,
        "heartbeat_timeout_seconds": heartbeat_timeout_seconds,
    }
    config_path = run_dir / "launch.json"
    config_path.write_text(json.dumps(launch_config, indent=2), encoding="utf-8")
    timeout_seconds = total_timeout_seconds or max(90, int((frames + warmup_frames) / 20) + 60)
    launcher = invoke_hidden(config_path, timeout_seconds)
    values = read_key_values(result_file)
    heartbeat = read_key_values(heartbeat_file)
    if launcher.get("timed_out") or int(launcher.get("exit_code", 0)) != 0:
        failure = classify_case_failure(launcher, heartbeat)
        failure.update({"scenario": scenario, "mode": mode, "run_dir": str(run_dir)})
        raise BenchmarkCaseError(
            f"benchmark {failure['status']}: scenario={scenario} mode={mode} "
            f"kind={failure['failure_kind']} phase={failure['last_phase']}",
            failure,
        )
    if values.get("done") != "1":
        failure = classify_case_failure(launcher, heartbeat)
        failure.update({
            "scenario": scenario, "mode": mode, "run_dir": str(run_dir),
            "failure_kind": "benchmark_error",
            "error": values.get("error", "missing result"),
        })
        raise BenchmarkCaseError(
            f"benchmark failed: scenario={scenario} mode={mode} "
            f"error={values.get('error', 'missing result')}",
            failure,
        )
    result: dict[str, Any] = {
        "scenario": scenario,
        "renderer": renderer,
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
        "status": "passed",
        "launcher": launcher,
        "lifecycle": read_lifecycle(lifecycle_file),
        "resources": summarize_resource_samples(resource_samples_file),
        "heartbeat": heartbeat,
        "launch_to_plugin_loaded_ms": float(launcher.get("first_heartbeat_ms") or 0),
        "peak_working_set_bytes": float(launcher.get("peak_working_set_bytes") or 0),
        "peak_private_bytes": float(launcher.get("peak_private_bytes") or 0),
        "state_settle": {
            "frames": int(float(values.get("state_settle_frames", 0))),
            "max_frames": int(float(values.get("state_settle_max_frames", 0))),
            "scroll_to_x": float(values.get("scroll_to_x", 0)),
            "scroll_to_y": float(values.get("scroll_to_y", 0)),
        },
        "state": {
            "doc_lines": int(values.get("doc_lines", 0)),
            "wrapped_rows": int(values.get("wrapped_rows", 0)),
            "text_revision": int(values.get("text_revision", 0)),
            "selection_line": int(values.get("selection_line", 0)),
            "selection_col": int(values.get("selection_col", 0)),
            "scroll_x": float(values.get("scroll_x", 0)),
            "scroll_y": float(values.get("scroll_y", 0)),
        },
    }
    if result["measured_frames"] != frames:
        raise RuntimeError(f"workload mismatch: expected {frames}, got {result['measured_frames']}")
    if renderer == "d3d11" and result["renderer_path"] != "commands":
        raise RuntimeError(f"expected D3D11 command renderer, got {result['renderer_path']!r}")
    if renderer == "software" and result["renderer_path"] == "commands":
        raise RuntimeError("software benchmark unexpectedly used the D3D11 command renderer")
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
        if scenario == "font-raster-correctness":
            fixtures = read_font_raster_metadata(raster_metadata_file)
            result["font_raster"] = analyze_font_raster_seams(
                screenshot_file, fixtures, int(settings["seam_channel_threshold"]),
            )
            reference_ppem = int(
                settings["directwrite_reference"]["first_stable_stroke_ppem"]
            )
            stable_ppem = result["font_raster"]["first_stable_stroke_ppem"]
            if stable_ppem is None or stable_ppem > reference_ppem + 1:
                result["font_raster"]["passed"] = False
                result["font_raster"]["failures"].append({
                    "error": "stable stroke starts too late",
                    "anvil_ppem": stable_ppem,
                    "directwrite_ppem": reference_ppem,
                })
            if (renderer == "d3d11" and mode == "metrics"
                    and result["metrics"].get("texture_uploads_max", 0) > 0):
                result["font_raster"]["passed"] = False
                result["font_raster"]["failures"].append({
                    "error": "glyph texture uploads continued after warm-up",
                    "texture_uploads_max": result["metrics"]["texture_uploads_max"],
                })
            result["font_raster_metadata"] = str(raster_metadata_file)
    return result


def summarize_case_lifecycle(cases: list[dict[str, Any]]) -> dict[str, float]:
    lifecycle_rows = [case.get("lifecycle", {}) for case in cases if case.get("lifecycle")]
    if not lifecycle_rows:
        return {}
    lifecycle = median_metric_summaries(lifecycle_rows)
    launch_to_plugin = statistics.median(
        float(case.get("launch_to_plugin_loaded_ms") or 0) for case in cases
    )
    lifecycle["launch_to_plugin_loaded_ms"] = launch_to_plugin
    if "first_ready_frame_ms" in lifecycle:
        lifecycle["startup_total_ms"] = launch_to_plugin + lifecycle["first_ready_frame_ms"]
    return lifecycle


def states_consistent(states: Iterable[dict[str, Any] | None]) -> bool:
    """Require every captured observable state to match exactly."""
    captured = list(states)
    return bool(captured) and all(state == captured[0] for state in captured)


def run_case_safely(**kwargs: Any) -> dict[str, Any]:
    try:
        return run_case(**kwargs)
    except BenchmarkCaseError as exc:
        return exc.details
    except Exception as exc:
        run_dir = Path(kwargs.get("run_dir", ""))
        heartbeat = read_key_values(run_dir / "heartbeat.txt") if run_dir else {}
        return {
            "status": "failed",
            "failure_kind": "harness_error",
            "error": str(exc),
            "scenario": str(kwargs.get("scenario", "unknown")),
            "mode": str(kwargs.get("mode", "unknown")),
            "run_dir": str(run_dir),
            "last_phase": heartbeat.get("phase", "unknown"),
            "heartbeat": heartbeat,
            "lifecycle": read_lifecycle(run_dir / "lifecycle.csv") if run_dir else {},
            "resources": summarize_resource_samples(run_dir / "resources.csv") if run_dir else {},
            "performance_penalty": "invalid",
        }


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
        if now.get("status") != "passed":
            findings.append({
                "scenario": scenario,
                "metric": "reliability",
                "status": "regression",
                "current": 1.0,
                "baseline": 0.0,
                "relative_change": 1.0,
            })
            continue
        before = baseline.get("scenarios", {}).get(scenario)
        if not before:
            findings.append({"scenario": scenario, "metric": "baseline", "status": "missing"})
            continue
        if before.get("state") is not None and now.get("state") != before.get("state"):
            findings.append({
                "scenario": scenario,
                "metric": "observable_state",
                "status": "regression",
                "current": 1.0,
                "baseline": 0.0,
                "relative_change": 1.0,
                "current_state": now.get("state"),
                "baseline_state": before.get("state"),
            })
        pairs = {"active_fps": (now["active_fps"], before["active_fps"])}
        if now.get("paced") and before.get("paced"):
            pairs["paced_active_fps"] = (
                now["paced"]["active_fps"], before["paced"]["active_fps"]
            )
            pairs["paced_interval_ms_p95"] = (
                now["paced"]["metrics"]["interval_ms_p95"],
                before["paced"]["metrics"]["interval_ms_p95"],
            )
            pairs["paced_interval_ms_max"] = (
                now["paced"]["metrics"].get("interval_ms_max", 0),
                before["paced"]["metrics"].get("interval_ms_max", 0),
            )
            pairs["paced_interval_over_33_33_fraction"] = (
                now["paced"]["metrics"].get("interval_over_33_33_fraction", 0),
                before["paced"]["metrics"].get("interval_over_33_33_fraction", 0),
            )
        if now.get("lifecycle") and before.get("lifecycle"):
            pairs["startup_total_ms"] = (
                now["lifecycle"].get("startup_total_ms", 0),
                before["lifecycle"].get("startup_total_ms", 0),
            )
        for metric in LOWER_IS_BETTER:
            if metric in now["metrics"] and metric in before.get("metrics", {}):
                pairs[metric] = (now["metrics"][metric], before["metrics"][metric])
        for metric in HIGHER_IS_BETTER:
            if metric != "active_fps" and metric in now["metrics"] and metric in before.get("metrics", {}):
                pairs[metric] = (now["metrics"][metric], before["metrics"][metric])
        for metric, (value, reference) in pairs.items():
            relative = (
                (value - reference) / reference if reference
                else 1.0 if value > 0
                else -1.0 if value < 0
                else 0.0
            )
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
        f"- Renderer: `{report.get('renderer', 'd3d11')}`",
        f"- Result: **{verdict}**",
        f"- Run directory: `{report['run_dir']}`",
        "",
        "| Scenario | Active FPS | Paced FPS | Startup ready | Metrics tax | Frame p50 | Frame p95 | Frame max | >33ms | Draw p50 | Renderer p50 | Visual |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|",
    ]
    for name, scenario in report["scenarios"].items():
        if scenario.get("status") != "passed":
            failures = scenario.get("failures", [])
            detail = failures[0] if failures else scenario
            lines.append(
                f"| {name} | FAIL | FAIL | FAIL | n/a | n/a | n/a | n/a | n/a | n/a | n/a | "
                f"{detail.get('failure_kind', 'failed')} ({detail.get('last_phase', 'unknown')}) |"
            )
            continue
        metrics = scenario["metrics"]
        visual = scenario.get("visual", {}).get("status", "n/a")
        lines.append(
            f"| {name} | {scenario['active_fps']:.1f} | "
            f"{scenario.get('paced', {}).get('active_fps', 0):.1f} | "
            f"{scenario.get('lifecycle', {}).get('startup_total_ms', 0):.1f} ms | "
            f"{scenario['telemetry_overhead_fraction']:.1%} | "
            f"{metrics['frame_ms_p50']:.3f} | "
            f"{metrics['frame_ms_p95']:.3f} | {metrics.get('frame_ms_max', 0):.3f} | "
            f"{metrics.get('interval_over_33_33_count', 0):.0f} | "
            f"{metrics['draw_emit_ms_p50']:.3f} | "
            f"{metrics['renderer_end_ms_p50']:.3f} | {visual} |"
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
    parser.add_argument("--renderer", choices=("d3d11", "software"), default="d3d11")
    parser.add_argument("--runs", type=int)
    parser.add_argument("--metrics-runs", type=int)
    parser.add_argument("--paced-runs", type=int)
    parser.add_argument("--max-runs", type=int, default=9)
    parser.add_argument("--frames", type=int)
    parser.add_argument("--warmup-frames", type=int)
    parser.add_argument("--timeout-seconds", type=int,
                        help="hard wall-clock deadline for each benchmark process")
    parser.add_argument("--startup-timeout-seconds", type=int, default=30,
                        help="deadline for the first in-app heartbeat")
    parser.add_argument("--heartbeat-timeout-seconds", type=int, default=15,
                        help="terminate when an in-app heartbeat stops advancing")
    parser.add_argument("--user-state-mode", choices=("clean", "reuse"), default="clean",
                        help="fresh USERDIR per process or reuse it across repetitions")
    parser.add_argument("--specimen", type=Path,
                        help="private local file copied into the isolated run; its path is not reported")
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--golden-root", type=Path)
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
    if ((args.timeout_seconds is not None and args.timeout_seconds < 1)
            or args.startup_timeout_seconds < 1 or args.heartbeat_timeout_seconds < 1):
        parser.error("watchdog timeouts must be positive")
    if args.max_runs < runs:
        parser.error("--max-runs must be greater than or equal to --runs")

    selected_scenarios = [args.scenario] if args.scenario else SUITES[args.suite]
    suite_label = f"scenario:{args.scenario}" if args.scenario else args.suite
    specimen_selected = any(name in SPECIMEN_SCENARIOS for name in selected_scenarios)
    if specimen_selected and not args.specimen:
        parser.error("specimen scenarios require --specimen PATH")
    if args.specimen and not specimen_selected:
        parser.error("--specimen is only valid with --suite specimen or a specimen scenario")
    specimen_source = args.specimen.expanduser().resolve() if args.specimen else None
    if specimen_source and not specimen_source.is_file():
        parser.error(f"specimen is not a regular file: {specimen_source}")
    specimen_digest = sha256(specimen_source) if specimen_source else None
    local_specimen_root = (
        RESULTS_ROOT / "specimen-baselines" / specimen_digest / args.user_state_mode
        if specimen_digest else None
    )
    args.baseline = args.baseline or (
        local_specimen_root / "render_perf.json" if local_specimen_root else BASELINE_PATH
    )
    golden_root = args.golden_root or (
        local_specimen_root / "goldens" if local_specimen_root else GOLDEN_ROOT
    )

    baseline = None
    if args.baseline.exists():
        baseline = json.loads(args.baseline.read_text(encoding="utf-8"))
    baseline_scenario_names = set(SPECIMEN_SCENARIOS if specimen_selected else STANDARD_SCENARIOS)
    partial_baseline_update = set(selected_scenarios) != baseline_scenario_names
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
    external_fixture = None
    specimen_metadata = None
    if specimen_source:
        external_fixture, specimen_metadata = copy_external_specimen(
            specimen_source, work / "private-specimen"
        )

    report: dict[str, Any] = {
        "schema": 2,
        "suite": suite_label,
        "run_id": run_id,
        "run_dir": str(run_root),
        "runs": runs,
        "metrics_runs": metrics_runs,
        "paced_runs": paced_runs,
        "frames": frames,
        "warmup_frames": warmup_frames,
        "user_state_mode": args.user_state_mode,
        "renderer": args.renderer,
        "machine": machine_info(exe, external_fixture or fixture),
        "specimen": specimen_metadata,
        "repository": repository_info(),
        "scenarios": {},
        "passed": True,
    }

    if args.update_baseline and partial_baseline_update:
        baseline_scenarios = baseline.get("scenarios", {})
        untouched_scenarios = set(baseline_scenarios) - set(selected_scenarios)
        incompatible = []
        missing_scenarios = baseline_scenario_names - set(baseline_scenarios)
        if missing_scenarios - set(selected_scenarios):
            incompatible.append("the existing baseline is missing untouched scenarios")
        if baseline.get("machine", {}).get("node") != report["machine"]["node"]:
            incompatible.append("machine")
        if (baseline.get("machine", {}).get("fixture_sha256")
                != report["machine"]["fixture_sha256"]):
            incompatible.append("fixture")
        if baseline.get("frames") != frames or baseline.get("warmup_frames") != warmup_frames:
            incompatible.append("frame counts")
        if baseline.get("user_state_mode", "clean") != args.user_state_mode:
            incompatible.append("user state mode")
        if baseline.get("renderer", "d3d11") != args.renderer:
            incompatible.append("renderer")
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
        case_watchdogs = {
            "total_timeout_seconds": args.timeout_seconds,
            "startup_timeout_seconds": args.startup_timeout_seconds,
            "heartbeat_timeout_seconds": args.heartbeat_timeout_seconds,
        }
        throughput_runs = []
        case_failures = []
        def case_user(mode: str, index: int) -> Path:
            if args.user_state_mode == "reuse":
                return user / f"{scenario}-reused"
            return user / f"{scenario}-{mode}-{index}"
        state_primer = None
        if args.user_state_mode == "reuse":
            print(f"[{scenario}] user-state primer", flush=True)
            state_primer = run_case_safely(
                exe=exe, work=work, user=case_user("primer", 0),
                fixture=fixture, external_fixture=external_fixture,
                tab_dir=tab_dir, scenario=scenario, settings=settings,
                renderer=args.renderer,
                mode="throughput", run_dir=run_root / scenario / "state-primer",
                frames=2, warmup_frames=1, screenshot=False,
                **case_watchdogs,
            )
            if state_primer.get("status") != "passed":
                report["scenarios"][scenario] = {
                    "status": "failed", "settings": settings,
                    "failures": [state_primer], "state_primer": state_primer,
                }
                report["passed"] = False
                print(
                    f"  primer: {state_primer.get('failure_kind', 'failed')} "
                    f"phase={state_primer.get('last_phase', 'unknown')}", flush=True,
                )
                continue
        print(f"[{scenario}] throughput runs: {runs} minimum", flush=True)
        while True:
            index = len(throughput_runs) + 1
            case = run_case_safely(
                exe=exe, work=work, user=case_user("throughput", index),
                fixture=fixture, external_fixture=external_fixture,
                tab_dir=tab_dir, scenario=scenario, settings=settings,
                renderer=args.renderer,
                mode="throughput", run_dir=run_root / scenario / f"throughput-{index}",
                frames=frames, warmup_frames=warmup_frames, screenshot=False,
                **case_watchdogs,
            )
            if case.get("status") != "passed":
                case_failures.append(case)
                print(
                    f"  run {index}: {case.get('failure_kind', 'failed')} "
                    f"phase={case.get('last_phase', 'unknown')}", flush=True,
                )
                break
            throughput_runs.append(case)
            print(f"  run {index}: {case['active_fps']:.1f} fps", flush=True)
            if len(throughput_runs) < runs:
                continue
            noise = relative_mad([item["active_fps"] for item in throughput_runs])
            if noise <= 0.06 or len(throughput_runs) >= args.max_runs:
                break
            print(f"  throughput noise {noise:.1%}; automatically adding a repetition", flush=True)

        if case_failures:
            report["scenarios"][scenario] = {
                "status": "failed", "settings": settings, "failures": case_failures,
                "throughput_runs": throughput_runs,
            }
            report["passed"] = False
            continue

        print(f"[{scenario}] metrics runs: {metrics_runs}", flush=True)
        metric_runs = []
        visual_run: dict[str, Any] | None = None
        for index in range(1, metrics_runs + 1):
            take_screenshot = (
                index == metrics_runs and settings["visual"] and not args.no_visual
            )
            case = run_case_safely(
                exe=exe, work=work, user=case_user("metrics", index),
                fixture=fixture, external_fixture=external_fixture,
                tab_dir=tab_dir, scenario=scenario, settings=settings,
                renderer=args.renderer,
                mode="metrics", run_dir=run_root / scenario / f"metrics-{index}",
                frames=frames, warmup_frames=warmup_frames,
                screenshot=take_screenshot,
                **case_watchdogs,
            )
            if case.get("status") != "passed":
                case_failures.append(case)
                print(
                    f"  run {index}: {case.get('failure_kind', 'failed')} "
                    f"phase={case.get('last_phase', 'unknown')}", flush=True,
                )
                break
            metric_runs.append(case)
            if take_screenshot:
                visual_run = case
            print(
                f"  run {index}: frame p50={case['metrics']['frame_ms_p50']:.3f}ms "
                f"p95={case['metrics']['frame_ms_p95']:.3f}ms",
                flush=True,
            )

        if case_failures:
            report["scenarios"][scenario] = {
                "status": "failed", "settings": settings, "failures": case_failures,
                "throughput_runs": throughput_runs, "metric_runs": metric_runs,
            }
            report["passed"] = False
            continue

        scenario_report = {
            "status": "passed",
            "active_fps": statistics.median(item["active_fps"] for item in throughput_runs),
            "active_fps_runs": [item["active_fps"] for item in throughput_runs],
            "metrics_active_fps": statistics.median(item["active_fps"] for item in metric_runs),
            "metrics": median_metric_summaries([item["metrics"] for item in metric_runs]),
            "throughput_runs": throughput_runs,
            "metric_runs": metric_runs,
            "settings": settings,
            "lifecycle": summarize_case_lifecycle(throughput_runs),
            "resources": median_metric_summaries([
                item.get("resources", {}) for item in throughput_runs if item.get("resources")
            ]),
            "state": throughput_runs[0].get("state"),
            "state_primer": state_primer,
        }
        states = [item.get("state") for item in throughput_runs + metric_runs]
        scenario_report["state_consistent"] = states_consistent(states)
        if not scenario_report["state_consistent"]:
            scenario_report["status"] = "failed"
            scenario_report["failures"] = [{
                "failure_kind": "state_instability",
                "last_phase": "finished",
                "states": states,
            }]
            report["scenarios"][scenario] = scenario_report
            report["passed"] = False
            continue
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
                case = run_case_safely(
                    exe=exe, work=work, user=case_user("paced", index),
                    fixture=fixture, external_fixture=external_fixture,
                    tab_dir=tab_dir, scenario=scenario, settings=settings,
                    renderer=args.renderer,
                    mode="paced-metrics", run_dir=run_root / scenario / f"paced-{index}",
                    frames=frames, warmup_frames=warmup_frames, screenshot=False,
                    **case_watchdogs,
                )
                if case.get("status") != "passed":
                    case_failures.append(case)
                    print(
                        f"  run {index}: {case.get('failure_kind', 'failed')} "
                        f"phase={case.get('last_phase', 'unknown')}", flush=True,
                    )
                    break
                paced_results.append(case)
                print(
                    f"  run {index}: {case['active_fps']:.1f} fps, "
                    f"interval p95={case['metrics']['interval_ms_p95']:.3f}ms",
                    flush=True,
                )
            if case_failures:
                scenario_report["status"] = "failed"
                scenario_report["failures"] = case_failures
                report["passed"] = False
                report["scenarios"][scenario] = scenario_report
                continue
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
            golden = golden_root / f"{scenario}-{args.renderer}.png"
            if scenario == "font-raster-correctness":
                scenario_report["font_raster"] = visual_run["font_raster"]
                if not visual_run["font_raster"]["passed"]:
                    scenario_report["status"] = "failed"
                    scenario_report.setdefault("failures", []).append({
                        "failure_kind": "font_raster_seam",
                        "details": visual_run["font_raster"]["failures"],
                    })
                    report["passed"] = False
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
        same_user_state_mode = (
            baseline.get("user_state_mode", "clean") == report["user_state_mode"]
        )
        same_renderer = baseline.get("renderer", "d3d11") == report["renderer"]
        same_workload = same_frame_counts and same_scenario_settings and same_user_state_mode
        report["baseline_compatibility"] = {
            "same_machine": same_machine,
            "same_fixture": same_fixture,
            "same_frame_counts": same_frame_counts,
            "same_scenario_settings": same_scenario_settings,
            "same_user_state_mode": same_user_state_mode,
            "same_renderer": same_renderer,
            "same_workload": same_workload,
        }
        findings = (
            compare_performance(report, baseline)
            if same_machine and same_fixture and same_workload and same_renderer else []
        )
        report["performance_findings"] = findings
        if (not same_machine or not same_fixture or not same_workload or not same_renderer
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
            "user_state_mode": args.user_state_mode,
            "renderer": args.renderer,
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
                    "lifecycle": item.get("lifecycle", {}),
                    "resources": item.get("resources", {}),
                    "state": item.get("state"),
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
        if msvcrt is None:
            raise RuntimeError("the isolated D3D11 gate requires Windows")
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
