#!/usr/bin/env bash
# Firing tests for the product-folder grant: a file edit inside the product
# folder is allowed without a prompt when the repository's config.json turns
# the switch on, and nowhere else. Also covers the library's own refusals.
set -euo pipefail
# A caller such as `git rebase -x` exports these; nothing below reaches a
# repository: the fixtures mark checkouts with a bare .git entry.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
scratch="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

home="$scratch/home"
pf="$home/product"
checkout="$pf/repo"

# A scaffold copy: only what the grant reads.
scaffold() {  # <checkout> <switch: true|false|none>
  [[ -e "$1/.git" ]] || mkdir -p "$1/.git"
  mkdir -p "$1/.agents/hooks/policy" "$1/.agents/hooks/lib" "$1/.agents/claude"
  cp "$repo/.agents/hooks/policy/product-folder.sh" "$1/.agents/hooks/policy/"
  cp "$repo"/.agents/hooks/lib/{product_folder,config,write_targets}.py "$1/.agents/hooks/lib/"
  cp "$repo/.agents/claude/normalize-hook.py" "$1/.agents/claude/"
  rm -f "$1/.agents/config.json"
  [[ "$2" == none ]] || printf '{"hooks":{"product_folder":{"enabled":%s}}}\n' "$2" > "$1/.agents/config.json"
}

mkdir -p "$home" "$pf/notes" "$pf/worklog" "$pf/sibling/.git" "$pf/sibling/src" "$pf/repo-wt" \
  "$pf/.vercel" "$pf/.agents" "$pf/.claude" "$pf/notes/my.git-notes" "$scratch/elsewhere"
scaffold "$checkout" true
mkdir -p "$checkout/src" "$checkout/.claude/worktrees/lane"
printf 'gitdir: %s/.git/worktrees/wt\n' "$checkout" > "$pf/repo-wt/.git"
printf 'gitdir: %s/.git/worktrees/lane\n' "$checkout" > "$checkout/.claude/worktrees/lane/.git"
: > "$pf/AGENTS.md"; : > "$pf/notes/AGENTS.md"
ln -s "$pf/sibling/src" "$pf/notes/into-sibling"
ln -s "$pf/AGENTS.md" "$pf/notes/linked-instructions.md"

policy_of() { printf '%s/.agents/hooks/policy/product-folder.sh' "$1"; }

# grant <tool> <json tool_input> [mode] [checkout] -> sets out, err
grant() {
  local c="${4:-$checkout}"
  out="$(jq -nc --arg tool "$1" --argjson input "$2" --arg mode "${3:-default}" --arg cwd "$pf/notes" \
      '{hook_event_name:"PreToolUse",tool_name:$tool,tool_input:$input,permission_mode:$mode,cwd:$cwd}' |
    env HOME="$home" bash -c "python3 '$c/.agents/claude/normalize-hook.py' product-folder.sh '$c' | '$(policy_of "$c")'" 2>"$scratch/err")" || fail "the policy exited non-zero: $(<"$scratch/err")"
  err="$(<"$scratch/err")"
}
allowed() { [[ "$out" == *'"permissionDecision": "allow"'* ]]; }
write_to() { grant Write "$(jq -nc --arg p "$1" '{file_path:$p,content:"x"}')" "${2:-default}" "${3:-$checkout}"; }

expect_allow() {  # <path> <description>
  write_to "$1"; allowed || fail "$2: not allowed (stdout '$out', stderr '$err')"
}
expect_silent() {  # <path> <description>
  write_to "$1"; [[ -z "$out" ]] || fail "$2: decided anyway ($out)"
}

# the grant: files in the product folder, existing or not
expect_allow "$pf/notes/x.md" "a note in the product folder"
expect_allow "$pf/worklog/new/deeper/2026-10-12.md" "a note in folders that do not exist yet"
expect_allow "$pf/top-level.md" "a note directly in the product folder"
expect_allow "$pf/notes/my.git-notes/x.md" "a name that merely contains .git"
grant MultiEdit "$(jq -nc --arg a "$pf/notes/a.md" --arg b "$pf/worklog/b.md" '{edits:[{file_path:$a},{file_path:$b}]}')"
allowed || fail "a MultiEdit whose every target is held was not allowed"
grant NotebookEdit "$(jq -nc --arg p "$pf/notes/n.ipynb" '{notebook_path:$p}')"
allowed || fail "a notebook in the product folder was not allowed"
grant Write '{"file_path":"rel.md"}'
allowed || fail "a relative path resolved against the working folder (inside the product folder) was not allowed"
ok "files in the product folder are allowed, existing or not, by every write tool"

# what the grant must never open
expect_silent "$checkout/src/x.md" "the checkout"
expect_silent "$checkout/.claude/worktrees/lane/x.md" "a worktree inside the checkout"
expect_silent "$pf/sibling/src/x.md" "a sibling repository"
expect_silent "$pf/repo-wt/x.md" "a sibling worktree"
expect_silent "$pf/notes/into-sibling/x.md" "a symlink into a sibling repository"
expect_silent "$scratch/elsewhere/x.md" "a folder outside the product folder"
expect_silent "/tmp/product-folder-test-x.md" "/tmp"
expect_silent "$pf" "the product folder itself"
ok "checkouts, siblings, worktrees, symlinks out of the folder, and outside folders get no decision"

for path in AGENTS.md CLAUDE.md CLAUDE.local.md notes/AGENTS.md notes/CLAUDE.md notes/deep/CLAUDE.local.md \
            notes/agents.md notes/linked-instructions.md; do
  expect_silent "$pf/$path" "the instruction file $path"
done
ok "the named instruction files are refused at any depth, in any case, and through a symlink"

for path in .vercel/x notes/.env .env .mcp.json .agents/x .claude/settings.json .codex/x .kimi/x .agents/worklog/x.md \
            notes/.cache/deep/x notes/.env.local; do
  expect_silent "$pf/$path" "the hidden path $path"
done
ok "a path with a hidden component is refused anywhere below the product folder"

for path in tools/x.md analysis/tools/y.json backups/a.json node_modules/p/index.json x/__pycache__/m.txt \
            off-repo-inventory/a.py notes/run.SH notes/b.js notes/c.mjs notes/Tools/z.md; do
  expect_silent "$pf/$path" "the risky part $path"
done
for path in off-repo-inventory/a.json off-repo-inventory/b.ts off-repo-inventory/c.body worklog/d.md; do
  expect_allow "$pf/$path" "the note $path"
done
ok "tools, backups, node_modules and __pycache__ folders and .py, .sh, .js and .mjs files are refused at any depth, in any case; other notes are not"

grant MultiEdit "$(jq -nc --arg a "$pf/notes/a.md" --arg b "$pf/notes/.env" '{edits:[{file_path:$a},{file_path:$b}]}')"
[[ -z "$out" ]] || fail "a MultiEdit with one refused target was allowed"
grant Write '{}'
[[ -z "$out" ]] || fail "a call that names no file was allowed"
ok "every target must be held, and at least one must exist"

write_to "$pf/notes/x.md" plan
[[ -z "$out" ]] || fail "plan mode was granted"
write_to "$pf/notes/x.md" acceptEdits; allowed || fail "acceptEdits was not granted"
write_to "$pf/notes/x.md" auto; allowed || fail "auto mode was not granted"
ok "plan mode is never granted"

# the switch
for state in false none; do
  scaffold "$checkout" "$state"
  expect_silent "$pf/notes/x.md" "the switch $state"
  [[ -z "$err" ]] || fail "the switch $state: stderr said '$err'"
done
scaffold "$checkout" none
printf '{"hooks":{"product_folder":{"enabled":true}}}\n' > "$checkout/.agents/policy.json"
expect_silent "$pf/notes/x.md" "a switch set in the tracked policy.json"
ok "the switch lives in config.json alone; off or absent is silent"
scaffold "$checkout" true

# refusals of the product folder itself, each with one stderr line
refused() {  # <description> <checkout> [HOME override]
  out="$(jq -nc --arg p "$home/product/notes/x.md" '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$p},permission_mode:"default",cwd:"/"}' |
    env HOME="${3-$home}" bash -c "python3 '$2/.agents/claude/normalize-hook.py' product-folder.sh '$2' | '$(policy_of "$2")'" 2>"$scratch/err")"
  err="$(<"$scratch/err")"
  [[ -z "$out" ]] || fail "$1: granted ($out)"
  [[ "$(grep -c . <<<"$err")" -eq 1 && "$err" == product_folder.py:* ]] || fail "$1: expected one stderr line, got '$err'"
}
scaffold "$pf/repo-wt" true
refused "a linked worktree as the checkout" "$pf/repo-wt"
scaffold "$scratch/outside/repo" true
refused "a parent outside HOME" "$scratch/outside/repo"
scaffold "$home/direct" true
refused "a parent that is HOME itself" "$home/direct"
refused "HOME unset" "$checkout" ""
mkdir -p "$home/outer/.git"; scaffold "$home/outer/inner/repo" true
refused "a parent inside a git checkout" "$home/outer/inner/repo"
scaffold "$pf/no-git" true; rmdir "$pf/no-git/.git"
refused "a checkout with no .git directory" "$pf/no-git"
[[ "$err" == *"no .git directory"* ]] || fail "a checkout with no .git directory was refused for another reason: $err"
ok "a linked worktree, a folder with no .git directory, a parent outside HOME or equal to it, an unset HOME, and a parent inside a checkout each open nothing and say why"

# the library's commands directly
lib="$checkout/.agents/hooks/lib/product_folder.py"
[[ "$(env HOME="$home" python3 "$lib" root "$checkout")" == "$pf" ]] || fail "root did not print the product folder"
env HOME="$home" python3 "$lib" root "$pf/sibling" 2>/dev/null && fail "root answered for a repository with no switch"
printf 'not json' | env HOME="$home" python3 "$lib" grant "$checkout" 2>"$scratch/err" && fail "grant accepted a payload that is not JSON"
[[ -s "$scratch/err" ]] || fail "a payload that is not JSON was refused silently"
ok "root and grant answer as documented and grant refuses a malformed payload aloud"

printf '\nall product-folder tests passed\n'
