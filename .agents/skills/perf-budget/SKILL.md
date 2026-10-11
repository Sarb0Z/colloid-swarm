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

Without a budget, a bundle grows 4 KB a week for a year and no one notices. This
skill turns "how big is the bundle, how slow is p95?" into a gate that blocks
when a metric regresses past its agreed tolerance, and so prevents that silent
slow death.

## Rules

- **Metrics without a baseline are noise:** establish the baseline first, gate
  second.
- **The baseline never updates automatically.** Every regression is acknowledged
  by the user.
- **Verdict `broken` blocks the merge**, and only a hard-cap violation earns it.
  Verdict `regressed` warns; the lead decides.
- **Local reproduction outranks remote metrics.** This is a merge gate, not
  observability; production trends belong to the project's APM (Grafana /
  DataDog / …), and the user is pointed there.
- **No package manager or directory layout is assumed.** Commands and lanes come
  from `.agents/perf-budgets.json`; the config is inferred and persisted only
  when it is absent.

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

When the config is missing, infer the lanes from the repository's shape — a web
build target gives `web-bundle`; a mobile app, `mobile-start`; an HTTP service,
`backend-p95` and a body cap; a queue worker or model service, `worker-start`
and `worker-p95` — run them, and then **write the inferred config**, so the next
run is deterministic. The `measure` command comes from the config, or from the
project's native build or test runner as its manifest names it, never from a
hardcoded package manager or directory name.

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

Run only the lanes whose source the diff touches: a CSS-only change needs no
backend load test. Where the reach is unclear, run every configured lane.

### 2. Read the baseline

Load `docs/perf/baseline.json`. **When it is missing, the run is in
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
  hard cap.
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

A baseline update is explicit, per the rules above. When the user approves a
regression as expected (a new feature), write the new value to
`docs/perf/baseline.json` with the reason; otherwise the old baseline stays, and
later runs still gate against it.
