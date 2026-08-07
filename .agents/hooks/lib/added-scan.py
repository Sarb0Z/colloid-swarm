#!/usr/bin/env python3
"""Scan the lines this edit added for one advisory rule.

Usage: added-scan.py <tombstones|nullsafety> <project-dir>
       # file list on stdin, one absolute path per line

Both rules read the additions against HEAD rather than the whole file, because
no session commits mid-work by policy: what the diff shows is what this edit
introduced, so pre-existing prose and pre-existing casts do not nag.

Advisory, never a gate. Both rules are deliberately narrow — a false miss beats
crying wolf on every line.
"""

import os
import re
import subprocess
import sys

# Tombstones: phrasings that narrate a change rather than describe present
# behaviour. The standing rationale belongs in .agents/debt-log.md, not inline.
TOMBSTONE_PHRASES = re.compile(r'''(?ix)
    \b(
      previously | formerly | no\s+longer |
      used\s+to(\s+be)? |
      was\s+(previously\s+|formerly\s+)?(refactored|renamed|removed|replaced|changed|moved|deprecated) |
      refactored\s+(this|the|from|to|out|into) |
      changed\s+(this|the|it|these)?\s*from |
      renamed\s+(this|the|it|from) |
      moved\s+(this|the|it)\s+(from|to|out) |
      replaced\s+(the\s+)?old |
      instead\s+of\s+the\s+old |
      prior\s+to\s+this\s+(change|refactor) |
      as\s+part\s+of\s+(the\s+)?refactor |
      legacy\s+(behaviou?r|version|impl|code|path)
    )\b
    | \bTODO\b[^\n]*\b(19|20)\d\d\b
''')

# Only lines that read as comments, plus every line of a prose document.
CODE_COMMENT = re.compile(r'(^\s*(//|\#|\*|/\*|<!--|--|;))|(//|/\*|<!--|\#\s)')
DOC_EXT = (".md", ".mdx", ".markdown", ".rst", ".txt")

# Files whose whole job is to narrate history — exempt, or they nag on every edit.
SKIP_NAMES = re.compile(
    r'^(CHANGELOG|CHANGES|HISTORY|RELEASES?|NEWS|MIGRATION|UPGRADING)(\.|$)', re.I)

# The knowledge store holds dated observations of things outside this repository.
# An entry reporting that a claim "no longer" holds describes a source that
# moved, not a change to this code, so the rule does not reach it.
SKIP_PATHS = re.compile(r'(^|/)\.agents/knowledge/')

# Null safety: high-signal patterns tsc is blind to by construction — a cast
# silences strictNullChecks, and parsed JSON is typed `any`.
NULLSAFETY_PATTERNS = [
    (re.compile(r'\bas\s+(any|unknown)\b'),
     "cast to any/unknown launders the type — tsc can't see past it"),
    (re.compile(r'[\w\)\]]\!(?=[.\[(])'),
     "non-null `!` assertion proves nothing at runtime — guard instead"),
    (re.compile(r'\b(JSON\.parse|await\s+[\w.]+\.json)\s*\('),
     "parsed data is `any` — validate its shape before use"),
]

# A banned phrase inside double quotes or backticks is a citation, not narration,
# so those spans are blanked before matching — this file's own rules would trip
# otherwise, while a bare `// previously returned X` still does.
#
# The two rules disagree about single quotes, deliberately. For tombstones,
# prose apostrophes (it's, user's) far outnumber single-quoted comment strings,
# and a `'...'` pair straddling a banned phrase would hide a real tombstone. For
# null safety the input is code with comment-leading lines already skipped, and
# prettier may have rewritten "…" to '…', so single quotes must count.
TOMBSTONE_QUOTED = re.compile(r'"[^"]*"|`[^`]*`')
NULLSAFETY_QUOTED = re.compile(r'"[^"]*"|`[^`]*`' + r"|'[^']*'")


def relative(path, project):
    return path[len(project) + 1:] if path.startswith(project + "/") else path


def added_lines(path, project):
    """The lines this working tree adds to HEAD, or the whole file when new."""
    rel = relative(path, project)
    try:
        diff = subprocess.run(["git", "-C", project, "diff", "HEAD", "-U0", "--", rel],
                              capture_output=True, text=True, timeout=10)
        if diff.returncode != 0:
            return []
        if diff.stdout.strip():
            return [line[1:] for line in diff.stdout.splitlines()
                    if line.startswith("+") and not line.startswith("+++")]
        tracked = subprocess.run(
            ["git", "-C", project, "ls-files", "--error-unmatch", "--", rel],
            capture_output=True, text=True, timeout=10)
        if tracked.returncode != 0:           # untracked new file: scan it whole
            with open(path, encoding="utf-8", errors="replace") as handle:
                return handle.read().splitlines()
    except (OSError, subprocess.SubprocessError):
        pass
    return []


def tombstones(files, project):
    seen = []
    for path in files:
        if SKIP_NAMES.match(os.path.basename(path)) or SKIP_PATHS.search(relative(path, project)):
            continue
        is_doc = path.lower().endswith(DOC_EXT)
        for line in added_lines(path, project):
            if not (is_doc or CODE_COMMENT.search(line)):
                continue
            if not TOMBSTONE_PHRASES.search(TOMBSTONE_QUOTED.sub(" ", line)):
                continue
            entry = f"{relative(path, project)}: {line.strip()[:120]}"
            if entry not in seen:
                seen.append(entry)
    return seen[:12]


def nullsafety(files, project):
    seen, hits = set(), []
    for path in files:
        rel = relative(path, project)
        for line in added_lines(path, project):
            stripped = line.strip()
            if stripped.startswith(("//", "*", "/*")):
                continue
            probe = NULLSAFETY_QUOTED.sub(" ", line)
            for pattern, message in NULLSAFETY_PATTERNS:
                if not pattern.search(probe):
                    continue
                key = f"{rel}: {message}"
                if key not in seen:
                    seen.add(key)
                    hits.append(f"{key}\n    {stripped[:100]}")
                break
    return hits[:10]


RULES = {"tombstones": tombstones, "nullsafety": nullsafety}


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in RULES:
        raise SystemExit("added-scan.py: usage: added-scan.py <tombstones|nullsafety> <project-dir>")
    project = sys.argv[2]
    files = [path for path in sys.stdin.read().splitlines()
             if path.strip() and os.path.isfile(path)]
    for line in RULES[sys.argv[1]](files, project):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
