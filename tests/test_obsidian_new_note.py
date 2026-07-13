from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (
    REPO_ROOT
    / "plugins"
    / "obsidian"
    / "skills"
    / "obsidian-vault"
    / "scripts"
    / "new_note.py"
)


class NewNoteTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.vault = Path(self.temp_dir.name) / "vault"
        (self.vault / ".obsidian").mkdir(parents=True)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def run_script(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", str(SCRIPT), str(self.vault), *args],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_creates_structured_pumpd_idea_without_overwriting(self) -> None:
        relative_path = "PUMPD/Tasks/Todo/Example Idea.md"
        result = self.run_script(
            relative_path,
            "--title",
            "Example Idea",
            "--type",
            "idea",
            "--status",
            "captured",
            "--tags",
            "pumpd",
            "idea",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        note = self.vault / relative_path
        content = note.read_text(encoding="utf-8")
        self.assertIn('title: "Example Idea"', content)
        self.assertIn('status: "captured"', content)
        self.assertIn('project: "PUMPD"', content)
        self.assertIn('area: "Tasks / Todo"', content)
        self.assertIn("## Raw Idea", content)

        second = self.run_script(
            relative_path,
            "--title",
            "Replacement",
        )
        self.assertEqual(second.returncode, 73)
        self.assertIn("refusing to overwrite", second.stderr)
        self.assertNotIn("Replacement", note.read_text(encoding="utf-8"))

    def test_rejects_protected_and_escaping_paths(self) -> None:
        protected = self.run_script(
            ".obsidian/Unsafe.md",
            "--title",
            "Unsafe",
        )
        self.assertEqual(protected.returncode, 64)
        self.assertIn("hidden/protected", protected.stderr)

        escaping = self.run_script(
            "../Outside.md",
            "--title",
            "Outside",
        )
        self.assertEqual(escaping.returncode, 64)
        self.assertIn("outside the vault", escaping.stderr)

    def test_does_not_infer_project_from_organizational_or_root_paths(self) -> None:
        for relative_path in ("00 Inbox/Inbox Note.md", "Root Note.md"):
            with self.subTest(relative_path=relative_path):
                result = self.run_script(
                    relative_path,
                    "--title",
                    Path(relative_path).stem,
                )

                self.assertEqual(result.returncode, 0, result.stderr)
                content = (self.vault / relative_path).read_text(encoding="utf-8")
                self.assertNotIn("\nproject:", content)
                self.assertNotIn("\narea:", content)

    def test_rejects_non_vault_and_non_markdown_targets(self) -> None:
        not_markdown = self.run_script(
            "PUMPD/Tasks/Todo/Bad.txt",
            "--title",
            "Bad",
        )
        self.assertEqual(not_markdown.returncode, 64)
        self.assertIn("must end with .md", not_markdown.stderr)

        missing_vault = Path(self.temp_dir.name) / "not-a-vault"
        missing_vault.mkdir()
        result = subprocess.run(
            [
                "python3",
                str(SCRIPT),
                str(missing_vault),
                "Note.md",
                "--title",
                "Note",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 65)
        self.assertIn("not an Obsidian vault", result.stderr)


if __name__ == "__main__":
    unittest.main()
