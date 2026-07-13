#!/usr/bin/env python3
"""Collect pull request context for the pr-walkthrough skill.

This script intentionally gathers raw facts only. The agent should still read
the changed files and reason about rationale before writing the walkthrough.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path


def run(
    args: list[str],
    cwd: Path,
    *,
    check: bool = False,
) -> tuple[int, str, str]:
    result = subprocess.run(
        args,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and result.returncode != 0:
        raise RuntimeError(
            f"{' '.join(args)} failed with {result.returncode}: {result.stderr.strip()}"
        )
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def heading(title: str) -> None:
    print(f"\n## {title}")


def fenced(value: str, language: str = "text") -> None:
    print(f"```{language}")
    print(value.rstrip())
    print("```")


def git_output(repo: Path, args: list[str]) -> str:
    _, stdout, stderr = run(["git", *args], repo)
    return stdout or stderr


def gh_json(repo: Path, args: list[str]) -> dict[str, object] | None:
    if not shutil.which("gh"):
        return None
    code, stdout, _ = run(["gh", *args], repo)
    if code != 0 or not stdout:
        return None
    try:
        return json.loads(stdout)
    except json.JSONDecodeError:
        return None


def resolve_base(repo: Path, explicit_base: str | None, pr: str | None) -> str:
    if explicit_base:
        return explicit_base

    pr_args = ["pr", "view"]
    if pr:
        pr_args.append(pr)
    pr_args.extend(["--json", "baseRefName"])
    metadata = gh_json(repo, pr_args)
    base = metadata.get("baseRefName") if metadata else None
    if isinstance(base, str) and base:
        return f"origin/{base}"

    for candidate in ("origin/preview", "origin/main", "origin/master"):
        code, _, _ = run(["git", "rev-parse", "--verify", candidate], repo)
        if code == 0:
            return candidate

    return "HEAD~1"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".", help="Repository path")
    parser.add_argument("--pr", default=None, help="PR number or URL")
    parser.add_argument("--base", default=None, help="Base ref for git diff")
    parser.add_argument(
        "--max-diff-lines",
        type=int,
        default=220,
        help="Maximum diff summary lines to print",
    )
    args = parser.parse_args()

    repo = Path(args.repo).resolve()
    if not (repo / ".git").exists():
        print(f"Not a git repository: {repo}", file=sys.stderr)
        return 2

    base = resolve_base(repo, args.base, args.pr)

    print("# PR Walkthrough Context")
    print(f"- Repo: `{repo}`")
    print(f"- Base: `{base}`")

    heading("Git Status")
    fenced(git_output(repo, ["status", "--short", "--branch"]))

    heading("Branch Commits")
    fenced(git_output(repo, ["log", "--oneline", f"{base}..HEAD"]))

    heading("Changed Files")
    fenced(git_output(repo, ["diff", "--name-only", f"{base}...HEAD"]))

    heading("Diff Stat")
    fenced(git_output(repo, ["diff", "--stat", f"{base}...HEAD"]))

    if shutil.which("gh"):
        pr_view_args = ["pr", "view"]
        if args.pr:
            pr_view_args.append(args.pr)
        pr_view_args.extend(
            [
                "--json",
                "number,url,title,state,isDraft,baseRefName,headRefName,mergeable,reviewDecision",
            ]
        )
        metadata = gh_json(repo, pr_view_args)
        if metadata:
            heading("GitHub PR Metadata")
            fenced(json.dumps(metadata, indent=2, sort_keys=True), "json")

    heading("Diff Preview")
    diff_preview = git_output(repo, ["diff", "--find-renames", f"{base}...HEAD"])
    lines = diff_preview.splitlines()
    if len(lines) > args.max_diff_lines:
        diff_preview = "\n".join(lines[: args.max_diff_lines])
        diff_preview += f"\n... truncated after {args.max_diff_lines} lines ..."
    fenced(diff_preview, "diff")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
