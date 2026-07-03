"""Small, dependency-free statistics helpers used across the analysis scripts.

Wilson score intervals for binomial rates (never report a bare 0%), and a
simple percentile bootstrap for means.
"""

from __future__ import annotations

import math
import random

Z95 = 1.959963984540054


def wilson(k: int, n: int, z: float = Z95) -> tuple[float, float]:
    """95% Wilson score interval for a binomial proportion k/n."""
    if n == 0:
        return (0.0, 1.0)
    phat = k / n
    z2 = z * z
    denom = 1 + z2 / n
    center = (phat + z2 / (2 * n)) / denom
    half = (z * math.sqrt(phat * (1 - phat) / n + z2 / (4 * n * n))) / denom
    return (max(0.0, center - half), min(1.0, center + half))


def rate_report(k: int, n: int) -> dict:
    lo, hi = wilson(k, n)
    return {"k": k, "n": n, "rate": (k / n if n else 0.0),
            "ci95": [round(lo, 4), round(hi, 4)]}


def bootstrap_mean_ci(xs: list[float], iters: int = 5000, z: float = Z95,
                      seed: int = 0) -> tuple[float, float, float]:
    """Return (mean, lo, hi) with a percentile bootstrap 95% CI."""
    if not xs:
        return (0.0, 0.0, 0.0)
    n = len(xs)
    mean = sum(xs) / n
    if n == 1:
        return (mean, mean, mean)
    rng = random.Random(seed)
    means = []
    for _ in range(iters):
        s = sum(xs[rng.randrange(n)] for _ in range(n)) / n
        means.append(s)
    means.sort()
    lo = means[int(0.025 * iters)]
    hi = means[int(0.975 * iters)]
    return (mean, lo, hi)
