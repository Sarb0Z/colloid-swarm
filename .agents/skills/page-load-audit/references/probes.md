# Probes

Runnable scripts for the experiments in `SKILL.md`. Each was written wrong at
least once in this skill's history; these are the corrected forms. They need
`playwright` in a scratch directory (`npm i playwright && npx playwright
install chromium webkit`) and nothing from the target repository.

## Contents

- [Hang versus refuse](#hang-versus-refuse)
- [Frame sampler](#frame-sampler)
- [Route sweep](#route-sweep)
- [Typography parity](#typography-parity)
- [Vendor-chunk cache stability](#vendor-chunk-cache-stability)
- [Which process answered](#which-process-answered)
- [Upload plugin without publishing](#upload-plugin-without-publishing)

### Hang versus refuse

Runs the target through three conditions in two engines and reports when the
app mounted, if ever. `TARGET` is deliberately not named `URL` — that shadows
the global the route handler needs.

```js
import { webkit, chromium } from "playwright";

const TARGET = process.env.TARGET;
const HOSTS = (process.env.HOSTS ?? "").split(",").filter(Boolean);
const BUDGET_MS = 45000;
const CONDITIONS = [
  { key: "baseline", mode: "none" },
  { key: "HANG", mode: "hang" },
  { key: "REFUSED", mode: "abort" },
];

async function run(engine, name, cond) {
  const browser = await engine.launch();
  const page = await (await browser.newContext()).newPage();
  if (cond.mode !== "none") {
    await page.route("**/*", (route) => {
      const host = new globalThis.URL(route.request().url()).hostname;
      if (!HOSTS.includes(host)) return route.continue();
      if (cond.mode === "abort") return route.abort("connectionrefused");
      return new Promise(() => {}); // hang: never settle, as a silent drop does
    });
  }
  const t0 = Date.now();
  page.goto(TARGET, { waitUntil: "commit", timeout: BUDGET_MS }).catch(() => {});
  let mounted = null;
  while (Date.now() - t0 < BUDGET_MS && mounted === null) {
    const kids = await page
      .evaluate(() => document.getElementById("root")?.childElementCount ?? 0)
      .catch(() => 0);
    if (kids > 0) mounted = Date.now() - t0;
    else await page.waitForTimeout(50);
  }
  await browser.close();
  console.log(`${name} ${cond.key.padEnd(9)} mounted: ${mounted === null ? "NEVER" : mounted + "ms"}`);
}

for (const [e, n] of [[chromium, "chromium"], [webkit, "webkit"]])
  for (const c of CONDITIONS) await run(e, n, c);
```

`HOSTS=fonts.googleapis.com,fonts.gstatic.com TARGET=https://… node hang.mjs`

### Frame sampler

What the user sees over time under a hang or a delay. Samples on a fixed
timer to the end of the budget — a loop that stops at first mount reports
pre-stylesheet state as steady state — and gives `screenshot()` its own short
timeout, because it otherwise waits on the still-loading page.

```js
const SAMPLES_MS = [2000, 5000, 10000, 20000, 30000];
// … route as above, then:
const t0 = Date.now();
page.goto(TARGET, { waitUntil: "commit", timeout: 32000 }).catch(() => {});
for (const at of SAMPLES_MS) {
  const wait = at - (Date.now() - t0);
  if (wait > 0) await new Promise((r) => setTimeout(r, wait));
  const s = await page.evaluate(() => {
    const cs = getComputedStyle(document.body);
    return {
      rootKids: document.getElementById("root")?.childElementCount ?? -1,
      textLen: (document.body?.innerText ?? "").trim().length,
      sheets: document.styleSheets.length,
      bg: cs.backgroundColor,          // transparent => app stylesheet not applied
      font: cs.fontFamily.split(",")[0],
    };
  }).catch(() => null);
  const shot = await page.screenshot({ path: `frame-${at}.png`, timeout: 4000 })
    .then(() => "saved").catch(() => "TIMED OUT");
  console.log(at, JSON.stringify(s), shot);
}
```

### Route sweep

Every public route, protected routes redirecting, the catch-all. Fails on an
empty root, a fallback still showing, a page error, or any 4xx/5xx. Run it
after any lever that moves chunk boundaries.

```js
import { chromium } from "playwright";
const BASE = process.env.BASE ?? "http://localhost:4173";
const ROUTES = process.env.ROUTES.split(",");
const b = await chromium.launch();
const ctx = await b.newContext();
let fails = 0;
for (const r of ROUTES) {
  const p = await ctx.newPage();
  const errs = [];
  p.on("pageerror", (e) => errs.push(e.message.slice(0, 100)));
  p.on("console", (m) => m.type() === "error" && errs.push(m.text().slice(0, 100)));
  p.on("response", (res) => res.status() >= 400 && errs.push(`${res.status()} ${res.url().split("/").pop()}`));
  await p.goto(BASE + r, { waitUntil: "load", timeout: 30000 }).catch((e) => errs.push(e.message.slice(0, 60)));
  await p.waitForTimeout(2200); // let the lazy chunk resolve
  const s = await p.evaluate(() => ({
    kids: document.getElementById("root")?.childElementCount ?? 0,
    spinner: !!document.querySelector(".animate-spin"), // your fallback's selector
    url: location.pathname,
  }));
  const bad = s.kids === 0 || s.spinner || errs.length;
  if (bad) fails++;
  console.log((bad ? "FAIL " : "ok   ") + r.padEnd(24) + `-> ${s.url}`, errs.length ? errs.slice(0, 2) : "");
  await p.close();
}
console.log(fails ? `${fails} route(s) failed` : "all routes OK");
await b.close();
```

### Typography parity

Proves a self-hosted font swap is invisible: identical text nodes must have
identical bounding boxes on production and on the new build.

```js
async function measure(url) {
  // … launch, goto with waitUntil "load", await document.fonts.ready, wait 2.5 s
  return page.evaluate(() =>
    [...document.querySelectorAll("h1,h2,p,a,button,span")]
      .filter((e) => e.textContent.trim().length > 12 && e.children.length === 0)
      .slice(0, 8)
      .map((e) => ({ t: e.textContent.trim().slice(0, 34), w: +e.getBoundingClientRect().width.toFixed(1) })));
}
// diff prod against local by `t`; any |Δw| > 1 px means a different face
```

### Vendor-chunk cache stability

The claim is that app-code changes leave the vendor hashes alone. Prove it
with a change that survives minification; a trailing comment does not.

```sh
V1=$(ls dist/assets/vendor-*.js | xargs -n1 basename | paste -sd' ' -)
E1=$(grep -oE 'index-[^"]+\.js' dist/index.html | head -1)
sed -i '' 's/"Start Your Journey"/"Start Your Journey Now"/' src/constants/hero.ts   # a rendered literal
<build>
git checkout -- src/constants/hero.ts
V2=$(ls dist/assets/vendor-*.js | xargs -n1 basename | paste -sd' ' -)
E2=$(grep -oE 'index-[^"]+\.js' dist/index.html | head -1)
[ "$E1" != "$E2" ] && echo "entry changed (correct)"
[ "$V1" = "$V2" ]  && echo "vendor unchanged (lever delivers)"
```

### Which process answered

```sh
curl -sSI https://<host>/assets/<hashed>.js | grep -iE '^(etag|vary|cache-control|cf-cache-status|content-type)'
```

- `content-type` not JavaScript: the catch-all answered with the app; stop.
- `etag: W/"<decimal>-<decimal>"`: a runtime static handler, not the web
  server.
- `vary:` naming anything but `accept-encoding`: the CDN will not store it.
- `cache-control` shorter than the origin config asks for: a CDN TTL override.

### Upload plugin without publishing

Prove the source-map upload plugin is (or is not) wired without sending
anything. An invalid token against a closed local port fails the upload
locally; whether the build then exits 0 tells you whether a failed upload
blocks a deploy.

```sh
SENTRY_URL=http://127.0.0.1:9 \
SENTRY_AUTH_TOKEN=sntrys_invalid_probe_token \
SENTRY_ORG=nonexistent SENTRY_PROJECT=nonexistent \
<build>; echo "exit=$?"; ls dist/assets/*.js.map 2>/dev/null | wc -l
```

For the analysis build the plugin must not run at all: same variables, plus
whatever flag the config reads to suppress it, and the maps must survive.
