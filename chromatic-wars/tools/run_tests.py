#!/usr/bin/env python3
"""运行真实 Godot 测试，保留原始输出；没有断言绝不报告通过。"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import time

RESULT_PREFIX = "CHROMATIC_TEST "


def read_results(output: str) -> list[dict]:
    results = []
    for line in output.splitlines():
        if line.startswith(RESULT_PREFIX):
            try:
                result = json.loads(line[len(RESULT_PREFIX):])
            except json.JSONDecodeError:
                continue
            if isinstance(result, dict) and result.get("status") in {"PASS", "FAIL", "NOT TESTED"}:
                results.append(result)
    return results


def classify(returncode: int | None, results: list[dict], timed_out: bool = False) -> tuple[str, str]:
    if timed_out:
        return "FAIL", "超过截止时间，已终止进程"
    if returncode == 77 and results and any(r["status"] == "NOT TESTED" for r in results) and not any(r["status"] == "FAIL" for r in results):
        return "NOT TESTED", "运行环境不满足此套件要求"
    if returncode != 0:
        return "FAIL", f"Godot 退出码 {returncode}"
    if any(r["status"] == "FAIL" for r in results):
        return "FAIL", "断言失败"
    if not any(r["status"] == "PASS" for r in results):
        return "FAIL", "没有实际通过的断言，不能报告测试通过"
    if any(r["status"] == "NOT TESTED" for r in results):
        return "NOT TESTED", "套件含未执行项目，请查看逐项结果"
    return "PASS", f"实际通过 {len(results)} 项断言"


def run_command(command: list[str], cwd: Path, log_path: Path, timeout: float, env: dict) -> dict:
    started = time.monotonic()
    timed_out = False
    with log_path.open("w", encoding="utf-8") as log:
        log.write("命令：" + shlex.join(command) + "\n")
        log.flush()
        try:
            proc = subprocess.Popen(command, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT,
                                    start_new_session=True)
        except OSError as error:
            log.write(f"启动失败：{error}\n")
            return {"returncode": 127, "elapsed_seconds": time.monotonic() - started,
                    "timed_out": False, "error": str(error)}
        try:
            returncode = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
            returncode = proc.returncode
            log.write(f"\nFAIL：超过 {timeout:g} 秒截止时间。\n")
    return {"returncode": returncode, "elapsed_seconds": round(time.monotonic() - started, 3),
            "timed_out": timed_out}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=shutil.which("godot") or shutil.which("godot4"))
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--suite", choices=["cpu", "channel_floor", "pinball_properties", "settings", "gpu", "contact_energy", "pool_integrity", "weapon_validation", "stress", "battle", "all"], default="all")
    parser.add_argument("--timeout", type=float, default=900, help="每个套件的真实时间截止秒数")
    parser.add_argument("--duration", type=float, default=1200, help="左侧长局测试的模拟秒数")
    parser.add_argument("--seed", type=int, default=20261016)
    parser.add_argument("--capacity", type=int, default=10000, help="GPU 压力测试容量")
    parser.add_argument("--speed", type=float, default=1.0, choices=[1.0, 2.0, 4.0], help="完整对局的目标模拟倍率")
    parser.add_argument("--wall-seconds", type=float, default=3600, help="长局真实时间预算，达到预算但不足目标模拟时长会标记未测试")
    parser.add_argument("--wrapper", default="", help="图形套件的可选命令前缀，例如 xvfb-run -a")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--import-project", action="store_true", help="先在图形环境执行编辑器导入")
    args = parser.parse_args(argv)
    if args.timeout <= 0 or args.duration <= 0 or args.capacity <= 0:
        parser.error("时间与容量必须大于0")
    args.project = args.project.resolve()
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    output_dir = (args.output or args.project / "artifacts" / "tests" / timestamp).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    suites = ["settings", "channel_floor", "cpu", "pinball_properties", "contact_energy", "pool_integrity", "weapon_validation", "gpu"] if args.suite == "all" else [args.suite]
    report = {"started_utc": timestamp, "project": str(args.project), "suites": [],
              "seed": args.seed, "duration_sim_seconds": args.duration,
              "host": {"platform": sys.platform}, "godot": args.godot}
    env = os.environ.copy()
    # Godot/fontconfig need writable user directories in cloud sandboxes.
    for key, child in [("XDG_CACHE_HOME", "cache"), ("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data")]:
        if not env.get(key):
            directory = output_dir / "runtime" / child
            directory.mkdir(parents=True, exist_ok=True)
            env[key] = str(directory)
    if not args.godot:
        report["suites"].append({"name": "runtime", "status": "NOT TESTED", "reason": "找不到 Godot 4 可执行文件"})
    else:
        binary = str(Path(args.godot).resolve()) if "/" in args.godot else args.godot
        common = [binary, "--path", str(args.project)]
        if args.import_project:
            import_log = output_dir / "import.log"
            outcome = run_command(shlex.split(args.wrapper) + common + ["--editor", "--import", "--quit"],
                                  args.project, import_log, args.timeout, env)
            import_text = import_log.read_text(encoding="utf-8", errors="replace")
            errors = [line for line in import_text.splitlines()
                      if "SCRIPT ERROR:" in line or "SHADER ERROR:" in line or "Parse Error:" in line]
            ok = outcome["returncode"] == 0 and not outcome["timed_out"] and not errors
            report["suites"].append({"name": "import", "status": "PASS" if ok else "FAIL",
                                     "reason": "实际编辑器导入" if ok else "导入失败，查看原始日志",
                                     "log": str(import_log), **outcome})
        for suite in suites:
            script = args.project / "tests" / (suite + "_suite.gd")
            if not script.is_file():
                report["suites"].append({"name": suite, "status": "NOT TESTED", "reason": "测试脚本尚不存在"})
                continue
            graphical = suite not in {"cpu", "channel_floor", "settings", "pinball_properties"}
            if graphical and not env.get("DISPLAY") and not env.get("WAYLAND_DISPLAY") and not args.wrapper:
                report["suites"].append({"name": suite, "status": "NOT TESTED",
                    "reason": "没有图形显示。GPU 套件必须使用 Vulkan 普通窗口，可通过 --wrapper 'xvfb-run -a' 运行；不能用 --headless 代替"})
                continue
            command = (shlex.split(args.wrapper) if graphical else []) + common
            command += (["--rendering-method", "forward_plus", "--rendering-driver", "vulkan", "--audio-driver", "Dummy"] if graphical else ["--headless"])
            command += ["--script", "res://tests/" + suite + "_suite.gd", "--", "--seed", str(args.seed),
                        "--duration", str(args.duration), "--capacity", str(args.capacity), "--speed", str(args.speed),
                        "--wall_seconds", str(args.wall_seconds), "--artifact-dir", str(output_dir)]
            log_path = output_dir / (suite + ".log")
            print(f"正在运行 {suite}，截止 {args.timeout:g} 秒；日志：{log_path}", flush=True)
            outcome = run_command(command, args.project, log_path, args.timeout, env)
            raw = log_path.read_text(encoding="utf-8", errors="replace")
            results = read_results(raw)
            status, reason = classify(outcome["returncode"], results, outcome["timed_out"])
            # Godot can return 0 after parse/runtime errors: those cannot count as passing.
            engine_errors = [line for line in raw.splitlines()
                             if "SCRIPT ERROR:" in line or "SHADER ERROR:" in line or "Parse Error:" in line]
            if engine_errors:
                status, reason = "FAIL", "Godot 报告脚本或着色器错误"
            report["suites"].append({"name": suite, "status": status, "reason": reason, "results": results,
                                     "engine_errors": engine_errors, "log": str(log_path), **outcome})
            print(f"{status}：{suite}：{reason}", flush=True)
    statuses = [r["status"] for r in report["suites"]]
    report["status"] = "FAIL" if "FAIL" in statuses else ("NOT TESTED" if "NOT TESTED" in statuses else "PASS")
    if not statuses:
        report["status"] = "FAIL"
    (output_dir / "results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    lines = ["# 实际自动测试记录", "", f"总状态：**{report['status']}**", "",
             "原始输出与结构化结果保存在同一目录。此记录仅证明实际执行的断言；不替代 Windows、画面观感和真实显卡性能验收。", ""]
    for suite in report["suites"]:
        lines += [f"## {suite['name']}：{suite['status']}", "", suite["reason"], ""]
        if suite.get("log"):
            lines += [f"原始日志：`{Path(suite['log']).name}`", ""]
        for result in suite.get("results", []):
            lines.append(f"- {result['status']}：{result.get('name', '未命名')} — {result.get('detail', '')}")
        lines.append("")
    (output_dir / "REPORT.md").write_text("\n".join(lines), encoding="utf-8")
    print(f"{report['status']}：结果已写入 {output_dir}")
    return 1 if report["status"] == "FAIL" else (77 if report["status"] == "NOT TESTED" else 0)


if __name__ == "__main__":
    raise SystemExit(main())
