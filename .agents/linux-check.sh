#!/usr/bin/env bash
# Run hook tests and the death reader's procStart self-check on Linux, in an
# ubuntu:24.04 container, from a Mac or any host with Docker.
#
# Usage: .agents/linux-check.sh [test-name.sh ...]
#
# With no arguments it runs nine hook and workloop tests: the death reader's,
# the wait gate's, the readout's, the workloop inbox's, session start's,
# session end's, the commit nudge's, style injection's and the workloop's. It
# tests the tree it is run from: the tracked and
# unignored files, uncommitted edits included, committed as one fresh root
# commit in a git repository inside the container. The tree is streamed in
# with tar, never bind-mounted, so it works against Colima and a remote Docker
# host alike. The tests run as a normal user, so a file at mode 0 stays
# unreadable.
#
# The first run pulls ubuntu:24.04 and installs python3, git, procps, jq and
# lsof with apt into a local image `colloid-linux-check:ubuntu-24.04-<hash>`,
# the hash taken from the image's Dockerfile text; later runs reuse that image
# and need no network. An edit to the Dockerfile builds a new image and removes
# the other `colloid-linux-check` images.
#
# The image carries the label `colloid.tool=linux-check`; the container carries
# it too, and `colloid.run` and `colloid.lane` from COLLOID_RUN and COLLOID_LANE
# when set.
#
# Not a `test-*` file and not in check-all.sh: it needs a running Docker daemon,
# which not every host has.
#
# Exit status: 0 when every test and the self-check pass, 1 when any fails,
# 2 when Docker is missing or its daemon is down, a named test does not exist,
# the container is lost or a setup step failed.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name="linux-check-$$"
dockerfile='FROM ubuntu:24.04
LABEL colloid.tool=linux-check
RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 git procps jq lsof \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m tester \
 && mkdir /w && chown tester /w
USER tester
RUN git config --global user.name "colloid linux-check" \
 && git config --global user.email "linux-check@colloid.invalid"
'
image="colloid-linux-check:ubuntu-24.04-$(printf '%s' "$dockerfile" | cksum | cut -d' ' -f1)"
labels=(--label colloid.tool=linux-check)  # the container's, on `docker run` only
[[ -n "${COLLOID_RUN:-}" ]] && labels+=(--label "colloid.run=$COLLOID_RUN")
[[ -n "${COLLOID_LANE:-}" ]] && labels+=(--label "colloid.lane=$COLLOID_LANE")
default_tests=(
  test-agent-deaths.sh test-agent-waits.sh test-readout.sh
  test-workloop-inbox.sh test-session-start.sh test-session-end.sh test-commit-nudge.sh
  test-style-inject.sh test-workloop.sh
)
tests=("$@")
(( ${#tests[@]} )) || tests=("${default_tests[@]}")
for t in "${tests[@]}"; do
  [[ -f "$repo/.agents/$t" ]] \
    || { echo "linux-check: no test named $t in .agents/" >&2; exit 2; }
done

command -v docker >/dev/null \
  || { echo "linux-check: docker is not installed or not on PATH" >&2; exit 2; }
docker info >/dev/null 2>&1 \
  || { echo "linux-check: the docker daemon is not reachable (on Colima: colima start)" >&2; exit 2; }

container_alive() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == true ]]
}

cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# The image's user has a global git identity for the tree's commit and the
# tests, and safe.directory stays unset: test-workloop.sh relies on git's
# ownership check being live, and the tar-streamed files belong to that user.
if ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "linux-check: building $image (first run: pulls ubuntu:24.04 and apt packages)"
  printf '%s' "$dockerfile" | docker build -q -t "$image" - >/dev/null \
    || { echo "linux-check: image build failed" >&2; exit 2; }
  # Each Dockerfile edit leaves the previous image behind; one still in use stays.
  docker image ls colloid-linux-check --format '{{.Repository}}:{{.Tag}}' | grep -vxF "$image" \
    | while IFS= read -r old; do
        docker image rm "$old" >/dev/null 2>&1 || echo "linux-check: could not remove the old image $old" >&2
      done
fi

docker run -d --rm --name "$name" "${labels[@]}" "$image" sleep 3600 >/dev/null \
  || { echo "linux-check: cannot start the container" >&2; exit 2; }

# Stream the working tree in: tracked and unignored files that exist on disk.
# COPYFILE_DISABLE keeps macOS tar from adding AppleDouble `._` files.
cd "$repo" || exit 2
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
    printf '%s\n' "$out" | grep -E '^(note:|SKIP)' | sed 's/^/    /' || true
  else
    container_alive || { echo "linux-check: the container was lost during $t" >&2; exit 2; }
    echo "FAIL $t"
    printf '%s\n' "$out" | sed 's/^/    /'
    failed+=("$t")
  fi
done

# The death reader compares a session's recorded procStart with `ps` for the
# same pid; Linux and macOS print the same lstart format only under LC_ALL=C
# and TZ=UTC. A matching entry and one 3 s off (within the reader's start
# slack) must produce no output, an entry an hour off
# (beyond the reader's start slack) the "cannot tell live sessions" line naming
# both values.
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
near="$(date -u -d "$ps_start UTC + 3 seconds" "+%a %b %e %H:%M:%S %Y")"
mk "$near"
within="$(show)"
off="$(date -u -d "$ps_start UTC + 1 hour" "+%a %b %e %H:%M:%S %Y")"
mk "$off"
mismatch="$(show)"
rc=0
if [[ -n "$exact" ]]; then echo "exact procStart [$ps_start] printed: $exact"; rc=1; fi
if [[ -z "$near" || "$near" == "$ps_start" || -n "$within" ]]; then
  echo "procStart [$near] 3 s after ps [$ps_start] printed: [$within]"; rc=1
fi
if [[ -z "$off" || "$off" == "$ps_start" ]]; then
  echo "the offset procStart [$off] is empty or equals ps [$ps_start]"; rc=1
elif [[ "$mismatch" != *"cannot tell live sessions on this host (ps gives '$ps_start' for pid $pid, its registry entry '$off')"* ]]; then
  echo "procStart [$off] against ps [$ps_start] printed: [$mismatch]"; rc=1
fi
exit $rc
PROBE
}
if out="$(probe_script | docker exec -i "$name" bash -s 2>&1)"; then
  echo "PASS procStart self-check"
else
  container_alive || { echo "linux-check: the container was lost during the procStart self-check" >&2; exit 2; }
  echo "FAIL procStart self-check"
  printf '%s\n' "$out" | sed 's/^/    /'
  failed+=("procStart self-check")
fi

if (( ${#failed[@]} )); then
  echo "linux-check: ${#failed[@]} failed: ${failed[*]}" >&2
  exit 1
fi
echo "linux-check: all passed"
