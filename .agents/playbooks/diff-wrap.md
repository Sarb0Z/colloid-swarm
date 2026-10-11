# Clean-up and behavior-impact review

Scope: the files this session touched. A wrap is not a cleanup of the
repository, and a file the session did not edit is off-limits.

## 1. Clean-up on the touched files

A touched file is in scope as a whole, pre-existing faults included. Within it,
remove every unused import, dead branch, and unused variable; delete the
comments that describe behavior you removed or replaced, the TODO markers you
wrote, and the scripts, fixtures, and scratch files made for iteration. Stop
what the work started — browser contexts, dev servers, watchers, and the
containers or compose stacks it needed: the unit is closing, so nothing remains
to keep them warm for, and any one you keep is named with its reason.

## 2. Behavior-impact review on the touched files

Compare the new behavior with the prior behavior and report every regression
or unintended consequence the comparison exposes. Update every downstream
caller, test, and documentation or instruction file in the touched domain that
the change affects: stale behavior left in an old code path or document is
itself a regression.
