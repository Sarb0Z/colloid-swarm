#!/usr/bin/env bash
# The environment every repository check runs in, for suite.sh and for CI.
#
# Usage: .agents/check-env.sh print HOME_DIR
#        .agents/check-env.sh github
#
# A check runs under a temporary home that holds only a git identity. No
# system, global or inherited git setting reaches it, so neither a credential
# helper nor a runner image's `safe.directory = *` does; git never prompts, and
# no GitHub token is set. Tool caches and uv's Python installs keep their real
# folders, read here before HOME changes, so nothing downloads.
#
# `print` makes HOME_DIR that home and prints one line per setting: `unset NAME`
# for a variable a check must not see, `NAME=VALUE` for one it must. suite.sh
# applies them to its checks.
#
# `github` makes $RUNNER_TEMP/check-home that home and appends the assignments
# to $GITHUB_ENV, so every later step of the job runs as a suite check does. A
# step cannot unset a variable, so one that must be unset and is set fails it.
set -euo pipefail

fail() { printf 'check-env.sh: %s\n' "$*" >&2; exit 1; }

settings() {  # <home>
  local home="$1" dir browsers_default real_default browsers clone
  mkdir -p "$home/.claude" "$home/.codex" || fail "cannot make the temporary home $home"
  home="$(cd "$home" && pwd -P)"
  printf '[user]\n\tname = colloid suite\n\temail = suite@colloid.invalid\n' > "$home/.gitconfig"
  printf 'unset %s\n' GH_TOKEN GITHUB_TOKEN GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_PARAMETERS \
    GIT_CONFIG_COUNT CLAUDE_PROJECT_DIR
  # The XDG folders follow HOME, as they would unset; a runner that sets them
  # cannot unset them for a step.
  printf '%s\n' "HOME=$home" "CLAUDE_CONFIG_DIR=$home/.claude" "CODEX_HOME=$home/.codex" \
    "XDG_CONFIG_HOME=$home/.config" "XDG_CACHE_HOME=$home/.cache" "XDG_DATA_HOME=$home/.local/share" \
    "XDG_STATE_HOME=$home/.local/state" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
  if command -v uv >/dev/null; then
    dir="$(uv cache dir)" || fail "uv cache dir failed"
    printf 'UV_CACHE_DIR=%s\n' "$dir"
    dir="$(uv python dir)" || fail "uv python dir failed"
    printf 'UV_PYTHON_INSTALL_DIR=%s\n' "$dir"
  fi
  if command -v npm >/dev/null; then
    dir="$(npm config get cache)" || fail "npm config get cache failed"
    printf 'npm_config_cache=%s\n' "$dir"
  fi
  # Playwright's browsers are cloned to their default place in the temporary
  # home, because the Scrapling server drops every PLAYWRIGHT_ variable and
  # finds them under HOME; on APFS the clone shares the files' blocks and costs
  # no copy.
  case "$(uname -s)" in
    Darwin) browsers_default="Library/Caches/ms-playwright"; real_default="$HOME/$browsers_default"; clone=(cp -cR) ;;
    *) browsers_default=".cache/ms-playwright"; real_default="${XDG_CACHE_HOME:-$HOME/.cache}/ms-playwright"
       clone=(cp -R --reflink=auto) ;;
  esac
  browsers="${PLAYWRIGHT_BROWSERS_PATH:-$real_default}"
  if [[ "$browsers" != 0 && -d "$browsers" ]]; then
    { mkdir -p "$(dirname "$home/$browsers_default")" && "${clone[@]}" "$browsers" "$home/$browsers_default"; } \
      || fail "cannot copy Playwright's browsers from $browsers"
    printf 'PLAYWRIGHT_BROWSERS_PATH=%s\n' "$home/$browsers_default"
  fi
}

case "${1:-}" in
  print)
    [[ $# -eq 2 ]] || fail "usage: check-env.sh print HOME_DIR"
    settings "$2"
    ;;
  github)
    [[ -n "${GITHUB_ENV:-}" && -n "${RUNNER_TEMP:-}" ]] || fail "github needs GITHUB_ENV and RUNNER_TEMP, set by GitHub Actions"
    lines="$(settings "$RUNNER_TEMP/check-home")"
    while IFS= read -r setting; do
      case "$setting" in
        "unset "*)
          name="${setting#unset }"
          [[ -z "${!name+set}" ]] || fail "$name is set, and a check must run without it; remove it from the workflow"
          ;;
        *) printf '%s\n' "$setting" >> "$GITHUB_ENV" ;;
      esac
    done <<<"$lines"
    ;;
  *) fail "usage: check-env.sh print HOME_DIR | check-env.sh github" ;;
esac
