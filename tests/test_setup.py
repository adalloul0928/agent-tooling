from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
SETUP = REPO_ROOT / "scripts" / "setup"
DOCTOR = REPO_ROOT / "scripts" / "doctor"


def load_script(name: str, path: Path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules[loader.name] = module
    loader.exec_module(module)
    return module


class SetupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.setup = load_script("agent_tooling_setup_test", SETUP)
        cls.doctor = load_script("agent_tooling_doctor_test", DOCTOR)

    def test_profile_validation_rejects_shell_command_strings(self) -> None:
        profile = {
            "variables": {},
            "checks": [
                {
                    "id": "unsafe",
                    "kind": "path",
                    "path": "~/missing",
                    "install": {"run": "touch ~/owned"},
                }
            ],
        }

        with self.assertRaisesRegex(self.doctor.ProfileError, "non-empty string array"):
            self.doctor.validate_definition(profile)

    def test_execute_never_invokes_a_shell(self) -> None:
        completed = subprocess.CompletedProcess(["tool", "arg with space"], 0)
        with mock.patch.object(self.setup.subprocess, "run", return_value=completed) as run:
            status = self.setup.execute(["tool", "arg with space"])

        self.assertEqual(status, 0)
        run.assert_called_once_with(["tool", "arg with space"], shell=False)

    def test_command_rendering_quotes_arguments_for_review(self) -> None:
        self.assertEqual(self.setup.render_command(["tool", "arg with space"]), "tool 'arg with space'")

    def test_cli_rejects_unsafe_profile_before_planning(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profiles = root / "profiles"
            home = root / "home"
            profiles.mkdir()
            home.mkdir()
            (profiles / "unsafe.json").write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "name": "unsafe",
                        "checks": [
                            {
                                "id": "unsafe",
                                "kind": "path",
                                "path": "~/missing",
                                "install": {"run": "touch ~/owned"},
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    "python3",
                    str(SETUP),
                    "unsafe",
                    "--profiles-dir",
                    str(profiles),
                    "--home",
                    str(home),
                    "--json",
                ],
                check=False,
                capture_output=True,
                text=True,
            )

        self.assertEqual(result.returncode, 65)
        self.assertIn("install.run must be a non-empty string array", result.stderr)


if __name__ == "__main__":
    unittest.main()
