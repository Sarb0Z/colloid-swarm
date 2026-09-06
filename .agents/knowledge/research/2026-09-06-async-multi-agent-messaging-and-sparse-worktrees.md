---
date: 2026-09-06
subject: What Claude Code hooks and native messaging can deliver to a running or idle agent, what git supports for sparse worktrees, and what this machine measured — an R&D pass over the workloop's async model
kind: research
source: see `## Sources`
---

# Async multi-agent messaging and sparse worktrees

Opened by three operator hypotheses: message inboxes tied to hooks are a
cheap notification layer; slow or unreliable inference forces an async
workflow that must hold up under contention; worktrees get slow on large or
vendored repositories and sparse checkouts help.

## Claims

Grades: `[P]` primary read directly · `[S]` secondary · `[?]` unverified ·
`[A]` our own measurement or analysis.

### What a hook can deliver

- `[P]` Every hook event accepts `hookSpecificOutput.additionalContext`
  except `Notification` and `StopFailure`, whose context fields are
  ignored. `SubagentStart`'s context seeds the subagent before its first
  prompt. Only `SessionStart`'s `initialUserMessage` creates a user turn,
  and only under `-p`. (hooks)
- `[P]` `asyncRewake: true` runs a hook in the background and "wakes Claude
  on exit code 2", showing its stderr as a system reminder; any other exit
  is silent. This is the one path by which something that happens
  mid-turn reaches the model without a tool call. (hooks)
- `[P]` No event fires on a timer or on generic idleness. `TeammateIdle`
  is a team lifecycle transition; `Notification`'s `idle_prompt` cannot
  inject context. (hooks)
- `[P]` Native delivery: "The receiving Claude reads the message between
  tool calls during an active turn … When the receiving session is idle,
  Claude Code starts a new turn with the message." A hook can match the
  first half; nothing a hook does can start a turn for an idle agent.
  (cross-session-messaging)
- `[P]` `notify_when_idle` is main-conversation only: "When a subagent or
  an agent team teammate sets `notify_when_idle`, Claude Code makes no
  subscription and tells it so." (cross-session-messaging)
- `[P]` Cross-session messages are live socket delivery, not persisted;
  agent-team mailboxes are JSON files under
  `~/.claude/teams/<team>/inboxes/`, validated on read. The team task list
  is file-backed with locking and dependency gating. (agent-teams)
- `[P]` "Agents can read each other's session contexts" is not a supported
  feature: messaging sends "a piece of text one Claude writes to another,
  never the sender's conversation history or files". Transcripts are
  plaintext at `~/.claude/projects/<project>/<session>.jsonl`, written
  asynchronously and lagging the live conversation. (claude-directory)
- `[P]` `ScheduleWakeup` and `CronCreate` fire only while the session is
  running and idle, are session-scoped, expire (recurring) after 7 days,
  and do not catch up missed fires. `/loop <interval> <command>` is the
  user-facing form the same page documents, and this host lists it as a
  built-in skill. (scheduled-tasks)

### Sparse worktrees

- `[P]` `git worktree add --no-checkout` exists "to make customizations,
  such as configuring sparse-checkout"; `git sparse-checkout set` upgrades
  the repository to `extensions.worktreeConfig` so each worktree carries
  its own cone. Cone mode is O(M+N); non-cone is deprecated. (git-worktree,
  git-sparse-checkout)
- `[P]` "Commands like merge or rebase can materialize paths to do their
  work (e.g. in order to show you a conflict)"; `sparse-checkout reapply`
  restores the cone. The sparse index is still marked experimental. (git-
  sparse-checkout, github.blog sparse-index)
- `[P]` pnpm silently skips `node_modules` for workspace packages whose
  directories are absent and reports success — an open issue. A sparse
  lane with a root pnpm lockfile installs a partial workspace and looks
  provisioned. (pnpm#7667)
- `[P]` Conductor hides unselected monorepo directories per workspace
  with sparse checkout; no other agent harness documents sparse or partial
  checkouts for agent workspaces. (conductor)
- `[P]` Claude Code's own worktrees are full checkouts; no sparse option.
  (worktrees)

### Measured here

- `[A]` Largest local repository (`clearclaim`, 2,252 tracked files): full
  `git worktree add` 9.1 s / 152 MB; `--no-checkout` + cone of the largest
  top directory + `read-tree -mu` 3.3 s / 12 MB / 828 files. Per-worktree
  sparse config took effect without manual setup. Its untracked
  `node_modules` is 765 MB — five times the full checkout — so on this
  class of repository provisioning, not checkout, is the dominant lane
  cost.
- `[A]` Sharing `node_modules` as one symlink fails twice: a `node_modules/`
  ignore pattern matches directories only, so the link is listed as
  untracked and `git add -A` commits it; and esbuild writes module paths
  resolved through the link into the bundle, with or without
  `preserveSymlinks`. A real directory of per-package links satisfies the
  ignore rule; folding the resolved prefix back to `node_modules/` before
  hashing makes the bundle manifest identical for a linked and a real
  install (verified on both MCP servers, main and lane).
- `[A]` Internal audit of `workloop.py`: the lane entry with its paths is
  written inside the exclusive lock before any work runs outside it, so
  concurrent `add-lane`s cannot both pass the overlap check; `integrate`
  recording tips at read time and `check` reporting `integration:stale`
  is the intended detection, not a race. What holds: nothing pushes —
  `inbox`, `watch`, `heartbeat`, `release-stale` are manual and session
  start surfaces no active run or unread message; finding messages are
  never archived under the 128 cap; a writer dispatched but never started
  leaves the gate's turn counter at 1 for the rest of that prompt.

## Sources

- https://code.claude.com/docs/en/hooks — read in full (fetched 2026-09-06)
- https://code.claude.com/docs/en/cross-session-messaging — read in full
- https://code.claude.com/docs/en/agent-teams — read in full
- https://code.claude.com/docs/en/claude-directory — read in full
- https://code.claude.com/docs/en/scheduled-tasks — read in full
- https://code.claude.com/docs/en/worktrees — read in full
- https://git-scm.com/docs/git-sparse-checkout — read in full
- https://git-scm.com/docs/git-worktree — read in full
- https://github.blog/open-source/git/bring-your-monorepo-down-to-size-with-sparse-checkout/ — read (2020-01-17)
- https://github.blog/open-source/git/make-your-monorepo-feel-small-with-gits-sparse-index/ — read (2021-11-10)
- https://github.blog/open-source/git/the-story-of-scalar/ — read (2022-10-13)
- https://www.kernel.org/pub/software/scm/git/docs/technical/partial-clone.html — read
- https://github.com/pnpm/pnpm/issues/7667 — read
- https://www.conductor.build/docs/guides/repositories/monorepos — read
