#!/usr/bin/env bash
# Run hook tests and the death reader's procStart self-check on Linux, in an
# ubuntu:24.04 container, from a Mac or any host with Docker.
#
# Usage: .agents/linux-check.sh [test-name.sh ...]
#
# With no arguments it runs the hook tests the agent-deaths work touches. It
# tests the tree it is run from: the tracked and unignored files, uncommitted
# edits included, as `.agents/suite.sh` copies them, committed into a fresh git
# repository inside the container. The tree is streamed in with tar, never
# bind-mounted, so it works against Colima and a remote Docker host alike.
#
# The first run pulls ubuntu:24.04 and installs python3, git, procps, jq and
# lsof with apt into the local image `colloid-linux-check:ubuntu-24.04`; later
# runs reuse that image and need no network. Delete the image to refresh it.
#
# Not a `test-*` file and not in check-all.sh: it needs a running Docker daemon,
# which not every host has.
#
# Exit status: 0 when every test and the self-check pass, 1 when any fails,
# 2 when Docker is missing or its daemon is down or a setup step failed.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="colloid-linux-check:ubuntu-24.04"
name="linux-check-$$"
default_tests=(
  test-agent-deaths.sh test-agent-waits.sh test-readout.sh
  test-workloop-inbox.sh test-session-start.sh test-commit-nudge.sh
  test-style-inject.sh test-workloop.sh
)
tests=("$@")
(( ${#tests[@]} )) || tests=("${default_tests[@]}")

command -v docker >/dev/null \
  || { echo "linux-check: docker is not installed or not on PATH" >&2; exit 2; }
docker info >/dev/null 2>&1 \
  || { echo "linux-check: the docker daemon is not reachable (on Colima: colima start)" >&2; exit 2; }

cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# git's ownership check and the tests' own identity need a real global identity,
# and safe.directory must stay unset: test-workloop.sh relies on the ownership
# check being live.
if ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "linux-check: building $image (first run: pulls ubuntu:24.04 and apt packages)"
  docker build -q -t "$image" --label colloid.run=linux-check - >/dev/null <<'DOCKERFILE' \
    || { echo "linux-check: image build failed" >&2; exit 2; }
FROM ubuntu:24.04
RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 git procps jq lsof \
 && rm -rf /var/lib/apt/lists/* \
 && git config --global user.name "colloid linux-check" \
 && git config --global user.email "linux-check@colloid.invalid"
DOCKERFILE
fi

docker run -d --rm --name "$name" --label colloid.run=linux-check "$image" sleep 3600 >/dev/null \
  || { echo "linux-check: cannot start the container" >&2; exit 2; }

# Stream the working tree in: tracked and unignored files that exist on disk.
# COPYFILE_DISABLE keeps macOS tar from adding AppleDouble `._` files.
cd "$repo" || exit 2
docker exec "$name" mkdir /w || exit 2
{
  git ls-files -z --cached --others --exclude-standard --deduplicate \
    | while IFS= read -r -d '' f; do
        if [[ -e "$f" || -L "$f" ]]; then printf '%s\0' "$f"; fi
      done
} | COPYFILE_DISABLE=1 tar --no-xattrs --null -T - -cf - \
  | docker exec -i "$name" tar -xf - -C /w \
  || { echo "linux-check: copying the tree into the container failed" >&2; exit 2; }
docker exec "$name" bash -c 'cd /w && git init -q && git add -A && git commit -q -m "linux-check tree"' \
  || { echo "linux-check: cannot commit the tree in the container" >&2; exit 2; }

failed=()
for t in "${tests[@]}"; do
  if out="$(docker exec "$name" bash -c "cd /w && bash .agents/$t" 2>&1)"; then
    echo "PASS $t"
  else
    echo "FAIL $t"
    printf '%s\n' "$out" | sed 's/^/    /'
    failed+=("$t")
  fi
done

# The death reader compares a session's recorded procStart with `ps` for the
# same pid; Linux and macOS print the same lstart format only under LC_ALL=C
# and TZ=UTC. A matching entry must produce no output, a one-second-off entry
# the "cannot tell live sessions" line.
probe_script() {
  cat <<'PROBE'
set -u
export CLAUDE_CONFIG_DIR=/tmp/cfg
rm -rf "$CLAUDE_CONFIG_DIR"; mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
sleep 600 & pid=$!
trap "kill $pid 2>/dev/null" EXIT
ps_start="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$pid" | sed "s/^ *//;s/ *$//")"
mk() {
  python3 - "$pid" "$1" <<PY > "$CLAUDE_CONFIG_DIR/sessions/$pid.json"
import json, sys, time
print(json.dumps({"pid": int(sys.argv[1]), "sessionId": "sess-own-1", "procStart": sys.argv[2], "startedAt": int(time.time() * 1000) - 60000}))
PY
}
show() { python3 /w/.agents/hooks/lib/agent_deaths.py show /w sess-own-1 2>&1; }
mk "$ps_start"
exact="$(show)"
off="$(date -u -d "$ps_start UTC + 1 second" "+%a %b %e %H:%M:%S %Y")"
mk "$off"
mismatch="$(show)"
rc=0
if [[ -n "$exact" ]]; then echo "exact procStart [$ps_start] printed: $exact"; rc=1; fi
if [[ "$mismatch" != *"cannot tell live sessions on this host"* ]]; then
  echo "procStart [$off] against ps [$ps_start] printed: [$mismatch]"; rc=1
fi
exit $rc
PROBE
}
if out="$(probe_script | docker exec -i "$name" bash -s 2>&1)"; then
  echo "PASS procStart self-check"
else
  echo "FAIL procStart self-check"
  printf '%s\n' "$out" | sed 's/^/    /'
  failed+=("procStart self-check")
fi

if (( ${#failed[@]} )); then
  echo "linux-check: ${#failed[@]} failed: ${failed[*]}" >&2
  exit 1
fi
echo "linux-check: all passed"
