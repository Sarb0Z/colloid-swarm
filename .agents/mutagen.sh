#!/usr/bin/env bash
# Mutagen roller — roll one mutation vector and emit a mutagen-agent prompt.
#
# Prints the mutagen contract (mutagen.md) + a rolled MUTATION VECTOR + a slot
# for the base task. The orchestrator appends the purpose-stripped base task and
# dispatches it. Claude Code and Codex inject the cell's genome at
# SubagentStart; Kimi dispatches prepend `genome.sh --register none`. The
# mutagen returns only a rewritten task.
#
# The eval-cost dial picks the pool: cheap-to-verify -> a BOLD axis (push hard,
# selection will catch the wreckage); expensive-to-verify -> a GENTLE axis.
#
# Usage:
#   mutagen.sh --cost cheap         roll a bold axis
#   mutagen.sh --cost expensive     roll a gentle axis
#   mutagen.sh --cost cheap --seed 7   reproducible; bypasses the ledger
#   mutagen.sh --check              validate contract + axis pools, emit nothing
#
# Diagnostics go to STDERR; STDOUT is the paste-ready prompt. Fails closed.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HERE="$here" python3 - "$@" <<'PY'
import argparse, os, random, sys, time

HERE     = os.environ["HERE"]
CONTRACT = os.path.join(HERE, "mutagen.md")
LEDGER   = os.path.join(HERE, ".mutagen-ledger")

# Axis pools live here — the roller owns the entropy and the axis data; the
# contract (mutagen.md) applies whichever axis it is handed. Pools are disjoint:
# the cost dial maps to exactly one tier.
GENTLE = {
    "VANTAGE":  "Approach this from a different seat — the maintainer debugging it at 3am, or the adversary probing it. Let that vantage decide what matters.",
    "EMPHASIS": "Treat what reads as secondary in this task as the main event; let the stated-primary fall where it may, then reconcile.",
    "ALTITUDE": "Work one level off where the task sits — solve the general case it is an instance of, or get radically specific — whichever is less obvious.",
}
BOLD = {
    "FORBID-OBVIOUS": "The first approach that comes to mind is off-limits. Reach the criteria by a road you would normally reject on sight.",
    "INVERT":         "Invert a premise the task takes for granted; build toward the criteria from the opposite assumption, then reconcile.",
    "DUAL-FIRST":     "Solve the inverse or dual of this problem first; let that solution illuminate the real one before you write it.",
    "MINIMIZE-FIRST": "Find the smallest thing that could possibly satisfy the criteria, build exactly that, and refuse every addition that is not forced.",
}
POOLS = {"expensive": ("gentle", GENTLE), "cheap": ("bold", BOLD)}


def die(msg):
    sys.stderr.write("mutagen.sh: " + msg + "\n")
    sys.exit(3)


ap = argparse.ArgumentParser(prog="mutagen.sh", add_help=True,
                             description="Roll a mutation vector for a mutagen dispatch.")
ap.add_argument("--cost", choices=["cheap", "expensive"],
                help="eval-cost dial: cheap -> bold axis, expensive -> gentle")
ap.add_argument("--seed", type=int, help="reproducible roll; bypasses the ledger")
ap.add_argument("--check", action="store_true",
                help="validate contract + axis pools and exit")
args = ap.parse_args()

# Integrity — fail closed before any roll.
try:
    contract = open(CONTRACT, encoding="utf-8").read().strip()
except OSError as e:
    die("cannot read contract %s: %s" % (CONTRACT, e))
if not contract:
    die("contract %s is empty" % CONTRACT)
if "Inviolable" not in contract or "safety-relevant" not in contract:
    die("contract %s lost its Inviolable safety clause — refusing to emit "
        "a mutagen without its anti-laundering safeguard" % CONTRACT)
overlap = set(GENTLE) & set(BOLD)
if overlap:
    die("axis pools must be disjoint; both contain: " + ", ".join(sorted(overlap)))
if not GENTLE or not BOLD:
    die("an axis pool is empty")

if args.check:
    sys.stderr.write("mutagen.sh: ok — contract + %d gentle / %d bold axes, "
                     "disjoint\n" % (len(GENTLE), len(BOLD)))
    sys.exit(0)

if not args.cost:
    die("--cost cheap|expensive is required (the eval-cost dial)")

# Always record a concrete seed so the roll is reproducible and auditable, even
# when the caller didn't pin one.
seed = args.seed if args.seed is not None else random.SystemRandom().randint(0, 2**31 - 1)
rng = random.Random(seed)
boldness, pool = POOLS[args.cost]
axis = rng.choice(sorted(pool))            # sorted -> deterministic under seed
directive = pool[axis]

out = [
    contract, "",
    "— MUTATION VECTOR —",
    "axis: %s · boldness: %s · seed: %d" % (axis, boldness, seed),
    "directive: %s" % directive, "",
    "— base task follows; rewrite it per the vector, return only the rewritten task —",
]
sys.stdout.write("\n".join(out) + "\n")

if args.seed is None:                       # seeded rolls are repro/test, not history
    try:                                    # ts · seed · cost · axis — roll audit
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        open(LEDGER, "a", encoding="utf-8").write(
            "%s\t%d\t%s\t%s\n" % (ts, seed, args.cost, axis))
    except OSError:
        pass
sys.stderr.write("mutagen.sh: rolled %s (%s) seed %d\n" % (axis, boldness, seed))
PY
