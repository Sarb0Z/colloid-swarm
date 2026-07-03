"""Soundness receipt (Template Tier-1, requirement #1).

Runs the cheat battery + honest controls through the verifier across many
instances and reports:
  * false-accept rate (FAR): a cheat scored as passing (reward >= TAU), Wilson CI
  * false-reject rate (FRR): an honest correct solution scored as failing, Wilson CI
  * per-cheat-class exploit value (mean reward with bootstrap CI, and max)
  * any cheat class that still passes, named explicitly
  * a tight-timeout stress run to bound harness-induced false rejects

Run (from the project root, with the package importable):
    python -m analysis.soundness --instances 30 --workers 8
Outputs analysis/out/soundness.{json,md}.
"""

from __future__ import annotations

import argparse
import json
import os
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor

from shifted_dialect.generate import make_instance
from shifted_dialect.scoring import score_code

from analysis.cheats import CHEATS, HONEST
from analysis.stats import bootstrap_mean_ci, rate_report

TAU = 0.95          # "accepted" threshold: must reproduce >= 95% of outputs
DIFFS = ("easy", "medium", "hard")
OUT_DIR = os.path.join(os.path.dirname(__file__), "out")


def _instances(n: int, n_tests: int) -> list[dict]:
    out = []
    for i in range(n):
        out.append(make_instance(i, DIFFS[i % len(DIFFS)], n_tests=n_tests))
    return out


def _score_one(job: dict) -> dict:
    code = job.pop("_code")
    tests = job.pop("_tests")
    kw = job.pop("_kw")
    r = score_code(code, tests, **kw)
    job["reward"] = r["reward"]
    job["fatal"] = r["fatal"]
    job["timed_out"] = r["timed_out"]
    return job


def run(n_instances: int = 30, n_tests: int = 80, workers: int = 8) -> dict:
    instances = _instances(n_instances, n_tests)
    normal_kw = {"per_call_timeout": 0.5, "total_timeout": 20.0}
    tight_kw = {"per_call_timeout": 0.05, "total_timeout": 8.0, "cpu_seconds": 4}

    jobs: list[dict] = []
    for inst in instances:
        tests = inst["info"]["tests"]
        iid = inst["example_id"]
        for h in HONEST:
            jobs.append({"kind": "honest", "cls": "honest", "name": h["name"],
                         "iid": iid, "_code": h["factory"](inst), "_tests": tests,
                         "_kw": dict(normal_kw)})
        # honest reference under a tight timeout: harness-FRR stress
        jobs.append({"kind": "honest_tight", "cls": "honest_tight",
                     "name": "honest_reference", "iid": iid,
                     "_code": HONEST[0]["factory"](inst), "_tests": tests,
                     "_kw": dict(tight_kw)})
        for c in CHEATS:
            jobs.append({"kind": "cheat", "cls": c["cls"], "name": c["name"],
                         "iid": iid, "_code": c["factory"](inst), "_tests": tests,
                         "_kw": dict(normal_kw)})

    with ThreadPoolExecutor(max_workers=workers) as ex:
        results = list(ex.map(_score_one, jobs))

    honest = [r for r in results if r["kind"] == "honest"]
    honest_tight = [r for r in results if r["kind"] == "honest_tight"]
    cheats = [r for r in results if r["kind"] == "cheat"]

    # FAR / FRR
    far_accept = sum(1 for r in cheats if r["reward"] >= TAU)
    frr_reject = sum(1 for r in honest if r["reward"] < TAU)
    frr_tight_reject = sum(1 for r in honest_tight if r["reward"] < TAU)

    # per-cheat-class exploit value
    by_class: dict[str, list[float]] = defaultdict(list)
    for r in cheats:
        by_class[r["cls"]].append(r["reward"])
    class_stats = {}
    surviving = []
    for cls, rewards in sorted(by_class.items()):
        mean, lo, hi = bootstrap_mean_ci(rewards, seed=1)
        n_acc = sum(1 for x in rewards if x >= TAU)
        class_stats[cls] = {
            "n": len(rewards), "mean_reward": round(mean, 4),
            "mean_ci95": [round(lo, 4), round(hi, 4)],
            "max_reward": round(max(rewards), 4),
            "n_accepted": n_acc,
        }
        if max(rewards) >= TAU:
            surviving.append(cls)

    honest_rewards = [r["reward"] for r in honest]
    h_mean, h_lo, h_hi = bootstrap_mean_ci(honest_rewards, seed=2)

    report = {
        "config": {"n_instances": n_instances, "n_tests": n_tests, "tau_accept": TAU},
        "false_accept": rate_report(far_accept, len(cheats)),
        "false_reject": rate_report(frr_reject, len(honest)),
        "false_reject_tight_timeout": rate_report(frr_tight_reject, len(honest_tight)),
        "honest_mean_reward": {"mean": round(h_mean, 4),
                               "ci95": [round(h_lo, 4), round(h_hi, 4)],
                               "min": round(min(honest_rewards), 4)},
        "surviving_cheat_classes": surviving,
        "per_class": class_stats,
    }
    return report


def to_markdown(rep: dict) -> str:
    cfg = rep["config"]
    fa, fr, frt = rep["false_accept"], rep["false_reject"], rep["false_reject_tight_timeout"]
    lines = [
        "# Soundness receipt — shifted_dialect",
        "",
        f"- instances: **{cfg['n_instances']}**, scored programs/instance: "
        f"**{cfg['n_tests']}**, acceptance threshold tau = **{cfg['tau_accept']}**",
        f"- cheat trials: **{fa['n']}**, honest trials: **{fr['n']}**",
        "",
        "## Headline rates (95% Wilson CI)",
        "",
        f"- **False-accept rate**: {fa['k']}/{fa['n']} = {fa['rate']:.4f} "
        f"(CI {fa['ci95'][0]:.4f}–{fa['ci95'][1]:.4f})",
        f"- **False-reject rate**: {fr['k']}/{fr['n']} = {fr['rate']:.4f} "
        f"(CI {fr['ci95'][0]:.4f}–{fr['ci95'][1]:.4f})",
        f"- **False-reject under tight (50ms) timeout**: {frt['k']}/{frt['n']} = "
        f"{frt['rate']:.4f} (CI {frt['ci95'][0]:.4f}–{frt['ci95'][1]:.4f})",
        f"- honest mean reward: {rep['honest_mean_reward']['mean']:.4f} "
        f"(min {rep['honest_mean_reward']['min']:.4f})",
        "",
        f"- **Surviving cheat classes (max reward >= tau)**: "
        f"{rep['surviving_cheat_classes'] or 'none'}",
        "",
        "## Exploit value by cheat class",
        "",
        "| class | n | mean reward | 95% CI | max reward | accepted |",
        "|---|---|---|---|---|---|",
    ]
    for cls, s in rep["per_class"].items():
        lines.append(
            f"| {cls} | {s['n']} | {s['mean_reward']:.4f} | "
            f"{s['mean_ci95'][0]:.4f}–{s['mean_ci95'][1]:.4f} | "
            f"{s['max_reward']:.4f} | {s['n_accepted']} |")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--instances", type=int, default=30)
    ap.add_argument("--tests", type=int, default=80)
    ap.add_argument("--workers", type=int, default=8)
    args = ap.parse_args()

    rep = run(args.instances, args.tests, args.workers)
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(os.path.join(OUT_DIR, "soundness.json"), "w") as f:
        json.dump(rep, f, indent=2)
    md = to_markdown(rep)
    with open(os.path.join(OUT_DIR, "soundness.md"), "w") as f:
        f.write(md)
    print(md)


if __name__ == "__main__":
    main()
