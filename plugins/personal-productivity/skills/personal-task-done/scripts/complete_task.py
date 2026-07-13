#!/usr/bin/env python3
"""Complete a personal PUMPD task in Obsidian: move its note/folder from PUMPD/Tasks/Todo/ or
PUMPD/Tasks/Active/ to PUMPD/Tasks/Completed/ and set `status: done` (+ bump `updated`).

Locate the item by --linear-id (scans frontmatter) or --name (file/folder basename, case-
insensitive). Works for both a standalone task note (`<Name>.md`) and a feature folder
(`<Name>/` with `_index.md`). Prints machine-readable lines so the caller can flip Linear:

  LINEAR_ID=PUM-…
  LINEAR_URL=…
  MOVED_FROM=PUMPD/Tasks/Active/…
  MOVED_TO=PUMPD/Tasks/Completed/…

If the item is already in Completed, prints `ALREADY_DONE=…` and exits 0. Use --dry-run to preview.
"""
import argparse
import datetime
import os
import re
import shutil
import sys

DEFAULT_VAULT = os.environ.get("OBSIDIAN_VAULT", os.path.expanduser("~/Obsidian/obsidian-vault"))


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def fm_get(text, key):
    m = re.search(r"^\s*" + re.escape(key) + r":\s*(.*?)\s*(?:\s#.*)?$", text, re.MULTILINE)
    return m.group(1).strip().strip('"').strip("'") if m else ""


def set_field(text, key, formatted):
    pat = re.compile(r"^(\s*" + re.escape(key) + r":\s*)(.*?)(\s+#.*)?\s*$", re.MULTILINE)
    return pat.subn(lambda m: m.group(1) + formatted + (m.group(3) or ""), text, count=1)[0]


def index_file(path):
    """The file that holds the item's frontmatter: the note itself, or a folder's _index.md."""
    return os.path.join(path, "_index.md") if os.path.isdir(path) else path


def candidates(root):
    if not os.path.isdir(root):
        return []
    out = []
    for entry in sorted(os.listdir(root)):
        p = os.path.join(root, entry)
        if os.path.isdir(p):
            out.append(p)
        elif entry.endswith(".md") and not entry.startswith("_") and entry != "README.md":
            out.append(p)
    return out


def make_matcher(name, linear_id):
    def matches(p):
        base = os.path.basename(p)
        stem = base[:-3] if base.endswith(".md") else base
        if linear_id:
            idx = index_file(p)
            return os.path.exists(idx) and fm_get(read(idx), "linear-id").upper() == linear_id.upper()
        return stem.lower() == name.lower()
    return matches


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--vault", default=DEFAULT_VAULT)
    ap.add_argument("--name", default="", help="note/folder name (without .md)")
    ap.add_argument("--linear-id", default="", help="e.g. PUM-337")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    if not a.name and not a.linear_id:
        sys.exit("provide --name or --linear-id")

    todo = os.path.join(a.vault, "PUMPD", "Tasks", "Todo")
    active = os.path.join(a.vault, "PUMPD", "Tasks", "Active")
    completed = os.path.join(a.vault, "PUMPD", "Tasks", "Completed")
    matches = make_matcher(a.name, a.linear_id)

    open_items = candidates(todo) + candidates(active)
    found = [p for p in open_items if matches(p)]
    if not found:
        done = [p for p in candidates(completed) if matches(p)]
        if done:
            print("ALREADY_DONE=" + os.path.relpath(done[0], a.vault))
            return
        avail = ", ".join(os.path.basename(p) for p in open_items) or "(none)"
        sys.exit(f"no Todo/Active item matched. Open items: {avail}")
    if len(found) > 1:
        sys.exit("ambiguous match: " + ", ".join(os.path.basename(p) for p in found))

    src = found[0]
    base = os.path.basename(src)
    dst = os.path.join(completed, base)
    idx_text = read(index_file(src)) if os.path.exists(index_file(src)) else ""
    linear_id = fm_get(idx_text, "linear-id")
    linear_url = fm_get(idx_text, "linear-issue") or fm_get(idx_text, "linear-project")
    today = datetime.date.today().isoformat()

    rel_from = os.path.relpath(src, a.vault)
    rel_to = os.path.relpath(dst, a.vault)

    if a.dry_run:
        print(f"LINEAR_ID={linear_id}")
        print(f"LINEAR_URL={linear_url}")
        print(f"MOVED_FROM={rel_from}")
        print(f"MOVED_TO={rel_to}  (dry-run, not moved; would set status: done)")
        return

    if os.path.exists(dst):
        sys.exit(f"refusing to overwrite existing: {rel_to}")
    os.makedirs(completed, exist_ok=True)
    shutil.move(src, dst)

    didx = index_file(dst)
    if os.path.exists(didx):
        t = read(didx)
        t = set_field(t, "status", "done")
        t = set_field(t, "updated", f'"{today}"')
        with open(didx, "w", encoding="utf-8") as f:
            f.write(t)

    print(f"LINEAR_ID={linear_id}")
    print(f"LINEAR_URL={linear_url}")
    print(f"MOVED_FROM={rel_from}")
    print(f"MOVED_TO={rel_to}")


if __name__ == "__main__":
    main()
