#!/usr/bin/env bash
set -euo pipefail
python3 - "$@" <<'PY'
import csv, json, math, os, subprocess, sys, time, urllib.parse, urllib.request

if len(sys.argv) < 3:
    print("Usage: 01_azure_vm_optimizer_v1.sh <FinalRankedReport.csv> <output.csv>", file=sys.stderr)
    sys.exit(1)

input_csv = sys.argv[1]
output_csv = sys.argv[2]
top_n = int(os.environ.get("TOP_N", "0") or "0")
hours_per_month = float(os.environ.get("HOURS_PER_MONTH", "730") or "730")
retry_max = int(os.environ.get("RETRY_MAX", "6") or "6")
sleep_base = int(os.environ.get("SLEEP_BASE", "2") or "2")

OUT_COLS = [
    "SubscriptionId","ResourceId","ResourceName","ObservedMonthlyCostUSD","TotalCost3Mo",
    "CurrentSKU","Region","OSType","VMSizevCPU","VMSizeMemoryGiB","AvgCPU","MaxCPU",
    "AvgMemoryUsedPct","MaxMemoryUsedPct","AvgAvailableMemoryGB","CurrentListMonthlyUSD",
    "RI1YListMonthlyUSD","RI3YListMonthlyUSD","TargetSKU","TargetListMonthlyUSD",
    "EstimatedMonthlySavingsUSD","SavingsType","Recommendation","Evidence",
    "PricingLookupStatus","PricingSource","RecommendationConfidence"
]

TARGET_MAP = {
    "Standard_D8ds_v5": "Standard_D4ds_v5",
    "Standard_D8ads_v5": "Standard_D4ads_v5",
    "Standard_D8as_v5": "Standard_D4as_v5",
    "Standard_D8as_v4": "Standard_D4as_v4",
    "Standard_D8ds_v4": "Standard_D4ds_v4",
    "Standard_D4ads_v5": "Standard_D2ads_v5",
    "Standard_D4as_v5": "Standard_D2as_v5",
    "Standard_D4as_v4": "Standard_D2as_v4",
    "Standard_D4ds_v5": "Standard_D2ds_v5",
    "Standard_D4ds_v4": "Standard_D2ds_v4",
    "Standard_DS3_v2": "Standard_DS2_v2",
    "Standard_DS4_v2": "Standard_DS3_v2",
    "Standard_E8as_v5": "Standard_E4as_v5",
    "Standard_E8ds_v5": "Standard_E4ds_v5",
    "Standard_E4as_v5": "Standard_E2as_v5",
    "Standard_E4ds_v5": "Standard_E2ds_v5",
}


def to_float(v):
    try:
        if v in (None, "", "null"):
            return None
        return float(str(v).strip())
    except Exception:
        return None


def f2(v):
    if v is None:
        return ""
    try:
        return f"{float(v):.2f}"
    except Exception:
        return ""


def derive_name(resource_id: str) -> str:
    if not resource_id:
        return ""
    return resource_id.rstrip("/").split("/")[-1]


def run_az_json(args):
    delay = sleep_base
    for attempt in range(1, retry_max + 1):
        proc = subprocess.run(["az", *args, "-o", "json"], text=True, capture_output=True)
        if proc.returncode == 0:
            try:
                return json.loads(proc.stdout)
            except Exception:
                pass
        err = (proc.stderr or proc.stdout or "")
        if any(x in err.lower() for x in ["429", "toomanyrequests", "throttl"]):
            time.sleep(delay)
            delay = min(delay * 2, 30)
            continue
        if attempt < 3:
            time.sleep(2)
            continue
        return None
    return None


def fetch_json_url(base_url, params):
    query = urllib.parse.urlencode(params, safe="()$,='")
    url = base_url + ("&" if "?" in base_url else "?") + query
    delay = sleep_base
    for attempt in range(1, retry_max + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "vm-cost-optimizer-v9"})
            with urllib.request.urlopen(req, timeout=90) as r:
                return json.load(r)
        except Exception:
            if attempt < retry_max:
                time.sleep(delay)
                delay = min(delay * 2, 30)
            else:
                return None
    return None


def retail_items(sku, region, price_type):
    filt = f"serviceName eq 'Virtual Machines' and armSkuName eq '{sku}' and armRegionName eq '{region}' and priceType eq '{price_type}'"
    base = "https://prices.azure.com/api/retail/prices"
    data = fetch_json_url(base, {"$filter": filt})
    if not data:
        return []
    items = list(data.get("Items") or [])
    next_link = data.get("NextPageLink")
    page_count = 1
    while next_link and page_count < 5:
        more = fetch_json_url(next_link, {})
        if not more:
            break
        items.extend(more.get("Items") or [])
        next_link = more.get("NextPageLink")
        page_count += 1
    return items


def bad_meter(item):
    text = " ".join([
        str(item.get("meterName") or ""),
        str(item.get("productName") or ""),
        str(item.get("skuName") or ""),
    ]).lower()
    bad_words = [
        "spot", "low priority", "lowpriority", "promo", "dev/test", "devtest",
        "cloud services", "windows basic", "windows web"
    ]
    return any(w in text for w in bad_words)


def choose_payg_item(items, os_type):
    clean = [it for it in items if not bad_meter(it)]
    if not clean:
        return None
    os_lower = (os_type or "").lower()
    if os_lower == "windows":
        preferred = [it for it in clean if "windows" in (str(it.get("productName") or "") + " " + str(it.get("meterName") or "")).lower()]
    else:
        preferred = [it for it in clean if "windows" not in (str(it.get("productName") or "") + " " + str(it.get("meterName") or "")).lower()]
    pool = preferred or clean
    pool = [it for it in pool if float(it.get("retailPrice") or 0) > 0]
    if not pool:
        return None
    return sorted(pool, key=lambda x: float(x.get("retailPrice") or 0))[0]


def choose_ri_item(items, term):
    clean = [it for it in items if not bad_meter(it)]
    pool = [it for it in clean if (it.get("reservationTerm") or "") == term and float(it.get("retailPrice") or 0) > 0]
    if not pool:
        return None
    return sorted(pool, key=lambda x: float(x.get("retailPrice") or 0))[0]


def retail_price_lookup(sku, region, os_type, price_type, term=None):
    items = retail_items(sku, region, price_type)
    if price_type == "Consumption":
        chosen = choose_payg_item(items, os_type)
        if not chosen:
            return None, ""
        return float(chosen.get("retailPrice", 0)) * hours_per_month, chosen.get("meterName", "")
    chosen = choose_ri_item(items, term)
    if not chosen:
        return None, ""
    months = 12 if term == "1 Year" else 36
    return float(chosen.get("retailPrice", 0)) / months, chosen.get("meterName", "")


def metric_avg_max(resource_id, metric_name):
    data = run_az_json(["monitor", "metrics", "list", "--resource", resource_id, "--metric", metric_name, "--interval", "PT1H", "--aggregation", "Average", "Maximum"])
    if not data:
        return None, None
    pts = (((data.get("value") or [{}])[0].get("timeseries") or [{}])[0].get("data") or [])
    avgs = [x.get("average") for x in pts if x.get("average") is not None]
    maxs = [x.get("maximum") for x in pts if x.get("maximum") is not None]
    return (sum(avgs) / len(avgs) if avgs else None), (max(maxs) if maxs else None)


def metric_avg_min(resource_id, metric_name):
    data = run_az_json(["monitor", "metrics", "list", "--resource", resource_id, "--metric", metric_name, "--interval", "PT1H", "--aggregation", "Average", "Minimum"])
    if not data:
        return None, None
    pts = (((data.get("value") or [{}])[0].get("timeseries") or [{}])[0].get("data") or [])
    avgs = [x.get("average") for x in pts if x.get("average") is not None]
    mins = [x.get("minimum") for x in pts if x.get("minimum") is not None]
    return (sum(avgs) / len(avgs) if avgs else None), (min(mins) if mins else None)


def get_vm_info(resource_id):
    data = run_az_json(["resource", "show", "--ids", resource_id])
    if not data:
        return None
    props = data.get("properties") or {}
    storage = props.get("storageProfile") or {}
    osdisk = storage.get("osDisk") or {}
    hardware = props.get("hardwareProfile") or {}
    return {
        "region": (data.get("location") or "").lower(),
        "sku": (data.get("sku") or {}).get("name") or hardware.get("vmSize") or "",
        "os": osdisk.get("osType") or "",
        "size": hardware.get("vmSize") or (data.get("sku") or {}).get("name") or "",
    }


def get_size_caps(region, size):
    data = run_az_json(["vm", "list-skus", "--location", region, "--size", size, "--resource-type", "virtualMachines"])
    if not data:
        return None, None
    first = data[0] if data else {}
    caps = {c.get("name"): c.get("value") for c in first.get("capabilities") or []}
    return to_float(caps.get("vCPUs")), to_float(caps.get("MemoryGB"))


def calc_mem(mem_gb, avg_avail_bytes, min_avail_bytes):
    if not mem_gb:
        return None, None, None
    total = mem_gb * 1024 * 1024 * 1024
    avg_used = ((total - avg_avail_bytes) / total) * 100 if avg_avail_bytes is not None else None
    max_used = ((total - min_avail_bytes) / total) * 100 if min_avail_bytes is not None else None
    avg_avail_gb = avg_avail_bytes / (1024 * 1024 * 1024) if avg_avail_bytes is not None else None
    return avg_used, max_used, avg_avail_gb

# read + dedupe by ResourceId, keep highest score
by_id = {}
with open(input_csv, newline='', encoding='utf-8-sig') as f:
    r = csv.DictReader(f)
    for row in r:
        rid = (row.get("ResourceId") or "").strip()
        if "/providers/microsoft.compute/virtualmachines/" not in rid.lower():
            continue
        total3 = to_float(row.get("TotalCost3Mo"))
        obs = to_float(row.get("ObservedMonthlyCostUSD"))
        score = total3 if total3 is not None else (obs * 3 if obs is not None else 0.0)
        prev = by_id.get(rid)
        if (prev is None) or (score > prev[0]):
            by_id[rid] = (score, row)

rows = list(by_id.values())
rows.sort(key=lambda x: x[0], reverse=True)
if top_n > 0:
    rows = rows[:top_n]
print(len(rows))
print(f"VM rows to process: {len(rows)}", file=sys.stderr)

with open(output_csv, "w", newline="", encoding="utf-8") as f:
    w = csv.DictWriter(f, fieldnames=OUT_COLS)
    w.writeheader()
    for idx, (_, row) in enumerate(rows, start=1):
        sub = (row.get("SubscriptionId") or "").strip()
        rid = (row.get("ResourceId") or "").strip()
        name = (row.get("ResourceName") or "").strip() or derive_name(rid)
        total3 = to_float(row.get("TotalCost3Mo"))
        obs = to_float(row.get("ObservedMonthlyCostUSD"))
        if obs is None and total3 is not None:
            obs = total3 / 3.0
        print(f"Processing VM: {name} ({idx}/{len(rows)})", file=sys.stderr)
        if sub:
            subprocess.run(["az", "account", "set", "--subscription", sub], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        out = {k: "" for k in OUT_COLS}
        out.update({
            "SubscriptionId": sub,
            "ResourceId": rid,
            "ResourceName": name,
            "ObservedMonthlyCostUSD": f2(obs),
            "TotalCost3Mo": f2(total3),
        })

        info = get_vm_info(rid)
        if not info:
            out.update({"Recommendation": "Review manually", "Evidence": "vmShowFailed", "PricingLookupStatus": "error", "RecommendationConfidence": "Low"})
            w.writerow(out)
            continue

        region = info["region"]
        sku = info["sku"]
        os_type = info["os"]
        size = info["size"]
        vcpu, mem_gb = get_size_caps(region, size)
        avg_cpu, max_cpu = metric_avg_max(rid, "Percentage CPU")
        avg_avail_bytes, min_avail_bytes = metric_avg_min(rid, "Available Memory Bytes")
        avg_mem_used, max_mem_used, avg_avail_gb = calc_mem(mem_gb, avg_avail_bytes, min_avail_bytes)

        cur_price, cur_meter = retail_price_lookup(sku, region, os_type, "Consumption")
        ri1, ri1_meter = retail_price_lookup(sku, region, os_type, "Reservation", "1 Year")
        ri3, ri3_meter = retail_price_lookup(sku, region, os_type, "Reservation", "3 Years")

        pricing_status = "ok"
        pricing_source = "retail"
        if cur_price is None and obs is not None:
            cur_price = obs
            pricing_status = "fallback"
            pricing_source = "observed_monthly"
        elif cur_price is None:
            pricing_status = "notfound"
            pricing_source = ""

        target_sku = TARGET_MAP.get(sku, "")
        target_price = None
        if target_sku and target_sku != sku:
            target_price, _ = retail_price_lookup(target_sku, region, os_type, "Consumption")

        savings = None
        savings_type = ""
        recommendation = "Review manually"
        confidence = "Low"
        low_cpu = avg_cpu is not None and avg_cpu <= 10
        peak_ok = max_cpu is not None and max_cpu < 70
        mem_ok = avg_mem_used is not None and avg_mem_used < 70

        if low_cpu and peak_ok and target_sku and target_price is not None and cur_price is not None and target_price < cur_price:
            savings = cur_price - target_price
            savings_type = "Resize"
            recommendation = f"Resize to {target_sku}"
            confidence = "High" if mem_ok else "Medium"
        elif cur_price is not None and ri1 is not None and ri1 < cur_price:
            savings = cur_price - ri1
            savings_type = "RI"
            recommendation = "Consider 1Y Reserved Instance"
            confidence = "Medium"

        evidence = (
            f"sku={sku}; osType={os_type}; vcpu={f2(vcpu)}; memoryGiB={f2(mem_gb)}; "
            f"avgCPU={f2(avg_cpu)}; maxCPU={f2(max_cpu)}; avgMemUsedPct={f2(avg_mem_used)}; "
            f"maxMemUsedPct={f2(max_mem_used)}; avgAvailableMemoryGB={f2(avg_avail_gb)}; "
            f"paygMeter={cur_meter}; ri1Meter={ri1_meter}; ri3Meter={ri3_meter}"
        )

        out.update({
            "CurrentSKU": sku,
            "Region": region,
            "OSType": os_type,
            "VMSizevCPU": f2(vcpu),
            "VMSizeMemoryGiB": f2(mem_gb),
            "AvgCPU": f2(avg_cpu),
            "MaxCPU": f2(max_cpu),
            "AvgMemoryUsedPct": f2(avg_mem_used),
            "MaxMemoryUsedPct": f2(max_mem_used),
            "AvgAvailableMemoryGB": f2(avg_avail_gb),
            "CurrentListMonthlyUSD": f2(cur_price),
            "RI1YListMonthlyUSD": f2(ri1),
            "RI3YListMonthlyUSD": f2(ri3),
            "TargetSKU": target_sku,
            "TargetListMonthlyUSD": f2(target_price),
            "EstimatedMonthlySavingsUSD": f2(savings),
            "SavingsType": savings_type,
            "Recommendation": recommendation,
            "Evidence": evidence,
            "PricingLookupStatus": pricing_status,
            "PricingSource": pricing_source,
            "RecommendationConfidence": confidence,
        })
        w.writerow(out)

print(f"Done. Output written to {output_csv}", file=sys.stderr)
PY
