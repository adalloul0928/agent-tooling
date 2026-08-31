from pathlib import Path
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]


class CIContractTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
