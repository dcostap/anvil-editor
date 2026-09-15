"""Offline benchmark analysis. Profile costs never replace unprofiled scores."""
from __future__ import annotations

from collections import defaultdict
import csv
import html
import json
import math
from pathlib import Path
import statistics
from typing import Any


def rows(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8-sig") as stream:
        return list(csv.DictReader(stream))


def key_values(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    return dict(line.split("=", 1) for line in path.read_text(encoding="utf-8").splitlines() if "=" in line)


def distribution(values: list[float]) -> dict[str, float]:
    ordered = sorted(values)
    if not ordered:
        return {}
    def percentile(q: float) -> float:
        index = (len(ordered) - 1) * q
        lo = int(index)
        return ordered[lo] + (ordered[min(lo + 1, len(ordered) - 1)] - ordered[lo]) * (index - lo)
    return dict(count=len(values), avg=statistics.mean(values), p50=percentile(.5),
                p95=percentile(.95), p99=percentile(.99), max=max(values), total=sum(values))


def read_actions(path: Path, expected: int) -> dict[str, Any]:
    captured = rows(path)
    if len(captured) != expected:
        raise ValueError(f"action count mismatch: expected {expected}, got {len(captured)}: {path}")
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for index, row in enumerate(captured, 1):
        for key in ("id", "start_ms", "dispatch_ms", "ready_ms", "latency_ms", "redraws"):
            row[key] = float(row[key])
            if not math.isfinite(row[key]) or row[key] < 0:
                raise ValueError(f"invalid action {key}: {path}")
        if (row["id"] != index or row["redraws"] < 1 or not row["result"]
                or row["latency_ms"] < row["ready_ms"]
                or row["ready_ms"] < row["dispatch_ms"]):
            raise ValueError(f"invalid action completion evidence: {path}")
        grouped[row["name"]].append(row)
    summaries = {}
    for name, actions in grouped.items():
        summaries[name] = {
            f"{key}_{stat}": value
            for key in ("dispatch_ms", "ready_ms", "latency_ms", "redraws")
            for stat, value in distribution([row[key] for row in actions]).items()
        }
    return {"summary": summaries, "rows": captured,
            "sequence": [[row["name"], row["result"]] for row in captured]}


def red_flags(case: dict[str, Any], frame_budget_ms: float, action_budget_ms: float) -> list[dict[str, Any]]:
    findings = []
    def check(metric: str, value: float, budget: float, action: str | None = None) -> None:
        if value > budget:
            findings.append(dict(metric=metric, value=value, budget=budget,
                                 ratio=value / budget, action=action, evidence="measured"))
    for metric in ("frame_ms_p95", "frame_ms_max"):
        check(metric, case.get("metrics", {}).get(metric, 0), frame_budget_ms)
    for name, values in case.get("actions", {}).items():
        for metric in ("latency_ms_p95", "latency_ms_max"):
            check(metric, values.get(metric, 0), action_budget_ms, name)
    return sorted(findings, key=lambda item: item["ratio"], reverse=True)


def flame_svg(samples: list[tuple[list[str], float]], unit: str) -> str:
    """Aggregate weighted stacks. Exclusive weights prevent double counting."""
    root: dict[str, Any] = {"name": "all", "value": 0.0, "children": {}}
    for stack, weight in samples:
        node = root
        node["value"] += weight
        for name in stack:
            node = node["children"].setdefault(name, {"name": name, "value": 0.0, "children": {}})
            node["value"] += weight
    total = root["value"] or 1
    boxes, max_depth = [], 0
    def visit(node: dict[str, Any], left: float, depth: int) -> None:
        nonlocal max_depth
        width = node["value"] / total * 1200
        if width < .3:
            return
        max_depth = max(max_depth, depth)
        title = html.escape(f"{node['name']}: {node['value']:.3f} {unit}")
        hue = sum(ord(c) for c in node["name"]) % 65
        y = depth * 23
        boxes.append(f'<g><title>{title}</title><rect x="{left:.2f}" y="{y}" '
                     f'width="{width:.2f}" height="22" fill="hsl({hue},80%,72%)"/>')
        if width > 35:
            text = html.escape(node["name"][:max(1, int(width / 7) - 1)])
            boxes.append(f'<text x="{left + 3:.2f}" y="{y + 15}" font-size="12">{text}</text>')
        boxes.append('</g>')
        # Unoccupied width is the parent's own exclusive cost.
        x = left
        for child in sorted(node["children"].values(), key=lambda item: item["name"]):
            visit(child, x, depth + 1)
            x += child["value"] / total * 1200
    visit(root, 0, 0)
    return f'<svg viewBox="0 0 1200 {(max_depth + 1) * 23}" xmlns="http://www.w3.org/2000/svg">' + ''.join(boxes) + '</svg>'


def build_profile(root: Path) -> dict[str, Any]:
    captured = rows(root / "profile_draw_scopes.csv")
    sampler = key_values(root / "profile-status.txt")
    paths: dict[tuple[str, str, str], dict[str, Any]] = {}
    frames = set()
    group_frames: dict[tuple[str, str], set[str]] = defaultdict(set)
    imbalanced = set()
    for row in captured:
        frames.add(row["frame"])
        if int(row.get("scope_imbalance", 0)):
            imbalanced.add(row["frame"])
        phase, action = row.get("phase", "unspecified"), row.get("action", "unspecified")
        group_frames[phase, action].add(row["frame"])
        aggregate = paths.setdefault((phase, action, row["path"]), dict(
            phase=phase, action=action, path=row["path"], calls=0, inclusive_ms=0., exclusive_ms=0.,
            max_inclusive_ms=0., heap_delta_kib=0., heap_drop_calls=0))
        aggregate["calls"] += int(row["calls"])
        for key in ("inclusive_ms", "exclusive_ms"):
            aggregate[key] += float(row[key])
        aggregate["max_inclusive_ms"] = max(aggregate["max_inclusive_ms"], float(row["inclusive_ms"]))
        aggregate["heap_delta_kib"] += float(row.get("scope_heap_delta_kb", 0))
        aggregate["heap_drop_calls"] += int(row.get("scope_heap_drop_calls", 0))
    for aggregate in paths.values():
        count = len(group_frames[aggregate["phase"], aggregate["action"]])
        aggregate["captured_frames"] = count
        aggregate["exclusive_ms_per_captured_frame"] = aggregate["exclusive_ms"] / max(1, count)
    hotspots = sorted(paths.values(), key=lambda item: item["exclusive_ms"], reverse=True)
    profiles = []
    shared: list[dict[str, str]] = []
    indices: dict[str, int] = {}
    sections = []
    def add_profile(name: str, stacks: list[tuple[list[str], float]], unit: str) -> None:
        if not stacks:
            return
        samples, weights = [], []
        for stack, weight in stacks:
            ids = []
            for frame in stack:
                if frame not in indices:
                    indices[frame] = len(shared)
                    shared.append({"name": frame})
                ids.append(indices[frame])
            samples.append(ids)
            weights.append(weight)
        profiles.append(dict(type="sampled", name=name, unit=unit, startValue=0,
                             endValue=sum(weights), samples=samples, weights=weights))
        sections.append(f'<details open><summary>{html.escape(name)}</summary>'
                        + flame_svg(stacks, unit) + '</details>')
    add_profile("Draw scopes: exclusive elapsed cost (sampled redraws)", [
        (item["path"].split("/"), item["exclusive_ms"]) for item in hotspots if item["exclusive_ms"] > 0
    ], "milliseconds")
    for phase, action in sorted(group_frames):
        if phase == "unspecified":
            continue
        add_profile(f"Draw scopes: {phase} / {action}", [
            (item["path"].split("/"), item["exclusive_ms"]) for item in hotspots
            if item["phase"] == phase and item["action"] == action and item["exclusive_ms"] > 0
        ], "milliseconds")
    groups: dict[str, list[tuple[list[str], float]]] = defaultdict(list)
    vmstates: dict[str, int] = defaultdict(int)
    for row in rows(root / "stacks.csv"):
        name = f'LuaJIT samples: {row["phase"]} / {row["action"]}'
        vmstates[row["vmstate"]] += int(row["samples"])
        stack = [frame for frame in row["stack"].splitlines() if frame]
        stack.append("VM state: " + row["vmstate"])
        groups[name].append((stack, float(row["samples"])))
    for name, stacks in sorted(groups.items()):
        add_profile(name, stacks, "none")
    document = {"$schema": "https://www.speedscope.app/file-format-schema.json",
                "name": root.name, "shared": {"frames": shared}, "profiles": profiles,
                "activeProfileIndex": 0, "exporter": "Anvil diagnostic harness"}
    (root / "profile.speedscope.json").write_text(json.dumps(document), encoding="utf-8")
    notes = (
        "Diagnostic timings include profiler overhead. Use unprofiled runs for scores. "
        "Timers measure elapsed time, including waits, not isolated CPU time. "
        "Draw scopes cover diagnostic redraws; nested totals overlap. "
        "Heap deltas show net growth, not allocated bytes. They include profiler allocations. "
        "LuaJIT samples include interpreted code, compiled Lua, C boundaries, GC, and JIT compilation. "
        "Native call stacks are not captured. C addresses identify Lua call boundaries, not native function trees. "
        "Worker threads and child processes need a separate native profile. "
        "VM states: I=interpreter, N=compiled Lua, C=C code, G=GC, J=JIT compiler. "
        "Sample groups are not a chronological call trace. Sparse samples can miss short operations."
    )
    content = ["<h1>Diagnostic profile</h1><p>" + notes + "</p>",
               "<p>Sampler status: " + html.escape(sampler.get("sampler", "not recorded"))
               + "; samples: " + html.escape(sampler.get("samples", str(sum(vmstates.values()))))
               + ". " + html.escape(sampler.get("note", "")) + "</p>",
               '<p><a href="profile.speedscope.json">Speedscope file</a> · '
               '<a href="timeline.json">Action timeline (Chrome Trace)</a> · '
               '<a href="profile_summary.txt">Detailed counters and slow frames</a></p>',
               table(hotspots[:40], ["phase", "action", "path", "calls", "exclusive_ms", "inclusive_ms",
                     "exclusive_ms_per_captured_frame", "max_inclusive_ms", "heap_delta_kib"])]
    content.extend(sections)
    (root / "profile.html").write_text(page("Diagnostic profile", ''.join(content)), encoding="utf-8")
    result = dict(hotspots=hotspots, captured_frames=len(frames), imbalanced_frames=len(imbalanced),
                  vmstates=dict(vmstates), sampler=sampler, native_stack_capture=False,
                  notes=notes, html=str(root / "profile.html"),
                  speedscope=str(root / "profile.speedscope.json"))
    (root / "diagnostics.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    return result


def write_timeline(root: Path) -> None:
    """Action intervals use measured timestamps; frame costs use counter events."""
    events = []
    values = key_values(root / "result.txt")
    origin = float(values.get("clock_origin_seconds", 0))
    measure_offset = (float(values.get("measurement_origin_seconds", origin)) - origin) * 1000000
    for row in rows(root / "actions.csv"):
        start = measure_offset + float(row["start_ms"]) * 1000
        for name, duration, lane in ((row["name"], row["latency_ms"], "completion"),
                                     (row["name"] + ": dispatch", row["dispatch_ms"], "dispatch")):
            events.append(dict(name=name, cat="action", ph="X", ts=start,
                               dur=float(duration) * 1000, pid=1, tid=lane,
                               args={"result": row["result"], "redraws": row["redraws"]}))
    for row in rows(root / "metrics.csv"):
        events.append(dict(name="Frame costs (ms)", ph="C", pid=1, tid="frames",
                           ts=measure_offset + float(row["completion_ms"]) * 1000,
                           args={key: float(row[key]) for key in (
                               "action_ms", "update_ms", "draw_emit_ms", "renderer_end_ms",
                               "run_threads_ms", "gc_ms") if key in row}))
    for row in rows(root / "lifecycle.csv"):
        events.append(dict(name=row["milestone"], ph="i", s="t", pid=1, tid="lifecycle",
                           ts=float(row["elapsed_ms"]) * 1000))
    if origin:
        for row in rows(root / "profile_file_opens.csv"):
            if row["event"] not in ("stage", "stage_auto", "complete"):
                continue
            duration = float(row["duration_ms"]) * 1000
            events.append(dict(name=row["detail"], cat="file-open", ph="X", pid=1,
                               tid="file-open " + row["open_id"], dur=duration,
                               ts=(float(row["time"]) - origin) * 1000000 - duration,
                               args={"path": row["path"], "source": row["source"], "depth": row["depth"]}))
    (root / "timeline.json").write_text(json.dumps({"traceEvents": events}), encoding="utf-8")


def table(items: list[dict[str, Any]], columns: list[str]) -> str:
    def value(item: Any) -> str:
        return html.escape(f"{item:.3f}" if isinstance(item, float) else str(item))
    return ('<div class="scroll"><table><tr>' + ''.join(f'<th>{value(key)}</th>' for key in columns)
            + '</tr>' + ''.join('<tr>' + ''.join(f'<td>{value(item.get(key, ""))}</td>'
                              for key in columns) + '</tr>' for item in items) + '</table></div>')


def page(title: str, body: str) -> str:
    return ('<!doctype html><html><head><meta charset="utf-8"><title>' + html.escape(title)
            + '</title><style>body{font:14px system-ui;margin:24px;background:#fafafa;color:#222}'
            'table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:6px;text-align:left}'
            '.scroll{overflow:auto}svg{width:100%;min-width:900px}details{margin:20px 0;overflow:auto}'
            'summary{font-weight:bold;cursor:pointer}a{color:#065fba}code{white-space:pre-wrap}'
            '</style></head><body>' + body + '</body></html>')


def write_report(report: dict[str, Any], root: Path) -> None:
    def link(path: str, label: str) -> str:
        relative = Path(path).relative_to(root).as_posix()
        from urllib.parse import quote
        return f'<a href="{quote(relative)}">{html.escape(label)}</a>'
    parts = ['<h1>Anvil workload report</h1>',
             '<p>Unprofiled runs provide scores. Diagnostic passes provide attribution, not regression scores. '
             'Action latency ends after a redraw contains the verified result. Hidden presentation is not physical display latency.</p>',
             '<p><a href="report.json">Full JSON</a> · <a href="report.md">Summary</a></p>']
    ranked = []
    for name, case in report["scenarios"].items():
        for flag in case.get("red_flags", []):
            ranked.append(dict(scenario=name, **flag))
    ranked.sort(key=lambda row: row["ratio"], reverse=True)
    parts.append('<h2>Absolute budget flags</h2>' + table(ranked, [
        "scenario", "action", "metric", "value", "budget", "ratio", "evidence"]))
    for name, case in report["scenarios"].items():
        parts.append('<h2>' + html.escape(name) + '</h2>')
        parts.append('<p>Status: ' + html.escape(case["status"]) + '</p>')
        if case.get("failures"):
            parts.append('<pre>' + html.escape(json.dumps(case["failures"], indent=2)) + '</pre>')
        parts.append('<p>Workload: <code>' + html.escape(json.dumps(case.get("settings", {}))) + '</code></p>')
        parts.append(table([dict(action=name, **values) for name, values in case.get("actions", {}).items()], [
            "action", "latency_ms_count", "latency_ms_p50", "latency_ms_p95", "latency_ms_max",
            "dispatch_ms_p95", "ready_ms_p95", "redraws_max"]))
        parts.append('<details><summary>Frame costs, work counts, lifecycle, and memory</summary><pre>'
                     + html.escape(json.dumps({key: case.get(key) for key in (
                         "active_fps", "telemetry_overhead_fraction", "metrics", "lifecycle", "resources")}, indent=2))
                     + '</pre></details>')
        for run in case.get("metric_runs", []) + case.get("diagnostic_runs", []):
            run_root = Path(run["run_dir"])
            parts.append('<p>' + html.escape(run.get("mode", "run")) + ': ')
            for filename, label in (("metrics.csv", "frame CSV"), ("actions.csv", "action CSV"),
                                    ("timeline.json", "timeline"), ("profile.html", "flame graphs"),
                                    ("profile_summary.txt", "all counters"), ("profile_file_opens.csv", "file-open stages"),
                                    ("screenshot.png", "render checkpoint"), ("resources.csv", "memory samples"),
                                    ("profile-status.txt", "sampler status")):
                if (run_root / filename).exists():
                    parts.append(link(str(run_root / filename), label) + ' · ')
            parts.append('</p>')
        for diagnostic in case.get("diagnostic_runs", []):
            parts.append(table(diagnostic.get("diagnostics", {}).get("hotspots", [])[:12], [
                "phase", "action", "path", "exclusive_ms", "inclusive_ms", "exclusive_ms_per_captured_frame", "calls"]))
    parts.append('<h2>Interpretation</h2><p>Flags identify measured costs, not proven causes. '
                 'Compare size variants and inspect stacks before changing code. '
                 'Memory growth can include caches and fixture state; it does not prove a leak. '
                 'Background CPU and GPU load can change timings. No physical OS cache flush is used.</p>')
    (root / "report.html").write_text(page("Anvil workload report", ''.join(parts)), encoding="utf-8")
