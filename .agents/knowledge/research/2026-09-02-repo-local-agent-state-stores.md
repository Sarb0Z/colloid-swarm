---
date: 2026-09-02
subject: Repository-local state stores for coding-agent harnesses — file count, decision records, injection versus on-demand, vendor memory
kind: research
source: https://arxiv.org/abs/2605.10039
---

## Scope note

One researcher cell, fifteen sources opened, run to decide whether adding a
fourth durable store (`decisions.md`) to the scaffold was contra-indicated.
The strongest evidence is one controlled study; the decision-record and
vendor-memory questions rest on practitioner write-ups and tool documentation.

## Findings

| Claim | Grade |
|---|---|
| A factorial study of 1,650 Claude Code sessions (16,050 function-level observations) found instruction-file size (25–500 lines), position, split-versus-single-file architecture, and self-contradiction had no detectable effect on rule adherence. The architecture arm directly compared one file, plus `AGENTS.md`, and plus nested per-directory files. The authors flag architecture as underpowered: a null without Bayes-factor support | `[P]` |
| Having any instruction file at all is the dominant lever: 0 of 524 rule-follows with none present versus 67.7% with one | `[P]` |
| The largest driver of non-adherence is task type and session length: 71.3% compliance writing new code versus 45.1% editing, and roughly 5.6% lower odds per additional function generated in a session (exploratory, not pre-registered) | `[P]` |
| An ETH Zurich evaluation on SWE-bench found context files do not generally improve task success and raise inference cost over 20%; repository overview sections were not helpful, non-standard-convention instructions were followed. Its February wording "tend to reduce" was softened in the June revision, and secondary sources still quote the stronger form | `[P]` |
| A mining study of 2,303 agent context files across 1,925 repositories found a median length near 485 words, files edited repeatedly like configuration, and content skewed to test procedure and implementation detail | `[P]` |
| Claude Code auto-memory is an injected index (first 200 lines or 25KB of `MEMORY.md`) plus topic files read on demand; `CLAUDE.md` loads in full with a soft 200-line target the docs do not back with a study | `[P]` |
| Practitioners keep repository-local decision logs wired into `CLAUDE.md` or `AGENTS.md` specifically to stop agents re-proposing rejected approaches | `[S]` |
| A flat, append-only decision log loses coherence past roughly ten entries because nothing links a later entry to the one it supersedes | `[?]` one opinion essay |
| The auto-memory disable toggle has been reported unreliable, and a third-party memory tool silently disabled native memory by writing settings in June 2026 | `[S]` single issue threads |
| Codex CLI reportedly maintains `~/.codex/memory/` loaded at session start; not verified against Codex's own docs, and no such directory exists on the machine measured | `[?]` |
| Obsidian-vault memory tools for Claude Code, Codex, and Gemini CLI load an index at session start and traverse wikilinks on demand; a "262× smaller recall" figure is maintainer self-report | `[?]` |
| A 288-run ablation (Claude Code and Codex, 17 tasks, 3 repositories, July 2026) reportedly found context-injection strategy does not change correctness; the page body could not be retrieved, only a search excerpt | `[?]` |

## What transfers

The measured hazard is not file count. It is a file that is never read, and a
session that runs long. So a store earns its place by being surfaced (an index
line or heading injected at session start, the body opened on demand) and by
staying short at the surfaced layer. A decision record needs a line saying what
would reopen it and a rule against appending a second entry for the same
question, or it drifts into the incoherent flat log the critique describes.

## Could not verify

- Any primary source measuring the effect of the number of distinct
  repository-local state files (queue, tradeoff log, decision record, index)
  as such. The factorial study's architecture arm is the nearest proxy.
- Any measurement of re-proposal rates with and without a decision record.
- Cursor's and Gemini CLI's persistence models against their own docs.

## Sources

- https://arxiv.org/abs/2605.10039 — factorial study of instruction-file structure, May 2026
- https://arxiv.org/abs/2602.11988 — ETH Zurich context-file evaluation, v1 February and v2 June 2026
- https://arxiv.org/abs/2511.12884 — mining study of 2,303 agent context files, revised August 2026
- https://code.claude.com/docs/en/memory — Claude Code memory documentation, fetched 2026-09-02
- https://www.alexdunlop.com/writing/claude-md-best-practices — practitioner synthesis, August 2026
- https://www.developersdigest.tech/blog/context-files-coding-agents-ablation-2026 — ablation claim, excerpt only
- https://github.com/anthropics/claude-code/issues/23544 — auto-memory toggle reliability
- https://github.com/thedotmack/claude-mem/issues/2836 — third-party tool disabling native memory
- https://engincanveske.substack.com/p/decision-log-md-gives-your-ai-sessions-memory — decision-log pattern
- https://volodymyrpavlyshyn.substack.com/p/your-repo-remembers-code-and-forgets — critique of flat decision logs
- https://codex.danielvaughan.com/2026/04/06/codex-cli-persistent-memory-mcp-servers/ — Codex memory, secondary
- https://codex.danielvaughan.com/2026/03/26/agentic-primitives-codex-claude-gemini/ — cross-host comparison, secondary
- https://knightli.com/en/2026/05/19/agentmemory-persistent-memory-ai-coding-agents/ — third-party memory layers
- https://github.com/breferrari/obsidian-mind — vault-based memory tool
- https://github.com/ccf/agentcairn — vault-based memory tool
- https://github.com/mithunyc/obsidian-agent-memory — vault-based memory tool
