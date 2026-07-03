"""Random expression generator shared by the spec (worked examples) and the
dataset generator (scored test inputs).

Generated programs are always syntactically valid. Two knobs keep them useful:
  * `**` right operands are forced to small literals so bigint results stay
    bounded (no astronomically large numbers).
  * boundary literals (near the integer-model limits) and explicit `/0`
    sub-expressions are injected so overflow / division-by-zero rules actually
    get exercised.
"""

from __future__ import annotations

import random

from .semantics import ARITH_OPS, COMPARE_OPS, LOGIC_OPS, SemanticParams

_BINARY = ARITH_OPS + COMPARE_OPS + LOGIC_OPS


def _boundary_literals(params: SemanticParams) -> list[int]:
    vals = [0, 1, 2]
    if params.int_model in ("wrap", "saturate", "error"):
        hi = (1 << (params.int_bits - 1)) - 1
        vals += [hi, hi + 1, hi // 2 + 1]
    else:
        vals += [7, 50, 1000]
    return vals


def _atom(rng: random.Random, params: SemanticParams) -> str:
    r = rng.random()
    if r < 0.12:
        return rng.choice(["true", "false"])
    if r < 0.30:
        return str(rng.choice(_boundary_literals(params)))
    return str(rng.randint(0, 20))


def random_expr(rng: random.Random, params: SemanticParams, depth: int) -> str:
    """A syntactically valid program of roughly `depth` nesting."""
    if depth <= 0 or rng.random() < 0.28:
        return _atom(rng, params)

    roll = rng.random()
    if roll < 0.18:  # prefix unary
        op = rng.choice(["-", "!"])
        return f"{op}({random_expr(rng, params, depth - 1)})"
    if roll < 0.26:  # explicit division by zero, to exercise that rule
        num = random_expr(rng, params, depth - 1)
        return f"({num}{rng.choice(['/', '%'])}0)"

    op = rng.choice(_BINARY)
    left = random_expr(rng, params, depth - 1)
    if op == "**":
        # keep exponents tiny so values stay bounded
        right = str(rng.randint(0, 5))
    else:
        right = random_expr(rng, params, depth - 1)
    return f"({left}{op}{right})"


def sample_programs(
    seed: int, params: SemanticParams, n: int, depth: int = 4
) -> list[str]:
    """Deterministically sample `n` distinct programs."""
    rng = random.Random(f"exprgen/{params.seed}/{params.difficulty}/{seed}")
    seen: set[str] = set()
    out: list[str] = []
    tries = 0
    while len(out) < n and tries < n * 50:
        tries += 1
        e = random_expr(rng, params, depth)
        if e not in seen and 1 <= len(e) <= 120:
            seen.add(e)
            out.append(e)
    return out
