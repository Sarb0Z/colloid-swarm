"""Verifier / sandbox tests: the honest reference solver must pass, cheats must
not, and the sandbox must block reaching the reference package."""

from shifted_dialect.generate import make_instance
from shifted_dialect.refsolver import reference_solution_code
from shifted_dialect.semantics import sample_params
from shifted_dialect.scoring import score_instance, score_code


def test_reference_solver_scores_one():
    for diff in ("easy", "medium", "hard"):
        inst = make_instance(0, diff, n_tests=40)
        code = reference_solution_code(sample_params(0, diff))
        r = score_instance(code, inst["info"])
        assert r["reward"] == 1.0, (diff, r)


def test_constant_cheat_bounded():
    inst = make_instance(1, "medium", n_tests=40)
    r = score_code("def evaluate(s):\n return 'error'\n", inst["info"]["tests"])
    assert r["reward"] <= 0.30 + 1e-9


def test_missing_evaluate_scores_zero():
    inst = make_instance(2, "medium", n_tests=20)
    r = score_code("x = 1\n", inst["info"]["tests"])
    assert r["reward"] == 0.0 and r["fatal"] == "no_evaluate"


def test_import_oracle_is_blocked():
    inst = make_instance(3, "medium", n_tests=20)
    code = ("def evaluate(s):\n"
            "    from shifted_dialect.oracle import evaluate as o\n"
            "    return 'x'\n")
    r = score_code(code, inst["info"]["tests"])
    assert r["reward"] == 0.0


def test_grader_requires_exact_format():
    # correct values but uppercase booleans / +prefixed ints must be rejected
    inst = make_instance(4, "easy", n_tests=40)
    ref = reference_solution_code(sample_params(4, "easy"))
    mangled = ref + (
        "\n_ref = evaluate\n"
        "def evaluate(src):\n"
        "    r = _ref(src)\n"
        "    if r in ('true', 'false'):\n"
        "        return r.upper()\n"
        "    if r and r[0].isdigit():\n"
        "        return '+' + r\n"
        "    return r + ' '\n"   # mangles every output kind -> guaranteed mismatch
    )
    r = score_code(mangled, inst["info"]["tests"])
    # correct values, wrong formatting -> the exact-match grader rejects them
    assert r["reward"] < 1.0
