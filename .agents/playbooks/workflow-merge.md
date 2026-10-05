# Workflow: Merge

Triage, test-merge, and review of a pull request. Merging is an outward
mutation and needs the operator's approval in the session.

| Step | Standard | Critical |
|---|---|---|
| Read the pull request, its linked issue, and its CI result | Yes | Yes |
| Test-merge locally onto the current base, never onto a shared branch | Yes | Yes |
| Run the full suite on the merged tree, the engine suite included where the repository has one | Yes | Yes |
| Review the code yourself before merging; a reviewer cell adds an independent read | One reviewer | Several reviewers, one axis each, as one round |
| Report the findings and a merge recommendation; merge only on the operator's approval | Yes | Yes |
| After the merge, verify the result where it runs | Yes | Yes |
