#!/usr/bin/env python3
"""Verify committed host links without generating or pruning them."""

from pathlib import Path
import os
import sys


ROOT = Path(__file__).resolve().parent.parent


def expected_links() -> dict[Path, str]:
    links = {
        Path(".claude/AGENTS.md"): "../.agents/claude/AGENTS.md",
        Path(".claude/CLAUDE.md"): "AGENTS.md",
        Path(".claude/settings.json"): "../.agents/claude/settings.json",
        Path(".claude/hooks/adapter.sh"): "../../.agents/claude/adapter.sh",
        Path(".claude/hooks/README.md"): "../../.agents/claude/README.md",
        Path(".codex/hooks.json"): "../.agents/codex/hooks.json",
        Path(".codex/hooks/adapter.sh"): "../../.agents/codex/adapter.sh",
        Path(".codex/hooks/README.md"): "../../.agents/codex/README.md",
        Path(".github/copilot-instructions.md"): "../AGENTS.md",
        Path(".github/instructions/agents.instructions.md"): "../../.agents/AGENTS.md",
        Path(".github/instructions/claude.instructions.md"): "../../.claude/AGENTS.md",
        Path(".github/lsp.json"): "../.agents/lsp.json",
    }
    for persona in sorted((ROOT / ".agents/personas").glob("*.md")):
        links[Path(".claude/agents") / persona.name] = (
            f"../../.agents/personas/{persona.name}"
        )
    skills = sorted(
        path for path in (ROOT / ".agents/skills").iterdir()
        if path.is_dir() and (path / "SKILL.md").is_file()
    )
    rules = sorted((ROOT / ".agents/rules").glob("*.md"))
    collisions = {path.name for path in skills} & {path.stem for path in rules}
    if collisions:
        raise SystemExit(f"layout: skill/rule name collision: {sorted(collisions)}")
    for skill in skills:
        links[Path(".claude/skills") / skill.name] = f"../../.agents/skills/{skill.name}"
        links[Path(".claude/rules") / f"{skill.name}.md"] = (
            f"../../.agents/skills/{skill.name}/AGENTS.md"
        )
        links[Path(".github/instructions") / f"00-{skill.name}.instructions.md"] = (
            f"../../.agents/skills/{skill.name}/AGENTS.md"
        )
    for rule in rules:
        links[Path(".claude/rules") / rule.name] = f"../../.agents/rules/{rule.name}"
        links[Path(".github/instructions") / f"01-{rule.stem}.instructions.md"] = (
            f"../../.agents/rules/{rule.name}"
        )
    for name in ("demo", "tensium-trial"):
        if (ROOT / name / "AGENTS.md").is_file():
            links[Path(".github/instructions") / f"{name}.instructions.md"] = (
                f"../../{name}/AGENTS.md"
            )
    return links


def scaffold_owns(path: Path, expected: dict[Path, str]) -> bool:
    relative = path.relative_to(ROOT)
    if relative in expected:
        return True
    target = (path.parent / os.readlink(path)).resolve(strict=False)
    try:
        target.relative_to(ROOT / ".agents")
        return True
    except ValueError:
        return False


def main() -> int:
    expected = expected_links()
    failures = []
    for relative, target in expected.items():
        path = ROOT / relative
        if not path.is_symlink():
            failures.append(f"{relative}: expected symlink")
        elif os.readlink(path) != target:
            failures.append(f"{relative}: points to {os.readlink(path)!r}, expected {target!r}")
        elif not path.exists():
            failures.append(f"{relative}: target is missing")

    owned_roots = (
        Path(".claude/agents"), Path(".claude/skills"), Path(".claude/rules"),
        Path(".github/instructions"),
    )
    for directory in owned_roots:
        root = ROOT / directory
        if not root.is_dir():
            failures.append(f"{directory}: directory is missing")
            continue
        for path in root.iterdir():
            relative = path.relative_to(ROOT)
            if path.is_symlink() and scaffold_owns(path, expected) and relative not in expected:
                failures.append(f"{relative}: stale scaffold symlink")

    if failures:
        print("layout: invalid host integration", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1
    print(f"layout: {len(expected)} scaffold links valid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
