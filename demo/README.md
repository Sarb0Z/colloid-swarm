# Scaffold demo

One command, live output, no slides:

```
bash demo/demo.sh
```

It exercises the runnable cores of the mechanical layer against real inputs and
prints what they actually emit. Every beat runs offline. Each beat that needs a
repository, a policy file or a workloop run builds it in one scratch folder,
and an `EXIT` trap removes that folder, so a run leaves nothing behind. Scratch
commits use a fixed demo identity and no signing, so the viewer's git setup
cannot stop the run.

## The beats

1. **Static personas** (`.agents/personas/`) — one file each for `explorer`,
   `implementer`, `learning-reporter`, `mechanic`, `qa-verifier`, `researcher`
   and `reviewer`. Each dispatch names its model and role directly.
2. **Layout check** (`.agents/check-layout.py`) — validates canonical files and
   host fan-out paths against the current tree.
3. **The membrane** (`.agents/hooks/policy/guard-destructive.sh`) — blocks
   irreversible commands (exit 2 plus a reason) and passes safe ones. The
   Claude, Codex and Kimi hook configurations all call this one script. The
   guard exits 0 when it cannot read its payload, so it is a strong filter, not
   a sandbox.
4. **Progressive disclosure** (scoped `AGENTS.md` hierarchy) — counts the
   canonical instruction files, verifies that every fan-out symlink under each
   host folder (`.claude`, `.codex`, `.opencode`, `.kimi`, `.github`) and
   `.agents` resolves, and shows one rule reached through three tool doors.
   A host folder that is not in the checkout is skipped.
5. **Scaffold export** (`.agents/export-scaffold.py`) — emits the satellite copy
   into the scratch folder, then proves the subtraction held: every dropped
   path is absent, no host's hook table still names a dropped policy, no
   `colloid-only` marker line survives, and the genome config keys are gone. The
   assertions read the export's own drop lists, so a new entry is checked here
   the moment it is added.
6. **Repository-owned MCP** (`.agents/mcp.py`, `.agents/mcp-servers/`) — speaks the real MCP
   handshake to both committed bundles over stdio, lists the tools each
   registers, then calls the two guards. `security-mcp` allows loopback and
   refuses a public host and a cloud-metadata address; `research-mcp` refuses
   link-local, loopback, and `file://`. Both refuse before opening a socket,
   which is why this beat needs no network. This beat alone needs Node
   `>=20.19.0`; without it the beat prints a SKIP notice.
7. **The publish guard** (`.agents/hooks/policy/guard-publish.sh`) — sends
   payloads in the shape Claude Code's hook sends to a scratch repository with
   one commit and no remote. Outward commands (a push, a pull request merge, a
   package publish, a hosted deploy) get `ask` in default mode. Reads stay
   quiet. The same push in `auto` mode, where nobody can answer a prompt, gets
   `deny`. The guard also reads this checkout's `hooks.guard_publish.enabled`
   setting and prunes expired approval tokens from this checkout's `.agents/`.
8. **Declared read access** (`.agents/access.py`) — `access.py check` reads the
   systems a repository declares in `.agents/policy.json`. One scratch policy
   declares a pull request merge as a read, and the check refuses it by name.
   A second declares only a list command, and the check passes. The check
   prints its summary only when nothing fails, hence two calls.
9. **A test that catches its bug** (`.agents/revert-check.sh`) — a scratch
   repository holds a bug, its fix, a test that asserts the result and a test
   that only checks a file exists. The script restores the bug and reruns each
   test: the asserting test fails there (it catches the defect), and the other
   one still passes (it does not).
10. **The completion gate** (`.agents/workloop.py`) — a scratch workloop run
    with one lane. `check --recorded` names what blocks completion; after a
    review and QA evidence, `check` runs the run's composed test and passes; a
    later commit and resubmit moves the lane's tip, and `check --recorded`
    reports the review and the QA record as stale. Every call carries `--state`
    and `--repo` for the scratch folder, so no run lands in this checkout.

## The "it's real" moment

The live session's own guard is wired to the same scripts. Writing `rm -rf ~`
straight into a shell here gets **blocked before it runs** — the demo assembles
its probe payloads at runtime specifically so presenting it doesn't trip the
very membrane it's demonstrating. The scaffold governs the session showing it.

## Requirements

`bash`, `python3` and `git` cover every beat except the MCP beat, which also
needs Node `>=20.19.0`.

## What isn't in this script

The genome *content* (`genomes.md`, `colloid-constitution.md`, `panspermia.txt`),
the skills (`.agents/skills/`), and the per-host adapters (`.claude/`, `.codex/`,
`.opencode/`, `.kimi/`) are the rest of the kit — read `README.md` at the repo
root for the full map. This demo is the mechanical proof; those are the payload.
