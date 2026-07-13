from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
DOCTOR = REPO_ROOT / "scripts" / "doctor"


class DoctorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.home = self.root / "home"
        self.profiles = self.root / "profiles"
        self.home.mkdir()
        self.profiles.mkdir()

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def write_json(self, path: Path, data: object) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data), encoding="utf-8")

    def run_doctor(self, profile: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "python3",
                str(DOCTOR),
                profile,
                "--profiles-dir",
                str(self.profiles),
                "--home",
                str(self.home),
                "--json",
            ],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_composes_profiles_and_reports_pass_and_manual(self) -> None:
        self.write_json(
            self.home / ".claude/settings.json",
            {"enabledPlugins": {"obsidian@agent-tooling": True}},
        )
        self.write_json(
            self.home / ".claude/plugins/known_marketplaces.json",
            {"agent-tooling": {"source": {"ref": "release-1"}}},
        )
        codex = self.home / ".codex/config.toml"
        codex.parent.mkdir(parents=True)
        codex.write_text(
            '[plugins."obsidian@agent-tooling"]\nenabled = true\n'
            '[marketplaces.agent-tooling]\nref = "release-1"\n',
            encoding="utf-8",
        )
        self.write_json(
            self.profiles / "base.json",
            {
                "schema_version": 1,
                "name": "base",
                "variables": {"release": "release-1"},
                "checks": [
                    {"id": "claude-plugin", "kind": "claude_plugin", "plugin": "obsidian@agent-tooling", "expected": "enabled"},
                    {"id": "codex-plugin", "kind": "codex_plugin", "plugin": "obsidian@agent-tooling", "expected": "enabled"},
                    {"id": "claude-market", "kind": "claude_marketplace", "name": "agent-tooling", "expected": "present", "ref": "${release}"},
                    {"id": "codex-market", "kind": "codex_marketplace", "name": "agent-tooling", "expected": "present", "ref": "${release}"}
                ],
                "manual_checks": [
                    {"id": "hosted", "description": "Verify hosted account", "last_verified": None}
                ]
            },
        )
        self.write_json(
            self.profiles / "child.json",
            {"schema_version": 1, "name": "child", "extends": ["base.json"]},
        )

        result = self.run_doctor("child")

        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["summary"], {"fail": 0, "manual": 1, "pass": 4, "warn": 0})

    def test_required_drift_fails_and_advisory_drift_warns(self) -> None:
        self.write_json(
            self.profiles / "drift.json",
            {
                "schema_version": 1,
                "name": "drift",
                "checks": [
                    {"id": "missing", "kind": "path", "path": "~/missing.md", "path_type": "file", "expected": "present"},
                    {"id": "legacy", "kind": "claude_marketplace", "name": "legacy", "expected": "absent", "severity": "warning"}
                ]
            },
        )
        self.write_json(
            self.home / ".claude/plugins/known_marketplaces.json",
            {"legacy": {"source": {"repo": "example/legacy"}}},
        )

        result = self.run_doctor("drift")

        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertEqual(report["summary"]["fail"], 1)
        self.assertEqual(report["summary"]["warn"], 1)

    def test_detects_profile_inheritance_cycles(self) -> None:
        self.write_json(
            self.profiles / "a.json",
            {"schema_version": 1, "name": "a", "extends": ["b.json"]},
        )
        self.write_json(
            self.profiles / "b.json",
            {"schema_version": 1, "name": "b", "extends": ["a.json"]},
        )

        result = self.run_doctor("a")

        self.assertEqual(result.returncode, 65)
        self.assertIn("inheritance cycle", result.stderr)

    def test_rejects_unknown_check_kinds(self) -> None:
        self.write_json(
            self.profiles / "invalid.json",
            {
                "schema_version": 1,
                "name": "invalid",
                "checks": [{"id": "invalid", "kind": "mutate_everything"}],
            },
        )

        result = self.run_doctor("invalid")

        self.assertEqual(result.returncode, 65)
        self.assertIn("unsupported check kind", result.stderr)


if __name__ == "__main__":
    unittest.main()
