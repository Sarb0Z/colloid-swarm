"""Turn raw rollouts into the capability leaderboard + best-of-N + variance
report (Template requirements #2, #3, #5).

Reads analysis/out/rollouts.jsonl and writes analysis/out/leaderboard.{json,md}.
Re-runnable without spending API budget.
"""

from __future__ import annotations

import json
import os
from collections import defaultdict
from itertools import combinations

from analysis.stats import bootstrap_mean_ci, rate_report

OUT_DIR = os.path.join(os.path.dirname(__file__), "out")
ROLLOUTS_PATH = os.path.join(OUT_DIR, "rollouts.jsonl")
SOLVE_TAU = 0.95
MODEL_ORDER = ["llama-3.1-8b-instant", "llama-3.3-70b-versatile",
               "qwen/qwen3-32b", "openai/gpt-oss-120b"]


def load() -> list[dict]:
    with open(ROLLOUTS_PATH) as f:
        return [json.loads(line) for line in f if line.strip()]


def _expected_best_of_n(rewards_s: list[float], rewards_v: list[float]):
    """For n=1..len, expected (over size-n subsets) best-by-S reward, and the V
    reward of that S-argmax solution. Returns (curve_s, curve_v)."""
    R = len(rewards_s)
    curve_s, curve_v = [], []
    for n in range(1, R + 1):
        sel_s, sel_v = [], []
        for combo in combinations(range(R), n):
            best = max(combo, key=lambda i: rewards_s[i])
            sel_s.append(rewards_s[best])
            sel_v.append(rewards_v[best])
        curve_s.append(sum(sel_s) / len(sel_s))
        curve_v.append(sum(sel_v) / len(sel_v))
    return curve_s, curve_v


def analyze(rows: list[dict]) -> dict:
    models = [m for m in MODEL_ORDER if any(r["model"] == m for r in rows)]
    models += [m for m in {r["model"] for r in rows} if m not in models]

    # index
    valid = defaultdict(lambda: defaultdict(list))   # model -> problem -> [reward_s]
    valid_v = defaultdict(lambda: defaultdict(list))  # model -> problem -> [reward_v]
    per_diff = defaultdict(lambda: defaultdict(list))  # model -> diff -> [reward_s]
    counts = defaultdict(lambda: {"total": 0, "errors": 0, "truncated": 0, "no_code": 0})
    sample_error: dict[str, str] = {}
    for r in rows:
        m = r["model"]
        counts[m]["total"] += 1
        if r["error"] is not None or r["reward_s"] is None:
            counts[m]["errors"] += 1
            if r.get("error") and m not in sample_error:
                sample_error[m] = r["error"]
            continue
        if r["finish_reason"] == "length":
            counts[m]["truncated"] += 1
        if not r["had_code"]:
            counts[m]["no_code"] += 1
        valid[m][r["problem_id"]].append(r["reward_s"])
        valid_v[m][r["problem_id"]].append(r["reward_v"])
        per_diff[m][r["difficulty"]].append(r["reward_s"])

    model_stats = {}
    problem_means = {}  # model -> {problem: mean_reward_s}
    for m in models:
        probs = valid[m]
        pmeans = {p: sum(v) / len(v) for p, v in probs.items()}
        problem_means[m] = pmeans
        vec = list(pmeans.values())
        mean, lo, hi = bootstrap_mean_ci(vec, seed=7) if vec else (0.0, 0.0, 0.0)
        all_rollouts = [x for v in probs.values() for x in v]
        n_solved = sum(1 for x in all_rollouts if x >= SOLVE_TAU)
        model_stats[m] = {
            "n_problems": len(probs),
            "n_valid_rollouts": len(all_rollouts),
            "counts": counts[m],
            "mean_reward": round(mean, 4),
            "mean_ci95": [round(lo, 4), round(hi, 4)],
            "solve_rate": rate_report(n_solved, len(all_rollouts)),
            "per_difficulty": {d: round(sum(xs) / len(xs), 4)
                               for d, xs in sorted(per_diff[m].items()) if xs},
        }

    # models with no valid rollouts are excluded for cause (e.g. token cap)
    excluded = {m: {"reason": sample_error.get(m, "no valid rollouts"),
                    "errors": counts[m]["errors"], "total": counts[m]["total"]}
                for m in models if model_stats[m]["n_valid_rollouts"] == 0}
    ranked = [m for m in models if model_stats[m]["n_valid_rollouts"] > 0]

    # rank by CI lower bound (template requirement #2)
    ranking = sorted(ranked, key=lambda m: model_stats[m]["mean_ci95"][0], reverse=True)

    # pairwise significance on paired problem-level means (shared problems)
    pairwise = []
    for a, b in zip(ranking, ranking[1:]):
        shared = sorted(set(problem_means[a]) & set(problem_means[b]))
        diffs = [problem_means[a][p] - problem_means[b][p] for p in shared]
        mean_d, lo_d, hi_d = bootstrap_mean_ci(diffs, seed=11) if diffs else (0, 0, 0)
        pairwise.append({
            "higher": a, "lower": b, "n_shared_problems": len(shared),
            "mean_diff": round(mean_d, 4), "diff_ci95": [round(lo_d, 4), round(hi_d, 4)],
            "significant": lo_d > 0,
        })

    # best-of-N curves (requirement #3): selection on S, quality measured on V
    bestofn = {}
    for m in models:
        curves_s, curves_v = [], []
        maxR = 0
        for p in valid[m]:
            rs, rv = valid[m][p], valid_v[m][p]
            if len(rs) >= 2:
                cs, cv = _expected_best_of_n(rs, rv)
                curves_s.append(cs)
                curves_v.append(cv)
                maxR = max(maxR, len(cs))
        if not curves_s:
            continue
        # average across problems at each n (only problems with >= n rollouts)
        agg_s, agg_v, gap = [], [], []
        for n in range(maxR):
            s_vals = [c[n] for c in curves_s if len(c) > n]
            v_vals = [c[n] for c in curves_v if len(c) > n]
            agg_s.append(round(sum(s_vals) / len(s_vals), 4))
            agg_v.append(round(sum(v_vals) / len(v_vals), 4))
            gap.append(round(agg_s[-1] - agg_v[-1], 4))
        bestofn[m] = {"n": list(range(1, maxR + 1)), "reward_S": agg_s,
                      "reward_V": agg_v, "S_minus_V": gap}

    # variance / stability (requirement #5) for the top model
    top = ranking[0]
    var_rows = []
    for p, xs in valid[top].items():
        if len(xs) >= 2:
            mu = sum(xs) / len(xs)
            var = sum((x - mu) ** 2 for x in xs) / (len(xs) - 1)
            var_rows.append({"problem": p, "n": len(xs), "mean": round(mu, 4),
                             "std": round(var ** 0.5, 4)})
    var_rows.sort(key=lambda r: r["std"], reverse=True)
    stds = [r["std"] for r in var_rows]
    high_var = [r for r in var_rows if r["std"] >= 0.15]

    return {
        "config": {"models": models, "solve_tau": SOLVE_TAU},
        "model_stats": model_stats,
        "ranking_by_ci_lower": ranking,
        "excluded_models": excluded,
        "pairwise_significance": pairwise,
        "best_of_n": bestofn,
        "variance_top_model": {
            "model": top,
            "median_std": round(sorted(stds)[len(stds) // 2], 4) if stds else 0.0,
            "n_high_variance_problems": len(high_var),
            "high_variance": high_var[:8],
        },
    }


def to_markdown(rep: dict) -> str:
    L = ["# Capability leaderboard — shifted_dialect", ""]
    L.append("Held-out problems, scored through the same verifier the env uses. "
             "Reward = fraction of held-out programs reproduced exactly. Ranked "
             "by the **lower bound** of the 95% bootstrap CI.")
    L.append("")
    L.append("| rank | model | mean reward | 95% CI | solve@0.95 | easy/med/hard | valid | trunc | err |")
    L.append("|---|---|---|---|---|---|---|---|---|")
    for i, m in enumerate(rep["ranking_by_ci_lower"], 1):
        s = rep["model_stats"][m]
        pd = s["per_difficulty"]
        emh = "/".join(f"{pd.get(d, float('nan')):.2f}" for d in ("easy", "medium", "hard"))
        sr = s["solve_rate"]
        L.append(f"| {i} | {m} | {s['mean_reward']:.3f} | "
                 f"{s['mean_ci95'][0]:.3f}–{s['mean_ci95'][1]:.3f} | "
                 f"{sr['rate']:.2f} ({sr['ci95'][0]:.2f}–{sr['ci95'][1]:.2f}) | {emh} | "
                 f"{s['n_valid_rollouts']} | {s['counts']['truncated']} | {s['counts']['errors']} |")
    if rep.get("excluded_models"):
        L += ["", "**Excluded for cause** (measurement hygiene):"]
        for m, info in rep["excluded_models"].items():
            L.append(f"- `{m}`: {info['errors']}/{info['total']} calls failed — "
                     f"{info['reason'][:140]}")
    L += ["", "## Pairwise separation (paired bootstrap on shared problems)", ""]
    for pw in rep["pairwise_significance"]:
        sig = "**significant**" if pw["significant"] else "not significant"
        L.append(f"- {pw['higher']} > {pw['lower']}: Δ={pw['mean_diff']:.3f} "
                 f"(CI {pw['diff_ci95'][0]:.3f}–{pw['diff_ci95'][1]:.3f}) — {sig}")
    L += ["", "## Best-of-N: verifier reward (selection set S) vs held-out quality (set V)", "",
          "If reward on S climbs under search while quality on the disjoint set V "
          "stays flat, the verifier is being gamed. Here they track, because the "
          "model never sees any test inputs and a selected solution is a genuine "
          "general implementation.", ""]
    for m, bo in rep["best_of_n"].items():
        L.append(f"- **{m}**  n={bo['n']}")
        L.append(f"    - reward_S: {bo['reward_S']}")
        L.append(f"    - reward_V: {bo['reward_V']}")
        L.append(f"    - S−V gap : {bo['S_minus_V']}")
    v = rep["variance_top_model"]
    L += ["", f"## Variance / stability (top model: {v['model']})", "",
          f"- median per-problem std (over rollouts): {v['median_std']}",
          f"- high-variance problems (std ≥ 0.15): {v['n_high_variance_problems']}"]
    for r in v["high_variance"]:
        L.append(f"    - {r['problem']}: mean {r['mean']:.2f}, std {r['std']:.2f}, n={r['n']}")
    return "\n".join(L) + "\n"


def main():
    rows = load()
    rep = analyze(rows)
    with open(os.path.join(OUT_DIR, "leaderboard.json"), "w") as f:
        json.dump(rep, f, indent=2)
    md = to_markdown(rep)
    with open(os.path.join(OUT_DIR, "leaderboard.md"), "w") as f:
        f.write(md)
    print(md)


if __name__ == "__main__":
    main()
