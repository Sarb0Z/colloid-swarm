# Agent memory (snapshot)

A point-in-time **copy** of the Claude Code per-project auto-memory, committed so the
notes are versioned and shared. `MEMORY.md` is the index; each `*.md` is one fact.

**Not yet wired.** The live store the harness actually reads/writes is still
`~/.claude/projects/<encoded-project-path>/memory/` on each machine — edits there do
**not** sync here automatically, and edits here do **not** affect the harness. This
is a manual snapshot until we set up the symlink/adapter wiring (canonical
`.agents/memory/` ← per-user symlink), matching how `skills/`, `hooks/`, and
`mcp.json` are shared.

To refresh the snapshot for now: copy `~/.claude/projects/<…>/memory/*.md` here.
