#!/usr/bin/env bash
# Engine-agnostic policy: an agent's file edit inside the product folder needs
# no permission prompt.
#
# PreToolUse on Edit, Write, MultiEdit and NotebookEdit, for every agent. When
# the repository's ignored config.json sets hooks.product_folder.enabled and
# every target lies in the product folder (hooks/lib/product_folder.py defines
# it), the decision is "allow". Anything else gets no decision, so Claude
# Code's own prompt, a user-level deny rule, and the parallel-writers gate's
# denial all stay in force: a hook's "allow" skips only the prompt. Plan mode
# is never granted.
#
# Input (stdin JSON): {"project_dir", "cwd", "tool_name", "tool_input": {...},
#   "permission_mode"}
# Output: an allow envelope on stdout when the grant applies, silence otherwise.
# The switch is a no-op where it is off, so this policy ships to every
# repository unchanged.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
exec python3 "$repo/.agents/hooks/lib/product_folder.py" grant "$repo"
