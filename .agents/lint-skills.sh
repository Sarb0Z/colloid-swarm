#!/usr/bin/env bash
# Validate every skill against the Agent Skills format:
#   name         <= 64 chars, [a-z0-9-], no edge or doubled hyphen, matches its
#                directory, and free of the reserved words "anthropic"/"claude"
#   description  non-empty, <= 1024 chars, third person
#   SKILL.md     <= 500 body lines
#   references   linked only from SKILL.md (a file reached from another
#                reference file may be read only in part), and carrying a
#                table of contents past 100 lines
#
# Every rule is an error. The last two are vendor performance guidance rather
# than field validation, but `post-edit-check.sh` has no non-blocking channel,
# so a warning tier here would be a rule nothing ever reports.
#
# Anything that stops a rule from being evaluated is also an error: an
# unreadable file, a path outside any skill, a missing frontmatter terminator.
# A gate that passes what it never opened is worse than no gate, because the
# exit code looks the same either way.
#
# Arguments may be any path inside a skill; the owning SKILL.md is found by
# walking up to the nearest directory holding one, so callers pass the files
# they touched and do no path arithmetic. Paths may also arrive
# newline-delimited in $LINT_SKILLS_PATHS, which is the safe channel when they
# can contain spaces; set-but-empty means "no skills selected", not "sweep
# everything". With no arguments and no variable, every skill is swept.
#
# Usage: .agents/lint-skills.sh [path ...]
#        LINT_SKILLS_PATHS=$'a\nb' .agents/lint-skills.sh
# Exit:  0 clean, 1 at least one error
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

argv_paths=""
for a in "$@"; do argv_paths+="$a"$'\n'; done

have_selection=""
[[ $# -gt 0 || -n "${LINT_SKILLS_PATHS+set}" ]] && have_selection=1

REPO="$repo" LINT_PATHS="${argv_paths}${LINT_SKILLS_PATHS:-}" HAVE_SELECTION="$have_selection" \
python3 <<'PY'
import os, re, sys, glob

repo = os.environ["REPO"]
given = [p for p in os.environ.get("LINT_PATHS", "").split("\n") if p.strip()]
have_selection = bool(os.environ.get("HAVE_SELECTION"))

errors = []

# A markdown link target: tolerates <angle brackets>, surrounding space, and a
# #fragment. Without the fragment branch, `[x](y.md#part)` evades every rule
# below that inspects links.
LINK = re.compile(r"\]\(\s*<?\s*([^)<>\s#]+\.md)(?:#[^)<>\s]*)?\s*>?\s*\)")
EXTERNAL = re.compile(r"^(?:[a-z][a-z0-9+.\-]*:)?//", re.I)
QUOTED = re.compile(r"\"[^\"]*\"|'[^']*'")
RESERVED = ("anthropic", "claude")


def show(p):
    """Path relative to the repo when it lies inside it, else as given."""
    rel = os.path.relpath(p, repo)
    return p if rel.startswith("..") else rel


def read(p):
    """Text of p, or None with the reason recorded as an error."""
    try:
        with open(p, encoding="utf-8") as f:
            return f.read()
    except (OSError, UnicodeDecodeError) as e:
        errors.append(f"{show(p)}: could not read ({type(e).__name__})")
        return None


def owning_skill(path):
    """Nearest ancestor directory holding a SKILL.md, or None. Resolves
    symlinks so `.claude/skills/x` and `.agents/skills/x` are one skill."""
    d = os.path.dirname(os.path.realpath(path))
    while True:
        candidate = os.path.join(d, "SKILL.md")
        if os.path.isfile(candidate):
            return candidate
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def frontmatter(src, rel):
    """Text between the opening `---` line and the next one, or None.
    Splitting on the bare string instead would truncate at the first `---`
    inside a value and silently shorten the description."""
    if not re.match(r"^---[ \t]*\n", src):
        errors.append(f"{rel}: no YAML frontmatter")
        return None
    rest = src[src.index("\n") + 1:]
    end = re.search(r"^---[ \t]*$", rest, re.M)
    if not end:
        errors.append(f"{rel}: frontmatter is never closed by a `---` line")
        return None
    return rest[:end.start()]


def scalar(fm, key):
    """Value of a top-level frontmatter key, folded to one line. Handles the
    `>` and `|` block indicators, whose character would otherwise be measured
    as part of the value."""
    m = re.search(rf"^{key}:[ \t]*(.*?)(?=\n[a-zA-Z][a-zA-Z0-9_.\-]*:[ \t]|\Z)", fm, re.S | re.M)
    if not m:
        return ""
    raw = m.group(1)
    if re.match(r"^[|>][0-9+-]*[ \t]*(\n|$)", raw):
        raw = raw.split("\n", 1)[1] if "\n" in raw else ""
    return " ".join(raw.split()).strip("\"'")


if have_selection:
    paths = []
    for g in given:
        if not os.path.exists(g):
            errors.append(f"{show(g)}: no such file")
            continue
        owner = owning_skill(g)
        if owner is None:
            hint = "; create its SKILL.md first" if f"{os.sep}skills{os.sep}" in os.path.abspath(g) else ""
            errors.append(f"{show(g)}: not inside a skill (no SKILL.md in any parent){hint}")
        elif owner not in paths:
            paths.append(owner)
else:
    paths = sorted(glob.glob(os.path.join(repo, ".agents/skills/*/SKILL.md")))

for path in paths:
    d = os.path.dirname(path)
    slug = os.path.basename(d)
    rel = show(path)
    src = read(path)
    if src is None:
        continue

    # sync-claude-agents.sh links .claude/rules/<slug>.md at this file for every
    # skill directory it finds. Without it the link is created and dangles, and
    # a dangling link reads as a missing canonical file, not a stale mirror.
    if not os.path.isfile(os.path.join(d, "AGENTS.md")):
        errors.append(f"{show(d)}: no AGENTS.md; .claude/rules/{slug}.md would dangle")

    fm = frontmatter(src, rel)
    if fm is None:
        continue

    name = scalar(fm, "name")
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

    desc = scalar(fm, "description")
    if not desc:
        errors.append(f"{rel}: description is empty")
    elif len(desc) > 1024:
        errors.append(f"{rel}: description is {len(desc)} chars, over the 1024 limit")
    # A description is read by the model deciding whether to load the skill, not
    # by a user, so it must not address a reader. Third person and the
    # imperative both satisfy that; second person does not. Quoted spans are
    # trigger phrases carried in the user's voice, not the skill speaking, so
    # only unquoted text is the description's own point of view.
    if re.search(r"\b(you|your|yours)\b", QUOTED.sub(" ", desc), re.I):
        errors.append(f"{rel}: description addresses the reader ('you') outside a quoted phrase; "
                      "state what the skill does, in third person or the imperative")

    body = len(src.splitlines())
    if body > 500:
        errors.append(f"{rel}: body is {body} lines, over the 500-line guidance")

    for target in LINK.findall(src):
        if EXTERNAL.match(target):
            continue
        if not os.path.isfile(os.path.join(d, target)):
            errors.append(f"{rel}: link to '{target}' does not resolve")

    for ref in sorted(glob.glob(os.path.join(d, "**", "*.md"), recursive=True)):
        if os.path.basename(ref) in ("SKILL.md", "AGENTS.md"):
            continue
        text = read(ref)
        if text is None:
            continue
        # Only a link to another reference file inside this skill creates the
        # partial-read condition. A back-link to SKILL.md or an external URL
        # does not.
        outward = []
        for t in LINK.findall(text):
            if EXTERNAL.match(t):
                continue
            resolved = os.path.realpath(os.path.join(os.path.dirname(ref), t))
            if resolved == os.path.realpath(path):
                continue
            if resolved.startswith(os.path.realpath(d) + os.sep):
                outward.append(t)
        if outward:
            errors.append(
                f"{show(ref)}: links to {', '.join(outward)}; only SKILL.md may link to a reference file"
            )
        if len(text.splitlines()) > 100 and "## Contents" not in text:
            errors.append(f"{show(ref)}: over 100 lines with no '## Contents' table of contents")

# A same-named skill under ~/.claude/skills wins over the project's, so this
# repository's own version never loads in its own repo and the two bodies drift
# apart unnoticed. That directory is the operator's and sits outside the tree,
# so this warns rather than failing: a CI machine has no such directory, and a
# red build there would say nothing about the code.
personal = os.path.join(os.path.expanduser("~"), ".claude", "skills")
shadowed = [os.path.basename(os.path.dirname(p)) for p in paths
            if os.path.isdir(os.path.join(personal, os.path.basename(os.path.dirname(p))))]
for name in shadowed:
    print(f"WARN  {name}: shadowed by {os.path.join(personal, name)}, which wins over project scope; "
          "this repository's own version never loads. Remove or rename the personal copy.")

for e in errors:
    print(f"ERROR {e}")

if errors:
    print(f"\nlint-skills: {len(errors)} error(s) across {len(paths)} skill(s)")
    sys.exit(1)
if not paths and not have_selection:
    print("lint-skills: no skills found")
    sys.exit(1)
print(f"lint-skills: {len(paths)} skill(s) clean")
PY
