# Colloid Swarm

A portable agent scaffold for Claude Code, Codex, Kimi, and GitHub Copilot.
Canonical instructions, skills, hook policies, personas, and MCP definitions
live under `.agents/`; host directories contain direct links or thin adapters.

This repository also carries an experimental genome layer. Exports remove it.

## Install

Requirements are Bash, Python 3, and Node.js 22+ for the two repository-owned
MCP servers.

```sh
git clone https://github.com/Sarb0Z/colloid-swarm.git
cd colloid-swarm
.agents/export-scaffold.py /tmp/scaffold-kit
```

The exporter reads the current Git commit and refuses a non-empty destination.
Review the kit, then follow `export/README.md` to merge it into a target. It
includes `.agents/`, static `.claude/` and `.codex/` integration, Kimi config,
Copilot links, root instructions, and the transplant guide. Dirty or ignored
local state does not travel.

## Architecture

- `AGENTS.md`: operating contract and delegation policy.
- `.agents/personas/`: Claude-native cached roles; `.claude/agents/` links here.
- `.codex/agents/`: static Codex roles with exact invocation model/effort.
- `.agents/skills/`: reusable, progressively disclosed workflows.
- `.agents/rules/`: scoped codebase and framework guidance.
- `.agents/hooks/`: engine-neutral policies plus host payload adapters.
- `.agents/mcp.json`: server definitions and project on/off state.
- `.agents/playbooks/`: focused review, QA, wrap, and reporting procedures.

Run `python3 .agents/check-layout.py` after changing scaffold inventory. It
checks committed links without generating or pruning files.

## Delegation defaults

| Work | Claude | Codex |
| --- | --- | --- |
| Mechanical or bounded exploration | Haiku | `gpt-5.6-luna` / low |
| Implementation, QA, research | Claude Sonnet 5 | `gpt-5.6-terra` / medium |
| Planning or independent hostile review | Claude Opus 5 | `gpt-5.6-sol` / high |

The cached personas cover common work but do not restrict generic delegation.
The driver chooses the cheapest tier that can solve and verify the task, and
grants only the capabilities that task needs.

## MCP capabilities

The tracked registry directly owns state. Defaults are Context7, Playwright,
and the repository-owned research server; mobile automation, live security
scanning, issue trackers, and keyed search services remain off until requested.

```sh
python3 .agents/mcp.py
python3 .agents/mcp.py enable appium-mcp
python3 .agents/mcp.py disable appium-mcp
```

The command writes `.mcp.json`, `.codex/config.toml`, optional
`.kimi-code/mcp.json`, Claude's enabled-server list, and the reader browser
config. Restart the session after a state change.

| Server | Default | Purpose |
| --- | --- | --- |
| `context7` | on | current library documentation |
| `playwright` | on | browser QA |
| `research-mcp` | on | readable web/PDF research |
| `playwright-reader` | off | browser reading with an installed blocker |
| `appium-mcp` | off | mobile device/simulator QA |
| `security-mcp` | off | authorized live-target scanning |
| `linear`, `atlassian` | off | issue and knowledge systems |
| `greptile`, `exa` | off | keyed external services |

User- and plugin-level host configuration may still add unknown capabilities.
Project records mask only the same server names; this is not a machine-wide
allowlist.

## Hooks

Policies under `.agents/hooks/policy/` receive normalized JSON on stdin. The
active set covers destructive-command refusal, focused post-edit checks,
research/source context, compaction recovery, session start/wrap, and stop
inspection. Host adapters translate payloads; policies own behavior.

Codex hook declarations are hash-trusted. After changing them, review the file
and run:

```sh
python3 .agents/codex/trust-hooks.py "$(pwd)"
```

## Verification

```sh
python3 .agents/check-layout.py
.agents/lint-skills.sh
.agents/test-session-start.sh
python3 .agents/test-guard-destructive.py
python3 .agents/test-guard-publish.py
.agents/test-mcp.sh
.agents/test-codex.sh
.agents/test-export.sh
```

Each repository-owned MCP server also runs `npm run check`. CI runs the static
and focused behavior suites; local `test-codex.sh` additionally proves that the
installed Codex binary loads the project MCP records.

## Deferred work and evidence

- `.agents/breadcrumbs.md`: deferred work, surfaced at SessionStart.
- `.agents/debt-log.md`: standing tradeoffs referenced as `debt: <id>`.
- `.agents/knowledge/`: dated external observations indexed on demand.

## Experimental genome layer

Colloid alone carries `genomes.md`, `.agents/genome.sh`, the mutagen, and the
`panspermia-mutation` skill. The export removes those files, their hooks, config
keys, and links. Run `bash demo/demo.sh` for the offline scaffold demonstration.

## License

No repository-wide license has been selected. The learning-output-style
playbook has its own Apache-2.0 notice under `.agents/licenses/`.
