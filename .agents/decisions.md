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

- **Decision** — No `.dispatch-ledger` (base SHA, write box, siblings at dispatch). Adopted from the same protocol: four-way finding disposition with a review stop rule, criticality named at plan time with a headline-claim reproduction, and runnable acceptance in every writer report.
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
