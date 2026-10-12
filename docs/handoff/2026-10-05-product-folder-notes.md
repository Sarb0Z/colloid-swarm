# Plan: product-folder notes

Workflow: Build · Stakes: Critical (a gate hook and a permission grant).

## Ask

The operator, after the parallel-writers gate refused three tax-appeals-app inventory
cells on 2026-10-05:

> there should be a way to avoid these problems
> maybe more granular file controls?

> that specific file was for notetaking
> as you can see from uhh tax-appeals-app, we have a specific pattern for
> worklogs/notetaking in Product folder holding satellites
> so rather than going for the outside repo thing which seems contorted, let's
> just have it freely edit the parent directory in product folders (this can be
> an adaptation that is hardcoded since it seems like a security risk otherwise)

Rulings from the grilling (2026-10-05), recorded as decision
`product-folder-notes` and in `GLOSSARY.md`:

1. The switch lives in the satellite's ignored `.agents/config.json`, never in
   the tracked `policy.json`.
2. The product folder is the repository's parent directory minus every git
   checkout inside it: the repository, its siblings, and their worktrees.
3. A cell that reads and writes notes is dispatched `NOTES-ONLY`, a separate
   marker from `READ-ONLY`. It may write in the product folder only. Where the
   switch is off, the dispatch is refused.
4. `READ-ONLY` becomes strict: a `READ-ONLY` cell's Edit, Write, MultiEdit and
   NotebookEdit calls are refused wherever they point.
5. Claude Code's refusal of a cell's Write to `REPORT*`, `SUMMARY*`,
   `FINDINGS*` or `ANALYSIS*` `.md` files stands; the lead writes those.

The hostile review added one narrowing for the operator to confirm: the
instruction files in the product folder stay outside the grant (Review, P1-1).

## Evidence

- tax-appeals-app session `d2aa0d67` (tax-appeals-web): the Vercel, edge and Bubble
  cells were refused as a second writer at 13:18; every one wrote only under
  `/Users/alice/Projects/tax-appeals-app/off-repo-inventory/`. Relaunched with a
  `READ-ONLY toward both git repositories…` first line, they passed.
- The Webflow cell's Write to `REPORT.md` failed with Claude Code's
  `tengu_subagent_md_report_blocked` check, present in the 2.1.280, 2.1.281 and
  2.1.286 binaries, inside the Write tool only. Not ours to change.
- Probe, Claude Code 2.1.286, headless, `/tmp/pw-probe`:
  - PreToolUse(Agent) carries `tool_use_id` and the prompt.
  - SubagentStart carries `agent_id`, `agent_type`, `prompt_id`, `session_id`,
    `transcript_path` (the main transcript), `cwd`; no dispatch id. The cell's
    `subagents/agent-<agent_id>.meta.json` does not exist yet.
  - PreToolUse(Write) inside the cell carries `agent_id`; by then
    `<dirname(transcript_path)>/<session_id>/subagents/agent-<agent_id>.meta.json`
    exists and its `toolUseId` is the dispatch's `tool_use_id`.
- Hook "allow" skips the permission prompt; deny and ask rules still win
  (code.claude.com/docs/en/permissions, "Extend permissions with hooks"). The
  scaffold sets no Edit or Write permission rules. The repository's own
  knowledge entry lists hook-versus-rule precedence as unverified, so QA checks
  it.
- Claude Code loads `CLAUDE.md` from every ancestor of the working directory:
  `/Users/alice/Projects/tax-appeals-app/CLAUDE.md` links to its `AGENTS.md`, and every
  session in either tax-appeals-app repository reads it.
- Product folders with gated satellites on this machine: tax-appeals-app (2),
  profit-tracker (2), saas-audit (2), field-crm-product (2), mail-platform (1), product-37 (1).
  `colloid-swarm` and `writing-app` sit directly in `~/Projects`.

## Design

### `.agents/hooks/lib/product_folder.py` (new; the grant and the gate call it)

- `root(checkout)`: the product folder, or `None`. `checkout` is the checkout
  that holds the scaffold (the hook's own repository root), never the payload's
  working directory. Reads `hooks.product_folder.enabled` from `config.json`
  alone, the mirror of how `guard-publish` reads `dry_run_commands` from
  `policy.json` alone. Returns `None`, with one stderr line, when the
  checkout's `.git` is a file (a linked worktree, whose parent is not the
  product folder), when the parent does not lie strictly under `$HOME` or
  `$HOME` is unset, or when the parent is itself inside a git checkout.
- `holds(root, path)`: true when the real path lies under `root`, no directory
  from the path's own directory up to (not including) `root` contains `.git`
  (file or directory), and the path is not an instruction surface: a file named
  `AGENTS.md`, `CLAUDE.md`, `CLAUDE.local.md` or `.mcp.json`, or anything under
  a `.agents`, `.claude`, `.codex` or `.kimi` directory. A path that does not
  exist yet resolves through its existing prefix.

### `.agents/hooks/lib/cell_markers.py` (new; the gate's marker bookkeeping)

- `record(project, session, tool_use_id, marker)`: at dispatch, a marked
  prompt's `tool_use_id` and marker go into `.agents/.cell-markers-<session>`,
  cleared by `session-start.sh` with the other gate state.
- `marker_of(project, session, transcript_path, agent_id)`: reads the cell's
  `subagents/agent-<agent_id>.meta.json` and looks its `toolUseId` up in the
  record. Returns `READ-ONLY`, `NOTES-ONLY`, `unmarked` (metadata read, no
  record), or `unknown` (metadata missing or unreadable).

### `.agents/hooks/policy/product-folder.sh` (new): the grant

PreToolUse on `Edit|Write|MultiEdit|NotebookEdit`, every agent. When `root()`
is set, every target is held, and `permission_mode` is not `plan`, it emits
`permissionDecision: "allow"`. Otherwise silent. `normalize-hook.py` maps
`tool_input` and `permission_mode` for it. Inert in every repository without
the switch, so it ships to all satellites unchanged.

### `.agents/hooks/policy/parallel-writers-gate.sh`: the markers

- Dispatch: a prompt opening with `NOTES-ONLY` passes like `READ-ONLY`, records
  the turn without a writer type, and records its marker. With no product
  folder, it is denied: "This repository has no product folder enabled
  (`hooks.product_folder.enabled` in `.agents/config.json`). Dispatch it
  `READ-ONLY` and write the notes yourself, or make it a writer."
  `READ-ONLY` dispatches record their marker too.
- A cell's own `Edit|Write|MultiEdit|NotebookEdit` (a settings entry with
  `--agent subagent`; `normalize-hook.py` adds `transcript_path` for the gate),
  decided in this order:
  1. a reader persona by `agent_type`: no decision;
  2. `READ-ONLY`: removed from the live writers if it registered there, and
     denied;
  3. `NOTES-ONLY`: removed from the live writers if it registered there, and
     denied unless every target is held by the product folder;
  4. `unmarked`: a writer; no decision, as today;
  5. `unknown`: a registered live writer gets no decision and one stderr line;
     any other cell is denied, naming the metadata path. Only marked cells can
     be unregistered non-readers, so the gate fails closed exactly there.
- The second-writer denial names `NOTES-ONLY` beside `READ-ONLY`. The header
  comment describes the events and the markers. The marker lookup lives in the
  library, so the gate stays under 300 lines.

Known limits, stated in the header and the decision:
- A marked cell dispatched in the same turn as a writer of the same type
  registers as a live writer at start, because SubagentStart carries no
  dispatch id. It is removed at its first file-tool call. Until then the lead's
  own checkout edits and a further writer dispatch are refused, which blocks
  more and never allows more.
- Shell writes stay unseen (`colloid-shell-writes-skip-post-edit`).
- Codex and Kimi do not run this gate.

### Wiring and documents

- `.agents/claude/settings.json`: the two PreToolUse entries above.
- `.agents/config.json.example`: `hooks.product_folder.enabled: false`. The
  ownership bullet in `.agents/AGENTS.md` names it as the config-only key beside
  the policy-only `dry_run_commands`; `.agents/README.md`'s config section
  states its boundary.
- `.agents/claude/delegation.md`: `READ-ONLY` writes nothing; `NOTES-ONLY`
  writes notes in the product folder; a cell never writes a `REPORT`,
  `SUMMARY`, `FINDINGS` or `ANALYSIS` `.md` file and returns that content as
  its reply; the product's own conventions name everything else.
- `.agents/debt-log.md`: `gate-reads-cell-metadata`, covering the dependency on
  Claude Code's `subagents/agent-<id>.meta.json` and its `toolUseId`.
- Tests: rows in `.agents/test-parallel-writers.sh` (dispatch with the switch
  on and off; each marker against the checkout, the product folder, a sibling
  repository and `/tmp`; a marked cell demoted from the live writers; unknown
  metadata, registered and not; an unmarked writer untouched). A new
  `.agents/test-product-folder.sh` (allow in the folder; silence in the
  checkout, a sibling, a worktree, an instruction file, plan mode, and with the
  switch off; a linked-worktree checkout, a parent outside `$HOME`, and a
  parent inside a checkout all refused). Both join the `.agents/AGENTS.md`
  verification list and `ci.yml`.

## Options weighed

- Marker enforcement inside the gate, or in a separate policy. Inside: the gate
  owns `.writers-live-<session>`, and a marked cell's demotion edits it.
- Linking a cell to its marker through `meta.json`'s `toolUseId` and a
  dispatch-time record, or through the first record of the cell's transcript.
  `meta.json`: an exact link that does not depend on which record comes first.
  The scaffold's own SubagentStart hooks inject context, and where that lands in
  the cell's transcript is unobserved.

## QA claim

In a fixture product folder holding a satellite with the switch on and the
scaffold's full hook set, a real headless Claude Code session in default
permission mode:
- a `NOTES-ONLY` cell dispatched while a writer cell is live passes the gate and
  writes `<product folder>/worklog/x.md` with no prompt;
- the same cell's Write into the checkout is refused;
- a `READ-ONLY` cell's Write into the product folder is refused, where the gate
  denies and the grant allows on one call;
- the lead's write to `<product folder>/AGENTS.md` is not auto-approved;
- a user-level `deny` rule on a product-folder path still refuses with the
  grant on;
- in plan mode a product-folder write is not auto-approved;
- with the switch off, the `NOTES-ONLY` dispatch is refused and a
  product-folder write is not auto-approved.

Repeat the allow in auto mode if the account offers it.

## Rollout

1. Carrier commits, along seams: the library and the grant with its test; the
   gate's markers with their tests; the documents.
2. Sync the scaffold into `tax-appeals-web` and `tax-appeals-engine`
   by `.agents/export/README.md`. In each one, confirm
   `git check-ignore -q .agents/config.json` before setting the switch.
   tax-appeals-app's `AGENTS.md` commits only when asked, so the satellite changes wait
   for the operator's word.
3. The other eight satellites take it at their next sync, with the same ignore
   check; one breadcrumb.

Size: a few hundred lines with tests.

## Review

Plan review on 2026-10-05: `reviewer` on the frontier model. CONFORMANCE: no.
EFFECTS: none. No `P0`; every finding adopted. None resolves a `P0` or lands in
a subsystem the round did not cover, so the round is complete.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | The grant covers the product folder's own `AGENTS.md` and `CLAUDE.md`, which every session in the sibling repositories loads, so a mistaken or injected note becomes a standing instruction with no prompt | Adopted: instruction surfaces fall outside `holds()`; QA checks a write to `AGENTS.md` |
| 2 | P1 | Reading the marker from the transcript's first record fails open when injected context precedes the prompt, and an unmarked unregistered cell got no decision | Adopted: the marker comes from `meta.json` and a dispatch record; an unregistered non-reader with unknown metadata is denied |
| 3 | P1 | Same-turn, same-type registration leaves marked cells unenforced, which is the motivating pattern | Adopted: the marker is read before registration; a marked cell is removed from the live writers at its first file-tool call |
| 4 | P2 | The product folder derived from a worktree's working directory could be `/tmp` | Adopted: derived from the scaffold's checkout; a linked worktree opens nothing |
| 5 | P2 | Refusing only `/` and home leaves `/Users` or a volume open | Adopted: the parent must lie strictly under `$HOME` |
| 6 | P2 | A satellite whose gitignore lacks `config.json` could track the switch | Adopted: the ignore check in rollout steps 2 and 3 |
| 7 | P2 | QA never tested deny against allow on one call, nor a settings deny rule | Adopted: both in the QA claim |
| 8 | P2 | The config-only key would be stated only in README prose | Adopted: the `.agents/AGENTS.md` ownership bullet |
| 9 | P2 | Cells following tax-appeals-app's naming would hit the report-name refusal | Adopted: `delegation.md` names the four prefixes |

The operator approved this plan on 2026-10-12. The code review changed the
design above: hidden folders and the risky parts (`tools`, `backups`,
`node_modules`, `__pycache__`, script files) are outside the grant, the `holds`
command gave way to `cell_markers.py decide`, and target extraction moved to
`hooks/lib/write_targets.py`. The round, its QA and every disposition are in
`docs/reviews/2026-10-12-product-folder-notes.md`.
