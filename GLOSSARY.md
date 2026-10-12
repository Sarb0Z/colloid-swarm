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
