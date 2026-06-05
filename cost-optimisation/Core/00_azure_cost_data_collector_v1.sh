#!/usr/bin/env bash
set -euo pipefail

# Azure Cost Optimization - Phase 0 Orchestrator
# ------------------------------------------------------------
# Reads subscription IDs from subs.txt and collects:
#   1. 3-month amortized cost by resource
#   2. Azure Advisor cost recommendations
# Produces:
#   - CostByResource.csv
#   - AdvisorCostRecommendations.csv
#   - FinalRankedReport.csv
#   - phase0_raw_cost_json/*.json
#   - phase0_logs/phase0.log
#
# Usage:
#   chmod +x costopt_phase0_orchestrator.sh
#   ./costopt_phase0_orchestrator.sh subs.txt FinalRankedReport.csv
#
# Optional env vars:
#   MONTHS=3
#   CURRENCY=USD
#   TOP_N=0          # 0 = all rows
#   SLEEP_SECONDS=2 # between subscription calls

SUBS_FILE="${1:-subs.txt}"
FINAL_OUT="${2:-FinalRankedReport.csv}"
MONTHS="${MONTHS:-3}"
CURRENCY="${CURRENCY:-USD}"
TOP_N="${TOP_N:-0}"
SLEEP_SECONDS="${SLEEP_SECONDS:-2}"

COST_OUT="CostByResource.csv"
ADVISOR_OUT="AdvisorCostRecommendations.csv"
RAW_DIR="phase0_raw_cost_json"
LOG_DIR="phase0_logs"
LOG_FILE="$LOG_DIR/phase0.log"

mkdir -p "$RAW_DIR" "$LOG_DIR"
: > "$LOG_FILE"

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG_FILE" >&2
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: missing required command: $1" >&2
    exit 1
  fi
}

need_cmd az
need_cmd jq
need_cmd python3

if [[ ! -f "$SUBS_FILE" ]]; then
  echo "ERROR: subscription file not found: $SUBS_FILE" >&2
  echo "Create it with one subscription ID per line." >&2
  exit 1
fi

if ! az account show >/dev/null 2>&1; then
  echo "ERROR: Azure CLI is not logged in. Run: az login" >&2
  exit 1
fi

START_DATE=$(python3 - <<PY
from datetime import date
import calendar
months=int('$MONTHS')
today=date.today()
y=today.year
m=today.month-months
while m<=0:
    m+=12
    y-=1
print(date(y,m,1).isoformat())
PY
)
END_DATE=$(date -u '+%Y-%m-%d')

log "Phase 0 started"
log "Subscriptions file: $SUBS_FILE"
log "Cost window: $START_DATE to $END_DATE ($MONTHS months)"
log "Output: $FINAL_OUT"

# CSV headers
cat > "$COST_OUT" <<'EOF'
SubscriptionId,ResourceId,ResourceGroup,ResourceName,ResourceType,ServiceName,Location,TotalCost3Mo,Currency,Source
EOF

cat > "$ADVISOR_OUT" <<'EOF'
SubscriptionId,ResourceId,ResourceGroup,ResourceName,ResourceType,FindingType,Severity,CurrentState,Recommendation,EstimatedSavingsNotes,SignalSource
EOF

retry_az_rest() {
  local method="$1"
  local url="$2"
  local body_file="${3:-}"
  local max=6
  local wait=5
  local attempt=1
  local tmp_err
  tmp_err=$(mktemp)

  while (( attempt <= max )); do
    if [[ -n "$body_file" ]]; then
      if az rest --method "$method" --url "$url" --body "@$body_file" -o json 2>"$tmp_err"; then
        rm -f "$tmp_err"
        return 0
      fi
    else
      if az rest --method "$method" --url "$url" -o json 2>"$tmp_err"; then
        rm -f "$tmp_err"
        return 0
      fi
    fi

    if grep -qiE 'TooManyRequests|429|throttl|temporarily unavailable|timeout|GatewayTimeout|InternalServerError' "$tmp_err"; then
      log "Retryable Azure REST error, attempt $attempt/$max. Sleeping ${wait}s. URL: $url"
      sleep "$wait"
      wait=$((wait * 2))
      attempt=$((attempt + 1))
    else
      cat "$tmp_err" >&2
      rm -f "$tmp_err"
      return 1
    fi
  done

  cat "$tmp_err" >&2 || true
  rm -f "$tmp_err"
  return 1
}

csv_escape_py='import csv,sys; w=csv.writer(sys.stdout); w.writerow(sys.argv[1:])'
write_csv_row() {
  python3 -c "$csv_escape_py" "$@" | sed 's/\r$//'
}

collect_cost_for_sub() {
  local sub="$1"
  local body tmp raw
  body=$(mktemp)
  tmp=$(mktemp)
  raw="$RAW_DIR/cost_${sub}.json"

  cat > "$body" <<EOF
{
  "type": "AmortizedCost",
  "timeframe": "Custom",
  "timePeriod": {
    "from": "${START_DATE}T00:00:00Z",
    "to": "${END_DATE}T23:59:59Z"
  },
  "dataset": {
    "granularity": "None",
    "aggregation": {
      "totalCost": {
        "name": "Cost",
        "function": "Sum"
      }
    },
    "grouping": [
      { "type": "Dimension", "name": "ResourceId" },
      { "type": "Dimension", "name": "ResourceGroupName" },
      { "type": "Dimension", "name": "ResourceType" },
      { "type": "Dimension", "name": "ServiceName" },
      { "type": "Dimension", "name": "ResourceLocation" }
    ]
  }
}
EOF

  local url="https://management.azure.com/subscriptions/${sub}/providers/Microsoft.CostManagement/query?api-version=2023-03-01"
  if retry_az_rest POST "$url" "$body" > "$tmp"; then
    cp "$tmp" "$raw"
    python3 - "$sub" "$tmp" >> "$COST_OUT" <<'PY'
import csv, json, sys, os
sub = sys.argv[1]
path = sys.argv[2]
with open(path, encoding='utf-8') as f:
    data = json.load(f)
cols = [c.get('name') for c in data.get('properties', {}).get('columns', [])]
idx = {name:i for i,name in enumerate(cols)}
rows = data.get('properties', {}).get('rows', [])
w = csv.writer(sys.stdout)
for r in rows:
    def get(name, default=''):
        i = idx.get(name)
        return r[i] if i is not None and i < len(r) else default
    cost = get('Cost', 0) or 0
    rid = str(get('ResourceId','') or '')
    rg = str(get('ResourceGroupName','') or '')
    rtype = str(get('ResourceType','') or '')
    svc = str(get('ServiceName','') or '')
    loc = str(get('ResourceLocation','') or '')
    currency = str(get('Currency','') or '') or os.environ.get('CURRENCY','USD')
    name = rid.rstrip('/').split('/')[-1] if rid else ''
    if not rid and float(cost or 0) == 0:
        continue
    w.writerow([sub, rid, rg, name, rtype, svc, loc, round(float(cost or 0), 6), currency, 'CostManagement'])
PY
    log "Cost collected for $sub"
  else
    log "WARNING: Cost collection failed for $sub"
  fi

  rm -f "$body" "$tmp"
}

collect_advisor_for_sub() {
  local sub="$1"
  local tmp
  tmp=$(mktemp)

  # Advisor REST: filter to Cost category where possible. Some tenants reject filters, so fallback to unfiltered.
  local url="https://management.azure.com/subscriptions/${sub}/providers/Microsoft.Advisor/recommendations?api-version=2023-01-01"
  if ! retry_az_rest GET "$url" > "$tmp"; then
    log "WARNING: Advisor collection failed for $sub"
    rm -f "$tmp"
    return 0
  fi

  python3 - "$sub" "$tmp" >> "$ADVISOR_OUT" <<'PY'
import csv, json, sys
sub = sys.argv[1]
path = sys.argv[2]
with open(path, encoding='utf-8') as f:
    data = json.load(f)
w = csv.writer(sys.stdout)
for item in data.get('value', []):
    p = item.get('properties', {}) or {}
    cat = str(p.get('category','') or '')
    if cat.lower() != 'cost':
        continue
    rid = p.get('resourceMetadata', {}).get('resourceId') or p.get('impactedValue') or ''
    rtype = p.get('impactedField') or ''
    name = rid.rstrip('/').split('/')[-1] if rid else str(p.get('impactedValue','') or '')
    rg = ''
    parts = rid.split('/') if rid else []
    try:
        rg = parts[parts.index('resourceGroups')+1]
    except Exception:
        pass
    short = p.get('shortDescription', {}) or {}
    problem = short.get('problem') or 'Advisor Cost Recommendation'
    solution = short.get('solution') or p.get('recommendationTypeId') or ''
    impact = p.get('impact') or ''
    state = p.get('metadata', {}).get('state') or ''
    notes = ''
    ext = p.get('extendedProperties') or {}
    for key in ('savingsAmount','annualSavingsAmount','monthlySavingsAmount','term'):
        if key in ext:
            notes += f'{key}={ext[key]}; '
    w.writerow([sub, rid, rg, name, rtype, problem, impact, state, solution, notes.strip(), 'Advisor'])
PY
  log "Advisor cost recommendations collected for $sub"
  rm -f "$tmp"
}

# Iterate subscriptions
count=0
while IFS= read -r sub || [[ -n "$sub" ]]; do
  sub=$(echo "$sub" | tr -d '\r' | xargs)
  [[ -z "$sub" ]] && continue
  [[ "$sub" =~ ^# ]] && continue
  count=$((count+1))
  log "[$count] Processing subscription $sub"

  if ! az account set --subscription "$sub" >/dev/null 2>&1; then
    log "WARNING: Cannot set subscription context: $sub. Skipping."
    continue
  fi

  collect_cost_for_sub "$sub"
  collect_advisor_for_sub "$sub"
  sleep "$SLEEP_SECONDS"
done < "$SUBS_FILE"

log "Merging cost + advisor signals into $FINAL_OUT"
python3 - "$COST_OUT" "$ADVISOR_OUT" "$FINAL_OUT" "$TOP_N" <<'PY'
import csv, sys, math
from collections import defaultdict
cost_file, advisor_file, out_file, top_n = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])

cost_rows=[]
with open(cost_file, newline='', encoding='utf-8') as f:
    for r in csv.DictReader(f):
        try:
            total=float(str(r.get('TotalCost3Mo','0')).replace('$','').replace(',','') or 0)
        except Exception:
            total=0.0
        if total <= 0:
            continue
        r['TotalCost3Mo']=round(total,6)
        cost_rows.append(r)

advisor_by_rid=defaultdict(list)
with open(advisor_file, newline='', encoding='utf-8') as f:
    for r in csv.DictReader(f):
        rid=(r.get('ResourceId') or '').lower()
        if rid:
            advisor_by_rid[rid].append(r)

out_cols = [
    'SubscriptionId','ResourceId','ResourceGroup','ResourceName','ResourceType','ServiceName','Location',
    'FindingType','Severity','CurrentState','Recommendation','EstimatedSavingsNotes','SignalSource',
    'TotalCost3Mo','Kind','CurrentSKU','Region','ObservedMonthlyCostUSD','AvgCPU','MaxCPU','AvgMemory','MaxMemory',
    'AvgThroughputMBps','AvgIOPS','CurrentListMonthlyUSD','RI1YListMonthlyUSD','RI3YListMonthlyUSD',
    'TargetSKU','TargetListMonthlyUSD','EstimatedMonthlySavingsUSD','SavingsType','Evidence','SourceResourceId'
]

final=[]
for c in cost_rows:
    rid=(c.get('ResourceId') or '').lower()
    matches=advisor_by_rid.get(rid, [])
    if matches:
        for a in matches:
            row={k:'' for k in out_cols}
            row.update({
                'SubscriptionId': c.get('SubscriptionId',''),
                'ResourceId': c.get('ResourceId',''),
                'ResourceGroup': c.get('ResourceGroup',''),
                'ResourceName': c.get('ResourceName',''),
                'ResourceType': c.get('ResourceType',''),
                'ServiceName': c.get('ServiceName',''),
                'Location': c.get('Location',''),
                'FindingType': a.get('FindingType','Advisor Cost Recommendation'),
                'Severity': a.get('Severity',''),
                'CurrentState': a.get('CurrentState',''),
                'Recommendation': a.get('Recommendation',''),
                'EstimatedSavingsNotes': a.get('EstimatedSavingsNotes',''),
                'SignalSource': 'CostManagement+Advisor',
                'TotalCost3Mo': c.get('TotalCost3Mo',''),
                'Region': c.get('Location',''),
                'ObservedMonthlyCostUSD': round(float(c.get('TotalCost3Mo') or 0)/3, 6),
                'Evidence': f"service={c.get('ServiceName','')}; location={c.get('Location','')}; advisor={a.get('FindingType','')}",
                'SourceResourceId': c.get('ResourceId','')
            })
            final.append(row)
    else:
        row={k:'' for k in out_cols}
        rt=(c.get('ResourceType') or '').lower()
        kind=''
        if 'microsoft.compute/virtualmachines' in rt:
            kind='VM'
        elif 'microsoft.compute/disks' in rt:
            kind='Disk'
        row.update({
            'SubscriptionId': c.get('SubscriptionId',''),
            'ResourceId': c.get('ResourceId',''),
            'ResourceGroup': c.get('ResourceGroup',''),
            'ResourceName': c.get('ResourceName',''),
            'ResourceType': c.get('ResourceType',''),
            'ServiceName': c.get('ServiceName',''),
            'Location': c.get('Location',''),
            'FindingType': 'High spend resource',
            'Severity': 'Info',
            'CurrentState': 'Cost observed in last 3 months',
            'Recommendation': 'Analyze for rightsizing, reservation, or cleanup opportunity',
            'EstimatedSavingsNotes': 'Requires Phase 1/2 enrichment',
            'SignalSource': 'CostManagement',
            'TotalCost3Mo': c.get('TotalCost3Mo',''),
            'Kind': kind,
            'Region': c.get('Location',''),
            'ObservedMonthlyCostUSD': round(float(c.get('TotalCost3Mo') or 0)/3, 6),
            'Evidence': f"service={c.get('ServiceName','')}; location={c.get('Location','')}",
            'SourceResourceId': c.get('ResourceId','')
        })
        final.append(row)

final.sort(key=lambda r: float(r.get('TotalCost3Mo') or 0), reverse=True)
if top_n > 0:
    final = final[:top_n]

with open(out_file, 'w', newline='', encoding='utf-8') as f:
    w=csv.DictWriter(f, fieldnames=out_cols)
    w.writeheader()
    w.writerows(final)

print(f"Wrote {len(final)} rows to {out_file}")
PY

log "Phase 0 complete"
log "Created: $COST_OUT"
log "Created: $ADVISOR_OUT"
log "Created: $FINAL_OUT"
