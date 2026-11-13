#!/usr/bin/env bash
# Policy: when a background agent's permission prompt opens, record that it
# waits on the operator, so every lead prompt and session start names it
# (WAITING ON YOU) and `workloop.py watch` reads its lane or cell as waiting,
# not silent.
#
# Event: Claude Code's PermissionRequest, the only record that names the agent
# behind a prompt. A prompt of the lead's own (no agent_id) is in front of the
# operator already and is not kept.
#
# Input  (stdin JSON): {"project_dir", "agent_id", "agent_type", "session_id",
#                       "transcript_path", "tool_name", "tool_input"}
# Output: nothing. The hook never decides the prompt; it always exits 0 and
#         reports a failure on stderr. The record is
#         <project_dir>/.agents/.readout/.agent-waits (hooks/lib/agent_waits.py).

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

python3 "$repo/.agents/hooks/lib/agent_waits.py" record "$repo" \
  || echo "agent-waits: recording the agent waiting on this permission prompt failed, so it reads as silent" >&2
exit 0
