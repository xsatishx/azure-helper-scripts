#!/usr/bin/env bash
set -euo pipefail

# databricks_optimize_collector_v1.sh
# Read-only Azure Databricks cost optimisation collector
# Collects Azure Databricks workspaces, Azure cost, clusters, jobs, SQL warehouses and simple cost findings.

usage() {
  cat <<'USAGE'
Usage:
  ./databricks_optimize_collector_v1.sh \
    --subs-file subs.txt \
    --cost-start YYYY-MM-DD \
    --cost-end YYYY-MM-DD \
    --token-file ./databricks_token.txt \
    --output-dir ./databricks-costopt-out

Required:
  --subs-file PATH              Text file with one Azure subscription ID per line
  --cost-start YYYY-MM-DD       Cost query start date, for example 2026-02-01
  --cost-end YYYY-MM-DD         Cost query end date, for example 2026-05-01

Databricks auth, choose one:
  --token TOKEN                 One Databricks PAT/AAD token used for all discovered workspaces
  --token-file PATH             File containing one Databricks token
  --token-map PATH              CSV file: WorkspaceUrl,Token for multiple workspace-specific tokens

Optional:
  --output-dir PATH             Output folder prefix. Default: ./databricks-costopt-out-<timestamp>
  --workspace-url URL           Limit Databricks API collection to one workspace URL
  --warehouse-id ID             Optional SQL warehouse ID used to query system.billing.usage
  --skip-azure-cost             Skip Azure Cost Management collection
  --skip-databricks-api         Only collect Azure workspace inventory and Azure cost
  --help                        Show this help

Examples:
  ./databricks_optimize_collector_v1.sh \
    --subs-file subs.txt \
    --cost-start 2026-02-01 \
    --cost-end 2026-05-01 \
    --token-file ./databricks_token.txt

  ./databricks_optimize_collector_v1.sh \
    --subs-file subs.txt \
    --cost-start 2026-02-01 \
    --cost-end 2026-05-01 \
    --token-map ./workspace_tokens.csv

Notes:
  - This script is read-only.
  - Token on command line can be stored in shell history. --token-file or --token-map is safer.
  - Requires: az, jq, curl.
USAGE
}

SUBS_FILE=""
COST_START=""
COST_END=""
TOKEN=""
TOKEN_FILE=""
TOKEN_MAP=""
OUTPUT_DIR=""
WORKSPACE_URL_FILTER=""
WAREHOUSE_ID=""
SKIP_AZURE_COST=0
SKIP_DATABRICKS_API=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subs-file) SUBS_FILE="${2:-}"; shift 2 ;;
    --cost-start) COST_START="${2:-}"; shift 2 ;;
    --cost-end) COST_END="${2:-}"; shift 2 ;;
    --token) TOKEN="${2:-}"; shift 2 ;;
    --token-file) TOKEN_FILE="${2:-}"; shift 2 ;;
    --token-map) TOKEN_MAP="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --workspace-url) WORKSPACE_URL_FILTER="${2:-}"; shift 2 ;;
    --warehouse-id) WAREHOUSE_ID="${2:-}"; shift 2 ;;
    --skip-azure-cost) SKIP_AZURE_COST=1; shift ;;
    --skip-databricks-api) SKIP_DATABRICKS_API=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: Missing required command: $1" >&2; exit 1; }
}

validate_date() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "ERROR: Invalid date '$1'. Use YYYY-MM-DD." >&2; exit 1; }
}

require_cmd az
require_cmd jq
require_cmd curl

[[ -n "$SUBS_FILE" ]] || { echo "ERROR: --subs-file is required." >&2; usage; exit 1; }
[[ -f "$SUBS_FILE" ]] || { echo "ERROR: subs file not found: $SUBS_FILE" >&2; exit 1; }
[[ -n "$COST_START" ]] || { echo "ERROR: --cost-start is required." >&2; usage; exit 1; }
[[ -n "$COST_END" ]] || { echo "ERROR: --cost-end is required." >&2; usage; exit 1; }
validate_date "$COST_START"
validate_date "$COST_END"

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="./databricks-costopt-out-$(date -u +%Y%m%d-%H%M%S)"
fi
mkdir -p "$OUTPUT_DIR/raw"

if [[ -n "$TOKEN_FILE" ]]; then
  [[ -f "$TOKEN_FILE" ]] || { echo "ERROR: token file not found: $TOKEN_FILE" >&2; exit 1; }
  TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"
fi

if [[ "$SKIP_DATABRICKS_API" -eq 0 && -z "$TOKEN" && -z "$TOKEN_MAP" ]]; then
  echo "ERROR: Databricks API collection requires --token, --token-file, or --token-map. Or use --skip-databricks-api." >&2
  exit 1
fi

if [[ -n "$TOKEN_MAP" ]]; then
  [[ -f "$TOKEN_MAP" ]] || { echo "ERROR: token map not found: $TOKEN_MAP" >&2; exit 1; }
fi

echo "============================================================"
echo "Azure Databricks Cost Optimisation Collector"
echo "Output:       $OUTPUT_DIR"
echo "Cost window:  $COST_START to $COST_END"
echo "Subs file:    $SUBS_FILE"
echo "Read-only:    yes"
echo "============================================================"

# Confirm Azure login
az account show >/dev/null 2>&1 || { echo "ERROR: Azure CLI is not logged in. Run az login first." >&2; exit 1; }

WORKSPACES_CSV="$OUTPUT_DIR/01_databricks_workspaces.csv"
AZURE_COST_CSV="$OUTPUT_DIR/02_azure_cost_by_resource.csv"
CLUSTERS_CSV="$OUTPUT_DIR/03_clusters.csv"
CLUSTER_FINDINGS_CSV="$OUTPUT_DIR/04_cluster_findings.csv"
JOBS_CSV="$OUTPUT_DIR/05_jobs.csv"
WAREHOUSES_CSV="$OUTPUT_DIR/06_sql_warehouses.csv"
DBU_CSV="$OUTPUT_DIR/07_dbu_usage.csv"
RECS_CSV="$OUTPUT_DIR/08_recommendations.csv"
SUMMARY_TXT="$OUTPUT_DIR/Summary.txt"

printf 'SubscriptionId,ResourceGroup,WorkspaceName,WorkspaceUrl,Location,Sku,ManagedResourceGroupId,ResourceId\n' > "$WORKSPACES_CSV"
printf 'SubscriptionId,ResourceId,ResourceType,ResourceGroup,ServiceName,Cost,Currency\n' > "$AZURE_COST_CSV"
printf 'WorkspaceUrl,ClusterId,ClusterName,State,Creator,ClusterSource,SparkVersion,NodeType,DriverNodeType,NumWorkers,AutoscaleMin,AutoscaleMax,AutoTerminationMinutes,CustomTagsJson\n' > "$CLUSTERS_CSV"
printf 'WorkspaceUrl,Severity,FindingType,ObjectType,ObjectId,ObjectName,Recommendation\n' > "$CLUSTER_FINDINGS_CSV"
printf 'WorkspaceUrl,JobId,JobName,Creator,ScheduleQuartz,UsesExistingCluster,ExistingClusterId,NewClusterNodeType,NewClusterWorkers,NewClusterAutoscaleMin,NewClusterAutoscaleMax\n' > "$JOBS_CSV"
printf 'WorkspaceUrl,WarehouseId,Name,State,ClusterSize,MinClusters,MaxClusters,AutoStopMinutes,WarehouseType,SpotInstancePolicy,Creator\n' > "$WAREHOUSES_CSV"
printf 'WorkspaceUrl,UsageDate,SkuName,UsageUnit,DBUs,WorkspaceId,BillingOriginProduct\n' > "$DBU_CSV"
printf 'Priority,WorkspaceUrl,Area,ObjectType,ObjectName,Finding,Recommendation\n' > "$RECS_CSV"

normalize_url() {
  local u="$1"
  if [[ "$u" != http* ]]; then
    u="https://$u"
  fi
  echo "${u%/}"
}

csv_escape() {
  local s="${1:-}"
  s="${s//$'\n'/ }"
  s="${s//$'\r'/ }"
  s="${s//\"/\"\"}"
  printf '"%s"' "$s"
}

get_token_for_workspace() {
  local ws_url="$1"
  if [[ -n "$TOKEN_MAP" ]]; then
    awk -F',' -v url="$ws_url" 'BEGIN{IGNORECASE=1} NR==1 && $1 ~ /WorkspaceUrl/ {next} {gsub(/\r/,"",$1); gsub(/\r/,"",$2); if ($1==url || $1==url"/") {print $2; exit}}' "$TOKEN_MAP"
  else
    echo "$TOKEN"
  fi
}

db_api_get() {
  local ws_url="$1"
  local endpoint="$2"
  local token="$3"
  curl -sS --fail --connect-timeout 20 --max-time 120 \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    "$ws_url$endpoint"
}

db_api_post() {
  local ws_url="$1"
  local endpoint="$2"
  local token="$3"
  local body="$4"
  curl -sS --fail --connect-timeout 20 --max-time 120 \
    -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "$ws_url$endpoint"
}

collect_workspaces_for_sub() {
  local sub="$1"
  echo "[Workspace] Discovering Databricks workspaces in subscription: $sub"
  local tmp="$OUTPUT_DIR/raw/workspaces_$sub.json"
  set +e
  az graph query --subscriptions "$sub" -q "
resources
| where type =~ 'microsoft.databricks/workspaces'
| project subscriptionId, resourceGroup, name, location, workspaceUrl=tostring(properties.workspaceUrl), sku=tostring(sku.name), managedResourceGroupId=tostring(properties.managedResourceGroupId), id
" -o json > "$tmp" 2>"$OUTPUT_DIR/raw/workspaces_$sub.err"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "  WARN: ARG workspace query failed for $sub. See raw/workspaces_$sub.err"
    return 0
  fi
  jq -r '.data[]? | [.subscriptionId,.resourceGroup,.name,.workspaceUrl,.location,.sku,.managedResourceGroupId,.id] | @csv' "$tmp" >> "$WORKSPACES_CSV"
}

collect_cost_for_sub() {
  local sub="$1"
  [[ "$SKIP_AZURE_COST" -eq 1 ]] && return 0
  echo "[Cost] Pulling amortized cost for subscription: $sub"
  local body tmp
  tmp="$OUTPUT_DIR/raw/cost_$sub.json"
  body="$(jq -n --arg from "$COST_START" --arg to "$COST_END" '{
    type: "AmortizedCost",
    timeframe: "Custom",
    timePeriod: {from: $from, to: $to},
    dataset: {
      granularity: "None",
      aggregation: {totalCost: {name: "Cost", function: "Sum"}},
      grouping: [
        {type: "Dimension", name: "ResourceId"},
        {type: "Dimension", name: "ResourceType"},
        {type: "Dimension", name: "ResourceGroupName"},
        {type: "Dimension", name: "ServiceName"}
      ]
    }
  }')"
  set +e
  az rest --method post \
    --url "https://management.azure.com/subscriptions/$sub/providers/Microsoft.CostManagement/query?api-version=2023-03-01" \
    --body "$body" > "$tmp" 2>"$OUTPUT_DIR/raw/cost_$sub.err"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "  WARN: Cost query failed for $sub. See raw/cost_$sub.err"
    return 0
  fi
  jq -r --arg sub "$sub" '
    .properties.rows[]? as $r
    | [$sub, ($r[0] // ""), ($r[1] // ""), ($r[2] // ""), ($r[3] // ""), ($r[4] // 0), (.properties.columns[-1].name // "")] | @csv
  ' "$tmp" >> "$AZURE_COST_CSV" || true
}

collect_clusters() {
  local ws_url="$1"
  local token="$2"
  echo "[Databricks] Collecting clusters: $ws_url"
  local tmp="$OUTPUT_DIR/raw/clusters_$(echo "$ws_url" | sed 's#https\?://##; s#[/:]#_#g').json"
  set +e
  db_api_get "$ws_url" "/api/2.0/clusters/list" "$token" > "$tmp" 2>"$tmp.err"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "  WARN: Cluster API failed for $ws_url. See $tmp.err"
    return 0
  fi

  jq -r --arg ws "$ws_url" '
    .clusters[]? | [
      $ws,
      (.cluster_id // ""),
      (.cluster_name // ""),
      (.state // ""),
      (.creator_user_name // ""),
      (.cluster_source // ""),
      (.spark_version // ""),
      (.node_type_id // ""),
      (.driver_node_type_id // ""),
      (.num_workers // ""),
      (.autoscale.min_workers // ""),
      (.autoscale.max_workers // ""),
      (.autotermination_minutes // ""),
      ((.custom_tags // {}) | tostring)
    ] | @csv
  ' "$tmp" >> "$CLUSTERS_CSV"

  jq -r --arg ws "$ws_url" '
    def tag_missing($k): ((.custom_tags // {})[$k] // "") == "";
    .clusters[]? as $c
    | [
        (if (($c.cluster_source // "") != "JOB" and (($c.autotermination_minutes // 0) == 0)) then [$ws,"High","NoAutoTermination","Cluster",($c.cluster_id//""),($c.cluster_name//""),"Set auto-termination to 15-30 minutes for all-purpose clusters"] else empty end),
        (if (($c.cluster_source // "") != "JOB" and (($c.autotermination_minutes // 0) > 60)) then [$ws,"Medium","HighAutoTermination","Cluster",($c.cluster_id//""),($c.cluster_name//""),"Reduce auto-termination to 15-30 minutes unless justified"] else empty end),
        (if (($c.autoscale // null) == null and (($c.num_workers // 0) >= 4)) then [$ws,"Medium","FixedWorkers","Cluster",($c.cluster_id//""),($c.cluster_name//""),"Use autoscaling or validate fixed worker count"] else empty end),
        (if ((($c.autoscale.max_workers // 0) >= 20) or (($c.num_workers // 0) >= 20)) then [$ws,"High","LargeCluster","Cluster",($c.cluster_id//""),($c.cluster_name//""),"Review large worker count and validate workload requirement"] else empty end),
        (if ((($c.node_type_id // "") | test("(?i)(standard_nc|standard_nd|standard_nv|gpu)"))) then [$ws,"High","GpuNodeType","Cluster",($c.cluster_id//""),($c.cluster_name//""),"Restrict GPU SKUs unless required for ML/GPU workloads"] else empty end),
        (if (tag_missing("Owner") or tag_missing("CostCenter") or tag_missing("Environment") or tag_missing("Application")) then [$ws,"Medium","MissingTags","Cluster",($c.cluster_id//""),($c.cluster_name//""),"Enforce Owner, CostCenter, Environment and Application tags through cluster policy"] else empty end)
      ][] | @csv
  ' "$tmp" >> "$CLUSTER_FINDINGS_CSV" || true
}

collect_jobs() {
  local ws_url="$1"
  local token="$2"
  echo "[Databricks] Collecting jobs: $ws_url"
  local base tmp page token_next
  base="$(echo "$ws_url" | sed 's#https\?://##; s#[/:]#_#g')"
  tmp="$OUTPUT_DIR/raw/jobs_${base}.json"
  set +e
  db_api_get "$ws_url" "/api/2.1/jobs/list?limit=100&expand_tasks=true" "$token" > "$tmp" 2>"$tmp.err"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "  WARN: Jobs API failed for $ws_url. See $tmp.err"
    return 0
  fi

  jq -r --arg ws "$ws_url" '
    .jobs[]? as $j
    | ($j.settings.tasks // []) as $tasks
    | if ($tasks|length) > 0 then
        $tasks[] | [
          $ws,
          ($j.job_id // ""),
          ($j.settings.name // ""),
          ($j.creator_user_name // ""),
          ($j.settings.schedule.quartz_cron_expression // ""),
          ((.existing_cluster_id // "") != ""),
          (.existing_cluster_id // ""),
          (.new_cluster.node_type_id // ""),
          (.new_cluster.num_workers // ""),
          (.new_cluster.autoscale.min_workers // ""),
          (.new_cluster.autoscale.max_workers // "")
        ] | @csv
      else
        [
          $ws,
          ($j.job_id // ""),
          ($j.settings.name // ""),
          ($j.creator_user_name // ""),
          ($j.settings.schedule.quartz_cron_expression // ""),
          (($j.settings.existing_cluster_id // "") != ""),
          ($j.settings.existing_cluster_id // ""),
          ($j.settings.new_cluster.node_type_id // ""),
          ($j.settings.new_cluster.num_workers // ""),
          ($j.settings.new_cluster.autoscale.min_workers // ""),
          ($j.settings.new_cluster.autoscale.max_workers // "")
        ] | @csv
      end
  ' "$tmp" >> "$JOBS_CSV"

  jq -r --arg ws "$ws_url" '
    .jobs[]? as $j
    | ($j.settings.tasks // []) as $tasks
    | if ($tasks|length) > 0 then
        $tasks[] | select((.existing_cluster_id // "") != "") | ["High",$ws,"Jobs","Job",($j.settings.name//""),"Job uses existing all-purpose cluster","Move scheduled workload to a job cluster/serverless job compute where suitable"] | @csv
      else
        select(($j.settings.existing_cluster_id // "") != "") | ["High",$ws,"Jobs","Job",($j.settings.name//""),"Job uses existing all-purpose cluster","Move scheduled workload to a job cluster/serverless job compute where suitable"] | @csv
      end
  ' "$tmp" >> "$RECS_CSV" || true
}

collect_warehouses() {
  local ws_url="$1"
  local token="$2"
  echo "[Databricks] Collecting SQL warehouses: $ws_url"
  local tmp="$OUTPUT_DIR/raw/warehouses_$(echo "$ws_url" | sed 's#https\?://##; s#[/:]#_#g').json"
  set +e
  db_api_get "$ws_url" "/api/2.0/sql/warehouses" "$token" > "$tmp" 2>"$tmp.err"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "  WARN: SQL Warehouses API failed for $ws_url. See $tmp.err"
    return 0
  fi

  jq -r --arg ws "$ws_url" '
    (.warehouses // [])[]? | [
      $ws,
      (.id // ""),
      (.name // ""),
      (.state // ""),
      (.cluster_size // ""),
      (.min_num_clusters // ""),
      (.max_num_clusters // ""),
      (.auto_stop_mins // ""),
      (.warehouse_type // ""),
      (.spot_instance_policy // ""),
      (.creator_name // "")
    ] | @csv
  ' "$tmp" >> "$WAREHOUSES_CSV"

  jq -r --arg ws "$ws_url" '
    (.warehouses // [])[]?
    | [
        (if ((.auto_stop_mins // 0) == 0) then ["High",$ws,"SQL Warehouse","Warehouse",(.name//""),"SQL warehouse has no auto-stop","Set auto-stop, commonly 10-30 minutes depending on BI pattern"] else empty end),
        (if ((.auto_stop_mins // 0) > 60) then ["Medium",$ws,"SQL Warehouse","Warehouse",(.name//""),"SQL warehouse auto-stop is high","Reduce auto-stop to 10-30 minutes unless justified"] else empty end),
        (if ((.cluster_size // "") | test("(?i)(2x-large|3x-large|4x-large|x-large|large)")) then ["Medium",$ws,"SQL Warehouse","Warehouse",(.name//""),"Large SQL warehouse size","Benchmark smaller warehouse size and validate query performance"] else empty end),
        (if ((.max_num_clusters // 0) > 5) then ["Medium",$ws,"SQL Warehouse","Warehouse",(.name//""),"High max cluster scaling","Review concurrency need and cap max clusters"] else empty end)
      ][] | @csv
  ' "$tmp" >> "$RECS_CSV" || true
}

collect_dbu_usage() {
  local ws_url="$1"
  local token="$2"
  [[ -z "$WAREHOUSE_ID" ]] && return 0
  echo "[Databricks] Querying system.billing.usage using warehouse: $WAREHOUSE_ID"
  local statement tmp stmt_id status_url status
  statement="select date(usage_start_time) as usage_date, sku_name, usage_unit, round(sum(usage_quantity), 4) as dbus, workspace_id, billing_origin_product from system.billing.usage where usage_start_time >= date('$COST_START') and usage_start_time < date('$COST_END') group by all order by usage_date desc, dbus desc limit 1000"
  tmp="$OUTPUT_DIR/raw/dbu_statement_$(echo "$ws_url" | sed 's#https\?://##; s#[/:]#_#g').json"
  local body
  body="$(jq -n --arg wh "$WAREHOUSE_ID" --arg st "$statement" '{warehouse_id:$wh, statement:$st, wait_timeout:"30s"}')"
  set +e
  db_api_post "$ws_url" "/api/2.0/sql/statements" "$token" "$body" > "$tmp" 2>"$tmp.err"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "  WARN: DBU usage query failed for $ws_url. See $tmp.err"
    return 0
  fi
  jq -r --arg ws "$ws_url" '
    if (.result.data_array // null) != null then
      .result.data_array[] | [$ws, .[0], .[1], .[2], .[3], .[4], .[5]] | @csv
    else empty end
  ' "$tmp" >> "$DBU_CSV" || true
}

# Main collection loop
while IFS= read -r sub || [[ -n "$sub" ]]; do
  sub="$(echo "$sub" | tr -d '\r' | xargs)"
  [[ -z "$sub" || "$sub" =~ ^# ]] && continue
  collect_workspaces_for_sub "$sub"
  collect_cost_for_sub "$sub"
done < "$SUBS_FILE"

# De-duplicate workspaces
awk 'NR==1 || !seen[$0]++' "$WORKSPACES_CSV" > "$WORKSPACES_CSV.tmp" && mv "$WORKSPACES_CSV.tmp" "$WORKSPACES_CSV"

if [[ "$SKIP_DATABRICKS_API" -eq 0 ]]; then
  tail -n +2 "$WORKSPACES_CSV" | while IFS=, read -r sub rg name url loc sku mrg id; do
    # CSV values may be quoted; use jq for robust CSV parsing per line
    line="$sub,$rg,$name,$url,$loc,$sku,$mrg,$id"
    ws_url="$(printf '%s\n' "$line" | jq -Rr 'fromcsv | .[3]')"
    [[ -z "$ws_url" ]] && continue
    ws_url="$(normalize_url "$ws_url")"
    if [[ -n "$WORKSPACE_URL_FILTER" ]]; then
      filter_norm="$(normalize_url "$WORKSPACE_URL_FILTER")"
      [[ "$ws_url" == "$filter_norm" ]] || continue
    fi
    token_for_ws="$(get_token_for_workspace "$ws_url")"
    if [[ -z "$token_for_ws" ]]; then
      echo "  WARN: No token found for $ws_url. Skipping Databricks API calls for this workspace."
      continue
    fi
    collect_clusters "$ws_url" "$token_for_ws"
    collect_jobs "$ws_url" "$token_for_ws"
    collect_warehouses "$ws_url" "$token_for_ws"
    collect_dbu_usage "$ws_url" "$token_for_ws"
  done
fi

# Convert cluster findings into recommendations
awk -F',' 'NR>1 {print $2","$1",Clusters,"$4","$6","$3","$7}' "$CLUSTER_FINDINGS_CSV" >> "$RECS_CSV" || true

# Summary
{
  echo "Databricks Cost Optimisation Collector Summary"
  echo "Generated UTC: $(date -u)"
  echo "Cost window:   $COST_START .. $COST_END"
  echo "Subs file:     $SUBS_FILE"
  echo "Output dir:    $OUTPUT_DIR"
  echo ""
  echo "Counts:"
  echo "- Workspaces:       $(($(wc -l < "$WORKSPACES_CSV") - 1))"
  echo "- Azure cost rows:  $(($(wc -l < "$AZURE_COST_CSV") - 1))"
  echo "- Clusters:         $(($(wc -l < "$CLUSTERS_CSV") - 1))"
  echo "- Cluster findings: $(($(wc -l < "$CLUSTER_FINDINGS_CSV") - 1))"
  echo "- Jobs rows:        $(($(wc -l < "$JOBS_CSV") - 1))"
  echo "- Warehouses:       $(($(wc -l < "$WAREHOUSES_CSV") - 1))"
  echo "- DBU rows:         $(($(wc -l < "$DBU_CSV") - 1))"
  echo "- Recommendations:  $(($(wc -l < "$RECS_CSV") - 1))"
  echo ""
  echo "Outputs:"
  echo "- $WORKSPACES_CSV"
  echo "- $AZURE_COST_CSV"
  echo "- $CLUSTERS_CSV"
  echo "- $CLUSTER_FINDINGS_CSV"
  echo "- $JOBS_CSV"
  echo "- $WAREHOUSES_CSV"
  echo "- $DBU_CSV"
  echo "- $RECS_CSV"
} > "$SUMMARY_TXT"

cat "$SUMMARY_TXT"
echo "Done."
