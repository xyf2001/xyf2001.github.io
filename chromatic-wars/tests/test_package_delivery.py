"""Packaging safeguards using tiny temporary fixtures; does not execute Godot or an EXE."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SPEC = importlib.util.spec_from_file_location("package_delivery", Path(__file__).parents[1] / "tools/package_delivery.py")
delivery = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(delivery)


class DeliveryEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "project"
        files = {
            "project.godot": "fixture", "export_presets.cfg": "fixture",
            "scenes/main.tscn": "fixture", "scripts/main.gd": "fixture",
            "scripts/main.gd.uid": "uid://fixture", "shaders/battle.glsl": "fixture",
            "assets/chinese_ui.otf": "fixture", "assets/字体许可.txt": "fixture",
            "README.md": "fixture", "CHANGELOG.md": "fixture", "TEST_REPORT.md": "PARTIAL fixture",
            "export/颜色大战.exe": "fixture executable, never run",
            "artifacts/runtime-before-fix/runtime_results.json": '{"status":"FAIL"}',
            "artifacts/runtime-final/runtime_results.json": '{"status":"PASS"}',
            "artifacts/check/runtime/cache/generated.bin": "cache",
            ".godot/imported/generated.res": "cache",
        }
        for name, value in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(value, encoding="utf-8")
        self.exe = self.root / "export/颜色大战.exe"
        self.validation = self.root / "artifacts/release_validation.json"
        self.pck = self.root / "artifacts/pck/export_pck.json"
        self.pck.parent.mkdir()
        self.write_evidence()

    def write_evidence(self, status="PASS", pck_sha=True):
        self.validation.write_text(json.dumps({"status": status, "runtime_source_sha256": delivery.runtime_source_hashes(self.root)}))
        self.pck.write_text(json.dumps({"status": "PASS", "main_pack_sha256": delivery.digest(self.exe) if pck_sha else "old_sha", "execution_os": "Linux", "device": "llvmpipe fixture"}))

    def validate(self, allow_partial=False):
        return delivery.validate_release_evidence(self.root, self.exe, self.validation, self.pck, allow_partial)

    def test_current_hashes_accept_pass(self):
        status, hashes, _ = self.validate()
        self.assertEqual(status, "PASS")
        self.assertIn("scripts/main.gd", hashes)
        self.assertNotIn("scripts/main.gd.uid", hashes)

    def test_partial_requires_explicit_flag_and_fail_cannot_be_waived(self):
        self.write_evidence("PARTIAL")
        with self.assertRaises(RuntimeError):
            self.validate()
        self.assertEqual(self.validate(True)[0], "PARTIAL")
        self.write_evidence("FAIL")
        with self.assertRaises(RuntimeError):
            self.validate(True)

    def test_changed_source_rejects_previous_validation(self):
        (self.root / "shaders/battle.glsl").write_text("changed")
        with self.assertRaisesRegex(RuntimeError, "源码SHA256"):
            self.validate()

    def test_missing_source_fingerprint_rejects_historical_report(self):
        self.validation.write_text('{"status":"PASS"}')
        with self.assertRaises(RuntimeError):
            self.validate()

    def test_changed_executable_rejects_previous_pck_smoke(self):
        self.exe.write_text("new executable")
        with self.assertRaisesRegex(RuntimeError, "当前Windows EXE"):
            self.validate()

    def test_missing_pack_hash_cannot_pass(self):
        self.pck.write_text('{"status":"PASS"}')
        with self.assertRaises(RuntimeError):
            self.validate()

    def test_archive_member_verification_checks_actual_bytes(self):
        archive = self.base / "fixture.zip"
        delivery.build_zip(archive, [(self.exe, "fixture.exe")])
        with self.assertRaises(RuntimeError):
            delivery.verify_member_hashes(archive, {"fixture.exe": "invalid_sha"})

    def test_partial_archive_preserves_failed_evidence_and_native_limits(self):
        self.write_evidence("PARTIAL")
        output = self.base / "delivery"
        argv = ["package_delivery.py", "--output", str(output), "--validation-file", "artifacts/release_validation.json", "--pck-dir", "artifacts/pck", "--allow-partial-validation"]
        with patch.object(delivery, "__file__", str(self.root / "tools/package_delivery.py")), patch("sys.argv", argv), contextlib.redirect_stdout(io.StringIO()):
            delivery.main()
        info = json.loads((self.root / "BUILD_INFO.json").read_text())
        self.assertEqual(info["release_validation_status"], "PARTIAL")
        self.assertEqual(info["windows_os_execution"], "NOT TESTED")
        self.assertEqual(info["physical_gpu_execution"], "NOT TESTED")
        self.assertEqual(info["export_pck_main_pack_sha256"], info["windows_exe_sha256"])
        with zipfile.ZipFile(output / "颜色大战_Godot工程.zip") as archive:
            names = archive.namelist()
            self.assertIn("ChromaticWars/scripts/main.gd.uid", names)
            self.assertIn("ChromaticWars/artifacts/runtime-before-fix/runtime_results.json", names)
            self.assertIn("ChromaticWars/artifacts/runtime-final/runtime_results.json", names)
            self.assertFalse(any("/.godot/" in n or "/runtime/cache/" in n or "/export/" in n for n in names))
        with zipfile.ZipFile(output / "颜色大战_Windows_x64.zip") as archive:
            self.assertIn("artifacts/runtime-before-fix/runtime_results.json", archive.namelist())
            self.assertIn("PARTIAL", archive.read("运行说明.txt").decode("utf-8-sig"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
