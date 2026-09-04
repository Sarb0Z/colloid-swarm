# Clean-up and behavior-impact review

Scope: the files this session actually touched. Do not sweep files you did not
edit — a wrap is not a repo-wide cleanup mission.

## 1. Clean-up on the touched files

- Remove unused imports, dead branches, and unused variables anywhere in these
  files — pre-existing or introduced this session. The touched files are in
  scope as a whole; only files you did not edit are off-limits.
- Delete comments that describe behavior you removed or replaced.
- Delete TODO markers you wrote.
- Delete temporary scripts, fixtures, or scratch files created for iteration.
- Stop what the work started: browser contexts, dev servers, watchers, and the
  containers or compose stacks the work needed. The unit is closing, so nothing
  is left to keep them warm for. Say which one you kept, and why, if you keep
  any.

## 2. Behavior-impact review on the touched files

- Compare the new behavior to the prior behavior.
- Flag any regressions or unintended consequences you find.
- Update every downstream caller, test, and doc/instruction file in the touched
  domain that the change affects.
- Stale behavior left in old code paths or docs is a regression.
