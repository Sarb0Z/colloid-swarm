#!/usr/bin/env bash
# Seams under test, each fired through the host's real adapter and normalizer:
# - Claude Read file_path, Grep path and the Bash, Monitor and PowerShell command -> catches each spelling of a configured env_file (absolute, ~/, $HOME/, ${HOME}/, quoted, doubled slash, dot segment, a symlink to it) and a content Grep or an rg over its folder; misses a path built any other way and a search of $HOME itself.
# - Codex shell command -> catches the same four spellings in command text; misses Read-like tools, which Codex lacks.
# - Kimi Read, Grep and Bash -> catches the same through its normalizer; misses the real Kimi tool names, which the fixture assumes from its session logs.
# - Allowed calls (unrelated file, a listing of the folder holding the file, no names, a config without "proxies") -> catches over-denial; misses a name that merely contains the file name.
# - Broken config and refused scrapling.proxies -> catches a hook that blocks on its own failure; misses a config that loads but is wrong.
# - The sentinel in the env file -> catches any output that quotes or opens the file; misses a leak through a channel this test does not capture.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

dir="$scratch/fixture"
home="$scratch/home"
sentinel="SENTINEL-proxy-password-7c1f"
mkdir -p "$dir/.agents/hooks/policy" "$dir/.agents/hooks/lib" "$dir/.agents/lib" "$dir/.agents/claude" "$dir/.agents/codex" \
  "$dir/.claude/hooks" "$dir/.codex/hooks" "$dir/.kimi/hooks" "$home/.config/colloid"
cp "$repo/.agents/hooks/policy/proxy-file-guard.sh" "$dir/.agents/hooks/policy/"
cp "$repo"/.agents/hooks/lib/{config,write_targets,proxy-file-guard}.py "$dir/.agents/hooks/lib/"
cp "$repo/.agents/lib/proxy.py" "$dir/.agents/lib/"
cp "$repo/.agents/claude/adapter.sh" "$repo/.agents/claude/normalize-hook.py" "$dir/.agents/claude/"
cp "$repo/.agents/codex/normalize-hook.py" "$dir/.agents/codex/"
cp "$repo/.codex/hooks/adapter.sh" "$dir/.codex/hooks/"
cp "$repo/.kimi/hooks/adapter.sh" "$repo/.kimi/hooks/normalize-hook.py" "$dir/.kimi/hooks/"

env_file="$home/.config/colloid/proxies.env"
printf 'OFFICE_PROXY=http://user:%s@proxy.example:8080\n' "$sentinel" > "$env_file"
chmod 600 "$env_file"
printf 'unrelated\n' > "$home/notes.txt"

config="$dir/.agents/config.json"
write_config() { printf '%s\n' "$1" > "$config"; }
named='{"scrapling":{"proxies":{"office":{"env_file":"~/.config/colloid/proxies.env","key":"OFFICE_PROXY"}}}}'
write_config "$named"

rc=0; out=""; err=""
# <host> <payload>: sets rc, out and err; HOME is the fixture's so ~ resolves inside it.
fire() {
  local host="$1" payload="$2"
  local adapter
  case "$host" in
    claude) adapter=("$dir/.agents/claude/adapter.sh" proxy-file-guard.sh) ;;
    codex) adapter=("$dir/.codex/hooks/adapter.sh" proxy-file-guard.sh) ;;
    kimi) adapter=("$dir/.kimi/hooks/adapter.sh" proxy-file-guard.sh) ;;
  esac
  set +e
  out="$(printf '%s' "$payload" | HOME="$home" CLAUDE_PROJECT_DIR="$dir" bash "${adapter[@]}" 2>"$scratch/err")"
  rc=$?
  set -e
  err="$(cat "$scratch/err")"
  if [[ "$out$err" == *"$sentinel"* ]]; then fail "$host: the sentinel reached the output"; fi
}

claude_tool() {  # <tool> <input json>
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","session_id":"s1","tool_name":"%s","tool_input":%s}' "$dir" "$1" "$2"
}
codex_bash() { printf '{"hook_event_name":"PreToolUse","cwd":"%s","session_id":"x1","tool_name":"Bash","tool_input":{"command":"%s"}}' "$dir" "$1"; }

denied() {  # <label> <host> <payload>
  fire "$2" "$3"
  [[ $rc -eq 2 ]] || fail "$1: expected exit 2, got $rc (stderr: $err)"
  [[ "$err" == *"'office'"* && "$err" == *'proxy="office"'* ]] || fail "$1: the denial does not name the proxy: $err"
  ok "$1 denied"
}
allowed() {  # <label> <host> <payload>
  fire "$2" "$3"
  [[ $rc -eq 0 && -z "$out" && -z "$err" ]] || fail "$1: expected a silent allow, got rc=$rc out=$out err=$err"
  ok "$1 allowed"
}

spellings=("$env_file" '~/.config/colloid/proxies.env' '$HOME/.config/colloid/proxies.env' '${HOME}/.config/colloid/proxies.env')
for spelling in "${spellings[@]}"; do
  denied "Claude Read $spelling" claude "$(claude_tool Read "{\"file_path\":\"$spelling\"}")"
  denied "Claude Bash cat $spelling" claude "$(claude_tool Bash "{\"command\":\"cat $spelling | head\"}")"
  denied "Codex shell cat $spelling" codex "$(codex_bash "cat $spelling")"
  denied "Kimi Bash cat $spelling" kimi "$(claude_tool Bash "{\"command\":\"cat $spelling\"}")"
done
denied "Claude Grep path" claude "$(claude_tool Grep "{\"pattern\":\"PROXY\",\"path\":\"$env_file\"}")"
denied "Claude Grep path in ~ form" claude "$(claude_tool Grep '{"pattern":"PROXY","path":"~/.config/colloid/proxies.env"}')"
denied "Kimi Read" kimi "$(claude_tool Read "{\"file_path\":\"$env_file\"}")"
denied "Kimi Grep" kimi "$(claude_tool Grep "{\"pattern\":\"PROXY\",\"path\":\"$env_file\"}")"

# Spellings of the path that the four fixed forms do not match.
bash_denied() {  # <label> <host> <command text>
  denied "$1" "$2" "$(claude_tool Bash "$(jq -nc --arg c "$3" '{command:$c}')")"
}
bash_denied 'Claude Bash cat with a quoted "$HOME"' claude 'cat "$HOME"/.config/colloid/proxies.env'
bash_denied 'Claude Bash cat with ${HOME} and a pipe' claude 'cat ${HOME}/.config/colloid/proxies.env|head'
bash_denied "Claude Bash cat with a doubled slash" claude 'cat ~/.config/colloid//proxies.env'
bash_denied "Claude Bash cat with a dot segment" claude 'cat ~/.config/colloid/./proxies.env'
bash_denied "Claude Bash cat after a semicolon, quoted" claude 'true; cat "$HOME/.config/colloid//proxies.env"'
bash_denied "Claude Bash with an option value" claude 'tool --file=$HOME/.config/colloid/proxies.env'
bash_denied "Claude Bash rg over the folder in ~ form" claude 'rg PROXY ~/.config/colloid'
bash_denied 'Claude Bash grep -r over an ancestor of the folder' claude 'grep -r PROXY "$HOME"/.config'
bash_denied "Claude Bash rg after an assignment" claude 'X=1 rg PROXY ~/.config/colloid'
denied "Claude Monitor cat" claude "$(claude_tool Monitor '{"command":"cat ~/.config/colloid//proxies.env"}')"
denied "Claude PowerShell cat" claude "$(claude_tool PowerShell '{"command":"cat $HOME/.config/colloid//proxies.env"}')"
denied "Kimi Bash cat with a doubled slash" kimi "$(claude_tool Bash '{"command":"cat ~/.config/colloid//proxies.env"}')"
denied "Codex shell rg over the folder" codex "$(codex_bash "rg PROXY ~/.config/colloid")"
denied "Claude Grep content over the folder" claude "$(claude_tool Grep "{\"pattern\":\"x\",\"path\":\"$home/.config/colloid\",\"output_mode\":\"content\"}")"
denied "Claude Grep content over an ancestor of the folder" claude "$(claude_tool Grep "{\"pattern\":\"x\",\"path\":\"$home/.config\",\"output_mode\":\"content\"}")"
denied "Kimi Grep content over the folder" kimi "$(claude_tool Grep '{"pattern":"x","path":"~/.config/colloid","output_mode":"content"}')"
# A link to the env file names it as surely as its path does.
ln -s "$env_file" "$home/link.env"
denied "Claude Read through a symlink" claude "$(claude_tool Read "{\"file_path\":\"$home/link.env\"}")"
denied "Claude Grep path through a symlink" claude "$(claude_tool Grep "{\"pattern\":\"x\",\"path\":\"$home/link.env\"}")"
bash_denied "Claude Bash cat through a symlink" claude 'cat ~/link.env'
denied "Claude Read through a dot-dot path" claude "$(claude_tool Read "{\"file_path\":\"$home/.config/../.config/colloid/proxies.env\"}")"

allowed "Claude Read of an unrelated file" claude "$(claude_tool Read "{\"file_path\":\"$home/notes.txt\"}")"
allowed "Claude Read of the folder holding the file" claude "$(claude_tool Read "{\"file_path\":\"$home/.config/colloid\"}")"
allowed "Claude Grep listing files over the folder holding the file" claude "$(claude_tool Grep "{\"pattern\":\"x\",\"path\":\"$home/.config/colloid\",\"output_mode\":\"files_with_matches\"}")"
allowed "Claude Bash ls of the folder in ~ form" claude "$(claude_tool Bash '{"command":"ls ~/.config/colloid"}')"
allowed "Claude Bash rg in a sibling of the folder" claude "$(claude_tool Bash "{\"command\":\"rg PROXY $home/.config/other\"}")"
allowed "Claude Bash listing the folder" claude "$(claude_tool Bash "{\"command\":\"ls $home/.config/colloid\"}")"
allowed "Codex shell listing the folder" codex "$(codex_bash "ls ~/.config/colloid")"
allowed "Kimi Read of an unrelated file" kimi "$(claude_tool Read "{\"file_path\":\"$home/notes.txt\"}")"

write_config '{"scrapling":{"proxies":{}}}'
allowed "a config with no names" claude "$(claude_tool Read "{\"file_path\":\"$env_file\"}")"
write_config '{"browser":{}}'
allowed "a config without proxies text" claude "$(claude_tool Read "{\"file_path\":\"$env_file\"}")"
rm "$config"
allowed "no config.json" claude "$(claude_tool Read "{\"file_path\":\"$env_file\"}")"

write_config '{"hooks":{"proxy_file_guard":{"enabled":false}},"scrapling":{"proxies":{"office":{"env_file":"~/.config/colloid/proxies.env","key":"OFFICE_PROXY"}}}}'
allowed "the switch off" claude "$(claude_tool Read "{\"file_path\":\"$env_file\"}")"

# A hook that must not block on its own failure: one stderr line, exit 0.
broken() {  # <label> <config text>
  write_config "$2"
  fire claude "$(claude_tool Read "{\"file_path\":\"$env_file\"}")"
  [[ $rc -eq 0 && -z "$out" ]] || fail "$1: expected an allow, got rc=$rc out=$out"
  [[ "$(grep -c . <<<"$err")" -eq 1 && "$err" == proxy-file-guard:* ]] || fail "$1: expected one stderr line, got: $err"
  ok "$1 allowed with one stderr line"
}
broken "a config that is not JSON" '{"scrapling": "proxies" ['
broken "proxies that is a list" '{"scrapling":{"proxies":[]}}'
broken "a proxy entry missing its key" '{"scrapling":{"proxies":{"office":{"env_file":"~/.config/colloid/proxies.env"}}}}'

printf 'PASS: proxy-file-guard policy\n'
