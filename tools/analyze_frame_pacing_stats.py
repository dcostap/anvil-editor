#!/usr/bin/env python3
"""Summarize Anvil frame pacing and D3D11 CSV dumps."""
from __future__ import annotations

import argparse
import csv
import math
import os
from typing import Iterable


def as_float(value):
    try:
        return float(value)
    except Exception:
        return None


def stats(values: Iterable[float | None]):
    vals = [v for v in values if v is not None and math.isfinite(v)]
    if not vals:
        return None
    vals.sort()
    n = len(vals)

    def pct(q: float):
        return vals[min(n - 1, int((n - 1) * q))]

    return {
        "n": n,
        "p50": pct(0.50),
        "p90": pct(0.90),
        "p95": pct(0.95),
        "p99": pct(0.99),
        "max": vals[-1],
        "avg": sum(vals) / n,
    }


def fmt(s):
    if not s:
        return "n/a"
    return (
        "n={n} p50={p50:.3f} p90={p90:.3f} p95={p95:.3f} "
        "p99={p99:.3f} max={max:.3f} avg={avg:.3f}"
    ).format(**s)


def timestamp_span_fps(rows):
    times = [as_float(r.get("time")) for r in rows]
    times = [t for t in times if t is not None and math.isfinite(t)]
    if len(times) < 2:
        return None
    elapsed = times[-1] - times[0]
    if elapsed <= 0:
        return None
    return (len(times) - 1) / elapsed, elapsed


def timestamp_intervals_ms(rows):
    times = [as_float(r.get("time")) for r in rows]
    times = [t for t in times if t is not None and math.isfinite(t)]
    return [(b - a) * 1000 for a, b in zip(times, times[1:]) if b >= a]


def read_csv(path):
    if not os.path.exists(path):
        return []
    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        return list(csv.DictReader(f))


def is_redraw(row):
    return (
        row.get("did_redraw") in ("1", "true", "yes")
        or (as_float(row.get("draw_emit_ms")) or 0) > 0
        or (as_float(row.get("renderer_end_ms")) or 0) > 0
    )


def summarize(frame_path, d3d_path, budget_ms):
    print("files:")
    for path in (frame_path, d3d_path):
        print(path, os.path.exists(path), os.path.getsize(path) if os.path.exists(path) else None)

    rows = read_csv(frame_path)
    if rows:
        red = [r for r in rows if is_redraw(r)]
        print(f"\nframe rows {len(rows)}")
        print(f"redraw rows {len(red)} non-redraw {len(rows) - len(red)}")
        if red:
            active_rate = timestamp_span_fps(red)
            if active_rate:
                fps, elapsed = active_rate
                print(f"redraw timestamp rate {fps:.1f} fps over {elapsed:.3f}s")
            intervals = timestamp_intervals_ms(red)
            if intervals:
                print("redraw interval_ms", fmt(stats(intervals)))
            steady_red = red[10:] if len(red) > 20 else red
            steady_rate = timestamp_span_fps(steady_red)
            if steady_rate and steady_red is not red:
                fps, elapsed = steady_rate
                print(f"steady redraw timestamp rate {fps:.1f} fps over {elapsed:.3f}s (first 10 redraws skipped)")
            for key in [
                "target_fps",
                "event_ms",
                "update_ms",
                "pre_draw_ms",
                "draw_emit_ms",
                "renderer_end_ms",
                "frame_time_ms",
                "run_threads_ms",
                "core_step_ms",
                "present_ms",
                "sleep_actual_ms",
                "total_ms",
            ]:
                if key in red[0]:
                    print(key, fmt(stats(as_float(r.get(key)) for r in red)))
            for key in [
                "draw_calls",
                "quad_instances",
                "texture_quads",
                "texture_uploads",
                "texture_upload_bytes",
                "rencache_commands",
                "rencache_text_commands",
                "rencache_rect_commands",
                "rencache_set_clip_commands",
                "rencache_command_bytes",
                "rencache_text_bytes",
                "rencache_draw_text_ms",
                "rencache_draw_text_width_ms",
                "docview_draw_ms",
                "docview_gutter_ms",
                "docview_body_ms",
                "docview_text_ms",
                "docview_highlighter_get_line_ms",
                "docview_token_loop_ms",
                "docview_renderer_draw_text_ms",
                "docview_visible_lines",
                "docview_text_lines",
                "docview_tokens",
                "docview_draw_text_calls",
            ]:
                if key in red[0]:
                    print(key, fmt(stats(as_float(r.get(key)) for r in red)))
            if budget_ms:
                over = sum(1 for r in red if (as_float(r.get("frame_time_ms")) or 0) > budget_ms)
                print(f"frames over {budget_ms:.3f}ms: {over} / {len(red)} ({100 * over / len(red):.1f}%)")
            print("top frame_time rows:")
            for r in sorted(red, key=lambda r: as_float(r.get("frame_time_ms")) or -1, reverse=True)[:5]:
                print({k: r.get(k) for k in [
                    "seq", "reason", "event_ms", "update_ms", "draw_emit_ms",
                    "renderer_end_ms", "frame_time_ms", "docview_draw_ms", "docview_text_ms",
                    "docview_renderer_draw_text_ms", "draw_calls", "rencache_text_commands",
                    "rencache_draw_text_ms", "rencache_draw_text_width_ms", "texture_uploads",
                    "texture_upload_bytes",
                ]})

    drows = read_csv(d3d_path)
    if drows:
        print(f"\nd3d rows {len(drows)}")
        for key in [
            "cpu_ms",
            "present_ms",
            "dwm_flush_ms",
            "draw_calls",
            "quad_instances",
            "texture_quads",
            "texture_draws",
            "texture_batch_breaks",
            "quad_batches",
            "unique_batch_srvs",
            "repeated_batch_srvs",
            "texture_uploads",
            "texture_upload_bytes",
            "texture_recreates",
            "texture_prunes",
        ]:
            if key in drows[0]:
                print("d3d " + key, fmt(stats(as_float(r.get(key)) for r in drows)))
        print("top d3d cpu rows:")
        for r in sorted(drows, key=lambda r: as_float(r.get("cpu_ms")) or -1, reverse=True)[:5]:
            print({k: r.get(k) for k in [
                "frame", "cpu_ms", "present_ms", "draw_calls", "quad_instances",
                "texture_uploads", "texture_upload_bytes", "texture_recreates", "texture_prunes",
            ]})


def main():
    temp = os.environ.get("TEMP") or os.environ.get("TMP") or "."
    ap = argparse.ArgumentParser()
    ap.add_argument("--frame", default=os.path.join(temp, "anvil_frame_pacing_stats.csv"))
    ap.add_argument("--d3d", default=os.path.join(temp, "anvil_d3d11_stats.csv"))
    ap.add_argument("--budget-ms", type=float, default=6.06)
    args = ap.parse_args()
    summarize(args.frame, args.d3d, args.budget_ms)


if __name__ == "__main__":
    main()
