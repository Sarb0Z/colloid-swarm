#!/usr/bin/env bash
# One-command, model-free verification of the shifted_dialect environment.
# Runs the engine tests, the soundness receipt, the contamination check, an
# env-load, and an honest-vs-cheat demo, then prints a PASS/FAIL summary.
#
# Usage:  bash verify.sh [soundness_instances]     (default 20)
# No API key required.

cd "$(dirname "$0")" || exit 1
export PYTHONPATH="$PWD"          # make shifted_dialect + analysis importable
PY="../.venv/bin/python"
[ -x "$PY" ] || PY="$(command -v python3.12 || command -v python3 || command -v python)"
INSTANCES="${1:-20}"
echo "Interpreter: $PY"
echo "Soundness instances: $INSTANCES"

PASS=0; FAIL=0
record() {  # record <exit_code> <name>
  if [ "$1" -eq 0 ]; then echo "[PASS] $2"; PASS=$((PASS+1));
  else echo "[FAIL] $2"; FAIL=$((FAIL+1)); fi
}

echo; echo "=== 1/5  engine + verifier tests (pytest) ==="
"$PY" -m pytest tests/ -q
record $? "engine + verifier tests"

echo; echo "=== 2/5  soundness receipt ==="
"$PY" -m analysis.soundness --instances "$INSTANCES" --workers 6 >/dev/null 2>&1
"$PY" - <<'EOF'
import json, sys
d = json.load(open("analysis/out/soundness.json"))
fa, surv = d["false_accept"], d["surviving_cheat_classes"]
print(f"  false_accept = {fa['k']}/{fa['n']} (CI {fa['ci95'][0]:.4f}-{fa['ci95'][1]:.4f}); "
      f"surviving_cheat_classes = {surv or 'none'}")
sys.exit(0 if (fa["k"] == 0 and not surv) else 1)
EOF
record $? "soundness: 0 false-accepts, no surviving cheats"

echo; echo "=== 3/5  contamination receipt ==="
"$PY" -m analysis.contamination >/dev/null 2>&1
"$PY" - <<'EOF'
import json, sys
d = json.load(open("analysis/out/contamination.json"))
ov = d["fingerprint_overlap_train_eval"]
mem = d["leakage_probe"]["overall_memorizer_accuracy_on_eval"]
print(f"  train/eval fingerprint overlap = {ov}; train-memoriser accuracy on eval = {mem}")
sys.exit(0 if ov == 0 else 1)
EOF
record $? "contamination: 0 split overlap"

echo; echo "=== 4/5  environment loads (verifiers SingleTurnEnv) ==="
"$PY" - <<'EOF'
import sys
from shifted_dialect import load_environment
e = load_environment(n_train_per_difficulty=2, n_eval_per_difficulty=2, n_tests=20)
print(f"  train={len(e.dataset)} eval={len(e.eval_dataset)} "
      f"rewards={e.rubric._get_reward_func_names()}")
sys.exit(0 if len(e.dataset) and len(e.eval_dataset) else 1)
EOF
record $? "environment loads"

echo; echo "=== 5/5  honest solver vs cheat ==="
"$PY" - <<'EOF'
import sys
from shifted_dialect.generate import make_instance
from shifted_dialect.refsolver import reference_solution_code
from shifted_dialect.semantics import sample_params
from shifted_dialect.scoring import score_code
t = make_instance(0, "hard", n_tests=40)["info"]["tests"]
h = score_code(reference_solution_code(sample_params(0, "hard")), t)["reward"]
c = score_code("def evaluate(s): return 'error'", t)["reward"]
print(f"  honest_reference = {h}  (want 1.0);  const cheat = {c}  (want <= 0.30)")
sys.exit(0 if (h == 1.0 and c <= 0.30) else 1)
EOF
record $? "honest = 1.0 and cheat <= 0.30"

echo; echo "==================== SUMMARY ===================="
echo "PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "ALL CHECKS PASSED"; exit 0; else echo "SOME CHECKS FAILED"; exit 1; fi
