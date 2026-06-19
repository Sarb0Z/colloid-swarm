#!/usr/bin/env python3
"""build-trend-report.py — aggregate the scheduled time-series snapshots into a
peak-aware decision report. Reads audit-results/timeseries/<ip>/snapshots/*.json
(produced by `schedule-audit.sh pull`) and emits trend-report.md + trends.csv.

Unlike the single-snapshot report, this classifies on the 95th percentile, so a
host is only called "downgradeable" when even its sustained peaks stay low.
"""
import argparse, csv, glob, json, os
from pathlib import Path
from datetime import datetime

def parse_cost(v):
    try: return float(str(v).strip())
    except (TypeError, ValueError): return 0.0

def load_inventory(path):
    by_ip = {}
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            ip = (row.get("IP Address") or "").strip()
            if ip:
                by_ip[ip] = {"used_for": (row.get("Used For") or "").strip(),
                             "used_by": (row.get("Used By") or "").strip(),
                             "cost": parse_cost(row.get("Monthly Cost USD")),
                             "plan": (row.get("Plan / Resource") or "").strip()}
    return by_ip

def num(x):
    return x if isinstance(x, (int, float)) else None

def pctl(vals, q):
    if not vals: return None
    if len(vals) == 1: return vals[0]
    idx = (len(vals) - 1) * q
    lo = int(idx); hi = min(lo + 1, len(vals) - 1)
    return vals[lo] + (vals[hi] - vals[lo]) * (idx - lo)

def stats(raw):
    vals = sorted(v for v in raw if isinstance(v, (int, float)))
    if not vals: return None
    return {"min": vals[0], "avg": sum(vals)/len(vals),
            "p95": pctl(vals, 0.95), "max": vals[-1], "n": len(vals)}

def classify_peak(cpu_p95, mem_p95, tx_p95):
    """Load class from sustained peaks (p95). Missing inputs -> UNKNOWN."""
    if cpu_p95 is None or mem_p95 is None: return "UNKNOWN"
    t = tx_p95 or 0
    if cpu_p95 < 5 and mem_p95 < 30 and t < 1:  return "IDLE"
    if cpu_p95 < 20 and mem_p95 < 55:           return "LIGHT"
    if cpu_p95 < 60 and mem_p95 < 85:           return "MODERATE"
    return "BUSY"

def load_series(host_dir):
    snaps = []
    for p in sorted(glob.glob(os.path.join(host_dir, "snapshots", "snap-*.json"))):
        try: snaps.append(json.loads(Path(p).read_text()))
        except (json.JSONDecodeError, OSError): continue
    return snaps

def host_summary(snaps):
    cpu = [num(s.get("load", {}).get("cpu_util_pct_window")) for s in snaps]
    mem = [num(s.get("memory", {}).get("used_pct")) for s in snaps]
    txm = [num(s.get("network", {}).get("window_tx_mbps")) for s in snaps]
    swp = [num(s.get("memory", {}).get("swap_used_pct")) for s in snaps]
    last = snaps[-1]
    times = sorted(s.get("collected_at_utc") for s in snaps if s.get("collected_at_utc"))
    span = "?"
    if len(times) >= 2:
        try:
            fmt = "%Y-%m-%dT%H:%M:%SZ"
            span = f"{(datetime.strptime(times[-1], fmt) - datetime.strptime(times[0], fmt)).days}d"
        except ValueError:
            span = "?"
    return {
        "cores": num(last.get("system", {}).get("cpu_cores")),
        "ram_total_mb": num(last.get("memory", {}).get("total_mb")),
        "cpu": stats(cpu), "mem": stats(mem), "tx": stats(txm), "swap": stats(swp),
        "n": len(snaps), "span": span,
        "roles": last.get("role_signals", []),
    }

def g(st, k, suf=""):
    if not st or st.get(k) is None: return "—"
    v = st[k]
    return f"{v:.1f}{suf}" if isinstance(v, float) else f"{v}{suf}"

def main():
    here = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser()
    ap.add_argument("--inventory", default="/Users/mac/Downloads/mailstation_server_inventory.csv")
    ap.add_argument("--timeseries", default=str(here.parent / "audit-results" / "timeseries"))
    ap.add_argument("--out", default=str(here.parent / "audit-results"))
    a = ap.parse_args()

    inv = load_inventory(a.inventory)
    host_dirs = sorted(d for d in glob.glob(os.path.join(a.timeseries, "*")) if os.path.isdir(d))
    if not host_dirs:
        raise SystemExit(f"no host data under {a.timeseries} — run: schedule-audit.sh pull")

    rows = []
    for hd in host_dirs:
        ip = os.path.basename(hd)
        snaps = load_series(hd)
        if not snaps:
            rows.append({"ip": ip, "n": 0, **inv.get(ip, {})}); continue
        s = host_summary(snaps)
        cls = classify_peak(s["cpu"] and s["cpu"]["p95"], s["mem"] and s["mem"]["p95"], s["tx"] and s["tx"]["p95"])
        rows.append({"ip": ip, "cls": cls, **s, **inv.get(ip, {})})

    os.makedirs(a.out, exist_ok=True)
    write_csv(Path(a.out) / "trends.csv", rows)
    (Path(a.out) / "trend-report.md").write_text(render(rows))
    collected = sum(1 for r in rows if r.get("n"))
    print(f"hosts with time-series: {collected}/{len(rows)}")
    print(f"report:  {Path(a.out)/'trend-report.md'}")
    print(f"csv:     {Path(a.out)/'trends.csv'}")

def write_csv(path, rows):
    cols = ["ip", "used_for", "cost", "cls", "n", "span", "cores", "ram_total_mb",
            "cpu_avg", "cpu_p95", "cpu_max", "mem_avg", "mem_p95", "mem_max", "tx_p95", "tx_max"]
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            cpu, mem, tx = r.get("cpu"), r.get("mem"), r.get("tx")
            w.writerow({"ip": r["ip"], "used_for": r.get("used_for", ""), "cost": r.get("cost", ""),
                        "cls": r.get("cls", ""), "n": r.get("n", 0), "span": r.get("span", ""),
                        "cores": r.get("cores", ""), "ram_total_mb": r.get("ram_total_mb", ""),
                        "cpu_avg": rnd(cpu, "avg"), "cpu_p95": rnd(cpu, "p95"), "cpu_max": rnd(cpu, "max"),
                        "mem_avg": rnd(mem, "avg"), "mem_p95": rnd(mem, "p95"), "mem_max": rnd(mem, "max"),
                        "tx_p95": rnd(tx, "p95"), "tx_max": rnd(tx, "max")})

def rnd(st, k):
    if not st or st.get(k) is None: return ""
    return round(st[k], 2)

def render(rows):
    L = ["# Contabo Fleet — Week-long Trend Report\n",
         "Classification is on the **95th-percentile** of each metric across all "
         "snapshots, so a host is only flagged downgradeable when its sustained "
         "peaks — not just an idle moment — stay low.\n",
         "| IP | Role | $/mo | n | span | Cores | RAM | CPU% avg/p95/max | RAM% avg/p95/max | TX p95/max Mbps | Class |",
         "|----|------|-----:|--:|-----:|------:|----:|------------------|------------------|-----------------|-------|"]
    order = {"BUSY":0,"MODERATE":1,"LIGHT":2,"IDLE":3,"UNKNOWN":4}
    for r in sorted(rows, key=lambda x: (order.get(x.get("cls"), 5), -(x.get("cost") or 0))):
        if not r.get("n"):
            L.append(f"| {r['ip']} | {short(r.get('used_for',''))} | {r.get('cost',0):.2f} | 0 | — | — | — | — | — | — | **NO DATA** |")
            continue
        cpu, mem, tx = r["cpu"], r["mem"], r["tx"]
        ram = f"{(r['ram_total_mb'] or 0)/1024:.0f}G" if r.get("ram_total_mb") else "—"
        L.append(f"| {r['ip']} | {short(r.get('used_for',''))} | {r.get('cost',0):.2f} | {r['n']} | {r['span']} | "
                 f"{r.get('cores') or '—'} | {ram} | "
                 f"{g(cpu,'avg')}/{g(cpu,'p95')}/{g(cpu,'max')} | "
                 f"{g(mem,'avg')}/{g(mem,'p95')}/{g(mem,'max')} | "
                 f"{g(tx,'p95')}/{g(tx,'max')} | {r['cls']} |")

    cands = [r for r in rows if r.get("n") and r.get("cls") in ("IDLE","LIGHT") and (r.get("cost") or 0) >= 15]
    L.append("\n## Downgrade candidates (peak-validated)\n")
    if not cands:
        L.append("_None: no host ≥$15/mo stayed IDLE/LIGHT at its p95._")
    for r in sorted(cands, key=lambda x: -(x.get("cost") or 0)):
        cpu, mem = r["cpu"], r["mem"]
        L.append(f"- **{r['ip']}** — {r.get('used_for','')} (${r.get('cost',0):.2f}/mo, {r['cls']}): "
                 f"CPU p95 {g(cpu,'p95','%')} (max {g(cpu,'max','%')}), RAM p95 {g(mem,'p95','%')} (max {g(mem,'max','%')}) "
                 f"over {r['n']} samples / {r['span']}."
                 + (" ⚠️ mail node — downgrade, don't delete." if ("kumomta" in r.get("roles", []) or "KumoMTA" in r.get("used_for","")) else ""))

    thin = [r for r in rows if 0 < r.get("n", 0) < 20]
    if thin:
        L.append("\n## Low-confidence (few samples)\n")
        for r in thin:
            L.append(f"- **{r['ip']}** — only {r['n']} snapshot(s); let collection run longer before deciding.")
    L.append("\n---\n_p95 = sustained peak; max = worst single sample. Re-pull and re-run to refresh._")
    return "\n".join(L) + "\n"

def short(s, n=40):
    s = (s or "").replace("\n", " ")
    return s if len(s) <= n else s[:n-1] + "…"

if __name__ == "__main__":
    main()
