"""Render a SemanticParams into the precise specification shown to the model.

The spec must be complete and unambiguous: a competent engineer should be able
to implement a matching `evaluate` from it alone. It is generated from the same
SemanticParams that drives the oracle, so the two cannot disagree about *what*
the rules are. Only reachable behaviours are described (e.g. the `nil` token is
mentioned only when some rule can actually produce nil), which keeps the spec
tight and reduces ambiguity.
"""

from __future__ import annotations

from .exprgen import sample_programs
from .oracle import evaluate
from .semantics import COMPARE_OPS, UNARY_OPS, SemanticParams

N_WORKED_EXAMPLES = 10


def _bool_repr(params: SemanticParams) -> str:
    return "the words `true` / `false`" if params.compare_result == "bool" else "`1` / `0`"


def _precedence_table(params: SemanticParams) -> str:
    """Render levels TIGHTEST first (level 1 binds hardest)."""
    lines = []
    levels = list(reversed(params.tiers))
    for i, tier in enumerate(levels, 1):
        ops = set(tier.ops)
        if ops == set(UNARY_OPS):
            lines.append(f"  Level {i} (binds tightest among remaining): "
                         f"prefix unary `-` (negation) and `!` (logical not). "
                         f"Prefix operators apply to the operand on their right.")
        elif ops == set(COMPARE_OPS):
            assoc = {"chain": "see the chaining rule below",
                     "left": "left-associative",
                     "error": "non-associative (chaining is an error)"}[params.compare_chain]
            lines.append(f"  Level {i}: comparison operators "
                         f"`<` `<=` `>` `>=` `==` `!=` (all share this level; {assoc}).")
        else:
            shown = " ".join(f"`{o}`" for o in sorted(tier.ops))
            lines.append(f"  Level {i}: {shown}  ({tier.assoc}-associative).")
    return "\n".join(lines)


def _int_model(params: SemanticParams) -> str:
    if params.int_model == "bigint":
        return ("Integers are arbitrary precision (unbounded). No overflow ever "
                "occurs.")
    lo = -(1 << (params.int_bits - 1))
    hi = (1 << (params.int_bits - 1)) - 1
    head = (f"Integers are signed {params.int_bits}-bit, valid range "
            f"[{lo}, {hi}]. **Every integer value -- including each integer "
            f"literal in the source -- is reduced into this range** ")
    if params.int_model == "wrap":
        return head + ("by two's-complement wraparound (i.e. value modulo "
                       f"2^{params.int_bits}, mapped into the signed range). This "
                       "applies to literals and to the result of every "
                       "arithmetic operation.")
    if params.int_model == "saturate":
        return head + (f"by clamping: anything below {lo} becomes {lo}, anything "
                       f"above {hi} becomes {hi}. This applies to literals and to "
                       "the result of every arithmetic operation.")
    return head + ("by raising an error: any literal or arithmetic result "
                   "outside the range makes the whole program evaluate to "
                   "`error`.")


def _division(params: SemanticParams) -> str:
    rounding = {
        "trunc": "rounded toward zero (truncated). E.g. -10 / 3 == -3.",
        "floor": "rounded toward negative infinity (floor). E.g. -10 / 3 == -4.",
        "euclid": ("by Euclidean division: the remainder is always in "
                   "[0, |divisor|). E.g. -10 / 3 == -4 and -10 / -3 == 4."),
    }[params.div_round]
    zero = {
        "error": "Division or modulo by zero is an `error`.",
        "nil": "Division or modulo by zero yields `nil`.",
        "zero": "Division or modulo by zero yields `0`.",
    }[params.div_zero]
    return (f"`/` is integer division, with the quotient {rounding}\n"
            f"  `a % b` equals `a - (a / b) * b`, using the same division rule "
            f"(so the remainder is consistent with `/`).\n  {zero}")


def _power(params: SemanticParams) -> str:
    neg = {
        "error": "A negative exponent is an `error`.",
        "nil": "A negative exponent yields `nil`.",
        "zero": "A negative exponent yields `0`.",
    }[params.pow_negative_exp]
    return ("`a ** b` for `b >= 0` is repeated multiplication; `0 ** 0 == 1`. "
            + neg)


def _comparison(params: SemanticParams) -> str:
    rep = _bool_repr(params)
    out = [f"Comparison operators yield a truth value, written as {rep}."]
    if params.compare_chain == "chain":
        out.append("A run of two or more comparisons such as `a < b < c` is "
                    "interpreted as `(a < b)` AND `(b < c)`: each operand is "
                    "evaluated once, left to right, and evaluation stops at the "
                    "first comparison that is false (the result is then false). "
                    "The overall result is a truth value.")
    elif params.compare_chain == "left":
        out.append("A run of comparisons such as `a < b < c` is left-"
                   "associative: it means `(a < b) < c`. (The truth value of "
                   "`a < b` is then compared with `c`.)")
    else:
        out.append("Two or more comparison operators in a row, such as "
                   "`a < b < c`, is an `error`.")
    return " ".join(out) if params.compare_chain != "chain" else "\n  ".join(out)


def _logic(params: SemanticParams) -> str:
    truthy = ("a non-zero integer is true (zero is false)"
              if params.truthy == "nonzero"
              else "a strictly positive integer is true (zero and negatives are false)")
    side = "an `error` or `nil`" if _nil_reachable(params) else "an `error`"
    sc = ("Evaluation is short-circuit: the right operand is not evaluated when "
          "the left operand already decides the result."
          if params.logic_shortcircuit else
          "Evaluation is NOT short-circuit: both operands are always evaluated, "
          f"so {side} in the right operand occurs even when the left "
          "operand already decides the result.")
    if params.logic_return == "bool":
        ret = (f"`a && b` yields a truth value ({_bool_repr(params)}): true iff "
               f"both operands are truthy. `a || b` yields true iff either is "
               f"truthy.")
    else:
        ret = ("`a && b` yields the left operand if it is falsey, otherwise the "
               "right operand. `a || b` yields the left operand if it is truthy, "
               "otherwise the right operand. (The operands are returned as-is, "
               "not converted to a truth value.)")
    return (f"For `&&` and `||`, an operand used as a condition is truthy when: "
            f"{truthy}; booleans are themselves.\n  {sc}\n  {ret}\n  `!a` yields "
            f"a truth value ({_bool_repr(params)}): true iff `a` is falsey.")


def _coercion(params: SemanticParams) -> str:
    if params.mix_bool_int == "coerce":
        return ("Where an arithmetic or comparison operator receives a boolean, "
                "the boolean is treated as an integer: `true` is 1, `false` is 0.")
    return ("Mixing a boolean and an integer in arithmetic (`+ - * / % **`) or "
            "ordering (`< <= > >=`) is an `error`. For equality (`==`, `!=`): "
            "comparing a boolean with an integer is an `error`; comparing two "
            "booleans or two integers is allowed.")


def _nil_reachable(params: SemanticParams) -> bool:
    return params.div_zero == "nil" or params.pow_negative_exp == "nil"


def _error_sources(params: SemanticParams) -> list[str]:
    src = ["a syntax error (a program that does not parse)"]
    if params.div_zero == "error":
        src.append("division or modulo by zero")
    if params.pow_negative_exp == "error":
        src.append("a negative exponent")
    if params.int_model == "error":
        src.append("an integer literal or arithmetic result outside the valid range")
    if params.mix_bool_int == "error":
        src.append("mixing a boolean and an integer where it is not allowed")
    if params.compare_chain == "error":
        src.append("a chain of two or more comparison operators")
    return src


def _output_format(params: SemanticParams) -> str:
    kinds = ["an **integer**, written in decimal (a leading `-` for negatives, "
             "no leading zeros), e.g. `-7`",
             f"a **boolean**, written as {_bool_repr(params)}"]
    if _nil_reachable(params):
        kinds.append("the token `nil`")
    kinds.append("the token `error`")
    body = "\n".join(f"    - {k}" for k in kinds)
    return ("`evaluate` returns exactly one string, with no surrounding "
            "whitespace or quotes. It is one of:\n" + body)


def worked_example_inputs(params: SemanticParams) -> list[str]:
    """The example programs shown in the spec. Excluded from the scored test set
    so that grading measures generalisation, not echoing the examples."""
    return sample_programs(seed=999, params=params, n=N_WORKED_EXAMPLES, depth=3)


def _worked_examples(params: SemanticParams) -> str:
    rows = [f"    {p}  =>  {evaluate(p, params)}" for p in worked_example_inputs(params)]
    return "\n".join(rows)


def render_spec(params: SemanticParams) -> str:
    nil_note = ""
    if _nil_reachable(params):
        nil_note = ("\n- **nil**: `nil` is a value (not an error). Any operation "
                    "with a `nil` operand yields `nil` -- nil propagates through "
                    "everything, including conditions of `&&`/`||` and `!`.")
    errors = _error_sources(params)
    err_list = "\n".join(f"    - {e}" for e in errors)

    return f"""\
# Task: implement an evaluator for a small expression language

You are given the complete semantics of a small integer/boolean expression
language. Implement a Python function `evaluate(src: str) -> str` that returns
the result of evaluating the program `src` under exactly these rules.

This language deliberately departs from the conventions of Python/C/JavaScript.
**Follow the rules below literally; do not assume familiar defaults.** Read the
precedence table and every rule carefully -- several of them differ from what
you might expect.

## Surface syntax (fixed)

- Integer literals: one or more digits (e.g. `0`, `42`). They are always
  non-negative in the source; negative values arise only from the unary `-`.
- Boolean literals: `true` and `false`.
- Parentheses `(` `)` group sub-expressions.
- Operators (spellings are standard): binary `+ - * / % ** < <= > >= == != && ||`
  and prefix unary `- !`. Whitespace is insignificant.
- Any other character, an unknown identifier, or a malformed program is a
  syntax error (see Errors).

## Values

There are two value kinds: **integers** and **booleans**.{(' There is also '
'**nil** (described below).') if _nil_reachable(params) else ''} A run that
hits an error condition evaluates to the single token `error`.

## Operator precedence and associativity

Levels are listed TIGHTEST first (Level 1 binds most tightly). Operators on the
same level share precedence. Parentheses override precedence as usual.

{_precedence_table(params)}

## Integer model

{_int_model(params)}

## Arithmetic

- {_division(params)}
- {_power(params)}

## Comparison

{_comparison(params)}

## Logical operators (`&&`, `||`, `!`)

{_logic(params)}

## Type coercion

{_coercion(params)}{nil_note}

## Errors

The whole program evaluates to `error` if any of the following occurs:
{err_list}

## Output format

{_output_format(params)}

## Worked examples (computed under these exact rules)

The following input => output pairs are all consistent with the rules above.
Use them to check your understanding (they are illustrative, not the inputs you
will be graded on):

{_worked_examples(params)}

## What to submit

Return a single Python code block defining `evaluate(src: str) -> str`. It must
be self-contained (standard library only), define no top-level side effects,
and read nothing from disk or the network. Your function will be called on many
held-out programs and scored on how many outputs exactly match the reference.
"""
