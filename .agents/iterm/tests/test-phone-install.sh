#!/usr/bin/env bash
# Tests for the phone link's install (install.sh, phone/install.py) in a
# temporary HOME, with fake-launchctl in launchctl's place and an empty script
# in signal-cli's. Seam: the files a run leaves and the launchctl calls it
# makes. Catches a key or a hook of another owner lost from settings.json, a
# settings link turned into a file, an entry written twice or left behind, a
# run that changes something under --check or after a refusal, a daemon given
# a TCP port, and an uninstall that takes more than the install put. Misses
# launchd itself and Claude Code reading the entry, which the live checkpoint
# shows.
set -uo pipefail
unset CLAUDE_CONFIG_DIR PHONE_LINK_STATE

IT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fails=$((fails + 1)); }
eq() { # name expected actual
  if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi
}
has() { # name needle text
  if [[ $3 == *"$2"* ]]; then ok "$1"; else bad "$1: no [$2] in [$3]"; fi
}

printf '#!/bin/sh\n' >"$T/signal-cli"
chmod +x "$T/signal-cli"
export PHONE_LINK_LAUNCHCTL=$IT/tests/fake-launchctl PHONE_LINK_SIGNAL_CLI=$T/signal-cli
python=$(command -v python3)
hook_link() { echo "$1/.local/bin/phone-permission.sh"; }
calls() { cat "$FAKE_LAUNCHCTL_STATE/calls" 2>/dev/null | sed "s#gui/$(id -u)#gui/UID#g"; }
changing_calls() { calls | grep -v '^print ' || true; }
tree() { (cd "$1" && find . \( -type f -o -type l \) | LC_ALL=C sort | tr '\n' ' '); }
mode_of() { python3 -c 'import os, stat, sys; print(" ".join(f"{stat.S_IMODE(os.stat(p).st_mode):o}" for p in sys.argv[1:]))' "$@"; }

# A home like the operator's: one settings.json with hooks of other owners, and
# three accounts whose settings.json is a link to it.
new_home() { # folder
  mkdir -p "$1/.claude" "$1/.claude-personal" "$1/.claude-family" "$1/.claude-guest"
  cat >"$1/.claude/settings.json" <<'JSON'
{
  "theme": "dark",
  "env": {
    "DISABLE_TELEMETRY": "1"
  },
  "hooks": {
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "printf \"\\a\" > /dev/tty 2>/dev/null || true"
          }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"/Users/x/.config/iterm2/it2\" handle-agent-hook"
          }
        ]
      }
    ]
  },
  "statusLine": {
    "type": "command",
    "command": "échappé — status"
  },
  "permissions": {
    "allow": [
      "Bash(ls:*)"
    ]
  }
}
JSON
  chmod 640 "$1/.claude/settings.json"
  for account in personal family guest; do ln -s "$1/.claude/settings.json" "$1/.claude-$account/settings.json"; done
}

H=$T/home
new_home "$H"
export FAKE_LAUNCHCTL_STATE=$T/launchd
cp "$H/.claude/settings.json" "$T/original.json"
before=$(tree "$H")

# --- --check on a fresh home -------------------------------------------------
out=$(HOME=$H "$IT/install.sh" --check --zone Europe/Lisbon 2>&1); rc=$?
eq "check: exits 0" 0 "$rc"
eq "check: nothing was made or changed" "$before" "$(tree "$H")"
cmp -s "$T/original.json" "$H/.claude/settings.json" && ok "check: settings.json is untouched" || bad "check: settings.json changed"
eq "check: launchctl was only asked what is loaded" "" "$(changing_calls)"
has "check: names the hook link" "would: linked: $(hook_link "$H") -> $IT/phone/hooks/phone-permission.sh" "$out"
has "check: names the settings file and its accounts" "would: the phone link's hook added to $H/.claude/settings.json (the settings of .claude, .claude-personal, .claude-family, .claude-guest)" "$out"
has "check: names the state folder" "would: state folder made: $H/.local/state/phone-link" "$out"
has "check: names both agents" "would: started: com.colloid.phone-link-signal" "$out"
has "check: names both agents (phone-link)" "would: started: com.colloid.phone-link" "$out"
eq "check: every line is a would or a pane link's" "" "$(grep -v -e '^would: ' <<<"$out")"

# --- install -----------------------------------------------------------------
out=$(HOME=$H "$IT/install.sh" --zone Europe/Lisbon 2>&1); rc=$?
eq "install: exits 0" 0 "$rc"
eq "install: the hook link" "$IT/phone/hooks/phone-permission.sh" "$(readlink "$(hook_link "$H")")"
[[ -x $(hook_link "$H") ]] && ok "install: the hook adapter is executable" || bad "install: the hook adapter is not executable"
for account in personal family guest; do
  eq "install: .claude-$account/settings.json is still a link" "$H/.claude/settings.json" "$(readlink "$H/.claude-$account/settings.json")"
done
[[ ! -L $H/.claude/settings.json ]] && ok "install: the shared settings.json is still a file" || bad "install: settings.json became a link"
eq "install: settings.json keeps its mode" 640 "$(mode_of "$H/.claude/settings.json")"
cmp -s "$T/original.json" "$H/.claude/settings.json.pre-phone-link" && ok "install: the file as it was is kept beside it" || bad "install: no backup of settings.json"
python3 - "$T/original.json" "$H/.claude/settings.json" "$(hook_link "$H")" <<'PY' && ok "install: one entry added, everything else as it was" || bad "install: settings.json"
import json, re, sys
before, after = (json.load(open(path, encoding="utf-8")) for path in sys.argv[1:3])
entry = {"matcher": "^(?!(AskUserQuestion|ExitPlanMode)$).*",
         "hooks": [{"type": "command", "command": sys.argv[3], "timeout": 3600}]}
assert after["hooks"]["PermissionRequest"] == before["hooks"]["PermissionRequest"] + [entry], after["hooks"]["PermissionRequest"]
assert list(after) == list(before), list(after)
assert list(after["hooks"]) == list(before["hooks"]), list(after["hooks"])
after["hooks"]["PermissionRequest"].pop()
assert after == before
# The matcher: every tool except the question tool and plan approval.
matches = lambda name: re.search(entry["matcher"], name) is not None
assert all(matches(name) for name in ("Bash", "Edit", "Write", "NotebookEdit", "WebFetch", "mcp__playwright__browser_click",
                                      "Agent", "AskUserQuestions", "MyExitPlanMode", "ExitPlanModeX"))
assert not matches("AskUserQuestion") and not matches("ExitPlanMode")
PY
grep -q 'échappé — status' "$H/.claude/settings.json" && ok "install: text outside ASCII is written as it was" || bad "install: non-ASCII text was rewritten"
eq "install: the state folder, signal/ and errors.log" "700 700 600" "$(mode_of "$H/.local/state/phone-link" "$H/.local/state/phone-link/signal" "$H/.local/state/phone-link/errors.log")"
agents=$H/Library/LaunchAgents
python3 - "$agents" "$T/signal-cli" "$python" "$IT/phone/phone_link.py" "$H/.local/state/phone-link" <<'PY' && ok "install: the two launchd agents" || bad "install: the launchd agents"
import plistlib, sys
folder, signal_cli, python, service, state = sys.argv[1:]
daemon = plistlib.load(open(f"{folder}/com.colloid.phone-link-signal.plist", "rb"))
assert daemon["ProgramArguments"] == [signal_cli, "daemon", "--socket", f"{state}/signal/socket", "--no-receive-stdout",
                                      "--ignore-attachments", "--ignore-avatars", "--ignore-stickers",
                                      "--ignore-stories"], daemon["ProgramArguments"]
assert not {"--tcp", "--http", "--dbus", "--verbose"} & set(daemon["ProgramArguments"])
assert (daemon["StandardOutPath"], daemon["StandardErrorPath"]) == ("/dev/null", "/dev/null")
assert daemon["Umask"] == 0o077 and daemon["Label"] == "com.colloid.phone-link-signal"
link = plistlib.load(open(f"{folder}/com.colloid.phone-link.plist", "rb"))
assert link["ProgramArguments"] == [python, service, "--zone", "Europe/Lisbon", "--state", state], link["ProgramArguments"]
assert (link["StandardOutPath"], link["StandardErrorPath"]) == ("/dev/null", f"{state}/errors.log")
for agent in (daemon, link):
    assert agent["RunAtLoad"] is True and agent["KeepAlive"] is True
PY
eq "install: signal-cli's agent is started, then phone-link's" \
  "bootstrap gui/UID $agents/com.colloid.phone-link-signal.plist|bootstrap gui/UID $agents/com.colloid.phone-link.plist|" \
  "$(changing_calls | tr '\n' '|')"
has "install: says what it did" "the phone link's hook added to $H/.claude/settings.json" "$out"
has "install: links the pane commands too" "linked: $H/.local/bin/pane-run -> $IT/bin/pane-run" "$out"

# --- a second run changes nothing ----------------------------------------------
cp "$H/.claude/settings.json" "$T/installed.json"
: >"$FAKE_LAUNCHCTL_STATE/calls"
after=$(tree "$H")
out=$(HOME=$H "$IT/install.sh" --zone Europe/Lisbon 2>&1); rc=$?
eq "second run: exits 0" 0 "$rc"
eq "second run: no file was made or removed" "$after" "$(tree "$H")"
cmp -s "$T/installed.json" "$H/.claude/settings.json" && ok "second run: settings.json is byte for byte the same" || bad "second run: settings.json changed"
eq "second run: launchctl was only asked what is loaded" "" "$(changing_calls)"
eq "second run: every line says unchanged" "nothing to change" "$(grep -v '^unchanged: ' <<<"$out")"
has "second run: says how to restart the service after a code change" "launchctl kickstart -k gui/$(id -u)/com.colloid.phone-link)" "$out"

# --- another zone restarts phone-link alone -------------------------------------
out=$(HOME=$H "$IT/install.sh" --zone Asia/Karachi 2>&1); rc=$?
eq "new zone: exits 0" 0 "$rc"
eq "new zone: phone-link is stopped and started, signal-cli is left" \
  "bootout gui/UID/com.colloid.phone-link|bootstrap gui/UID $agents/com.colloid.phone-link.plist|" "$(changing_calls | tr '\n' '|')"
grep -q 'Asia/Karachi' "$agents/com.colloid.phone-link.plist" && ok "new zone: the agent holds it" || bad "new zone: the agent's zone"
out=$(HOME=$H "$IT/install.sh" --zone Mars/Olympus 2>&1); rc=$?
eq "a zone the system does not know: refused" 1 "$rc"
has "a zone the system does not know: named" "--zone 'Mars/Olympus' is not a time zone this system knows" "$out"

# --- an entry of an earlier install is replaced, not doubled ---------------------
python3 - "$H/.claude/settings.json" <<'PY'
import json, sys
settings = json.load(open(sys.argv[1], encoding="utf-8"))
settings["hooks"]["PermissionRequest"][-1]["hooks"][0]["timeout"] = 600
settings["hooks"]["PermissionRequest"][-1]["matcher"] = "Bash"
json.dump(settings, open(sys.argv[1], "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
HOME=$H "$IT/install.sh" --zone Asia/Karachi >/dev/null 2>&1
python3 - "$T/installed.json" "$H/.claude/settings.json" <<'PY' && ok "stale entry: replaced by the one entry of this install" || bad "stale entry"
import json, sys
want, got = (json.load(open(path, encoding="utf-8")) for path in sys.argv[1:3])
assert got == want, got["hooks"]["PermissionRequest"]
PY

# --- uninstall ---------------------------------------------------------------
: >"$FAKE_LAUNCHCTL_STATE/calls"
installed=$(tree "$H")
out=$(HOME=$H "$IT/install.sh" --uninstall --check 2>&1); rc=$?
eq "uninstall --check: exits 0" 0 "$rc"
eq "uninstall --check: nothing was removed" "$installed" "$(tree "$H")"
eq "uninstall --check: launchctl was only asked what is loaded" "" "$(changing_calls)"
has "uninstall --check: names the settings" "would: the phone link's hook removed from $H/.claude/settings.json" "$out"

out=$(HOME=$H "$IT/install.sh" --uninstall 2>&1); rc=$?
eq "uninstall: exits 0" 0 "$rc"
cmp -s "$T/original.json" "$H/.claude/settings.json" && ok "uninstall: settings.json is byte for byte as before the install" || bad "uninstall: settings.json differs from the original: $(diff "$T/original.json" "$H/.claude/settings.json" | head -5)"
eq "uninstall: the accounts' links stay" "$H/.claude/settings.json" "$(readlink "$H/.claude-guest/settings.json")"
[[ ! -e $(hook_link "$H") && ! -L $(hook_link "$H") ]] && ok "uninstall: the hook link is gone" || bad "uninstall: the hook link is still there"
[[ -L $H/.local/bin/pane-run ]] && ok "uninstall: the pane commands stay" || bad "uninstall: a pane command's link was removed"
eq "uninstall: both agents are stopped, phone-link first" \
  "bootout gui/UID/com.colloid.phone-link|bootout gui/UID/com.colloid.phone-link-signal|" "$(changing_calls | tr '\n' '|')"
eq "uninstall: no agent file is left" "" "$(ls "$agents")"
[[ -d $H/.local/state/phone-link && -f $H/.claude/settings.json.pre-phone-link ]] && ok "uninstall: the state folder and the backup stay" || bad "uninstall: removed more than the install put"
out=$(HOME=$H "$IT/install.sh" --uninstall 2>&1); rc=$?
eq "a second uninstall: exits 0 with nothing to change" "0 nothing to change" "$rc $(grep -v '^unchanged: ' <<<"$out")"

# --- accounts with settings of their own, without any, and absent ----------------
H2=$T/home2
mkdir -p "$H2/.claude" "$H2/.claude-personal" "$H2/.claude-family"
printf '{\n  "theme": "light"\n}\n' >"$H2/.claude/settings.json"
printf '{\n  "hooks": {\n    "Stop": []\n  }\n}\n' >"$H2/.claude-personal/settings.json"
export FAKE_LAUNCHCTL_STATE=$T/launchd2
out=$(HOME=$H2 "$IT/install.sh" 2>&1); rc=$?
eq "own settings: exits 0 with this machine's zone" 0 "$rc"
python3 - "$H2" <<'PY' && ok "own settings: each account's file gets the entry, a missing file is made, an absent account is not" || bad "own settings"
import json, os, sys
home = sys.argv[1]
entry = {"matcher": "^(?!(AskUserQuestion|ExitPlanMode)$).*",
         "hooks": [{"type": "command", "command": f"{home}/.local/bin/phone-permission.sh", "timeout": 3600}]}
read = lambda account: json.load(open(f"{home}/{account}/settings.json"))
assert read(".claude") == {"theme": "light", "hooks": {"PermissionRequest": [entry]}}
assert read(".claude-personal") == {"hooks": {"Stop": [], "PermissionRequest": [entry]}}
assert read(".claude-family") == {"hooks": {"PermissionRequest": [entry]}}
assert not os.path.exists(f"{home}/.claude-guest")
assert not os.path.exists(f"{home}/.claude-family/settings.json.pre-phone-link")
PY
HOME=$H2 "$IT/install.sh" --uninstall >/dev/null 2>&1
eq "own settings: uninstall leaves each file without the entry" '{"theme": "light"}|{"hooks": {"Stop": []}}|{}|' \
  "$(for account in .claude .claude-personal .claude-family; do python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))), end="|")' "$H2/$account/settings.json"; done)"

# --- refusals change nothing ---------------------------------------------------
refused() { # name, expected text, home, then the command
  local name=$1 text=$2 home=$3 before out rc
  shift 3
  before=$(tree "$home"; cat "$home"/.claude*/settings.json 2>/dev/null)
  : >"$FAKE_LAUNCHCTL_STATE/calls"
  out=$(HOME="$home" "$@" 2>&1); rc=$?
  eq "$name: exits 1" 1 "$rc"
  has "$name: says why" "$text" "$out"
  eq "$name: nothing changed" "$before" "$(tree "$home"; cat "$home"/.claude*/settings.json 2>/dev/null)"
  eq "$name: no agent was started or stopped" "" "$(changing_calls)"
}
fresh() { rm -rf "$T/r"; new_home "$T/r"; mkdir -p "$T/r/.local/bin"; for f in "$IT"/bin/*; do ln -s "$f" "$T/r/.local/bin/$(basename "$f")"; done; }

fresh
rm "$T/r/.claude-guest/settings.json"
printf '{"theme": "dark",\n' >"$T/r/.claude-guest/settings.json"
refused "settings that are not JSON" "$T/r/.claude-guest/settings.json is not JSON" "$T/r" "$IT/install.sh"

fresh
printf '{"hooks": []}\n' >"$T/r/.claude/settings.json"
refused "hooks that are not an object" "$T/r/.claude/settings.json: \`hooks\` is not an object of lists" "$T/r" "$IT/install.sh"

fresh
echo mine >"$(hook_link "$T/r")"
refused "a file in the hook link's place" "$(hook_link "$T/r") exists and is not a link to" "$T/r" "$IT/install.sh"

fresh
refused "no signal-cli" "signal-cli is not installed (brew install signal-cli)" "$T/r" env PHONE_LINK_SIGNAL_CLI="$T/absent" "$IT/install.sh"

# Without a stand-in the real launchctl would be next: a home that is not the
# user's own is refused before it is reached, so no test can load a real agent.
fresh
refused "a home that is not the user's, with the real launchctl" "launchd agents are the user's" "$T/r" env -u PHONE_LINK_LAUNCHCTL "$IT/install.sh"
refused "the same for an uninstall" "launchd agents are the user's" "$T/r" env -u PHONE_LINK_LAUNCHCTL "$IT/install.sh" --uninstall
refused "the same under --check" "launchd agents are the user's" "$T/r" env -u PHONE_LINK_LAUNCHCTL "$IT/install.sh" --check

out=$(HOME=$H "$IT/install.sh" --bogus 2>&1); rc=$?
eq "an unknown option: usage, exit 2" "2 usage: install.sh [--check] [--uninstall] [--zone <IANA zone>]" "$rc $out"

((fails == 0)) && echo "phone install tests passed" || { echo "$fails failed" >&2; exit 1; }
