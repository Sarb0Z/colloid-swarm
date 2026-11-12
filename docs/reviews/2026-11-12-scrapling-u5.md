# Scrapling unit 5: code review round 1

Unit 5 of `docs/handoff/2026-11-11-scrapling-review-fixes.md`: one optional
`hosts` list per `.agents/mcp.json` entry replaces `codex_enabled` and
`kimi_enabled`, by the operator's ruling `mcp-hosts-default-every-host`, and
then Scrapling lists `claude` only, so enabling it renders no OpenCode server,
where no hook runs. Commits `ed809eb` (the refactor, with the new
`.agents/mcp_hosts.py`) and `591e5aa` (Scrapling), lane `hosts` of run
`scrapling-u5`, on `76975e6`. One reviewer (opus) read the scope whole and its
seams; Critical stakes, since it changes every host's MCP renderer.

With every registry entry enabled, the reviewer rendered the five generated
host files from scratch copies of `76975e6` and `591e5aa`: they are identical
but for Scrapling leaving `.opencode/opencode.json`. Its mutations of
`591e5aa`: `mcp_hosts.renders` returning true and Kimi ignoring `hosts` each
failed `test-mcp.sh`; OpenCode ignoring `hosts` failed only the carrier-only
`test-opencode.sh` row, which an exported kit strips.

## Findings

| # | Sev | Finding | Evidence |
|---|---|---|---|
| 1 | P2 | `mcp_opencode.py:203-206` refuses a remote URL holding `${NAME}` only after `_env` has turned it into `{env:NAME}`, so the refusal never fires; enabling exa renders `…exaApiKey={env:EXA_API_KEY}` and exits 0, while `opencode/README.md:39-40` and `ed809eb`'s Seams line say OpenCode refuses it | reproduced |
| 2 | P2 | `export/README.md` has no sync step migrating the 19 satellite registries that carry the old fields, and the validator's error names `hosts` but not the mapping | inspection |
| 3 | P2 | The carrier-only matrix row derives each entry's hosts through `mcp_hosts.renders` and its own copy of the SSE filter, so no renderer defect can fail it; the SSE rule now exists three times | reproduced |
| 4 | P2 | No row an exported kit keeps proves OpenCode honours `hosts` for an enabled entry: both OpenCode exclusion fixtures are disabled | reproduced: the `payload` mutation above |
| 5 | P2 | `opencode/README.md:13` says `mcp.servers` holds "enabled servers only" | inspection |

`mcp.py` (329 lines), `test-mcp.sh` (443) and `test-codex.sh` (469) were over
300 before the unit. Judged not defects: persona-scoped `scrapling_*` denies
still emitted when OpenCode does not render Scrapling, which `test-opencode.sh`
asserts on purpose; `sources-matcher.py` ignoring `hosts`, whose patterns name
tools no other host has; `mcp-off.py` listing Claude-only servers on other
hosts, which is unit 9's breadcrumb.

HANDOFF (reviewer): a live check that OpenCode expands `{env:}` inside a remote
URL; and the plan's live QA after units 1 to 6, `mcp.py enable scrapling` in a
scratch copy followed by each host's server listing.

The reviewer ran `python3 demo/embed-src.py --help` in the checkout, which
ignores the flag and regenerated both showcase pages, byte-identical.

## Review of the review

A second cell (sonnet) labelled every finding supported and added none. On 1
it ran `server_config` on exa's URL at `591e5aa` and found the same two lines
at `ed809eb^`, so the dead branch is older than the unit. On 2 it confirmed the
error lists the valid hosts without the mapping.

AMBIGUITY (second cell): "OpenCode refuses exa's URL placeholder" — (a) a
refusal at render time was intended; (b) OpenCode expands `{env:}`, so the
refusal is obsolete; code: neither.

## Dispositions

No P0 or P1. The lead made every fix.

| # | Disposition |
|---|---|
| 1 | Adopted in `b7dff9a`, the AMBIGUITY settled as (b): OpenCode's configuration documentation (opencode.ai/docs/config, "Variables", read 2026-11-12) substitutes `{env:VARIABLE_NAME}` inside any JSON string of the config. The refusal and its unused `name` parameter go, the README says a URL's `${NAME}` becomes `{env:NAME}`, and a row pins that form. `ed809eb`'s Seams line stays as written, since other sessions commit in this checkout; `b7dff9a`'s body corrects it. The live check stays open: it rests on the documentation |
| 2 | Adopted in `40d3695`: the sync's host-state step says `mcp.py` refuses the old fields and gives each one's `hosts` list |
| 3 | Adopted in `b7dff9a`: the row writes the carrier's registry with every entry enabled into the fixture tree, with stand-ins for its repository-owned files, the reader's extension and the two credentials, runs `mcp.py`, and reads each host's set from the four generated files. Handing Scrapling to OpenCode in the registry fails it. The SSE rule now lives in the Codex and OpenCode renderers only |
| 4 | Adopted in `b7dff9a`: an enabled `fx-noopencode` entry is absent from OpenCode and present on the other three. OpenCode ignoring `hosts` now fails `test-mcp.sh` |
| 5 | Adopted in `b7dff9a` |
| Lead | Running the mutations showed a gap the review did not name: no row held an enabled SSE server without `hosts`, since `atlassian` lists its hosts, so OpenCode rendering SSE stayed green. `b7dff9a` adds that row; dropping the SSE filter from either renderer, or Codex ignoring `hosts`, now fails it |

## QA

| Claim | Command | Result |
|---|---|---|
| The refactor renders today's matrix, and Scrapling reaches Claude only | the reviewer's scratch render of all five host files at `76975e6` and `591e5aa`, every entry enabled; the matrix row at `b7dff9a` | identical but for Scrapling leaving OpenCode; the row passes on the real registry and fails with Scrapling handed to OpenCode |
| Each new row catches its defect | scratch copies of `b7dff9a`'s tree, one mutation each: OpenCode ignoring `hosts`, a raw `${NAME}` URL, OpenCode rendering SSE, Codex rendering SSE, Codex ignoring `hosts` | each failed `test-mcp.sh`; the unmutated copy passed |
| The suites | `test-mcp.sh`, `test-opencode.sh`, `test-codex.sh`, `port-public.py check`, `demo/check-inventory.py` at `b7dff9a` | all pass |

The live QA after units 1 to 6 covers the real session path.
