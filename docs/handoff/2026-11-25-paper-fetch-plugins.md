# Handoff: the paper-fetch plugins

Written 2026-11-25. The reader may be the operator or any model or person the
operator chooses. Everything needed is in this file and the files it names.

## Objective

Make the tool at `scripts/paper-fetch/` get the 28 papers in
`~/Projects/product-61/data/curated/papers_needed.csv`, turn each
into text the project's quote checker can read, and push each to Zotero. The
tool is built and has no plugins. This handoff covers the plugins.

The purpose of the project is to evaluate the model and the harness on scientific
work. The data is generic. The goal is the harness's behaviour, not the
research.

## Not in this handoff

Any source beyond the four below. The tool does not depend on any one source: another
source is one more file in `plugins/sources/`. The papers that no source finds end as
`awaiting-inbox` and name the file to save by hand (`data/raw/papers/<key>.pdf`).

## Current state

Built, committed on `main` of this repository, reviewed by a fresh reviewer and a QA
cell, and tested (144 tests, Python 3.14 and 3.15; the suite is
`python3 scripts/paper-fetch/test-papers.py`, in `check-all.sh` and CI):

- Commands `status`, `sources`, `fetch`, `push`, the ledger, the state table, the
  inbox, the polite client, the plugin loader, the dry run that cannot write.
- `scripts/paper-fetch/README.md` is the reference: states, transition table, exit
  codes, the three plugin contracts. Read it first. `plugins/*/_template.py` holds one
  template per kind, with the rules in its docstring.
- `tests/fetchcase.py`, `tests/test_fetch.py` and `tests/test_push.py` show how to test a
  plugin: write a fake plugin, point it at a local `http.server`, run the CLI.
- The README command `fetch --manifest data/curated/papers_needed.csv --root .` run from
  the project folder ends all 28 papers `awaiting-inbox` until a source exists. Run it first
  in a scratch copy, not in the project, which other sessions are editing.

Not built: every plugin below. The project README points to the tool.

## Evidence the plugins rest on

| Fact | How it was observed |
|---|---|
| 28 papers, a DOI in each row, columns `key,study,doi,reference,needed_for,unchecked_counts,save_as` | read the CSV |
| 11 of 28 are open access (8 bronze, 2 gold, 1 green); 17 closed | OpenAlex `works?filter=doi:…`, 2026-11-25 |
| 3 have a PMC copy: `gaudino-2018`, `harik-2023`, `danek-2020`. None is on arXiv, medRxiv or bioRxiv. | OpenAlex `locations`, 2026-11-25 |
| Europe PMC search returns `pmcid`, `isOpenAccess`, `license`, `fullTextUrlList` for a DOI | `…/europepmc/webservices/rest/search?query=DOI:10.3389/fcvm.2023.1125126&format=json&resultType=core` returned `PMC10031065`, `isOpenAccess: Y`, `license: cc by` |
| Europe PMC serves JATS XML at `…/rest/<PMCID>/fullTextXML` | a request for `PMC10151570` returned HTTP 200, `application/xml` (a real article; the id was a guess, so this shows the endpoint, not a paper in the list) |
| Whether Wiley, AHA journals, OUP and ScienceDirect give a plain client their free-to-read PDFs | not read; the first run of a source will show |
| `pdftotext` is at `/opt/homebrew/bin/pdftotext`; Python 3.14 and 3.15, `uv` exist | `which`, `--version` |
| Zotero is not installed here; no `ZOTERO_*` variable is set | `ls`, `env` |
| Zotero web API v3 facts (below) | zotero.org `…/web_api/v3/file_upload`, `…/write_requests`, `…/basics`, read 2026-11-25 |
| The quote checker reads one of `page.html fulltext.xml fulltext.md article.xml record.json study.json` per `data/external/paper-<key>/` and `.md` is read as plain text | `scripts/verify_counts.py`, `scripts/source_text.py` in the project |

## The work

Each item is one file under `scripts/paper-fetch/plugins/`. Build in this order. After each,
run `python3 -I scripts/paper-fetch/papers.py fetch --manifest M --root T --only KEY`
against a scratch root `T` (a copy of nothing: an empty folder) and read the ledger and
the folder. Do not run against the project folder until the scratch run is right.

### 1. Source `europepmc` (`sources/europepmc.py`)

`locate` asks the search endpoint above with the paper's DOI. When the result has a
`pmcid` and `isOpenAccess` is `Y`, return a `Candidate` of kind `xml` for
`…/rest/<pmcid>/fullTextXML`, and one of kind `pdf` for the `fullTextUrlList` entry whose
`availability` is `Open access` and `documentStyle` is `pdf`. Put `license` in the
candidate. Return `[]` otherwise.

Acceptance: `fetch --only harik-2023,gaudino-2018,danek-2020 --sources europepmc`
ends each in `fetched`, with `original.xml` that starts `<?xml`.

### 2. Source `openalex` (`sources/openalex.py`)

`GET https://api.openalex.org/works/doi:<doi>` returns `open_access.is_oa`,
`open_access.oa_status`, `open_access.oa_url`, and `locations[]` with `landing_page_url` and
`pdf_url`. Return a `pdf` candidate for each distinct `pdf_url` of an open location. No key is
needed. A contact address in a `mailto` parameter is optional and the operator's to give.

Acceptance: for the 11 open papers, `locate` returns at least one candidate; for the 17
closed ones, `[]`. Expect some publisher links to answer with a challenge page; the tool
records those as `blocked` and names the host. The tool does not defeat a bot wall.

### 3. Source `arxiv` (`sources/arxiv.py`)

The operator prefers arXiv. The API is `export.arxiv.org/api/query`. Its terms ask for one
request every three seconds, so declare `HOST_INTERVALS_MS = {"export.arxiv.org": 3000}`.
Search by DOI, then by title. Return a `pdf` candidate for an exact match only; a fuzzy title
match must be compared before it is trusted. None of the 28 papers is on arXiv, so this
source returns `[]` for the whole manifest; test it with a known arXiv paper in a fixture.

### 4. Source `unpaywall` (`sources/unpaywall.py`)

`GET https://api.unpaywall.org/v2/<doi>?email=<mailbox>` returns `oa_locations[]` with
`url_for_pdf`, `url_for_landing_page`, `license`. It rejects placeholder mailboxes. Read the
mailbox from an environment variable named in the plugin (for example
`PAPER_FETCH_CONTACT_EMAIL`), return `[]` with a clear raised error when it is unset, and never
write it in a file. The operator supplies the mailbox.

### 5. Converter `pdftotext` (`converters/pdftotext.py`)

`ACCEPTS = ("pdf",)`. `text = run(["/opt/homebrew/bin/pdftotext", "-layout", str(path), "-"])`.
The signature is `convert(paper, path, run)`. Raise `NoText` when the text has almost no
characters (a scan). Return the text unchanged. Identity check: raise `WrongPaper("…")` when
`paper.doi` does not appear in the text. Many journals print the DOI on the first page, so a
miss is a signal, not proof. The manifest has `study`, not a title, for most rows, so a title
check needs a Crossref lookup; decide whether it is worth it before building it. Any other
error leaves the paper `fetched` and the next run converts it again without a download, so a
missing `pdftotext` costs no request.

Write a second converter for `xml` (JATS from Europe PMC): strip tags, keep each table row on
its own line, keep numbers and their units together. The checker collapses whitespace
and plain-izes quotation marks, so layout matters less than not losing digits.

Acceptance: `fetch --only harik-2023` with `europepmc` and the XML converter ends
`converted`, and `python3 -I P/scripts/source_text.py T/data/external/paper-harik-2023/fulltext.md "<a phrase from the paper>"`
prints a match.

### 6. Sink `zotero` (`sinks/zotero.py`)

Zotero is not installed here, so use the web API. Facts (read 2026-11-25):

- Base `https://api.zotero.org`. A user library is `/users/<userID>`, a group library
  `/groups/<groupID>`. The user ID is a number on the API Keys page, not the username.
- Headers: `Zotero-API-Key: <key>` and `Zotero-API-Version: 3`.
- A write holds at most 50 objects. `Zotero-Write-Token` (32 characters) makes a write
  safe to repeat for 12 hours; reusing a token gives 412. A multi-object reply lists
  `successful`, `unchanged` and `failed` by index.
- A file goes up in four steps: create the attachment item (`parentItem` set), `POST
  …/items/<key>/file` with `md5`, `filename`, `filesize`, `mtime` in milliseconds and
  `If-None-Match: *`, then POST prefix + file bytes + suffix to the returned `url`, then
  register with `upload=<uploadKey>` (expect 204). A reply of `{"exists":1}` means the file is
  already stored.
- 413 means the storage quota. 429 carries `Retry-After`. Any reply may carry `Backoff`.
  The tool's client already honours both.

Build `plan` first: read the library through GET only, and for each paper print what it would
do (create the collection, create the item, reuse an item with this DOI, attach the file).
Then `push`: look the paper up by DOI before it creates one, create a `journalArticle` with
title, creators, publication, date, DOI and `Extra: Citation Key: <key>`, put it in the
collection, upload the saved PDF. Metadata comes from Crossref (`api.crossref.org/works/<doi>`).
Declare `MAX_REQUESTS_PER_HOST` high enough for 28 papers at about 6 requests each, and mark a
write `idempotent=True` only when it carries a write token.

Acceptance: a second `push --apply` creates nothing new; an item already in the library
with the same DOI is reused; a Zotero listing read back matches the counts the tool printed.

## Decisions the operator owes

1. Zotero library (user or group ID), the collection name, and an API key in `ZOTERO_API_KEY`.
2. A contact mailbox for Unpaywall and, optionally, Crossref and OpenAlex.
3. Whether the project ignores `data/external/paper-*/original.*`. Publisher PDFs sit under a
   tracked folder, and the project README asks to keep that folder out of anything published.
   The tool does not edit the project's `.gitignore`.

## Limits and gates

- The project has no publish guard. A session that runs `push --apply` writes to the operator's
  Zotero library. Get the operator's approval for each such run, in that session.
- Do not drive a browser. Call the APIs.
- A plugin must not write in a paper folder. The tool warns when a sink changes one.
- Read secrets from the environment. Never write one into a file or a message.
- `fetch` makes at most 25 requests per host per run. Rerun to continue.

## Exact next action

Write `sources/europepmc.py`, copying `plugins/sources/_template.py`, and run acceptance item 1
in a scratch root. No authorization is needed for that: it makes at most a few requests to
`ebi.ac.uk`, and writes only in the scratch root.
