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

    def run_doctor(self, profile: str, *extra_args: str) -> subprocess.CompletedProcess[str]:
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
                *extra_args,
            ],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_composes_profiles_and_reports_pass_and_manual(self) -> None:
        self.write_json(
            self.home / ".claude/settings.json",
            {"enabledPlugins": {"personal@agent-tooling": True}},
        )
        self.write_json(
            self.home / ".claude/plugins/known_marketplaces.json",
            {"agent-tooling": {"source": {"ref": "release-1"}}},
        )
        codex = self.home / ".codex/config.toml"
        codex.parent.mkdir(parents=True)
        codex.write_text(
            '[plugins."personal@agent-tooling"]\nenabled = true\n'
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
                    {"id": "claude-plugin", "kind": "claude_plugin", "plugin": "personal@agent-tooling", "expected": "enabled"},
                    {"id": "codex-plugin", "kind": "codex_plugin", "plugin": "personal@agent-tooling", "expected": "enabled"},
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

    def test_checks_user_scoped_claude_and_codex_mcps(self) -> None:
        self.write_json(
            self.home / ".claude.json",
            {"mcpServers": {"analytics-mcp": {"command": "analytics-mcp"}}},
        )
        codex = self.home / ".codex/config.toml"
        codex.parent.mkdir(parents=True)
        codex.write_text(
            '[mcp_servers.analytics-mcp]\ncommand = "analytics-mcp"\n',
            encoding="utf-8",
        )
        self.write_json(
            self.profiles / "mcp.json",
            {
                "schema_version": 1,
                "name": "mcp",
                "checks": [
                    {"id": "claude-mcp", "kind": "claude_mcp", "server": "analytics-mcp", "expected": "present"},
                    {"id": "codex-mcp", "kind": "codex_mcp", "server": "analytics-mcp", "expected": "present"}
                ]
            },
        )

        result = self.run_doctor("mcp")

        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["summary"]["pass"], 2)

    def test_checks_ios_session_runtime_with_read_only_installer_status(self) -> None:
        checker = self.root / "install-runtime.mjs"
        runtime_root = (
            self.home / "Library/Application Support/agent-tooling/ios-session-lanes/runtime"
        ).resolve()
        bin_dir = (self.home / ".local/bin").resolve()
        expected_args = [
            "--check",
            "--runtime-root",
            str(runtime_root),
            "--bin-dir",
            str(bin_dir),
        ]
        checker.write_text(
            "const expected = "
            + json.dumps(expected_args)
            + ";\n"
            + "if (JSON.stringify(process.argv.slice(2)) !== JSON.stringify(expected)) {\n"
            + "  process.stderr.write(JSON.stringify({status:'error',code:'wrong-args',message:'unexpected arguments'}) + '\\n');\n"
            + "  process.exitCode = 1;\n"
            + "} else {\n"
            + "  process.stdout.write(JSON.stringify({status:'ok',integrityVersion:3,wrappers:3}) + '\\n');\n"
            + "}\n",
            encoding="utf-8",
        )
        self.write_json(
            self.profiles / "runtime.json",
            {
                "schema_version": 1,
                "name": "runtime",
                "checks": [
                    {
                        "id": "ios-runtime",
                        "kind": "ios_session_runtime",
                        "installer": str(checker),
                    }
                ],
            },
        )

        current = self.run_doctor("runtime")

        self.assertEqual(current.returncode, 0, current.stderr or current.stdout)
        current_report = json.loads(current.stdout)
        self.assertEqual(current_report["summary"]["pass"], 1)
        self.assertIn("integrity v3, 3 wrappers", current_report["results"][0]["message"])

        checker.write_text(
            "process.stderr.write(JSON.stringify({status:'drift',code:'source-revision-drift',message:'stale runtime'}) + '\\n');\n"
            "process.exitCode = 1;\n",
            encoding="utf-8",
        )
        drift = self.run_doctor("runtime")

        self.assertEqual(drift.returncode, 1)
        drift_report = json.loads(drift.stdout)
        self.assertEqual(drift_report["summary"]["fail"], 1)
        self.assertIn("source-revision-drift", drift_report["results"][0]["message"])

    def test_project_root_override_checks_active_project_state(self) -> None:
        stale_root = self.root / "stale-project"
        active_root = self.root / "active-project"
        self.write_json(
            active_root / ".claude/settings.json",
            {"enabledPlugins": {"pumpd-workflows@agent-tooling": True}},
        )
        codex = active_root / ".codex/config.toml"
        codex.parent.mkdir(parents=True)
        codex.write_text(
            '[mcp_servers.context7]\ncommand = "context7"\n',
            encoding="utf-8",
        )
        self.write_json(
            self.profiles / "project.json",
            {
                "schema_version": 1,
                "name": "project",
                "variables": {"project_root": str(stale_root)},
                "checks": [
                    {
                        "id": "project-plugin",
                        "kind": "claude_plugin",
                        "plugin": "pumpd-workflows@agent-tooling",
                        "path": "${project_root}/.claude/settings.json",
                        "expected": "enabled",
                    },
                    {
                        "id": "project-mcp",
                        "kind": "project_codex_mcp",
                        "path": "${project_root}/.codex/config.toml",
                        "server": "context7",
                        "expected": "present",
                    },
                ],
            },
        )

        result = self.run_doctor("project", "--project-root", str(active_root))

        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["summary"]["pass"], 2)

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
