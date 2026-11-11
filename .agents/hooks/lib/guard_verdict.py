"""One verdict from both guards for a command that runs outside any tool call.

The workloop controller runs a `--verify` command and `access.py` runs a
declared probe with no PreToolUse hook in front of them, so each asks the
destructive guard and the publish guard itself. Both are asked with `--force`:
the config toggles govern the hooks, where a denial costs the operator one
tool call they can rephrase, and a command running unattended has no such
escape. `repo` is the repository whose policy the guards read.
"""
import json
import subprocess
import sys
from pathlib import Path

LIB = Path(__file__).resolve().parent


class GuardFailure(RuntimeError):
    """A guard could not evaluate the command; the command's fate is unknown."""

    def __init__(self, guard, status, stderr):
        super().__init__(f"{guard} could not evaluate the command (exit {status}): {stderr}")
        self.guard = guard
        self.status = status
        self.stderr = stderr


def verdict(command, repo):
    """(guard name, reason) of the first guard that refuses `command`, or None.

    Raises GuardFailure when a guard exits with a status that is neither a
    verdict nor silence.
    """
    destructive = subprocess.run(
        [sys.executable, str(LIB / "guard-destructive.py"), str(repo), "--force"],
        input=json.dumps({"command": command}), text=True, capture_output=True,
    )
    if destructive.returncode == 2:
        return "guard-destructive", destructive.stderr.strip()
    if destructive.returncode != 0:
        raise GuardFailure("guard-destructive", destructive.returncode, destructive.stderr.strip())
    publish = subprocess.run(
        [sys.executable, str(LIB / "guard-publish.py"), str(repo), "--force"],
        input=json.dumps({"tool_name": "Bash", "tool_input": {"command": command}, "permission_mode": "default"}),
        text=True, capture_output=True,
    )
    if publish.returncode != 0:
        raise GuardFailure("guard-publish", publish.returncode, publish.stderr.strip())
    if publish.stdout.strip():
        try:
            reason = json.loads(publish.stdout)["hookSpecificOutput"].get("permissionDecisionReason", "")
        except (ValueError, KeyError, TypeError):
            reason = publish.stdout.strip()
        return "guard-publish", reason
    return None
