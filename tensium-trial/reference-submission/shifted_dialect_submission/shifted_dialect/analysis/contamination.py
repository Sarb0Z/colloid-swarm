"""Contamination / leakage receipt.

The core argument is constructive: instances are produced by a seeded generator,
so the specific dialects never existed before generation, and train/eval come
from disjoint seed ranges. This script backs that with numbers:

  1. dialect-fingerprint overlap between train and eval (should be 0);
  2. an estimate of the dialect space size (collisions are astronomically
     unlikely);
  3. a leakage probe: even when the *same program string* appears in both a
     train and an eval instance, its expected output usually differs (different
     dialect), so memorising train (program -> output) pairs actively misleads
     on eval. Program identity carries almost no transferable signal.

Run: python -m analysis.contamination
"""

from __future__ import annotations

import json
import math
import os
from collections import defaultdict

from shifted_dialect.generate import build_dataset

OUT_DIR = os.path.join(os.path.dirname(__file__), "out")


def dialect_space_lower_bound() -> float:
    """Conservative lower bound on the number of distinct dialects."""
    # scalar (non-precedence) choices actually sampled
    scalar = (4 * 4   # int_model x int_bits
              * 3 * 3  # div_round x div_zero
              * 3      # pow_negative_exp
              * 2 * 3  # compare_result x compare_chain
              * 2 * 2 * 2  # shortcircuit x logic_return x truthy
              * 2)     # mix_bool_int
    # precedence: 8 arith/logic ops assigned to ordered tiers with per-tier
    # associativity, plus a comparison tier and a unary tier inserted anywhere.
    # Lower-bound it by: orderings of the 8 ops into a sequence (8!) times
    # associativity for ~6 tiers (2^6) times unary/comparison placements (~7*7).
    precedence = math.factorial(8) * (2 ** 6) * 7 * 7
    return scalar * precedence


def ngram_jaccard(a: str, b: str, n: int = 5) -> float:
    A = {a[i:i + n] for i in range(len(a) - n + 1)}
    B = {b[i:i + n] for i in range(len(b) - n + 1)}
    if not A or not B:
        return 0.0
    return len(A & B) / len(A | B)


def run(n_per_diff: int = 20, n_tests: int = 80) -> dict:
    train = build_dataset(n_per_diff, start_seed=0, n_tests=n_tests)
    eval_ = build_dataset(n_per_diff, start_seed=1_000_000, n_tests=n_tests)

    # 1. fingerprint overlap
    train_fp = {r["answer"] for r in train}
    eval_fp = {r["answer"] for r in eval_}
    fp_overlap = train_fp & eval_fp

    # spec exact-duplicate check
    train_specs = {r["question"] for r in train}
    spec_dups = sum(1 for r in eval_ if r["question"] in train_specs)

    # 2. space size
    space = dialect_space_lower_bound()

    # 3. leakage probe: program -> set of expected outputs in train
    train_prog = defaultdict(set)
    for r in train:
        for prog, exp in r["info"]["tests"]:
            train_prog[prog].add(exp)
    eval_pairs = [(prog, exp) for r in eval_ for prog, exp in r["info"]["tests"]]
    shared = [(p, e) for p, e in eval_pairs if p in train_prog]
    # of eval programs also seen in train, how often does a train label match?
    memorizer_right = sum(1 for p, e in shared if e in train_prog[p])
    distinct_outputs = [len(train_prog[p]) for p, _ in shared]
    avg_distinct = (sum(distinct_outputs) / len(distinct_outputs)) if distinct_outputs else 0.0

    # spec n-gram similarity: random train/eval spec pair vs same-template floor
    import random
    rng = random.Random(0)
    sims = [ngram_jaccard(rng.choice(train)["question"], rng.choice(eval_)["question"])
            for _ in range(50)]
    avg_spec_sim = sum(sims) / len(sims)

    return {
        "config": {"n_per_diff": n_per_diff, "n_tests": n_tests,
                   "train_instances": len(train), "eval_instances": len(eval_)},
        "fingerprint_overlap_train_eval": len(fp_overlap),
        "spec_exact_duplicates_eval_in_train": spec_dups,
        "dialect_space_lower_bound": f"{space:.3e}",
        "leakage_probe": {
            "eval_test_pairs": len(eval_pairs),
            "eval_programs_also_in_train": len(shared),
            "memorizer_correct_among_shared": memorizer_right,
            "memorizer_accuracy_on_shared": round(memorizer_right / len(shared), 4) if shared else None,
            "overall_memorizer_accuracy_on_eval": round(memorizer_right / len(eval_pairs), 4) if eval_pairs else None,
            "avg_distinct_train_outputs_per_shared_program": round(avg_distinct, 3),
            "note": ("A program seen in training maps to ~this many different "
                     "outputs across dialects, so its identity does not reveal "
                     "its label in a new dialect."),
        },
        "avg_spec_ngram_jaccard_train_eval": round(avg_spec_sim, 4),
    }


def main():
    rep = run()
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(os.path.join(OUT_DIR, "contamination.json"), "w") as f:
        json.dump(rep, f, indent=2)
    print(json.dumps(rep, indent=2))


if __name__ == "__main__":
    main()
