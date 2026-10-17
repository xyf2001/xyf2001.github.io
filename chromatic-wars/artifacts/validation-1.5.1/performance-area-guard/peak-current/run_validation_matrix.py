#!/usr/bin/env python3
"""Run the identical Vulkan fixture on baseline/current, retaining raw per-batch data."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shlex
import signal
import statistics
import subprocess
import time

SOURCE_FILES = ("shaders/battle.glsl", "scripts/gpu_world.gd", "scripts/gpu_collisions.gd", "scripts/gpu_emitters.gd", "scripts/gpu_render.gd", "scripts/game_settings.gd", "project.godot", "tools/validation_matrix.gd")

def source_hashes(project: Path, extra_files: tuple[str, ...] = ()) -> dict[str, str]:
    names = dict.fromkeys(SOURCE_FILES + extra_files)
    return {name: hashlib.sha256((project / name).read_bytes()).hexdigest() for name in names}

def execution_tool_hashes(project: Path) -> dict[str, str]:
    names = ("tools/run_validation_matrix.py", "tools/run_tests.py")
    return {name: hashlib.sha256((project / name).read_bytes()).hexdigest() for name in names}

def git_metadata(project: Path) -> dict:
    try:
        commit = subprocess.run(["git", "-C", str(project), "rev-parse", "HEAD"], capture_output=True, text=True, check=False)
        if commit.returncode:
            return {"available":False,"commit":None,"reason":"snapshot is not a Git working tree; source SHA256 is recorded"}
        status = subprocess.run(["git", "-C", str(project), "status", "--porcelain", "--untracked-files=no", "--", "."], capture_output=True, text=True, check=False)
        return {"available":True,"commit":commit.stdout.strip(),"tracked_worktree_dirty":bool(status.stdout.strip()),"tracked_changes_porcelain":status.stdout}
    except OSError as error:
        return {"available":False,"commit":None,"reason":str(error)}

DEFAULT_CASES = "uniform:1000:10000,uniform:10000:10000,uniform:1000:100000,uniform:10000:100000,uniform:1000:1000000,uniform:10000:1000000,uniform:5000:10000,uniform:30000:30000,uniform:50000:50000,uniform:100000:100000,dense_crossing:1000:10000,fast_sniper:1000:10000,four_storm:1000:10000"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--fixture", type=Path, default=Path("tools/validation_matrix.gd"), help="Standalone fixture inside current project; parent matrix is copied alongside it")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--cases", default=DEFAULT_CASES)
    parser.add_argument("--samples", type=int, default=60)
    parser.add_argument("--warmup", type=int, default=10)
    parser.add_argument("--profiling", action="store_true", help="Counters only; use disabled for primary performance comparison")
    parser.add_argument("--case-timeout", type=int, default=180)
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument("--affinity", default="", help="Optional Linux CPU affinity, e.g. 0-3")
    parser.add_argument("--threads", type=int, default=4, help="llvmpipe LP_NUM_THREADS; recorded, not a GPU hardware setting")
    args = parser.parse_args()
    if args.samples < 1 or args.warmup < 0:
        parser.error("samples must be positive and warmup nonnegative")
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = (args.output or args.project / "artifacts" / "validation" / stamp).resolve()
    output.mkdir(parents=True, exist_ok=True)
    project_root = args.project.resolve()
    source_fixture = (args.fixture if args.fixture.is_absolute() else project_root / args.fixture).resolve()
    try:
        fixture_relative = source_fixture.relative_to(project_root)
    except ValueError:
        parser.error("fixture must be inside current project")
    fixture = source_fixture.read_bytes()
    parent_relative = Path("tools/validation_matrix.gd")
    assets = {parent_relative: (project_root / parent_relative).read_bytes(), fixture_relative: fixture}
    asset_metadata = {}
    for relative, contents in assets.items():
        evidence = relative.stem + "_fixture" + relative.suffix
        (output / evidence).write_bytes(contents)
        asset_metadata[relative.as_posix()] = {"sha256":hashlib.sha256(contents).hexdigest(),"evidence_file":evidence}
    frozen_execution_tools = execution_tool_hashes(project_root)
    for name in frozen_execution_tools:
        (output / Path(name).name).write_bytes((project_root / name).read_bytes())
    report = {"started_utc":stamp,"fixture_schema_version":3,
              "intended_current_rule_version":"1.5.1-energy-magazine",
              "throughput_schema":"v2: measured completed steps / full measured wall interval",
              "behavior_note":"current rules include real mechanical CCD corrections; historical peak ratios are not pure optimization comparisons",
              "execution_tool_sha256_before":frozen_execution_tools,
              "fixture_sha256":hashlib.sha256(fixture).hexdigest(),
              "fixture_relative_path":fixture_relative.as_posix(),"fixture_assets":asset_metadata,
              "samples":args.samples,"warmup":args.warmup,"cases":args.cases,
              "profiling":args.profiling,"affinity":args.affinity,"LP_NUM_THREADS":args.threads,
              "physical_vram_claim":False,"hardware_fps_claim":False,
              "cgroup_cpu_max":Path("/sys/fs/cgroup/cpu.max").read_text().strip() if Path("/sys/fs/cgroup/cpu.max").exists() else None,
              "cgroup_cpuset_effective":Path("/sys/fs/cgroup/cpuset.cpus.effective").read_text().strip() if Path("/sys/fs/cgroup/cpuset.cpus.effective").exists() else None,
              "runs":[]}
    env = os.environ.copy()
    env["LP_NUM_THREADS"] = str(args.threads)
    for label, project in (([("baseline", args.baseline)] if args.baseline else []) + [("current", args.project)]):
        project = project.resolve()
        for relative, contents in assets.items():
            target_fixture = project / relative
            if target_fixture != project_root / relative:
                # Only standalone test fixtures are copied; baseline game sources stay frozen.
                target_fixture.parent.mkdir(parents=True,exist_ok=True)
                target_fixture.write_bytes(contents)
        result_path = output / (label + "_matrix.json")
        log_path = output / (label + "_matrix.log")
        command = (["taskset", "-c", args.affinity] if args.affinity else []) + [args.godot,"--path",str(project),
            "--rendering-method","forward_plus","--rendering-driver","vulkan","--audio-driver","Dummy",
            "--script","res://"+fixture_relative.as_posix(),"--","--cases",args.cases,
            "--samples",str(args.samples),"--warmup",str(args.warmup),"--profiling",str(args.profiling).lower(),
            "--case-timeout",str(args.case_timeout),"--json",str(result_path)]
        hashes_before = source_hashes(project,(fixture_relative.as_posix(),))
        git_before = git_metadata(project)
        started = time.monotonic()
        cpu_stat = Path("/sys/fs/cgroup/cpu.stat")
        cgroup_before = cpu_stat.read_text() if cpu_stat.exists() else None
        timed_out = False
        with log_path.open("w",encoding="utf-8") as log:
            log.write("Command: " + shlex.join(command) + "\n")
            log.flush()
            proc = subprocess.Popen(command,cwd=project,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
            try:
                code = proc.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(proc.pid,signal.SIGTERM)
                try: code=proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid,signal.SIGKILL)
                    code=proc.wait()
        raw = log_path.read_text(encoding="utf-8",errors="replace")
        errors=[line for line in raw.splitlines() if line.startswith("ERROR:") or "SCRIPT ERROR:" in line or "SHADER ERROR:" in line or "Parse Error:" in line]
        data=json.loads(result_path.read_text()) if result_path.exists() else {}
        hashes_after = source_hashes(project,(fixture_relative.as_posix(),))
        execution_tools_after = execution_tool_hashes(project_root)
        ok=hashes_before==hashes_after and frozen_execution_tools==execution_tools_after and code==0 and not timed_out and not errors and data.get("results") and not data.get("failed",True)
        run={"label":label,"project":str(project),"returncode":code,"timed_out":timed_out,
             "elapsed_wall_seconds":time.monotonic()-started,"status":"PASS" if ok else "FAIL",
             "cgroup_cpu_before":cgroup_before,"cgroup_cpu_after":cpu_stat.read_text() if cpu_stat.exists() else None,
             "git_before":git_before,"git_after":git_metadata(project),
             "source_sha256_before":hashes_before,"source_sha256_after":hashes_after,"sources_unchanged_during_run":hashes_before==hashes_after,
             "execution_tool_sha256_after":execution_tools_after,
             "execution_tools_unchanged_during_run":frozen_execution_tools==execution_tools_after,
             "engine_errors":errors,"raw_log":str(log_path),"json":str(result_path),"summary":[]}
        for case in data.get("results",[]):
            totals=[float(sample["stages"]["gpu_ms_by_mode"]["TOTAL"]) for sample in case.get("samples",[])
                    if "TOTAL" in sample.get("stages",{}).get("gpu_ms_by_mode",{})]
            run["summary"].append({"scenario":case["scenario"],"active":case["requested_active"],"capacity":case["capacity"],
                "device":case.get("device"),"status":case["status"],"measured_batches":len(totals),
                "gpu_batch_p50_ms":statistics.median(totals) if totals else None,
                "gpu_batch_min_ms":min(totals) if totals else None,"gpu_batch_max_ms":max(totals) if totals else None,
                "drawn_fps_average":case.get("drawn_fps_average"),"drawn_fps_1pct_low":case.get("drawn_fps_1pct_low"),
                "step_batch_p50_ms":case.get("step_batch_p50_ms"),"initial":case.get("initial"),"final":case.get("final")})
        report["runs"].append(run)
        print(label + ": " + run["status"],flush=True)
        (output / "comparison.json").write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    return 0 if all(run["status"]=="PASS" for run in report["runs"]) else 1


if __name__ == "__main__":
    raise SystemExit(main())
