"""Semantic parameter space for the shifted-dialect environment.

Every task instance is a small expression language whose *surface syntax* is
fixed and familiar (C-style infix integers and booleans) but whose *semantics*
are sampled from a seed. The point is to break the model's priors: it cannot
fall back on "this is like Python/JS/C", because the precedence table,
associativity, integer model, division rounding, comparison behaviour and
error model are all randomised per instance and stated explicitly in the spec.

`SemanticParams` is the single source of truth. The same object is consumed by:
  - oracle.py   -> the held-back reference interpreter (ground truth)
  - spec.py     -> the human-readable specification shown to the model

Because both are generated from the same object, the spec and the oracle can
never silently disagree about *what* the rules are. (Whether the spec *prose*
is unambiguous is a separate question, attacked in the false-reject analysis.)

Design notes worth stating because a reviewer will ask:
  * Comparison operators always share a single precedence tier. If they were
    scattered, "chained comparison" (a<b<c) would be ambiguous, which produces
    false rejects -- a soundness failure, not a feature.
  * There is deliberately no "evaluation order" parameter. Expressions are
    side-effect free and there is a single `error` token, so left-vs-right
    operand order is unobservable; shipping an untestable rule is a smell.
"""

from __future__ import annotations

import random
from dataclasses import asdict, dataclass
from typing import Literal

# ---------------------------------------------------------------------------
# Operator inventory. Spellings are fixed and standard so the model is never
# fighting the lexer -- only the semantics.
# ---------------------------------------------------------------------------

ARITH_OPS = ["+", "-", "*", "/", "%", "**"]
COMPARE_OPS = ["<", "<=", ">", ">=", "==", "!="]
LOGIC_OPS = ["&&", "||"]
BINARY_OPS = ARITH_OPS + COMPARE_OPS + LOGIC_OPS

UNARY_NEG = "-"   # arithmetic negation
UNARY_NOT = "!"   # logical not
UNARY_OPS = [UNARY_NEG, UNARY_NOT]

Assoc = Literal["left", "right"]

# Difficulty presets control how far the sampled semantics are pushed away from
# the "obvious" defaults and how deep the test expressions get. They do NOT
# change the schema -- an easy instance and a hard instance are described by the
# same fields, so a single oracle and a single spec template cover all of them.
DIFFICULTIES = ("easy", "medium", "hard")
_ARITH_LOGIC_TIERS = {"easy": 2, "medium": 3, "hard": 4}


@dataclass(frozen=True)
class Tier:
    """One precedence level. All operators on a tier share a precedence and an
    associativity -- this keeps precedence-climbing parsing well defined."""

    ops: tuple[str, ...]
    assoc: Assoc


@dataclass(frozen=True)
class SemanticParams:
    """A complete, self-contained description of one dialect's semantics."""

    seed: int
    difficulty: str

    # Precedence: tiers ordered LOOSEST -> TIGHTEST. The last tier binds hardest.
    # Two tiers are special and located by index:
    #   - the comparison tier holds all six comparison operators
    #   - the unary tier holds the prefix operators (- and !); its position
    #     decides the classic `-2 ** 2` ambiguity.
    tiers: tuple[Tier, ...]
    compare_tier_index: int
    unary_tier_index: int

    # Integer model -------------------------------------------------------
    int_model: Literal["bigint", "wrap", "saturate", "error"]
    int_bits: int  # bit width for wrap/saturate (signed two's complement)

    # Division / modulo ---------------------------------------------------
    div_round: Literal["trunc", "floor", "euclid"]   # rounding of `/`
    div_zero: Literal["error", "nil", "zero"]         # behaviour of `/0` and `%0`

    # Exponentiation ------------------------------------------------------
    pow_negative_exp: Literal["error", "nil", "zero"]  # behaviour of a ** (negative)

    # Comparison ----------------------------------------------------------
    compare_result: Literal["bool", "int"]            # yield true/false or 1/0
    compare_chain: Literal["chain", "left", "error"]  # a < b < c semantics

    # Logical &&, || ------------------------------------------------------
    logic_shortcircuit: bool                          # skip RHS once LHS decides
    logic_return: Literal["bool", "operand"]          # boolean, or the deciding operand
    truthy: Literal["nonzero", "positive"]            # which integers count as true

    # Type coercion -------------------------------------------------------
    mix_bool_int: Literal["error", "coerce"]          # coerce => true==1, false==0

    # Tokens for the two non-integer result kinds.
    error_token: str = "error"
    nil_token: str = "nil"

    # Convenience lookups -------------------------------------------------
    def op_tier_index(self, op: str) -> int:
        for i, t in enumerate(self.tiers):
            if op in t.ops:
                return i
        raise KeyError(op)

    def tier_assoc_at(self, index: int) -> Assoc:
        return self.tiers[index].assoc

    def to_dict(self) -> dict:
        d = asdict(self)
        d["tiers"] = [{"ops": list(t["ops"]), "assoc": t["assoc"]} for t in d["tiers"]]
        return d

    @staticmethod
    def from_dict(d: dict) -> "SemanticParams":
        d = dict(d)
        d["tiers"] = tuple(Tier(ops=tuple(t["ops"]), assoc=t["assoc"]) for t in d["tiers"])
        return SemanticParams(**d)


# ---------------------------------------------------------------------------
# Sampling
# ---------------------------------------------------------------------------

# The "obvious" precedence a model assumes if it ignores the spec, LOOSEST
# first. Comparisons are collapsed to a single token "CMP". Used only to
# *measure* deviation for difficulty reporting, never imposed.
_DEFAULT_ORDER = ["||", "&&", "CMP", "+", "-", "*", "/", "%", "**"]


def _partition(rng: random.Random, items: list[str], k: int) -> list[list[str]]:
    """Randomly split `items` into `k` non-empty ordered buckets."""
    items = list(items)
    rng.shuffle(items)
    assert len(items) >= k
    buckets: list[list[str]] = [[items[i]] for i in range(k)]
    for it in items[k:]:
        buckets[rng.randrange(k)].append(it)
    return buckets


def sample_params(seed: int, difficulty: str = "medium") -> SemanticParams:
    """Deterministically sample a full dialect from `seed` and `difficulty`.

    Reproducibility: the RNG is seeded from a *stable* string. (random.Random on
    a str hashes with sha512 internally, unlike the salted builtin hash().)
    """
    if difficulty not in DIFFICULTIES:
        raise ValueError(f"unknown difficulty {difficulty!r}")
    rng = random.Random(f"shifted-dialect/v1/{seed}/{difficulty}")

    # Arithmetic + logical operators scatter across several tiers...
    k = _ARITH_LOGIC_TIERS[difficulty]
    buckets = _partition(rng, ARITH_OPS + LOGIC_OPS, k)
    tiers = [Tier(ops=tuple(sorted(b)), assoc=rng.choice(("left", "right"))) for b in buckets]
    rng.shuffle(tiers)  # randomise relative precedence of those tiers

    # ...comparisons occupy one dedicated tier...
    comp_tier = Tier(ops=tuple(sorted(COMPARE_OPS)), assoc="left")
    tiers.insert(rng.randrange(len(tiers) + 1), comp_tier)

    # ...and the prefix-unary tier slots in anywhere (deciding -x**y etc).
    unary_tier = Tier(ops=tuple(UNARY_OPS), assoc="right")
    tiers.insert(rng.randrange(len(tiers) + 1), unary_tier)

    compare_tier_index = next(i for i, t in enumerate(tiers) if set(t.ops) == set(COMPARE_OPS))
    unary_tier_index = next(i for i, t in enumerate(tiers) if set(t.ops) == set(UNARY_OPS))

    if difficulty == "easy":
        int_model = rng.choice(["bigint", "bigint", "wrap"])
    elif difficulty == "medium":
        int_model = rng.choice(["bigint", "wrap", "saturate"])
    else:
        int_model = rng.choice(["wrap", "saturate", "error", "bigint"])

    return SemanticParams(
        seed=seed,
        difficulty=difficulty,
        tiers=tuple(tiers),
        compare_tier_index=compare_tier_index,
        unary_tier_index=unary_tier_index,
        int_model=int_model,
        int_bits=rng.choice([8, 16, 32, 64]),
        div_round=rng.choice(["trunc", "floor", "euclid"]),
        div_zero=rng.choice(["error", "nil", "zero"]),
        pow_negative_exp=rng.choice(["error", "nil", "zero"]),
        compare_result=rng.choice(["bool", "int"]),
        compare_chain=rng.choice(["chain", "left", "error"]),
        logic_shortcircuit=rng.choice([True, False]),
        logic_return=rng.choice(["bool", "operand"]),
        truthy=rng.choice(["nonzero", "positive"]),
        mix_bool_int=rng.choice(["error", "coerce"]),
    )


def prior_params() -> SemanticParams:
    """A fixed, Python-/C-flavoured dialect representing the semantics a model
    *assumes by default*. Used only to flag "discriminating" test programs --
    those where the sampled dialect disagrees with this prior, i.e. exactly the
    expressions where a model's instinct betrays it. Never shown to the model.
    """
    tiers = (
        Tier(("||",), "left"),
        Tier(("&&",), "left"),
        Tier(tuple(sorted(COMPARE_OPS)), "left"),
        Tier(("+", "-"), "left"),
        Tier(("*", "/", "%"), "left"),
        Tier(tuple(UNARY_OPS), "right"),
        Tier(("**",), "right"),
    )
    return SemanticParams(
        seed=-1, difficulty="prior", tiers=tiers,
        compare_tier_index=2, unary_tier_index=5,
        int_model="bigint", int_bits=64,
        div_round="floor", div_zero="error", pow_negative_exp="error",
        compare_result="bool", compare_chain="chain",
        logic_shortcircuit=True, logic_return="operand",
        truthy="nonzero", mix_bool_int="coerce",
    )


def _flat_precedence_tokens(params: SemanticParams) -> list[str]:
    """Operators LOOSEST-first, comparisons collapsed to 'CMP'."""
    out: list[str] = []
    for t in params.tiers:
        if set(t.ops) == set(COMPARE_OPS):
            out.append("CMP")
        elif set(t.ops) == set(UNARY_OPS):
            continue
        else:
            out.extend(sorted(t.ops))
    return out


def deviation_score(params: SemanticParams) -> int:
    """Rough count of how many rules deviate from the common prior. Used only
    for difficulty reporting / test weighting, never shown to the model."""
    score = 0
    flat = _flat_precedence_tokens(params)
    rank = {op: i for i, op in enumerate(_DEFAULT_ORDER)}
    for i in range(len(flat)):
        for j in range(i + 1, len(flat)):
            a, b = flat[i], flat[j]
            if a in rank and b in rank and (rank[a] < rank[b]) != (i < j):
                score += 1
    score += sum(1 for t in params.tiers if t.assoc == "right")
    score += {"bigint": 0, "wrap": 1, "saturate": 1, "error": 1}[params.int_model]
    score += {"trunc": 0, "floor": 1, "euclid": 1}[params.div_round]
    score += {"chain": 0, "left": 1, "error": 1}[params.compare_chain]
    score += 0 if params.logic_shortcircuit else 1
    score += 1 if params.logic_return == "operand" else 0
    score += 1 if params.truthy == "positive" else 0
    score += 1 if params.mix_bool_int == "error" else 0
    return score
