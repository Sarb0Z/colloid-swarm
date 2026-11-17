# >>> claude account launchers (colloid-swarm .agents/iterm/server) >>>
# setup-server.sh writes this block into openclawops' ~/.bashrc and replaces it on
# each run; edit the copy in colloid-swarm, not this one. Each account keeps its
# own login in its own folder, as on the Mac. ~/.claude stays with the login that
# was already there.
claudew() { CLAUDE_PROFILE=work CLAUDE_CONFIG_DIR="$HOME/.claude-work" command claude "$@"; }
claudep() { CLAUDE_PROFILE=personal CLAUDE_CONFIG_DIR="$HOME/.claude-personal" command claude "$@"; }
claudef() { CLAUDE_PROFILE=family CLAUDE_CONFIG_DIR="$HOME/.claude-family" command claude "$@"; }
claudeg() { CLAUDE_PROFILE=guest CLAUDE_CONFIG_DIR="$HOME/.claude-guest" command claude "$@"; }
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
