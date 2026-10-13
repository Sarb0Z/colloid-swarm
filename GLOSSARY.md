# Agent scaffold

The vocabulary of the agent harness this repository carries and exports to the product repositories that adopt it.

## Language

**Product folder**:
The directory that holds one product's repositories side by side, together with that product's notes. It is not itself a repository. Agents may edit it without a prompt only where the repository's ignored `config.json` turns the grant on, and never in a checkout, a hidden folder or file below it, an `AGENTS.md`, `CLAUDE.md` or `CLAUDE.local.md`, or a risky part: a `tools`, `backups`, `node_modules` or `__pycache__` folder, or a `.py`, `.sh`, `.js` or `.mjs` file. The risky parts are a deny-list: a new risky folder is open until it is added.
_Avoid_: workspace, parent directory, product root

**Notes**:
The untracked working documents a product folder keeps outside every repository: worklogs, specs, plans, findings, and the raw data behind them. They are kept, not disposable. They live in visible folders: a hidden folder holds tool and account state, not notes.
_Avoid_: scratch, artifacts

**Launch folder**:
The folder an agent session was started or resumed from. It can differ from the folder the session is working in.
_Avoid_: project root, project directory

## Delegation

**Cell**:
An agent the lead dispatches for one bounded task, with its own brief, model and tools.
_Avoid_: worker, helper, child agent

**Delegation shape**:
How the lead divides one objective among cells: one writer, parallel slices, a contract-first split, a read-only fan-out, a bake-off, or a mix of these.
_Avoid_: strategy, topology, pattern

**Run**:
One multi-cell delegation toward one objective, kept from its plan to its verified result: every cell the lead dispatches for it, writers and read-only cells alike.
_Avoid_: job, batch, swarm

**Lane**:
One writer's share of a run: the paths it owns, its commits and its review. A lone writer works in the main tree; writers working at once get a branch and a worktree each.
_Avoid_: track, stream, slot

**Contract**:
The written interface between a lane that produces data or an API and a lane that consumes it, such as types, a schema or sample data, fixed before both build against it.
_Avoid_: spec, agreement, handshake

**Bake-off**:
A delegation shape in which several cells attempt the same task and the lead keeps one. Every attempt is paid for in full.
_Avoid_: race, tournament, competition

**Read-only cell**:
A cell that writes nothing, such as a research, review or QA cell. Its run tracks it until it returns.
_Avoid_: reader lane, observer

**Shared file**:
A file several lanes need to change and none owns: a manifest, a lockfile, generated code, an index. Lanes' edits to a manifest or an index are merged; a lockfile or a generated file is rebuilt after the merge, never merged.
_Avoid_: common file, global file
