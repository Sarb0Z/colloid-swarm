# Workflow: Scaffold

Edits to the scaffold and transplants of it into satellites. Read
`.agents/AGENTS.md` first. Guard and gate hooks and the contract files (the root
`AGENTS.md`, `.agents/AGENTS.md`, the playbooks, the hostile-review contract)
are critical; every other scaffold change is standard.

| Step | Standard | Critical |
|---|---|---|
| Run the Build workflow at the stakes above | Yes | Yes |
| **Delegate** independent surfaces to `workloop` lanes; a single writer edits the main tree | When two or more writers run at once | When two or more writers run at once |
| Run the scaffold's Verification list (`.agents/AGENTS.md`) on the landed tree, not only the narrow checks | Yes | Yes |
| A guard or gate change ships with a firing test that fails without it | Yes | Yes |
| Propagate to satellites last, by `.agents/export/README.md`: sync first, adaptation after, on the branch each satellite is on | When asked | When asked |
