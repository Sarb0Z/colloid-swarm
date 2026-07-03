"""Run untrusted model-generated `evaluate` in an isolated subprocess.

Isolation (declared explicitly; see README "Sandbox manifest"):
  * `python -S -E`: the standard library only. site-packages are NOT on the
    child's path, so the installed `shifted_dialect` package (the oracle) is
    unimportable, and the "stdlib only" rule from the spec is enforced.
  * empty environment (no PYTHONPATH), a fresh temp working directory, and an
    explicit meta-path blocker for `shifted_dialect` as belt-and-suspenders.
  * RLIMIT_CPU and RLIMIT_AS (best effort; RLIMIT_AS is not enforced on macOS),
    a per-call wall-clock SIGALRM to localise a single hanging input, and an
    overall wall-clock timeout that kills the whole process group.
  * Network: NOT isolated at the OS level by this local runner. This is safe for
    *scoring* soundness because the held-out inputs and the reference answers
    never exist on disk or on any network the child can reach -- they are
    computed in the trusted parent and never handed to the child. For untrusted
    execution at scale, run this under a container/microVM (see README).

The child is told only the program strings; never the expected outputs. So a
"pass" can only come from actually computing the right value.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field

# Self-contained, stdlib-only runner executed as the child process.
_RUNNER_SRC = r'''
import sys, json, os, signal

class _Blocker:
    def find_spec(self, name, path=None, target=None):
        if name == "shifted_dialect" or name.startswith("shifted_dialect."):
            raise ImportError("import of reference package is blocked in sandbox")
        return None

sys.meta_path.insert(0, _Blocker())

job_path, out_path = sys.argv[1], sys.argv[2]
with open(job_path) as f:
    job = json.load(f)
code = job["code"]
inputs = job["inputs"]
per_call = float(job["per_call_timeout"])

out = open(out_path, "w")
def emit(obj):
    out.write(json.dumps(obj) + "\n")
    out.flush()

ns = {}
try:
    exec(compile(code, "<solution>", "exec"), ns)
except BaseException as e:
    emit({"fatal": "exec_error", "detail": type(e).__name__})
    out.close(); sys.exit(0)

fn = ns.get("evaluate")
if not callable(fn):
    emit({"fatal": "no_evaluate"})
    out.close(); sys.exit(0)

class _Timeout(Exception):
    pass
def _on_alarm(sig, frame):
    raise _Timeout()
signal.signal(signal.SIGALRM, _on_alarm)

devnull = open(os.devnull, "w")
for i, prog in enumerate(inputs):
    result = {"i": i, "ok": False, "err": "unknown"}
    signal.setitimer(signal.ITIMER_REAL, per_call)
    saved = (sys.stdout, sys.stderr)
    sys.stdout = sys.stderr = devnull
    try:
        r = fn(prog)
        if isinstance(r, str):
            result = {"i": i, "ok": True, "out": r}
        else:
            result = {"i": i, "ok": False, "err": "non_str"}
    except _Timeout:
        result = {"i": i, "ok": False, "err": "timeout"}
    except BaseException as e:
        result = {"i": i, "ok": False, "err": "exc:" + type(e).__name__}
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        sys.stdout, sys.stderr = saved
    emit(result)
out.close()
'''


@dataclass
class SandboxResult:
    outputs: list[dict]            # aligned to inputs: {"ok": bool, "out": str|None, "err": str|None}
    fatal: str | None = None       # "exec_error" | "no_evaluate" | None
    timed_out: bool = False
    stderr: str = ""
    meta: dict = field(default_factory=dict)


def _preexec(cpu_seconds: int, mem_mb: int):
    def _set():
        try:
            import resource
            resource.setrlimit(resource.RLIMIT_CPU, (cpu_seconds, cpu_seconds + 1))
            try:
                b = mem_mb * 1024 * 1024
                resource.setrlimit(resource.RLIMIT_AS, (b, b))
            except (ValueError, OSError):
                pass
        except Exception:
            pass
        try:
            os.setsid()
        except OSError:
            pass
    return _set


def run_solution(
    code: str,
    inputs: list[str],
    *,
    per_call_timeout: float = 1.0,
    total_timeout: float = 25.0,
    cpu_seconds: int = 12,
    mem_mb: int = 512,
) -> SandboxResult:
    """Execute `code` (which should define evaluate(src)->str) on each input."""
    tmpdir = tempfile.mkdtemp(prefix="sd_sandbox_")
    runner_path = os.path.join(tmpdir, "runner.py")
    job_path = os.path.join(tmpdir, "job.json")
    out_path = os.path.join(tmpdir, "results.jsonl")
    with open(runner_path, "w") as f:
        f.write(_RUNNER_SRC)
    with open(job_path, "w") as f:
        json.dump({"code": code, "inputs": inputs, "per_call_timeout": per_call_timeout}, f)
    open(out_path, "w").close()

    cmd = [sys.executable, "-S", "-E", runner_path, job_path, out_path]
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": tmpdir,
           "TMPDIR": tmpdir, "LC_ALL": "C", "LANG": "C"}

    timed_out = False
    stderr = ""
    proc = subprocess.Popen(
        cmd, cwd=tmpdir, env=env,
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        preexec_fn=_preexec(cpu_seconds, mem_mb),
    )
    try:
        _, err = proc.communicate(timeout=total_timeout)
        stderr = (err or b"").decode("utf-8", "replace")[:2000]
    except subprocess.TimeoutExpired:
        timed_out = True
        try:
            os.killpg(os.getpgid(proc.pid), 9)
        except (OSError, ProcessLookupError):
            proc.kill()
        try:
            _, err = proc.communicate(timeout=5)
            stderr = (err or b"").decode("utf-8", "replace")[:2000]
        except Exception:
            pass

    # Parse whatever results were flushed before exit/kill.
    fatal: str | None = None
    by_index: dict[int, dict] = {}
    try:
        with open(out_path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                obj = json.loads(line)
                if "fatal" in obj:
                    fatal = obj["fatal"]
                    break
                by_index[obj["i"]] = obj
    except FileNotFoundError:
        pass

    outputs: list[dict] = []
    for i in range(len(inputs)):
        r = by_index.get(i)
        if r is None:
            outputs.append({"ok": False, "out": None, "err": "no_result"})
        else:
            outputs.append({"ok": r.get("ok", False), "out": r.get("out"),
                            "err": r.get("err")})

    try:
        import shutil
        shutil.rmtree(tmpdir, ignore_errors=True)
    except Exception:
        pass

    return SandboxResult(outputs=outputs, fatal=fatal, timed_out=timed_out,
                         stderr=stderr, meta={"n_inputs": len(inputs)})
