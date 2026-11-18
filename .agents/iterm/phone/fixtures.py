#!/usr/bin/env python3
"""Test support: write a transcript the way Claude Code 2.1.325 writes one.

Each method of `Transcript` appends the rows one real event wrote, copied from
the sessions of `.agents/knowledge/research/2026-11-17-permission-request-hook-timing.md`
and of the headless runs of 2026-11-18 (a hook's allow, a hook's deny, no
decision), less the fields no reader here uses: model usage, request ids, git
branch. The tests of this folder build their transcripts with it, and
`.agents/test-phone-hooks.sh` runs it as a command to stand in for Claude Code:

    fixtures.py <file> use <call id> <tool name> <tool input as JSON>
    fixtures.py <file> allowed-by-hook|denied-by-hook|allowed-at-mac|rejected-at-mac|denied-without-dialog <call id>
"""

from __future__ import annotations

import json
import sys
import time
from datetime import datetime, timezone

SESSION = "994bd8c0-b576-439f-9843-945d8e630a46"
REJECTED = ("The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a "
            "file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the "
            "user to tell you how to proceed.")


class Transcript:
    """Appends rows to `path`. `agent` makes it a subagent's file. `clock` gives each row's time."""

    def __init__(self, path, agent=None, clock=time.time):
        self.path, self.agent, self.clock = str(path), agent, clock
        self.count = 0

    def _row(self, kind: str, **fields) -> None:
        self.count += 1
        stamp = datetime.fromtimestamp(self.clock(), timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
        row = {"parentUuid": f"00000000-0000-4000-8000-{self.count - 1:012d}", "isSidechain": bool(self.agent)}
        if self.agent:
            row["agentId"] = self.agent
        row.update(fields)
        row.update({"type": kind, "uuid": f"00000000-0000-4000-8000-{self.count:012d}", "timestamp": stamp,
                    "userType": "external", "entrypoint": "cli", "sessionId": SESSION, "version": "2.1.325"})
        with open(self.path, "a", encoding="utf-8") as stream:
            stream.write(json.dumps(row) + "\n")

    def _result(self, call: str, content: str, is_error: bool, tool_use_result, **fields) -> None:
        self._row("user", promptId="143cbdce-9d87-4f9e-9f12-aea65fcbd1cd",
                  message={"role": "user", "content": [
                      {"type": "tool_result", "content": content, "is_error": is_error, "tool_use_id": call}]},
                  toolUseResult=tool_use_result, **fields)

    def prompt(self, text: str) -> None:
        self._row("user", promptId="143cbdce-9d87-4f9e-9f12-aea65fcbd1cd",
                  message={"role": "user", "content": text})

    def use(self, call: str, name: str, tool_input: dict) -> None:
        """The pending call: what the transcript holds while the permission dialog shows."""
        self._row("assistant", message={
            "model": "claude-haiku-5-5", "type": "message", "role": "assistant", "stop_reason": "tool_use",
            "content": [{"type": "tool_use", "id": call, "name": name, "input": tool_input,
                         "caller": {"type": "direct"}}]})

    def other_rows(self, count: int) -> None:
        """Rows of the kinds a transcript holds between calls, which no reader here uses."""
        for index in range(count):
            self._row("system", subtype="turn_duration", durationMs=index, isMeta=False)

    def allowed_by_hook(self, call: str, output: str = "200") -> None:
        self.hook_decided(call, "allow")
        self._result(call, output, False,
                     {"stdout": output, "stderr": "", "interrupted": False, "isImage": False,
                      "noOutputExpected": False},
                     permissionDecision={"decision": "accept", "source": "hook", "reasonType": "hook",
                                         "reasonCode": "bashMiss:no-rule-match"})

    def hook_decided(self, call: str, decision: str) -> None:
        """The row Claude Code writes when a hook's decision lands, before the call's result."""
        self._row("attachment", attachment={"type": "hook_permission_decision", "decision": decision,
                                            "toolUseID": call, "hookEvent": "PermissionRequest"})

    def denied_by_hook(self, call: str, message: str = "too risky") -> None:
        self.hook_decided(call, "deny")
        self._result(call, message, True, f"Error: {message}", toolDenialKind="permission-rule",
                     permissionDecision={"decision": "reject", "source": "hook", "reasonType": "hook",
                                         "reasonCode": "hook:PermissionRequest"})

    def allowed_at_mac(self, call: str, output: str = "200") -> None:
        self._result(call, output, False,
                     {"stdout": output, "stderr": "", "interrupted": False, "isImage": False,
                      "noOutputExpected": False},
                     sandboxed=False,
                     permissionDecision={"decision": "accept", "source": "user_temporary", "grantScope": "once",
                                         "reasonCode": "bashMiss:no-rule-match"})

    def rejected_at_mac(self, call: str) -> None:
        """A No or an Esc at the dialog: the rejection, then the interrupt."""
        self._result(call, REJECTED, True, "User rejected tool use", toolDenialKind="user-rejected")
        self.interrupt()

    def interrupt(self) -> None:
        self._row("user", promptId="143cbdce-9d87-4f9e-9f12-aea65fcbd1cd",
                  message={"role": "user", "content": [
                      {"type": "text", "text": "[Request interrupted by user for tool use]"}]})

    def denied_without_dialog(self, call: str) -> None:
        """A session with no dialog whose hooks gave no decision."""
        self._result(call, "This command requires approval", True, "Error: This command requires approval",
                     permissionDecision={"decision": "reject", "source": "config",
                                         "reasonCode": "bashMiss:no-rule-match"})


def main(argv) -> int:
    path, action, call = argv[1], argv[2], argv[3]
    transcript = Transcript(path)
    if action == "use":
        transcript.use(call, argv[4], json.loads(argv[5]))
    else:
        getattr(transcript, action.replace("-", "_"))(call)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
