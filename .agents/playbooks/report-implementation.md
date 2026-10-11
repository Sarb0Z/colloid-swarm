# Session report — implementation

The session produced a diff. Report what it does and what it costs.

The reader directed this work and did not write it. Say what each file, symbol,
or setting you name is for, the first time you name it: a name you have lived
with for an hour is noise to someone meeting it here. Lead each item with the
behavior the reader can observe, then the code that produces it.

- **Root cause** (for a defect): proximate and underlying.
- **What was done and why** — the decision, and the alternative you rejected.
- **What changed or was verified** — name the evidence: the command you ran, the
  test that passed, the flow you drove. "Should work" is not verification; it
  is the sentence written at the moment verification was skipped. A curl
  probe, a spot check, or a local run is partial evidence: report it as
  partial. Only the real user path, exercised end to end, raises a claim to
  verified.
- **Remaining blockers, risks, or next steps**, if any.
- **Review findings declined or filed**, each with its reason.

Close with a draft commit message for the session's work, in conventional
style.
