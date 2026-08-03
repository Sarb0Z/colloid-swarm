#!/usr/bin/env bash
# Validate every skill against the Agent Skills format. The rules are the
# vendor-documented ones, not house style:
#   name         <= 64 chars, [a-z0-9-], no edge or doubled hyphen, matches its
#                directory, and free of the reserved words "anthropic"/"claude"
#   description  non-empty, <= 1024 chars, third person
#   SKILL.md     <= 500 body lines
#   references   linked only from SKILL.md (a file reached from another
#                reference file may be read only in part), and carrying a
#                table of contents past 100 lines
#
# The 500-line and TOC rules are performance guidance rather than validation,
# so they warn; the rest fail. Run with no arguments to sweep every skill, or
# pass SKILL.md paths to check only those.
#
# Usage: .agents/lint-skills.sh [SKILL.md ...]
# Exit:  0 clean (warnings allowed), 1 at least one error
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_ARGS="$*" REPO="$repo" python3 <<'PY'
import os, re, sys, glob

repo = os.environ["REPO"]
args = [a for a in os.environ.get("SKILL_ARGS", "").split() if a.endswith("SKILL.md")]
paths = args or sorted(glob.glob(os.path.join(repo, ".agents/skills/*/SKILL.md")))

RESERVED = ("anthropic", "claude")
errors, warnings = [], []

for path in paths:
    if not os.path.isfile(path):
        continue
    d = os.path.dirname(path)
    slug = os.path.basename(d)
    rel = os.path.relpath(path, repo)
    src = open(path, encoding="utf-8").read()

    parts = src.split("---")
    if len(parts) < 3 or not src.startswith("---"):
        errors.append(f"{rel}: no YAML frontmatter")
        continue
    fm = parts[1]

    m = re.search(r"^name:\s*(\S+)", fm, re.M)
    name = m.group(1).strip("\"'") if m else ""
    if not name:
        errors.append(f"{rel}: name is missing")
    else:
        if len(name) > 64:
            errors.append(f"{rel}: name is {len(name)} chars, over the 64 limit")
        if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", name):
            errors.append(f"{rel}: name '{name}' must be lowercase [a-z0-9-], no edge or doubled hyphen")
        if name != slug:
            errors.append(f"{rel}: name '{name}' does not match its directory '{slug}'")
        for w in RESERVED:
            if w in name.lower():
                errors.append(f"{rel}: name contains the reserved word '{w}'")

    m = re.search(r"^description:\s*(.*?)(?=\n[a-zA-Z][a-zA-Z0-9_-]*:\s|\Z)", fm, re.S | re.M)
    desc = " ".join(m.group(1).split()).strip("\"'") if m else ""
    if not desc:
        errors.append(f"{rel}: description is empty")
    elif len(desc) > 1024:
        errors.append(f"{rel}: description is {len(desc)} chars, over the 1024 limit")
    if re.search(r"\b(you|your|yours)\b", desc, re.I):
        errors.append(f"{rel}: description uses second person; write it in third person")

    body = src.count("\n") + 1
    if body > 500:
        warnings.append(f"{rel}: body is {body} lines, over the 500-line guidance")

    for target in re.findall(r"\]\(([^)]+\.md)\)", src):
        if not os.path.isfile(os.path.join(d, target)):
            errors.append(f"{rel}: link to '{target}' does not resolve")

    for ref in sorted(glob.glob(os.path.join(d, "**", "*.md"), recursive=True)):
        base = os.path.basename(ref)
        if base in ("SKILL.md", "AGENTS.md"):
            continue
        rref = os.path.relpath(ref, repo)
        text = open(ref, encoding="utf-8").read()
        linked = re.findall(r"\]\(([^)]+\.md)\)", text)
        if linked:
            errors.append(f"{rref}: links to {', '.join(linked)}; only SKILL.md may link to a reference file")
        if text.count("\n") + 1 > 100 and "## Contents" not in text:
            warnings.append(f"{rref}: over 100 lines with no '## Contents' table of contents")

for w in warnings:
    print(f"warn  {w}")
for e in errors:
    print(f"ERROR {e}")

checked = len([p for p in paths if os.path.isfile(p)])
if errors:
    print(f"\nlint-skills: {len(errors)} error(s), {len(warnings)} warning(s) across {checked} skill(s)")
    sys.exit(1)
print(f"lint-skills: {checked} skill(s) clean" + (f", {len(warnings)} warning(s)" if warnings else ""))
PY
