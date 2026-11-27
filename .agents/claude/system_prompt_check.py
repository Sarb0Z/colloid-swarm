#!/usr/bin/env python3
"""Compare Claude Code's live default system prompt with the copy the curated prompt was cut from.

The launchers start every session with `--system-prompt-file
.agents/claude/system-prompt.md`, which replaces Claude Code's own prompt. That
file is the default with its behavioural lines removed, so a Claude Code release
that changes the default — a new harness fact, a reworded section — is invisible
until someone compares. This script captures the default the installed Claude
Code sends, through a local listener it points `ANTHROPIC_BASE_URL` at, and
compares it with `system-prompt.default.txt`, the default as captured when the
curated file was last cut. Nothing leaves the machine: the listener answers
every request with 500.

Usage:
  system_prompt_check.py          exit 1 and print the diff when the default changed
  system_prompt_check.py --update record the live default as the new baseline

After an update, carry the change into `system-prompt.md` by hand, then run
`--update`. The appended device-policy prompt and the environment block are
not part of the compared text: the first follows the style file, the second
arrives in the first user message.
"""

import difflib
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASELINE = HERE / "system-prompt.default.txt"
STYLE = HERE / "output-style.md"
sys.path.insert(0, str(HERE.parent / "hooks" / "lib"))
import output_style  # noqa: E402

TIMEOUT_SECONDS = 90
# The default differs by model: some models get extra paragraphs of
# behavioural guidance. Each one a launcher can start is compared.
MODELS = ("fable", "opus", "sonnet", "haiku")


def capture_all(run) -> str:
    return "".join(f"=== {model} ===\n{capture(run, model)}" for model in MODELS)


def capture(run, model) -> str:
    """The default prompt's own text block, from one headless request the listener refuses."""
    bodies = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("content-length", 0)))
            if b'"system"' in body:
                bodies.append(json.loads(body))
            self.send_response(500)
            self.end_headers()

        def do_HEAD(self):
            self.send_response(200)
            self.end_headers()

        def log_message(self, format, *args):
            return

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory() as fixture:
            run(["git", "init", "-q", fixture])
            env = {key: value for key, value in os.environ.items()
                   if key not in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT")}
            env.update(ANTHROPIC_BASE_URL=f"http://127.0.0.1:{server.server_port}",
                       CLAUDE_CODE_MAX_RETRIES="0")
            run(["claude", "-p", "hi", "--model", model], cwd=fixture, env=env,
                timeout=TIMEOUT_SECONDS)
    finally:
        server.shutdown()
    if not bodies:
        raise SystemExit(f"system-prompt check: Claude Code sent no request with a system prompt for {model}")
    blocks = [block["text"] for block in bodies[-1]["system"]]
    if len(blocks) < 2:
        raise SystemExit(f"system-prompt check: expected the identity block and the prompt, got {len(blocks)} block(s)")
    return own_text(blocks[1], output_style.body(str(STYLE)))


def own_text(prompt: str, style_body: str) -> str:
    """The prompt without the device policy's appended style, which starts with the
    style's first line, and without the token-budget line, which changes per request."""
    first_line = style_body.strip().splitlines()[0]
    cut = prompt.find(first_line)
    text = prompt if cut < 0 else prompt[:cut]
    lines = [line for line in text.splitlines() if not line.startswith("<total_tokens>")]
    return "\n".join(lines).strip() + "\n"


def run_quietly(argv, **kwargs):
    # A refused request makes `claude -p` exit non-zero, which is the expected
    # end of the capture; only a missing binary or a timeout is a failure.
    subprocess.run(argv, capture_output=True, check=False, **kwargs)


def main(argv) -> int:
    live = capture_all(run_quietly)
    version = subprocess.run(["claude", "--version"], capture_output=True, text=True).stdout.strip()
    if argv[:1] == ["--update"]:
        BASELINE.write_text(live)
        print(f"system-prompt check: recorded the default of Claude Code {version} ({len(live)} bytes)")
        return 0
    recorded = BASELINE.read_text() if BASELINE.is_file() else ""
    if live == recorded:
        print(f"system-prompt check: Claude Code {version} sends the recorded default")
        return 0
    sys.stdout.writelines(difflib.unified_diff(
        recorded.splitlines(keepends=True), live.splitlines(keepends=True),
        "system-prompt.default.txt", f"live default ({version})"))
    print(f"\nsystem-prompt check: the default changed. Carry each change into "
          f"{HERE / 'system-prompt.md'} unless it is behavioural guidance the harness "
          f"already owns, then run this script with --update.")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
