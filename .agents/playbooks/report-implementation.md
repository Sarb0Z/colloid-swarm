# Session report — implementation

The session produced a diff. Report what it does and what it costs.

The reader directed this work and did not write it. Say what each file, symbol,
or setting you name is for, the first time you name it. Lead each item with the
behavior the reader can observe, then the code that produces it.

- **Root cause** (for defects): proximate and underlying.
- **What was done and why** — the decision, and the alternative you rejected.
- **What changed or was verified** — name the evidence: the command you ran, the
  test that passed, the flow you drove. "Should work" is not verification.
  Curl checks, spot checks, and local runs are partial evidence — report
  them as partial; only the real user path exercised end-to-end upgrades
  a claim to verified.
- **Remaining blockers, risks, or next steps**, if any.
- **Review findings declined or filed**, each with its reason.

Then draft a commit message for the session's work in conventional style.

Last, after writing the report, clear the status band's `report` flag. On
Claude Code, run
`python3 .agents/hooks/lib/owed.py clear report --session "$CLAUDE_CODE_SESSION_ID"`;
other hosts raise no flag.
