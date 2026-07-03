"""Reference interpreter (the held-back oracle).

`evaluate(src, params)` returns the canonical output string for a program:
  - an integer in decimal (e.g. "-7")
  - a boolean, spelled per `compare_result` ("true"/"false" or "1"/"0")
  - the nil token, when a `nil`-valued operation propagates
  - the error token, when parsing fails or a hard error is raised

This module is GROUND TRUTH and must never be visible to the model at solve
time. The verifier computes oracle outputs in the trusted parent process and
ships only (input, expected-output) pairs into the sandbox -- never this code.

Value model:
  * Python `int`  -> dialect integer
  * Python `bool` -> dialect boolean (kept distinct from int)
  * `NIL`         -> a value that propagates through every operation
  * `EvalError`   -> a hard stop; the whole program evaluates to the error token
"""

from __future__ import annotations

from .semantics import COMPARE_OPS, LOGIC_OPS, SemanticParams
from .syntax import Binary, Bool, Compare, Int, ParseError, Unary, parse


class EvalError(Exception):
    """A hard runtime error; surfaces as the dialect's error token."""


class _Nil:
    _instance = None

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance

    def __repr__(self):
        return "NIL"


NIL = _Nil()
_COMPARE_SET = set(COMPARE_OPS)
_LOGIC_SET = set(LOGIC_OPS)
# Cap on the bit length of an exponentiation result (~30k digits); keeps the
# oracle total. Far above any production value (exponents are <= 5).
_POW_BIT_LIMIT = 100_000


class _Interp:
    def __init__(self, params: SemanticParams):
        self.p = params
        if params.int_model in ("wrap", "saturate", "error"):
            self.imin = -(1 << (params.int_bits - 1))
            self.imax = (1 << (params.int_bits - 1)) - 1
        else:
            self.imin = self.imax = None

    # -- integer model -----------------------------------------------------
    def _norm(self, x: int) -> int:
        m = self.p.int_model
        if m == "bigint":
            return x
        lo, hi = self.imin, self.imax
        if lo <= x <= hi:
            return x
        if m == "error":
            raise EvalError("integer overflow")
        if m == "saturate":
            return lo if x < lo else hi
        # wrap (two's complement)
        span = 1 << self.p.int_bits
        return (x - lo) % span + lo

    # -- coercion helpers --------------------------------------------------
    def _to_int(self, v):
        """Coerce an operand for arithmetic / ordering. Raises in error mode."""
        if isinstance(v, bool):
            if self.p.mix_bool_int == "coerce":
                return 1 if v else 0
            raise EvalError("boolean in arithmetic/ordering context")
        if isinstance(v, int):
            return v
        raise EvalError("non-numeric operand")  # NIL handled by callers

    def _cond(self, v):
        """Truth value of a condition; returns True/False, or NIL to propagate."""
        if v is NIL:
            return NIL
        if isinstance(v, bool):
            return v
        if isinstance(v, int):
            return v != 0 if self.p.truthy == "nonzero" else v > 0
        raise EvalError("non-condition operand")

    def _truth(self, b: bool):
        """Represent a truth value per the dialect's convention."""
        if self.p.compare_result == "bool":
            return bool(b)
        return 1 if b else 0

    # -- operators ---------------------------------------------------------
    def _arith(self, op: str, a, b):
        if a is NIL or b is NIL:
            return NIL
        x, y = self._to_int(a), self._to_int(b)
        if op == "+":
            return self._norm(x + y)
        if op == "-":
            return self._norm(x - y)
        if op == "*":
            return self._norm(x * y)
        if op == "/":
            r = self._divide(x, y)
            return r if r is NIL else self._norm(r)
        if op == "%":
            r = self._modulo(x, y)
            return r if r is NIL else self._norm(r)
        if op == "**":
            r = self._power(x, y)
            return r if r is NIL else self._norm(r)
        raise EvalError(f"unknown arithmetic op {op}")

    def _divzero(self):
        dz = self.p.div_zero
        if dz == "error":
            raise EvalError("division by zero")
        return NIL if dz == "nil" else 0

    def _divide(self, x: int, y: int):
        if y == 0:
            return self._divzero()
        mode = self.p.div_round
        if mode == "trunc":
            q = abs(x) // abs(y)
            return -q if (x < 0) != (y < 0) else q
        if mode == "floor":
            return x // y  # Python floor division
        # euclid: choose q so that the remainder x - q*y lands in [0, |y|)
        q = x // y
        if x - q * y < 0:
            q += 1 if y < 0 else -1
        return q

    def _modulo(self, x: int, y: int):
        if y == 0:
            return self._divzero()
        q = self._divide(x, y)
        if q is NIL:
            return NIL
        return x - q * y

    def _power(self, x: int, y: int):
        if y < 0:
            pne = self.p.pow_negative_exp
            if pne == "error":
                raise EvalError("negative exponent")
            return NIL if pne == "nil" else 0
        # Defensive resource bound so the oracle is total: refuse to materialise
        # an absurdly large integer. Production exponents are tiny (the generator
        # caps ** to <= 5), so this never fires there; it only guards against a
        # pathological exponent being fed in directly, where it yields the error
        # token instead of hanging.
        if x not in (-1, 0, 1) and y * x.bit_length() > _POW_BIT_LIMIT:
            raise EvalError("exponentiation result too large")
        return x ** y  # y >= 0; 0**0 == 1 by Python convention (stated in spec)

    def _compare(self, op: str, a, b):
        if a is NIL or b is NIL:
            return NIL
        if op in ("==", "!="):
            res = self._equal(a, b)
            return self._truth(res if op == "==" else not res)
        x, y = self._to_int(a), self._to_int(b)
        res = {"<": x < y, "<=": x <= y, ">": x > y, ">=": x >= y}[op]
        return self._truth(res)

    def _equal(self, a, b) -> bool:
        if self.p.mix_bool_int == "coerce":
            na = (1 if a else 0) if isinstance(a, bool) else a
            nb = (1 if b else 0) if isinstance(b, bool) else b
            return na == nb
        # error mode: cross-type (bool vs int) is an error; same type compares
        if isinstance(a, bool) != isinstance(b, bool):
            raise EvalError("equality across bool and int")
        return a == b

    # -- evaluation --------------------------------------------------------
    def eval(self, node):
        if isinstance(node, Int):
            return self._norm(node.value)
        if isinstance(node, Bool):
            return node.value
        if isinstance(node, Unary):
            return self._eval_unary(node)
        if isinstance(node, Compare):
            return self._eval_compare(node)
        if isinstance(node, Binary):
            return self._eval_binary(node)
        raise EvalError(f"unknown node {node!r}")

    def _eval_unary(self, node: Unary):
        if node.op == "-":
            v = self.eval(node.operand)
            if v is NIL:
                return NIL
            return self._norm(-self._to_int(v))
        # logical not
        c = self._cond(self.eval(node.operand))
        return NIL if c is NIL else self._truth(not c)

    def _eval_binary(self, node: Binary):
        op = node.op
        if op in _LOGIC_SET:
            return self._eval_logic(node)
        if op in _COMPARE_SET:
            return self._compare(op, self.eval(node.left), self.eval(node.right))
        return self._arith(op, self.eval(node.left), self.eval(node.right))

    def _eval_logic(self, node: Binary):
        op = node.op
        if self.p.logic_shortcircuit:
            return self._logic_short(op, node.left, node.right)
        # non-short-circuit: both operands always evaluated (errors/nil from
        # either propagate, like arithmetic operands).
        lv, rv = self.eval(node.left), self.eval(node.right)
        lc = self._cond(lv)
        if lc is NIL:
            return NIL
        rc = self._cond(rv)
        if rc is NIL:
            return NIL
        decided_left = (op == "&&" and not lc) or (op == "||" and lc)
        if self.p.logic_return == "operand":
            return lv if decided_left else rv
        result = (lc and rc) if op == "&&" else (lc or rc)
        return self._truth(result)

    def _logic_short(self, op: str, left, right):
        lv = self.eval(left)
        lc = self._cond(lv)
        if lc is NIL:
            return NIL
        short = (op == "&&" and not lc) or (op == "||" and lc)
        if short:
            if self.p.logic_return == "operand":
                return lv
            return self._truth(op == "||")  # || short => true, && short => false
        rv = self.eval(right)
        rc = self._cond(rv)
        if rc is NIL:
            return NIL
        return rv if self.p.logic_return == "operand" else self._truth(bool(rc))

    def _eval_compare(self, node: Compare):
        mode = self.p.compare_chain
        if mode == "error":
            raise EvalError("chained comparison not allowed")
        if mode == "left":
            acc = self.eval(node.operands[0])
            for i, op in enumerate(node.ops):
                acc = self._compare(op, acc, self.eval(node.operands[i + 1]))
            return acc
        # chain: conjunction, short-circuit at first false, each operand once
        prev = self.eval(node.operands[0])
        for i, op in enumerate(node.ops):
            cur = self.eval(node.operands[i + 1])
            c = self._cond(self._compare(op, prev, cur))
            if c is NIL:
                return NIL
            if not c:
                return self._truth(False)
            prev = cur
        return self._truth(True)


def format_value(v, params: SemanticParams) -> str:
    if v is NIL:
        return params.nil_token
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    raise EvalError(f"unformattable value {v!r}")


def evaluate(src: str, params: SemanticParams) -> str:
    """Canonical output of program `src` under `params`."""
    try:
        ast = parse(src, params)
        value = _Interp(params).eval(ast)
        return format_value(value, params)
    except (ParseError, EvalError, RecursionError):
        return params.error_token
