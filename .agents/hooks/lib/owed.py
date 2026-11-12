#!/usr/bin/env python3
"""What a session still owes: five flags computed from its own records.

A flag informs and never blocks. Each is true only while something is owed,
and only for what THIS session did: `edit-record.sh` keeps, per session key
(the cksum of the session id), the paths its editors wrote
(`.agents/.wrap-edits-<key>`) and the commits it made
(`.agents/.wrap-commits-<key>`), so history from before the session and other
sessions' commits never raise one.

  review    a critical-path file the session committed has no review record
            covering its content. Cover is by file content: a record
            `docs/reviews/<date>-<slug>.md` carries one line
            `Covers: <base>..<tip>`; the file is `reviewed` when its content at
            HEAD equals its content at a record's tip, `changed since review`
            when a record's range touched it and the content has moved, and
            `unreviewed` otherwise. A record whose base or tip git cannot
            resolve covers nothing and is named.
  suite     a path the session wrote differs between the working tree and the
            tree of the last passing run of `owed.suite` (`suite.sh` records
            that tree), or no pass is recorded.
  report    raised with `raise report`, cleared by `clear report`.
  worklog   the work log is on and today's file is older than the session's
            newest commit.
  cleanup   resources the teardown ledger holds for the session, worktrees it
            created that still exist, untracked files it wrote.

`owed.critical_paths` (globs) and `owed.suite` (one command) are read from
`.agents/policy.json` only: which paths need review and what the suite is are
repository decisions, beyond one operator's `config.json`.

Usage:
  owed.py write [--repo DIR] --session ID [--key KEY]   write the `owed` readout, print its strip
  owed.py show  [--repo DIR] --session ID [--key KEY]   print the strip and note
  owed.py push-line [--repo DIR]                        review-line for what a
                                          `git push` from DIR carries
  owed.py review-line REVRANGE [--repo DIR]             critical files a commit
                                          range carries that no record covers
  owed.py raise report [--repo DIR] --session ID [--tier diff|large|investigation]
  owed.py clear report|learning [--repo DIR] [--session ID]   no session: every one
            `learning` is raised beside `report` while hooks.learning_report.enabled
            is true, and names .agents/playbooks/learning-report.md
  owed.py tree [--repo DIR]                             tree hash of the work tree
  owed.py record-pass TREE [--repo DIR]                 remember a passing tree
  owed.py suite-command [--repo DIR]                    print `owed.suite`
"""
import argparse
import glob
import importlib.util
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_REPO = str(HERE.parents[2])
sys.path.insert(0, str(HERE))
import config  # noqa: E402

COVERS = re.compile(r"^Covers:[ \t]*(\S+?)\.\.(\S+)[ \t]*$", re.M)
HASH = re.compile(r"[0-9a-fA-F]{7,64}")
STATES = ("changed since review", "unreviewed")
# A push with no remote branch to measure against carries every commit of the
# history; the line reads the newest ones only and says so.
NO_REMOTE_LIMIT = 200
REPORT_PLAYBOOKS = {
    "diff": "crossed the diff tier: .agents/playbooks/diff-wrap.md, then report-implementation.md",
    "large": "crossed the large tier: .agents/playbooks/diff-wrap.md, hostile-review.md, "
             "then report-implementation.md",
    "investigation": "a long session with no diff: .agents/playbooks/report-investigation.md",
}


def git(repo, *args, env=None, check=False, input=None):
    clean = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    clean.update(env or {})
    result = subprocess.run(["git", "--literal-pathspecs", "-C", str(repo), *args],
                            capture_output=True, text=True, env=clean, input=input)
    if check and result.returncode:
        raise RuntimeError(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout if result.returncode == 0 else None


def policy(repo):
    document = config.read_json(os.path.join(repo, ".agents", "policy.json"))
    owed = document.get("owed") if isinstance(document, dict) else None
    return owed if isinstance(owed, dict) else {}


def critical_regexes(repo):
    return [glob_regex(pattern) for pattern in policy(repo).get("critical_paths") or []
            if isinstance(pattern, str)]


def glob_regex(pattern):
    """`**` crosses directories, `*` and `?` stop at a slash."""
    out, index = "", 0
    while index < len(pattern):
        if pattern.startswith("**/", index):
            out, index = out + "(?:.*/)?", index + 3
        elif pattern.startswith("**", index):
            out, index = out + ".*", index + 2
        elif pattern[index] == "*":
            out, index = out + "[^/]*", index + 1
        elif pattern[index] == "?":
            out, index = out + "[^/]", index + 1
        else:
            out, index = out + re.escape(pattern[index]), index + 1
    return re.compile(out + r"\Z")


def cksum_key(ident):
    """The record key edit-record.sh and session-wrap.sh derive: `cksum` with
    the space between its checksum and its byte count removed."""
    result = subprocess.run(["cksum"], input=ident.encode(), capture_output=True, check=True)
    return "".join(result.stdout.decode().split())


def lines(path):
    try:
        return Path(path).read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return []


def session_commits(repo, key):
    """The session's recorded commits that git still resolves."""
    found = []
    for commit in dict.fromkeys(lines(Path(repo) / ".agents" / f".wrap-commits-{key}")):
        if git(repo, "cat-file", "-e", f"{commit}^{{commit}}") is not None:
            found.append(commit)
    return found


def commit_files(repo, commits):
    files = []
    for commit in commits:
        out = git(repo, "show", "--first-parent", "-m", "--name-only", "--no-renames",
                  "--format=", commit)
        files += [line for line in (out or "").splitlines() if line]
    return list(dict.fromkeys(files))


def edited_files(repo, key):
    paths = []
    for line in lines(Path(repo) / ".agents" / f".wrap-edits-{key}"):
        _, _, path = line.partition("\t")
        if path:
            paths.append(path)
    return list(dict.fromkeys(paths))


def resolves(repo, rev):
    return git(repo, "rev-parse", "-q", "--verify", f"{rev}^{{commit}}") is not None


def records(repo):
    """([(base, tip, name)] with both ends resolvable, [names git cannot resolve]).
    An end must be a hexadecimal object name of at least seven digits: `HEAD`
    or a branch name moves with later commits and would cover them."""
    good, unresolved = [], []
    for path in sorted(glob.glob(os.path.join(repo, "docs", "reviews", "*.md"))):
        text = Path(path).read_text(encoding="utf-8", errors="replace")
        for base, tip in COVERS.findall(text):
            name = os.path.relpath(path, repo)
            if HASH.fullmatch(base) and HASH.fullmatch(tip) and resolves(repo, base) and resolves(repo, tip):
                good.append((base, tip, name))
            else:
                unresolved.append(f"{name} (Covers: {base}..{tip})")
    return good, unresolved


def blob(repo, rev, path):
    out = git(repo, "rev-parse", "-q", "--verify", f"{rev}:{path}")
    return out.strip() if out else None


def review_states(repo, files):
    """{file: state} for each critical-path file in `files` that exists at HEAD,
    and the unresolvable record names. A record covers a file only when its
    range touched the file: the file is `reviewed` when its content at the
    record's tip equals HEAD, and `changed since review` when a record touched
    it and the content has moved."""
    patterns = critical_regexes(repo)
    critical = [f for f in files if any(p.match(f) for p in patterns) and blob(repo, "HEAD", f)]
    if not critical:
        return {}, []
    good, unresolved = records(repo)
    touched = {}
    for base, tip, _ in good:
        touched[(base, tip)] = set((git(repo, "diff", "--name-only", "--no-renames", base, tip) or "").splitlines())
    states = {}
    for path in critical:
        head = blob(repo, "HEAD", path)
        seen = [(base, tip) for (base, tip), names in touched.items() if path in names]
        if any(blob(repo, tip, path) == head for _, tip in seen):
            states[path] = "reviewed"
        elif seen:
            states[path] = "changed since review"
        else:
            states[path] = "unreviewed"
    return states, unresolved


def review_line(repo, rev_range, limit=None):
    """One line for a push prompt: the critical-path files in `rev_range` that no
    record covers, empty when none. `limit` bounds the commits read, newest
    first; a line that hit the bound says so."""
    if not critical_regexes(repo):
        return ""
    bound = [f"--max-count={limit}"] if limit else []
    commits = git(repo, "rev-list", "--no-merges", *bound, *rev_range.split(), check=True).split()
    states, unresolved = review_states(repo, commit_files(repo, commits))
    parts = []
    for state in STATES:
        names = [f for f, s in states.items() if s == state]
        if names:
            parts.append(f"{state}: {', '.join(names)}")
    if unresolved:
        parts.append(f"records git cannot resolve: {', '.join(unresolved)}")
    line = "critical-path files without a covering review record: " + "; ".join(parts) if parts else ""
    if limit and len(commits) >= limit:
        line = (line + " " if line else "") + f"Only the newest {limit} commits were read."
    return line


def push_line(here):
    """`review_line` for the commits a `git push` run in `here` carries: those
    after the upstream, or, with none, the newest commits on no remote."""
    top = (git(here, "rev-parse", "--show-toplevel", check=True)).strip()
    if git(top, "rev-parse", "-q", "--verify", "@{u}") is not None:
        return review_line(top, "@{u}..HEAD")
    return review_line(top, "HEAD --not --remotes", limit=NO_REMOTE_LIMIT)


def tree(repo):
    """The tree object of the work tree: tracked and untracked, unignored files."""
    with tempfile.TemporaryDirectory() as scratch:
        env = {"GIT_INDEX_FILE": os.path.join(scratch, "index")}
        if git(repo, "rev-parse", "-q", "--verify", "HEAD"):
            git(repo, "read-tree", "HEAD", env=env, check=True)
        git(repo, "add", "-A", "--", ".", env=env, check=True)
        return git(repo, "write-tree", env=env, check=True).strip()


def pass_file(repo):
    return Path(repo) / ".agents" / ".readout" / "suite-pass"


def record_pass(repo, tree_hash):
    path = pass_file(repo)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(tree_hash + "\n", encoding="utf-8")


def suite_flag(repo, written):
    """(paths that differ from the last pass, whether a pass is recorded)."""
    if not policy(repo).get("suite") or not written:
        return [], True
    recorded = (lines(pass_file(repo)) or [""])[0].strip()
    if recorded and git(repo, "cat-file", "-e", f"{recorded}^{{tree}}") is None:
        recorded = ""
    if not recorded:
        return list(written), False
    return changed_since(repo, recorded, written), True


def changed_since(repo, recorded_tree, paths):
    """The `paths` whose content in the work tree differs from `recorded_tree`.
    Only these paths are hashed, with `git hash-object` and no `-w`, so a Stop
    neither walks the tree nor writes objects. A path git ignores is not in a
    recorded tree and is skipped."""
    listed = set((git(repo, "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--",
                      *paths) or "").split("\0"))
    present = [p for p in paths if p in listed and os.path.isfile(os.path.join(repo, p))]
    hashes = {}
    if present:
        out = git(repo, "hash-object", "--stdin-paths", input="\n".join(present) + "\n", check=True)
        hashes = dict(zip(present, out.split()))
    recorded = {}
    for row in (git(repo, "ls-tree", "-r", "-z", recorded_tree, "--", *paths) or "").split("\0"):
        meta, _, path = row.partition("\t")
        if path:
            recorded[path] = meta.split()[2]
    ignored = {p for p in paths if p not in listed and os.path.isfile(os.path.join(repo, p))}
    return [p for p in paths if p not in ignored and hashes.get(p) != recorded.get(p)]


def worklog_flag(repo, commits):
    if not commits:
        return ""
    committed = (git(repo, "log", "-1", "--format=%ct", commits[-1]) or "").strip()
    if not committed.isdigit():
        return ""
    result = subprocess.run([sys.executable, str(HERE / "worklog.py"), repo],
                            capture_output=True, text=True)
    answer = result.stdout.split("\n")
    if answer[0] != "ok":
        return ""
    day_file = answer[1]
    try:
        if os.path.getmtime(day_file) >= int(committed):
            return ""
    except FileNotFoundError:
        pass
    return day_file


def cleanup_items(repo, session, written):
    items = []
    ledger = Path(repo) / ".agents" / f".teardown-pending-{session}"
    for line in lines(ledger):
        fields = line.split("\t")
        if line.startswith("#") or len(fields) < 4 or fields[0] == "worktree":
            continue
        items.append(f"{fields[0]}: {fields[3]}")
    wt = load_module("worktree_records")
    records_file = wt.records_dir(repo) / f"{wt.session_key(session)}.jsonl"
    if session and records_file.is_file():
        for entry in wt.load(records_file):
            if entry.get("type") == "worktree" and os.path.isdir(entry.get("path", "")):
                items.append(f"worktree: {entry['path']}")
    untracked = set((git(repo, "ls-files", "--others", "--exclude-standard") or "").splitlines())
    items += [f"untracked: {p}" for p in written if p in untracked]
    return list(dict.fromkeys(items))


def load_module(name):
    spec = importlib.util.spec_from_file_location(name, HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


RAISED = ("report", "learning")


def marker_for(repo, flag, key):
    """The file that holds a raised flag; a `*` key matches every session's."""
    return Path(repo) / ".agents" / ".readout" / f"owed-{flag}--{key}"


def learning_enabled(repo):
    """The opt-in pairing mode: false unless exactly `true`."""
    return config.read(config.load(os.path.join(repo, ".agents", "config.json")),
                       "hooks.learning_report.enabled", False)


def compute(repo, session, key):
    """({flag: [detail lines]}, strip) for the session; flags absent when nothing is owed."""
    commits = session_commits(repo, key)
    edits = edited_files(repo, key)
    committed = commit_files(repo, commits)
    written = list(dict.fromkeys(edits + committed))
    flags = {}

    states, unresolved = review_states(repo, committed)
    owed_files = [f"{f} ({s})" for f, s in states.items() if s in STATES]
    if owed_files or unresolved:
        flags["review"] = (len(owed_files), owed_files + [f"record git cannot resolve: {u}" for u in unresolved])

    stale, recorded = suite_flag(repo, written)
    if stale:
        why = "no passing run recorded" if not recorded else "changed since the last passing run"
        flags["suite"] = (None, [f"{policy(repo)['suite']}: {why}"] + stale)

    marker = marker_for(repo, "report", key)
    if marker.is_file():
        tier = (lines(marker) or [""])[0].strip()
        flags["report"] = (None, [f"a session report is owed: {REPORT_PLAYBOOKS.get(tier, 'see .agents/playbooks/report-implementation.md')}"])
    if marker_for(repo, "learning", key).is_file():
        flags["learning"] = (None, ["a pairing-mode learning report is owed, outside any skip: .agents/playbooks/learning-report.md"])

    day_file = worklog_flag(repo, commits)
    if day_file:
        flags["worklog"] = (None, [f"{day_file} is older than the session's last commit"])

    items = cleanup_items(repo, session, written)
    if items:
        flags["cleanup"] = (len(items), items)

    order = ("review", "suite", "report", "learning", "worklog", "cleanup")
    segments = [f + (f" {flags[f][0]}" if flags[f][0] else "") for f in order if f in flags]
    strip = "owed: " + " · ".join(segments) if segments else ""
    return flags, strip


def note_of(flags):
    return "\n".join(f"{flag}: " + "; ".join(details) for flag, (_, details) in flags.items())


def write_readout(repo, session, key):
    flags, strip = compute(repo, session, key)
    readout = load_module("readout")
    readout.write(repo, "owed", strip=strip, note=note_of(flags), session=session)
    return flags, strip


def main(argv):
    parser = argparse.ArgumentParser(prog="owed.py", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)

    def common(p, session=False, required=False):
        p.add_argument("--repo", default=DEFAULT_REPO)
        if session:
            p.add_argument("--session", required=required, default="")
            p.add_argument("--key", default="")

    for name in ("write", "show"):
        common(sub.add_parser(name), session=True, required=True)
    p = sub.add_parser("review-line"); p.add_argument("range"); common(p)
    common(sub.add_parser("push-line"))
    p = sub.add_parser("raise"); p.add_argument("flag", choices=["report"]); common(p, True, True)
    p.add_argument("--tier", choices=sorted(REPORT_PLAYBOOKS), default="")
    p = sub.add_parser("clear"); p.add_argument("flag", choices=RAISED); common(p, True)
    common(sub.add_parser("tree"))
    p = sub.add_parser("record-pass"); p.add_argument("tree"); common(p)
    common(sub.add_parser("suite-command"))
    args = parser.parse_args(argv)

    key = getattr(args, "key", "") or (cksum_key(args.session) if getattr(args, "session", "") else "")
    if args.command == "write":
        print(write_readout(args.repo, args.session, key)[1])
    elif args.command == "show":
        flags, strip = compute(args.repo, args.session, key)
        print(strip)
        print(note_of(flags))
    elif args.command == "push-line":
        line = push_line(args.repo)
        if line:
            print(line)
    elif args.command == "review-line":
        line = review_line(args.repo, args.range)
        if line:
            print(line)
    elif args.command == "raise":
        marker = marker_for(args.repo, "report", key)
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(f"{args.tier}\n", encoding="utf-8")
        # The pairing-mode learning report rides beside a report that follows
        # work, not beside a long investigation.
        if args.tier != "investigation" and learning_enabled(args.repo):
            marker_for(args.repo, "learning", key).write_text("1\n", encoding="utf-8")
    elif args.command == "clear":
        markers = [marker_for(args.repo, args.flag, key)] if key else sorted(
            Path(args.repo, ".agents", ".readout").glob(f"owed-{args.flag}--*"))
        for marker in markers:
            marker.unlink(missing_ok=True)
    elif args.command == "tree":
        print(tree(args.repo))
    elif args.command == "record-pass":
        record_pass(args.repo, args.tree)
    else:
        command = policy(args.repo).get("suite")
        if not command:
            print("owed.py: .agents/policy.json declares no owed.suite", file=sys.stderr)
            return 1
        print(command)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
