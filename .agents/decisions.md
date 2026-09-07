# Decisions

Settled decisions and what would reopen them. Surfaced at session start by
`session-start.sh` as headings only; open the entry for the why before
proposing the alternative it declined.

One `### <id>` heading per entry (a kebab slug), with one line each for:

- **Decision** — what holds now, including what was declined.
- **Why** — the evidence or constraint that settled it.
- **Reopens when** — the observation that would justify revisiting.

The file describes the present. When a decision changes, rewrite its entry;
never append a second entry for the same question.

### durable-state-in-repository

- **Decision** — The four stores the root `AGENTS.md` names under "Durable state" are the only durable state. Claude Code auto-memory is off (`autoMemoryEnabled: false` in `.agents/claude/settings.json`) and nothing re-enables it per operator. Operator and machine facts go to the gitignored `CLAUDE.local.md` or the user-level `CLAUDE.md` in the host config directory, never to a committed file.
- **Why** — The host store is per-user, per-account, uncommitted, and outside every gate this repository owns. Measured on 2026-09-02: six settled decisions sat in the host store and none in the tree; a satellite's committed snapshot held 14 of 47 live files. A 2026 factorial study of 1,650 Claude Code sessions found no adherence effect from the number of instruction files, so the constraint on stores is that each one is surfaced, not that there are few.
- **Reopens when** — The host offers a repository-local, committed memory path that hooks can gate, or a store here goes a quarter without being read.

### compaction-guidance-in-hook-only

- **Decision** — No always-on prose tells the agent to persist state before context loss, and nothing recommends a fresh session after compaction. The post-compaction restatement lives in `session-start.sh` under `source=compact`, which fires after the summary is in place. Durable stores are written when the fact arises, not at compaction time.
- **Why** — Ruled by the operator on 2026-09-02: the pre-loss sentence competed with the persist-to-completion rule, and the host now carries the summary forward and states that wrapping up early is unnecessary. A hook fires at the moment the guidance matters; prose costs every session.
- **Reopens when** — A compaction is observed to lose a settled decision or deferred item that was known before it and written nowhere.

### knowledge-store-layout

- **Decision** — `.agents/knowledge/` holds dated external observations under `research/` and `transcripts/` behind an index read first. Declined from the spec-driven layout: a six-file template per feature, `changes/` and `archive/`, `constitution/`, `identity/agents/`, `state/backlog/`, and a hook that writes episodic entries.
- **Why** — A fixed schema over variable features guarantees empty headings, which the `market-researcher` skill names as the confabulation trigger. Git owns change history; `AGENTS.md`, `personas/`, and `breadcrumbs.md` cover the rest. Unread accumulating files are the documented failure mode, so nothing writes here unattended.
- **Reopens when** — A drift-detection loop exists that checks a spec against running code, or an entry class appears that the existing stores cannot hold.

### boxed-handoff-dispatch-ledger

- **Decision** — No `.dispatch-ledger` (base SHA, write box, siblings at dispatch). Adopted from the same protocol: four-way finding disposition with a review stop rule, criticality named at plan time with a headline-claim reproduction, and runnable acceptance in every writer report. A workloop lane's `lock_hash` is outside this: it records the environment the lane was installed against, which git does not hold.
- **Why** — Worktree isolation confines writers, the host task system tracks lanes and survives process exits, and git holds base state. A shared-tree writer fan-out is not a working mode here.
- **Reopens when** — Shared-tree writer fan-out becomes a working mode, and the argument first beats worktree isolation.

### board-targeting-github-only

- **Decision** — Board-backed controls read GitHub only. No GitHub-plus-Linear adapter; Linear teams use Linear's native two-way GitHub Issues sync, and Linear stays a human window.
- **Why** — Verbs normalize across boards; event semantics such as auto-close on trunk push do not. Sync limits verified 2026-07: one repository per team link, one workspace per GitHub org, newly created issues only, label fidelity untested.
- **Reopens when** — A control needs an event the Linear sync does not carry, or a second board with matching event semantics.

### stack-packs-carrier

- **Decision** — The carrier model in `.agents/AGENTS.md` (every pack here, subtraction at transplant, `check-stack-packs.py` gating leftovers) stands. `paths:` and `detect:` stay separate frontmatter keys, both with `**/`-prefixed globs; a merged key was declined.
- **Why** — Expo Router and the Next.js App Router both own `app/**/*.tsx`; only a marker file separates them. The gated failure is a pack nobody deleted firing framework rules at a repository without that framework. A root-anchored marker misses `apps/web/next.config.ts` in a monorepo.
- **Reopens when** — A stack arrives with no marker file, or a satellite genuinely runs stacks the markers cannot separate.

### spec-driven-clients-orval

- **Decision** — Orval generates TypeScript clients from OpenAPI. Recorded in `stack-nextjs.md` (generate the client, never hand-write it) and `stack-nestjs.md` (the OpenAPI document is generated from the DTOs, never hand-maintained).
- **Why** — Types and validation rules stay in one place, so a backend change surfaces as a type error rather than a runtime failure.
- **Reopens when** — A stack pack targets a client language Orval does not emit, or the backends publish an OpenAPI version Orval does not read.

### options-over-single-answer

- **Decision** — Agent instructions carry no "give one solution only" rule. A firm recommendation with the live alternatives is the standard.
- **Why** — A single-answer rule conflicts with the Verify-with-user rule and with Workflow step 2, and the operator wants to guide direction rather than receive it.
- **Reopens when** — The operator asks for single answers, or option-heavy responses are observed to delay decisions.

### plugin-absorption-policy

- **Decision** — Skill-type Claude Code plugins are forked into `.agents/skills/` and the plugin is disabled in the repository's `enabledPlugins`. Runtime plugins (MCP and LSP servers) are wired through `enabledPlugins`, and any inline server entry a plugin supersedes is dropped.
- **Why** — A skill can be vendored engine-neutral with one source of truth; a server cannot. The `softaims-boilerplate` marketplace is the operator's own repository, so overlap with scaffold skills is shared ancestry, not duplication to resolve.
- **Reopens when** — A plugin carries state or hooks a fork cannot reproduce, or the host lets a server be vendored.

### publish-guard-denies-where-no-prompt

- **Decision** — `guard-publish` answers "ask" only when the hook payload's `permission_mode` is one the host shows a prompt in (`default`, `acceptEdits`, `plan`) and "deny" for every other value, including a missing one; its failure paths and the adapter's missing-policy path follow the same allowlist. The reason tells the model to stop and report, and tells the user the two ways to approve: switch the mode to default and answer the prompt on rerun, or run the command with the `!` prefix. Declined: trusting the host's "ask" in auto mode, a denylist of known non-prompting modes, and a chat-text approval the hook would parse from the transcript.
- **Why** — Claude Code documents a hook "ask" as flooring at a prompt in auto mode (fixed for unsandboxed Bash in 2.1.211). Observed on 2.1.258, 2026-09-02 and 03: ten `git push` calls in one clearclaim session each drew "ask" from this guard and ran 4 to 17 seconds later with no human answering, and a foreground probe in this repository did the same; a deny in the same session was honored. The `Bash(git push:*)` ask rule never matched, because every push was `git -c … push` inside a compound command. A prompt nobody sees is not approval, and an allowlist fails loud when the host adds or renames a mode, where a denylist fails silent.
- **Reopens when** — A hook "ask" in an auto-mode session is observed to stop the call until a human answers, on a version that documents the fix, or the host offers a way to mark an ask as never classifier-resolvable.

### no-persona-turn-cap

- **Decision** — No persona in `.agents/personas/` sets `maxTurns`; a cell runs until it finishes or its context window ends; when it was dispatched in the background the orchestrator can also stop it through the host task tools, and a blocking dispatch has no stop short of that window. Declined: raising the caps to a higher fixed number, and a per-persona cap sized from a playbook's expected tool count.
- **Why** — Every cap that fired wasted the whole cell. Measured across this repository's and clearclaim's transcripts on 2026-09-03: seven cells stopped at their cap (three `reviewer` at 24 turns here, three at 20 and one at 24 in clearclaim), two of the reviewer cells were mid hostile-review at exactly 24 API turns with 33 and 36 tool calls and returned no report, and the lead re-did the review itself. In the same period 46 uncapped clearclaim cells ran 12 to 218 turns each to finish ordinary implementation and QA work, so no fixed number separates a runaway cell from a working one. The host's own default is no cap, and the caps carried no recorded rationale when added.
- **Reopens when** — A cell is observed looping without progress until its context fills, and the orchestrator's stop was not enough to contain the cost.

### teardown-tiered-by-restart-cost

- **Decision** — `.agents/hooks/policy/teardown-gate.sh` records what a tool call started and blocks the stop when it is due, tiered by how expensive the resource is to restart: a browser page is due at once, a dev server or test watcher at the end of its turn, and a container, compose stack, or build watcher only once a commit lands. The gate never kills anything itself, and an agent may keep a resource past its tier by naming it and why. Declined: killing leftover processes automatically at end of turn, warning without blocking, and one uniform tier for every resource.
- **Why** — Ten Playwright windows survived a single session and held the operator's machine memory until restart, so a warning-only gate is already the observed failure. Automatic killing would take down a server the operator asked to keep and destroys the process before it can be inspected. A uniform tier would tear down a database container after every turn and pay image pulls and migrations to rebuild it, costing more than the memory it frees. A landed commit is the cheapest completion signal a hook can read, and `session-wrap.sh` already measures work that way.
- **Reopens when** — A host reports which context or container a close reached, so clearing can key on process identity instead of on the class; or the commit signal is observed misreading completion in a repository that commits mid-unit.

### verification-placement

- **Decision** — Each writer verifies its own slice inside its own worktree; `post-edit-check.sh` owns lint, format, and typecheck on every edit; `workloop.py integrate` verifies the merged lanes once; `provision.sh` installs from lockfiles after checkout, memoizes the lockfile hash, and refuses to hand over a failed install. Declined: the root agent running every lane's tests, a shared warm typecheck daemon, and isolating single writers by default.
- **Why** — Anthropic, Cognition (after reversing its 2025 essay), Cursor, Codex, and Factory all converge on isolated writers that self-verify, with the parent decomposing and reviewing; test output pulled into the root is the largest token sink in the one context in-session decay is measured against; no first-party harness ships a shared checker and OpenCode's docs recommend against one; a lone sequential writer in the main tree is the linear case with nothing to compose.
- **Reopens when** — A host exposes a verification service that several cells can query cheaper than each running its own suite, or a measured run shows the per-lane install cost exceeding the composition it protects.

### lane-resources-reaped-by-ownership

- **Decision** — What a workloop lane starts in Docker carries `colloid.run` and `colloid.lane` labels or the compose project `<run>-<lane>`; `release-stale`, `teardown`, `reap`, and the lead's digest remove by those labels when the lane ends or its worker is found stopped, automatically, and never touch a resource without them. Scarce shared resources are leased with `add-lane --exclusive`; cheap ones are isolated per lane (a database per lane in one Postgres). Declined: reaping by age, confirming before reaping owned resources, and a container per lane.
- **Why** — Testcontainers reaps by session label the moment the owner's connection drops, and that is the only reaper that has held up under killed processes; age is what a lead falls back on when nothing reads the label, and it removed twenty leaked databases by hand in the transcript that opened this. On this machine two testcontainers sessions with no process left still held containers, and another repository's compose stack sat beside them — ownership is what separates the two. GitLab `resource_group` is the lease shape; Rails' database-per-worker is the isolation shape.
- **Reopens when** — A host reports which container a cell started, so ownership can be recorded without the cell labelling; or a run is observed reaping a labelled resource a live lane still needed.
