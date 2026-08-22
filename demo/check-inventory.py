#!/usr/bin/env python3
"""Fail when the showcase page no longer describes the scaffold it ships with.

The page drifted across roughly ten commits because nothing compared it to the
repository: `embed-src.py` refreshes the source panel inside a card that already
exists, and is silent about a hook or skill that has no card at all.

Read-only by design — CI asserts a clean working tree, so this reports drift and
leaves the fix to `embed-src.py` plus a hand-written card.

Hooks and skills are checked for full coverage because those are the sets that
grow. Playbooks and personas are checked only through the manifest, since not
every file in those directories earns a card and an exemption list would rot the
same way the page did.
"""
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PAGE = REPO / "demo/scaffold-showcase.html"
GEN = REPO / "demo/embed-src.py"
WORDS = {1: "one", 2: "two", 3: "three", 4: "four", 5: "five", 6: "six", 7: "seven",
         8: "eight", 9: "nine", 10: "ten", 11: "eleven", 12: "twelve", 13: "thirteen",
         14: "fourteen", 15: "fifteen", 16: "sixteen", 17: "seventeen", 18: "eighteen",
         19: "nineteen", 20: "twenty"}

page = PAGE.read_text()
gen = GEN.read_text()
problems = []


def compare(label, on_page, on_disk):
    for name in sorted(on_disk - on_page):
        problems.append(f"{label}: `{name}` exists in the repository but has no card")
    for name in sorted(on_page - on_disk):
        problems.append(f"{label}: the page shows `{name}`, which is not in the repository")
    return on_disk


def band(name, nxt):
    return re.search(rf'id="{name}".*?(?=id="{nxt}"|\Z)', page, re.S).group(0)


hooks = compare(
    "hook",
    set(re.findall(r'<span class="id">([a-z0-9.\-]+)</span>', band("hooks", "model"))),
    {p.stem for p in (REPO / ".agents/hooks/policy").glob("*.sh")},
)
skills = compare(
    "skill",
    set(re.findall(r"<h3>([a-z0-9\-]+)</h3>", band("skills", "prompts"))),
    {p.name for p in (REPO / ".agents/skills").iterdir() if p.is_dir()},
)

manifest = dict(re.findall(r'"([^"]+)":\s+"([^"]+)"', gen))
for key, rel in sorted(manifest.items()):
    if not (REPO / rel).exists():
        problems.append(f"manifest: `{key}` points at `{rel}`, which does not exist")
    if key not in page:
        problems.append(f"manifest: `{key}` has no card on the page")
for name in sorted(hooks - set(manifest)):
    problems.append(f"manifest: hook `{name}` has a card but no source panel")
for name in sorted(skills - set(manifest)):
    problems.append(f"manifest: skill `{name}` has a card but no source panel")

# The headline counts are hand-written, and they are what went stale first.
for claimed, actual, noun in [
    (re.search(r'<span class="m-n">(\d+) policies</span>', page), len(hooks), "policies"),
    (re.search(r'<span class="m-n">(\d+) skills</span>', page), len(skills), "skills"),
]:
    if claimed is None:
        problems.append(f"counts: the page states no {noun} total")
    elif int(claimed.group(1)) != actual:
        problems.append(f"counts: the page claims {claimed.group(1)} {noun}; the repository has {actual}")

lede = re.search(r'lede">(.*?)</p>', page, re.S).group(1)
for actual, noun in [(len(hooks), "enforcement hooks"), (len(skills), "skills")]:
    if actual not in WORDS:
        problems.append(f"lede: {actual} {noun} is past this check's number words — say it another way")
        continue
    want = f"{WORDS[actual]} {noun}"
    if want not in lede:
        problems.append(f'lede: expected "{want}"')

if problems:
    sys.stderr.write("showcase drifted from the scaffold:\n")
    for line in problems:
        sys.stderr.write(f"  - {line}\n")
    sys.stderr.write("\nAdd the card by hand, then run `python3 demo/embed-src.py`.\n")
    raise SystemExit(1)
print(f"showcase: {len(hooks)} hook policies, {len(skills)} skills, "
      f"{len(manifest)} source panels — page matches the repository")
