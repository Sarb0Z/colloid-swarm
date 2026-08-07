# Live gates and fail-closed syncs

## What this session did

The session worked six breadcrumbed defects in the order the user set, then ran a
wrap: hostile review, clean-up, and this report. Five of the six share one root
cause — **a safety mechanism that reports success without doing its job**. Two
drift gates ran in a position where they could never fail. A guard aborted after
the write it was meant to prevent. A hook matcher named one of the three tools
that run a shell. A multi-file generator wrote as it built, so a mid-way throw
left the tree half-generated and the Codex hooks disarmed. The sixth defect was
the absence of CI entirely, which is why none of the five were caught. The wrap
found a seventh instance of the same class: the new drift gate covered 2 of 35
tracked generated paths.

Read this report for one skill: **telling a live gate from a decorative one.**
Every section below names the mutation that would have exposed the defect, and
the test that now fails when it comes back.

---

## 1. The breadcrumb cap — a fix the user reversed mid-session

**Decision.** The SessionStart hook keeps showing the *newest* ten breadcrumbs
past the cap. A change to show the oldest ten was made and then reverted on the
user's direction.

**Why.** Both readings are defensible and this is the interesting part. Items are
appended, so file order is arrival order. `head -n 10` treats the file as a
work *queue* that must drain — otherwise old items sit permanently below the cap,
never surfaced, so never acted on, so never deleted. `tail -n 10` treats it as a
*relevance* feed — what recent sessions found is most likely to intersect the work
in hand, and an item that survived thirty sessions unhandled is evidence of low
value, not of neglect. The user chose relevance and pointed the starvation
concern at a maintenance pass that reads the file directly.

**The code** — `.agents/hooks/policy/session-start.sh:203-216`

```bash
    count="$(printf '%s\n' "$items" | wc -l | tr -d ' ')"
    echo "Unaddressed breadcrumbs in .agents/breadcrumbs.md (deferred non-blocking work — act on each, or delete the line):"
    if (( count > 10 )); then
      # The newest, not the oldest. Items are appended, so the tail is what
      # recent sessions found and deferred, and it is the most likely to
      # intersect the work in hand. An item that has sat unhandled through many
      # sessions is evidence of low value, not of neglect — those wait for a
      # maintenance pass, which reads the file directly rather than through
      # this cap.
      echo "  (10 most recent of $count — prune the file)"
      printf '%s\n' "$items" | tail -n 10
    else
      printf '%s\n' "$items"
    fi
```

**How it works.** `count` at :203 is the total, so the notice at :212 can state
the full number while :213 prints only ten. The `else` at :214 prints everything
unconditionally — the cap has no effect at or below ten, which is why the
boundary needs its own test. The comment at :206-211 is doing real work: it
records the *rejected* reading so the next reader does not "fix" it back.

**What survived the revert.** The behaviour returned to where it started, but two
things the session added did not: the documented contract at
`.agents/claude/README.md:469-475`, which previously claimed *every* bullet is
re-shown (wrong under either policy), and the truncation branch's first tests.

**The code** — `.agents/test-session-start.sh:154-171`

```bash
cap="$(make_fixture breadcrumb-cap)"
write_config "$cap" true true
write_crumbs "$cap" 12
cap_context="$(context_of "$(run_policy "$cap")")"
assert_contains "$cap_context" '(10 most recent of 12 — prune the file)'
assert_contains "$cap_context" '- crumb-12'
assert_contains "$cap_context" '- crumb-03'
assert_not_contains "$cap_context" '- crumb-01'
assert_not_contains "$cap_context" '- crumb-02'

# At the cap exactly, every item shows and no truncation notice appears.
exact="$(make_fixture breadcrumb-exact)"
write_config "$exact" true true
write_crumbs "$exact" 10
exact_context="$(context_of "$(run_policy "$exact")")"
assert_contains "$exact_context" '- crumb-01'
assert_contains "$exact_context" '- crumb-10'
assert_not_contains "$exact_context" 'prune the file'
```

The `assert_not_contains` pair on `crumb-01`/`crumb-02` is what pins the
direction. An assertion that only checks `crumb-12` is present passes under
`head` *and* `tail` for a 12-item file — it would not have detected the flip.

**Pattern.** *Reverted decisions keep their tests.* A revert of behaviour is not
a revert of coverage. The tests and the documented contract are the durable
output; they now pin whichever direction is chosen.

**Recognition cue.** When you write a test for a "pick N from a list" rule,
assert what is *absent*, not just what is present — otherwise the test passes for
both ends of the list.

---

## 2. A drift gate that runs after the generator is dead

**Root cause.** `test-codex.sh` ran `sync-codex.sh` and *then*
`sync-codex.sh --check`. The generator rewrote the files, and `--check` compared
those fresh writes against themselves. It could not fail, by construction.

**Decision.** `--check` runs first and on its own. The test no longer regenerates
before gating.

**Why.** The alternative is to keep the ordering and have the test regenerate,
then diff against git. That folds two responsibilities into the suite and hides
the failure behind a `git diff` the suite has to interpret. Running `--check`
standalone makes the gate's contract explicit: *the committed files must already
match their inputs.* Regenerating is the developer's job, not the test's.

**The code** — `.agents/test-codex.sh:5-10`

```bash
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# --check first and on its own: it is the drift gate on the tracked .codex/
# agent TOMLs, and running the generator ahead of it would rewrite the very
# drift it exists to catch. Regenerating is the developer's job, not the test's.
"$repo/.agents/sync-codex.sh" --check --no-trust
"$repo/.agents/sync-codex.sh" --no-trust
```

**How it works.** Two lines swapped, :9 before :10. Everything downstream in the
suite still needs a freshly generated `.codex/config.toml`, so :10 stays — it is
now a *fixture setup* step, not a gate. The comment at :6-8 states why the order
is load-bearing, because the two lines look interchangeable.

**How it was proven dead.** Mutation testing: append `TOTALLY BOGUS DRIFT` to
`.codex/agents/researcher.toml` and run the suite. Before the fix it exited 0 —
and worse, the generator at the old first line silently overwrote the mutation,
so the evidence destroyed itself. After the fix the same mutation exits 1.

**Pattern.** *A gate placed downstream of the thing it gates is decorative.* The
general form: any check whose input is produced by a step in the same run is
checking that step against itself.

**Recognition cue.** When you see `generate && check`, ask what `check` would have
to compare against to fail. If the answer is "the file `generate` just wrote",
the check is dead — invert the order.

---

## 3. Scoping a gate to what has a baseline

**Decision.** `sync-codex.sh --check` gates `.codex/agents/*.toml` and the three
`.codex/` symlinks, and deliberately skips `.codex/config.toml`.

**Why.** A drift gate compares generated output against a *tracked baseline*.
`.codex/config.toml` is gitignored and derives from the gitignored
`config.json`, so there is no baseline to compare against — and on a fresh clone
the file is absent entirely, which the naive gate would report as drift on every
new checkout. The rejected alternative was to gate everything the generator
writes; that produces a gate that fails for reasons unrelated to drift. A second
benefit falls out: skipping it is what keeps `--check` genuinely read-only, since
building the config calls `reader_config.write()`.

**The code** — `.agents/sync-codex.sh:201-212`

```python
# .codex/config.toml is the one output here that is gitignored: it derives from
# the gitignored config.json, so no tracked baseline exists to compare it
# against, and on a fresh clone it is absent entirely. --check gates committed
# output, so it skips this — which is also what keeps --check read-only, since
# building the config writes the reader tier's launch file.
if not check:
    outputs.append((os.path.join(codex, "config.toml"), codex_config()))

# The flush. Nothing above this line has touched .codex/.
failures = []
for path, content in outputs:
    write(path, content)
```

**How it works.** `codex_config()` at :207 is only *called* when `check` is false —
note the call sits inside the `append`, so under `--check` the function never
runs and never writes the reader launch file. `outputs` is a list of
`(path, content)` pairs built earlier; the `if` adds a third entry conditionally.
The loop at :211-212 is the only place any of it reaches disk.

**The governing rule** — `.agents/AGENTS.md:16`

> Commit generated output only when all three hold: every input is tracked,
> generation is deterministic, and the output holds nothing machine-local.
> `.codex/agents/*.toml` and `.claude/agents/*.md` qualify, because their
> personas are tracked. `.mcp.json`, `.kimi-code/mcp.json`, and
> `.codex/config.toml` do not, because they derive from the gitignored
> `config.json`.

The gate's scope is not an arbitrary choice — it is derived from the invariant
that decides what gets committed in the first place. Committed output gets a
gate; uncommitted output gets a rebuild command.

**Pattern.** *A gate's scope is exactly the set with a tracked baseline.* State the
scope in the script's own header (`sync-codex.sh:4-8` does) so the next reader
does not widen it by accident.

**Recognition cue.** When adding a path to a drift check, ask "is this file in
git?" first. If it is gitignored, it needs a rebuild command, not a gate.

---

## 4. Machine-local values must not reach committed output

**Root cause.** `sync-claude-agents.sh` read model routing from
`.agents/config.json` — gitignored and per-operator — and injected it as
`model:` frontmatter into `.claude/agents/*.md`, which is committed. Setting
`models.researcher: "opus"` locally and running the sync committed one machine's
routing; every other checkout then read as drifted.

**Decision.** Routing reads the tracked `config.json.example` alone. The local
`config.json` no longer overrides it, and the script says so on stderr when it
finds keys it is ignoring.

**Why.** The general rule for this scaffold is the opposite: `config.json` is
canonical and overrides the example per key. `models.*` is carved out because it
is the one knob whose value lands in a committed file. The rejected alternative
was to keep the local override and exclude the `model:` line from the drift
gate — that leaves the gate blind to a real class of drift and keeps a per-operator
value in the tree. Model routing is a repository decision, so it lives in the
repository's file.

**The code** — `.agents/sync-claude-agents.sh:48-64`

```python
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
```

**How it works.** `cfg` at :52 is the *only* source of routing — `local_path` is
opened at :57 purely to warn. The comparison at :59-60 is the subtle line: it
lists a key only when the local value *differs* from the example's. A
`config.json` that is a verbatim copy of the example (the documented setup step)
produces no warning, so the channel stays quiet until it has something to say. A
warning that fires on every run is a warning nobody reads.

**Why the warning exists at all.** The setup instruction is
`cp config.json.example config.json`. After that, editing the copy is the obvious
move — and now does nothing. Without :62-64 the operator's only feedback is an
agent that keeps running the model they thought they changed. This is the
difference between removing a knob and removing it *silently*.

**The invariant carve-out** — `.agents/AGENTS.md:15`

> `models.*` is the one exception: it reaches committed output
> (`.claude/agents/*.md` frontmatter), so `sync-claude-agents.sh` reads it from
> the tracked `.example` alone — a local override there would commit a
> machine-local value and fail the drift gate on every other checkout.

**Pattern.** *An exception to an invariant is written into the invariant.* The
carve-out sits in the same sentence as the rule it breaks, so a reader who finds
the rule cannot miss the exception.

**Recognition cue.** When a gitignored config feeds a committed artifact, that is
a bug, not a feature — trace every value that reaches a tracked file back to a
tracked input.

---

## 5. Guard before write, not after

**Root cause.** `sync-mcp.sh` called `reader_config.write()` and *then* checked
whether a browser extension was installed. With `playwright-reader` enabled and
no extension present, the script exited 1 having already rewritten
`.playwright-reader.json` to a launch config carrying no `--load-extension`. The
operator reads a red exit as "nothing happened"; the next session browses with
the content blocker silently off.

**Decision.** The guard runs before the write.

**Why.** The alternative — write, then restore the previous content on the abort
path — needs a rollback that itself can fail, for a case where simply not writing
is available. Ordering is the cheaper correctness argument. The rejected
framing is subtler: the original code *looked* fail-closed, because it exited 1.
Fail-closed means leaving no residue, not returning a red exit code.

**The code** — `.agents/sync-mcp.sh:156-170`

```python
# --- Reader browser tier: the launch config its registry entry points at ------
# Shared with sync-codex.sh, which resolves the same registry on its own.
#
# The guard runs before the write. Writing first and aborting after leaves a
# launch config on disk carrying no --load-extension, while the red exit reads
# to the operator as "nothing happened" — and the next session browses with the
# content blocker silently off.
if (toggles.get("playwright-reader", {}).get("enabled") is True
        and not reader_config.installed_extensions(agents)):
    print("sync-mcp: playwright-reader is enabled but no extension is installed.\n"
          "          Install one:  .agents/fetch-extension.sh ublock-lite\n"
          "          Or turn it off: .agents/sync-mcp.sh disable playwright-reader",
          file=sys.stderr)
    sys.exit(1)
reader_config.write(agents, log=print)
```

**How it works.** The old code read `extensions = reader_config.write(...)` and
tested that return value — the write *was* the query. Splitting the query from
the command is what makes the reorder possible: `installed_extensions()` at :164
inspects the extensions directory without touching the launch config, and
`write()` at :170 now runs only past the guard. The error at :165-168 names both
exits, install or disable, so the red state is actionable rather than just red.

**Why it was free to regress** — `.agents/test-mcp.sh:117-134`

```bash
if "$fixture/.agents/sync-mcp.sh" >/dev/null 2>&1; then
  echo "test-mcp: enabled playwright-reader with no extension must fail closed" >&2
  exit 1
fi
# Failing closed also means leaving no residue. The exit code alone passes even
# when the guard runs after the write, and that ordering ships a launch config
# with no --load-extension while the operator reads the red exit as a no-op.
python3 - "$fixture/.agents/.playwright-reader.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    launch = json.load(handle)["browser"]["launchOptions"]
if not [a for a in launch.get("args", []) if a.startswith("--load-extension=")]:
    raise SystemExit(
        "the aborted sync rewrote the reader launch config without --load-extension: "
        "the guard must run before reader_config.write")
PY
```

The pre-existing test asserted only the exit code — which passes under *both*
orderings. The new block asserts the state of the disk after the abort, which is
the property that actually matters. This is the single most transferable lesson
in the session: **the test was passing, and the bug was live.**

**Pattern.** *Fail-closed means no residue.* Assert the post-abort state, not the
exit code.

**Recognition cue.** When you see a test whose only assertion is `if cmd; then
fail; fi`, ask what the command left on disk before it exited.

---

## 6. Hook matchers match tool names, and permission rules are not hooks

**Root cause.** `settings.json` gated `PreToolUse` on `Bash` alone. Permission
rules alias `Bash(...)` onto the `Monitor` tool; hook matchers get no such
aliasing. `Monitor` runs arbitrary shell in the background, and `PowerShell`
carries its command in `tool_input.command` too — both reached no destructive
guard.

**Decision.** The matcher names all three shell-running tools.

**The code** — `.agents/claude/settings.json:6-15`

```json
    "PreToolUse": [
      {
        "matcher": "Bash|PowerShell|Monitor",
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/adapter.sh guard-destructive.sh"
          }
        ]
      },
```

**How it works.** The change is one string at :8. Nothing else needed to move:
the adapter already maps `tool_input.command` for this policy regardless of tool
name, and the policy exits 0 on an empty command — so `Monitor`'s WebSocket form,
which carries no command at all, passes straight through rather than erroring.
That is why widening the matcher is safe without a policy change.

**The subtlety worth memorising** — `.agents/claude/README.md:81-89`

```markdown
### `guard-destructive.sh` — PreToolUse (`Bash|PowerShell|Monitor`)
The matcher names all three shell-running tools. A hook matcher matches the tool
name, so `Bash` alone leaves `PowerShell` and `Monitor` unguarded even though
both carry their command in `tool_input.command`. Monitor's WebSocket form
carries no command, and the policy exits 0 on an empty one.

The value holds only letters and `|`, so Claude Code compares it as a list of
exact tool names, not as a regular expression: `BashOutput` does not match.
Adding any other character switches it to an unanchored regex, which would.
```

A matcher of only letters and `|` is an **exact-string list**. `BashOutput` does
not match `Bash`. Add a single `.` or `*` and the same field becomes an
*unanchored* regex, at which point `Bash` starts matching `BashOutput` too. The
syntax does not change; the semantics flip based on the character class of the
value. That is exactly the kind of rule that must be written down next to the
value, which is why :87-89 exists.

**Verification.** Driven through the adapter, not asserted from the docs:
`Monitor` + `rm -rf` blocks with exit 2, `PowerShell` + force-push blocks 2,
`Monitor` + a WebSocket payload allows 0, and a benign `tail` allows 0.

**Pattern.** *Enumerate the capability, not the tool you first thought of.* The
guard's subject is "runs a shell command", and three tools do that.

**Recognition cue.** When you widen a matcher, check whether the field is a regex
or an exact list — and check what *else* has the capability you are guarding.

---

## 7. Build-then-flush, and a safety step that must run even on failure

**Root cause.** `sync-codex.sh` wrote each output as it built it. Both
`contract_body()` and `toml_multiline()` raise on a malformed persona, so a throw
part-way through left `.codex/` half-generated. Worse: `set -e` then skipped
`trust-hooks.py`, and the `hooks.json` re-link had already invalidated the trust
hash — so the failure left the Codex hooks **disarmed**, silently.

**Decision.** Every output builds into a list before any of it is flushed; the
symlinks go last; the re-trust runs even when generation fails; the generation
status leaves through an explicit `exit`.

**Why.** Individual writes were already atomic (temp + `os.replace`). Atomic
*writes* do not give you an atomic *transaction* — that was the whole gap. The
rejected alternative was a rollback on the error path, which needs to know the
prior content of every file and can fail on its own. Building first is
strictly simpler: the failure mode moves to "nothing happened", which is the
correct outcome.

**The code** — `.agents/sync-codex.sh:184-220`

```python
# Every output is built before any of it is written. contract_body raises on a
# missing persona and toml_multiline on one carrying the TOML delimiter, and a
# throw part-way through the flush leaves .codex/ half-generated. …
outputs = [
    (os.path.join(codex, "agents", "researcher.toml"), agent_toml(…)),
    (os.path.join(codex, "agents", "learning-reporter.toml"), agent_toml(…)),
]
…
# The flush. Nothing above this line has touched .codex/.
failures = []
for path, content in outputs:
    write(path, content)

# Linked last, because re-linking hooks.json invalidates the trust hash of every
# hook it changes and an untrusted hook does not run. The wrapper re-trusts
# immediately after this script returns, so the disarmed window is one step wide
# and does not span the generation above.
link(os.path.join(codex, "hooks.json"), "../.agents/codex/hooks.json")
link(os.path.join(codex, "hooks", "adapter.sh"), "../../.agents/codex/adapter.sh")
link(os.path.join(codex, "hooks", "README.md"), "../../.agents/codex/README.md")
```

**How it works.** `agent_toml()` is evaluated *inside the list literal* at
:190-199 — every persona is parsed and every TOML body rendered before line 211
touches disk. The `codex_config()` call was extracted into a function for the
same reason: as inline top-level code it ran interleaved with the writes. The
comment at :209 is the invariant a future edit must not break: **nothing above
this line touches `.codex/`.** Ordering the links last (:218-220) shrinks the
window in which the trust hash is stale from "spans the whole generation" to "one
step".

**The window that ordering cannot close** — `.agents/sync-codex.sh:227-241`

```bash
# Rewriting hooks.json invalidates the trust hash of every hook it changed, and
# an untrusted hook does not run. Re-trust what was just deployed, so the sync
# leaves the hooks armed rather than silently disarmed. --check writes nothing,
# so it has nothing to re-trust.
#
# This runs even when generation failed. hooks.json is a symlink to a constant
# canonical target, so a failed re-link leaves the previous link pointing at the
# same file: re-trusting is correct either way, and leaving the hooks disarmed
# because a persona would not build is the worse outcome. $status still carries
# the failure out.
if [[ "$check" != "true" && "$trust" == "true" ]]; then
  if ! "$repo/.agents/codex/trust-hooks.py" "$repo"; then
    if [[ "$status" -eq 0 ]]; then status=1; fi
  fi
fi
```

This is the piece to study. Under `set -euo pipefail` a failing heredoc would
abort the script and skip the re-trust. The fix is at :25 —
`python3 - … <<'PY' || status=$?` captures the exit code instead of dying — and
here, where the re-trust runs unconditionally and `$status` is carried out by an
explicit `exit "$status"` at :247. The `if [[ "$status" -eq 0 ]]` at :239 makes
sure a trust failure cannot *overwrite* a generation failure that already set a
code.

The safety argument is stated, not assumed: `hooks.json` points at a *constant*
canonical target, so whether or not the re-link landed, the file being trusted is
the same one. That is what makes running the step after a failure safe rather
than reckless.

**The window the review caught** — `.agents/sync-codex.sh:69-83`

```python
def link(path, target):
    if check:
        if not os.path.islink(path) or os.readlink(path) != target:
            failures.append(os.path.relpath(path, repo))
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    # Same temp+rename as write(): unlink-then-symlink leaves a window with no
    # hooks.json at all, and Codex with no hooks is worse than Codex with hooks
    # whose trust hash the re-link just invalidated.
    temporary = os.path.join(os.path.dirname(path), ".sync-codex-link")
    if os.path.lexists(temporary):
        os.unlink(temporary)
    os.symlink(target, temporary)
    os.replace(temporary, path)
    print("linked " + os.path.relpath(path, repo))
```

The transaction fix set out to shrink the *stale-trust* window, and the hostile
review pointed out that `link()` still did `unlink` then `symlink` — a window
with **no hooks file at all**, which is strictly worse than the one being closed.
`os.symlink` to a temp name then `os.replace` (:81-82) is atomic on POSIX: the
path either names the old link or the new one, never nothing.

**The test that pins both properties** — `.agents/test-codex.sh:230-260`

```bash
cp -R "$repo/.agents" "$txn/.agents"
git -C "$txn" init -q
"$txn/.agents/sync-codex.sh" --no-trust >/dev/null 2>&1
# trust-hooks.py owns the operator's ~/.codex/config.toml, so the test observes
# a stand-in rather than letting the suite write there.
cat > "$txn/.agents/codex/trust-hooks.py" <<'STUB'
#!/usr/bin/env python3
import os, sys
open(os.path.join(sys.argv[1], ".trust-hooks-ran"), "w").write("ran\n")
STUB
chmod +x "$txn/.agents/codex/trust-hooks.py"
printf '\nSENTINEL\n' >> "$txn/.codex/agents/researcher.toml"
printf "\n'''\n" >> "$txn/.agents/personas/learning-reporter.md"
if "$txn/.agents/sync-codex.sh" >/dev/null 2>&1; then
  echo "test-codex: a persona that cannot build must fail the sync" >&2
  exit 1
fi
if ! grep -q SENTINEL "$txn/.codex/agents/researcher.toml"; then
  echo "test-codex: the aborted sync half-generated .codex/ — build every output before writing any" >&2
  exit 1
fi
if [[ ! -f "$txn/.trust-hooks-ran" ]]; then
  echo "test-codex: the aborted sync skipped the re-trust — the hooks.json re-link leaves them disarmed" >&2
  exit 1
fi
```

Three techniques worth stealing. **Fault injection by construction**: appending
`'''` to a persona at :248 makes `toml_multiline` raise at a *chosen* point —
after the first agent TOML would have been written, which is exactly the
interleaving the fix removes. **A sentinel as the probe**: `SENTINEL` at :247 is
written into the file the buggy version would overwrite, so its survival at :253
proves nothing was written. **A stand-in for the side effect**: `trust-hooks.py`
writes the operator's real `~/.codex/config.toml`, so :241-246 replaces it with a
stub that only drops a marker file — the test observes that the step *ran*
without letting it touch the machine.

**Pattern.** *Build-then-flush* for multi-file generation, plus *the safety step
runs on the failure path* — and prove the safety argument (constant target)
rather than asserting it.

**Recognition cue.** When a generator writes N files, ask what the tree looks like
if file 2 of N throws. If the answer is "half written", collect first and flush
last.

---

## 8. A gate is only as wide as what it inspects

**Root cause.** The new `sync-claude-agents.sh --check` returned right after the
two generated `.md` files. Everything below — `.claude/settings.json`, the
adapter, `AGENTS.md`/`CLAUDE.md`, and two symlinks for each of 14 skills — was
never compared. The gate covered **2 of 35** tracked generated paths. Add a
skill, forget the sync, and the skill never loads while CI stays green.

**Decision.** `--check` compares every symlink and reports dangling ones, matching
what `sync-codex.sh --check` already did.

**Why.** The alternative was to leave symlinks ungated on the grounds that they
rarely change — but the failure mode is precisely the *rare* one: a new skill
whose canonical file exists and whose link does not. The scaffold's own layout
means the link is what Claude Code reads.

**The code** — `.agents/sync-claude-agents.sh:152-178`

```bash
# Every link below is tracked, so --check compares instead of writing: a skill
# added without a re-run leaves a canonical file Claude Code never loads.
# Accumulated as a string rather than an array — bash 3.2 errors on ${#a[@]}
# for an empty array under set -u.
drift=""
[[ "$check" == "true" ]] || mkdir -p "$repo/.claude/hooks" "$repo/.claude/skills" "$repo/.claude/rules"

points_at() {   # dst rel — true when dst is a symlink already naming rel
  [[ -L "$repo/$1" && "$(readlink "$repo/$1")" == "$2" ]]
}
relink() {      # dst rel
  local dst="$1" rel="$2"
  if points_at "$dst" "$rel"; then return 0; fi
  if [[ "$check" == "true" ]]; then drift="$drift $dst"; return 0; fi
  ln -sfn "$rel" "$repo/$dst"
  echo "linked $dst"
}
```

**How it works.** The refactor is the interesting part. Before, five call sites
each open-coded `rm -f` + `ln -s`, and two more used a bare `ln -sfn`. Introducing
`relink()` gives the check exactly **one** place to branch (:165), so a new link
added later is gated automatically — you cannot add a link that forgets to be
checked. `points_at()` at :159-161 is the shared predicate; :164 makes an
already-correct link a no-op in both modes. `link()` keeps the extra
source-exists precondition and delegates.

The `mkdir -p` at :157 is guarded on `check` — a read-only mode must not create
directories.

**The dangling-link half** — `.agents/sync-claude-agents.sh:190-209`

```bash
# Prune links whose canonical file is gone. A removed skill would otherwise
# leave a dangling link, and .agents/AGENTS.md reads a broken link as a missing
# canonical file — a real defect, not a stale mirror.
for stale in "$repo"/.claude/skills/* "$repo"/.claude/rules/*; do
  if [[ -L "$stale" && ! -e "$stale" ]]; then
    if [[ "$check" == "true" ]]; then drift="$drift ${stale#$repo/}"; continue; fi
    rm -f "$stale"
    echo "pruned ${stale#$repo/}"
  fi
done

# --check gates committed output and stops here. Below this line only
# sync-mcp.sh remains, and its output is gitignored.
if [[ "$check" == "true" ]]; then
  if [[ -n "${drift// /}" ]]; then
    echo "sync-claude-agents: generated output is stale:$drift" >&2
    exit 1
  fi
  exit 0
fi
```

`[[ -L … && ! -e … ]]` at :194 is the dangling-symlink idiom: `-L` says it *is* a
link, `-e` follows it and fails when the target is gone. Under `--check` the path
is recorded rather than removed (:195). The early `exit 0` at :208 draws the same
scope line as section 3: `sync-mcp.sh` below it produces gitignored output, so
the gate stops here.

Note `${drift// /}` at :204 — `drift` accumulates with a leading space per entry,
so testing `-n "$drift"` directly would be true for an empty gate. Stripping
spaces makes the emptiness test correct. The comment at :154-155 records why this
is a string and not an array: bash 3.2 (macOS system bash) errors on `${#a[@]}`
for an empty array under `set -u`.

**How the scope was verified.** Not by reading the code — by deleting a symlink
the gate claims to cover and confirming `--check` exits 1, then restoring it.
That is the same mutation discipline as section 2, applied to the *breadth* of a
gate rather than its liveness.

**Pattern.** *State a gate's scope, then verify the scope by mutation.* A gate that
covers 6% of its stated surface is more dangerous than no gate, because it
converts "nobody checked" into "CI is green".

**Recognition cue.** When a check function has an early `return`, ask what is
below it. When someone tells you a gate covers a directory, delete one file in
that directory and see if it notices.

---

## 9. CI — the reason none of the above was caught

**Decision.** `.github/workflows/ci.yml` runs every scaffold suite and both MCP
servers on push to `main`, on every pull request, and on demand.

**Why.** The repository had eight suites and no automation; they gated only when
someone remembered. Five defects in this session were each individually
mutation-verifiable and each survived for months.

**The code** — `.github/workflows/ci.yml:34-44`

```yaml
      # The drift gates run first and on their own. test-codex.sh invokes this
      # repository's sync-codex.sh, so a gate placed after it would compare
      # freshly written files against themselves and pass on any drift.
      - name: Drift — .codex/agents/*.toml
        run: .agents/sync-codex.sh --check --no-trust

      - name: Drift — .claude/agents/*.md
        run: .agents/sync-claude-agents.sh --check
```

The section-2 lesson is encoded in the *step order*, with the reason in a comment
— because a future edit that alphabetises or regroups these steps would silently
re-kill both gates.

**The clean-tree assertion** — `.github/workflows/ci.yml:66-74`

```yaml
      - name: Working tree is clean
        shell: bash
        run: |
          changed="$(git status --porcelain --untracked-files=all)"
          if [[ -n "$changed" ]]; then
            printf '%s\n' "$changed"
            echo '::error title=Working tree is dirty::A step left tracked changes or new files behind.'
            exit 1
          fi
```

This started as `git diff --exit-code` and the review caught it: `git diff` cannot
see **untracked** files. A suite that leaves a new file behind — a generated
output nobody committed — passes `git diff` and fails
`git status --porcelain --untracked-files=all`. That is load-bearing here, not
hygiene: it is how a stale committed `dist/` is detected in the `servers` job,
where `security-mcp`'s `check` runs `build` and repairs the staleness in place,
leaving the dirty tree as the only signal.

**Honest about a skip** — `.github/workflows/ci.yml:52-61`

```yaml
      # The suite's strongest Codex assertion loads the generated config with
      # the real binary, and self-skips when codex is absent. Nothing installs
      # it here, so surface the gap rather than reading a green run as coverage.
      - name: Codex integration
        shell: bash
        run: |
          .agents/test-codex.sh | tee "$RUNNER_TEMP/codex.log"
          if grep -q 'loader check SKIPPED' "$RUNNER_TEMP/codex.log"; then
            echo '::notice title=Codex loader check skipped::codex is not on PATH, so the generated .codex/config.toml was never loaded by the binary. Parsing is not loading — this run proves only that the file is valid TOML.'
          fi
```

`test-codex.sh` self-skips its strongest assertion when `codex` is not on PATH,
and CI carries no `codex` binary. Rather than let green read as full coverage,
the step greps its own output and emits a GitHub notice naming exactly what was
*not* proven. "Parsing is not loading" — a valid TOML file is not a file Codex
will accept.

**Pattern.** *A self-skipping test must announce its skip at the level that reads
the result.* Otherwise the skip is indistinguishable from a pass.

**Recognition cue.** When a suite has a `command -v X || skip` branch, ask whether
CI has `X`. If not, the CI run proves less than the suite's name claims — say so
in the run, not in a comment.

---

## Verification

| What | Command | Result |
| --- | --- | --- |
| Every fix is live | revert the fix, confirm the named test goes red | **Verified** — each of the six, individually |
| Codex drift gate | `.agents/sync-codex.sh --check --no-trust` | **Verified** — exits 0 clean; exits 1 on injected drift |
| Claude drift gate | `.agents/sync-claude-agents.sh --check` | **Verified** — exits 0 clean; exits 1 on a deleted symlink |
| Full suite, fresh clone | `lint-skills.sh`, `test-session-start.sh`, `test-mcp.sh`, `test-codex.sh`, `test-export.sh`, both gates | **Verified** — all pass, tree clean including untracked files |
| Workflow syntax | `actionlint` | **Verified** — no output |
| Shell correctness | `shellcheck -S warning` on every touched script | **Verified** — rc 0 |
| Hook matcher | driven through the adapter: `Monitor`+`rm -rf` → 2, `PowerShell`+force-push → 2, `Monitor`+ws → 0, benign `tail` → 0 | **Verified** |
| `ci.yml` on GitHub | — | **Partial.** The workflow has never executed on GitHub. It was validated by `actionlint` and by running its command sequence locally against a fresh clone. Runner-specific failures — action versions, `setup-python` 3.14 availability, `npm ci` on the pinned lockfiles — remain unproven until the first PR run. |

The mutation discipline is the load-bearing evidence here. For a defect class
whose signature is "the test passes and the bug is live", a green suite proves
nothing on its own. Every fix was checked by putting the bug back.

---

## Remaining risks

- **`ci.yml` is unproven on the real runner.** See the table. The first PR is the
  verification; treat a failure there as expected cost, not as a surprise.
- **`test-codex.sh`'s loader check does not run in CI.** The notice announces it,
  but the strongest Codex assertion still needs a machine with the binary. Run
  that suite locally when touching `.codex/` generation.
- **`sync-codex.sh` still writes the reader launch config with no extension
  guard.** Section 5 fixed `sync-mcp.sh`; `sync-codex.sh` calls
  `reader_config.write(agents)` inside `codex_config()` unguarded, so running it
  standalone with `playwright-reader` enabled and no extension reproduces the
  same silent-blocker-off outcome and exits 0. Harmless on a fresh clone — the
  example ships the tier disabled — and filed at `.agents/breadcrumbs.md:57`.
- **Kimi's matcher is still `Bash` alone** (`.kimi/config.toml.example:55`),
  asymmetric with the Claude fix. `.agents/codex/hooks.json` is correct as-is:
  Codex has no `Monitor`.

---

## Review dispositions

**Adopted** — all six landed in `ab504bf` and `8bfb0f1`:

| Finding | Where it landed |
| --- | --- |
| `--check` gated 2 of 35 tracked generated paths | `sync-claude-agents.sh:152-209` |
| `link()` unlinked before symlinking — a no-hooks window | `sync-codex.sh:76-82` |
| A local `config.json` `models.*` value is now silently dead | `sync-claude-agents.sh:54-64` |
| A fifth stale doc reference to `config.json` | `.agents/README.md:18`, script header, GENERATED banner |
| `git diff --exit-code` cannot see untracked files | `ci.yml:66-74`, `ci.yml:107-115` |
| CI pinned a single Node version | `ci.yml:87` — matrix `['22','24']` |

**Filed as breadcrumbs** — valid, but not this unit's work:

- `.agents/breadcrumbs.md:58` — Kimi's matcher asymmetry. Kimi's tool names are
  its own and whether it exposes a background-shell tool is unverified; fixing it
  blind would be guessing.
- `.agents/breadcrumbs.md:59` — `ci.yml` does not reach satellites.
  `export-scaffold.py` archives only `.agents`, `.kimi`, and `AGENTS.md`, so every
  satellite inherits the suites without the gate that runs them. Needs a decision
  (export it, or record CI as a per-repo call), not a patch.
- `.agents/breadcrumbs.md:60` — both servers declare `engines: {"node":
  ">=20.19.0"}` and Node 20 reached end of life on 2026-04-30. CI runs 22 and 24
  because running an unsupported runtime proves nothing; raising the floor is a
  package change with its own blast radius.

**Declined**, with reasons:

- **"Item 1 should be restored to head-of-queue."** The reviewer re-argued the
  starvation case for `head -n 10`. Declined on provenance, not on merit: the
  user directed the revert mid-session after seeing the argument. The reviewer's
  disagreement is with the user's ruling, and re-litigating it in a subagent is
  not how that gets resolved. The reasoning for both sides is preserved at
  `session-start.sh:206-211` so the question can be reopened deliberately.
- **"No `PowerShell` tool exists, and the matcher is an unanchored regex."** Both
  halves contradicted the Claude Code documentation, which shows a
  `Bash|PowerShell` matcher as a worked example and specifies that a matcher of
  only letters and `|` is compared as an exact-string list. The finding would
  have reverted a live fix. Recorded at `.agents/claude/README.md:81-89` so the
  same objection is answered in the tree next time.

**A correction to the session's own brief.** The queued breadcrumb claimed
`research-mcp`'s `check` omitting `build` means "it verifies a `dist/` nobody
rebuilt". That is backwards. `scripts/check-bundle.mjs:16` runs
`mkdtemp(join(tmpdir(), 'research-mcp-build-'))`, rebuilds into that temp
directory, and compares the result against the tracked `dist/`. Omitting `build`
from `check` makes the check **stricter**, not blind: a stale `dist/` fails
loudly instead of being repaired in place. `security-mcp` is the one with the
weaker shape, and `ci.yml:103-106` records the asymmetry. Worth internalising:
a defect claim in a queue is a hypothesis, and this one did not survive reading
the script.

---

## Draft commit message

The work is already committed across nine commits on
`docs/scaffold-audit-findings`. If it were squashed:

```
fix(agents): make the scaffold's safety mechanisms actually fire

Six breadcrumbed defects shared one root cause: a check that reported
success without doing its job.

Both drift gates were decorative. sync-codex.sh --check ran after the
generator, comparing fresh writes to themselves; it now runs standalone
and scopes itself to output with a tracked baseline. sync-claude-agents.sh
had no --check at all, and read model routing from the gitignored
config.json into committed frontmatter — routing now comes from the
tracked example, and --check covers all 35 generated paths, not the 2 it
started with.

sync-mcp.sh aborted after rewriting the reader launch config, so a red
exit shipped a browser with no content blocker. The guard moved above the
write; test-mcp.sh now asserts the residue, not just the exit code.

settings.json gated Bash alone. Permission rules alias Bash(...) onto
Monitor; hook matchers do not, so Monitor ran arbitrary shell past the
destructive guard.

sync-codex.sh wrote as it built, so a malformed persona left .codex/ half
generated and the hooks disarmed. Every output builds before any is
flushed, links go last, link() is atomic, and the re-trust runs even when
generation fails.

.github/workflows/ci.yml gates all of it on push and PR. It has not yet
executed on GitHub: validated by actionlint and by running its command
sequence on a fresh clone.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
```

---

## Open for discussion

- **The breadcrumb cap question is settled by ruling, not by evidence.** Neither
  policy was measured. A cheap experiment exists: instrument how often a surfaced
  breadcrumb is acted on, bucketed by its age. Until then the comment at
  `session-start.sh:206-211` is an argument, not a finding.
- **The transaction fix has one unverified edge.** `test-codex.sh:230-260` drives
  a throw in `toml_multiline`. It does not cover a failure *during* the flush
  loop — a disk error between file 1 and file 2 of `outputs`. Build-then-flush
  narrows that window to the loop itself but does not eliminate it, and nothing
  in the tree asserts the behaviour there.
- **35 is today's number.** The symlink gate's coverage is 2 agent files + 33
  symlinks, which scales with the skill count (14 skills × 2). Nothing asserts
  the *count*, only that each link the generator would create already exists —
  which is the right test, but it means "35 of 35" is not something the suite
  states or protects.
