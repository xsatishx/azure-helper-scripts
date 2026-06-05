#!/usr/bin/env bash
set -euo pipefail
python3 - "$@" <<'PY'
import csv, json, os, subprocess, sys, time, urllib.parse, urllib.request
from datetime import datetime, timezone

if len(sys.argv) < 3:
    print("Usage: 02_azure_disk_snapshot_optimizer_v1.sh <FinalRankedReport.csv> <output.csv>", file=sys.stderr)
    print("Example: TOP_N=5 ./02_azure_disk_snapshot_optimizer_v1.sh FinalRankedReport.csv Disk_Snapshot_Optimization_Output_top5.csv", file=sys.stderr)
    sys.exit(1)

input_csv = sys.argv[1]
output_csv = sys.argv[2]
top_n = int(os.environ.get("TOP_N", "0") or "0")
retry_max = int(os.environ.get("RETRY_MAX", "6") or "6")
sleep_base = int(os.environ.get("SLEEP_BASE", "2") or "2")
snapshot_old_days = int(os.environ.get("SNAPSHOT_OLD_DAYS", "90") or "90")

OUT_COLS = [
    "Kind","SubscriptionId","ResourceId","ResourceName","ResourceGroup","Region",
    "AttachedState","ManagedBy","SourceResourceId","CurrentSKU","DiskSizeGB","DiskTier","OSType",
    "SnapshotType","SnapshotAgeDays","TimeCreated","TotalCost3Mo","ObservedMonthlyCostUSD",
    "AvgReadMBps","AvgWriteMBps","AvgThroughputMBps","AvgReadIOPS","AvgWriteIOPS","AvgIOPS",
    "CurrentListMonthlyUSD","TargetSKU","TargetTier","TargetListMonthlyUSD",
    "EstimatedMonthlySavingsUSD","SavingsType","Recommendation","Evidence",
    "PricingLookupStatus","PricingSource","RecommendationConfidence"
]

PREMIUM_TO_STANDARD = {
    "Premium_LRS": "StandardSSD_LRS",
    "Premium_ZRS": "StandardSSD_ZRS",
}

BAD_PRICE_TEXT = ["operation", "write", "read", "mount", "transaction", "burst", "reservation"]

def to_float(v):
    try:
        if v is None or str(v).strip() == "":
            return None
        return float(str(v).replace('$','').replace(',','').strip())
    except Exception:
        return None

def f2(v):
    if v is None or v == "":
        return ""
    try:
        return f"{float(v):.2f}"
    except Exception:
        return ""

def nz(v):
    if v is None:
        return ""
    s = str(v).strip()
    if s.lower() in ("nan", "none", "null", "<na>"):
        return ""
    return s

def derive_name(rid):
    return rid.rstrip('/').split('/')[-1] if rid else ""

def derive_rg(rid):
    parts = rid.split('/')
    for i, p in enumerate(parts):
        if p.lower() == 'resourcegroups' and i + 1 < len(parts):
            return parts[i+1]
    return ""

def derive_sub(rid):
    parts = rid.split('/')
    for i, p in enumerate(parts):
        if p.lower() == 'subscriptions' and i + 1 < len(parts):
            return parts[i+1]
    return ""

def normalize_region(r):
    return nz(r).replace(" ", "").lower()

def parse_dt(v):
    s = nz(v)
    if not s:
        return None
    try:
        if s.endswith('Z'):
            s = s[:-1] + '+00:00'
        return datetime.fromisoformat(s).astimezone(timezone.utc)
    except Exception:
        return None

def age_days(v):
    dt = parse_dt(v)
    if not dt:
        return None
    return (datetime.now(timezone.utc) - dt).days

def run_az_json(args):
    delay = sleep_base
    for attempt in range(1, retry_max + 1):
        proc = subprocess.run(["az", *args, "-o", "json"], text=True, capture_output=True)
        if proc.returncode == 0:
            try:
                return json.loads(proc.stdout or "{}")
            except Exception:
                pass
        err = (proc.stderr or proc.stdout or "")
        low = err.lower()
        if any(x in low for x in ["429", "toomanyrequests", "throttl", "temporarily unavailable", "timeout"]):
            print(f"429/throttle detected. retry {attempt}/{retry_max}; sleeping {delay}s", file=sys.stderr, flush=True)
            time.sleep(delay)
            delay = min(delay * 2, 45)
            continue
        if attempt < 3:
            time.sleep(2)
            continue
        print(f"WARN: az command failed: az {' '.join(args)} :: {err[:300]}", file=sys.stderr, flush=True)
        return None
    return None

def metric_average(resource_id, metric_name, aggregation="Average"):
    data = run_az_json([
        "monitor", "metrics", "list",
        "--resource", resource_id,
        "--metric", metric_name,
        "--interval", "PT1H",
        "--aggregation", aggregation
    ])
    if not data:
        return None
    vals = []
    key = aggregation.lower()
    for item in data.get("value", []) or []:
        for ts in item.get("timeseries", []) or []:
            for d in ts.get("data", []) or []:
                v = d.get(key)
                if v is not None:
                    try: vals.append(float(v))
                    except Exception: pass
    if not vals:
        return None
    return sum(vals) / len(vals)

def disk_tier(size_gb, prefix):
    try:
        size = float(size_gb or 0)
    except Exception:
        size = 0
    buckets = [
        (4,"1"),(8,"2"),(16,"3"),(32,"4"),(64,"6"),(128,"10"),(256,"15"),(512,"20"),
        (1024,"30"),(2048,"40"),(4096,"50"),(8192,"60"),(16384,"70"),(32767,"80")
    ]
    for limit, code in buckets:
        if size <= limit:
            return f"{prefix}{code}"
    return f"{prefix}80"

def tier_for_sku(sku, size_gb):
    s = nz(sku)
    if s.startswith("Premium"):
        return disk_tier(size_gb, "P")
    if s.startswith("StandardSSD"):
        return disk_tier(size_gb, "E")
    if s.startswith("Standard"):
        return disk_tier(size_gb, "S")
    return ""

def product_for_disk_sku(sku):
    s = nz(sku)
    if s.startswith("Premium"):
        return "Premium SSD Managed Disks"
    if s.startswith("StandardSSD"):
        return "Standard SSD Managed Disks"
    if s.startswith("Standard"):
        return "Standard HDD Managed Disks"
    if s.startswith("Ultra"):
        return "Ultra Disks"
    return "Managed Disks"

def fetch_json_url(base_url, params):
    # URL-encode filters safely; no hand-built URLs with spaces.
    query = urllib.parse.urlencode(params, safe="()$,='")
    url = base_url + ("&" if "?" in base_url else "?") + query
    delay = sleep_base
    for attempt in range(1, retry_max + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "azure-disk-snapshot-optimizer-v1"})
            with urllib.request.urlopen(req, timeout=90) as r:
                return json.load(r)
        except Exception as e:
            if attempt < retry_max:
                msg = str(e).lower()
                if any(x in msg for x in ["429", "too many", "timed out", "timeout", "temporarily"]):
                    print(f"Pricing retry {attempt}/{retry_max}; sleeping {delay}s", file=sys.stderr, flush=True)
                time.sleep(delay)
                delay = min(delay * 2, 45)
            else:
                print(f"WARN: pricing lookup failed: {str(e)[:250]}", file=sys.stderr, flush=True)
                return None
    return None

def choose_best_monthly_price(items, prefer_snapshot=False):
    good = []
    for it in items or []:
        ptype = (it.get("priceType") or "")
        price = it.get("retailPrice")
        if price is None or ptype != "Consumption":
            continue
        txt = " ".join(str(it.get(k,"")) for k in ["productName","skuName","meterName","unitOfMeasure"]).lower()
        if any(bad in txt for bad in BAD_PRICE_TEXT):
            continue
        score = 0
        if "month" in txt: score += 3
        if prefer_snapshot and "snapshot" in txt: score += 3
        if not prefer_snapshot and "disk" in txt: score += 2
        if "lrs" in txt or "zrs" in txt: score += 1
        good.append((score, float(price), it.get("meterName") or it.get("skuName") or "", it.get("unitOfMeasure") or ""))
    if not good:
        return None, ""
    good.sort(key=lambda x: (-x[0], x[1]))
    return good[0][1], f"{good[0][2]} ({good[0][3]})"

def retail_disk_price(region, sku, tier):
    if not region or not sku or not tier:
        return None, ""
    product = product_for_disk_sku(sku)
    zone = "ZRS" if sku.endswith("_ZRS") else "LRS"
    sku_name = f"{tier} {zone}"
    filters = [
        f"serviceName eq 'Storage' and armRegionName eq '{region}' and productName eq '{product}' and skuName eq '{sku_name}'",
        f"serviceName eq 'Storage' and armRegionName eq '{region}' and skuName eq '{sku_name}'",
    ]
    for filt in filters:
        data = fetch_json_url("https://prices.azure.com/api/retail/prices", {"$filter": filt})
        price, meter = choose_best_monthly_price((data or {}).get("Items") or [], prefer_snapshot=False)
        if price is not None:
            return price, meter
    return None, ""

def retail_snapshot_price(region, sku, size_gb, redundancy="LRS"):
    # Snapshot billing is often per GB/month. This is best-effort and falls back to observed cost.
    if not region:
        return None, ""
    red = "ZRS" if "ZRS" in nz(sku).upper() or nz(redundancy).upper() == "ZRS" else "LRS"
    filters = [
        f"serviceName eq 'Storage' and armRegionName eq '{region}' and contains(productName, 'Snapshot')",
        f"serviceName eq 'Storage' and armRegionName eq '{region}' and contains(meterName, 'Snapshot')",
    ]
    for filt in filters:
        data = fetch_json_url("https://prices.azure.com/api/retail/prices", {"$filter": filt})
        items = (data or {}).get("Items") or []
        candidates = []
        for it in items:
            price = it.get("retailPrice")
            if price is None or (it.get("priceType") or "") != "Consumption":
                continue
            txt = " ".join(str(it.get(k,"")) for k in ["productName","skuName","meterName","unitOfMeasure"]).lower()
            if "snapshot" not in txt:
                continue
            if red.lower() not in txt and "lrs" in txt and red.lower() != "lrs":
                continue
            if any(bad in txt for bad in ["operation", "transaction", "write", "read"]):
                continue
            score = 0
            if "gb" in txt: score += 3
            if red.lower() in txt: score += 2
            candidates.append((score, float(price), it.get("meterName") or it.get("skuName") or "", it.get("unitOfMeasure") or ""))
        if candidates:
            candidates.sort(key=lambda x: (-x[0], x[1]))
            unit_price, meter, unit = candidates[0][1], candidates[0][2], candidates[0][3]
            sz = to_float(size_gb) or 0
            # If unit looks GB/month, multiply by snapshot size. If already monthly, leave as-is.
            monthly = unit_price * sz if "gb" in unit.lower() else unit_price
            return monthly, f"{meter} ({unit})"
    return None, ""

def get_disk_details(rid):
    d = run_az_json(["disk", "show", "--ids", rid])
    if not d:
        return {}
    return {
        "name": d.get("name") or derive_name(rid),
        "region": normalize_region(d.get("location")),
        "sku": ((d.get("sku") or {}).get("name") or ""),
        "size_gb": d.get("diskSizeGB"),
        "managed_by": d.get("managedBy") or "",
        "os_type": d.get("osType") or "",
        "tier": d.get("tier") or "",
    }

def get_snapshot_details(rid):
    s = run_az_json(["snapshot", "show", "--ids", rid])
    if not s:
        return {}
    creation = nz(s.get("timeCreated"))
    sku = ((s.get("sku") or {}).get("name") or "")
    incr = s.get("incremental")
    source = (((s.get("creationData") or {}).get("sourceResourceId")) or "")
    return {
        "name": s.get("name") or derive_name(rid),
        "region": normalize_region(s.get("location")),
        "sku": sku,
        "size_gb": s.get("diskSizeGB"),
        "os_type": s.get("osType") or "",
        "time_created": creation,
        "age_days": age_days(creation),
        "incremental": incr,
        "source_resource_id": source,
    }

def read_input(path):
    rows = []
    seen = set()
    with open(path, newline='', encoding='utf-8-sig') as f:
        for row in csv.DictReader(f):
            rid = nz(row.get("ResourceId") or row.get("SourceResourceId"))
            low = rid.lower()
            kind = ""
            if "/providers/microsoft.compute/disks/" in low:
                kind = "ManagedDisk"
            elif "/providers/microsoft.compute/snapshots/" in low:
                kind = "DiskSnapshot"
            else:
                continue
            key = low
            if key in seen:
                continue
            seen.add(key)
            total = to_float(row.get("TotalCost3Mo"))
            obs = to_float(row.get("ObservedMonthlyCostUSD"))
            if obs is None and total is not None:
                obs = total / 3.0
            rows.append({"kind": kind, "raw": row, "rid": rid, "total": total, "obs": obs})
    rows.sort(key=lambda x: x["total"] if x["total"] is not None else (x["obs"] or 0), reverse=True)
    if top_n > 0:
        rows = rows[:top_n]
    return rows

def choose_disk_recommendation(details, metrics, current_price, target_price, observed_monthly):
    sku = details.get("sku") or ""
    managed_by = details.get("managed_by") or ""
    attached = "Attached" if managed_by else "Unattached"
    avg_tput = metrics.get("avg_tput")
    avg_iops = metrics.get("avg_iops")
    target_sku = ""
    savings_type = ""
    recommendation = "Review manually"
    confidence = "Low"
    savings = None
    target_tier = ""
    current_monthly = current_price if current_price is not None else observed_monthly

    if attached == "Unattached":
        savings_type = "Delete"
        recommendation = "Delete unattached managed disk after owner validation"
        savings = observed_monthly if observed_monthly is not None else current_monthly
        confidence = "High"
        return target_sku, target_tier, None, savings, savings_type, recommendation, confidence

    low_usage = False
    if avg_tput is not None and avg_iops is not None:
        low_usage = avg_tput < 5 and avg_iops < 100
    elif avg_tput is not None:
        low_usage = avg_tput < 5
    elif avg_iops is not None:
        low_usage = avg_iops < 100

    if sku in PREMIUM_TO_STANDARD and low_usage:
        target_sku = PREMIUM_TO_STANDARD[sku]
        target_tier = tier_for_sku(target_sku, details.get("size_gb"))
        if target_price is not None and current_monthly is not None:
            savings = max(current_monthly - target_price, 0)
        recommendation = f"Consider downgrade from {sku} to {target_sku} after performance validation"
        savings_type = "Disk downgrade"
        confidence = "Medium" if (avg_tput is not None or avg_iops is not None) else "Low"
    return target_sku, target_tier, target_price, savings, savings_type, recommendation, confidence

def choose_snapshot_recommendation(details, current_price, observed_monthly):
    age = details.get("age_days")
    size = to_float(details.get("size_gb"))
    incr = details.get("incremental")
    source = nz(details.get("source_resource_id"))
    savings = observed_monthly if observed_monthly is not None else current_price
    confidence = "Low"
    savings_type = ""
    recommendation = "Review snapshot retention and ownership"

    if age is not None and age >= snapshot_old_days:
        savings_type = "Delete snapshot"
        recommendation = f"Review and delete snapshot older than {snapshot_old_days} days if no retention requirement exists"
        confidence = "Medium"
    if not source and age is not None and age >= 30:
        savings_type = "Delete snapshot"
        recommendation = "Review orphaned/standalone snapshot and delete if no restore requirement exists"
        confidence = "Medium"
    if size is not None and size >= 1024 and age is not None and age >= 30:
        if savings_type:
            recommendation += "; large snapshot adds material storage cost"
        else:
            savings_type = "Review large snapshot"
            recommendation = "Large snapshot: validate retention requirement and lifecycle policy"
        confidence = "Medium"
    if not savings_type:
        savings = None
    return "", "", None, savings, savings_type, recommendation, confidence

def process_disk(item, writer, outf, i, n):
    rid = item["rid"]
    raw = item["raw"]
    print(f"Processing managed disk {i}/{n}: {derive_name(rid)}", file=sys.stderr, flush=True)
    sub = nz(raw.get("SubscriptionId")) or derive_sub(rid)
    rg = nz(raw.get("ResourceGroup")) or derive_rg(rid)
    details = get_disk_details(rid)
    name = details.get("name") or derive_name(rid)
    region = details.get("region") or normalize_region(raw.get("Location") or raw.get("Region"))
    sku = details.get("sku") or nz(raw.get("CurrentSKU"))
    size_gb = details.get("size_gb")
    managed_by = details.get("managed_by") or ""
    attached = "Attached" if managed_by else "Unattached"
    disk_t = details.get("tier") or tier_for_sku(sku, size_gb)

    read_bps = metric_average(rid, "Composite Disk Read Bytes/sec", "Average")
    write_bps = metric_average(rid, "Composite Disk Write Bytes/sec", "Average")
    read_iops = metric_average(rid, "Composite Disk Read Operations/Sec", "Average")
    write_iops = metric_average(rid, "Composite Disk Write Operations/Sec", "Average")
    read_mbps = read_bps / 1024 / 1024 if read_bps is not None else None
    write_mbps = write_bps / 1024 / 1024 if write_bps is not None else None
    avg_tput = (read_mbps or 0) + (write_mbps or 0) if (read_mbps is not None or write_mbps is not None) else None
    avg_iops = (read_iops or 0) + (write_iops or 0) if (read_iops is not None or write_iops is not None) else None

    current_price, current_meter = retail_disk_price(region, sku, disk_t)
    pricing_status = "ok" if current_price is not None else "fallback"
    pricing_source = "retail" if current_price is not None else "observed_cost"

    target_sku_pre = PREMIUM_TO_STANDARD.get(sku, "")
    target_tier_pre = tier_for_sku(target_sku_pre, size_gb) if target_sku_pre else ""
    target_price, target_meter = retail_disk_price(region, target_sku_pre, target_tier_pre) if target_sku_pre else (None, "")

    target_sku, target_tier, target_price_final, savings, savings_type, recommendation, confidence = choose_disk_recommendation(
        details, {"avg_tput": avg_tput, "avg_iops": avg_iops}, current_price, target_price, item["obs"]
    )

    evidence = "; ".join([
        f"sku={sku}", f"tier={disk_t}", f"sizeGB={size_gb}", f"attachedState={attached}",
        f"avgThroughputMBps={f2(avg_tput)}", f"avgIOPS={f2(avg_iops)}",
        f"currentMeter={current_meter}", f"targetMeter={target_meter}"
    ])
    writer.writerow({
        "Kind": "ManagedDisk", "SubscriptionId": sub, "ResourceId": rid, "ResourceName": name,
        "ResourceGroup": rg, "Region": region, "AttachedState": attached, "ManagedBy": managed_by,
        "SourceResourceId": "", "CurrentSKU": sku, "DiskSizeGB": size_gb if size_gb is not None else "",
        "DiskTier": disk_t, "OSType": details.get("os_type") or "", "SnapshotType": "", "SnapshotAgeDays": "", "TimeCreated": "",
        "TotalCost3Mo": f2(item["total"]), "ObservedMonthlyCostUSD": f2(item["obs"]),
        "AvgReadMBps": f2(read_mbps), "AvgWriteMBps": f2(write_mbps), "AvgThroughputMBps": f2(avg_tput),
        "AvgReadIOPS": f2(read_iops), "AvgWriteIOPS": f2(write_iops), "AvgIOPS": f2(avg_iops),
        "CurrentListMonthlyUSD": f2(current_price), "TargetSKU": target_sku, "TargetTier": target_tier,
        "TargetListMonthlyUSD": f2(target_price_final), "EstimatedMonthlySavingsUSD": f2(savings),
        "SavingsType": savings_type, "Recommendation": recommendation, "Evidence": evidence,
        "PricingLookupStatus": pricing_status, "PricingSource": pricing_source, "RecommendationConfidence": confidence,
    })
    outf.flush()

def process_snapshot(item, writer, outf, i, n):
    rid = item["rid"]
    raw = item["raw"]
    print(f"Processing snapshot {i}/{n}: {derive_name(rid)}", file=sys.stderr, flush=True)
    sub = nz(raw.get("SubscriptionId")) or derive_sub(rid)
    rg = nz(raw.get("ResourceGroup")) or derive_rg(rid)
    details = get_snapshot_details(rid)
    name = details.get("name") or derive_name(rid)
    region = details.get("region") or normalize_region(raw.get("Location") or raw.get("Region"))
    sku = details.get("sku") or nz(raw.get("CurrentSKU")) or "Standard_LRS"
    size_gb = details.get("size_gb")
    snap_type = "Incremental" if details.get("incremental") is True else "Full" if details.get("incremental") is False else "Unknown"
    age = details.get("age_days")
    source = details.get("source_resource_id") or ""
    time_created = details.get("time_created") or ""
    current_price, current_meter = retail_snapshot_price(region, sku, size_gb)
    pricing_status = "ok" if current_price is not None else "fallback"
    pricing_source = "retail" if current_price is not None else "observed_cost"
    target_sku, target_tier, target_price, savings, savings_type, recommendation, confidence = choose_snapshot_recommendation(details, current_price, item["obs"])
    evidence = "; ".join([
        f"sku={sku}", f"sizeGB={size_gb}", f"snapshotType={snap_type}", f"ageDays={age if age is not None else ''}",
        f"sourceResourceId={source}", f"currentMeter={current_meter}"
    ])
    writer.writerow({
        "Kind": "DiskSnapshot", "SubscriptionId": sub, "ResourceId": rid, "ResourceName": name,
        "ResourceGroup": rg, "Region": region, "AttachedState": "", "ManagedBy": "",
        "SourceResourceId": source, "CurrentSKU": sku, "DiskSizeGB": size_gb if size_gb is not None else "",
        "DiskTier": "", "OSType": details.get("os_type") or "", "SnapshotType": snap_type,
        "SnapshotAgeDays": age if age is not None else "", "TimeCreated": time_created,
        "TotalCost3Mo": f2(item["total"]), "ObservedMonthlyCostUSD": f2(item["obs"]),
        "AvgReadMBps": "", "AvgWriteMBps": "", "AvgThroughputMBps": "", "AvgReadIOPS": "", "AvgWriteIOPS": "", "AvgIOPS": "",
        "CurrentListMonthlyUSD": f2(current_price), "TargetSKU": target_sku, "TargetTier": target_tier,
        "TargetListMonthlyUSD": f2(target_price), "EstimatedMonthlySavingsUSD": f2(savings),
        "SavingsType": savings_type, "Recommendation": recommendation, "Evidence": evidence,
        "PricingLookupStatus": pricing_status, "PricingSource": pricing_source, "RecommendationConfidence": confidence,
    })
    outf.flush()

def main():
    rows = read_input(input_csv)
    print(len(rows))
    md = sum(1 for r in rows if r["kind"] == "ManagedDisk")
    sn = sum(1 for r in rows if r["kind"] == "DiskSnapshot")
    print(f"Rows to process: {len(rows)} (managed disks={md}, snapshots={sn})", file=sys.stderr, flush=True)
    with open(output_csv, 'w', newline='', encoding='utf-8') as outf:
        writer = csv.DictWriter(outf, fieldnames=OUT_COLS)
        writer.writeheader()
        outf.flush()
        for i, item in enumerate(rows, 1):
            if item["kind"] == "ManagedDisk":
                process_disk(item, writer, outf, i, len(rows))
            else:
                process_snapshot(item, writer, outf, i, len(rows))
    print(f"Done. Wrote {output_csv}", file=sys.stderr, flush=True)

if __name__ == "__main__":
    main()
PY
