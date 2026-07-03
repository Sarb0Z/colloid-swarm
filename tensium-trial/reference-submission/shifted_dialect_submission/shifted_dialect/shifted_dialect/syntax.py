"""Lexer + parser for the shifted dialect.

The *grammar* is fixed across all instances; only the precedence table and
associativity (carried by SemanticParams) vary. Parsing is precedence-climbing
driven by `params.tiers`. The one non-standard production is the comparison
chain: all comparison operators share a tier, and a run of two or more of them
(`a < b == c`) becomes a single `Compare` node so the oracle can apply the
instance's chaining rule.

A syntax error raises `ParseError`; the oracle turns that into the `error`
token, exactly as a runtime error would be. This keeps "malformed program" and
"program that blows up" on the same footing, which the spec states plainly.
"""

from __future__ import annotations

from dataclasses import dataclass

from .semantics import COMPARE_OPS, SemanticParams, UNARY_OPS


class ParseError(Exception):
    """Raised on any lexical or grammatical error."""


# --- AST -------------------------------------------------------------------


@dataclass(frozen=True)
class Int:
    value: int


@dataclass(frozen=True)
class Bool:
    value: bool


@dataclass(frozen=True)
class Unary:
    op: str
    operand: object


@dataclass(frozen=True)
class Binary:
    op: str
    left: object
    right: object


@dataclass(frozen=True)
class Compare:
    """A run of >= 2 comparison operators: operands[0] ops[0] operands[1] ..."""

    ops: tuple[str, ...]
    operands: tuple[object, ...]


# --- Lexer -----------------------------------------------------------------

# Multi-character operators must be matched before their single-char prefixes.
_SYMBOLS = ["**", "<=", ">=", "==", "!=", "&&", "||",
            "+", "-", "*", "/", "%", "<", ">", "!", "(", ")"]
_SYMBOLS.sort(key=len, reverse=True)

_KEYWORDS = {"true": ("BOOL", True), "false": ("BOOL", False)}


def tokenize(src: str) -> list[tuple[str, object]]:
    """Return a list of (kind, value) tokens ending with an ('EOF', None)."""
    toks: list[tuple[str, object]] = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c.isspace():
            i += 1
            continue
        if c.isdigit():
            j = i
            while j < n and src[j].isdigit():
                j += 1
            # an identifier-ish trailing char (e.g. 12abc) is a lexical error
            if j < n and (src[j].isalpha() or src[j] == "_"):
                raise ParseError(f"malformed number near {src[i:j + 1]!r}")
            toks.append(("INT", int(src[i:j])))
            i = j
            continue
        if c.isalpha() or c == "_":
            j = i
            while j < n and (src[j].isalnum() or src[j] == "_"):
                j += 1
            word = src[i:j]
            if word in _KEYWORDS:
                toks.append(_KEYWORDS[word])
            else:
                raise ParseError(f"unknown identifier {word!r}")
            i = j
            continue
        for sym in _SYMBOLS:
            if src.startswith(sym, i):
                toks.append(("OP", sym))
                i += len(sym)
                break
        else:
            raise ParseError(f"unexpected character {c!r}")
    toks.append(("EOF", None))
    return toks


# --- Parser ----------------------------------------------------------------


class _Parser:
    def __init__(self, toks: list[tuple[str, object]], params: SemanticParams):
        self.toks = toks
        self.params = params
        self.pos = 0
        self._compare_set = set(COMPARE_OPS)
        self._unary_set = set(UNARY_OPS)
        # Binary operators are exactly the spellings appearing on a non-unary
        # tier. Note `-` lives on both the unary tier and an arithmetic tier, so
        # it is correctly recognised in operator position; `!` is prefix-only.
        self._binary_ops = {
            op
            for i, tier in enumerate(params.tiers)
            if i != params.unary_tier_index
            for op in tier.ops
        }

    def _peek(self) -> tuple[str, object]:
        return self.toks[self.pos]

    def _advance(self) -> tuple[str, object]:
        t = self.toks[self.pos]
        self.pos += 1
        return t

    def _peek_binary(self) -> str | None:
        kind, val = self._peek()
        if kind == "OP" and isinstance(val, str) and val in self._binary_ops:
            return val
        return None

    def parse(self) -> object:
        node = self._parse_expr(0)
        if self._peek()[0] != "EOF":
            raise ParseError(f"trailing tokens at {self._peek()!r}")
        return node

    def _parse_expr(self, min_tier: int) -> object:
        left = self._parse_prefix()
        while True:
            op = self._peek_binary()
            if op is None:
                break
            tier = self.params.op_tier_index(op)
            if tier < min_tier:
                break
            if tier == self.params.compare_tier_index:
                left = self._parse_comparison(left, min_tier)
                continue
            assoc = self.params.tier_assoc_at(tier)
            self._advance()
            next_min = tier + 1 if assoc == "left" else tier
            right = self._parse_expr(next_min)
            left = Binary(op, left, right)
        return left

    def _parse_comparison(self, left: object, min_tier: int) -> object:
        ctier = self.params.compare_tier_index
        operand_min = ctier + 1  # operands bind tighter than the comparison
        operands = [left]
        ops: list[str] = []
        while True:
            kind, val = self._peek()
            if kind == "OP" and val in self._compare_set and ctier >= min_tier:
                self._advance()
                ops.append(val)  # type: ignore[arg-type]
                operands.append(self._parse_expr(operand_min))
            else:
                break
        if len(ops) == 1:
            return Binary(ops[0], operands[0], operands[1])
        return Compare(tuple(ops), tuple(operands))

    def _parse_prefix(self) -> object:
        kind, val = self._peek()
        if kind == "OP" and val in self._unary_set:
            self._advance()
            operand = self._parse_expr(self.params.unary_tier_index)
            return Unary(val, operand)  # type: ignore[arg-type]
        return self._parse_atom()

    def _parse_atom(self) -> object:
        kind, val = self._advance()
        if kind == "INT":
            return Int(val)  # type: ignore[arg-type]
        if kind == "BOOL":
            return Bool(val)  # type: ignore[arg-type]
        if kind == "OP" and val == "(":
            inner = self._parse_expr(0)
            close = self._advance()
            if close != ("OP", ")"):
                raise ParseError("expected ')'")
            return inner
        raise ParseError(f"unexpected token {(kind, val)!r}")


def parse(src: str, params: SemanticParams) -> object:
    """Tokenize and parse `src` under `params`; raise ParseError on failure."""
    return _Parser(tokenize(src), params).parse()
