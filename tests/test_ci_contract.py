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
        self.assertIn("EXPECTED_SIGNING_TEAM_ID: 434X69L4Z5", release)
        self.assertIn("com.arendalloul.agent-tooling.cli", release)
        self.assertIn("com.arendalloul.agent-tooling.mcp", release)

    def test_macos_release_runbook_separates_commit_and_tag_authority(self) -> None:
        runbook = (REPOSITORY_ROOT / "docs/macos-app-release.md").read_text()

        self.assertIn("Branch ancestry authorizes the source", runbook)
        self.assertIn("does **not** authorize the separate tag object", runbook)
        self.assertIn("MACOS_RELEASE_ALLOWED_ACTORS", runbook)
        self.assertIn("environment secrets", runbook)
        self.assertIn("prevents tag updates and deletion", runbook)


if __name__ == "__main__":
    unittest.main()
