# Infrastructure as code

Read before changing hosted, production, or staging state. The root
`AGENTS.md` section "Changes live in the repository" owns the rule; this file
carries its detail.

Hosting settings, environment-variable declarations, auth configuration, secret
names, DNS, schema, and seed data are declared in the repository and applied by
committed code: a CI workflow, or a committed plan/apply tool that reports drift
before it changes anything and is safe to rerun. State is then reproducible
after loss, auditable in Git, and comparable across environments.

A dashboard edit or a script outside the repository is diagnosis or containment
only; its declaration and apply path land in the repository in the same
session. Secret values stay in the secret store or a gitignored env file; the
repository names each secret and where it comes from.
