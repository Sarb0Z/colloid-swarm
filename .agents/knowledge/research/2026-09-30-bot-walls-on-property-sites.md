---
date: 2026-09-30
subject: What blocks a browser agent on Zillow, Redfin, and Yelp, measured from this machine through the scaffold's `playwright` MCP entry; and where real US property addresses come from instead
kind: research
source: see `## Sources`
---

# Bot walls on property sites

An operator reported that the `playwright` MCP entry "gets blocked by zillow,
yelp, redfin". The measurements below show three sites with three different
behaviors, and one of them blocks the machine rather than the browser.

## Claims

Grades: `[P]` primary read directly · `[S]` secondary · `[?]` unverified ·
`[A]` our own measurement or analysis.

### Per site, through `@playwright/mcp@0.0.78` with no flags (branded Chrome 154, headed)

- `[A]` **Yelp did not block.** Search and business-detail pages loaded in
  every run, headed and headless.
- `[A]` **Redfin blocks headless only.** Headed runs loaded search and listing
  pages. A `--headless` run received "Are You a Robot? | Redfin". A separate
  `curl` loop from the same machine received listing data for about 6 pages,
  then 0 results without a captcha page. Its `stingray` autocomplete API
  refused `curl` from the first call.
- `[A]` **Zillow gives one page, then blocks.** The first run loaded the search
  page. The second run, on the same persistent profile, received "Access to
  this page has been denied" (the PerimeterX block page) on the first
  navigation. An `--isolated` run (fresh in-memory profile) loaded one page and
  was denied on the second.
- `[A]` **The Zillow block follows the IP, not the browser.** After about seven
  automated sessions, a branded Chrome launched outside Playwright, with a new
  user-data directory and no automation flags, was denied on its first page
  when Playwright attached over CDP. The operator's own Chrome then received a
  "Press & Hold" challenge, and passed it by hand. No launch flag, profile
  mode, or headed setting changes this outcome. Each extra automated probe
  should be expected to raise the machine's score.
- `[A]` `navigator.webdriver` read `false` in every Playwright run, so that
  signal is not what any of the three sites acted on.

### The failed request that started this

- `[A]` The reported blocks came from a TaxDrop session asked to "grab a bunch
  of addresses from zillow for testing". That session never used the
  `playwright` MCP entry. It ran `curl` loops and an ad-hoc Playwright script
  from `/tmp`. Zillow refused its first `curl` request with a 403 and
  `px-captcha`.

### A source that works: assessor open data

- `[A]` County and state assessor datasets on Socrata (SODA `$offset`) and
  ArcGIS REST (`resultOffset`, `returnCountOnly`) returned 99 residential
  addresses across 9 states with no block: NYC PLUTO, Cook County IL, Maricopa
  AZ, Tarrant Appraisal District TX, Los Angeles County CA, Palm Beach FL (FL
  DOR NAL layer), Gwinnett GA, Maryland MdProperty View, and New Jersey
  MOD-IV. Each carries a property-class code, so a residential filter is one
  `WHERE` clause.
- `[A]` **Sampling trap.** One random offset followed by 11 consecutive rows
  gives 11 neighbors on one street; 4 of 9 states came back as a single ZIP.
  bash `$RANDOM` also caps at 32767, which cannot reach most of a
  multi-million-row roll. Draw each row from its own offset over the filtered
  count.
- `[A]` Some portals fail in ways that look like data: Collin County TX's
  public parcel layer holds 15,633 rows, not the county roll, and Broward FL
  exposes a 2-letter city code with no published decode. Travis County TX
  timed out, Cuyahoga OH did not resolve, and the Fulton and DeKalb GA layers
  carry no situs ZIP.
- `[A]` Python from python.org on this machine fails TLS verification against
  several of these portals (`CERTIFICATE_VERIFY_FAILED`); `curl` succeeds.

## Sources

- Probes run 2026-09-29 against `www.zillow.com/homes/Austin,-TX_rb/`,
  `www.yelp.com/search?find_desc=coffee&find_loc=Austin%2C+TX`,
  `www.redfin.com/city/30818/TX/Austin`, and detail pages linked from them,
  through `@playwright/mcp@0.0.78` over stdio.
- TaxDrop session transcript
  `~/.claude/projects/-Users-mac-Projects-TaxDrop/ef889158-b293-4ee6-9118-f11b84279cab.jsonl`,
  2026-09-29 13:51–13:58 UTC.
- The address sample and per-portal provenance: TaxDrop engine
  `cad-data/vercel-api/fixtures/real_addresses.csv` and
  `real_addresses.sources.md`; each row carries the exact query that returned
  it.
