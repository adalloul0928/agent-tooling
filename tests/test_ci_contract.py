from pathlib import Path
import os
import re
import shlex
import subprocess
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]


class CIContractTests(unittest.TestCase):
    def macos_validation_jobs(self) -> dict[str, str]:
        workflow = (REPOSITORY_ROOT / ".github/workflows/macos-app.yml").read_text()
        jobs = workflow.split("\njobs:\n", maxsplit=1)[1]
        return dict(re.findall(r"(?ms)^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)", jobs))

    def test_auto_merge_waits_for_the_aggregate_validation_workflow(self) -> None:
        validation = (REPOSITORY_ROOT / ".github/workflows/validate.yml").read_text()
        auto_merge = (REPOSITORY_ROOT / ".github/workflows/guarded-auto-merge.yml").read_text()

        self.assertIn("macos-app:\n    uses: ./.github/workflows/macos-app.yml", validation)
        self.assertIn("- Validate agent tooling", auto_merge)
        self.assertIn("github.event.workflow_run.conclusion == 'success'", auto_merge)
        self.assertIn("test \"$(jq -r '.headRefOid' <<<\"$pr\")\" = \"$VALIDATED_SHA\"", auto_merge)

    def test_required_macos_gate_includes_thread_sanitizer_and_release_build(self) -> None:
        workflow = (REPOSITORY_ROOT / ".github/workflows/macos-app.yml").read_text()

        self.assertIn("swift test --disable-sandbox --sanitize=thread", workflow)
        self.assertIn("swift build --configuration release -Xswiftc -warnings-as-errors", workflow)
        self.assertIn("codesign --verify --deep --strict", workflow)

    def test_macos_validation_jobs_run_independently_before_the_required_gate(self) -> None:
        jobs = self.macos_validation_jobs()
        lanes = {"debug", "thread", "release", "package"}
        self.assertEqual(set(jobs), lanes | {"build"})
        for lane in lanes:
            with self.subTest(lane=lane):
                self.assertRegex(jobs[lane], r"(?m)^    runs-on: macos-26$")
                self.assertNotRegex(jobs[lane], r"(?m)^    (?:needs|if|continue-on-error):")
                self.assertNotIn("continue-on-error:", jobs[lane])

        gate = jobs["build"]
        self.assertIn("    name: Test and package\n", gate)
        self.assertRegex(gate, r"(?m)^    runs-on: ubuntu-latest$")
        needs = re.search(r"(?m)^    needs: \[([^\]]+)\]$", gate)
        self.assertIsNotNone(needs, "The required gate must wait for every macOS job")
        self.assertEqual({job.strip() for job in needs.group(1).split(",")}, lanes)
        condition = re.search(r"(?m)^    if: (.+)$", gate)
        self.assertIsNotNone(condition, "The required gate must run even when a dependency fails")
        self.assertEqual(condition.group(1).removeprefix("${{").removesuffix("}}").strip(), "always()")
        self.assertNotIn("continue-on-error:", gate)

    def test_macos_required_gate_rejects_every_non_success_result(self) -> None:
        gate = self.macos_validation_jobs()["build"]
        results = dict(re.findall(r"(?m)^ +([A-Z_]+): \$\{\{ needs\.([\w-]+)\.result \}\}$", gate))
        self.assertEqual(set(results.values()), {"debug", "thread", "release", "package"})
        self.assertEqual(len(results), 4)
        runs = list(re.finditer(r"(?m)^( +)run: \|\n", gate))
        self.assertEqual(len(runs), 1, "Exercise the required gate's actual shell script")
        run = runs[0]
        indentation = len(run.group(1)) + 2
        script_lines = []
        for line in gate[run.end():].splitlines():
            if line.strip() and not line.startswith(" " * indentation):
                break
            script_lines.append(line[indentation:])
        script = "\n".join(script_lines)
        self.assertTrue(script.strip())

        def gate_result(overrides: dict[str, str]) -> subprocess.CompletedProcess[str]:
            environment = {**os.environ, **{name: "success" for name in results}, **overrides}
            return subprocess.run(
                ["bash", "--noprofile", "--norc", "-e", "-c", script],
                env=environment, capture_output=True, text=True, timeout=10,
            )

        passed = gate_result({})
        self.assertEqual(passed.returncode, 0, passed.stderr)
        for name, lane in results.items():
            for result in ("failure", "cancelled", "skipped", "neutral", ""):
                with self.subTest(lane=lane, result=result):
                    self.assertNotEqual(gate_result({name: result}).returncode, 0)

    def test_swift_testing_reports_are_validated_at_the_requested_path(self) -> None:
        for name, expected_runs in (("macos-app.yml", 6), ("release-macos-app.yml", 2)):
            workflow = (REPOSITORY_ROOT / ".github/workflows" / name).read_text()
            lines = [line.strip() for line in workflow.replace("\\\n", " ").splitlines() if line.strip()]
            runs = [(index, shlex.split(line)) for index, line in enumerate(lines) if line.startswith("swift test ")]
            self.assertEqual(len(runs), expected_runs, f"{name}: every test lane must produce a checked report")
            for index, command in runs:
                with self.subTest(workflow=name, command=command):
                    self.assertIn("--disable-xctest", command, "XCTest redirects Swift Testing reports to another path")
                    self.assertNotIn("--enable-xctest", command)
                    self.assertIn("--xunit-output", command)
                    report_index = command.index("--xunit-output") + 1
                    self.assertLess(report_index, len(command), "The report path is required")
                    self.assertLess(index + 1, len(lines), "The report must be validated after the test run")
                    self.assertEqual(
                        shlex.split(lines[index + 1]),
                        ["../../scripts/check-test-report", command[report_index]],
                        "Validate the same report path immediately after the test run",
                    )

    def test_disabling_xctest_does_not_skip_repository_tests(self) -> None:
        sources = list((REPOSITORY_ROOT / "apps/agent-tooling-macos/Tests").rglob("*.swift"))
        self.assertTrue(sources, "Expected Swift test sources")
        xctest = re.compile(r"\bimport(?:\s+(?:class|struct|enum|protocol|func|var|let|typealias))?\s+XCTest\b|\bXCTestCase\b")
        for source in sources:
            with self.subTest(source=source.relative_to(REPOSITORY_ROOT)):
                self.assertNotRegex(
                    source.read_text(), xctest,
                    "CI disables XCTest; add an XCTest lane and validate its report before introducing XCTest tests",
                )

    def test_macos_release_authorizes_tag_before_secret_bearing_job(self) -> None:
        workflow = (REPOSITORY_ROOT / ".github/workflows/release-macos-app.yml").read_text()
        authorize, release = workflow.split("\n  release:\n", maxsplit=1)

        self.assertIn("\n  authorize:\n", authorize)
        self.assertIn("permissions:\n  contents: read", authorize)
        self.assertNotIn("secrets.", authorize)
        self.assertIn("MACOS_RELEASE_ALLOWED_ACTORS", authorize)
        self.assertIn('git cat-file -t "$tag_ref"', authorize)
        self.assertIn('!= "tag"', authorize)
        self.assertIn('git merge-base --is-ancestor "$release_commit" "$default_branch_tip"', authorize)
        self.assertIn("needs: authorize", release)
        self.assertIn("environment: macos-release", release)
        self.assertIn("permissions:\n      contents: write", release)
        self.assertIn("ref: ${{ needs.authorize.outputs.release_commit }}", release)
        self.assertIn("secrets.MACOS_CERTIFICATE_P12_BASE64", release)
        self.assertIn("MACOS_SIGNING_TEAM_ID", release)
        self.assertIn("dev.agenttooling.app.cli", release)
        self.assertIn("dev.agenttooling.app.mcp", release)
        self.assertIn("./scripts/check-public-content", authorize)

    def test_macos_release_runbook_separates_commit_and_tag_authority(self) -> None:
        runbook = (REPOSITORY_ROOT / "docs/macos-app-release.md").read_text()

        self.assertIn("MACOS_RELEASE_ALLOWED_ACTORS", runbook)
        self.assertIn("MACOS_SIGNING_TEAM_ID", runbook)
        self.assertIn("macos-release", runbook)

    def test_macos_release_verifies_distribution_before_publication(self) -> None:
        workflow = (REPOSITORY_ROOT / ".github/workflows/release-macos-app.yml").read_text()
        for prerequisite in ("--verify-resources", "verify-dmg.sh", "notarytool submit", "stapler validate", "spctl --assess"):
            self.assertLess(workflow.index(prerequisite), workflow.index("gh release create"))


if __name__ == "__main__":
    unittest.main()
