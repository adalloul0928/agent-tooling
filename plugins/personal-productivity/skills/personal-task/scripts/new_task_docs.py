#!/usr/bin/env python3
"""Scaffold the Obsidian doc(s) for a personal PUMPD task/feature from the vault templates.

  task (default) -> PUMPD/Tasks/<col>/<Title>.md           (from "Standalone Task Template.md")
  feature        -> PUMPD/Tasks/<col>/<Title>/ (4 files)   (from _Templates/Feature/)

  <col> = Todo (default) / Active / Completed, selected by --status (todo|active|done).

Fills frontmatter (dates, status, Linear links, surface, execution) and the title heading,
preserving the templates' inline comments, and leaves body sections as template placeholders
so they can be filled in later. Refuses to overwrite. Prints two machine-readable lines:

  OBSIDIAN_URL=obsidian://open?vault=...&file=...   (use for the Linear back-link)
  CREATED=<relpath>;<relpath>;...
"""
import argparse
import datetime
import os
import re
import sys
import urllib.parse

DEFAULT_VAULT = os.environ.get("OBSIDIAN_VAULT", os.path.expanduser("~/Obsidian/obsidian-vault"))
EXECUTIONS = ["manual", "claude", "codex", "cyrus", "mixed"]
FEATURE_FILES = ["_index.md", "plan.md", "research.md", "checklist.md"]
FEATURE_TITLE_SUFFIX = {"plan.md": " — Plan", "research.md": " — Research", "checklist.md": " — Checklist"}
STATUS_DIRS = {"todo": "Todo", "active": "Active", "done": "Completed"}


def slugify(title):
    s = re.sub(r"[^a-z0-9]+", "-", title.strip().lower())
    return re.sub(r"-+", "-", s).strip("-")


def safe_name(title):
    return re.sub(r"[\\/:]+", "-", title).strip().strip(".")


def q(v):  # YAML double-quoted scalar
    return '"' + v.replace('"', '\\"') + '"'


def set_field(fm_lines, key, formatted):
    """Replace key's value in frontmatter lines, preserving an inline comment + indent."""
    pat = re.compile(r"^(\s*)" + re.escape(key) + r":\s*(.*?)(\s+#.*)?\s*$")
    for i, line in enumerate(fm_lines):
        m = pat.match(line)
        if m:
            indent, comment = m.group(1), m.group(3) or ""
            fm_lines[i] = f"{indent}{key}: {formatted}{comment}"
            return True
    return False


def fill(text, fields, body_subs):
    if not text.startswith("---"):
        sys.exit("template missing frontmatter")
    _, fm, body = text.split("---", 2)
    fm_lines = fm.splitlines()
    for key, val in fields.items():
        set_field(fm_lines, key, val)
    new_fm = "\n".join(fm_lines).strip("\n")
    for old, new in body_subs:
        body = body.replace(old, new)
    return f"---\n{new_fm}\n---{body}"


def obsidian_url(vault, rel_path):
    vault_name = os.path.basename(os.path.normpath(vault))
    file_param = rel_path[:-3] if rel_path.endswith(".md") else rel_path
    return (
        "obsidian://open?vault="
        + urllib.parse.quote(vault_name)
        + "&file="
        + urllib.parse.quote(file_param)
    )


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--vault", default=DEFAULT_VAULT)
    ap.add_argument("--type", choices=["task", "feature"], default="task")
    ap.add_argument("--title", required=True)
    ap.add_argument("--slug", default=None, help="feature slug / folder name (default: derived from title)")
    ap.add_argument("--linear-id", default="", help="e.g. PUM-341")
    ap.add_argument("--linear-url", default="")
    ap.add_argument("--execution", default="claude", choices=EXECUTIONS)
    ap.add_argument("--surface", default="", help="CSV, e.g. mobile or mobile,backend")
    ap.add_argument("--status", default="todo", choices=["todo", "active", "done"])
    ap.add_argument("--dry-run", action="store_true", help="print filled files, write nothing")
    a = ap.parse_args()

    today = datetime.date.today().isoformat()
    slug = a.slug or slugify(a.title)
    name = safe_name(a.title)
    surfaces = [s.strip() for s in a.surface.split(",") if s.strip()]
    surface_yaml = "[" + ", ".join(surfaces) + "]" if surfaces else "[]"
    col = STATUS_DIRS[a.status]
    tdir = os.path.join(a.vault, "PUMPD", "_Templates")

    outputs = []  # (relpath, content)

    if a.type == "task":
        tmpl = os.path.join(tdir, "Standalone Task Template.md")
        if not os.path.isfile(tmpl):
            sys.exit(f"template not found: {tmpl}")
        with open(tmpl, encoding="utf-8") as f:
            text = f.read()
        fields = {
            "title": q(a.title), "created": q(today), "updated": q(today), "status": a.status,
            "linear-issue": q(a.linear_url), "linear-id": q(a.linear_id),
            "surface": surface_yaml, "execution": a.execution,
        }
        body_subs = [("<Task>", a.title)]
        if a.linear_url:
            body_subs.append(("<url>", a.linear_url))
        outputs.append((os.path.join("PUMPD", "Tasks", col, f"{name}.md"), fill(text, fields, body_subs)))
    else:
        fdir = os.path.join(tdir, "Feature")
        if not os.path.isdir(fdir):
            sys.exit(f"template dir not found: {fdir}")
        for fname in FEATURE_FILES:
            with open(os.path.join(fdir, fname), encoding="utf-8") as f:
                text = f.read()
            fields = {"created": q(today), "updated": q(today), "feature": q(slug)}
            if fname == "_index.md":
                fields.update({
                    "title": q(a.title), "status": a.status, "execution": a.execution,
                    "surface": surface_yaml, "linear-project": q(a.linear_url),
                })
            else:
                fields["title"] = q(a.title + FEATURE_TITLE_SUFFIX[fname])
            body_subs = [("<Feature>", a.title)]
            if fname == "_index.md" and a.linear_url:
                body_subs.append(("**Linear Project:** <url>", f"**Linear Project:** {a.linear_url}"))
            outputs.append((os.path.join("PUMPD", "Tasks", col, name, fname), fill(text, fields, body_subs)))

    if a.dry_run:
        for rel, content in outputs:
            print(f"===== {rel} =====\n{content}")
        print("OBSIDIAN_URL=" + obsidian_url(a.vault, outputs[0][0]))
        print("CREATED=" + ";".join(r for r, _ in outputs) + "  (dry-run, not written)")
        return

    targets = [os.path.join(a.vault, rel) for rel, _ in outputs]
    existing = [t for t in targets if os.path.exists(t)]
    if existing:
        sys.exit("refusing to overwrite existing: " + "; ".join(existing))

    for rel, content in outputs:
        path = os.path.join(a.vault, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)

    print("OBSIDIAN_URL=" + obsidian_url(a.vault, outputs[0][0]))
    print("CREATED=" + ";".join(r for r, _ in outputs))


if __name__ == "__main__":
    main()
