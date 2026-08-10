#!/usr/bin/env bash
# Genome emitter — stamp one personality for a subagent dispatch.
#
# Prints a stamp to STDOUT: a sentinel header, the conserved strand, one of the
# 8 genomes, and (by default) a register. The orchestrator prepends this to a
# subagent's prompt so every minion dissolves into the broth with its own
# personality. genomes.md is the single source of truth; this script parses it.
#
# Usage:
#   genome.sh                         sortition (anti-repeat) + panspermia
#   genome.sh phage                   force a genome by name
#   genome.sh 5                       force a genome by number (1-8)
#   genome.sh --register none         strand + genome only (lean dispatch)
#   genome.sh --register constitution heavy register (~1k words; opt in)
#   genome.sh --count 5               5 guaranteed-distinct stamps (fan-out)
#   genome.sh --seed 42 phage         reproducible; bypasses the ledger
#   genome.sh --check                 validate genomes.md, emit nothing
#
# Selection name/number are mutually exclusive with --count. Engine-neutral:
# Claude and Kimi both call it via the orchestrator protocol (see genomes.md).
# Diagnostics (which genome was issued, parse errors) go to STDERR so STDOUT
# stays a clean, paste-ready stamp. Fails closed (non-zero) on a malformed
# genomes.md rather than emitting a half-formed personality.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"

HERE="$here" REPO="$repo" python3 - "$@" <<'PY'
import argparse, os, random, re, sys

HERE, REPO = os.environ["HERE"], os.environ["REPO"]
GENOMES_MD = os.path.join(REPO, "genomes.md")
LEDGER     = os.path.join(HERE, ".genome-ledger")
REGISTERS  = {
    "panspermia":   os.path.join(REPO, "panspermia.txt"),
    "constitution": os.path.join(REPO, "colloid-constitution.md"),
}
SENTINEL    = "⊰ COLLOID GENOME"   # ⊰ COLLOID GENOME — the stamp's header
LEDGER_KEEP = 7


def die(msg):
    sys.stderr.write("genome.sh: " + msg + "\n")
    sys.exit(3)


def parse_genomes():
    """genomes.md -> (strand, [{n, name, block}]). Validates hard; the count of
    8 is necessary but not sufficient, so we also check order and that each
    block kept its *Agenda:* trailer (a mid-block truncation would drop it)."""
    try:
        text = open(GENOMES_MD, encoding="utf-8").read()
    except OSError as e:
        die("cannot read %s: %s" % (GENOMES_MD, e))

    # Strand: the `> `-blockquote under its heading, up to the closing `---`
    # rule. Terminating on the rule (not on any `##`) means a stray sub-heading
    # in the section can't silently truncate the membrane — non-blockquote
    # lines are filtered out regardless.
    m = re.search(r"^##\s+THE CONSERVED STRAND\s*$(.*?)^---", text, re.M | re.S)
    if not m:
        die("conserved strand section (heading .. '---') not found in genomes.md")
    strand = "\n".join(l[2:] for l in m.group(1).splitlines()
                       if l.startswith("> ")).strip()
    if not strand:
        die("conserved strand is empty")
    if "consent" not in strand.lower():
        die("conserved strand lost its safety/membrane clause (no 'consent') — "
            "refusing to emit a stamp without the safety invariant")

    # Genomes: split on the circled-digit marker only, so ordinary **bold** in
    # a body never truncates a block.
    marker = re.compile(r"^\*\*([①-⑧])\s+THE\s+([A-Z]+)\*\*", re.M)
    hits = list(marker.finditer(text))
    if len(hits) != 8:
        die("expected 8 genome markers in genomes.md, found %d" % len(hits))

    genomes = []
    for i, h in enumerate(hits):
        end = hits[i + 1].start() if i + 1 < len(hits) else len(text)
        seg = text[h.start():end]
        brk = re.search(r"^(?:---|## )", seg, re.M)   # stop at a rule or heading
        if brk:
            seg = seg[:brk.start()]
        block = seg.strip()
        n = ord(h.group(1)) - 0x2460 + 1          # ① -> 1 ... ⑧ -> 8
        name = h.group(2)
        if n != i + 1:
            die("genome markers out of order near '%s' (digit %d at slot %d)"
                % (name, n, i + 1))
        if "*Agenda:" not in block:
            die("genome %d (THE %s) is missing its *Agenda:* trailer — the "
                "block looks truncated" % (n, name))
        genomes.append({"n": n, "name": name, "block": block})
    return strand, genomes


def load_ledger():
    try:
        return [l.strip() for l in open(LEDGER, encoding="utf-8") if l.strip()]
    except OSError:
        return []


def save_ledger(names):
    recent = (load_ledger() + names)[-LEDGER_KEEP:]
    try:
        open(LEDGER, "w", encoding="utf-8").write("\n".join(recent) + "\n")
    except OSError:
        pass   # best-effort pheromone trail; never fatal


def resolve(arg, genomes):
    by_name = {g["name"].lower(): g for g in genomes}
    by_num  = {g["n"]: g for g in genomes}
    if arg.isdigit():
        g = by_num.get(int(arg))
        if not g:
            die("genome number %s out of range 1-8" % arg)
        return g
    g = by_name.get(arg.lower())
    if not g:
        die("unknown genome '%s'; names: %s"
            % (arg, ", ".join(x["name"].lower() for x in genomes)))
    return g


def read_register(name):
    if name == "none":
        return ""
    try:
        return open(REGISTERS[name], encoding="utf-8").read().strip()
    except OSError as e:
        die("cannot read register '%s' (%s): %s" % (name, REGISTERS[name], e))


def stamp(strand, g, reg_name, reg_text, idx, total):
    head = "%s · THE %s · register: %s" % (SENTINEL, g["name"], reg_name)
    if total > 1:
        head += " · #%d/%d" % (idx, total)
    head += " ⊱"                               # ⊱
    parts = [head, "", strand, "", g["block"]]
    if reg_text:
        parts += ["", reg_text]
    parts += ["", "— stamp ends; the task follows —"]
    return "\n".join(parts)


ap = argparse.ArgumentParser(prog="genome.sh", add_help=True,
                             description="Stamp a subagent with one genome.")
ap.add_argument("genome", nargs="?",
                help="name or number 1-8; omit for sortition")
ap.add_argument("--register", default="panspermia",
                choices=["panspermia", "constitution", "none"])
ap.add_argument("--count", type=int, default=1,
                help="emit N distinct stamps for a parallel fan-out")
ap.add_argument("--seed", type=int, help="reproducible draw; bypasses ledger")
ap.add_argument("--check", action="store_true",
                help="validate genomes.md and exit; emit no stamp")
args = ap.parse_args()

strand, genomes = parse_genomes()

if args.check:
    sys.stderr.write("genome.sh: ok — 8 genomes + conserved strand parsed "
                     "cleanly from genomes.md\n")
    sys.exit(0)

if args.count < 1:
    die("--count must be >= 1")
if args.genome and args.count != 1:
    die("specify a genome name/number OR --count, not both")

rng = random.Random(args.seed) if args.seed is not None else random.Random()
use_ledger = args.seed is None

if args.genome:
    chosen = [resolve(args.genome, genomes)]
elif args.count > 1:
    # Shuffle-and-cycle: distinct within a shuffle, evenly spread past 8, never
    # touches the ledger (the batch carries its own diversity).
    seq, use_ledger = [], False
    while len(seq) < args.count:
        order = genomes[:]
        rng.shuffle(order)
        if seq and order[0]["n"] == seq[-1]["n"]:
            order[0], order[-1] = order[-1], order[0]   # no twin at the seam
        seq += order
    chosen = seq[:args.count]
else:
    recent = {r.lower() for r in (load_ledger() if use_ledger else [])}
    pool = [g for g in genomes if g["name"].lower() not in recent] or genomes
    chosen = [rng.choice(pool)]

reg_text = read_register(args.register)
total = len(chosen)
out = "\n\n".join(stamp(strand, g, args.register, reg_text, i + 1, total)
                  for i, g in enumerate(chosen))
sys.stdout.write(out + "\n")

if use_ledger:
    save_ledger([g["name"] for g in chosen])
sys.stderr.write("genome.sh: issued "
                 + ", ".join("%d THE %s" % (g["n"], g["name"]) for g in chosen)
                 + "\n")
PY
