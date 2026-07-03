# Capability leaderboard — shifted_dialect

Held-out problems, scored through the same verifier the env uses. Reward = fraction of held-out programs reproduced exactly. Ranked by the **lower bound** of the 95% bootstrap CI.

| rank | model | mean reward | 95% CI | solve@0.95 | easy/med/hard | valid | trunc | err |
|---|---|---|---|---|---|---|---|---|
| 1 | openai/gpt-oss-120b | 0.501 | 0.398–0.605 | 0.04 (0.01–0.18) | 0.42/0.57/0.51 | 27 | 8 | 0 |
| 2 | llama-3.1-8b-instant | 0.158 | 0.107–0.204 | 0.00 (0.00–0.12) | 0.13/0.16/0.18 | 27 | 2 | 0 |
| 3 | llama-3.3-70b-versatile | 0.173 | 0.078–0.264 | 0.00 (0.00–0.30) | 0.17/0.17/0.18 | 9 | 0 | 18 |

**Excluded for cause** (measurement hygiene):
- `qwen/qwen3-32b`: 27/27 calls failed — APIStatusError: Error code: 413 - {'error': {'message': 'Request too large for model `qwen/qwen3-32b` in organization `org_01k596gap4eqp

## Pairwise separation (paired bootstrap on shared problems)

- openai/gpt-oss-120b > llama-3.1-8b-instant: Δ=0.344 (CI 0.220–0.458) — **significant**
- llama-3.1-8b-instant > llama-3.3-70b-versatile: Δ=-0.016 (CI -0.074–0.053) — not significant

## Best-of-N: verifier reward (selection set S) vs held-out quality (set V)

If reward on S climbs under search while quality on the disjoint set V stays flat, the verifier is being gamed. Here they track, because the model never sees any test inputs and a selected solution is a genuine general implementation.

- **llama-3.1-8b-instant**  n=[1, 2, 3]
    - reward_S: [0.1578, 0.2481, 0.2911]
    - reward_V: [0.1309, 0.2111, 0.2444]
    - S−V gap : [0.0269, 0.037, 0.0467]
- **openai/gpt-oss-120b**  n=[1, 2, 3]
    - reward_S: [0.5015, 0.7096, 0.7667]
    - reward_V: [0.5185, 0.7407, 0.7815]
    - S−V gap : [-0.017, -0.0311, -0.0148]

## Variance / stability (top model: openai/gpt-oss-120b)

- median per-problem std (over rollouts): 0.3811
- high-variance problems (std ≥ 0.15): 7
    - medium-1000002: mean 0.57, std 0.52, n=3
    - easy-1000001: mean 0.57, std 0.50, n=3
    - easy-1000000: mean 0.25, std 0.44, n=3
    - medium-1000001: mean 0.49, std 0.43, n=3
    - easy-1000002: mean 0.44, std 0.38, n=3
    - hard-1000001: mean 0.42, std 0.36, n=3
    - hard-1000002: mean 0.33, std 0.28, n=3
