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

Unbudgeted, a bundle grows 4 KB a week for a year and no one notices. This skill turns
"how big is the bundle, how slow is p95?" into a gate that blocks a metric regressing
past its agreed tolerance.

## Hard rules

- **Metrics without a baseline are noise.** Establish the baseline first, gate second.
- **Never update the baseline automatically** — a rolling baseline admits any regression
  taken in instalments; the user must acknowledge each.
- **Verdict `broken` blocks the merge** — hard-cap violations only. Verdict `regressed`
  warns; the lead decides.
- **Prefer local reproduction over remote metrics:** this is a merge gate, not
  observability. Production trends belong to the project's APM (Grafana / DataDog / …);
  point the user there.
- **Do not assume a package manager or directory layout.** Read commands and lanes from
  `.agents/perf-budgets.json`; infer and persist the config only when it is absent.

## Configuration — per repo, not hardcoded

Lanes, their measuring commands, and their budgets live in a repo-local config, so the
skill fits any layout rather than a fixed `apps/*` tree. Look for, in order:

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

If the config is missing, infer lanes from the repository's shape (a web build target →
`web-bundle`; a mobile app → `mobile-start`; an HTTP service → `backend-p95` + body cap; a
queue worker or model service → `worker-start` + `worker-p95`), run them, then **write the
inferred config** so the next run is deterministic. Take each `measure` command from the
config, or the project's native build or test runner from its manifest.

## Budgets (defaults)

The tolerances the config seeds, unless overridden:

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

Run **only** the lanes whose source the diff touches — a CSS-only change spares the
backend load test — and all configured lanes when unsure.

### 2. Read baseline

Load `docs/perf/baseline.json`. **If it is missing, run in `establish-baseline` mode:**
measure every selected lane, write the file, and exit `0`, noting that this run set the
baseline and gated nothing.

### 3. Measure current (lanes in parallel)

- **bundle-size** — run the lane's `measure` build command, then read the main bundle's
  **gzipped** size from the build's stats output (or gzip the emitted artifact and measure).
- **api-p95** — start the service in the background, fire a short load test at each
  configured route, and capture p95 with the load tool the config names (`autocannon`, `k6`,
  `hey`, `wrk`, …).
- **body-cap** — a **spec check, not a runtime measurement**: read the router or body-parser
  config and verify each route's declared body limit is ≤ the hard cap.
- **cold-start** — run the warmup probe and time the first render or first response.

### 4. Diff vs baseline

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

### 6. Update baseline (opt-in)

Update the baseline only when the user approves a regression as expected (a new feature):
write the new value to `docs/perf/baseline.json` with the reason. Otherwise keep the old
baseline, so later runs still gate against it.
