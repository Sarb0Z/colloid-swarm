# Clean-up and behavior-impact review

Scope: the files this session touched. Do not sweep files you did not edit; a
wrap is not a cleanup of the repository.

## 1. Clean-up on the touched files

A touched file is in scope as a whole, pre-existing faults included. Within it,
remove every unused import, dead branch, and unused variable; delete the
comments that describe behavior you removed or replaced, the TODO markers you
wrote, and the scripts, fixtures, and scratch files made for iteration. Stop
what the work started — browser contexts, dev servers, watchers, and the
containers or compose stacks it needed: the unit is closing, so nothing remains
to keep them warm for, and name any one you keep, with its reason.

## 2. Behavior-impact review on the touched files

Compare the new behavior with the prior and report every regression or
unintended consequence. Update every downstream caller, test, and doc or
instruction file in the touched domain that the change affects; stale behavior
left in old code paths or docs is a regression.
