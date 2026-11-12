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

The page's prose is not compared to the code: debt: showcase-prose-unchecked
"""
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PAGE = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO / "demo/scaffold-showcase.html"
GEN = REPO / "demo/embed-src.py"
ONES = ["", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
        "eighteen", "nineteen"]
TENS = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]


def word(n):
    """The lede's spelling of 1 to 99: `twenty-seven`."""
    if n < 20:
        return ONES[n]
    return TENS[n // 10] + (f"-{ONES[n % 10]}" if n % 10 else "")


WORDS = {n: word(n) for n in range(1, 100)}

page = PAGE.read_text()
gen = GEN.read_text()
problems = []


def compare(label, on_page, on_disk):
    for name in sorted(on_disk - on_page):
        problems.append(f"{label}: `{name}` exists in the repository but has no card")
    for name in sorted(on_page - on_disk):
        problems.append(f"{label}: the page shows `{name}`, which is not in the repository")
    return on_disk


def found(pattern, what, group=0):
    match = re.search(pattern, page, re.S)
    if match is None:
        raise SystemExit(f"check-inventory: {PAGE.name} has no {what}")
    return match.group(group)


def band(name, nxt):
    return found(rf'id="{name}".*?(?=id="{nxt}"|\Z)', f'"{name}" band')


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

breakdown = re.search(
    r"(\d+) gates · (\d+) context injectors · (\d+) evidence trails · (\d+) checkpoints", page)
if breakdown is None:
    problems.append("counts: the hero map states no gates/injectors/trails/checkpoints breakdown")
elif sum(map(int, breakdown.groups())) != len(hooks):
    problems.append(f"counts: the hero map's breakdown sums to {sum(map(int, breakdown.groups()))}; "
                    f"the repository has {len(hooks)} policies")

lede = found(r'lede">(.*?)</p>', "lede paragraph", 1)
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
