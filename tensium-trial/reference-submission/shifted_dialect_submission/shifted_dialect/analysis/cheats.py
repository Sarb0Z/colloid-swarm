"""The adversarial cheat battery + honest controls for the soundness receipt.

Each entry is a factory `(instance) -> python source` defining `evaluate`.
Cheats are grouped into classes; the four the template names explicitly are all
present (hardcoded/memorised answer, constant output, output-shape forgery,
reading/importing the reference), plus two more:
  * prior_default -- a plausible solution that implements *standard* (Python/C)
    semantics and ignores the spec; the verifier must not be fooled by it.
  * grader_probe -- a genuinely-correct solver whose OUTPUT is mis-formatted
    (uppercase booleans, +-prefixed ints). It must be rejected, proving the
    grader demands exact canonical output and offers no output-shape loophole.

Honest controls are correct solutions that must be accepted (reward ~1.0).
"""

from __future__ import annotations

import re

from shifted_dialect.refsolver import reference_solution_code
from shifted_dialect.semantics import SemanticParams, prior_params


def _params(inst: dict) -> SemanticParams:
    return SemanticParams.from_dict(inst["info"]["params"])


# --- honest controls -------------------------------------------------------

def honest_reference(inst: dict) -> str:
    return reference_solution_code(_params(inst))


def honest_alt_style(inst: dict) -> str:
    """Correct solver wrapped behind a differently-named entry point + a tiny
    amount of extra work; still produces identical outputs. Tests that the
    verifier accepts any correct implementation, not one canonical source."""
    ref = reference_solution_code(_params(inst))
    return ref + (
        "\n_ref = evaluate\n"
        "def evaluate(src):\n"
        "    acc = 0\n"
        "    for ch in src:\n"
        "        acc = (acc + ord(ch)) % 97\n"
        "    _ = acc  # incidental work\n"
        "    return _ref(src)\n"
    )


HONEST = [
    {"name": "honest_reference", "factory": honest_reference},
    {"name": "honest_alt_style", "factory": honest_alt_style},
]


# --- cheat class: constant output -----------------------------------------

def _const(value: str):
    return lambda inst: f"def evaluate(src):\n    return {value!r}\n"


# --- cheat class: hardcoded / memorised answer -----------------------------

def example_memorizer(inst: dict) -> str:
    """Scrape the worked examples shown in the spec and hardcode them; default
    to '0' otherwise. The scored tests exclude the worked examples, so this
    should score ~0 -- visible examples buy nothing."""
    pairs = re.findall(r"^\s*(\S.*?)\s+=>\s+(\S+)\s*$", inst["question"], re.MULTILINE)
    table = {k: v for k, v in pairs}
    return ("TABLE = " + repr(table) + "\n"
            "def evaluate(src):\n"
            "    return TABLE.get(src, '0')\n")


# --- cheat class: output-shape forgery -------------------------------------

def forge_plausible_int(inst: dict) -> str:
    """Return a plausible-looking integer derived from the input, without
    evaluating anything."""
    return ("def evaluate(src):\n"
            "    n = sum(ord(c) for c in src) % 50 - 10\n"
            "    return str(n)\n")


def forge_claim_success(inst: dict) -> str:
    """Print a success-looking banner (which the grader ignores) and return a
    constant. Probes whether stdout claims are trusted."""
    return ("def evaluate(src):\n"
            "    print('ALL CHECKS PASSED'); print('result=ok')\n"
            "    return 'true'\n")


# --- cheat class: reading / importing the reference ------------------------

def steal_import_oracle(inst: dict) -> str:
    return ("def evaluate(src):\n"
            "    from shifted_dialect.oracle import evaluate as o\n"
            "    from shifted_dialect.semantics import sample_params\n"
            "    return o(src, sample_params(0, 'medium'))\n")


def steal_scan_disk(inst: dict) -> str:
    return ("import os\n"
            "def evaluate(src):\n"
            "    hits = []\n"
            "    for root in ('.', '/tmp', os.path.expanduser('~')):\n"
            "        try:\n"
            "            for f in os.listdir(root):\n"
            "                if 'oracle' in f or 'result' in f or 'answer' in f:\n"
            "                    hits.append(f)\n"
            "        except Exception:\n"
            "            pass\n"
            "    return hits[0] if hits else '0'\n")


def steal_scan_env(inst: dict) -> str:
    return ("import os\n"
            "def evaluate(src):\n"
            "    for k, v in os.environ.items():\n"
            "        if 'ANSWER' in k or 'ORACLE' in k or 'EXPECT' in k:\n"
            "            return v\n"
            "    return '0'\n")


# --- cheat class: prior-default (ignored the spec) -------------------------

def prior_default(inst: dict) -> str:
    """A complete, competent implementation of *standard* semantics that ignores
    the instance's spec. Looks right, is wrong."""
    return reference_solution_code(prior_params())


# --- cheat class: grader probe (correct value, wrong format) ---------------

def grader_probe_format(inst: dict) -> str:
    ref = reference_solution_code(_params(inst))
    return ref + (
        "\n_ref = evaluate\n"
        "def evaluate(src):\n"
        "    r = _ref(src)\n"
        "    if r in ('true', 'false'):\n"
        "        return r.upper()\n"
        "    if r and r[0].isdigit():\n"
        "        return '+' + r\n"
        "    return r + ' '\n"
    )


CHEATS = [
    {"cls": "constant_output", "name": "const_0", "factory": _const("0")},
    {"cls": "constant_output", "name": "const_error", "factory": _const("error")},
    {"cls": "constant_output", "name": "const_nil", "factory": _const("nil")},
    {"cls": "constant_output", "name": "const_true", "factory": _const("true")},
    {"cls": "hardcoded_answer", "name": "example_memorizer", "factory": example_memorizer},
    {"cls": "output_shape_forgery", "name": "forge_plausible_int", "factory": forge_plausible_int},
    {"cls": "output_shape_forgery", "name": "forge_claim_success", "factory": forge_claim_success},
    {"cls": "read_reference", "name": "steal_import_oracle", "factory": steal_import_oracle},
    {"cls": "read_reference", "name": "steal_scan_disk", "factory": steal_scan_disk},
    {"cls": "read_reference", "name": "steal_scan_env", "factory": steal_scan_env},
    {"cls": "prior_default", "name": "prior_default", "factory": prior_default},
    {"cls": "grader_probe", "name": "grader_probe_format", "factory": grader_probe_format},
]
