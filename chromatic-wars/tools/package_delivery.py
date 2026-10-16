#!/usr/bin/env python3
"""打包源码、Windows成品及实际测试证据；不运行或伪造测试。"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import zipfile


def digest(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def include(path: Path, root: Path) -> bool:
    relative = path.relative_to(root)
    if any(part in {".godot", ".git", "export", "__pycache__", "runtime"} for part in relative.parts):
        return False
    return path.is_file() and path.suffix not in {".pyc", ".tmp"} and not (
        "artifacts" in relative.parts and path.suffix == ".import")


def build_zip(destination: Path, files: list[tuple[Path, str]]) -> None:
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path, name in files:
            archive.write(path, name)
    with zipfile.ZipFile(destination) as archive:
        bad = archive.testzip()
        if bad is not None:
            raise RuntimeError(f"ZIP校验失败：{bad}")
        for name in archive.namelist():
            if name.startswith("/") or ".." in Path(name).parts:
                raise RuntimeError(f"不安全的ZIP路径：{name}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("/workspace/deliverables"))
    parser.add_argument("--validation-file", default="artifacts/tests/final-battle-1200/results.json",
                        help="本次构建实际完成的Godot验证结果；历史长局不可冒充新版运行")
    parser.add_argument("--pck-dir", default="artifacts", help="本次实际导出资源验证所在目录")
    parser.add_argument("--release-label", default="initial")
    parser.add_argument("--untested", action="store_true",
                        help="按用户要求跳过运行验证，明确标记本次构建未经测试")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    if root == output or root in output.parents:
        raise ValueError("交付目录应在工程目录外")
    output.mkdir(parents=True, exist_ok=True)
    executable = root / "export" / "颜色大战.exe"
    if not executable.is_file():
        raise FileNotFoundError(executable)
    if args.untested:
        release_validation = "NOT TESTED (user requested)"
        export_resource_check = "NOT TESTED (user requested)"
    else:
        battle_path = root / args.validation_file
        if not battle_path.is_file():
            raise RuntimeError("本次验证尚无结束结果，不能打包为最终交付")
        battle = json.loads(battle_path.read_text())
        if battle["status"] != "PASS":
            raise RuntimeError("本次验证失败，请先诊断实际记录")
        pck_path = root / args.pck_dir / "export_pck.json"
        pck = json.loads(pck_path.read_text())
        if pck["status"] != "PASS":
            raise RuntimeError("最终内嵌PCK检查未通过")
        if "PENDING" in (root / "TEST_REPORT.md").read_text():
            raise RuntimeError("测试报告仍有未回填结果")
        release_validation = str(battle_path.relative_to(root))
        export_resource_check = str(pck_path.relative_to(root))
    runtime_files = [root / "project.godot", root / "export_presets.cfg"]
    for folder in ["scenes", "scripts", "shaders", "assets"]:
        runtime_files += [path for path in (root / folder).rglob("*") if path.is_file() and path.suffix not in {".import", ".uid"}]
    hashes = {str(path.relative_to(root)): digest(path) for path in sorted(runtime_files)}
    info = {"built_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
            "release_label": args.release_label,
            "godot": "4.6.3.stable.official.7d41c59c4",
            "target": "Windows x86_64, embedded PCK, Forward+/Vulkan",
            "windows_os_execution": "NOT TESTED",
            "physical_gpu_execution": "NOT TESTED",
            "windows_exe_sha256": digest(executable),
            "runtime_source_sha256": hashes,
            "test_report": "TEST_REPORT.md",
            "export_resource_check": export_resource_check,
            "release_validation": release_validation,
            "historical_battle_result": "artifacts/tests/final-battle-1200/results.json"}
    (root / "BUILD_INFO.json").write_text(json.dumps(info, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (root / "SOURCE_SHA256SUMS.txt").write_text("".join(f"{value}  {name}\n" for name, value in hashes.items()), encoding="utf-8")
    files = sorted(path for path in root.rglob("*") if include(path, root))
    source_zip = output / "颜色大战_Godot工程.zip"
    build_zip(source_zip, [(path, "ChromaticWars/" + path.relative_to(root).as_posix()) for path in files])
    with zipfile.ZipFile(source_zip) as archive:
        for required in ["project.godot", "scenes/main.tscn", "shaders/battle.glsl", "scripts/main.gd", "TEST_REPORT.md", "assets/chinese_ui.otf"]:
            if "ChromaticWars/" + required not in archive.namelist():
                raise RuntimeError(f"源码ZIP缺少{required}")
    windows_notes = output / "运行说明.txt"
    validation_notes = (
        "按用户要求，本构建未运行测试或内嵌资源/Compute运行验证。\n"
        "TEST_REPORT.md及artifacts中的历史结果不代表本次构建通过验证。\n"
        if args.untested else
        "先看TEST_REPORT.md：本构建实际导出并验证了内嵌资源/Compute，\n"
    )
    windows_notes.write_text(
        "颜色大战 · Windows x64\n\n"
        "解压整个压缩包，运行颜色大战.exe。需要Windows10/11、可用Vulkan显卡与驱动。\n"
        "默认0.25倍速；空格暂停/继续，N单步，R重开，Tab参数，F12截图。\n"
        f"{validation_notes}"
        "本构建未在Windows系统或实体显卡上运行，不能承诺硬件性能。\n"
        "运行错误会显示中文原因。完整可编辑源工程在另一个Godot工程ZIP。\n"
        "规则、精度、已知性能限制与操作见README.md，证据在artifacts。\n",
        encoding="utf-8-sig")
    selected = [(executable, "颜色大战.exe"), (windows_notes, "运行说明.txt"),
                (root / "assets/字体许可.txt", "字体许可.txt")]
    for name in ["README.md", "CHANGELOG.md", "TEST_REPORT.md", "BUILD_INFO.json", "SOURCE_SHA256SUMS.txt"]:
        selected.append((root / name, name))
    selected += [(path, path.relative_to(root).as_posix()) for path in files if path.relative_to(root).parts[0] in {"docs", "artifacts"}]
    windows_zip = output / "颜色大战_Windows_x64.zip"
    build_zip(windows_zip, selected)
    manifest = {"files": {path.name: {"bytes": path.stat().st_size, "sha256": digest(path)} for path in [source_zip, windows_zip]},
                "executable": {"filename": executable.name, "bytes": executable.stat().st_size, "sha256": digest(executable)},
                "zip_integrity": "PASS"}
    (output / "交付校验.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (output / "SHA256SUMS.txt").write_text("".join(f"{item['sha256']}  {name}\n" for name, item in manifest["files"].items()), encoding="utf-8")
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
