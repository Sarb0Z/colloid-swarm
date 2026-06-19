#!/usr/bin/env python3
"""build-report.py — join collected per-host telemetry with the billing
inventory and emit a downgrade/delete decision report (Markdown + CSV).

Reads:  inventory CSV  +  audit-results/<ip>.json (one per collected host)
Writes: audit-results/report.md, audit-results/summary.csv

The classification is a transparent heuristic on long-term signals
(since-boot CPU%, current RAM%, since-boot avg egress). It informs a human
decision; it does not make it. Mail nodes are flagged role-aware because an
idle KumoMTA box still carries warmed sending-IP reputation.
"""
import argparse, csv, json, os, sys
from pathlib import Path

def load_inventory(path):
    servers, addon_ips = [], []
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            plan = (row.get("Plan / Resource") or "").strip()
            rec = {
                "ip": (row.get("IP Address") or "").strip(),
                "hostname": (row.get("Hostname") or "").strip(),
                "plan": plan,
                "cost": parse_cost(row.get("Monthly Cost USD")),
                "used_for": (row.get("Used For") or "").strip(),
                "used_by": (row.get("Used By") or "").strip(),
                "notes": (row.get("Notes") or "").strip(),
            }
            (addon_ips if "Additional IP" in plan else servers).append(rec)
    return servers, addon_ips

def parse_cost(v):
    try: return float(str(v).strip())
    except (TypeError, ValueError): return 0.0

def load_json(results_dir, ip):
    p = Path(results_dir) / f"{ip}.json"
    if not p.is_file(): return None
    try: return json.loads(p.read_text())
    except (json.JSONDecodeError, OSError): return None

def num(x, default=None):
    return x if isinstance(x, (int, float)) else default

def classify(cpu_boot, mem_pct, tx_mbps):
    """Long-term load class from since-boot CPU%, RAM%, and avg egress.
    Missing load-bearing inputs yield UNKNOWN, never a false IDLE — a mail node
    must not be flagged for downgrade on bad data."""
    if num(cpu_boot) is None or num(mem_pct) is None:
        return "UNKNOWN"
    c = num(cpu_boot, 0) or 0
    m = num(mem_pct, 0) or 0
    t = num(tx_mbps, 0) or 0
    if c < 3 and m < 25 and t < 0.5:  return "IDLE"
    if c < 10 and m < 50 and t < 5:   return "LIGHT"
    if c < 40 and m < 80:             return "MODERATE"
    return "BUSY"

def rightsizing_note(d):
    """Plain-language headroom + suggested direction."""
    mem = d.get("memory", {}); load = d.get("load", {}); sysd = d.get("system", {})
    cores = num(sysd.get("cpu_cores"))
    total_gb = (num(mem.get("total_mb")) or 0) / 1024
    used_gb = (num(mem.get("used_mb")) or 0) / 1024
    cpu = num(load.get("cpu_util_pct_since_boot"))
    parts = []
    if cores and cpu is not None:
        parts.append(f"{cores} cores at {cpu:.1f}% avg CPU")
    if total_gb:
        parts.append(f"{used_gb:.1f}/{total_gb:.0f} GB RAM in use")
    return "; ".join(parts)

def uptime_days(d):
    u = num(d.get("system", {}).get("uptime_seconds"))
    return f"{u/86400:.0f}d" if u else "?"

def main():
    ap = argparse.ArgumentParser()
    here = Path(__file__).resolve().parent
    ap.add_argument("--inventory", default="/Users/mac/Downloads/mailstation_server_inventory.csv")
    ap.add_argument("--results", default=str(here.parent / "audit-results"))
    ap.add_argument("--out", default=str(here.parent / "audit-results"))
    a = ap.parse_args()

    servers, addon_ips = load_inventory(a.inventory)
    rows, collected, missing = [], 0, []
    for s in servers:
        d = load_json(a.results, s["ip"])
        if d is None:
            missing.append(s)
            rows.append({**s, "data": None})
            continue
        collected += 1
        load, mem, net, sysd = d.get("load", {}), d.get("memory", {}), d.get("network", {}), d.get("system", {})
        cls = classify(load.get("cpu_util_pct_since_boot"),
                       mem.get("used_pct"),
                       net.get("avg_tx_mbps_since_boot"))
        rows.append({**s, "data": d, "class": cls,
                     "cpu_boot": num(load.get("cpu_util_pct_since_boot")),
                     "cpu_win": num(load.get("cpu_util_pct_window")),
                     "mem_pct": num(mem.get("used_pct")),
                     "mem_total_mb": num(mem.get("total_mb")),
                     "cores": num(sysd.get("cpu_cores")),
                     "tx_gb": num(net.get("total_tx_gb")),
                     "rx_gb": num(net.get("total_rx_gb")),
                     "tx_mbps": num(net.get("avg_tx_mbps_since_boot")),
                     "uptime": uptime_days(d),
                     "rightsize": rightsizing_note(d)})

    total_server_cost = sum(s["cost"] for s in servers)
    total_addon_cost = sum(s["cost"] for s in addon_ips)
    grand = total_server_cost + total_addon_cost

    os.makedirs(a.out, exist_ok=True)
    write_csv(Path(a.out) / "summary.csv", rows)
    md = render_md(rows, addon_ips, total_server_cost, total_addon_cost, grand, collected, missing)
    (Path(a.out) / "report.md").write_text(md)

    print(f"servers in inventory: {len(servers)}  collected: {collected}  missing: {len(missing)}")
    print(f"monthly spend: ${grand:.2f} (servers ${total_server_cost:.2f} + add-on IPs ${total_addon_cost:.2f})")
    print(f"report:  {Path(a.out)/'report.md'}")
    print(f"summary: {Path(a.out)/'summary.csv'}")

def write_csv(path, rows):
    cols = ["ip","hostname","used_for","used_by","plan","cost","class",
            "cores","mem_total_mb","mem_pct","cpu_boot","cpu_win","tx_gb","rx_gb","tx_mbps","uptime"]
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in cols})

def fmt(v, suf="", dash="—"):
    return f"{v}{suf}" if isinstance(v, (int, float)) else dash

def render_md(rows, addon_ips, server_cost, addon_cost, grand, collected, missing):
    L = []
    L.append("# Contabo Server Audit — Decision Report\n")
    L.append(f"- **Servers in inventory:** {len(rows)}  ·  **collected:** {collected}  ·  **missing data:** {len(missing)}")
    L.append(f"- **Monthly spend:** ${grand:.2f}  (servers ${server_cost:.2f} + {len(addon_ips)} add-on IPs ${addon_cost:.2f})")
    L.append("- **Classification:** IDLE < LIGHT < MODERATE < BUSY, from since-boot CPU%, current RAM%, avg egress.\n")

    L.append("## Utilization vs. cost\n")
    L.append("| IP | Role | $/mo | Cores | RAM | RAM% | CPU%(boot) | TX GB | Uptime | Class |")
    L.append("|----|------|-----:|------:|----:|-----:|-----------:|------:|-------:|-------|")
    order = {"BUSY":0,"MODERATE":1,"LIGHT":2,"IDLE":3,"UNKNOWN":4,None:5}
    for r in sorted(rows, key=lambda x: (order.get(x.get("class"),5), -x["cost"])):
        if r["data"] is None:
            L.append(f"| {r['ip']} | {short(r['used_for'])} | {r['cost']:.2f} | — | — | — | — | — | — | **NO DATA** |")
            continue
        ram = f"{(r['mem_total_mb'] or 0)/1024:.0f}G" if r["mem_total_mb"] else "—"
        L.append(f"| {r['ip']} | {short(r['used_for'])} | {r['cost']:.2f} | "
                 f"{fmt(r['cores'])} | {ram} | {fmt(r['mem_pct'],'%')} | {fmt(r['cpu_boot'],'%')} | "
                 f"{fmt(r['tx_gb'])} | {r['uptime']} | {r['class']} |")

    # Downgrade candidates: idle/light AND meaningful cost.
    cands = [r for r in rows if r["data"] and r.get("class") in ("IDLE","LIGHT") and r["cost"] >= 15]
    L.append("\n## Downgrade / consolidation candidates\n")
    if not cands:
        L.append("_None above the $15/mo threshold._")
    for r in sorted(cands, key=lambda x: -x["cost"]):
        L.append(f"\n### {r['ip']} — {r['used_for']}  (${r['cost']:.2f}/mo, {r['class']})")
        L.append(f"- **Headroom:** {r['rightsize']}")
        L.append(f"- **Used by:** {r['used_by'] or '—'}  ·  **uptime:** {r['uptime']}  ·  **egress:** {fmt(r['tx_gb'],' GB')} total, {fmt(r['tx_mbps'],' Mbps')} avg")
        top = r["data"].get("top_processes_by_rss", [])[:5]
        if top:
            procs = ", ".join(f"{p.get('comm') or '?'}({fmt(num(p.get('rss_mb')),'MB')})" for p in top)
            L.append(f"- **Top RAM:** {procs}")
        conts = [c.get("name") for c in r["data"].get("containers", []) if c.get("name")]
        if conts:
            L.append(f"- **Containers:** {', '.join(conts)}")
        if "kumomta" in r["data"].get("role_signals", []) or "KumoMTA" in r["used_for"]:
            L.append("- ⚠️ **Mail node:** idle CPU is normal; this box may hold warmed sending-IP reputation. Downgrade plan, do **not** delete without confirming IP warmup state.")

    if missing:
        L.append("\n## Not collected (no data)\n")
        for r in missing:
            L.append(f"- **{r['ip']}** — {r['used_for']} (${r['cost']:.2f}/mo) — no credentials / unreachable")

    if addon_ips:
        L.append("\n## Add-on sending IPs\n")
        L.append(f"{len(addon_ips)} additional IPs, ${addon_cost:.2f}/mo total — attached to existing KumoMTA nodes, not separate servers.")

    L.append("\n---\n_Single-snapshot utilization underestimates peaks. For reputation-critical mail nodes, prefer downgrade over deletion. Decisions are the operator's._")
    return "\n".join(L) + "\n"

def short(s, n=42):
    s = s.replace("\n", " ")
    return s if len(s) <= n else s[:n-1] + "…"

if __name__ == "__main__":
    main()
