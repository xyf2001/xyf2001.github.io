"""验证测试运行器不会把空日志、跳过或引擎失败当作通过。"""
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("run_tests", Path(__file__).parents[1] / "tools" / "run_tests.py")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class ResultIntegrityTests(unittest.TestCase):
    def test_no_assertions_is_failure(self):
        self.assertEqual(runner.classify(0, [])[0], "FAIL")

    def test_process_error_cannot_pass(self):
        self.assertEqual(runner.classify(1, [{"status": "PASS"}])[0], "FAIL")

    def test_timeout_cannot_pass(self):
        self.assertEqual(runner.classify(0, [{"status": "PASS"}], True)[0], "FAIL")

    def test_skipped_does_not_become_pass(self):
        self.assertEqual(runner.classify(77, [{"status": "NOT TESTED"}])[0], "NOT TESTED")
        self.assertEqual(runner.classify(77, [{"status": "PASS"}, {"status": "NOT TESTED"}])[0], "NOT TESTED")
        self.assertEqual(runner.classify(0, [{"status": "PASS"}, {"status": "NOT TESTED"}])[0], "NOT TESTED")

    def test_failed_assertion_wins(self):
        self.assertEqual(runner.classify(0, [{"status": "PASS"}, {"status": "FAIL"}])[0], "FAIL")

    def test_structured_result_only(self):
        raw = '随意 PASS\nCHROMATIC_TEST {"status":"PASS","name":"真实断言"}\nCHROMATIC_TEST invalid\n'
        self.assertEqual(len(runner.read_results(raw)), 1)
        self.assertEqual(runner.classify(0, runner.read_results(raw))[0], "PASS")


if __name__ == "__main__":
    unittest.main(verbosity=2)
