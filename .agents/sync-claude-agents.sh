#!/usr/bin/env bash
# Sync Claude agent definitions from their tracked inputs
#
# Reads model routing from .agents/config.json.example and regenerates
# .claude/agents/*.md with the correct frontmatter. Each agent's body is taken
# from its source contract in .agents/ (orchestrator meta blockquotes stripped).
#
# Usage:
#   .agents/sync-claude-agents.sh [--check]
#
# --check writes nothing and exits 1 on any drift between the tree and what this
# script emits. .claude/agents/*.md is committed, so drift there ships a
# definition contradicting the persona it claims to carry. Run it on its own —
# after the generator it compares fresh writes to themselves.
#
# Generate mode exits 1 only when it could not do its work: a missing canonical
# source, or a link destination that is a real directory. A path it reports but
# will not delete — an unrecognised file under .claude/agents, a link naming a
# skill that is not installed — prints and does not fail the run, so a stray
# file cannot break the chain to sync-mcp.sh.
#
# Deletion is confined to dangling symlinks. This script does not own every file
# under .claude/agents, and the emitted set it compares against is accumulated
# by side effect, so an input it could not read yields an empty set — safe to
# report against, unsafe to delete against.
#
# Do not hand-edit files in .claude/agents/ — they are generated.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) check=true; shift ;;
    *) echo "usage: sync-claude-agents.sh [--check]" >&2; exit 2 ;;
  esac
done
config="$repo/.agents/config.json.example"
local_config="$repo/.agents/config.json"
agents_dir="$repo/.claude/agents"
src_dir="$repo/.agents/personas"

[[ "$check" == "true" ]] || mkdir -p "$agents_dir"

# Both halves of the gate report together. The Python block records drift here
# rather than exiting on it, so a stale agent definition cannot abort the run
# before the symlinks below are compared and leave the operator fixing one
# class per CI round.
drift_file="$(mktemp)"
trap 'rm -f "$drift_file"' EXIT

python3 - "$config" "$local_config" "$agents_dir" "$src_dir" "$check" "$drift_file" <<'PY'
import json, os, sys

config_path, local_path, agents_dir, src_dir, check, drift_path = sys.argv[1:]
check = check == "true"

def load(path):
    # Absent is a fresh clone; malformed is a typo the operator must see.
    # sync-codex.sh's loader splits these the same way, which .agents/AGENTS.md
    # requires of every sync script.
    try:
        with open(path, encoding="utf-8") as f:
            value = json.load(f)
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError as error:
        raise SystemExit(f"sync-claude-agents: invalid JSON in {path}: {error}")
    return value if isinstance(value, dict) else {}

# Routing comes from config.json.example, never the gitignored, per-repo
# config.json: `model:` lands in the frontmatter of a committed file, so reading
# the local config would commit one operator's machine-local routing and make
# every other checkout read as drifted.
cfg = load(config_path)

# Setup is `cp config.json.example config.json`, so editing the copy is the
# obvious move and does nothing here. Say so rather than leaving the operator to
# infer it from an agent that keeps running the model they thought they changed.
local_models = load(local_path).get("models", {})
if isinstance(local_models, dict):
    ignored = sorted(k for k, v in local_models.items()
                     if cfg.get("models", {}).get(k) != v)
    if ignored:
        print("sync-claude-agents: model routing comes from config.json.example; "
              "these config.json keys are ignored: " + ", ".join(ignored),
              file=sys.stderr)

# Agent registry: one entry per generated definition. `model_key` indexes
# cfg["models"]; a null/absent model omits the frontmatter line (inherit parent).
AGENTS = [
    {
        "name": "researcher",
        "model_key": "researcher",
        "source": "researcher.md",
        "description": "Delegate research tasks that turn on current or external facts — library APIs, version compatibility, best practices, security implications, anything load-bearing where a wrong answer changes shipped code. Invoked via Task(subagent_type='researcher', prompt='[genome stamp] + [research question]').",
    },
    {
        "name": "learning-reporter",
        "model_key": "learning_reporter",
        "source": "learning-reporter.md",
        "description": "Generate a learning-focused session report for a junior reviewing the work — pairs each engineering decision and tradeoff with the actual code (file:line) that embodies it, written to docs/learning/. In pairing mode the report is produced inline by default; dispatch this subagent when the user asks to persist it to a file. Invoked via Task(subagent_type='learning-reporter', prompt='[decision-brief] + [changed files]'). Exempt from genome stamping — prepend no stamp.",
    },
]

header = (
    "<!-- GENERATED by .agents/sync-claude-agents.sh — do not hand-edit. "
    "Edit .agents/personas, or models in .agents/config.json.example, "
    "and run the sync script. -->\n"
)

failures, emitted = [], []
for agent in AGENTS:
    model = cfg.get("models", {}).get(agent["model_key"])
    model_line = f"model: {model}" if model else ""

    # Strip orchestrator meta blockquotes: blockquotes before the first ## heading
    # are instructions for the orchestrator; blockquotes after it are contract
    # examples for the agent and stay.
    with open(os.path.join(src_dir, agent["source"]), encoding="utf-8") as f:
        lines = f.readlines()

    body_lines = []
    seen_heading = False
    for line in lines:
        if line.startswith("## "):
            seen_heading = True
        if not seen_heading and (line.startswith("> ") or line.strip() == ">"):
            continue
        # export-scaffold.py's region markers are source annotations, not
        # content; the agent reads this body and should never see them.
        if line.strip() in ("<!-- colloid-only -->", "<!-- /colloid-only -->"):
            continue
        body_lines.append(line)

    body = "".join(body_lines).strip()

    frontmatter_parts = ["---", f"name: {agent['name']}", f"description: {agent['description']}"]
    if model_line:
        frontmatter_parts.append(model_line)
    frontmatter_parts.append("---")
    frontmatter = "\n".join(frontmatter_parts)

    # Frontmatter MUST start on line 1 — Claude Code only registers an agent
    # whose `---` is the first byte of the file. The GENERATED banner therefore
    # sits just below the closing `---`, inside the markdown body.
    output = frontmatter + "\n" + header + "\n" + body + "\n"

    out_path = os.path.join(agents_dir, agent["name"] + ".md")
    emitted.append(out_path)
    if check:
        try:
            with open(out_path, encoding="utf-8") as f:
                actual = f.read()
        except FileNotFoundError:
            actual = None
        if actual != output:
            failures.append(out_path)
        continue

    with open(out_path, "w", encoding="utf-8") as f:
        f.write(output)

    print("generated " + out_path + (f" (model: {model})" if model else " (no model override)"))

# An agent dropped from AGENTS leaves a definition Claude Code keeps loading
# after its source contract is gone. Reported, never deleted: .claude/agents is
# Claude Code's project-subagent directory and this script does not own every
# file in it, so an operator's own definition would be destroyed with no git
# history to recover it from. Whoever reads the report decides.
for name in sorted(os.listdir(agents_dir)) if os.path.isdir(agents_dir) else []:
    stale = os.path.join(agents_dir, name)
    if not name.endswith(".md") or stale in emitted:
        continue
    failures.append(stale + " (not generated; remove it by hand if it is stale)")

# Drift is data, not an exit code: the caller merges it with the symlink half.
with open(drift_path, "a", encoding="utf-8") as f:
    for path in failures:
        f.write(path + "\n")
PY

# The adapter layer itself. These four have no generator — they are hand-
# written sources that live under .agents/ so the tracked tree carries them,
# and .claude/ gets symlinks. Without this a checkout that ignores .claude/
# has no settings and no adapter, which means no hooks at all.
#
# Every link below is tracked, so --check compares instead of writing: a skill
# added without a re-run leaves a canonical file Claude Code never loads.
# `drift` is what the gate rejects; `blocked` is what stopped the generator
# doing its job. A generate run fails only on the second: it must not break the
# chain to sync-mcp.sh over a stray file it deliberately refuses to delete.
drift=()
blocked=()
expected=$'\n'   # newline-delimited repo-relative paths this run emits
[[ "$check" == "true" ]] || mkdir -p "$repo/.claude/hooks" "$repo/.claude/skills" "$repo/.claude/rules"

points_at() {   # dst rel — true when dst is a symlink already naming rel
  [[ -L "$repo/$1" && "$(readlink "$repo/$1")" == "$2" ]]
}
relink() {      # dst rel
  local dst="$1" rel="$2"
  expected="$expected$dst"$'\n'
  if points_at "$dst" "$rel"; then return 0; fi
  if [[ "$check" == "true" ]]; then drift+=("$dst"); return 0; fi
  # ln -sfn resolves a real directory destination and links *inside* it,
  # reporting success while --check fails forever. The old rm -f aborted here.
  if [[ -d "$repo/$dst" && ! -L "$repo/$dst" ]]; then
    echo "sync: $dst is a directory, not a link" >&2
    blocked+=("$dst (directory)")
    return 0
  fi
  ln -sfn "$rel" "$repo/$dst"
  echo "linked $dst"
}
link() {        # source under .agents/claude, destination under .claude
  local src="$1" dst="$2" rel="$3"
  # A missing canonical source is drift, not a reason to abandon the remaining
  # comparisons — returning non-zero here would abort the whole report.
  if [[ ! -f "$repo/$src" ]]; then
    echo "sync: missing source $src" >&2
    blocked+=("$src (missing source)")
    return 0
  fi
  relink "$dst" "$rel"
}
link .agents/claude/settings.json .claude/settings.json    ../.agents/claude/settings.json
link .agents/claude/adapter.sh    .claude/hooks/adapter.sh ../../.agents/claude/adapter.sh
link .agents/claude/README.md     .claude/hooks/README.md  ../../.agents/claude/README.md
link .agents/claude/AGENTS.md     .claude/AGENTS.md        ../.agents/claude/AGENTS.md
relink .claude/CLAUDE.md AGENTS.md

# One symlink per installed skill: Claude reads .claude/skills/<name> and
# .claude/rules/<name>.md, both resolving back to the canonical copy under
# .agents/skills/, which Kimi and Codex already read natively.
for skill_dir in "$repo"/.agents/skills/*/; do
  [[ -d "$skill_dir" ]] || continue
  n="$(basename "$skill_dir")"
  relink ".claude/skills/$n"   "../../.agents/skills/$n"
  relink ".claude/rules/$n.md" "../../.agents/skills/$n/AGENTS.md"
done

# Anything under the generated directories this run did not emit: a dangling
# link whose canonical file is gone, and equally a link that resolves fine but
# names a skill absent from .agents/skills/, which a broken-link test cannot see.
#
# Deletion is limited to the dangling case. The emitted set is authoritative
# enough to *report* against but not to delete against: it is built by side
# effect of the loop above, so any input the loop could not read yields an empty
# set and a silent sweep of every link here. Reporting is safe under that
# failure; deleting is not.
for stale in "$repo"/.claude/skills/* "$repo"/.claude/rules/*; do
  [[ -e "$stale" || -L "$stale" ]] || continue
  rel="${stale#$repo/}"
  if [[ "$expected" == *$'\n'"$rel"$'\n'* ]]; then continue; fi
  if [[ -L "$stale" && ! -e "$stale" ]] && [[ "$check" != "true" ]]; then
    rm -f "$stale"
    echo "pruned $rel"
    continue
  fi
  drift+=("$rel (not generated; remove it by hand if it is stale)")
done

# The Python half recorded its drift as data so both classes report together.
while IFS= read -r line; do
  [[ -n "$line" ]] && drift+=("${line#$repo/}")
done < "$drift_file"

# --check gates committed output and stops here. Below this line only
# sync-mcp.sh remains, and its output is gitignored.
if (( ${#blocked[@]} > 0 )); then
  printf 'sync-claude-agents: could not generate:\n' >&2
  printf '  %s\n' "${blocked[@]}" >&2
  exit 1
fi
if (( ${#drift[@]} > 0 )); then
  printf 'sync-claude-agents: generated output is stale:\n' >&2
  printf '  %s\n' "${drift[@]}" >&2
  [[ "$check" == "true" ]] && exit 1
fi
if [[ "$check" == "true" ]]; then
  exit 0
fi

# MCP + LSP connection files ride the same "edited config.json -> re-run sync"
# habit; sync-mcp.sh is a no-op-safe generator, cheap to always run.
"$(dirname "${BASH_SOURCE[0]}")/sync-mcp.sh"
