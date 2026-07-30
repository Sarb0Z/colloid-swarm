#!/usr/bin/env python3
"""Embed verbatim scaffold source into the showcase page.

Reads every hook / skill / contract file this page describes, HTML-escapes it,
and injects an expandable "View source" panel into the matching card. Idempotent:
each generated panel is marked data-gen="1" and stripped before re-injection, so
re-running after a source change refreshes the embedded text in place.

    python3 demo/embed-src.py        # rewrites demo/scaffold-showcase.html

Self-contained output: the panels carry the text, so the published page needs no
access to the repo. Skills embed their SKILL.md only (not the references/ dirs).
"""
import html
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
PAGE = os.path.join(HERE, "scaffold-showcase.html")
# Publish variant: body-only (style + body markup) for the Artifact host, which
# supplies its own <!doctype>/<head>/<body>. Kept in sync — regenerated here.
ARTIFACT = os.path.join(HERE, "scaffold-showcase.artifact.html")

# Visible card name  ->  repo-relative source file. Keys must match the page's
# hook <span class="id"> and card <h3> text exactly.
MANIFEST = {
    # hooks
    "session-start":     ".agents/hooks/policy/session-start.sh",
    "research-prime":    ".agents/hooks/policy/research-prime.sh",
    "guard-destructive": ".agents/hooks/policy/guard-destructive.sh",
    "post-edit-check":   ".agents/hooks/policy/post-edit-check.sh",
    "sources-capture":   ".agents/hooks/policy/sources-capture.sh",
    "stop-investigate":  ".agents/hooks/policy/stop-investigate.sh",
    "session-wrap":      ".agents/hooks/policy/session-wrap.sh",
    "pre-compact":       ".agents/hooks/policy/pre-compact.sh",
    # skills (SKILL.md only)
    "scalability-audit":                  ".agents/skills/scalability-audit/SKILL.md",
    "search-and-cite":                    ".agents/skills/search-and-cite/SKILL.md",
    "security-audit":                     ".agents/skills/security-audit/SKILL.md",
    "thermo-nuclear-code-quality-review": ".agents/skills/thermo-nuclear-code-quality-review/SKILL.md",
    "seo-geo-growth-audit":               ".agents/skills/seo-geo-growth-audit/SKILL.md",
    "frontend-design":                    ".agents/skills/frontend-design/SKILL.md",
    # contract / tracking / config
    "AGENTS.md":       "AGENTS.md",
    "breadcrumbs.md":  ".agents/breadcrumbs.md",
    "debt-log.md":     ".agents/debt-log.md",
    "config.json":     ".agents/config.json",
    # contracts
    "researcher.md":            ".agents/personas/researcher.md",
    "learning-reporter.md":     ".agents/personas/learning-reporter.md",
    "memory/README.md":         ".agents/memory/README.md",
    "diff-wrap.md":             ".agents/playbooks/diff-wrap.md",
    "report-implementation.md": ".agents/playbooks/report-implementation.md",
    "report-investigation.md":  ".agents/playbooks/report-investigation.md",
    "hostile-review.md":        ".agents/playbooks/hostile-review.md",
    "learning-report.md":       ".agents/playbooks/learning-report.md",
}

ARTICLE = re.compile(r'(<article class="(?:hook|card)"[^>]*>)(.*?)(</article>)', re.S)
HOOK_ID = re.compile(r'<span class="id">(.*?)</span>')
CARD_H3 = re.compile(r'<h3>(.*?)</h3>')
OLD_GEN = re.compile(r'\s*<details class="src" data-gen="1">.*?</details>', re.S)


def panel(name, rel):
    path = os.path.join(REPO, rel)
    with open(path, encoding="utf-8") as f:
        text = f.read()
    n = text.count("\n") + (0 if text.endswith("\n") else 1)
    body = html.escape(text)
    return (
        '<details class="src" data-gen="1">'
        f'<summary>View source <span class="lines">· {n} lines</span></summary>'
        f'<div class="srcpath">{html.escape(rel)}</div>'
        f'<pre><code>{body}</code></pre>'
        '</details>'
    )


def repl(m):
    open_tag, inner, close = m.group(1), m.group(2), m.group(3)
    inner = OLD_GEN.sub("", inner)                       # idempotent refresh
    name_m = HOOK_ID.search(inner) or CARD_H3.search(inner)
    if not name_m:
        return m.group(0)
    name = name_m.group(1).strip()
    rel = MANIFEST.get(name)
    if not rel:
        return open_tag + inner + close
    inner = inner.rstrip()
    return f"{open_tag}{inner}\n              {panel(name, rel)}\n            {close}"


def main():
    with open(PAGE, encoding="utf-8") as f:
        page = f.read()
    seen = set(HOOK_ID.findall(page)) | set(CARD_H3.findall(page))
    missing = [k for k in MANIFEST if k not in seen]
    if missing:
        sys.stderr.write("warning: manifest keys not found on page: %s\n" % ", ".join(missing))
    out, count = ARTICLE.subn(repl, page)
    with open(PAGE, "w", encoding="utf-8") as f:
        f.write(out)
    embedded = out.count('data-gen="1"')
    print(f"embedded {embedded} source panels across {count} cards -> {os.path.relpath(PAGE, REPO)}")

    style = re.search(r"<style>.*?</style>", out, re.S).group(0)
    body = re.search(r"<body>(.*)</body>", out, re.S).group(1).strip()
    with open(ARTIFACT, "w", encoding="utf-8") as f:
        f.write(style + "\n\n" + body + "\n")
    print(f"wrote publish variant -> {os.path.relpath(ARTIFACT, REPO)}")


if __name__ == "__main__":
    main()
