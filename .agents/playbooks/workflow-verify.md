# Workflow: Verify

QA of something deployed or built. It runs against the environment the user
reaches, not a local stand-in, and changes nothing there.

| Step | Standard | Critical |
|---|---|---|
| Name the claims under test and the environment, with the build or commit it runs | Yes | Yes |
| **Delegate** each surface to a `qa-verifier` cell; it closes what it started before it reports | Yes | Yes |
| Observe, do not infer: every pass carries a command, response, screenshot, or log line | Yes | Yes |
| Writes against a live system need the operator's approval first, one scope each | Yes | Yes |
| Report passes, failures, and coverage gaps; a failure goes to Fix, not into the report as a workaround | Yes | Yes |
| A second, independent cell reproduces each high-stakes claim | — | Yes |
