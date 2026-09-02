#!/usr/bin/env python3
"""Exercise the config rewriter against the shapes that break naive editing."""

import importlib.util
import os
import pathlib
import shutil
import sys
import tomllib

here = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("trust_hooks", here / "trust-hooks.py")
th = importlib.util.module_from_spec(spec)
spec.loader.exec_module(th)

fails = 0


def check(name, ok, detail=""):
    global fails
    if ok:
        print(f"ok    {name}")
    else:
        fails += 1
        print(f"FAIL  {name}{(chr(10) + '  ' + detail) if detail else ''}")


def state(text, keys):
    return th.upsert(text, th.STATE, "hooks.state",
                     {k: {"trusted_hash": th.quoted(v), "enabled": "true"}
                      for k, v in keys.items()})


def parses(text):
    try:
        return tomllib.loads(text), ""
    except tomllib.TOMLDecodeError as error:
        return None, str(error)


BASE = 'model = "gpt-5"\n\n[hooks.state."/r/.codex/hooks.json:stop:0:0"]\ntrusted_hash = "sha256:old"\nenabled = true\n'

# A key with a quote or a backslash must survive both the write and the re-read.
for label, key in (("quote", '/r"x/.codex/hooks.json:stop:0:0'),
                   ("backslash", "/r\\x/.codex/hooks.json:stop:0:0")):
    out = state(BASE, {key: "sha256:new"})
    doc, err = parses(out)
    check(f"key containing a {label} keeps the config parseable", doc is not None, err)
    if doc:
        check(f"key containing a {label} round-trips",
              doc["hooks"]["state"].get(key, {}).get("trusted_hash") == "sha256:new")
        again = state(out, {key: "sha256:new"})
        check(f"key containing a {label} is idempotent", again == out)

# No trailing newline on the final block.
out = state(BASE.rstrip("\n"), {"/r/.codex/hooks.json:stop:0:0": "sha256:new"})
doc, err = parses(out)
check("config with no trailing newline stays parseable", doc is not None, err)
if doc:
    check("config with no trailing newline takes the new hash",
          doc["hooks"]["state"]["/r/.codex/hooks.json:stop:0:0"]["trusted_hash"] == "sha256:new")

# A comment sitting after the table header.
commented = 'model = "x"\n\n[hooks.state."/r/.codex/hooks.json:stop:0:0"] # approved by hand\ntrusted_hash = "sha256:old"\n'
out = state(commented, {"/r/.codex/hooks.json:stop:0:0": "sha256:new"})
doc, err = parses(out)
check("comment after the table header does not duplicate the table", doc is not None, err)

# CRLF line endings.
out = state(BASE.replace("\n", "\r\n"), {"/r/.codex/hooks.json:stop:0:0": "sha256:new"})
doc, err = parses(out)
check("CRLF config does not duplicate the table", doc is not None, err)

# Unrelated keys in the block survive; other projects are untouched.
rich = ('[hooks.state."/r/.codex/hooks.json:stop:0:0"]\ntrusted_hash = "sha256:old"\n'
        'approved_at = "2026-01-01"\n\n[hooks.state."/other/.codex/hooks.json:stop:0:0"]\n'
        'trusted_hash = "sha256:keep"\nenabled = false\n')
out = state(rich, {"/r/.codex/hooks.json:stop:0:0": "sha256:new"})
doc, err = parses(out)
check("rewrite keeps the config parseable", doc is not None, err)
if doc:
    s = doc["hooks"]["state"]
    check("unrelated keys in the block survive",
          s["/r/.codex/hooks.json:stop:0:0"].get("approved_at") == "2026-01-01")
    check("another project's block is untouched",
          s["/other/.codex/hooks.json:stop:0:0"] == {"trusted_hash": "sha256:keep", "enabled": False})

# Appending to an empty config, then re-running, must not rewrite.
first = state("", {"/r/.codex/hooks.json:stop:0:0": "sha256:new"})
check("append produces parseable output", parses(first)[0] is not None, parses(first)[1])
check("append then re-run is a no-op",
      state(first, {"/r/.codex/hooks.json:stop:0:0": "sha256:new"}) == first)

# The project table uses the same machinery.
proj = th.upsert("", th.PROJECT, "projects", {"/r": {"trust_level": '"trusted"'}})
doc, err = parses(proj)
check("project trust entry parses", doc is not None, err)
if doc:
    check("project trust entry says trusted", doc["projects"]["/r"]["trust_level"] == "trusted")
check("project trust is idempotent",
      th.upsert(proj, th.PROJECT, "projects", {"/r": {"trust_level": '"trusted"'}}) == proj)

# A hooks.state edit must not disturb the projects table and vice versa.
mixed = proj + BASE
out = state(mixed, {"/r/.codex/hooks.json:stop:0:0": "sha256:new"})
doc, err = parses(out)
check("hook rewrite leaves the projects table intact",
      doc is not None and doc.get("projects", {}).get("/r", {}).get("trust_level") == "trusted", err)

# Repeated runs must not grow the file. The blank line between blocks is the
# one that accumulated before.
spaced = ('model = "x"\n\n[hooks.state."/r/.codex/hooks.json:stop:0:0"]\n'
          'trusted_hash = "sha256:old"\nenabled = true\n\n'
          '[hooks.state."/r/.codex/hooks.json:stop:0:1"]\ntrusted_hash = "sha256:b"\n\n'
          '[projects."/r"]\ntrust_level = "trusted"\n')
once = state(spaced, {"/r/.codex/hooks.json:stop:0:0": "sha256:new"})
twice = state(once, {"/r/.codex/hooks.json:stop:0:0": "sha256:new"})
check("a second pass over a spaced config changes nothing", once == twice,
      f"grew by {len(twice) - len(once)} chars")
check("the block after the rewritten one keeps its own trailing blank line",
      once.count("\n\n") == spaced.count("\n\n"),
      f"{spaced.count(chr(10)*2)} -> {once.count(chr(10)*2)}")
check("a spaced config still parses after rewrite", parses(once)[0] is not None, parses(once)[1])

# store() must refuse to write anything tomllib rejects.
target = pathlib.Path(os.environ.get("TMPDIR", "/tmp")) / "trust-hooks-store-test.toml"
target.write_text('model = "keep"\n')
try:
    th.store(str(target), 'this is not = = toml\n', False)
    check("store refuses unparseable output", False, "no Fault raised")
except th.Fault:
    check("store refuses unparseable output", True)
check("store left the original file alone", target.read_text() == 'model = "keep"\n')
target.unlink()


def run_main(config_path, *, which, discovered, declares):
    """Drive main() against stubbed Codex answers, and report what it wrote."""
    real = (shutil.which, th.ask_codex, th.declared, sys.argv)
    shutil.which = lambda name: which
    th.ask_codex = lambda repo: discovered
    th.declared = lambda repo: declares
    sys.argv = ["trust-hooks.py", "/r", f"--config={config_path}"]
    try:
        return th.main(), pathlib.Path(config_path).read_text()
    finally:
        shutil.which, th.ask_codex, th.declared, sys.argv = real


tmp = pathlib.Path(os.environ.get("TMPDIR", "/tmp")) / "trust-hooks-main-test.toml"

# No Codex means no write at all — not even the project trust entry, which lands
# in the operator's own config and is meaningless without the tool that reads it.
tmp.write_text('model = "keep"\n')
code, text = run_main(tmp, which=None, discovered={}, declares=2)
check("no codex on PATH returns 0", code == 0)
check("no codex on PATH writes nothing", text == 'model = "keep"\n', text)

# A discovery that misses hooks must fail before the hooks.state write. The
# hooks Codex did not return keep a stale hash and silently stop running.
tmp.write_text('model = "keep"\n')
code, text = run_main(tmp, which="/usr/bin/codex",
                      discovered={"/r/.codex/hooks.json:stop:0:0": "sha256:a"}, declares=3)
check("partial discovery returns 1", code == 1)
check("partial discovery writes no hook state", "hooks.state" not in text, text)
check("partial discovery still trusted the project",
      parses(text)[0]["projects"]["/r"]["trust_level"] == "trusted", text)

# The matching case still writes, so the guard above is not just refusing work.
tmp.write_text('model = "keep"\n')
code, text = run_main(tmp, which="/usr/bin/codex",
                      discovered={"/r/.codex/hooks.json:stop:0:0": "sha256:a"}, declares=1)
check("matching discovery returns 0", code == 0)
check("matching discovery writes the hook state",
      parses(text)[0]["hooks"]["state"]["/r/.codex/hooks.json:stop:0:0"]["trusted_hash"]
      == "sha256:a", text)
tmp.unlink()

print("\n" + ("ALL PASS" if fails == 0 else f"{fails} FAILED"))
sys.exit(1 if fails else 0)
