# Commits

Read before any commit, fixup, or rebase. This file carries the split, the
fold conditions and the procedure. When to commit is set elsewhere: the output
style, or a repository's own rule, which outranks it. Claude Code's built-in git
section is switched off (`includeGitInstructions: false`), so its other rules
live here:

- A subject is `type(scope): what changed` in plain words — `feat`, `fix`,
  `docs`, `test`, `chore` — and says what the change does before how; a
  reader who was not in the session must follow it.
- No interactive flags (`git rebase -i`, `git add -i`): the shell cannot answer
  them.
- Use `gh` for GitHub: pull requests, issues, the API.
- GitHub notifies the owner of any `@name` in a commit message, pull request,
  issue or comment. Write a bare `@name` only for a real login you mean to
  notify; put roles, placeholders and code (`@reviewer`, `@types/node`) in
  backticks.

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

Every commit builds and passes the checks covering what it changed: the
narrowest test, file or package that exercises it, or in a workloop run the
run's `--verify`. The full suite, the verify command the repository's
instructions declare, runs once, by the lead, on the tree about to be pushed,
and again when a fold or trailing fix changes that tree before the push; a cell
runs it only when its brief names it. A change no narrow check covers, such as
CI configuration, waits for that run. A repository that declares no suite says
so in the report. History therefore bisects by build and covering checks; a
distant test a commit broke may first fail at the push.
When the work stays uncommitted, propose the split in the report.

## Folding a review fix

A review fix belongs in the commit it corrects:

```sh
git commit --fixup=<sha>
GIT_SEQUENCE_EDITOR=true git rebase --autosquash -x '<checks>' <upstream>
```

`<checks>` are the covering checks of the commits replayed; the full suite runs
on the folded tip before it is pushed. Fold only while the target commit is on no
remote branch, has not been integrated by a workloop run, and sits in a tree no
other session writes. A `-x` step that runs git or a test suite inherits
`GIT_DIR` from the rebase; unset `GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
GIT_PREFIX` inside it, or the step acts on the repository under rebase. When any condition fails, or the fold
conflicts (`git rebase --abort`), land the fix as a trailing commit whose
message names the commit it corrects.
