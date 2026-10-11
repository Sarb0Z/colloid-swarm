---
name: perf-budget
description: >
  Baseline-diff performance gate. Reads a stored baseline, measures the current build per
  lane (web bundle size, mobile cold-start, backend API p95, worker/AI cold-start & p95),
  computes the delta percentage, blocks on a hard-cap violation, warns on a regression past
  tolerance, and establishes the baseline on first run. Lanes, commands, and budgets live in
  a per-repo config so it adapts to any layout. Use when the user types "perf-budget",
  "/perf-budget", "did I regress perf", "check bundle size", "startup time regression",
  "api latency budget", or before merging a perf-sensitive change.
---

# Perf budget

Prevent the silent slow death. Without a budget a bundle grows 4 KB a week for
a year and no one notices, because no single week is worth noticing. This skill
turns "how big is the bundle, how slow is p95?" into a gate that blocks when a
metric regresses past its agreed tolerance.

## Hard rules

- **Metrics without a baseline are noise.** A number alone says nothing about
  direction; establish the baseline first, gate second.
- **Never update the baseline automatically.** A regression must be
  acknowledged by the user. A baseline that follows every run measures each
  week against the last, and 4 KB on a 300 KB bundle is 1.3 % — under a 5 %
  tolerance every week, for ever.
- **Verdict `broken` blocks the merge** — hard-cap violations only. Verdict
  `regressed` warns; the lead decides.
- **Prefer local reproduction over remote metrics.** This is a merge gate, and a
  gate must answer before the merge; production telemetry answers after the
  ship. Point the user at the project's APM (Grafana / DataDog / …) for
  production trends.
- **Do not assume a package manager or directory layout.** Read commands and
  lanes from `.agents/perf-budgets.json`; infer and persist the config only when
  it is absent. The skill is exported to repositories whose package managers and
  layouts differ, and a guessed command measures nothing, or the wrong tree.

## Configuration — per repo, not hardcoded

Lanes, the commands that measure them, and their budgets live in a repo-local
config, so the skill fits any layout rather than assuming a fixed `apps/*` tree.
Look for, in order:

1. `.agents/perf-budgets.json` — lane definitions + budgets (preferred)
2. `docs/perf/baseline.json` — the measured baseline values

`.agents/perf-budgets.json` shape:

```json
{
  "lanes": {
    "web-bundle":     { "kind": "bundle-size", "measure": "<build cmd>", "artifact": "<stats file or dist glob>", "tolerance_pct": 5 },
    "mobile-start":   { "kind": "cold-start",  "measure": "<startup probe>",                                       "tolerance_pct": 10 },
    "backend-p95":    { "kind": "api-p95",     "measure": "<load-test cmd>", "routes": ["POST /orders"],           "tolerance_pct": 15 },
    "backend-body":   { "kind": "body-cap",    "source": "<router/config path>",                                  "hard_cap_kb": 256 },
    "worker-start":   { "kind": "cold-start",  "measure": "<warmup probe>",                                        "tolerance_pct": 15 },
    "worker-p95":     { "kind": "api-p95",     "measure": "<batch probe>",                                         "tolerance_pct": 15 }
  }
}
```

If the config is missing, infer the lanes from the repository's shape — a web
build target gives `web-bundle`; a mobile app, `mobile-start`; an HTTP service,
`backend-p95` and a body cap; a queue worker or model service, `worker-start`
and `worker-p95` — run them, then **write the inferred config**, so the next run
is deterministic: an inference repeated each run can land on a different lane
set, and a diff across two lane sets compares nothing. Do not hardcode a package
manager or a directory name — read the `measure` command from the config, or
pick the project's native build or test runner from its manifest.

## Budgets (defaults)

The tolerances the config seeds unless overridden:

| Lane kind    | Metric                                            | Tolerance |
|--------------|---------------------------------------------------|-----------|
| `bundle-size`| Web JS main-bundle **gzipped** size               | **+5 %**  |
| `cold-start` | Mobile cold-start (JS → first render)             | **+10 %** |
| `api-p95`    | Backend API p95 latency, per top route            | **+15 %** |
| `body-cap`   | Per-route request-body size                       | **hard cap** (absolute, spec check) |
| `cold-start` | Worker / AI-engine cold-start                     | **+15 %** |
| `api-p95`    | Worker / AI-engine per-request p95                | **+15 %** |

## Procedure

### 1. Select lanes

Run **only** the lanes whose source the diff touches: a CSS-only change does
not need the backend load test. When unsure, run all configured lanes; a lane
skipped by mistake is a regression waved through.

### 2. Read the baseline

Load `docs/perf/baseline.json`. **If it is missing, switch to
`establish-baseline` mode:** measure every selected lane, write the file, and
exit `0` with a note that this run set the baseline and gated nothing.

### 3. Measure the current build (lanes in parallel)

- **bundle-size** — run the lane's `measure` build command, then read the
  **gzipped** size of the main bundle from the build's stats output, or gzip the
  emitted artifact and measure it.
- **api-p95** — start the service in the background, fire a short load test at
  each configured route, and capture p95 with whatever load tool the config
  names (`autocannon`, `k6`, `hey`, `wrk`, …).
- **body-cap** — a **spec check, not a runtime measurement**: read the router or
  body-parser config and verify that each route's declared body limit is ≤ the
  hard cap. The cap guards what the service will accept, which the declaration
  states exactly and a load test only samples.
- **cold-start** — run the warmup probe and time the first render or first
  response.

### 4. Diff against the baseline

For each measured metric:

```
delta_pct = (current - baseline) / baseline * 100
```

| Condition                              | Verdict       |
|----------------------------------------|---------------|
| `delta_pct <= 0`                       | improved (log for posterity) |
| `0 < delta_pct <= tolerance`           | within budget |
| `delta_pct > tolerance`                | **over budget** → regressed |
| body-cap: declared limit > hard cap    | **broken** (hard-cap violation) |

### 5. Report

Save to `docs/perf/report-<YYYY-MM-DD>.md`.

```markdown
# perf-budget — 2026-07-22

**Verdict:** ok | regressed(<n>) | broken(<n>)

| Metric                          | Baseline | Current | Δ       | Verdict     |
|---------------------------------|----------|---------|---------|-------------|
| web-bundle main.js gzip         | 312 KB   | 341 KB  | +9.3 %  | over budget |
| backend POST /orders p95        | 120 ms   | 128 ms  | +6.7 %  | within      |
| mobile cold-start               | 810 ms   | 880 ms  | +8.6 %  | within      |
| worker /summarize p95           | 1.4 s    | 1.9 s   | +35 %   | over budget |

## Regressions
- web-bundle main.js gzip: +29 KB. Likely culprit: a full `lodash` import.
  Suggest: `import debounce from 'lodash/debounce'` or a vanilla helper.
- worker /summarize p95: +500 ms. Likely culprit: a new synchronous call in the critical path.
```

### 6. Update the baseline (opt-in)

Baseline updates are **explicit, never automatic**. If the user confirms a
regression is expected (a new feature), update `docs/perf/baseline.json` with
the new value and note why. Otherwise keep the old baseline, so later runs still
gate against it — the regression nobody accepted stays visible until someone
does.
