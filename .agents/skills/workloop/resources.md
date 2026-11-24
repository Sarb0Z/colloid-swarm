# Resources a lane starts

Three lanes sharing one Postgres, one Docker daemon, and one machine's browser
capacity are bottlenecked, not stalled, and a lane killed mid-run leaves its
containers behind. The controller answers with ownership, leases, and progress:

- **Ownership.** The brief exports `COLLOID_RUN`, `COLLOID_LANE`, and
  `COMPOSE_PROJECT_NAME=<run>-<lane>`. What only a lane uses carries
  `--label colloid.run=<run> --label colloid.lane=<lane>` or that compose
  project name; what the run shares — the one Postgres — carries `colloid.run`
  alone, so a lane's reap never takes it and `teardown` does. `release-stale`,
  `teardown`, `land` and `reap` remove by those labels, report what docker
  refused, and touch nothing else. The lead's digest reaps a lane whose cell
  stopped without submitting (the hook records every cell's start and stop) and
  names, without removing, test containers that belong to no one — a
  testcontainers session with no reaper. A container a test framework starts
  under its own labels lies outside all this: leave that framework's reaper on.
- **Leases.** `add-lane --exclusive <name>` leases a resource only one active
  lane may hold — `playwright`, a device, a shared service that cannot be
  copied. `claim` refuses while another active lane holds it; the lead
  sequences dispatch, and nothing queues. The lease frees at `submit` or
  `release-stale`; what the holder started stays until `reap` or `teardown`.
  `status` shows each lane's lease, so a misspelt name is visible.
- **Cheap isolation.** One shared, labelled Postgres per run and a database per
  lane named from `COLLOID_LANE` (the shape Rails uses per test worker), not a
  container per lane; give a lane its own compose stack only when it needs one.
- **Progress.** `heartbeat --progress '<what is running>'` works on any claimed
  lane, and the digest and `status` show it beside the lane's age, so a slow
  lane reads as slow.
- **Narrow acceptance.** A lane runs only the narrowest acceptance for its slice,
  never the end-to-end or browser suite; `--verify` runs once over the result:
  at `integrate` or `land` for a run with worktree lanes, one or more, and at
  `land` for a one-writer run. Every merge queue works this way.
