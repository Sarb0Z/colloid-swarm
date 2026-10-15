# Public copy

This repository can publish a sanitized copy of itself: a filtered replay of its
history with private paths dropped, private names replaced, and authors
normalized. `.agents/port-public.py` builds it; pushing it is a separate step
that needs approval.

| File | Holds |
|---|---|
| `satellites.txt` | Each private name and its public replacement. Kept in the private repository, dropped from the public copy; `satellites.txt.example` shows the format. |
| `port.json` | Dropped paths, allowed path prefixes, reviewed binaries, the authors the public history may carry, the mailmap that maps the rest, where to find names on this machine, the names that may stay, `debt:` ids in shipped code that are not real pointers, and reviewed lines. `port.json.example` shows the shape. |
| `tree/` | Starter files. Each lands at its own path with `.agents/public/tree/` removed, replacing a private record in public. `tree/.agents/debt-log.md` and the two `tree/demo/` pages are generated: `port-public.py refresh` rewrites them and `port-public.py check` fails when they are stale. |

## Port

```sh
python3 .agents/port-public.py build /tmp/public-copy --against <public-repository-url>
```

Run it from a clean checkout of `branch`. It filters, checks, and verifies in a
scratch folder beside the output and moves the copy there only when everything
passes, so a failed build leaves nothing to push. It fails when:

- a name found on this machine (folders and repositories under `sources.projects`,
  their GitHub owners and names, the hosts of their other remotes, the identity
  registry's orgs, the satellite registry) is in neither `satellites.txt`, `own`,
  nor `common_words`, or one of those sources is missing;
- any path, file version, commit message, or identity in the filtered history
  carries a replaced name, a path outside `allow`, an unreviewed binary, or an
  author outside `authors`;
- a line carries an unreviewed spelling variant of a replaced name (`Acme Co`,
  `AcmeCo2`, `acme_co`) or a common word in any case;
- shipped code carries a `debt:` pointer the debt log lacks;
- any check in the CI demo steps or the `.agents/AGENTS.md` Verification list
  fails on the filtered tree. Steps only CI runs (the SEO quick-audit test, the
  servers job, the Codex integration step) are not repeated here.

A flagged line is reviewed by adding the id the build prints to `reviewed`. The
id covers that line in that file (or in any commit message), so the same text
elsewhere is flagged again. `--against` reports a first publication when the
remote has no `branch` yet.
Re-running the build on unchanged inputs gives the same commit hashes, so a new
port fast-forwards the published branch. Changing `satellites.txt`, `drop`, or
the mailmap rewrites history from the earliest commit it touches; once a leak is
published, the fix is deleting and recreating the public repository and asking
GitHub Support to purge cached views, because a force-push leaves old commits
reachable by hash.
