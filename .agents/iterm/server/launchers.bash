# >>> claude account launchers (colloid-swarm .agents/iterm/server) >>>
# setup-server.sh writes this block into openclawops' ~/.bashrc and replaces it on
# each run; edit the copy in colloid-swarm, not this one. Each account keeps its
# own login in its own folder, as on the Mac. ~/.claude stays with the login that
# was already there.
# Every session replaces Claude Code's own system prompt with the colloid-swarm
# clone's curated copy (.agents/claude/system-prompt.md); a missing file falls
# back to the default and says so.
_colloid_prompt() {
  colloid_prompt=()
  local f="$HOME/Projects/colloid-swarm/.agents/claude/system-prompt.md"
  if [[ -f $f ]]; then
    colloid_prompt=(--system-prompt-file "$f")
  else
    echo "claude: $f is missing; this session gets Claude Code's default prompt" >&2
  fi
}
claudew() { _colloid_prompt; CLAUDE_PROFILE=work CLAUDE_CONFIG_DIR="$HOME/.claude-work" command claude "${colloid_prompt[@]}" "$@"; }
claudep() { _colloid_prompt; CLAUDE_PROFILE=personal CLAUDE_CONFIG_DIR="$HOME/.claude-personal" command claude "${colloid_prompt[@]}" "$@"; }
claudef() { _colloid_prompt; CLAUDE_PROFILE=family CLAUDE_CONFIG_DIR="$HOME/.claude-family" command claude "${colloid_prompt[@]}" "$@"; }
claudeg() { _colloid_prompt; CLAUDE_PROFILE=guest CLAUDE_CONFIG_DIR="$HOME/.claude-guest" command claude "${colloid_prompt[@]}" "$@"; }
alias claude-work=claudew claude-personal=claudep claude-family=claudef claude-guest=claudeg

# A bare `claude` must never quietly bill whichever login happens to be default.
claude() {
  case "$1" in
    --version | -v | --help | -h | update | install | doctor)
      command claude "$@"
      return
      ;;
  esac
  printf '%s\n' "claude: pick an account." \
    "  claudew  work      (~/.claude-work)" \
    "  claudep  personal  (~/.claude-personal)" \
    "  claudef  family    (~/.claude-family)" \
    "  claudeg  guest     (~/.claude-guest)" \
    "" \
    "The login already in ~/.claude, once: command claude" >&2
  return 1
}

# The Mac's key, forwarded by et: tmux windows read ~/.ssh/agent.sock (tmux.conf),
# so a login holding a live agent socket of its own points that path at it.
if [[ -S ${SSH_AUTH_SOCK:-} && $SSH_AUTH_SOCK != "$HOME/.ssh/agent.sock" ]]; then
  ln -sfn "$SSH_AUTH_SOCK" "$HOME/.ssh/agent.sock"
fi
# <<< claude account launchers (colloid-swarm .agents/iterm/server) <<<
