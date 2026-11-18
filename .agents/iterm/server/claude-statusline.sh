#!/bin/bash
# Claude Code status line — two rows, TokyoNight colours, Nerd Font icons.
#
#   ● PERSONAL   claims-app   mvp/roadmap ●3 ↑2   +156 −23   #41 ✓   session name  󰔛 1h12m
#   Fable 5.1 ⚡ high 󰧑  ━━━━┄┄┄┄┄┄ 367K/1M  5h 42% ↻2h10m  7d 18%  style:colloid
#
# Takes no arguments. Runs on the Linux server (bash, jq, git, awk); the account
# is named only by profile, never by email.

input=$(cat)

# ── one jq pass for everything ─────────────────────────────────────────────
eval "$(echo "$input" | jq -r '
  def s(v): (v // "" | tostring);
  "transcript=\(s(.transcript_path)|@sh)",
  "cwd=\(s(.workspace.current_dir)|@sh)",
  "model=\(s(.model.display_name)|@sh)",
  "effort=\(s(.effort.level)|@sh)",
  "thinking=\(s(.thinking.enabled)|@sh)",
  "fast=\(s(.fast_mode)|@sh)",
  "pct=\(s(.context_window.used_percentage)|@sh)",
  "ctx_size=\(s(.context_window.context_window_size)|@sh)",
  "ctx_used=\(((.context_window.current_usage // {}) | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)))|tostring|@sh)",
  "h5=\(s(.rate_limits.five_hour.used_percentage)|@sh)",
  "h5_reset=\(s(.rate_limits.five_hour.resets_at)|@sh)",
  "d7=\(s(.rate_limits.seven_day.used_percentage)|@sh)",
  "cost=\(s(.cost.total_cost_usd)|@sh)",
  "dur=\(s(.cost.total_duration_ms)|@sh)",
  "added=\(s(.cost.total_lines_added)|@sh)",
  "removed=\(s(.cost.total_lines_removed)|@sh)",
  "pr_num=\(s(.pr.number)|@sh)",
  "pr_state=\(s(.pr.review_state)|@sh)",
  "wt=\(s(.workspace.git_worktree // .worktree.name)|@sh)",
  "sname=\(s(.session_name)|@sh)",
  "style=\(s(.output_style.name)|@sh)",
  "vim=\(s(.vim.mode)|@sh)"
' 2>/dev/null)"

# ── colours (TokyoNight Night) ─────────────────────────────────────────────
R='\033[0m'; B='\033[1m'
c() { printf '\033[38;2;%sm' "$1"; }
FG=$(c '192;202;245'); DIM=$(c '86;95;137'); BLUE=$(c '122;162;247'); CYAN=$(c '125;207;255')
MAG=$(c '187;154;247'); GREEN=$(c '158;206;106'); YEL=$(c '224;175;104'); ORANGE=$(c '255;158;100'); RED=$(c '247;118;142')
SEP="${DIM}  ${R}"

# ── profile ────────────────────────────────────────────────────────────────
# The launchers (launchers.bash) set CLAUDE_PROFILE; a session started another
# way is named by the account folder its transcript sits in.
profile=${CLAUDE_PROFILE:-}
case "$profile" in
  work|personal|family|guest) ;;
  *) case "$transcript" in
       "$HOME"/.claude-work/*)     profile=work ;;
       "$HOME"/.claude-personal/*) profile=personal ;;
       "$HOME"/.claude-family/*)   profile=family ;;
       "$HOME"/.claude-guest/*)    profile=guest ;;
       *)                          profile=unknown ;;
     esac ;;
esac
case "$profile" in
  work)     label=work;     acct="$YEL" ;;
  personal) label=personal; acct="$MAG" ;;
  family)   label=family;   acct="$GREEN" ;;
  guest)    label=guest;    acct="$BLUE" ;;
  *)        label=unknown;  acct="$CYAN" ;;
esac

# ── row 1: profile · project · git · PR · worktree · session ───────────────
printf "${acct}${B}● %s${R}" "$(echo "$label" | tr '[:lower:]' '[:upper:]')"

if [ -n "$cwd" ]; then
  cd "$cwd" 2>/dev/null || true
  printf "${SEP}${GREEN} %s${R}" "$(basename "$cwd")"
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    branch=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
    dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    read -r behind ahead < <(git rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null || echo "0 0")
    printf " ${MAG} %s${R}" "$branch"
    [ "$dirty" != 0 ]  && printf " ${YEL}●%s${R}" "$dirty"
    [ "${ahead:-0}" != 0 ]  && printf " ${CYAN}↑%s${R}" "$ahead"
    [ "${behind:-0}" != 0 ] && printf " ${ORANGE}↓%s${R}" "$behind"
  fi
fi
if [ "${added:-0}" != 0 ] || [ "${removed:-0}" != 0 ]; then
  printf "  ${DIM}${R} ${GREEN}+%s${R} ${RED}−%s${R}" "${added:-0}" "${removed:-0}"
fi
if [ -n "$pr_num" ]; then
  case "$pr_state" in
    approved)          pr_c="$GREEN"; pr_i="✓" ;;
    changes_requested) pr_c="$RED";   pr_i="✗" ;;
    draft)             pr_c="$DIM";   pr_i="◌" ;;
    *)                 pr_c="$BLUE";  pr_i="○" ;;
  esac
  printf "${SEP}${pr_c} #%s %s${R}" "$pr_num" "$pr_i"
fi
[ -n "$wt" ]    && printf "${SEP}${CYAN} %s${R}" "$wt"
[ -n "$sname" ] && printf "${SEP}${DIM}%s${R}" "$sname"
if [ -n "$dur" ] && [ "${dur%.*}" -gt 0 ]; then
  m=$(( ${dur%.*} / 60000 ))
  if [ $m -ge 60 ]; then printf "${SEP}${DIM}󰔛 %dh%02dm${R}" $((m/60)) $((m%60)); else printf "${SEP}${DIM}󰔛 %dm${R}" $m; fi
fi
[ -n "$vim" ]   && printf "${SEP}${BLUE}${B}%s${R}" "$vim"
printf '\n'

# ── row 2: model · effort · context · limits · cost · time · lines ─────────
printf "${FG}${B}%s${R}" "${model:-?}"
[ -n "$effort" ]         && printf " ${DIM}⚡${R} ${FG}%s${R}" "$effort"
[ "$thinking" = true ]   && printf " ${MAG}󰧑${R}"
[ "$fast" = true ]       && printf " ${ORANGE}󱐋fast${R}"

# context bar, coloured by fullness
if [ -n "$pct" ]; then
  p=${pct%.*}; width=10; filled=$(( p * width / 100 )); [ $filled -gt $width ] && filled=$width
  if   [ $p -ge 85 ]; then bc="$RED"; elif [ $p -ge 60 ]; then bc="$ORANGE"; else bc="$GREEN"; fi
  bar=""; for ((i=0;i<width;i++)); do if [ $i -lt $filled ]; then bar+="━"; else bar+="┄"; fi; done
  k() { local n=${1%.*}; if [ "$n" -ge 1000000 ]; then printf '%d.%dM' $(( n / 1000000 )) $(( n % 1000000 / 100000 )); else printf '%dK' $(( n / 1000 )); fi; }
  printf "${SEP}${bc}%s${R} ${bc}%s${R}${DIM}/%s${R}" "$bar" "$(k "${ctx_used:-0}")" "$(k "${ctx_size:-200000}")"
fi

# rate limits (Max plans): small bars; the number appears only once it matters
lim() { # $1 label  $2 pct  $3 reset-in
  local n=${2%.*} col
  if [ $n -ge 90 ]; then col="$RED"; elif [ $n -ge 70 ]; then col="$ORANGE"; else col="$FG"; fi
  printf "${SEP}${DIM}%s${R} ${col}%s%%${R}" "$1" "$n"
  [ -n "$3" ] && printf " ${DIM}↻%s${R}" "$3"
}
if [ -n "$h5" ]; then
  left=""
  if [ -n "$h5_reset" ]; then
    secs=$(( ${h5_reset%.*} - $(date +%s) )); [ $secs -lt 0 ] && secs=0
    left=$(printf '%dh%02dm' $((secs/3600)) $(((secs%3600)/60)))
  fi
  lim "5h" "$h5" "$left"
fi
[ -n "$d7" ] && lim "7d" "$d7" ""

[ -n "$style" ] && [ "$style" != default ] && printf "${SEP}${DIM}style:%s${R}" "$style"
printf '\n'
