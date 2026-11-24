#!/usr/bin/env bash
# Engine-agnostic policy: the workloop controller's lead-only commands are the
# lead's. A cell (a payload carrying agent_id) may not run
#   workloop.py review … --ruling   lifts the review-round cap
#   workloop.py widen               grows a lane's owned paths
#   workloop.py share               declares a path every lane may edit
# Each takes a free-text --agent the controller cannot check, so the hook is
# what keeps a lane's writer from granting itself scope or waiving its review.
#
# Input  (stdin JSON): {"command": "<shell command>", "agent_id": "<a cell's id, empty for the lead>"}
# Output: exit 2 + stderr reason on a refusal; exit 0 otherwise.
#
# The command is read with guard-destructive.py's shell parse: every command of
# a compound line, past environment prefixes, wrappers and `sh -c`. A script
# that runs the controller indirectly gets past it, as the publish guard's push
# detection notes for its own case.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
parser="$repo/.agents/hooks/lib/guard-destructive.py"

if [[ ! -f "$parser" ]]; then
  echo "workloop-authority: $parser is missing; the check cannot run." >&2
  exit 0
fi

exec python3 -c '
import importlib.util, json, re, sys

spec = importlib.util.spec_from_file_location("guard_destructive", sys.argv[1])
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

PYTHON = re.compile(r"python[0-9.]*")
# The controller'"'"'s own options that take a value, before its subcommand.
VALUED = {"--state", "--event-id"}
# The interpreter'"'"'s options that take a separate value (`python3 -X dev`).
PYTHON_VALUED = {"-X", "-W", "--check-hash-based-pycs"}
# Every long option `review` reads, its own and the controller'"'"'s: argparse
# takes any unambiguous prefix of one, so `--rul` is `--ruling`.
REVIEW_LONGS = ("--reference", "--result", "--severity", "--tip", "--ruling", "--message", "--state", "--event-id", "--help")


def controller_args(words):
    """The words after workloop.py, or None when the command runs another program."""
    words = guard.lead(words)
    if words and PYTHON.fullmatch(guard.base(words[0])):
        words = words[1:]
        while words and words[0].startswith("-"):
            words = words[2:] if words[0] in PYTHON_VALUED else words[1:]
    if words and guard.base(words[0]) == "workloop.py":
        return words[1:]
    return None


def names_ruling(word):
    """True when argparse would read the word as --ruling: the option itself or
    an unambiguous prefix of it, with or without =value."""
    name = word.split("=", 1)[0]
    if not name.startswith("--") or len(name) < 3:
        return False
    return [option for option in REVIEW_LONGS if option.startswith(name)] == ["--ruling"]


def refusal(args):
    index = 0
    while index < len(args) and args[index].startswith("-"):
        index += 1 if "=" in args[index] or args[index] not in VALUED else 2
    verb = args[index] if index < len(args) else ""
    rest = args[index + 1:]
    if verb in ("widen", "share"):
        return verb
    if verb == "review" and any(names_ruling(word) for word in rest):
        return "review --ruling"
    return None


try:
    payload = json.loads(sys.stdin.read() or "{}")
except ValueError:
    sys.exit(0)
command = payload.get("command") if isinstance(payload, dict) else None
if not payload.get("agent_id") or not isinstance(command, str):
    sys.exit(0)
for parsed in guard.normalize(command):
    args = controller_args(parsed.words)
    found = refusal(args) if args is not None else None
    if found:
        print(f"workloop.py {found} is the lead'"'"'s: a cell may not widen a lane, share a path, or rule past the "
              "review-round cap. Return to your lead with what you need and why; the lead runs it.", file=sys.stderr)
        sys.exit(2)
sys.exit(0)
' "$parser"
