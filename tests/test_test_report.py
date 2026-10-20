from pathlib import Path
import subprocess
import tempfile
import unittest


CHECK = Path(__file__).resolve().parents[1] / "scripts/check-test-report"


class TestReportTests(unittest.TestCase):
    def check_report(self, content: str) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as folder:
            report = Path(folder) / "tests.xml"
            report.write_text(content)
            return subprocess.run([str(CHECK), str(report)], capture_output=True, text=True)

    def test_complete_successful_run_passes(self):
        for content in (
            '<testsuites><testsuite tests="1" failures="0" errors="0">'
            '<testcase name="setupReopens"/></testsuite></testsuites>',
            '<testsuites tests="3" skipped="1"><testsuite tests="3" skipped="1">'
            '<testcase name="setupReopens"/><testsuite tests="2" skipped="1">'
            '<testcase name="setupCloses"/><testcase name="optional"><skipped/></testcase>'
            '</testsuite></testsuite></testsuites>',
        ):
            with self.subTest(content=content):
                result = self.check_report(content)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_swift_tests_total_excludes_skipped_cases(self):
        report = (
            '<?xml version="1.0" encoding="UTF-8"?><testsuites>'
            '<testsuite name="TestResults" errors="0" tests="2" failures="0" skipped="1">'
            '<testcase classname="ExampleTests" name="first()"/>'
            '<testcase classname="ExampleTests" name="second()"/>'
            '<testcase classname="ExampleTests" name="optional()"><skipped/></testcase>'
            '</testsuite></testsuites>'
        )
        result = self.check_report(report)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.check_report(report.replace('tests="2"', 'tests="4"')).returncode, 1)
        self.assertEqual(self.check_report(report.removesuffix('</testsuite></testsuites>')).returncode, 1)

    def test_early_exit_zero_leaves_an_incomplete_report(self):
        result = self.check_report('<?xml version="1.0" encoding="UTF-8"?>\n<testsuites>\n')
        self.assertEqual(result.returncode, 1)

    def test_empty_and_entirely_skipped_runs_are_rejected(self):
        for content in (
            '<testsuites/>',
            '<testsuites><testsuite><testcase><skipped/></testcase></testsuite></testsuites>',
        ):
            with self.subTest(content=content):
                self.assertEqual(self.check_report(content).returncode, 1)

    def test_failures_are_rejected_even_if_process_exits_zero(self):
        for content in (
            '<testsuite failures="1"><testcase/></testsuite>',
            '<testsuite errors="1"><testcase/></testsuite>',
            '<testsuite><testcase><failure/></testcase></testsuite>',
            '<testsuite><testcase><error/></testcase></testsuite>',
        ):
            with self.subTest(content=content):
                self.assertEqual(self.check_report(content).returncode, 1)

    def test_root_aggregate_failures_are_rejected(self):
        for attribute in ("failures", "errors"):
            with self.subTest(attribute=attribute):
                result = self.check_report(
                    f'<testsuites {attribute}="1"><testsuite tests="1">'
                    '<testcase/></testsuite></testsuites>'
                )
                self.assertEqual(result.returncode, 1)

    def test_reported_counts_must_match_cases(self):
        for content in (
            '<testsuites tests="2"><testsuite tests="1"><testcase/></testsuite></testsuites>',
            '<testsuites><testsuite tests="2"><testcase/></testsuite></testsuites>',
            '<testsuites skipped="1"><testsuite><testcase/></testsuite></testsuites>',
            '<testsuite tests="2" skipped="0"><testcase/><testcase><skipped/></testcase></testsuite>',
        ):
            with self.subTest(content=content):
                self.assertEqual(self.check_report(content).returncode, 1)

    def test_missing_report_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            result = subprocess.run([str(CHECK), str(Path(folder) / "missing.xml")], capture_output=True)
        self.assertEqual(result.returncode, 1)


if __name__ == "__main__":
    unittest.main()
