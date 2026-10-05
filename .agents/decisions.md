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
- **Why** — A single-answer rule conflicts with the Verify-with-user rule and with the Build workflow's plan step, and the operator wants to guide direction rather than receive it.
- **Reopens when** — The operator asks for single answers, or option-heavy responses are observed to delay decisions.

### plugin-absorption-policy

- **Decision** — Skill-type Claude Code plugins are forked into `.agents/skills/` and the plugin is disabled in the repository's `enabledPlugins`. Runtime plugins (MCP and LSP servers) are wired through `enabledPlugins`, and any inline server entry a plugin supersedes is dropped.
- **Why** — A skill can be vendored engine-neutral with one source of truth; a server cannot. The `softaims-boilerplate` marketplace is the operator's own repository, so overlap with scaffold skills is shared ancestry, not duplication to resolve.
- **Reopens when** — A plugin carries state or hooks a fork cannot reproduce, or the host lets a server be vendored.

### mods-where-value-exceeds-portability

- **Decision** — Scaffold behavior moves into a repository-owned Claude Code mod (`.agents/claude/mods/`, planned in `docs/handoff/2026-10-02-claude-code-mods.md`) when the value it gains exceeds the coverage Codex and Kimi lose. Value is a measured failure removed, a shell workaround deleted, or a capability no settings hook has; loss is coverage those engines have today. Irreversible-harm gates (`guard-destructive`, `guard-publish`, `parallel-writers-gate`) keep their settings hook as the floor, and a mod may feed them an input but never turn their deny into allow; mods keep session state only and run existing Python policy by argv rather than porting it. Declined: porting every hook (the stateless and shared ones gain nothing), and keeping Codex and Kimi parity as a constraint on Claude.
- **Why** — Ruled by the operator on 2026-10-02: the work runs mostly on Claude Code. A mod can wait on the person, push into a running subagent and keep state, which the recorded workarounds (dot-file state, transcript re-reads, deny-in-auto-mode) exist to approximate; and the hooks carrying most of those workarounds (`guard-publish`, `provenance-gate`, `workloop-inbox`, `parallel-writers-gate`) are wired only for Claude, so moving them loses no coverage.
- **Reopens when** — Codex or Kimi becomes a primary engine for a satellite, or a Claude Code release removes or breaks a mod API a shipped mod depends on.

### publish-guard-denies-where-no-prompt

- **Decision** — `guard-publish` answers "ask" only when the hook payload's `permission_mode` is one the host shows a prompt in (`default`, `acceptEdits`, `plan`) and "deny" for every other value, including a missing one; its failure paths and the adapter's missing-policy path follow the same allowlist. The reason tells the model to stop and report, and tells the user the two ways to approve: switch the mode to default and answer the prompt on rerun, or run the command with the `!` prefix. Where the `publish-approval` mod (`.agents/claude/mods/publish-approval`) is loaded, a third way reaches the user in every mode: before the call runs, the mod asks the guard by argv whether it would ask, and if so opens Claude Code's question dialog; "Run it" writes `.agents/.publish-approved-<tool_use_id>`, which the guard consumes within 120 seconds and answers "allow" on its ask path only. A dismissal, typed text, a dialog that resolved while the user was idle, or no one to ask leaves the guard's own answer standing; the hosted-write refusal and the failure paths never read a token, a call too long to show whole gets no dialog, and every other hook still decides. Declined: trusting the host's "ask" in auto mode, a denylist of known non-prompting modes, and a chat-text approval the hook would parse from the transcript.
- **Why** — Claude Code documents a hook "ask" as flooring at a prompt in auto mode (fixed for unsandboxed Bash in 2.1.211). Observed on 2.1.258, 2026-09-02 and 03: ten `git push` calls in one clearclaim session each drew "ask" from this guard and ran 4 to 17 seconds later with no human answering, and a foreground probe in this repository did the same; a deny in the same session was honored. The `Bash(git push:*)` ask rule never matched, because every push was `git -c … push` inside a compound command. A prompt nobody sees is not approval, and an allowlist fails loud when the host adds or renames a mode, where a denylist fails silent. A mod's question dialog held a main-thread and a subagent call in an auto-mode session until the person answered (2.1.288, 2026-10-03),. The token is a plain file that a process the model started could forge from the transcript, accepted as debt `publish-token-forgeable` under the guard's honest-mistake threat model.
- **Reopens when** — A hook "ask" in an auto-mode session is observed to stop the call until a human answers, on a version that documents the fix, or the host offers a way to mark an ask as never classifier-resolvable.

### hosted-writes-need-committed-code

- **Decision** — `guard-publish` denies, in every permission mode, a command that runs a script writing to a hosted management API (Vercel, Supabase, GitHub, Railway, Cloudflare and similar) when the script is outside the repository, untracked, or edited since the last commit, and inline interpreter code that does the same; a committed, unchanged script and a hand-typed `curl` write fall through to the ordinary ask. Detection is textual, in `hooks/lib/hosted-scripts.py`: a management host and a write signal in the file the command runs. Declined: asking instead of denying (approval would not make the change reproducible), gating every out-of-checkout script (218 distinct ones ran in September, nearly all local analysis), and payment APIs such as Stripe (an application's runtime calls, not its infrastructure).
- **Why** — On 2026-09-27 a session changed production's database password, Supabase auth and OAuth client, both Vercel projects' settings and 34 variables, and eight GitHub environment secrets from scripts in `/tmp`, loaded by inline Python; nothing in the repository recorded what production should be. The remedy — commit the script as a plan/apply tool — is the agent's own, which is the condition for deny over ask. Replayed over 45,389 September commands: 8 denials (4 that session, 2 runs of a production env-copy tool kept outside any repository, 1 inline Supabase write, 1 inline edit of a file carrying such calls) and 30 asks (committed deploy scripts and hand `curl` writes). A relative script resolves against the session's directory and each `cd` before it; committed means committed in the script's own repository.
- **Reopens when** — A denial is observed on a script that makes no hosted write, beyond an inline edit of a file carrying such calls, or a hosted write from uncommitted code is observed passing through an SDK client or a spawned CLI this detection does not read.

### ssh-remote-read-only-allowlist

- **Decision** — `guard-destructive`'s SSH rule denies every command run over `ssh` unless each clause of it — every segment of a sequence or pipeline, every `bash -c` and `env -S` body, every `find -exec` and `xargs` hand-off, every onward `ssh` hop — is a known read-only tool, listed in `REMOTE_READS` with the test that keeps a call of it a read, and every output redirect, attached to a word or not, lands in a scratch root or device sink. The tests deny a reader in its writing or executing mode: `sed` in place, from a script file, or with `w`/`W`/`e`; `awk` calling `system`, piping, redirecting a print, or loading a program file; git's global `-c`, `--output`, `-O`, `--ext-diff`, and `branch`/`tag`/`remote` beyond listing; `journalctl` vacuum, rotate or `--cursor-file`; `curl` with a method, body, upload or output file; `crontab` beyond `-l`; `ip` beyond show/list/get; `sudo` with no command, which starts a shell. A variable assignment other than `LC_*`, `LANG` or `TZ` denies the clause, since `LD_PRELOAD` or `PAGER` makes a reader run a program. A clause that does not tokenize is denied. `ssh` with no remote command is denied, because a tool call has no terminal and a login shell executes whatever reaches its stdin (a heredoc, a pipe, `<`); so is `-o RemoteCommand`; only `-G`, `-V` and `-O` run without one. A tunnel (`ssh -N -L`) is denied with the rest: it opens a path for local tools to write to the far host. The denial names the clause and points at the deploy path, the `!` prefix, or proposing a list entry to the user. Declined: the denylist of named remote write forms it replaces; a database client such as `psql` on the list, since a `SELECT` can call a function that writes; and allowing a bare `ssh host` as an interactive login, which no tool call can be.
- **Why** — Ruled by the operator on 2026-10-04: under a read-only promise a denylist ships each new write spelling only after a loss teaches it (`service nginx restart`, `pm2 restart`, `chmod`, `ln -sfn` all passed it), while an allowlist fails closed and grows by a reviewed entry. The hostile review of the first allowlist then passed stdin-fed logins, attached redirects (`echo hi>/etc/motd`) and listed readers in exec mode, each reproduced in-process, so each tool's test now names its writing modes. A `RemoteCommand` or `LocalCommand` set in an ssh config file is out of sight and out of scope under the honest-mistake threat model.
- **Reopens when** — A routine remote read is observed denied often enough that the list's maintenance outweighs the losses it prevents, or the host gains a read-only remote execution surface the guard can defer to.

### no-persona-turn-cap

- **Decision** — No persona in `.agents/personas/` sets `maxTurns`; a cell runs until it finishes or its context window ends; when it was dispatched in the background the orchestrator can also stop it through the host task tools, and a blocking dispatch has no stop short of that window. Declined: raising the caps to a higher fixed number, and a per-persona cap sized from a playbook's expected tool count.
- **Why** — Every cap that fired wasted the whole cell. Measured across this repository's and clearclaim's transcripts on 2026-09-03: seven cells stopped at their cap (three `reviewer` at 24 turns here, three at 20 and one at 24 in clearclaim), two of the reviewer cells were mid hostile-review at exactly 24 API turns with 33 and 36 tool calls and returned no report, and the lead re-did the review itself. In the same period 46 uncapped clearclaim cells ran 12 to 218 turns each to finish ordinary implementation and QA work, so no fixed number separates a runaway cell from a working one. The host's own default is no cap, and the caps carried no recorded rationale when added.
- **Reopens when** — A cell is observed looping without progress until its context fills, and the orchestrator's stop was not enough to contain the cost.

### teardown-tiered-by-restart-cost

- **Decision** — `.agents/hooks/policy/teardown-gate.sh` records what a tool call started and blocks the stop when it is due, tiered by how expensive the resource is to restart: a browser page is due at once, a dev server or test watcher at the end of its turn, and a container, compose stack, build watcher, or booted emulator only once a `git push` runs after it started, read with `guard-destructive`'s shell parser so every spelling the guards see counts. Push detection is a heuristic: it misses a push behind a shell alias or inside a script the command runs, and a rejected push still counts. A commit does not make them due, and before a push they ride along on any other block as "tear down before you push or the session ends". The gate never kills anything itself, and an agent may keep a resource past its tier by naming it and why. Declined: killing leftover processes automatically at end of turn, warning without blocking, one uniform tier for every resource, a landed commit as the completion signal, and the end of the session as one.
- **Why** — Ten Playwright windows survived a single session and held the operator's machine memory until restart, so a warning-only gate is already the observed failure. Automatic killing would take down a server the operator asked to keep and destroys the process before it can be inspected. A uniform tier would tear down a database container after every turn and pay image pulls and migrations to rebuild it, costing more than the memory it frees. Ruled by the operator on 2026-10-04: work now lands in per-chunk commits mid-unit, so a commit misread completion, and the done signal is a push or the end of the session. The session's end cannot be a signal: no hook can block at the last Stop, because Stop fires at every turn end with nothing marking the last, and a SessionEnd hook runs once the agent can no longer act — so a push is the only signal the gate reads.
- **Reopens when** — A host reports which context or container a close reached, so clearing can key on process identity instead of on the class; a host marks a session's final Stop; or a repository is observed pushing mid-unit (a draft PR updated per chunk), so a push misreads completion the way a commit did.

### verification-placement

- **Decision** — Each writer verifies its own slice inside its own worktree; `post-edit-check.sh` owns lint, format, and typecheck on every edit; `workloop.py integrate` verifies the merged lanes once; `provision.sh` installs from lockfiles after checkout, memoizes the lockfile hash, and refuses to hand over a failed install. Declined: the root agent running every lane's tests, a shared warm typecheck daemon, and isolating single writers by default.
- **Why** — Anthropic, Cognition (after reversing its 2025 essay), Cursor, Codex, and Factory all converge on isolated writers that self-verify, with the parent decomposing and reviewing; test output pulled into the root is the largest token sink in the one context in-session decay is measured against; no first-party harness ships a shared checker and OpenCode's docs recommend against one; a lone sequential writer in the main tree is the linear case with nothing to compose.
- **Reopens when** — A host exposes a verification service that several cells can query cheaper than each running its own suite, or a measured run shows the per-lane install cost exceeding the composition it protects.

### lane-resources-reaped-by-ownership

- **Decision** — What a workloop lane starts in Docker carries `colloid.run` and `colloid.lane` labels or the compose project `<run>-<lane>`; `release-stale`, `teardown`, `reap`, and the lead's digest remove by those labels when the lane ends or its worker is found stopped, automatically, and never touch a resource without them. Scarce shared resources are leased with `add-lane --exclusive`; cheap ones are isolated per lane (a database per lane in one Postgres). Declined: reaping by age, confirming before reaping owned resources, and a container per lane.
- **Why** — Testcontainers reaps by session label the moment the owner's connection drops, and that is the only reaper that has held up under killed processes; age is what a lead falls back on when nothing reads the label, and it removed twenty leaked databases by hand in the transcript that opened this. On this machine two testcontainers sessions with no process left still held containers, and another repository's compose stack sat beside them — ownership is what separates the two. GitLab `resource_group` is the lease shape; Rails' database-per-worker is the isolation shape.
- **Reopens when** — A host reports which container a cell started, so ownership can be recorded without the cell labelling; or a run is observed reaping a labelled resource a live lane still needed.

### policy-file-beside-config

- **Decision** — A repository states what it decides for everyone who clones it — a hook it runs without, the scripts its publish guard must ask about — in the tracked `.agents/policy.json`; an operator's machine-local taste stays in the ignored `.agents/config.json`, which overrides policy key by key. Same shape, one reader (`hooks/lib/config.py`), and the two guards read through it. While either file exists and does not parse, the publish guard fails safe rather than falling back to an empty script list: it asks (denies where no prompt reaches the user) on every package-manager script run, every interpreter running a repository script, every repository script run by path, and every match of its other rules, naming the broken file; the parse report prints once per hook run. Declined: tracking `config.json` (it was designed to hold local toggles and secrets-adjacent paths), and a `permissions.ask` extension in `.claude/settings.json` (scaffold-owned, overwritten on every sync).
- **Why** — Every mechanism that gated a target's deploy script lived in a file Git ignores, so the gate existed on one machine and read as present everywhere; writing-coach had already committed hook disables into `config.json` because there was nowhere tracked to put them.
- **Reopens when** — A host grows a project-scoped, tracked permission surface that a sync does not overwrite, or a policy key turns out to need per-machine values as often as per-repository ones.

### no-dns-cache-in-research-fetches

- **Decision** — `research-mcp`'s HTTP client resolves every hostname on every redirect hop and pins the connection to the addresses that resolution cleared. It does not memoize lookups, process-wide or otherwise. Declined: career-ops' `providers/_dns-cache.mjs`, whose process-wide `dns.lookup` memo was otherwise a straight latency win worth porting.
- **Why** — Re-resolving per hop plus pinning is what closes the window between checking a name and connecting to it. A cache reopens it: a short-TTL name that answered public when the policy checked it can be connected to after it flips, which is a rebinding path to a link-local or private address, `169.254.169.254` included. The guard is the reason this server may be handed URLs by pages it does not control; a cache trades that for latency the workload does not need, since the per-host interval already dominates.
- **Reopens when** — A measured run shows per-hop resolution dominating fetch latency, and a cache can be keyed so the policy decision is re-derived rather than reused — caching the transport result while still re-authorising, not caching the authorisation.

### status-strip-as-statusline-command

- **Decision** — The status strip is `.agents/claude/statusline.sh`, a committed `statusLine` command in `.agents/claude/settings.json` that the export carries to every satellite, switched by `hooks.status_strip.enabled` like a hook. Switched off, it runs the person's own user `statusLine`, because a project `statusLine` replaces the user's even when it draws nothing. Declined: a Claude Code mod drawing a band above the prompt, which would reach the desktop app and take pushed usage figures but rest on an early-access API; and a carrier-only script that each operator's user settings point at.
- **Why** — Ruled by the operator on 2026-10-03: the script into the scaffold, no mod, in every satellite, with a config switch. The `statusLine` command is documented and stable, project settings override user settings for it, and the probe on 2026-10-03 showed it receives `CLAUDE_PROJECT_DIR` and settings `env` entries. Each refresh costs a shell, `jq`, `python3` for the switch and up to four `git` calls, and `git status` grows with the working tree.
- **Reopens when** — The operator works mainly on a surface that draws no `statusLine`, Claude Code removes or changes the `statusLine` command or stops passing it `CLAUDE_PROJECT_DIR` (the committed command resolves the script through that variable, which the documentation does not promise), or a collaborator-owned satellite objects to receiving the strip.
