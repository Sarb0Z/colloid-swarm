"""shifted_dialect -- an RL environment that tests spec-faithful implementation
of randomised expression-language semantics.

The core engine (semantics, syntax, oracle, spec, generate) is pure-Python and
has no third-party dependencies. The `verifiers` integration lives in
`environment.py` and is imported lazily so the engine can be used and tested
without `verifiers` installed.
"""

from __future__ import annotations

__version__ = "0.1.0"


def load_environment(**kwargs):
    """Entry point required by the verifiers package. Imported lazily so that
    the pure-Python core does not depend on verifiers."""
    from .environment import load_environment as _load

    return _load(**kwargs)
