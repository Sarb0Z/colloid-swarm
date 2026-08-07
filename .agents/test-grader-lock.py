#!/usr/bin/env python3
"""Drive the grader lock against the paths it must and must not refuse.

The table is the contract. A row states one repo-relative path and whether a
subagent may write it, so a set that widens or narrows shows up as a named
failure rather than as a behaviour nobody notices.

Two cases the sibling command guard cannot express are covered here end to end,
because both are ways the lock stops guarding without saying so: the toggle, and
a missing decision module.
"""

import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

here = pathlib.Path(__file__).resolve().parent
repo = here.parent
module = here / "hooks" / "lib" / "grader-lock.py"
spec = importlib.util.spec_from_file_location("grader_lock", module)
lock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lock)

fails = 0


def check(name, ok, detail=""):
    global fails
    if ok:
        print(f"ok    {name}")
    else:
        fails += 1
        print(f"FAIL  {name}{(chr(10) + '  ' + detail) if detail else ''}")


# Repo-relative paths a subagent must not write: the standard, the gates, the
# transport that reaches a gate, and the tests that prove a gate fires.
GOVERNED = [
    "AGENTS.md",
    ".agents/AGENTS.md",
    ".claude/AGENTS.md",
    "demo/AGENTS.md",
    "tensium-trial/AGENTS.md",
    ".agents/playbooks/hostile-review.md",
    ".agents/playbooks/review-axes.md",
    ".agents/playbooks/breadcrumb-burndown.md",
    ".agents/hooks/policy/guard-destructive.sh",
    ".agents/hooks/policy/grader-lock.sh",
    ".agents/hooks/lib/grader-lock.py",
    ".agents/claude/settings.json",
    ".agents/claude/normalize-hook.py",
    ".agents/claude/adapter.sh",
    ".agents/codex/hooks.json",
    ".kimi/hooks/adapter.sh",
    ".kimi/hooks/normalize-hook.py",
    ".agents/eval/review-harness/contract.md",
    ".agents/eval/review-harness/grader-task.md",
    ".agents/lint-skills.sh",
    ".agents/sync-claude-agents.sh",
    ".agents/sync-codex.sh",
    ".agents/sync-mcp.sh",
    ".agents/config.json",
    ".agents/config.json.example",
    ".agents/test-guard-destructive.py",
    ".agents/test-grader-lock.py",
    ".agents/test-sync-claude.sh",
    ".agents/test-mutation.py",
    ".github/workflows/ci.yml",
    # The review harness's answer keys — editing one beats reading it.
    ".agents/fixtures/review-episodes/ms-arf-forward-milter/ground-truth.md",
    ".agents/fixtures/review-episodes/anything/intent.md",
    # The modules the sync gates and session-start decide from.
    ".agents/toggles.py",
    ".agents/mcp_registry.py",
    ".agents/reader_config.py",
    ".agents/export-scaffold.py",
    # One clause of the standard, delegated out of root AGENTS.md.
    ".github/instructions/README.md",
]

# Work product. A skill is graded by lint-skills.sh, which is governed above —
# the grader is locked, the graded artifact stays delegable.
WRITABLE = [
    ".agents/skills/search-and-cite/SKILL.md",
    ".agents/skills/search-and-cite/AGENTS.md",
    ".agents/skills/pentesting/reference/anything.md",
    ".agents/breadcrumbs.md",
    ".agents/debt-log.md",
    ".agents/knowledge/index.md",
    ".agents/README.md",
    ".agents/personas/researcher.md",
    # colloid-only
    ".agents/genome.sh",
    # /colloid-only
    ".agents/mcp.json",
    "README.md",
    # colloid-only
    "genomes.md",
    # /colloid-only
    "demo/demo.sh",
    "docs/learning/report.md",
    # Near-misses on the test-file rule: the prefix and the suffix both count.
    ".agents/testing-notes.md",
    ".agents/test-fixture.json",
    "test-elsewhere.py",
]

for path in GOVERNED:
    check(f"governed: {path}", lock.governed(path) is not None, "no rule fired")

for path in WRITABLE:
    check(f"writable: {path}", lock.governed(path) is None,
          f"refused as: {lock.governed(path)}")

# The symlink mirrors. `.agents/AGENTS.md` forbids editing through them, and a
# matcher reading the raw path would guard the mirror and miss the canonical.
#
# Built rather than read from this repository: the export ships a transplant kit
# whose mirrors do not exist until an operator applies it, and a test that reads
# the surrounding layout passes here and fails there for no defect at all.
with tempfile.TemporaryDirectory() as mirror_root:
    os.makedirs(os.path.join(mirror_root, ".agents", "claude"))
    os.makedirs(os.path.join(mirror_root, ".claude"))
    for rel in ("AGENTS.md", os.path.join(".agents", "claude", "settings.json")):
        with open(os.path.join(mirror_root, rel), "w", encoding="utf-8") as out:
            out.write("x\n")
    os.symlink("AGENTS.md", os.path.join(mirror_root, "CLAUDE.md"))
    os.symlink(os.path.join("..", ".agents", "claude", "settings.json"),
               os.path.join(mirror_root, ".claude", "settings.json"))

    resolved = lock.relative(os.path.join(mirror_root, "CLAUDE.md"), mirror_root)
    check("CLAUDE.md resolves onto the standard", resolved == "AGENTS.md", str(resolved))

    resolved = lock.relative(os.path.join(mirror_root, ".claude", "settings.json"),
                             mirror_root)
    check(".claude/settings.json resolves onto the canonical settings",
          resolved == ".agents/claude/settings.json", str(resolved))
    check("a write through the mirror is refused", lock.governed(resolved) is not None)

# Outside the repository is not this lock's business.
check("a path outside the repo is not governed",
      lock.relative("/etc/hosts", str(repo)) is None)
check("the parent of the repo is not governed",
      lock.relative(str(repo.parent), str(repo)) is None)
check("a path that does not exist yet still resolves",
      lock.relative(str(repo / ".agents" / "hooks" / "policy" / "new.sh"), str(repo))
      == ".agents/hooks/policy/new.sh")

# End to end through the shell entry point, which is what the adapter invokes.
entry = str(here / "hooks" / "policy" / "grader-lock.sh")


def run(payload, at=entry):
    return subprocess.run([at], input=json.dumps(payload), text=True, capture_output=True)


blocked = run({"files": [str(repo / ".agents" / "AGENTS.md")]})
check("entry point exits 2 on a governed path", blocked.returncode == 2,
      f"exit {blocked.returncode}: {blocked.stderr}")
check("entry point names the path", ".agents/AGENTS.md" in blocked.stderr, blocked.stderr)
check("entry point states the way forward", "main session" in blocked.stderr, blocked.stderr)

check("entry point exits 0 on work product",
      run({"files": [str(repo / ".agents" / "breadcrumbs.md")]}).returncode == 0)
check("one governed path among many still blocks",
      run({"files": [str(repo / "README.md"), str(repo / "AGENTS.md")]}).returncode == 2)

# Fail-open. A guard that cannot decide must never block the action.
check("entry point exits 0 on an empty payload", run({}).returncode == 0)
check("entry point exits 0 when files is absent", run({"file_path": "AGENTS.md"}).returncode == 0)
check("entry point exits 0 when files is not a list", run({"files": "AGENTS.md"}).returncode == 0)
check("entry point exits 0 on a non-string entry", run({"files": [None, 17]}).returncode == 0)
check("entry point exits 0 on an empty entry", run({"files": ["", "   "]}).returncode == 0)
check("entry point exits 0 on unreadable input",
      subprocess.run([entry], input="{not json", text=True,
                     capture_output=True).returncode == 0)

# The two ways the lock stops guarding silently, each in its own fixture tree.
# The policy resolves its repository from its own location, so a copy under a
# temporary root reads that root's config and that root's lib.
def fixture(root, with_module=True, config=None):
    policy_dir = os.path.join(root, ".agents", "hooks", "policy")
    lib_dir = os.path.join(root, ".agents", "hooks", "lib")
    os.makedirs(policy_dir)
    os.makedirs(lib_dir)
    shutil.copy2(entry, os.path.join(policy_dir, "grader-lock.sh"))
    shutil.copy2(here / "hooks" / "lib" / "config.py", os.path.join(lib_dir, "config.py"))
    if with_module:
        shutil.copy2(module, os.path.join(lib_dir, "grader-lock.py"))
    if config is not None:
        with open(os.path.join(root, ".agents", "config.json"), "w", encoding="utf-8") as out:
            json.dump(config, out)
    return os.path.join(policy_dir, "grader-lock.sh")


with tempfile.TemporaryDirectory() as sandbox:
    governed_here = {"files": [os.path.join(sandbox, ".agents", "AGENTS.md")]}
    live = fixture(sandbox)
    check("the fixture blocks before the toggle is written",
          run(governed_here, at=live).returncode == 2)

with tempfile.TemporaryDirectory() as sandbox:
    off = fixture(sandbox, config={"hooks": {"grader_lock": {"enabled": False}}})
    result = run({"files": [os.path.join(sandbox, ".agents", "AGENTS.md")]}, at=off)
    check("the config toggle turns the lock off", result.returncode == 0, result.stderr)

with tempfile.TemporaryDirectory() as sandbox:
    bare = fixture(sandbox, with_module=False)
    result = run({"files": [os.path.join(sandbox, ".agents", "AGENTS.md")]}, at=bare)
    check("a missing decision module does not block the action",
          result.returncode == 0, f"exit {result.returncode}")
    check("a missing decision module says so", "missing" in result.stderr, result.stderr)

print("\nALL PASS" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
