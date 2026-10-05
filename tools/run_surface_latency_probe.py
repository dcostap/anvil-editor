#!/usr/bin/env python3
"""Compare typing latency of a direct Anvil window and the `--shell` compositor.

Each case runs on a private desktop with isolated app data. The native input
latency probe injects tagged key presses into the window that receives real
input (the Anvil window, or the shell window), and records the time until a
presented frame contains the edit. Hosted cases therefore include the pipe hop,
the hosted render, the frame handoff, and the shell composite.

    python tools/run_surface_latency_probe.py --no-build
"""

from __future__ import annotations

import argparse
import json
import shutil
import statistics
import tempfile
from pathlib import Path
from typing import Any

from run_render_perf_gate import (
    ROOT, build_anvil, copy_app_tree, invoke_hidden, native_path, read_key_values,
)

DISABLED_PLUGINS = "ipc,autorestart,autoreload,autosave_fast,autosaveonfocuslost"


def run_case(exe: Path, work: Path, mode: str, renderer: str, samples: int,
             warmup_ms: int, run_index: int) -> dict[str, Any]:
    run_dir = work / f"{mode}-{renderer}-{run_index}"
    user = run_dir / "user"
    project = run_dir / "project"
    user.mkdir(parents=True)
    project.mkdir(parents=True)
    probe_file = project / "probe.txt"
    probe_file.write_text("Latency probe\n", encoding="utf-8")
    result_file = run_dir / "latency.txt"

    environment = {
        "ANVIL_USERDIR": native_path(user),
        "USERPROFILE": native_path(user),
        "HOME": native_path(user),
        "ANVIL_TEST_DISABLE_PLUGINS": DISABLED_PLUGINS,
        "ANVIL_RENDERER": renderer,
        "ANVIL_INPUT_LATENCY_PROBE": str(samples),
        "ANVIL_INPUT_LATENCY_FILE": native_path(result_file),
        "ANVIL_INPUT_LATENCY_WARMUP_MS": str(warmup_ms),
        "ANVIL_SURFACE_LOG": native_path(run_dir / "surface.log"),
    }
    arguments = [native_path(probe_file)]
    if mode == "shell":
        arguments.insert(0, "--shell")
    config = {
        "exe": native_path(exe),
        "working_directory": native_path(project),
        "arguments": arguments,
        "environment": environment,
        "startup_timeout_seconds": 0,
        "stable_ui_scheduling": False,
    }
    config_path = run_dir / "launch.json"
    config_path.write_text(json.dumps(config, indent=2), encoding="utf-8")
    timeout = int(warmup_ms / 1000 + samples * 0.2 + 45)
    launcher = invoke_hidden(config_path, timeout)
    values = read_key_values(result_file)
    case = {
        "mode": mode, "renderer": renderer, "run": run_index,
        "exit_code": launcher.get("exit_code"), "timed_out": launcher.get("timed_out"),
        "done": values.get("done") == "1",
        "requested": int(values.get("requested", 0) or 0),
        "completed": int(values.get("completed", 0) or 0),
        "run_dir": str(run_dir),
    }
    for key in ("min_ms", "p50_ms", "p90_ms", "p99_ms", "max_ms", "mean_ms"):
        if key in values:
            case[key] = float(values[key])
    samples_ms = values.get("samples_ms", "")
    case["samples_ms"] = [float(value) for value in samples_ms.split(",") if value]
    return case


def summarize(cases: list[dict[str, Any]]) -> dict[str, Any]:
    samples = sorted(value for case in cases for value in case["samples_ms"])

    def pick(quantile: float) -> float:
        if not samples:
            return 0.0
        return samples[min(len(samples) - 1, int(quantile * (len(samples) - 1) + 0.5))]

    return {
        "runs": len(cases),
        "ok_runs": sum(1 for case in cases if case["done"] and case["completed"] == case["requested"]),
        "samples": len(samples),
        "p50_ms": pick(0.50), "p90_ms": pick(0.90), "p99_ms": pick(0.99),
        "max_ms": samples[-1] if samples else 0.0,
        "mean_ms": statistics.fmean(samples) if samples else 0.0,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--reference-exe", type=Path, help="copy a saved reference executable into the isolated app")
    parser.add_argument("--project-case", action="append", choices=["launch", "arguments", "option-arguments", "invalid", "quit", "quit-error", "shell-loss", "end-loss", "stalled-loss", "restart", "switch", "new-window", "duplicate", "foreground", "conflict", "controls", "routing"],
                        help="run an owned Project lifecycle check instead of typing")
    parser.add_argument("--samples", type=int, default=120)
    parser.add_argument("--runs", type=int, default=2)
    parser.add_argument("--warmup-ms", type=int, default=5000)
    parser.add_argument("--renderer", action="append", choices=["d3d11", "software"])
    parser.add_argument("--mode", action="append", choices=["direct", "shell"])
    parser.add_argument("--keep", action="store_true", help="keep the temporary work directory")
    parser.add_argument("--json", type=Path, help="write the full results to this file")
    args = parser.parse_args()

    if not args.no_build:
        build_anvil()
    renderers = args.renderer or ["d3d11", "software"]
    modes = args.mode or ["direct", "shell"]

    work = Path(tempfile.mkdtemp(prefix="anvil-surface-latency-"))
    try:
        exe = copy_app_tree(work / "app")
        if args.reference_exe:
            shutil.copy2(args.reference_exe, exe)
        if args.project_case:
            shutil.copy2(ROOT / "tests/fixtures/hosted_project_probe.lua",
                         work / "app/share/anvil/plugins/hosted_project_probe.lua")
            failed = False
            for mode in args.mode or ["shell"]:
                for action in args.project_case:
                    case_dir = work / f"project-{mode}-{action}"
                    for name in ("driver", "Project", "Replacement", "user"):
                        (case_dir / name).mkdir(parents=True)
                    (case_dir / "Project/edited.txt").write_bytes(b"on disk\n")
                    if action == "routing":
                        (case_dir / "Project/edited.txt").write_text("0123456789\n" * 200, encoding="utf-8")
                    (case_dir / "Project/second.txt").write_bytes(b"second instance\n")
                    namespace = "anvil-test-" + work.name.rsplit("-", 1)[-1] + "-" + action
                    init = ('local open = shmem.open\nshmem.open = function(name, capacity)\n'
                            f'  return open(name == "anvil-ipc" and "{namespace}" or name, capacity)\nend\n')
                    if action in ("conflict", "arguments", "option-arguments", "controls", "routing"):
                        init += 'local config = require "core.config"\nconfig.plugins.ipc.single_instance = false\n'
                    (case_dir / "user/init.lua").write_text(init, encoding="utf-8")
                    result = case_dir / "result.lua"
                    config = {
                        "exe": native_path(exe), "working_directory": native_path(case_dir / "driver"),
                        "arguments": [native_path(case_dir / "driver")],
                        "environment": {
                            "ANVIL_USERDIR": native_path(case_dir / "user"),
                            "USERPROFILE": native_path(case_dir / "user"), "HOME": native_path(case_dir / "user"),
                            "ANVIL_PROJECT_PROBE": action, "ANVIL_PROJECT_PROBE_MODE": mode,
                            "ANVIL_INPUT_ROUTING_PROBE": "1" if action == "routing" else "",
                            "ANVIL_PROJECT_PROBE_ROOT": native_path(case_dir).replace("\\", "/"),
                            "ANVIL_PROJECT_PROBE_RESULT": native_path(result),
                            "ANVIL_TEST_DISABLE_PLUGINS": "autorestart,autoreload,autosave_fast,autosaveonfocuslost",
                            "ANVIL_RENDERER": (args.renderer or ["d3d11"])[0],
                            "ANVIL_SURFACE_LOG": native_path(case_dir / "surface.log"),
                        }, "startup_timeout_seconds": 0, "stable_ui_scheduling": False,
                    }
                    config_path = case_dir / "launch.json"
                    config_path.write_text(json.dumps(config), encoding="utf-8")
                    launcher = invoke_hidden(config_path, 60)
                    text = result.read_text(encoding="utf-8") if result.exists() else "missing result"
                    ok = '["ok"]=true' in text and not launcher.get("timed_out")
                    failed |= not ok
                    print(f"Project {mode}/{action}: {'PASS' if ok else 'FAIL'} {text}", flush=True)
            return int(failed)
        cases: list[dict[str, Any]] = []
        # Interleave modes so drift on the machine affects both equally.
        for run_index in range(args.runs):
            for renderer in renderers:
                for mode in modes:
                    case = run_case(exe, work, mode, renderer, args.samples, args.warmup_ms, run_index)
                    cases.append(case)
                    status = "ok" if case["done"] else f"failed exit={case['exit_code']}"
                    print(f"{mode:7} {renderer:8} run {run_index}: {status} "
                          f"{case['completed']}/{case['requested']} p50={case.get('p50_ms', 0):.2f}ms",
                          flush=True)

        summary = {}
        print()
        print(f"{'mode':7} {'renderer':8} {'runs':>5} {'samples':>8} {'p50':>8} {'p90':>8} "
              f"{'p99':>8} {'max':>8} {'mean':>8}")
        for renderer in renderers:
            for mode in modes:
                group = [case for case in cases if case["mode"] == mode and case["renderer"] == renderer]
                result = summarize(group)
                summary[f"{mode}-{renderer}"] = result
                print(f"{mode:7} {renderer:8} {result['ok_runs']}/{result['runs']:<3} {result['samples']:>8} "
                      f"{result['p50_ms']:>8.2f} {result['p90_ms']:>8.2f} {result['p99_ms']:>8.2f} "
                      f"{result['max_ms']:>8.2f} {result['mean_ms']:>8.2f}")
        if args.json:
            args.json.write_text(json.dumps({"summary": summary, "cases": cases}, indent=2), encoding="utf-8")
        failed = any(not case["done"] for case in cases)
        return 1 if failed else 0
    finally:
        if args.keep:
            print(f"work directory: {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
