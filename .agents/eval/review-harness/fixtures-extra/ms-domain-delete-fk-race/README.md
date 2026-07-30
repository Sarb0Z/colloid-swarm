The fixture diff appends two untracked test files as raw text with no diff
header, so git apply drops them. These are those files, split at their
docstring boundaries and syntax-checked. truncate-at is the last line of
well-formed diff in artifact.diff.
