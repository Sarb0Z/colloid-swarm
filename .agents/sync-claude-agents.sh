#!/usr/bin/env bash
# Sync the Claude adapter layer from its tracked inputs
#
# Generates .claude/agents/*.md from .agents/personas plus the model routing in
# .agents/config.json.example, and links the rest of .claude/ back to the
# canonical files under .agents/.
#
# Usage:
#   .agents/sync-claude-agents.sh [--check]
#
# --check writes nothing and exits 1 on any disagreement between .claude/ and
# what this script owns. Run it on its own — after the generator it compares
# fresh writes to themselves.
#
# Generate mode exits 1 only when it could not do its work: a missing canonical
# source, or a link destination that is a real directory. Both stop the run
# before sync-mcp.sh. Untracked files under the managed directories are left
# alone and not reported — they are nobody's drift, because the manifest this
# gate compares against is what git tracks.
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

python3 - "$repo" "$check" <<'PY'
import json, os, subprocess, sys

repo, check = sys.argv[1], sys.argv[2] == "true"
agents = os.path.join(repo, ".agents")


def load(path):
    # Absent is a fresh clone; malformed is a typo the operator must see.
    # sync-codex.sh's loader splits these the same way, which .agents/AGENTS.md
    # requires of every sync script.
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError as error:
        raise SystemExit(f"sync-claude-agents: invalid JSON in {path}: {error}")
    return value if isinstance(value, dict) else {}


# Routing comes from config.json.example, never the gitignored, per-repo
# config.json: every field below lands in the frontmatter of a committed file,
# so reading the local config would commit one operator's machine-local routing
# and make every other checkout read as drifted.
cfg = load(os.path.join(agents, "config.json.example"))

# Setup is `cp config.json.example config.json`, so editing the copy is the
# obvious move and does nothing here. Say so rather than leaving the operator to
# infer it from an agent that keeps running the model they thought they changed.
local = load(os.path.join(agents, "config.json"))
local_subagents = local.get("subagents", {})
if isinstance(local_subagents, dict):
    ignored = sorted(key for key, value in local_subagents.items()
                     if cfg.get("subagents", {}).get(key) != value)
    if ignored:
        print("sync-claude-agents: subagent routing comes from config.json.example; "
              "these config.json keys are ignored: " + ", ".join(ignored),
              file=sys.stderr)

local_tiers = local.get("tiers", {})
if isinstance(local_tiers, dict):
    ignored_tiers = sorted(key for key, value in local_tiers.items()
                           if cfg.get("tiers", {}).get(key) != value)
    if ignored_tiers:
        print("sync-claude-agents: tier routing comes from config.json.example; "
              "these config.json tiers are ignored: " + ", ".join(ignored_tiers),
              file=sys.stderr)

# `models` is a key nothing reads, sitting in a file whose contract is "overrides
# the example per key" -- so it reads as live config and is not. Every existing
# config.json has one, satellites included, and silence there is the same defect
# the dead `models.explore`/`models.plan` keys were: a knob wired to nothing.
if "models" in local:
    print("sync-claude-agents: config.json carries a `models` block that nothing "
          "reads; subagent routing is `subagents.<name>` in config.json.example. "
          "Delete the block.", file=sys.stderr)

# Agent registry: one entry per generated definition. `name` indexes
# cfg["subagents"], whose fields become frontmatter; a null or absent field
# omits its line, which is how a definition inherits the parent's value.
AGENTS = [
    {
        "name": "implementer",
        "source": "implementer.md",
        "description": "Delegate one bounded implementation unit after the plan is settled. Make the change, run its narrow acceptance command, and return the result and remaining proof boundary.",
    },
    {
        "name": "mechanic",
        "source": "mechanic.md",
        "description": "Delegate mechanical, bounded edits with one obvious result: renames, formatting, straightforward moves, or a narrow verified fix.",
    },
    {
        "name": "explorer",
        "source": "explorer.md",
        "description": "Trace codebase structure, definitions, callers, data flow, and tests for one bounded question without editing.",
    },
    {
        "name": "qa-verifier",
        "source": "qa-verifier.md",
        "description": "Verify changed tests, APIs, and web behavior with focused executable scenarios. Report evidence, failures, and coverage gaps.",
    },
    {
        "name": "reviewer",
        "source": "reviewer.md",
        "description": "Independently review a plan or diff against repository rules and stated intent. Return conformance, concrete findings, and required handoffs.",
    },
    {
        "name": "researcher",
        "source": "researcher.md",
        "description": "Research current or external facts with primary sources, confidence, dates, and explicit evidence gaps.",
    },
    {
        "name": "learning-reporter",
        "source": "learning-reporter.md",
        "description": "Generate a learning-focused session report for a junior reviewing the work — pairs each engineering decision and tradeoff with the actual code (file:line) that embodies it, written to docs/learning/. In pairing mode the report is produced inline by default; dispatch this subagent when the user asks to persist it to a file. Invoked via Task(subagent_type='learning-reporter', prompt='[decision-brief] + [changed files]'). Exempt from genome stamping — prepend no stamp.",
    },
]

# The adapter layer has no generator: these are hand-written sources under
# .agents/ so the tracked tree carries them, and .claude/ gets symlinks. Without
# them a checkout that ignores .claude/ has no settings and no adapter, which
# means no hooks at all.
ADAPTER = [
    (".agents/claude/settings.json", ".claude/settings.json", "../.agents/claude/settings.json"),
    (".agents/claude/adapter.sh", ".claude/hooks/adapter.sh", "../../.agents/claude/adapter.sh"),
    (".agents/claude/README.md", ".claude/hooks/README.md", "../../.agents/claude/README.md"),
    (".agents/claude/AGENTS.md", ".claude/AGENTS.md", "../.agents/claude/AGENTS.md"),
]

HEADER = (
    "<!-- GENERATED by .agents/sync-claude-agents.sh — do not hand-edit. "
    "Edit .agents/personas, or subagents in .agents/config.json.example, "
    "and run the sync script. -->\n"
)


# Canonical keys are snake_case; this map is the complete Claude frontmatter
# surface this scaffold supports. Unsupported config must fail instead of
# looking configured while silently inheriting a costly default.
CONFIGURED_FIELDS = (
    "tools", "tier", "memory", "effort", "max_turns", "permission_mode",
    "skills", "mcp_servers", "hooks", "background", "isolation", "color",
    "initial_prompt",
)
EMITTED = {
    "tools": "tools", "tier": "model", "memory": "memory", "effort": "effort",
    "max_turns": "maxTurns", "permission_mode": "permissionMode", "skills": "skills",
    "mcp_servers": "mcpServers", "hooks": "hooks", "background": "background",
    "isolation": "isolation", "color": "color", "initial_prompt": "initialPrompt",
}


def yaml_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, (str, list, dict)):
        return json.dumps(value, ensure_ascii=False)
    raise SystemExit("sync-claude-agents: frontmatter values must be JSON-compatible")


def resolve_tier(name, tier):
    """The model a tier names. A tier nothing defines is a typo, not a default.

    Personas name a tier and never a model, so one edit re-points every cell and
    a satellite on a provider whose aliases differ corrects itself in one place.
    Aliases beat pinned ids here: `sonnet` resolves to the latest Sonnet the
    provider offers, and a pinned id is wrong the moment either side moves.
    """
    tiers = cfg.get("tiers", {})
    if not isinstance(tiers, dict) or tier not in tiers:
        raise SystemExit(f"sync-claude-agents: subagents.{name}.tier is {tier!r}, "
                         f"which config.json.example tiers does not define "
                         f"({', '.join(sorted(tiers)) or 'no tiers at all'})")
    setting = tiers[tier]
    if (not isinstance(setting, dict) or not isinstance(setting.get("claude"), str)
            or not isinstance(setting.get("codex"), str)
            or not isinstance(setting.get("codex_effort"), str)):
        raise SystemExit(f"sync-claude-agents: tiers.{tier} must name Claude and Codex model/effort")
    return setting["claude"]


def definition(agent):
    """The full text of one agent definition, frontmatter first."""
    settings = cfg.get("subagents", {}).get(agent["name"], {})
    if not isinstance(settings, dict):
        raise SystemExit(f"sync-claude-agents: config.json.example subagents."
                         f"{agent['name']} is not an object")
    unknown = sorted(set(settings) - set(CONFIGURED_FIELDS))
    if unknown:
        # A typo here is silent otherwise: the key sits in config, no
        # frontmatter line is written, and the agent runs with the default.
        raise SystemExit(f"sync-claude-agents: config.json.example subagents."
                         f"{agent['name']} names fields this script does not "
                         f"emit: {', '.join(unknown)}")
    # Blockquotes before the first ## heading are instructions for the
    # orchestrator; blockquotes after it are contract examples for the agent.
    with open(os.path.join(agents, "personas", agent["source"]), encoding="utf-8") as handle:
        lines = handle.readlines()
    body, seen_heading = [], False
    for line in lines:
        if line.startswith("## "):
            seen_heading = True
        if not seen_heading and (line.startswith("> ") or line.strip() == ">"):
            continue
        # export-scaffold.py's region markers are source annotations, not
        # content; the agent reads this body and should never see them.
        if line.strip() in ("<!-- colloid-only -->", "<!-- /colloid-only -->"):
            continue
        body.append(line)
    front = ["---", f"name: {agent['name']}", f"description: {agent['description']}"]
    for field in CONFIGURED_FIELDS:
        value = settings.get(field)
        if value is None:
            continue                   # null or absent inherits the default
        if field == "tier":
            value = resolve_tier(agent["name"], value)
        front.append(f"{EMITTED[field]}: {yaml_value(value)}")
    front.append("---")
    # A persona mid-merge would otherwise be copied verbatim into a live system
    # prompt, and the gate would certify it: the comparison only asks whether the
    # output matches the input, and it does.
    for line in body:
        if line.startswith(("<<<<<<< ", "=======\n", ">>>>>>> ")):
            raise SystemExit(f"sync-claude-agents: {agent['source']} contains merge "
                             "conflict markers; resolve it before generating")
    # Frontmatter MUST start on line 1 — Claude Code only registers an agent
    # whose `---` is the first byte. The GENERATED banner therefore sits just
    # below the closing `---`, inside the markdown body.
    return "\n".join(front) + "\n" + HEADER + "\n" + "".join(body).strip() + "\n"


# --- The one derivation ------------------------------------------------------
# `plan` is every path this script owns, mapped to what belongs there. The
# comparison, the writes and the prune all read this and nothing else. Deriving
# it more than once is what made the same defect keep coming back: the copies
# disagreed, and whichever one the prune consulted decided what got deleted.
plan, blocked = {}, []


def plan_has_skills(entries):
    return any(rel.startswith(".claude/skills/") for rel in entries)

for agent in AGENTS:
    plan[f".claude/agents/{agent['name']}.md"] = ("file", definition(agent))

for source, destination, target in ADAPTER:
    if not os.path.isfile(os.path.join(repo, source)):
        blocked.append(f"{source} (missing source)")
        continue
    plan[destination] = ("link", target)
plan[".claude/CLAUDE.md"] = ("link", "AGENTS.md")

# One symlink pair per installed skill: Claude reads .claude/skills/<name> and
# .claude/rules/<name>.md, both resolving back to the canonical copy under
# .agents/skills/, which Kimi and Codex already read natively.
#
# Unguarded on purpose. Every way this read can fail — absent, a regular file, a
# broken symlink, unreadable — must raise, because each one otherwise yields an
# empty plan, and an empty plan authorises the prune below to delete every link
# it finds. A guard that turns any of them into "no skills installed" is the
# defect this file has already shipped twice.
skills_root = os.path.join(agents, "skills")
if os.path.islink(skills_root):
    raise SystemExit("sync-claude-agents: .agents/skills is a symlink; refusing to "
                     "treat whatever it points at as the installed skill set")
for name in sorted(os.listdir(skills_root)):
    if not os.path.isdir(os.path.join(skills_root, name)):
        continue
    plan[f".claude/skills/{name}"] = ("link", f"../../.agents/skills/{name}")
    plan[f".claude/rules/{name}.md"] = ("link", f"../../.agents/skills/{name}/AGENTS.md")
if not plan_has_skills(plan):
    raise SystemExit("sync-claude-agents: .agents/skills holds no skill directories; "
                     "refusing to prune every installed link on that basis")

# Path-scoped domain rules, one symlink each. A skill's rule is scoped to the
# skill's own directory and fires when an agent edits the skill; these are
# scoped by glob to product code and fire when an agent writes the product. The
# two land in one directory because Claude reads one directory, so a name taken
# by a skill is a collision that must stop the run rather than pick a winner.
rules_root = os.path.join(agents, "rules")
if os.path.islink(rules_root):
    raise SystemExit("sync-claude-agents: .agents/rules is a symlink; refusing to "
                     "link whatever it points at into .claude/rules")
for name in sorted(os.listdir(rules_root)) if os.path.isdir(rules_root) else []:
    if not name.endswith(".md") or not os.path.isfile(os.path.join(rules_root, name)):
        continue
    rel = f".claude/rules/{name}"
    if rel in plan:
        raise SystemExit(f"sync-claude-agents: .agents/rules/{name} collides with the "
                         f"skill of the same name; rename one")
    plan[rel] = ("link", f"../../.agents/rules/{name}")


def git(*arguments):
    """Run git, returning None when it could not answer at all."""
    try:
        result = subprocess.run(["git", "-C", repo, *arguments],
                                capture_output=True, text=True, errors="surrogateescape")
    except OSError:
        return None                       # git is not installed
    return result if result.returncode == 0 else None


def tracked_paths():
    """What git says .claude/ must hold, or None when git could not say."""
    result = git("ls-files", "-z", "--", ".claude")
    if result is None:
        return None
    return {entry for entry in result.stdout.split("\0") if entry}


# Directories the prune may consider. Everything else under .claude/ — most
# importantly the gitignored, per-operator settings.local.json — is out of reach.
MANAGED = (".claude/agents/", ".claude/skills/", ".claude/rules/")


def managed(rel):
    return rel.startswith(MANAGED)


# Claude Code supports hand-written project subagents, and .claude/agents is its
# directory, not this script's. Ownership is self-describing: every file this
# script writes carries the banner, and every managed link it writes is a
# symlink. Anything else under a managed path belongs to the operator, whether
# or not they committed it — so it is neither pruned nor called drift.
BANNER_MARK = "GENERATED by .agents/sync-claude-agents.sh"


def ours(path):
    """True when this script wrote it, False when it is the operator's, None
    when the file exists but could not be read to tell."""
    if os.path.islink(path):
        return True
    if not os.path.isfile(path):
        return False
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return BANNER_MARK in handle.read(4096)
    except OSError:
        return None


# One list and one scan, used by both the gate and the prune. Two copies of
# these directories, each with its own glob, is the shape that kept them
# disagreeing about what existed.
DANGLING_SCAN = MANAGED


def dangling(prefix):
    """Managed entries whose symlink target does not resolve, planned or not."""
    root = os.path.join(repo, prefix.rstrip("/"))
    found = []
    for name in sorted(os.listdir(root)) if os.path.isdir(root) else []:
        rel = prefix + name
        path = os.path.join(repo, rel)
        if os.path.islink(path) and not os.path.exists(path):
            found.append(rel)
    return found


drift = []
known = tracked_paths()

# --- Compare, or write. --check reports and touches nothing; the generator
# --- acts and reports what it did, so drift it is about to repair is not news.
if check:
    for rel in sorted(plan):
        kind, payload = plan[rel]
        path = os.path.join(repo, rel)
        if kind == "file":
            try:
                with open(path, encoding="utf-8") as handle:
                    actual = handle.read()
            except OSError:
                actual = None
            if actual != payload:
                drift.append(rel)
        elif not os.path.islink(path) or os.readlink(path) != payload:
            drift.append(rel)

    # Tracked only. An untracked broken link is the operator's work in progress,
    # and .agents/AGENTS.md says an operator's file is neither deleted nor
    # reported — reporting one here wedges --check, because the generator
    # rightly will not touch it and CI runs --check on every push.
    #
    # Planned entries are included: a skill directory with no AGENTS.md still
    # yields a .claude/rules/<name>.md, and comparing only the readlink string
    # calls that healthy. lint-skills.sh now prevents that at the source.
    for prefix in DANGLING_SCAN:
        for rel in dangling(prefix):
            if rel in (known or set()):
                drift.append(f"{rel} (dangling — remove it: git rm {rel})")

    if known is None:
        raise SystemExit("sync-claude-agents: --check needs a git work tree; "
                         "`git ls-files .claude` is the manifest it compares against")
    if not known:
        # A repository tracking nothing under .claude/ has opted out. Both
        # manifest directions are vacuous there and the per-path comparison
        # above still holds. Said aloud, so it cannot read as a clean bill.
        print("sync-claude-agents: .claude/ is untracked here; checked generated "
              "content only, not the set of paths", file=sys.stderr)
    else:
        for rel in sorted(known - set(plan)):
            path = os.path.join(repo, rel)
            # Only an existing file can be the operator's. A tracked path missing
            # from the worktree is a deletion still to be staged, which is drift.
            if managed(rel) and os.path.lexists(path) and ours(path) is False:
                continue          # the operator's own file, deliberately committed
            drift.append(f"{rel} (tracked, not generated — remove it: git rm {rel})")
        for rel in sorted(set(plan) - known):
            drift.append(f"{rel} (generated, not tracked — commit it)")
else:
    for directory in (".claude/agents", ".claude/hooks", ".claude/skills", ".claude/rules"):
        os.makedirs(os.path.join(repo, directory), exist_ok=True)

    def replace(path, produce):
        """Build beside the destination, then rename over it — never unlink first."""
        temporary = f"{path}.sync-claude-{os.getpid()}"
        if os.path.lexists(temporary):
            os.unlink(temporary)
        produce(temporary)
        os.replace(temporary, path)

    for rel in sorted(plan):
        kind, payload = plan[rel]
        path = os.path.join(repo, rel)
        if kind == "link" and os.path.islink(path) and os.readlink(path) == payload:
            continue
        if kind == "file" and os.path.isfile(path) and not os.path.islink(path) \
                and ours(path) is not True:
            # An operator subagent at a registry name. Overwriting it destroys
            # content this script did not write, and the names collide easily:
            # `researcher` is the example Claude Code's own docs use.
            blocked.append(f"{rel} (operator file at a generated name)")
            continue
        if os.path.isdir(path) and not os.path.islink(path):
            # A real directory here would swallow the link: `ln -sfn` and
            # os.symlink both place it inside rather than replacing it.
            blocked.append(f"{rel} (directory)")
            continue
        if kind == "file":
            def produce(temporary, payload=payload):
                with open(temporary, "w", encoding="utf-8") as handle:
                    handle.write(payload)
            replace(path, produce)
            print("generated " + rel)
        else:
            replace(path, lambda temporary, payload=payload: os.symlink(payload, temporary))
            print("linked " + rel)

# --- Report -----------------------------------------------------------------
if blocked:
    print("sync-claude-agents: could not generate:", file=sys.stderr)
    for entry in blocked:
        print("  " + entry, file=sys.stderr)
    raise SystemExit(1)
if drift:
    print("sync-claude-agents: generated output is stale:", file=sys.stderr)
    for entry in drift:
        print("  " + entry, file=sys.stderr)
    if check:
        raise SystemExit(1)
PY

if [[ "$check" == "true" ]]; then
  exit 0
fi

# MCP + LSP connection files ride the same "edited config.json -> re-run sync"
# habit; sync-mcp.sh is a no-op-safe generator, cheap to always run.
"$(dirname "${BASH_SOURCE[0]}")/sync-mcp.sh"
