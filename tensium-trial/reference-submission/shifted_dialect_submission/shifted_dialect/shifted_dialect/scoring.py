"""Differential-testing scorer: run a candidate `evaluate` and compare its
outputs to the held-back reference outputs.

The reward is the fraction of held-out programs whose output the candidate
reproduces *exactly*. Crucially, the verdict is computed here in the trusted
parent from ground-truth answers; the sandbox is told only the program strings
and reports only what `evaluate` returned. A pass therefore requires actually
producing the right value -- there is no stdout/self-report channel to trust.
"""

from __future__ import annotations

from collections import Counter

from .sandbox import run_solution


def score_code(
    code: str,
    tests: list[tuple[str, str]] | list[list[str]],
    **sandbox_kwargs,
) -> dict:
    """Return reward and a breakdown for `code` against (program, expected) tests."""
    inputs = [t[0] for t in tests]
    expected = [t[1] for t in tests]
    res = run_solution(code, inputs, **sandbox_kwargs)

    n = len(tests)
    n_correct = 0
    err_counts: Counter[str] = Counter()
    for rec, exp in zip(res.outputs, expected):
        if rec["ok"] and rec["out"] == exp:
            n_correct += 1
        elif not rec["ok"]:
            err_counts[rec.get("err") or "fail"] += 1
        else:
            err_counts["wrong_value"] += 1

    reward = (n_correct / n) if n else 0.0
    return {
        "reward": reward,
        "n": n,
        "n_correct": n_correct,
        "fatal": res.fatal,
        "timed_out": res.timed_out,
        "failure_breakdown": dict(err_counts),
        "stderr": res.stderr if (res.fatal or res.timed_out) else "",
    }


def score_instance(code: str, info: dict, **sandbox_kwargs) -> dict:
    """Score `code` against the held-back tests carried in an instance's info."""
    return score_code(code, info["tests"], **sandbox_kwargs)


def score_detail(
    code: str,
    tests: list[tuple[str, str]] | list[list[str]],
    **sandbox_kwargs,
) -> dict:
    """Like score_code but also returns per-test correctness (aligned to tests),
    so callers can score arbitrary sub-slices (e.g. a selection vs verification
    split) from a single sandbox run."""
    expected = [t[1] for t in tests]
    res = run_solution(code, [t[0] for t in tests], **sandbox_kwargs)
    correct = [bool(rec["ok"] and rec["out"] == exp)
               for rec, exp in zip(res.outputs, expected)]
    n = len(tests)
    return {
        "correct": correct,
        "reward": (sum(correct) / n) if n else 0.0,
        "fatal": res.fatal,
        "timed_out": res.timed_out,
    }
