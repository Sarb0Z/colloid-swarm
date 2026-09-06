---
date: 2026-09-06
subject: How test resources started by parallel lanes are owned, isolated, and reaped; how scarce shared resources are leased; where composed verification runs — prior art from Testcontainers, CI systems, Postgres, Playwright, Temporal, and merge queues, plus what this machine showed
kind: research
source: see `## Sources`
---

# Lane resources, leases, and composed verification

Opened by an operator transcript: three lanes "active but bottlenecked" on
shared Docker, Postgres, and Playwright; twenty leaked test databases from
lanes killed over seventeen hours, cleaned by hand by container age; each
lane running the browser suite the lead's integrated pass repeated.

## Claims

Grades: `[P]` primary read directly · `[S]` secondary · `[?]` unverified ·
`[A]` our own measurement or analysis.

### Ownership and reaping

- `[P]` Testcontainers labels every resource with a session id
  (`org.testcontainers.session-id`) and a sidecar, Ryuk, removes matching
  containers, networks, and volumes by label about 10 s after the owning
  process's connection drops. Reaping survives a SIGKILL of the client
  because the reaper is a separate process. With
  `TESTCONTAINERS_RYUK_DISABLED` the fallback is a shutdown hook that does
  not run on `kill -9`; Ryuk may need to run privileged. (testcontainers)
- `[P]` `docker ps --filter label=k=v` and `docker container prune --filter
  label=k=v` match exactly; same-key filters OR, different keys AND. Compose
  labels `com.docker.compose.project`; the project name comes from `-p`,
  then `COMPOSE_PROJECT_NAME`, then `name:`, then the directory; `compose
  down -v` removes the project's containers, networks, and named volumes,
  never external ones. (docker)
- `[P]` GitHub Actions cancellation sends SIGINT, waits 7.5 s, SIGTERM,
  2.5 s, then kills the process tree; it does not clean up anything the
  job left on a self-hosted runner beyond that. (github)
- `[A]` On this machine at the time of writing: 45 containers; three
  `postgres:17-alpine` from testcontainers-python under three session ids,
  one Ryuk reaper alive, one pytest process alive. The two sessions with no
  process left had containers 8 and 20 minutes old — leaked exactly as
  the transcript describes, despite ownership labels being present. Four
  `playwright-mcp` processes from another repository's session had been
  up 19 h 54 m. Nothing in the scaffold reads either signal:
  `teardown-gate.sh` clears by class and never inspects `docker ps`;
  `workloop.py teardown` removes worktrees and branches only.

### Leases

- `[P]` GitLab `resource_group` runs one job at a time per named resource
  across pipelines; process modes order the queue, never widen it.
  Buildkite `concurrency_group` + `concurrency: N` caps active jobs per
  group. GitHub `concurrency` groups hold one run per group and optionally
  cancel the running one. (gitlab, buildkite, github)
- `[P]` Playwright workers are separate processes each with its own
  browser; a worker that fails is shut down; `lock:` tags and serial
  describe blocks serialise tests on a shared external resource;
  `webServer.reuseExistingServer` reuses a listening server or throws.
  The docs recommend `workers: 1` on CI and give no CPU or memory per
  worker. (playwright)

### Isolation cost

- `[P]` Postgres `CREATE DATABASE … TEMPLATE x` copies the template and
  fails if any session is connected to it. Rails creates one database per
  test worker, suffixed by index. Neon branches are copy-on-write, created
  in about a second, with per-branch compute and a TTL. (postgres, rails,
  neon)
- `[A]` So the cheap per-lane isolation for Postgres is a database per
  lane inside one shared container per run (the Rails shape), not a
  container per lane: no image pull or migration per lane, and the
  template lockout only bites at creation time.

### Liveness versus progress

- `[P]` Kubernetes separates liveness (fail → restart) from readiness
  (fail → out of rotation, no restart): "slow but alive" and "dead" are
  different probes. Temporal activity heartbeats carry an optional
  progress payload, are throttled client-side, and a missed heartbeat
  timeout fails the task and retries with the last payload available.
  (kubernetes, temporal)
- `[A]` The workloop heartbeat is a bare timestamp, and only supervised
  runs require one. "Active but bottlenecked" and "stalled" are the same
  state to the lead.

### Composed verification

- `[P]` GitHub's merge queue runs required checks on the composed
  `merge_group`, not the lone pull request, and on failure removes only
  the failing entry and rebuilds the rest. GitLab merge trains state the
  rationale: two requests can each pass alone and break the branch
  together; a train pipeline that fails cannot be retried because "the
  merged result is out of date". (github, gitlab)
- `[P]` Playwright's `--only-changed` "is a heuristic and might miss
  tests, so it's important that you always run the full test suite after
  the preliminary test run." Nx marks every project affected on a lockfile
  change as a failsafe; Turborepo widens to all packages on a shallow
  checkout. (playwright, nx, turborepo)
- `[P]` Meta: dependency-based selection runs up to a quarter of all tests
  per change; its learned selector runs a third of those at a stated
  regression miss rate under 0.1 %, and needed aggressive retries to tell
  regressions from flakes. (meta, 2018)
- `[P]` Devin, Cursor, and Codex each verify per lane inside its own
  sandbox; none documents a composed step. Claude Code: "Agent teams don't
  isolate teammates in worktrees, so partition the work so each teammate
  owns a different set of files"; cross-checking results is a property of
  dynamic workflows only. (cognition, cursor, openai, claude-code)

## Design conclusions

- Reap by ownership, never by age: label what a lane starts with the run
  and lane, and reap by label when the owner is no longer live — the Ryuk
  rule, with lane liveness in place of a TCP connection. Foreign labels
  (another repository's compose project, another tool's session) are
  reported, never touched.
- Lease what cannot be isolated: a named exclusive resource on `add-lane`
  that `claim` serialises on, the `resource_group` shape.
- Isolate what is cheap: one shared, labelled Postgres per run and a
  database per lane; a compose project name per lane only when a lane
  needs its own stack.
- Heartbeat with a payload, and show it: the digest reports the last
  progress line beside the age, so a slow lane reads as slow.
- A lane runs its narrow acceptance and never the e2e or browser suite;
  `integrate` runs `--verify` once over the composed tree. Every merge
  queue and Playwright's own docs say the same.

## Sources

- https://golang.testcontainers.org/features/garbage_collector/ — read
- https://java.testcontainers.org/features/configuration/ — read
- https://docs.docker.com/reference/cli/docker/container/prune/ · https://docs.docker.com/reference/cli/docker/container/ls/ · https://docs.docker.com/compose/how-tos/project-name/ · https://docs.docker.com/reference/cli/docker/compose/down/ — read
- https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency · https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-cancellation — read
- https://docs.gitlab.com/ci/resource_groups/ · https://docs.gitlab.com/ci/pipelines/merge_trains/ — read
- https://buildkite.com/docs/pipelines/configure/workflows/controlling-concurrency — read
- https://www.postgresql.org/docs/current/sql-createdatabase.html — read
- https://guides.rubyonrails.org/testing.html — parallel-testing section relayed
- https://neon.com/docs/introduction/branching — read
- https://playwright.dev/docs/test-parallel · https://playwright.dev/docs/test-webserver · https://playwright.dev/docs/ci — read
- https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/ — read
- https://docs.temporal.io/encyclopedia/detecting-activity-failures — read
- https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue — read
- https://nx.dev/docs/features/ci-features/affected · https://turborepo.dev/docs/reference/run — read
- https://engineering.fb.com/2018/11/21/developer-tools/predictive-test-selection/ — read (2018-11-21)
- https://cognition.com/blog/devin-can-now-manage-devins — read (2026-03-19)
- https://cursor.com/docs/cloud-agent · https://openai.com/index/introducing-codex/ · https://code.claude.com/docs/en/agents — read
