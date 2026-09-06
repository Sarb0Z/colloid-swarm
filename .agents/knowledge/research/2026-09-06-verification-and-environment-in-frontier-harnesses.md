---
date: 2026-09-06
subject: Where frontier coding harnesses put the verification loop relative to subagent fan-out, how they keep each isolated agent's environment current, and what this scaffold measured when it adopted the pattern under Claude Code
kind: research
source: see `## Sources` — each line carries the URL and how it was read
---

# Verification and environment in frontier harnesses

Opened by the question "should the root agent own tests, lint, and typecheck
so subagents stop burning time on them?" The answer from every first-party
account is no: isolate each writer and let it verify its own slice; what
makes that affordable is environment management, not centralised checking.

## Claims

Grades: `[P]` primary read directly · `[S]` secondary · `[?]` unverified ·
`[A]` our own measurement or analysis.

### Who verifies

- `[P]` Anthropic's orchestrator–worker research system is a read-only
  pattern the post says does not transfer to coding: "most coding tasks
  involve fewer truly parallelizable tasks than research, and LLM agents are
  not yet great at coordinating and delegating to other agents in real
  time." (multi-agent-research-system, 2025)
- `[P]` Cognition's *Don't Build Multi-Agents* (2025-06-12) argues for a
  single linear writer — "actions carry implicit decisions, and conflicting
  decisions carry bad results" — citing Claude Code's subagents as the model:
  never parallel with the main agent, "usually only tasked with answering a
  question, not writing any code."
- `[P]` Cognition reversed in *Devin can now Manage Devins* (2026-03-19):
  each managed Devin runs in its own VM and "can independently run shell
  commands, execute tests, and verify its own changes before reporting
  back." Verification moved into the isolated worker, not up to the parent.
- `[P]` Codex cloud runs one container per task; Jules one VM per task;
  SWE-agent and OpenHands one Docker sandbox per instance; Cursor a worktree
  per local agent and a VM per cloud agent. Factory scopes a review droid
  that "never writes features". No vendor documents "subagents produce
  diffs, the parent verifies."
- `[P]` Claude Code hooks fire inside subagent tool calls, carrying
  `agent_id`/`agent_type`, so a `PostToolUse` lint or typecheck already runs
  for every cell as a non-model layer. (hooks)

### Environment per isolated agent

- `[P]` Codex caches post-setup container state up to 12 hours, invalidated
  when the setup script, maintenance script, env vars, or secrets change or
  on manual reset. On resume: "Codex checks out the branch specified for the
  chat. Codex runs the maintenance script (optional). This is useful when
  the setup script ran on an older commit and dependencies need to be
  updated." Provision runs *after* checkout. (cloud-environment)
- `[P]` Cursor Builds snapshot the disk after `install`; a failed Build
  "never replaces the active one"; "Make install complete and idempotent. It
  can run repeatedly and may run on top of previously prepared disk state."
  A feature branch is checked out on top of the Build and "the agent
  receives your environment context and install command so it can refresh
  the environment before testing" — agent-driven, not detected. (builds,
  setup)
- `[P]` OpenHands tags sandbox images by a lock hash (`pyproject.toml` +
  `poetry.lock`) and a source hash; source-only change takes the fast path
  "bypassing all installation steps … except a final operation to copy the
  current source code." (runtime)
- `[P]` Devin keeps one snapshot per organisation; "session changes don't
  persist back to the snapshot." Jules snapshots per repository once a setup
  script exists. Neither documents a branch that changes the lockfile.
- `[P]` Claude Code worktrees are empty of untracked state; the docs say
  "ask Claude to install dependencies, or run your project's setup
  yourself." `.worktreeinclude` copies gitignored files into every worktree
  Claude creates with git. A `WorktreeCreate` hook replaces creation
  wholesale (fires before the worktree exists, with `worktree_path`), and
  hook-created worktrees are never auto-swept. Command hooks default to a
  600 s timeout; a timed-out hook "renders no decision". (worktrees, hooks)
- `[P]` Turborepo's local cache is shared across worktrees of one
  repository by task hash. (turborepo ai guide)
- `[P]` OpenCode recommends against a warm LSP daemon for agent verification:
  "Language servers can get out of sync, use significant memory … and slow
  down agent workflows." No first-party harness documents a shared
  typecheck daemon. (opencode lsp)
- `[?]` No vendor publishes setup or install time figures.
- `[P]` **No vendor documents environment/source mismatch as a failure mode
  or gives the agent a way to tell a missing dependency from a code
  defect.** Checked across Codex, Cursor, Devin, Jules, OpenHands docs.

### Network and packages

- `[P]` Codex agent-phase network is off by default for a stated security
  reason — "Prompt injection from untrusted web content; Code or secret
  exfiltration; Downloading malware or vulnerable dependencies" — with a
  named `Common dependencies` allowlist preset (npm, PyPI, crates.io, Go
  proxy, rubygems, maven, nuget, packagist, apt mirrors, container
  registries) and an HTTP-method restriction to GET/HEAD/OPTIONS. The base
  image preinstalls Python 3.10–3.14, Node 18/20/22, Rust, Go, Swift, Ruby,
  PHP, Java 11–25, bun, bazel, erlang, elixir; no pre-warmed package cache is
  documented. (internet-access, codex-universal)
- `[P]` Cursor: "The agent has internet access by default." Jules: VMs run
  "with internet access." Codex is the strict outlier, not the norm.
- `[P]` Claude Code's sandbox has `sandbox.network.allowedDomains` merged
  from any settings scope, but `strictAllowlist` is honoured from user,
  managed, or `--settings` scope only — a repository can suggest the
  registry allowlist, not enforce it. (sandboxing)

### Measured here

- `[A]` A `SubagentStart` hook for an `isolation: worktree` subagent received
  `cwd` = `.claude/worktrees/agent-<id>` — the worktree root — and the
  worktree was swept automatically once the cell finished without changes.
  So provisioning at subagent start rides on default creation; no
  `WorktreeCreate` replacement is needed.
- `[A]` `npm ci --ignore-scripts` for `research-mcp` in a fresh worktree of
  this repository: 23 s, 131 MB, 316 resolved packages, warm local cache.
  Both nested lockfiles through `provision.sh`: 62 s. The second run
  returned `current` without installing.
- `[A]` `git rev-parse --git-dir` prints `.git` (relative) from a worktree
  root when called with `-C`; only `--path-format=absolute` makes the memo
  path land in the target's git dir rather than the caller's.

## Sources

- https://www.anthropic.com/engineering/multi-agent-research-system — read in full (2025)
- https://cognition.ai/blog/dont-build-multi-agents — read in full (2025-06-12)
- https://cognition.ai/blog/devin-can-now-manage-devins — read in full (2026-03-19)
- https://code.claude.com/docs/en/hooks — extracted (fetched 2026-09-06)
- https://code.claude.com/docs/en/worktrees — read in full (fetched 2026-09-06)
- https://code.claude.com/docs/en/sub-agents — extracted (fetched 2026-09-06)
- https://code.claude.com/docs/en/sandboxing — read to the organisation section (fetched 2026-09-06)
- https://learn.chatgpt.com/docs/environments/cloud-environment — read in full (fetched 2026-09-06)
- https://learn.chatgpt.com/docs/cloud/internet-access — read in full (fetched 2026-09-06)
- https://developers.openai.com/codex/agent-approvals-security — read in full
- https://github.com/openai/codex-universal — README read in full
- https://cursor.com/docs/cloud-agent/builds — read in full
- https://cursor.com/docs/cloud-agent/setup — read in full
- https://cursor.com/docs/cloud-agent/security-network — read in full
- https://docs.devin.ai/onboard-devin/environment — read in full
- https://docs.devin.ai/cli/sandbox — relayed via search in one pass, fetched in another
- https://jules.google/docs/environment/ — read in full
- https://jules.google/docs/faq/ — read in full
- https://docs.openhands.dev/openhands/usage/architecture/runtime — read in full
- https://arxiv.org/abs/2405.15793 — SWE-agent; abstract and harness section
- https://www.swebench.com/SWE-bench/guides/docker_setup/ — read
- https://turborepo.dev/docs/guides/ai — read
- https://opencode.ai/docs/lsp — relayed via search synthesis
- https://docs.factory.ai/cli/configuration/custom-droids — relayed via search synthesis
