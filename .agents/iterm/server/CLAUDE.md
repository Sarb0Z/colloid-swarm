# Git identity on this server

`Sarb0z <93070907+Sarb0Z@users.noreply.github.com>` is the server default,
carried by the global `[user]` block in `~/.gitconfig`.

- Each clone under `~/Projects` authors as the identity the Mac's registry
  maps its origin owner to, set per clone with `git config --local`. Do not
  align these back to the default. An owner the registry does not list keeps
  the default.
- Everywhere else the noreply email is universal and only the author name
  varies, so contribution credit lands on the Sarb0Z profile.
- Read `git config user.email` for the identity in force; `gh api user` is not
  a safe source.
- The repositories under `~/apps` belong to running services: their remotes and
  files change only when the operator asks.

GitHub counts a commit toward the contribution graph only when the author
email is tied to the account and the account is a collaborator, org member,
or has a fork, PR, or issue on the repository.

Clones under `~/Projects` reach GitHub over https with `gh auth git-credential`
(`~/.gitconfig-projects` rewrites `git@github.com:` to https). Do not run
`gh auth setup-git`, and do not add a repo-local `credential.helper` line.

# Tools on this server

Prefer these over the POSIX defaults in shell commands.

- **Search:** `rg` over grep, `fd` over find (both skip .gitignored files).
  `jq` for JSON.
- **Python:** **uv**. `uv venv` makes `.venv`, then `uv pip install …`,
  `uv run <cmd>`, `uvx <tool>`. Never `pip install` into the system Python.
- **Prisma:** project-local only: `npx prisma …` (or `bunx prisma …`).
- **Interactive tools, never run them from a tool call:** `lazygit`, `fzf`,
  `nvim`.
