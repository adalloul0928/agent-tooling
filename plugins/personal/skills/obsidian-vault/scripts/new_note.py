#!/usr/bin/env python3
"""Create a new Markdown note inside an Obsidian vault with safe frontmatter."""

from __future__ import annotations

import argparse
import os
import sys
import tempfile
from datetime import date
from pathlib import Path


BLOCKED_PARTS = {".git", ".obsidian", ".smart-env", ".trash"}
NON_PROJECT_ROOTS = {"00 Inbox", "_Templates", "_Attachments", "99 Archive"}
STATUS_CHOICES = ("draft", "captured", "active", "review", "archived", "done", "reference")


def yaml_string(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def yaml_list(values: list[str]) -> str:
    if not values:
        return "[]"
    return "\n" + "\n".join(f"  - {yaml_string(v)}" for v in values)


def yaml_field(key: str, value: str) -> str:
    separator = "" if value.startswith("\n") else " "
    return f"{key}:{separator}{value}"


def infer_project_area(rel: Path) -> tuple[str, str]:
    parts = rel.parts
    if len(parts) < 2 or parts[0] in NON_PROJECT_ROOTS:
        return "", ""

    project = parts[0]
    area = ""
    if len(parts) > 2:
        area = " / ".join(parts[1:-1])
    return project, area


def validate_note_path(vault: Path, rel: Path) -> Path:
    if rel.is_absolute():
        raise ValueError("note path must be relative to the vault")
    if rel.suffix.lower() != ".md":
        raise ValueError("note path must end with .md")
    if any(part in {".", ".."} for part in rel.parts):
        raise ValueError("note path resolves outside the vault")
    if any(part in BLOCKED_PARTS or part.startswith(".") for part in rel.parts):
        raise ValueError("note path cannot target hidden/protected folders")

    target = (vault / rel).resolve()
    vault_real = vault.resolve()
    try:
        target.relative_to(vault_real)
    except ValueError as exc:
        raise ValueError("note path resolves outside the vault") from exc
    return target


def build_note(args: argparse.Namespace, rel: Path) -> str:
    today = date.today().isoformat()
    project, area = infer_project_area(rel)
    tags = list(args.tags or [])
    aliases = list(args.aliases or [])
    note_type = args.type
    status = args.status

    lines = [
        "---",
        f"title: {yaml_string(args.title)}",
        f"created: {yaml_string(today)}",
        f"updated: {yaml_string(today)}",
        f"type: {note_type}",
        f"status: {yaml_string(status)}",
        yaml_field("tags", yaml_list(tags)),
        yaml_field("aliases", yaml_list(aliases)),
    ]
    if project:
        lines.append(f"project: {yaml_string(project)}")
    if area:
        lines.append(f"area: {yaml_string(area)}")
    if note_type == "research":
        lines.append("sources: []")
        lines.append("related: []")
    elif note_type == "decision":
        lines.append(f"decided: {yaml_string(today)}")
        lines.append('review_after: ""')
        lines.append("related: []")
    elif note_type == "idea":
        lines.append(f"source: {yaml_string('user')}")
        lines.append("related: []")
    else:
        lines.append("related: []")
    lines.extend(["---", "", f"# {args.title}", ""])

    section_map = {
        "project": ["## Context", "", "## Current State", "", "## Next Actions", ""],
        "research": ["## Question", "", "## Findings", "", "## Sources", ""],
        "meeting": ["## Notes", "", "## Decisions", "", "## Follow-ups", ""],
        "decision": ["## Decision", "", "## Context", "", "## Consequences", ""],
        "idea": ["## Raw Idea", "", "## Interpretation", "", "## Why It Matters", "", "## Affected Surfaces", "", "## Next Action", "", "## Open Questions", ""],
        "runbook": ["## Purpose", "", "## Steps", "", "## Verification", ""],
        "plan": ["## Objective", "", "## Plan", "", "## Open Questions", ""],
    }
    lines.extend(section_map.get(note_type, []))
    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("vault", type=Path)
    parser.add_argument("path", type=Path, help="relative note path inside the vault")
    parser.add_argument("--title", required=True)
    parser.add_argument("--type", default="note", choices=["note", "project", "research", "meeting", "decision", "runbook", "plan", "idea"])
    parser.add_argument("--status", default="draft", choices=STATUS_CHOICES)
    parser.add_argument("--tags", nargs="*", default=[])
    parser.add_argument("--aliases", nargs="*", default=[])
    args = parser.parse_args()

    vault = args.vault.resolve()
    if not (vault / ".obsidian").is_dir():
        print(f"not an Obsidian vault: {vault}", file=sys.stderr)
        return 65

    try:
        target = validate_note_path(vault, args.path)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 64

    if target.exists():
        print(f"refusing to overwrite existing note: {target}", file=sys.stderr)
        return 73

    target.parent.mkdir(parents=True, exist_ok=True)
    content = build_note(args, args.path)

    fd, tmp_name = tempfile.mkstemp(prefix=f".{target.name}.tmp-", dir=target.parent)
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(content)
            fh.flush()
            os.fsync(fh.fileno())
        try:
            os.link(tmp, target)
        except FileExistsError:
            print(f"refusing to overwrite existing note: {target}", file=sys.stderr)
            return 73
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass

    print(target)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
