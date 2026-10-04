#!/usr/bin/env bash
# Engine-agnostic policy: a resource the agent started must be stopped before
# the work is reported done — sooner for the ones that are cheap to restart.
#
# Two events share one policy because they share one state file:
#   PostToolUse  — a tool call that starts a long-lived resource records it in
#                  .agents/.teardown-pending-<session>; the first such call in a
#                  batch also injects a reminder. A tool call that stops that
#                  CLASS of resource clears its lines.
#   Stop         — a due resource blocks the stop once (exit 2) with the list and
#                  the command that closes each class, then marks itself so later
#                  stops pass until a teardown clears the file or a new resource
#                  re-arms it. Under Claude, SubagentStop maps here too, so a QA
#                  cell must close its browser before it can hand results back;
#                  Codex and Kimi expose no subagent-stop event, so there a
#                  cell's browser is caught by the parent's Stop instead.
#
# The Claude PostToolUse matcher holds characters outside letters and `|`, so
# the host reads it as an unanchored regex rather than a tool-name list, and
# `Bash` also matches `BashOutput`. That is waste, not a defect: a BashOutput
# payload carries no command, so the policy classifies nothing and exits. The
# same trade is documented for guard-destructive.sh.
#
# THE TIERS, set by restart cost rather than by resource type. Tearing down a
# database container after every turn and rebuilding it on the next one costs
# far more than the memory it frees, so it is not asked for until the work is
# actually finished:
#   browser  always     — a page holds a full renderer process and buys nothing
#                         once the screenshot is taken. Re-navigating is free.
#   device   always     — an Appium driver session holds the device, so the next
#                         run against that device cannot start until it ends.
#   server   this turn  — a dev server, an Appium server, a Metro bundler, or a
#   watcher  this turn    test watcher restarts in seconds.
#   docker   on completion — a container, a compose stack, a build watcher, or a
#   build    on completion   booted emulator carries image pulls, migrations,
#   emulator on completion   warm caches, or a minute of boot time. Due once a
#                            commit lands; reported alongside any other block
#                            before that, never blocking alone.
#
# These are heuristics, and the block says so. An agent that still needs a
# resource says which and why in its reply instead of tearing it down.
#
# SCOPE: only resources that do not exit on their own. A backgrounded test run
# or build ends by itself, so recording it would block on a process already
# gone. Foreground commands are never recorded: the tool call did not return
# until they finished.
#
# CLEARING IS BY CLASS, not by process identity. One browser_close clears every
# recorded browser; one `docker compose down` clears every recorded container.
# No host reports which context or container a close reached, so the gate
# guarantees that a teardown was performed, not that nothing survived it. That
# is the same trade ui-gate.sh makes for screenshots, and for the same reason:
# a gate that demands proof no host emits blocks forever and gets ignored.
#
# The user's own long-running process is not this gate's business. It only ever
# records what an agent tool call started inside the session.
#
# Input (stdin JSON): {"project_dir", "event": "PostToolUse"|"Stop",
#   "session_id", "tool_name", "tool_input": {...}, "stop_hook_active": bool}
# Output: PostToolUse — an additionalContext object on the first record, exit 0.
#   Stop — exit 2 + stderr reason on a block, exit 0 otherwise.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib="$repo/.agents/hooks/lib"
enabled="$(python3 "$lib/config.py" "$repo/.agents/config.json" hooks.teardown_gate.enabled=true)"
[[ "$enabled" == "no" ]] && exit 0

# One interpreter for every field plus the whole classification: this runs on
# every Bash and browser call, so a second process would be paid thousands of
# times a session.
read -r -d '' parse <<'PY' || true
import json, re, sys

try:
    p = json.loads(sys.stdin.read() or "{}")
except ValueError:
    p = {}
p = p if isinstance(p, dict) else {}
s = lambda k: v if isinstance((v := p.get(k)), str) else ""
ti = p.get("tool_input")
ti = ti if isinstance(ti, dict) else {}

tool = s("tool_name")
raw_command = ti.get("command") if isinstance(ti.get("command"), str) else ""

# A tool call is not one command. `docker compose down && docker compose up -d`
# closes and then opens, and reading the whole string at once gets that exactly
# backwards. Split it into the clauses a shell would run, classify each, and
# apply the results in order.
SPLIT = re.compile(r"&&|\|\||;|\||\n")
# Escape-aware, so a `\"` inside a double-quoted payload does not end the span
# early and spill the rest of it into the clause stream as if it were code.
QUOTED = r"'(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\""
# A heredoc written `<<'EOF'` is literal: the shell expands nothing in it, and
# it is overwhelmingly a file being written or a fixture fed to a reader. Its
# body is data. An unquoted `<<EOF` is left alone because `bash <<EOF` runs its
# body. The two forms differ in their terminator: only `<<-` permits an indented
# one, so accepting indentation for both would end a heredoc early at an
# indented line that merely looks like the delimiter, and treat the real body
# after it as commands.
HEREDOC_DASH = re.compile(r"<<-\s*(['\"])(\w+)\1.*?^[ \t]*\2[ \t]*$", re.S | re.M)
HEREDOC_PLAIN = re.compile(r"<<\s*(['\"])(\w+)\1.*?^\2[ \t]*$", re.S | re.M)
# A `-c`/`-e` payload for a non-shell interpreter is that language's source, not
# shell. Dropped whole: splitting it on the `;` between two Python statements
# would hand its string literals to the shell classifier.
INTERPRETED = re.compile(
    r"\b(?:python[0-9.]*|node|ruby|perl|php|deno|osascript|awk)\s+(?:-[a-z]*\s+)*-[a-z]*[ce]\b\s*(?:"
    + QUOTED + r")", re.S)
# Command substitution runs, whatever quoting surrounds it: `echo "$(docker
# compose up -d)"` starts a container. Its body becomes a clause of its own.
SUBST = re.compile(r"\$\(([^()]*)\)|`([^`]*)`")
# Prefixes that decorate a command without being one.
NOISE = re.compile(
    r"^(?:do|then|else|elif|\{|!|time|nohup|sudo|command|exec|builtin|env|xargs"
    r"|(?:ba|z|k|d)?sh\s+-[a-z]*c)\s+")
ASSIGNMENT = re.compile(r"^\w+=\S*\s+")
# Words that read or print text rather than run it. This is the rule that makes
# a mention a mention: `grep "docker compose up -d"` names a launch, and the
# verb is what says so — not the quotes around it, which are also how a script
# name gets written in `npm run "dev"`.
MENTION = re.compile(
    r"^(?:echo|printf|cat|bat|grep|egrep|fgrep|rg|ack|sed|awk|jq|yq|head|tail|wc"
    r"|less|more|tee|diff|comm|sort|uniq|tr|cut|pgrep|ps|lsof|pidof|which|type"
    r"|man|touch|mkdir|export|read|declare|local|return)\b")
# A word list is not a command: the launch strings inside a `for` header are
# data until the loop body runs one, and the body is its own clause.
LIST_KEYWORD = re.compile(r"^(?:for|while|until|case|select|function|alias|if)\b")


def clauses(text, depth=0):
    """Every command a shell would actually run.

    Quote CHARACTERS are removed but their contents are kept, because quoting
    the thing being run is ordinary — `npm run "dev"` runs dev. What separates a
    mention from a launch is the verb: a clause led by `echo`, `grep`, or `cat`
    only ever reads or prints its arguments.
    """
    if depth > 3:
        return []
    text = HEREDOC_DASH.sub(" ", text)
    text = HEREDOC_PLAIN.sub(" ", text)
    text = INTERPRETED.sub(" ", text)

    nested = []

    def lift(match):
        nested.extend(clauses(match.group(1) or match.group(2) or "", depth + 1))
        return " "

    text = SUBST.sub(lift, text)
    text = text.replace("'", " ").replace('"', " ")

    out = []
    for part in SPLIT.split(text):
        part = part.strip()
        while True:
            shorter = ASSIGNMENT.sub("", NOISE.sub("", part)).strip()
            if shorter == part:
                break
            part = shorter
        if not part or MENTION.match(part) or LIST_KEYWORD.match(part):
            continue
        out.append(part)
    return out + nested


# Backgrounded means the tool call returned while the process kept running: the
# host's own flag, a tool that only ever runs in the background, or a trailing
# `&` the shell honored. `&&` is a conjunction, not a background operator, and
# the clause split has already consumed it. The whole-command check is what
# carries the `&` in `nohup bash -c "npm run dev" &` down to the unwrapped
# clause, which has no `&` of its own.
always_background = (
    bool(ti.get("run_in_background"))
    or tool == "Monitor"
    or bool(re.search(r"(?<![&>])&\s*$", raw_command))
)

# Resources that outlive the call that started them. Each pattern needs an
# explicit long-lived flag rather than guessing: `vitest` with no --watch runs
# once under a hook's non-TTY stdin and exits, so matching the bare binary would
# block on a process that already ended.
DOCKER_OPEN = re.compile(
    r"\bdocker\s+compose\b.*\bup\b"
    r"|\bdocker-compose\b.*\bup\b"
    # `-d` is often bundled into a combined short flag: `docker run -itd nginx`.
    r"|\bdocker\s+(?:container\s+)?run\b(?=.*\s(?:-[a-z]*d[a-z]*|--detach)\b)"
    r"|\bdocker\s+(?:container\s+)?start\b"
)
DOCKER_CLOSE = re.compile(
    # `docker container stop` is the modern spelling of `docker stop`.
    r"\bdocker(?:-compose|\s+compose)?\s+(?:container\s+)?(?:down|stop|kill|rm)\b"
)
SERVER = re.compile(
    # The package-manager form allows what a monorepo puts between the manager
    # and the script — `yarn workspace web dev`, `pnpm --filter api start`. The
    # guards on both sides keep the script NAME from matching a longer name that
    # merely contains it: `npm run test:dev` and `npm run dev:check` are tasks,
    # not servers, and both are common conventions.
    # The gap cannot cross a redirect or a background operator: without that,
    # `nohup npm test > dev.log 2>&1 &` reads as a dev server because its log
    # file is named dev.
    r"""\b(?:npm|pnpm|yarn|bun)\s[^|;&<>\n]{0,60}?(?<![:\w-])(?:dev|start|serve|preview)(?![:\w-])
      | \bnext\s+(?:dev|start)\b
      | \bvite\b(?!\s+build)
      | \bnest\s+start\b
      | \bexpo\s+start\b
      | \breact-native\s+start\b
      # Appium serves only when it is the command run, bare or as `server`;
      # `npm install -g appium` and its driver, plugin and setup subcommands
      # exit when done.
      | ^(?:(?:npx|bunx|yarn|pnpm\s+exec)\s+(?:-\S+\s+)*)?appium\b
        (?!\s+(?:driver|plugin|setup)\b)(?!\s+-{1,2}(?:v|version|h|help)\b)
      | \b(?:bin/)?rails\s+(?:s|server)\b
      | \bpython[0-9.]*\s+-m\s+http\.server\b
      | \b(?:uvicorn|gunicorn|daphne|hypercorn)\b
      | \bflask\s+run\b
      | \bphp\s+artisan\s+serve\b
      | \b(?:http-server|live-server)\b
      | \bnodemon\b
      | \bdotnet\s+run\b
      | \bspring-boot:run\b
    """,
    re.X,
)
# A build watcher rebuilds artifacts and holds a warm incremental cache, so it
# is worth keeping for the length of the work; a test watcher is re-runnable and
# is not. They are separated only because they fall in different tiers.
BUILD = re.compile(
    r"""\b(?:tsc|webpack|rollup|esbuild|parcel|swc|tsup)\b[^|;]*\s(?:-w|--watch)\b
      | \bturbo\s+watch\b
      | \bvite\s+build\b[^|;]*--watch\b
      | \b(?:next|nuxt)\s+build\b[^|;]*--watch\b
    """,
    re.X,
)
WATCHER = re.compile(r"--watch\b | --watchAll\b | \bwatchexec\b | \bchokidar\b", re.X)
# A booted emulator or simulator costs 30-60 seconds to start, which puts it in
# the same tier as a container: worth keeping while the mobile work runs.
EMULATOR_OPEN = re.compile(
    r"""\bemulator\s+(?:-avd\b|@\w)
      | \bxcrun\s+simctl\s+boot\b
      | \bopen\s+-a\s+Simulator\b
    """,
    re.X,
)
# `adb emu kill` is the documented stop and is reported to fail silently on
# newer adb builds, so the practical forms — killing the qemu process, closing
# the Simulator app — count as a teardown too.
EMULATOR_CLOSE = re.compile(
    # Every form needs an actual termination verb. Matching the process name
    # alone would let `pgrep -f qemu-system-x86_64` — asking whether the
    # emulator is still alive — count as having killed it.
    r"""\badb\b.*\bemu\s+kill\b
      | \bxcrun\s+simctl\s+shutdown\b
      | \b(?:kill|pkill|killall)\b.*\b(?:Simulator|qemu-system-\w+|emulator)\b
    """,
    re.X,
)
# Stopping a process the agent backgrounded. The host's own stop tool is the
# clean path; the shell forms cover the agent that reached for `kill` instead.
PROC_CLOSE = re.compile(
    r"""\b(?:kill|pkill|killall)\b | \bfuser\s+-k\b | \bxargs\s+kill\b
      | \bpm2\s+(?:stop|delete|kill)\b
      | \b(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?stop\b
    """,
    re.X,
)

BROWSER_OPEN = re.compile(r"^mcp__[A-Za-z0-9_-]+__browser_(navigate|tabs)$")
BROWSER_CLOSE = re.compile(r"^mcp__[A-Za-z0-9_-]+__browser_close$")
# The official appium-mcp server (appium/appium-mcp, npm `appium-mcp`) exposes
# no close-shaped tool name at all: one `appium_session_management` tool carries
# create, delete, list, select, attach, and detach in an `action` argument, so
# the action decides the direction. Community forks that publish under other npm
# names do use `start_session`/`end_session`, and matching both costs nothing.
APPIUM_SESSION = re.compile(r"^mcp__[A-Za-z0-9_-]+__appium_session_management$")
APPIUM_OPEN = re.compile(r"^mcp__[A-Za-z0-9_-]+__(start_session|create_session)$")
APPIUM_CLOSE = re.compile(r"^mcp__[A-Za-z0-9_-]+__(end_session|close_session|delete_session|quit_session)$")
# Booting a simulator is the expensive half of preparing a device.
APPIUM_BOOT = re.compile(r"^mcp__[A-Za-z0-9_-]+__(appium_)?prepare_ios_(simulator|real_device)$")
STOP_TOOL = re.compile(r"^(TaskStop|KillShell|KillBash)$")


def label(text, limit=72):
    text = " ".join(text.split())
    return text[: limit - 1] + "…" if len(text) > limit else text


def appium_label(fields, fallback="appium session"):
    """Name the device from the fields the server actually accepts.

    `appium_session_management` takes `capabilities` as a JSON *string* and
    `prepare_ios_simulator` takes `udid`; neither has a top-level `deviceName`,
    so reading one would name every session identically.
    """
    for key in ("udid", "sessionId", "deviceName"):
        value = fields.get(key)
        if isinstance(value, str) and value:
            return label(value)
    caps = fields.get("capabilities")
    if isinstance(caps, str) and caps:
        try:
            caps = json.loads(caps)
        except ValueError:
            caps = {}
    if isinstance(caps, dict):
        for key in ("appium:deviceName", "deviceName", "appium:udid", "platformName"):
            value = caps.get(key)
            if isinstance(value, str) and value:
                return label(value)
    platform = fields.get("platform")
    return label(f"{platform} session") if isinstance(platform, str) and platform else fallback


# One ordered list, not an opens bucket and a closes bucket: the caller replays
# it in the order a shell would have run the clauses, so the last word about a
# class belongs to whichever clause came last.
verdicts = []

if BROWSER_CLOSE.match(tool):
    verdicts.append("-browser")
elif BROWSER_OPEN.match(tool):
    # browser_tabs only opens something when it is asked to; every other action
    # acts on a tab a navigate already recorded.
    if not tool.endswith("browser_tabs") or ti.get("action") == "new":
        url = ti.get("url")
        verdicts.append("+browser\t" + label(url if isinstance(url, str) and url else "browser tab"))
elif APPIUM_SESSION.match(tool):
    action = ti.get("action")
    # `attach` takes hold of a remote session as firmly as `create` opens a new
    # one, and the server's own disconnect cleanup deletes only the sessions it
    # owns — an attached one survives it. Untracked here, nothing would contain
    # it at all. `detach` releases this end without ending that session, so it
    # is deliberately not a teardown; `list` and `select` do neither.
    if action in ("create", "attach"):
        verdicts.append("+device\t" + appium_label(ti))
    elif action == "delete":
        verdicts.append("-device")
elif APPIUM_CLOSE.match(tool):
    verdicts.append("-device")
elif APPIUM_OPEN.match(tool):
    verdicts.append("+device\t" + appium_label(ti))
elif APPIUM_BOOT.match(tool):
    verdicts.append("+emulator\t" + appium_label(ti, "iOS simulator"))
elif STOP_TOOL.match(tool):
    verdicts += ["-server", "-watcher", "-build"]
elif raw_command:
    for clause in clauses(raw_command):
        backgrounded = always_background or bool(re.search(r"(?<![&>])&\s*$", clause))
        if DOCKER_CLOSE.search(clause):
            verdicts.append("-docker")
        elif EMULATOR_CLOSE.search(clause):
            verdicts.append("-emulator")
        elif PROC_CLOSE.search(clause):
            verdicts += ["-server", "-watcher", "-build"]
        elif DOCKER_OPEN.search(clause):
            verdicts.append("+docker\t" + label(clause))
        elif EMULATOR_OPEN.search(clause):
            verdicts.append("+emulator\t" + label(clause))
        elif not backgrounded:
            continue
        elif SERVER.search(clause):
            verdicts.append("+server\t" + label(clause))
        elif BUILD.search(clause):
            verdicts.append("+build\t" + label(clause))
        elif WATCHER.search(clause):
            verdicts.append("+watcher\t" + label(clause))

print(s("project_dir"))
print(s("event"))
print(re.sub(r"[^A-Za-z0-9_-]", "", s("session_id")))
print("yes" if p.get("stop_hook_active") else "no")
print("\n".join(verdicts))
PY
parsed="$(python3 -c "$parse")"
proj="$(printf '%s\n' "$parsed" | sed -n '1p')"
event="$(printf '%s\n' "$parsed" | sed -n '2p')"
session="$(printf '%s\n' "$parsed" | sed -n '3p')"
stop_active="$(printf '%s\n' "$parsed" | sed -n '4p')"
verdicts="$(printf '%s\n' "$parsed" | tail -n +5 | grep . || true)"
[[ -z "$proj" ]] && proj="$repo"

# No session identity means no state to key on; do nothing rather than share one
# file across every session.
[[ -z "$session" ]] && exit 0
pending="$proj/.agents/.teardown-pending-$session"

# The close command for each class, printed with the block so the agent does not
# have to guess which tool ends which resource.
howto() {
  case "$1" in
    browser)       printf 'call browser_close' ;;
    device)        printf 'call appium_session_management with action=delete' ;;
    docker)        printf 'run `docker compose down` (or `docker stop <id>`)' ;;
    emulator)      printf 'run `adb emu kill` (Android) or `xcrun simctl shutdown booted` (iOS)' ;;
    server|watcher|build)
                   printf 'stop the background shell (TaskStop) or kill the process' ;;
    *)             printf 'stop it' ;;
  esac
}
# Tier prose, so the block reads as the heuristic it is rather than a rule.
due_why() {
  case "$1" in
    browser)  printf 'a page holds a renderer process and buys nothing after the screenshot' ;;
    device)   printf 'a driver session holds the device and blocks the next run against it' ;;
    docker)   printf 'due now that a commit landed; it was worth keeping while the work ran' ;;
    build)    printf 'due now that a commit landed; the warm cache was worth keeping until then' ;;
    emulator) printf 'due now that a commit landed; a boot costs a minute, so it was worth keeping' ;;
    *)        printf 'restarts in seconds, so it is not worth holding between turns' ;;
  esac
}

# The commit count is the "work is complete" signal, and it is a COUNT rather
# than a sha for the reason session-wrap.sh gives: a sha merely moves on
# `--amend`, `rebase`, or `checkout`, none of which close a unit of work.
commits="$(git -C "$proj" rev-list --count HEAD 2>/dev/null || true)"
[[ "$commits" =~ ^[0-9]+$ ]] || commits=""

case "$event" in
PostToolUse)
  [[ -z "$verdicts" ]] && exit 0
  mkdir -p "$proj/.agents"

  # Every clear is a read-modify-write of one file, and two tool calls in the
  # same session can be in flight at once. Without this, two concurrent clears
  # each filter the copy they read and the later rename discards the other's
  # work — losing an entry for a class neither of them touched. `mkdir` is the
  # portable atomic test-and-set; `flock` is not on macOS. A lock that cannot be
  # taken is waited on briefly and then ignored: a gate must never hang a tool
  # call, and a lost clear costs one spurious block where a hang costs the turn.
  lock="$pending.lock"
  held="no"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if mkdir "$lock" 2>/dev/null; then held="yes"; break; fi
    # Reap a lock left behind by a killed hook rather than waiting out the loop
    # on every later call.
    [[ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]] && rmdir "$lock" 2>/dev/null
    sleep 0.05
  done
  [[ "$held" == "yes" ]] && trap 'rmdir "$lock" 2>/dev/null || true' EXIT

  first="no"
  [[ -s "$pending" ]] || first="yes"

  # Replayed in the order the shell would have run the clauses, so
  # `docker compose down && docker compose up -d` ends with the new container
  # recorded, and `up -d && down` ends with nothing recorded. Two passes would
  # get one of those two backwards whichever way they were ordered.
  tmp="$pending.$$"
  opened=""
  while IFS= read -r verdict; do
    case "$verdict" in
      -*) kind="${verdict#-}"
          if [[ -f "$pending" ]]; then
            grep -v "^$kind	" "$pending" > "$tmp" 2>/dev/null || true
            mv "$tmp" "$pending"
          fi
          grep -qv '^#' "$pending" 2>/dev/null || rm -f "$pending" ;;
      # kind, the commit count when it was started, then the label. The count
      # makes "a commit has landed since" answerable per resource.
      # `opened` tracks the LAST open in the batch, so the reminder names an
      # entry the pending file actually holds rather than one a later clause in
      # the same command replaced.
      +*) kind="${verdict#+}"; kind="${kind%%	*}"
          printf '%s\t%s\t%s\n' "$kind" "${commits:--}" "${verdict#*	}" >> "$pending"
          opened="$verdict" ;;
    esac
  done <<< "$verdicts"

  # A new resource re-arms the one-shot: the batch the block was spent on is not
  # the batch now outstanding.
  if [[ -n "$opened" && -f "$pending" ]] && grep -qx '#blocked' "$pending"; then
    grep -vx '#blocked' "$pending" > "$tmp" && mv "$tmp" "$pending"
    first="yes"
  fi
  rm -f "$tmp"
  [[ "$held" == "yes" ]] && { trap - EXIT; rmdir "$lock" 2>/dev/null || true; }

  [[ -z "$opened" || "$first" == "no" ]] && exit 0
  kind="${opened#+}"; kind="${kind%%	*}"
  printf '%s' "Started something that keeps running: ${opened#*	}. Tear it down before you report the work done — $(howto "$kind"). Leftover browsers, servers, and containers hold the machine's memory until it is restarted." \
    | python3 "$lib/emit-context.py" PostToolUse
  exit 0
  ;;
Stop)
  find "$proj/.agents" -maxdepth 1 -name '.teardown-pending-*' -mtime +7 -delete 2>/dev/null || true
  [[ -s "$pending" ]] || exit 0
  # A sibling Stop hook may have blocked; the host flag says so. Pass without
  # marking, so the next stop still gets judged on the same resources.
  [[ "$stop_active" == "yes" ]] && exit 0
  if grep -qx '#blocked' "$pending"; then
    exit 0
  fi

  entries="$(grep -v '^#' "$pending" | awk '!seen[$0]++')"
  [[ -n "$entries" ]] || exit 0

  # Split by tier. A `docker` or `build` entry is due only once a commit landed
  # after it started — that is "the work is complete", the cheapest signal a
  # hook can read. Without git there is no signal, so those entries never make a
  # block happen on their own; they ride along on one and stay recorded until
  # they are torn down.
  due=""
  waiting=""
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    kind="${entry%%	*}"
    rest="${entry#*	}"
    started="${rest%%	*}"
    text="${rest#*	}"
    line="  - [$kind] $text"$'\n'"     -> $(howto "$kind")  ($(due_why "$kind"))"
    case "$kind" in
      docker|build|emulator)
        if [[ -n "$commits" && "$started" =~ ^[0-9]+$ ]] && (( commits > started )); then
          due="${due}${line}"$'\n'
        else
          waiting="${waiting}${line}"$'\n'
        fi ;;
      *) due="${due}${line}"$'\n' ;;
    esac
  done <<< "$entries"

  [[ -n "$due" ]] || exit 0
  printf '#blocked\n' >> "$pending"
  {
    printf 'Resources you started this session are still running:\n'
    printf '%s' "$due"
    if [[ -n "$waiting" ]]; then
      printf 'Still useful while the work continues, but tear these down before the session ends:\n'
      printf '%s' "$waiting"
    fi
    printf 'Tear down the ones listed as due, then report the turn done. These are heuristics: if you still need one, keep it and say which and why in your reply. This gate blocks once per batch, until a teardown clears it or a new resource re-arms it.\n'
  } >&2
  exit 2
  ;;
*)
  exit 0
  ;;
esac
