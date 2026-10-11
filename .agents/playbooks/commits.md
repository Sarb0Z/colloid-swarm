# Commits

Read before any commit, fixup, or rebase. The root `AGENTS.md` keeps the fold
conditions; this file carries the split and the procedure. When to commit is
set elsewhere: the output style, or a repository's own rule, which outranks it.

## Split along seams

Land significant work as a sequence of small commits, each carrying a
one-sentence story, cut along seams that carry meaning, never mechanically by
file or by layer.

- A refactor the feature motivated is its own commit and precedes the feature.
- A defect fixed in passing is its own commit, however small.
- A behavior change to an existing system stands apart from the refactor that
  enabled it and the feature that exposed it; it is the commit a later reader
  searches for.
- A vendored drop stands alone.
- What functions only together lands together: the halves of a feature that
  cannot run apart, data and the code that loads it.

Every commit builds and passes its checks, so the history bisects. When the
work stays uncommitted, propose the split in the report.

## Folding a review fix

A review fix belongs in the commit it corrects:

```sh
git commit --fixup=<sha>
GIT_SEQUENCE_EDITOR=true git rebase --autosquash -x '<checks>' <upstream>
```

Fold only while the target commit is on no remote branch, has not been
integrated by a workloop run, and sits in a tree no other session writes. A
`-x` step that runs git or a test suite inherits `GIT_DIR` from the rebase;
unset `GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX` inside it, or the step
acts on the repository under rebase. When any condition fails, or the fold
conflicts (`git rebase --abort`), land the fix as a trailing commit whose
message names the commit it corrects.
