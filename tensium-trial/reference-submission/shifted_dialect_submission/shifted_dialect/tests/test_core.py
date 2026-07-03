"""Hand-checked correctness tests for the parser + oracle, plus a determinism /
output-shape fuzz. These are ground truth: if any fail, the engine is wrong."""

import re

from shifted_dialect.oracle import evaluate
from shifted_dialect.semantics import SemanticParams, Tier, sample_params

STD_TIERS = [
    Tier(("||",), "left"), Tier(("&&",), "left"),
    Tier(("<", "<=", ">", ">=", "==", "!="), "left"),
    Tier(("+", "-"), "left"), Tier(("*", "/", "%"), "left"),
    Tier(("!", "-"), "right"), Tier(("**",), "right"),
]


def mk(tiers=None, compare_idx=2, unary_idx=5, **over):
    base = dict(
        seed=0, difficulty="medium",
        tiers=tuple(tiers or STD_TIERS),
        compare_tier_index=compare_idx, unary_tier_index=unary_idx,
        int_model="bigint", int_bits=64,
        div_round="trunc", div_zero="error", pow_negative_exp="error",
        compare_result="int", compare_chain="left",
        logic_shortcircuit=True, logic_return="bool",
        truthy="nonzero", mix_bool_int="coerce",
    )
    base.update(over)
    return SemanticParams(**base)


def test_standard_precedence():
    p = mk()
    assert evaluate("2+3*4", p) == "14"
    assert evaluate("2*3+4", p) == "10"
    assert evaluate("-2**2", p) == "-4"        # unary below ** => -(2**2)
    assert evaluate("(-2)**2", p) == "4"
    assert evaluate("2**3**2", p) == "512"     # ** right-assoc
    assert evaluate("1<2<3", p) == "1"         # left: (1<2)<3
    assert evaluate("true+1", p) == "2"
    assert evaluate("0&&(1/0)", p) == "0"      # short-circuit avoids div0


def test_inverted_precedence():
    tiers = [Tier(("*", "/", "%"), "left"), Tier(("+", "-"), "left"),
             Tier(("<", "<=", ">", ">=", "==", "!="), "left"),
             Tier(("!", "-"), "right"), Tier(("**",), "right"),
             Tier(("&&",), "left"), Tier(("||",), "left")]
    p = mk(tiers, compare_idx=2, unary_idx=3)
    assert evaluate("2+3*4", p) == "20"        # + tighter => (2+3)*4
    assert evaluate("2*3+4", p) == "14"        # + tighter => 2*(3+4)


def test_unary_above_power():
    tiers = STD_TIERS[:5] + [Tier(("**",), "right"), Tier(("!", "-"), "right")]
    p = mk(tiers, compare_idx=2, unary_idx=6)
    assert evaluate("-2**2", p) == "4"         # unary above ** => (-2)**2


def test_division_rounding():
    assert evaluate("-10/3", mk(div_round="trunc")) == "-3"
    assert evaluate("-10/3", mk(div_round="floor")) == "-4"
    assert evaluate("-10%3", mk(div_round="floor")) == "2"
    assert evaluate("-10/3", mk(div_round="euclid")) == "-4"
    assert evaluate("-10%-3", mk(div_round="euclid")) == "2"


def test_int_models():
    assert evaluate("127+1", mk(int_model="wrap", int_bits=8)) == "-128"
    assert evaluate("200", mk(int_model="wrap", int_bits=8)) == "-56"
    assert evaluate("127+1", mk(int_model="saturate", int_bits=8)) == "127"
    assert evaluate("0-200", mk(int_model="saturate", int_bits=8)) == "-127"
    assert evaluate("127+1", mk(int_model="error", int_bits=8)) == "error"


def test_div_zero():
    assert evaluate("1/0+5", mk(div_zero="nil")) == "nil"
    assert evaluate("1/0", mk(div_zero="zero")) == "0"
    assert evaluate("1/0", mk(div_zero="error")) == "error"


def test_chaining():
    p = mk(compare_chain="chain", compare_result="bool")
    assert evaluate("1<2<3", p) == "true"
    assert evaluate("3<2<1", p) == "false"
    assert evaluate("1<2<1", p) == "false"
    assert evaluate("1<2<3", mk(compare_chain="error")) == "error"
    assert evaluate("1<2", mk(compare_chain="error")) == "1"


def test_logic_and_truthiness():
    oper = mk(logic_return="operand")
    assert evaluate("3&&4", oper) == "4"
    assert evaluate("0&&4", oper) == "0"
    assert evaluate("0||7", oper) == "7"
    assert evaluate("0&&(1/0)", mk(logic_shortcircuit=False)) == "error"
    pos = mk(truthy="positive")
    assert evaluate("!(0-1)", pos) == "1"      # -1 not positive => falsey


def test_coercion_error_mode():
    p = mk(mix_bool_int="error")
    assert evaluate("true+1", p) == "error"
    assert evaluate("true==1", p) == "error"
    assert evaluate("true==true", p) == "1"


def test_determinism_and_output_shape():
    import random
    valid = re.compile(r"^(-?\d+|true|false|nil|error)$")
    rng = random.Random(123)
    atoms = ["0", "1", "2", "7", "true", "false", "100"]
    ops = ["+", "-", "*", "/", "%", "**", "<", ">", "==", "!=", "&&", "||"]

    def gen(depth):
        if depth <= 0 or rng.random() < 0.3:
            return rng.choice(atoms)
        if rng.random() < 0.25:
            return "(" + rng.choice(["-", "!"]) + gen(depth - 1) + ")"
        op = rng.choice(ops)
        left = gen(depth - 1)
        # bound ** exponents, exactly as the real generator (exprgen.py) does,
        # so the fuzz can't ask the oracle to build an astronomically large int
        right = str(rng.randint(0, 5)) if op == "**" else gen(depth - 1)
        return "(" + left + op + right + ")"

    for seed in range(25):
        for diff in ("easy", "medium", "hard"):
            p = sample_params(seed, diff)
            assert sample_params(seed, diff) == p
            for _ in range(40):
                e = gen(4)
                o1 = evaluate(e, p)
                assert o1 == evaluate(e, p)         # deterministic
                assert valid.match(o1), (e, o1)     # well-formed output
