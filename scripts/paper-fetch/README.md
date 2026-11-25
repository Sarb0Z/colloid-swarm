# paper-fetch

Get the papers a CSV lists, one folder per paper, and push them to a catalogue
such as Zotero. The tool is infrastructure. It ships no source, no converter and
no sink. You add those as plugins.

Run the tool by its path from any project. The folder is not part of the harness
export or the public port.

```
python3 -I scripts/paper-fetch/papers.py status  --manifest M --root P
python3 -I scripts/paper-fetch/papers.py sources [--plugins DIR]
python3 -I scripts/paper-fetch/papers.py fetch   --manifest M --root P [--only KEY,KEY] [--limit N] [--sources a,b] [--force] [--dry-run]
python3 -I scripts/paper-fetch/papers.py push    --manifest M --root P --sink NAME [--only KEY,KEY] [--force] [--apply]
```

`M` is a CSV with a `key` column and a `doi` column. Other columns are kept and
given to plugins. `P` is the project folder. Example:
`M=~/Projects/product-61/data/curated/papers_needed.csv`.

A key must match `[a-z0-9][a-z0-9-]*`, because it names a folder.

## What the tool does

| Command | Effect |
|---|---|
| `status` | Print every paper's state. Read only. Makes no request. |
| `sources` | List the loaded plugins. |
| `fetch` | For each paper: use a file saved by hand, else the inbox, else ask each source for addresses, download the first good one, save it, convert it. |
| `fetch --dry-run` | Ask the sources and print their addresses. Download nothing. Write nothing. It takes no lock, and its requests are real: each paper that reaches a source counts toward `--limit` and toward the per-host cap. It skips a paper with a file saved by hand or in the inbox, as the real run does. |
| `push` | Print each sink's plan. Write nothing. |
| `push --apply` | Call the sink's `push` and record the ids it returns. |

A session that runs `push --apply` writes to an outside system. Get the
operator's approval for each such run. The project has no publish guard, so
nothing but `--apply` and that rule stops it.

## Where files go

All paths are under the project folder `P`.

| Path | Holds |
|---|---|
| `data/external/paper-<key>/original.pdf` (or `.xml`, `.html`) | The downloaded file |
| `data/external/paper-<key>/fulltext.md` | The text the converter returned. The project's quote checker reads this file. |
| `data/external/papers_ledger.csv` | One row per outcome. Append only. |
| `data/raw/papers/<key>.pdf` | The inbox. Save a paper here by hand and `fetch` uses it. |

The manifest may have a `save_as` column. That path is also an inbox. A `.pdf` is
used as the original. A `.md` or `.txt` is copied to `fulltext.md`.

The quote checker accepts exactly one of `page.html`, `fulltext.xml`,
`fulltext.md`, `article.xml`, `record.json` and `study.json` in a paper folder.
The tool never writes a second one. A plugin must not write in a paper folder.

**A file saved by hand is never overwritten.** If one of those six names is in the
folder and the tool did not write it, the tool records it as `converted` with source
`hand` and leaves it as it is, even with `--force`. If a person edits a file the tool
wrote, it becomes theirs.

A run killed after it wrote `fulltext.md` and before it recorded the row leaves a
file the next run reads as saved by hand. To get a tool-written file back, delete
`fulltext.md` and run `fetch` again. The window is a few milliseconds wide.

The tool does not write outside those paths. A plugin runs with full Python access
and the tool cannot stop it from writing elsewhere. The tool detects only a sink that
changes a paper folder (see Plugins).

## States

The ledger holds two stages per paper. The latest row for a key and stage is its state.

| Stage | State | Meaning |
|---|---|---|
| fetch | (none) | `pending`: nothing done |
| fetch | `fetched` | A valid file is saved. No text yet, or the converter crashed and the next run will convert it again. |
| fetch | `converted` | Text the quote checker reads exists: `fulltext.md` written by the tool or copied from the inbox, or a file saved by hand (source `hand`) |
| fetch | `awaiting-inbox` | No source offered a file. The expected inbox path is printed. |
| fetch | `blocked` | Every candidate failed and one was a challenge page or HTTP 401, 403 or 429 |
| fetch | `needs-text` | The converter found no text layer. The file stays. |
| fetch | `failed` | Any other reason. The ledger row says why. |
| push | `pushed` | The sink stored the paper. The row holds the ids it returned. |
| push | `failed` | The sink raised. The fetch state does not change. |

What each command does with each fetch state:

| Fetch state | `fetch` | `push` |
|---|---|---|
| pending, `awaiting-inbox`, `blocked`, `failed` | Full attempt | Skipped |
| `fetched` | Convert only. No download. (A full attempt if the saved file is gone.) | Pushed |
| `converted`, `needs-text` | Skipped. `--force` makes a full attempt. | Pushed |

`push` also skips a paper whose push state is `pushed`. `--force` pushes it again.
A push that failed is tried again. When one candidate is blocked and a later one
failed, the paper ends `blocked`.

`--force` means redo. A forced attempt that fails records its failure, so a paper
that was `converted` can become `blocked` or `failed`. The attempt removes nothing it
did not replace, and it never overwrites a file the tool did not write.

Order. Papers with no fetch state come before papers that failed earlier, each group
in manifest order. A known failure then cannot use up the request budget that an
untried paper needs.

`--limit N` counts a paper only when it reaches a source. A paper served from the
inbox or a file saved by hand does not count. A dry run counts the same way.

An unexpected error on one paper (not a plugin's own error) is recorded as `failed`
with the error type, and the run goes on to the next paper.

## Politeness

- One request at a time. A base delay per host plus random jitter. `fetch` defaults
  to 1500 ms and 1200 ms. `push` defaults to 500 ms and 300 ms.
- A cap on requests per host per run. `fetch`: 25. `push`: 1000, or the sink's
  `MAX_REQUESTS_PER_HOST`. The request after the cap stops the run with exit code 3.
  Papers the run did not reach are left as they were.
- Each retry counts against the cap.
- `GET` and `HEAD` retry up to 3 times on a network error, 429, 500, 502, 503 and
  504, with exponential backoff. Other methods retry only on 429, unless the caller
  passes `idempotent=True`.
- `Retry-After` and `Backoff` are honoured. A pause longer than 120 seconds stops the
  run. A `Backoff` header never discards a response already received: it pauses the
  next request to that host.
- A failure that will recur on every try (a malformed address, an unsupported
  encoding, an undecodable or oversized body) is not retried.
- Redirects are followed one hop at a time. Each hop is printed and counted against
  its own host. Only `http` and `https` addresses are allowed.
- Every address the client reads is printed. The client sends an honest user agent.
- A body cut off before its declared length is refused, so a truncated PDF is never saved.

These rules bind the client. A plugin should make every request through `http`. The
tool cannot stop a plugin that opens its own connection, so that is the plugin's
obligation, not a guarantee of the tool.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | The run finished. Some papers may still be `failed`. Read the report. |
| 2 | Bad input: a manifest row, a `save_as` that leaves the project, an option, a plugin file, a path |
| 3 | A host cap or a long server pause stopped the run. The last line says `stopped early`. |
| 4 | Another run holds the ledger lock |

A run that writes holds an exclusive lock on the ledger file. A second writing run exits 4.
`status`, `fetch --dry-run` and `push` without `--apply` take no lock.

## Secrets

Plugins read secrets from the environment. Before the tool prints or stores any text
it replaces the value of each variable whose name contains `KEY`, `TOKEN`,
`SECRET`, `PASS`, `AUTH` or `CREDENTIAL` (value of 8 or more characters) with
`[redacted:NAME]`. It also redacts the value of a query parameter named `key`,
`api_key`, `apikey`, `token`, `access_token`, `secret` or `password`. A secret in a
parameter of another name, or in a variable of another name, is not found.

## Plugins

A plugin is one `.py` file in `plugins/sources/`, `plugins/converters/` or
`plugins/sinks/`, or in the same folders of another tree given with `--plugins`.
A file whose name starts with `_` is a template and is never loaded. A plugin that
does not fit its contract stops the load and is named.

Each folder has a `_template.py`. Copy it and drop the underscore.

```python
# sources/<name>.py: where might this paper's file be? Returns addresses; downloads nothing.
NAME = "example"                       # [a-z0-9][a-z0-9-]*; the name --sources takes
HOST_INTERVALS_MS = {"host": 3000}     # optional: a slower pace for a host
def locate(paper, http) -> list[Candidate]: ...

# converters/<name>.py: text from a saved file. Raise NoText or WrongPaper.
NAME = "example-pdf"
ACCEPTS = ("pdf",)                     # "pdf", "xml" or "html"
def convert(paper, path, run) -> str: ...

# sinks/<name>.py: store a paper elsewhere.
NAME = "example-sink"
MAX_REQUESTS_PER_HOST = 2000           # optional
def plan(paper, folder, http) -> list[str]: ...          # read-only client
def push(paper, folder, http) -> dict[str, str]: ...     # returns external ids
```

- `paper` has `key`, `doi` and `row`, the whole manifest row.
- A `Candidate` has `url`, `kind` (`pdf`, `xml` or `html`), `source` and `license`.
  Import it from `paperfetch.model`.
- `http.get(url)` and `http.request(method, url, headers, body, idempotent)` return a
  response with `.status`, `.headers` (lower-case names), `.body` and `.url`.
- `run(argv)` runs a command and returns its output. Do not import `subprocess`.
- `convert` receives the paper, so it can check the file against `paper.doi` and the
  manifest row. `NoText` makes the paper `needs-text`. `WrongPaper("why")` makes it
  `failed` with reason `identity` and removes the copy the tool saved. An inbox file is
  never removed. Any other error leaves the paper `fetched` and the file in place, so
  the next run converts it again without downloading it.
- A plugin `NAME` may not be `hand` or `inbox`: the ledger reads those as a person and
  the inbox.
- With no `--sources` flag, every source runs in name order. With two converters for
  one kind, the first by name converts.
- The client given to `plan` and to every dry-run call refuses any method except
  `GET` and `HEAD`.
- A sink must make `push` safe to repeat: look the paper up before it creates one. A
  write may pass `idempotent=True` to be retried after a network error only when the
  server accepts it twice, for example with a one-time token. Without it the client does
  not retry that write.
- Once `push` returns, the remote write has happened, so the ledger records `pushed`
  even if the sink broke a rule: it returned ids that are not all strings (stored as
  text) or it changed a file in the paper folder (found by name, size and modification
  time). The row and the console carry a warning. Recording `failed` would make the
  next run write the same thing again. A sink that returns something other than a dict
  ends `failed`.

## Tests

```
python3 scripts/paper-fetch/test-papers.py
```

The tests use fake plugins and a local HTTP server. They need no network and no
project. CI runs them on Python 3.14.
