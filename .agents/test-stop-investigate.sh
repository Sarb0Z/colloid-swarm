#!/usr/bin/env bash
# Firing tests for the stop-investigate hedge gate. The load-bearing case is the
# split between giving up and asking: AGENTS.md § "Verify with user" mandates
# escalating when the blocker is the user's, and that escalation is
# word-identical to a punt. A recommendation is what tells them apart.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

# The policy resolves its repository from its own location and reads that
# repository's .agents/config.json, which can turn the gate off. Run a copy from
# a sandbox with the gate explicitly on, so these cases assert what the policy
# does rather than how the surrounding repository is configured.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/.agents/hooks/policy" "$scratch/.agents/hooks/lib"
cp "$repo/.agents/hooks/policy/stop-investigate.sh" "$scratch/.agents/hooks/policy/"
cp "$repo"/.agents/hooks/lib/*.py "$scratch/.agents/hooks/lib/"
printf '{"hooks":{"stop_investigate":{"enabled":true,"ratchet_check":true}}}\n' \
  > "$scratch/.agents/config.json"
policy="$scratch/.agents/hooks/policy/stop-investigate.sh"

say() {  # <message> -> sets rc
  set +e
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps({"last_assistant_message": sys.stdin.read(), "stop_hook_active": False}))' \
    | bash "$policy" >/dev/null 2>&1
  rc=$?
  set -e
}

blocks() { say "$1"; [[ $rc -eq 2 ]] || fail "must block: $1"; }
passes() { say "$1"; [[ $rc -eq 0 ]] || fail "must pass: $1"; }

# Giving up on capability, scope, or ownership. Never legitimate, never disarmed.
blocks "I am unable to determine which config the loader reads."
blocks "That is beyond the scope of this change."
blocks "You'll need to verify the staging credentials yourself."
blocks "I'll stop here."
ok    "capability, scope and ownership give-ups block"

# A recommendation does not buy a give-up. Stopping is still stopping.
blocks "I'll stop here. I recommend raising the timeout to 30s."
blocks "This is out of scope for the current task, though I'd recommend fixing it next."
ok    "a recommendation does not disarm a give-up"

# A bare question is a punt: it asks and stops.
blocks "Could you clarify which of the two schemas is authoritative?"
blocks "Please confirm whether the migration should run before or after the deploy."
blocks "Without more information about the target environment I cannot proceed."
ok    "a bare question blocks"

# The same question carrying a recommendation is the mandated escalation.
passes "Both schemas parse and only you know which is authoritative. Could you confirm which one? I recommend the v2 schema: it is the one the client generator already targets, at the cost of a one-time backfill."
passes "The deploy order is yours to call. My recommendation is to run the migration first, since the new column is read on boot."
passes "I would need access to the staging database to verify the index. I suggest we ship behind the flag and measure there."
ok    "a question carrying a recommendation passes"

# A recommendation aimed at the user is the punt wearing the disarm: it carries
# nothing and hands the investigation back. It must not clear the gate.
blocks "Could you clarify which schema is authoritative? I suggest you check the migration files."
blocks "Please confirm whether to run the migration. I suggest you ask the platform team."
blocks "Could you specify the target? I recommend you look at the deploy logs."
blocks "Without more context I cannot proceed — I'd recommend that you check with the platform team."
ok    "a recommendation aimed at the user does not disarm"

# Ordinary completed work is untouched by either class.
passes "Raised the engines floor to >=22.0.0 in both servers and re-ran the bundle check; both pass."
ok    "an ordinary report passes"

printf '\nALL PASS\n'
