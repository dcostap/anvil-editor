from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
import sys


def _number(row: dict[str, str], key: str) -> float:
    try:
        return float(row.get(key) or 0)
    except ValueError:
        return 0.0


def summarize_idle_frames(path: Path) -> dict[str, float | int]:
    with path.open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream))
    if not rows:
        raise ValueError(f"idle capture has no frame rows: {path}")

    first_time = _number(rows[0], "time")
    last_time = _number(rows[-1], "time")
    elapsed = max(0.0, last_time - first_time)
    if elapsed == 0:
        elapsed = sum(_number(row, "total_ms") for row in rows) / 1000.0
    if elapsed <= 0:
        raise ValueError(f"idle capture has no measurable duration: {path}")

    idle_rows = [row for row in rows if row.get("did_redraw") != "1"]
    update_rows = [
        row for row in idle_rows
        if max(
            _number(row, "core_root_panel_update_ms"),
            _number(row, "rootpanel_update_ms"),
        ) > 0
    ]
    total_ms = sum(_number(row, "total_ms") for row in rows)
    sleep_ms = sum(_number(row, "sleep_actual_ms") for row in rows)
    measured_ms = max(total_ms, elapsed * 1000.0)

    return {
        "elapsed_seconds": elapsed,
        "iterations": len(rows),
        "iterations_per_second": len(rows) / elapsed,
        "redraw_iterations": len(rows) - len(idle_rows),
        "idle_iterations": len(idle_rows),
        "idle_ui_update_iterations": len(update_rows),
        "idle_ui_update_fraction": len(update_rows) / max(1, len(idle_rows)),
        "focused_iterations": sum(row.get("window_has_focus") == "1" for row in rows),
        "focused_fraction": sum(row.get("window_has_focus") == "1" for row in rows) / len(rows),
        "pending_event_iterations": sum(row.get("pending_events") == "1" for row in rows),
        "pending_event_fraction": sum(row.get("pending_events") == "1" for row in rows) / len(rows),
        "core_step_iterations": sum(_number(row, "core_step_ms") > 0 for row in rows),
        "total_ms": total_ms,
        "sleep_ms": sleep_ms,
        "awake_fraction": max(0.0, measured_ms - sleep_ms) / measured_ms,
        "core_step_ms": sum(_number(row, "core_step_ms") for row in rows),
        "root_panel_update_ms": sum(
            max(_number(row, "core_root_panel_update_ms"), _number(row, "rootpanel_update_ms"))
            for row in rows
        ),
    }


def evaluate_idle_summary(
    summary: dict[str, float | int],
    *,
    max_iterations_per_second: float = 120.0,
    max_idle_ui_update_fraction: float = 0.10,
    max_awake_fraction: float = 0.20,
    max_pending_event_fraction: float = 0.10,
    min_focused_fraction: float = 0.90,
) -> list[str]:
    checks = [
        ("focused_fraction", ">=", min_focused_fraction),
        ("iterations_per_second", "<=", max_iterations_per_second),
        ("idle_ui_update_fraction", "<=", max_idle_ui_update_fraction),
        ("awake_fraction", "<=", max_awake_fraction),
        ("pending_event_fraction", "<=", max_pending_event_fraction),
    ]
    failures: list[str] = []
    for name, relation, limit in checks:
        value = float(summary[name])
        passed = value >= limit if relation == ">=" else value <= limit
        if not passed:
            failures.append(f"{name}={value:.4f} must be {relation} {limit:.4f}")
    return failures


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate an Anvil focused-idle performance capture")
    parser.add_argument("frames_csv", type=Path)
    parser.add_argument("--max-iterations-per-second", type=float, default=120.0)
    parser.add_argument("--max-idle-ui-update-fraction", type=float, default=0.10)
    parser.add_argument("--max-awake-fraction", type=float, default=0.20)
    parser.add_argument("--max-pending-event-fraction", type=float, default=0.10)
    parser.add_argument("--min-focused-fraction", type=float, default=0.90)
    args = parser.parse_args(argv)

    try:
        summary = summarize_idle_frames(args.frames_csv)
        failures = evaluate_idle_summary(
            summary,
            max_iterations_per_second=args.max_iterations_per_second,
            max_idle_ui_update_fraction=args.max_idle_ui_update_fraction,
            max_awake_fraction=args.max_awake_fraction,
            max_pending_event_fraction=args.max_pending_event_fraction,
            min_focused_fraction=args.min_focused_fraction,
        )
    except (OSError, ValueError) as error:
        print(json.dumps({"status": "error", "error": str(error)}, indent=2))
        return 2

    result = {"status": "failed" if failures else "passed", "metrics": summary, "failures": failures}
    print(json.dumps(result, indent=2))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
