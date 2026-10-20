import hashlib
import importlib.machinery
import io
from contextlib import redirect_stderr
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zlib


CHECKER = importlib.machinery.SourceFileLoader(
    "public_content", str(Path(__file__).resolve().parents[1] / "scripts/check-public-content")
).load_module()


class PublicContentTests(unittest.TestCase):
    def test_private_words_are_case_insensitive_and_not_reported(self):
        digest = hashlib.sha256(b"confidentialfixture").hexdigest()
        issues = CHECKER.text_issues("ConfidentialFixture\nordinary public text", {digest})
        self.assertEqual(issues, [(1, "private vocabulary")])

    def test_private_phrases_cover_space_and_hyphen_separators(self):
        digest = hashlib.sha256(b"confidential-example").hexdigest()
        for text in ("Confidential Example", "confidential-example"):
            self.assertEqual(CHECKER.text_issues(text, {digest}), [(1, "private vocabulary")])

    def test_personal_paths_and_accounts_are_rejected_but_examples_are_allowed(self):
        private_path = "/Users/" + "realperson/Documents"
        private_email = "person@" + "private.invalid"
        self.assertEqual(CHECKER.text_issues(private_path), [(1, "personal home directory")])
        self.assertEqual(CHECKER.text_issues(private_email), [(1, "non-example email or account address")])
        self.assertEqual(CHECKER.text_issues("/Users/example/project me@example.com git@github.com"), [])

    def test_bare_and_nested_home_paths_are_rejected_on_macos_and_linux(self):
        for prefix in ("/Users/", "/home/"):
            for suffix in ("", "/Documents"):
                with self.subTest(prefix=prefix, suffix=suffix):
                    path = prefix + "realperson" + suffix
                    self.assertEqual(CHECKER.text_issues(path), [(1, "personal home directory")])
                    self.assertEqual(CHECKER.text_issues('"' + path + '"'), [(1, "personal home directory")])
                    self.assertEqual(CHECKER.text_issues(prefix + "example" + suffix), [])
                    self.assertEqual(CHECKER.text_issues(prefix + "example.person" + suffix), [(1, "personal home directory")])
        self.assertEqual(CHECKER.text_issues("/Users/Exam /Users/ex ample/project"), [])

    def test_retina_image_names_are_not_mistaken_for_email_addresses(self):
        for name in ("background@2x.png", "icons/tool@3x.webp"):
            self.assertEqual(CHECKER.text_issues(name), [])
            self.assertEqual(CHECKER.diagnostic_name(name), name)
            self.assertEqual(CHECKER.text_issues('image = "' + name + '"'), [])
        for name in ("person@" + "2x.invalid", "image@" + "4x.png", "image@" + "2x.png.invalid"):
            self.assertEqual(CHECKER.text_issues(name), [(1, "non-example email or account address")])
            self.assertTrue(CHECKER.diagnostic_name(name).startswith("file-"))

    def test_image_text_metadata_is_detected(self):
        def chunk(kind, payload):
            return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))

        header = b"\x89PNG\r\n\x1a\n"
        self.assertFalse(CHECKER.png_has_metadata(header + chunk(b"IEND", b"")))
        self.assertTrue(CHECKER.png_has_metadata(header + chunk(b"tEXt", b"Author\0Example")))
        png = header + chunk(b"eXIf", b"synthetic")
        icon = b"ic07" + struct.pack(">I", len(png) + 8) + png
        icns = b"icns" + struct.pack(">I", len(icon) + 8) + icon
        self.assertTrue(CHECKER.image_has_metadata(icns))

    def test_deleted_document_links_and_escaping_symlinks_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            readme = root / "README.md"
            readme.write_text("[Missing](missing.md)\n[Site](https://example.com)\n")
            self.assertEqual(CHECKER.inspect_file(root, readme), [(1, "broken local Markdown link")])
            link = root / "outside"
            link.symlink_to(root.parent)
            self.assertEqual(CHECKER.inspect_file(root, link), [(0, "symlink escapes repository")])

    def test_private_catalogs_and_credentials_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "profiles").mkdir()
            profile = root / "profiles/private.json"
            profile.write_text("{}")
            self.assertIn((0, "private catalog directory"), CHECKER.inspect_file(root, profile))
            key = root / "signing.p8"
            key.write_text("synthetic")
            self.assertIn((0, "credential/configuration file"), CHECKER.inspect_file(root, key))

    def test_private_vocabulary_in_filenames_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            file = root / "ConfidentialFixture.txt"
            file.write_text("public sample")
            digest = hashlib.sha256(b"confidentialfixture").hexdigest()
            with patch.object(CHECKER, "PRIVATE_WORD_HASHES", {digest}):
                self.assertIn((0, "private vocabulary"), CHECKER.inspect_file(root, file))

    def test_diagnostics_mask_private_filenames_but_keep_safe_locations(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            private_name = "ConfidentialFixture.txt"
            safe_name = "public-sample.txt"
            (root / private_name).write_text("public sample")
            (root / safe_name).write_text("ConfidentialFixture")
            listed = (private_name + "\0" + safe_name + "\0").encode()
            digest = hashlib.sha256(b"confidentialfixture").hexdigest()
            output = io.StringIO()
            with (
                patch.object(CHECKER, "__file__", str(root / "scripts/check-public-content")),
                patch.object(CHECKER, "PRIVATE_WORD_HASHES", {digest}),
                patch.object(CHECKER.subprocess, "check_output", return_value=listed),
                redirect_stderr(output),
            ):
                self.assertEqual(CHECKER.main(), 1)
                masked = CHECKER.diagnostic_name(private_name)
                self.assertEqual(CHECKER.diagnostic_name(private_name), masked)

            diagnostics = output.getvalue()
            self.assertNotIn("ConfidentialFixture", diagnostics)
            self.assertRegex(masked, r"^file-[0-9a-f]{12}$")
            self.assertIn(masked + ":0: private vocabulary", diagnostics)
            self.assertIn(safe_name + ":1: private vocabulary", diagnostics)
            self.assertIn("Public-content check failed: 2 issue(s).", diagnostics)


if __name__ == "__main__":
    unittest.main()
