#!/usr/bin/env python3
"""Clean local PUMPD Claude/Codex branches and worktrees."""

from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


LOCAL_BRANCH_PATTERNS = ("claude/*", "codex/*")
WORKTREE_PATH_MARKER = f"{os.sep}.claude{os.sep}worktrees{os.sep}"


@dataclass
class Worktree:
    path: Path
    branch: str | None
    head: str | None
    prunable: bool


def run(
    args: list[str],
    *,
    cwd: Path | None = None,
    check: bool = True,
    capture: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=str(cwd) if cwd else None,
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def git(repo: Path, *args: str, check: bool = True) -> str:
    proc = run(["git", "-C", str(repo), *args], check=check)
    return proc.stdout


def repo_root(path: Path) -> Path:
    proc = run(["git", "-C", str(path), "rev-parse", "--show-toplevel"])
    return Path(proc.stdout.strip()).resolve()


def parse_worktrees(repo: Path) -> list[Worktree]:
    output = git(repo, "worktree", "list", "--porcelain")
    worktrees: list[Worktree] = []
    current: dict[str, str | bool] = {}

    def flush() -> None:
        if not current:
            return
        path = current.get("worktree")
        if isinstance(path, str):
            branch = current.get("branch")
            if isinstance(branch, str) and branch.startswith("refs/heads/"):
                branch = branch.removeprefix("refs/heads/")
            worktrees.append(
                Worktree(
                    path=Path(path).resolve(),
                    branch=branch if isinstance(branch, str) else None,
                    head=current.get("HEAD") if isinstance(current.get("HEAD"), str) else None,
                    prunable=bool(current.get("prunable")),
                )
            )
        current.clear()

    for line in output.splitlines():
        if not line:
            flush()
            continue
        key, _, value = line.partition(" ")
        current[key] = value if value else True
    flush()
    return worktrees


def local_branches(repo: Path) -> list[str]:
    output = git(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads")
    return sorted(line.strip() for line in output.splitlines() if line.strip())


def matches_branch_patterns(branch: str) -> bool:
    return any(fnmatch.fnmatchcase(branch, pattern) for pattern in LOCAL_BRANCH_PATTERNS)


def select_worktrees(root: Path, worktrees: list[Worktree]) -> list[Worktree]:
    selected: list[Worktree] = []
    for worktree in worktrees:
        if worktree.path == root or worktree.prunable:
            continue
        path_text = str(worktree.path)
        branch = worktree.branch or ""
        if matches_branch_patterns(branch) or WORKTREE_PATH_MARKER in path_text:
            selected.append(worktree)
    return selected


def select_branches(branches: list[str], selected_worktrees: list[Worktree]) -> list[str]:
    selected = {branch for branch in branches if matches_branch_patterns(branch)}
    for worktree in selected_worktrees:
        if worktree.branch:
            selected.add(worktree.branch)
    return sorted(selected)


def status_short(path: Path) -> str:
    return run(
        ["git", "-C", str(path), "status", "--short", "--untracked-files=all"],
        check=True,
    ).stdout.strip()


def status_lines(path: Path) -> list[str]:
    status = status_short(path)
    return [line for line in status.splitlines() if line.strip()]


def status_path(line: str) -> str:
    # Porcelain v1 short format keeps the path after the two status columns.
    path = line[3:] if len(line) > 3 else ""
    if " -> " in path:
        path = path.rsplit(" -> ", 1)[1]
    return path.strip().strip('"')


def root_status_excluding_selected_worktrees(root: Path, selected_worktrees: list[Worktree]) -> list[str]:
    prefixes: list[str] = []
    for worktree in selected_worktrees:
        try:
            rel = worktree.path.relative_to(root).as_posix()
        except ValueError:
            continue
        prefixes.append(rel.rstrip("/") + "/")

    remaining: list[str] = []
    for line in status_lines(root):
        path = status_path(line)
        if any(path == prefix.rstrip("/") or path.startswith(prefix) for prefix in prefixes):
            continue
        remaining.append(line)
    return remaining


def current_branch(repo: Path) -> str | None:
    branch = git(repo, "branch", "--show-current").strip()
    return branch or None


def ensure_tracking_branch(repo: Path, branch: str, remote: str, execute: bool) -> None:
    exists = run(
        ["git", "-C", str(repo), "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"],
        check=False,
        capture=False,
    ).returncode == 0
    if exists:
        return
    if not execute:
        print(f"Would create local {branch} tracking {remote}/{branch}")
        return
    git(repo, "switch", "-c", branch, "--track", f"{remote}/{branch}")


def create_bundle(repo: Path, backup_dir: Path, branches: list[str], stamp: str, execute: bool) -> Path | None:
    if not branches:
        return None
    bundle = backup_dir / f"pumpd-local-claude-codex-branches-{stamp}.bundle"
    if not execute:
        print(f"Would create backup bundle: {bundle}")
        return bundle
    backup_dir.mkdir(parents=True, exist_ok=True)
    git(repo, "bundle", "create", str(bundle), *branches)
    return bundle


def stash_if_dirty(path: Path, label: str, stamp: str, execute: bool) -> bool:
    status = status_short(path)
    if not status:
        return False
    message = f"pre-local-worktree-cleanup {stamp} {label}"
    if not execute:
        print(f"Would stash dirty worktree {path}: {message}")
        return True
    git(path, "stash", "push", "-u", "-m", message)
    return True


def print_plan(
    *,
    root: Path,
    current: str | None,
    branches: list[str],
    worktrees: list[Worktree],
    dirty_worktrees: list[Worktree],
    root_dirty: bool,
    final_branch: str,
    skip_update: bool,
) -> None:
    print(f"Repo: {root}")
    print(f"Current branch: {current or '(detached)'}")
    print(f"Final branch: {final_branch}")
    print(f"Update main/preview: {'no' if skip_update else 'yes'}")
    print("")
    print(f"Local branches selected for deletion: {len(branches)}")
    for branch in branches:
        print(f"  {branch}")
    print("")
    print(f"Linked worktrees selected for removal: {len(worktrees)}")
    for worktree in worktrees:
        print(f"  {worktree.path} [{worktree.branch or 'detached'}]")
    print("")
    print(f"Dirty selected worktrees to stash: {len(dirty_worktrees)}")
    for worktree in dirty_worktrees:
        print(f"  {worktree.path} [{worktree.branch or 'detached'}]")
    if root_dirty:
        print("")
        print("Root checkout is dirty and on a selected cleanup branch; it will be stashed before switching.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".", help="Path inside the pumpd-mobile-app repo")
    parser.add_argument("--execute", action="store_true", help="Actually mutate the local repo")
    parser.add_argument("--backup-dir", help="Directory for local branch bundle backups")
    parser.add_argument("--remote", default="origin", help="Remote to fetch from")
    parser.add_argument("--final-branch", default="preview", help="Branch to leave checked out")
    parser.add_argument("--skip-update", action="store_true", help="Do not fetch/pull main and preview")
    args = parser.parse_args()

    root = repo_root(Path(args.repo).expanduser())
    backup_dir = Path(args.backup_dir).expanduser() if args.backup_dir else root.parent / "local-cleanup-backups"
    stamp = dt.datetime.now().strftime("%Y%m%dT%H%M%S")

    worktrees = parse_worktrees(root)
    selected_worktrees = select_worktrees(root, worktrees)
    branches = select_branches(local_branches(root), selected_worktrees)
    current = current_branch(root)
    root_selected = bool(current and current in branches)
    root_status = root_status_excluding_selected_worktrees(root, selected_worktrees)
    root_dirty = bool(root_status) if root_selected else False
    dirty_worktrees = [worktree for worktree in selected_worktrees if status_lines(worktree.path)]

    print_plan(
        root=root,
        current=current,
        branches=branches,
        worktrees=selected_worktrees,
        dirty_worktrees=dirty_worktrees,
        root_dirty=root_dirty,
        final_branch=args.final_branch,
        skip_update=args.skip_update,
    )

    if not args.execute:
        print("")
        print("Dry run only. Re-run with --execute to clean up local refs and worktrees.")
        return 0

    if not branches and not selected_worktrees and args.skip_update:
        print("Nothing to clean up.")
        return 0

    if root_status and not root_selected:
        print(
            "Root checkout is dirty on a branch that is not selected for cleanup. "
            "Commit, stash, or clean it before running with --execute.",
            file=sys.stderr,
        )
        return 2

    bundle = create_bundle(root, backup_dir, branches, stamp, execute=True)
    if bundle:
        print(f"Created backup bundle: {bundle}")

    stashed = 0
    if root_selected and stash_if_dirty(root, f"{current} root", stamp, execute=True):
        stashed += 1
    for worktree in selected_worktrees:
        label = f"{worktree.branch or 'detached'} {worktree.path.name}"
        if stash_if_dirty(worktree.path, label, stamp, execute=True):
            stashed += 1

    removed = 0
    for worktree in selected_worktrees:
        git(root, "worktree", "remove", str(worktree.path))
        removed += 1
    git(root, "worktree", "prune")

    if not args.skip_update:
        git(root, "fetch", args.remote, "main", "preview")
        ensure_tracking_branch(root, "preview", args.remote, execute=True)

    if root_selected or current != args.final_branch:
        git(root, "switch", args.final_branch)

    deleted = 0
    for branch in branches:
        exists = run(
            ["git", "-C", str(root), "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"],
            check=False,
            capture=False,
        ).returncode == 0
        if exists:
            git(root, "branch", "-D", branch)
            deleted += 1

    if not args.skip_update:
        ensure_tracking_branch(root, "main", args.remote, execute=True)
        git(root, "switch", "main")
        git(root, "pull", "--ff-only", args.remote, "main")
        ensure_tracking_branch(root, "preview", args.remote, execute=True)
        git(root, "switch", "preview")
        git(root, "pull", "--ff-only", args.remote, "preview")
    else:
        git(root, "switch", args.final_branch)

    print("")
    print(f"Stashed dirty worktrees: {stashed}")
    print(f"Removed linked worktrees: {removed}")
    print(f"Deleted local branches: {deleted}")
    if bundle:
        print(f"Backup bundle: {bundle}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
