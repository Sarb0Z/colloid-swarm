# Clean-up and behavior-impact review

Scope: the files this session touched. Do not sweep files you did not edit; a
wrap is not a cleanup of the repository, and a sweep turns a diff someone can
review into one nobody asked for.

## 1. Clean-up on the touched files

A touched file is in scope as a whole, pre-existing faults included: the
reviewer is already reading it, and the dead import above your hunk costs a
line now and a whole change later. Within it, remove every unused import, dead
branch, and unused variable; delete the comments that describe behavior you
removed or replaced, which speak of code that no longer exists to a reader who
never saw it, the TODO markers you wrote, and the scripts, fixtures, and
scratch files made for iteration. Stop what the work started — browser
contexts, dev servers, watchers, and the containers or compose stacks it
needed: the unit is closing, so nothing remains to keep them warm for, and name
any one you keep, with its reason.

## 2. Behavior-impact review on the touched files

Compare the new behavior with the prior behavior and report every regression
or unintended consequence the comparison exposes. The diff shows what you
changed; only the comparison shows what you broke. Update every downstream
caller, test, and documentation or instruction file in the touched domain that
the change affects: stale behavior left in an old code path or document is
itself a regression, and the quieter kind, because the next agent reads that
document as true.
