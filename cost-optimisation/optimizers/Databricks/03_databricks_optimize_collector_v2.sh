#!/usr/bin/env bash
set -euo pipefail

# 03_databricks_optimize_collector_v3.sh
# Read-only Azure Databricks cost optimisation collector
# Collects Azure Databricks workspaces, Azure cost, clusters, jobs, SQL warehouses, instance pools and simple cost findings.

usage() {
  cat <<'USAGE'
Usage:
  ./03_databricks_optimize_collector_v3.sh \
    --subs-file subs.txt \
    --cost-start YYYY-MM-DD \
    --cost-end YYYY-MM-DD \
    --token-file ./databricks_token.txt \
    --output-dir ./databricks-costopt-out

Required for Azure discovery/cost mode:
  --subs-file PATH              Text file with one Azure subscription ID per line

Required for Databricks-only mode:
  --workspace-url URL           Databricks workspace URL

Optional date window:
  --cost-start YYYY-MM-DD       Cost/query start date. Default: 90 days before today UTC
  --cost-end YYYY-MM-DD         Cost/query end date. Default: today UTC

Databricks auth, choose one:
  --token TOKEN                 One Databricks PAT/AAD token used for all discovered workspaces
  --token-file PATH             File containing one Databricks token
  --token-map PATH              CSV file: WorkspaceUrl,Token for multiple workspace-specific tokens

Optional:
  --output-dir PATH             Output folder prefix. Default: ./databricks-costopt-out-<timestamp>
  --workspace-url URL           Limit Databricks API collection to one workspace URL
  --warehouse-id ID             Optional SQL warehouse ID used to query system.billing.usage
  --include-pools true|false    Include Databricks instance pool optimisation analysis. Default: true
  --include-jobs true|false     Include Databricks job/workflow run efficiency analysis. Default: true
  --lookback-days NUMBER       Lookback window for job/workflow run analysis. Default: 30
  --skip-azure-cost             Skip Azure Cost Management collection
  --skip-databricks-api         Only collect Azure workspace inventory and Azure cost
  --help                        Show this help

Examples:
  ./03_databricks_optimize_collector_v3.sh \
    --subs-file subs.txt \
    --cost-start 2026-02-01 \
    --cost-end 2026-05-01 \
    --token-file ./databricks_token.txt

  ./03_databricks_optimize_collector_v3.sh \
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
INCLUDE_POOLS="true"
INCLUDE_JOBS="true"
LOOKBACK_DAYS="30"
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
    --include-pools) INCLUDE_POOLS="${2:-}"; shift 2 ;;
    --include-jobs) INCLUDE_JOBS="${2:-}"; shift 2 ;;
    --lookback-days) LOOKBACK_DAYS="${2:-}"; shift 2 ;;
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

require_cmd jq
require_cmd curl

if [[ -z "$SUBS_FILE" && -z "$WORKSPACE_URL_FILTER" ]]; then
  echo "ERROR: Provide --subs-file for Azure discovery mode or --workspace-url for Databricks-only mode." >&2
  usage
  exit 1
fi

if [[ -n "$SUBS_FILE" ]]; then
  [[ -f "$SUBS_FILE" ]] || { echo "ERROR: subs file not found: $SUBS_FILE" >&2; exit 1; }
  require_cmd az
fi

if [[ -z "$COST_END" ]]; then
  COST_END="$(date -u +%Y-%m-%d)"
fi
if [[ -z "$COST_START" ]]; then
  COST_START="$(date -u -d "$COST_END -90 days" +%Y-%m-%d)"
fi
validate_date "$COST_START"
validate_date "$COST_END"
case "${INCLUDE_POOLS,,}" in
  true|false) ;;
  *) echo "ERROR: --include-pools must be true or false." >&2; exit 1 ;;
esac
case "${INCLUDE_JOBS,,}" in
  true|false) ;;
  *) echo "ERROR: --include-jobs must be true or false." >&2; exit 1 ;;
esac
[[ "$LOOKBACK_DAYS" =~ ^[0-9]+$ ]] || { echo "ERROR: --lookback-days must be a positive integer." >&2; exit 1; }
[[ "$LOOKBACK_DAYS" -gt 0 ]] || { echo "ERROR: --lookback-days must be greater than 0." >&2; exit 1; }

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
echo "Subs file:    ${SUBS_FILE:-<not provided - Databricks-only mode>}"
echo "Read-only:    yes"
echo "Pool analysis: ${INCLUDE_POOLS,,}"
echo "Job analysis:  ${INCLUDE_JOBS,,}"
echo "Lookback days: $LOOKBACK_DAYS"
echo "============================================================"

# Confirm Azure login only when Azure discovery/cost mode is used.
if [[ -n "$SUBS_FILE" ]]; then
  az account show >/dev/null 2>&1 || { echo "ERROR: Azure CLI is not logged in. Run az login first." >&2; exit 1; }
fi

WORKSPACES_CSV="$OUTPUT_DIR/01_databricks_workspaces.csv"
AZURE_COST_CSV="$OUTPUT_DIR/02_azure_cost_by_resource.csv"
CLUSTERS_CSV="$OUTPUT_DIR/03_clusters.csv"
CLUSTER_FINDINGS_CSV="$OUTPUT_DIR/04_cluster_findings.csv"
JOBS_CSV="$OUTPUT_DIR/databricks_jobs_raw.csv"
JOB_RUNS_CSV="$OUTPUT_DIR/databricks_job_runs_raw.csv"
JOB_TASK_RUNS_CSV="$OUTPUT_DIR/databricks_job_task_runs_raw.csv"
JOB_FINDINGS_CSV="$OUTPUT_DIR/databricks_job_findings.csv"
JOB_SUMMARY_CSV="$OUTPUT_DIR/databricks_job_summary.csv"
WAREHOUSES_CSV="$OUTPUT_DIR/06_sql_warehouses.csv"
DBU_CSV="$OUTPUT_DIR/07_dbu_usage.csv"
RECS_CSV="$OUTPUT_DIR/08_recommendations.csv"
POOLS_RAW_CSV="$OUTPUT_DIR/databricks_instance_pools_raw.csv"
POOLS_FINDINGS_CSV="$OUTPUT_DIR/databricks_instance_pool_findings.csv"
POOLS_SUMMARY_CSV="$OUTPUT_DIR/databricks_instance_pool_summary.csv"
SUMMARY_TXT="$OUTPUT_DIR/Summary.txt"

printf 'SubscriptionId,ResourceGroup,WorkspaceName,WorkspaceUrl,Location,Sku,ManagedResourceGroupId,ResourceId\n' > "$WORKSPACES_CSV"
printf 'SubscriptionId,ResourceId,ResourceType,ResourceGroup,ServiceName,Cost,Currency\n' > "$AZURE_COST_CSV"
printf 'WorkspaceUrl,ClusterId,ClusterName,State,Creator,ClusterSource,SparkVersion,NodeType,DriverNodeType,NumWorkers,AutoscaleMin,AutoscaleMax,AutoTerminationMinutes,CustomTagsJson\n' > "$CLUSTERS_CSV"
printf 'WorkspaceUrl,Severity,FindingType,ObjectType,ObjectId,ObjectName,Recommendation\n' > "$CLUSTER_FINDINGS_CSV"
printf 'WorkspaceUrl,JobId,JobName,CreatorUserName,CreatedTime,ScheduleType,IsScheduled,IsContinuous,TaskCount,UsesExistingCluster,UsesJobCluster,UsesNewCluster,ExistingClusterIds,JobClusterKeys,NewClusterNodeTypes,TagsJson,RequiredTagsMissing,RawJsonFile\n' > "$JOBS_CSV"
printf 'WorkspaceUrl,JobId,JobName,RunId,RunName,RunType,TriggerType,StartTime,EndTime,DurationMinutes,LifeCycleState,ResultState,StateMessage,AttemptNumber,ClusterInstanceClusterId,ExistingClusterId,RunPageUrl\n' > "$JOB_RUNS_CSV"
printf 'WorkspaceUrl,JobId,JobName,RunId,TaskKey,TaskRunId,StartTime,EndTime,DurationMinutes,LifeCycleState,ResultState,AttemptNumber,ClusterId,ExistingClusterId,JobClusterKey\n' > "$JOB_TASK_RUNS_CSV"
printf 'WorkspaceUrl,JobId,JobName,FindingType,Severity,Evidence,Recommendation,EstimatedCostImpactNote\n' > "$JOB_FINDINGS_CSV"
printf 'WorkspaceUrl,TotalJobs,TotalRunsInLookback,JobsWithFailures,JobsWithHighFailureRate,LongRunningJobs,VeryLongRunningJobs,HighFrequencyJobs,JobsUsingAllPurposeClusters,JobsMissingTags,ScheduledJobsWithNoRecentSuccess,LookbackDays\n' > "$JOB_SUMMARY_CSV"
printf 'WorkspaceUrl,WarehouseId,Name,State,ClusterSize,MinClusters,MaxClusters,AutoStopMinutes,WarehouseType,SpotInstancePolicy,Creator\n' > "$WAREHOUSES_CSV"
printf 'WorkspaceUrl,UsageDate,SkuName,UsageUnit,DBUs,WorkspaceId,BillingOriginProduct\n' > "$DBU_CSV"
printf 'Priority,WorkspaceUrl,Area,ObjectType,ObjectName,Finding,Recommendation\n' > "$RECS_CSV"
printf 'WorkspaceUrl,PoolId,PoolName,NodeType,MinIdleInstances,MaxCapacity,IdleAutoTerminationMinutes,EnableElasticDisk,PreloadedSparkVersions,CustomTagsJson,UsedByClustersCount,AttachedClusterIds,AttachedClusterNames,RunningAttachedClustersCount,TerminatedAttachedClustersCount\n' > "$POOLS_RAW_CSV"
printf 'WorkspaceUrl,PoolId,PoolName,FindingType,Severity,Evidence,Recommendation,EstimatedMonthlyWasteNote\n' > "$POOLS_FINDINGS_CSV"
printf 'WorkspaceUrl,TotalPools,UnusedPools,PoolsWithMinIdleInstances,PoolsMissingAutoTermination,UntaggedPools,PotentiallyOversizedPools,TotalMinIdleInstances\n' > "$POOLS_SUMMARY_CSV"

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
    (.properties.columns | map(.name)) as $cols
    | def idx($n): ($cols | index($n));
    | .properties.rows[]? as $r
    | [
        $sub,
        ($r[idx("ResourceId")] // ""),
        ($r[idx("ResourceType")] // ""),
        ($r[idx("ResourceGroupName")] // ""),
        ($r[idx("ServiceName")] // ""),
        ($r[idx("Cost")] // 0),
        ($r[idx("Currency")] // "")
      ] | @csv
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

  jq -r --arg ws "$ws_url" '
    def tag_missing($k): ((.custom_tags // {})[$k] // "") == "";
    .clusters[]? as $c
    | [
        (if (($c.cluster_source // "") != "JOB" and (($c.autotermination_minutes // 0) == 0)) then ["High",$ws,"Clusters","Cluster",($c.cluster_name//""),"NoAutoTermination","Set auto-termination to 15-30 minutes for all-purpose clusters"] else empty end),
        (if (($c.cluster_source // "") != "JOB" and (($c.autotermination_minutes // 0) > 60)) then ["Medium",$ws,"Clusters","Cluster",($c.cluster_name//""),"HighAutoTermination","Reduce auto-termination to 15-30 minutes unless justified"] else empty end),
        (if (($c.autoscale // null) == null and (($c.num_workers // 0) >= 4)) then ["Medium",$ws,"Clusters","Cluster",($c.cluster_name//""),"FixedWorkers","Use autoscaling or validate fixed worker count"] else empty end),
        (if ((($c.autoscale.max_workers // 0) >= 20) or (($c.num_workers // 0) >= 20)) then ["High",$ws,"Clusters","Cluster",($c.cluster_name//""),"LargeCluster","Review large worker count and validate workload requirement"] else empty end),
        (if ((($c.node_type_id // "") | test("(?i)(standard_nc|standard_nd|standard_nv|gpu)"))) then ["High",$ws,"Clusters","Cluster",($c.cluster_name//""),"GpuNodeType","Restrict GPU SKUs unless required for ML/GPU workloads"] else empty end),
        (if (tag_missing("Owner") or tag_missing("CostCenter") or tag_missing("Environment") or tag_missing("Application")) then ["Medium",$ws,"Clusters","Cluster",($c.cluster_name//""),"MissingTags","Enforce Owner, CostCenter, Environment and Application tags through cluster policy"] else empty end)
      ][] | @csv
  ' "$tmp" >> "$RECS_CSV" || true
}

collect_jobs() {
  local ws_url="$1"
  local token="$2"
  if [[ "${INCLUDE_JOBS,,}" != "true" ]]; then
    echo "[Databricks] Job / workflow run efficiency analysis skipped for $ws_url (--include-jobs=false)"
    return 0
  fi

  echo "[Databricks] Collecting job/workflow efficiency data: $ws_url"
  local base now_ms lookback_start_ms
  base="$(echo "$ws_url" | sed 's#https\?://##; s#[/:]#_#g')"
  now_ms="$(($(date -u +%s) * 1000))"
  lookback_start_ms="$((now_ms - LOOKBACK_DAYS * 24 * 60 * 60 * 1000))"

  local jobs_pages="$OUTPUT_DIR/raw/jobs_pages_${base}.jsonl"
  local jobs_all="$OUTPUT_DIR/raw/databricks_jobs_raw_${base}.json"
  local job_details_jsonl="$OUTPUT_DIR/raw/databricks_job_details_${base}.jsonl"
  local job_details_json="$OUTPUT_DIR/databricks_jobs_details_raw_${base}.json"
  local runs_pages="$OUTPUT_DIR/raw/job_runs_pages_${base}.jsonl"
  local runs_all="$OUTPUT_DIR/raw/databricks_job_runs_raw_${base}.json"
  local run_details_jsonl="$OUTPUT_DIR/raw/databricks_job_run_details_raw_${base}.jsonl"
  local job_stats_json="$OUTPUT_DIR/raw/databricks_job_stats_${base}.json"
  : > "$jobs_pages"
  : > "$job_details_jsonl"
  : > "$runs_pages"
  : > "$run_details_jsonl"

  local page_token="" offset=0 page_tmp rc has_more next_token endpoint
  while :; do
    page_tmp="$OUTPUT_DIR/raw/jobs_list_${base}_${offset}.json"
    endpoint="/api/2.1/jobs/list?limit=100&expand_tasks=true"
    if [[ -n "$page_token" ]]; then endpoint="$endpoint&page_token=$page_token"; else endpoint="$endpoint&offset=$offset"; fi
    set +e
    db_api_get "$ws_url" "$endpoint" "$token" > "$page_tmp" 2>"$page_tmp.err"
    rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then echo "  WARN: Jobs list API failed for $ws_url. See $page_tmp.err"; break; fi
    cat "$page_tmp" >> "$jobs_pages"; printf '\n' >> "$jobs_pages"
    has_more="$(jq -r '.has_more // false' "$page_tmp")"
    next_token="$(jq -r '.next_page_token // empty' "$page_tmp")"
    if [[ -n "$next_token" ]]; then page_token="$next_token"; elif [[ "$has_more" == "true" ]]; then offset=$((offset + 100)); page_token=""; else break; fi
  done

  jq -s '{jobs: (map(.jobs // []) | add // [])}' "$jobs_pages" > "$jobs_all" 2>/dev/null || echo '{"jobs":[]}' > "$jobs_all"
  cp "$jobs_all" "$OUTPUT_DIR/databricks_jobs_raw_${base}.json"

  local job_id job_tmp
  while IFS= read -r job_id; do
    [[ -z "$job_id" ]] && continue
    job_tmp="$OUTPUT_DIR/raw/job_get_${base}_${job_id}.json"
    set +e
    db_api_get "$ws_url" "/api/2.1/jobs/get?job_id=$job_id" "$token" > "$job_tmp" 2>"$job_tmp.err"
    rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
      echo "  WARN: jobs/get failed for job_id=$job_id in $ws_url. Using list payload only. See $job_tmp.err"
      jq -c --arg id "$job_id" '.jobs[]? | select((.job_id|tostring)==$id)' "$jobs_all" >> "$job_details_jsonl" || true
    else
      jq -c '.' "$job_tmp" >> "$job_details_jsonl"
    fi
  done < <(jq -r '.jobs[]?.job_id // empty' "$jobs_all" | sort -u)
  jq -s '.' "$job_details_jsonl" > "$job_details_json" 2>/dev/null || echo '[]' > "$job_details_json"

  jq -r --arg ws "$ws_url" --arg base "$base" '
    def arrstr: map(tostring) | join(";");
    def tag_missing($tags):
      (["Owner","Application","Environment"] | map(select((($tags[.] // "") == "")))
       + (if ((($tags["CostCentre"] // $tags["CostCenter"] // "") == "")) then ["CostCentre"] else [] end));
    . as $j
    | ($j.settings // {}) as $s
    | ($s.tasks // []) as $tasks
    | ($s.job_clusters // []) as $jcs
    | ($s.tags // {}) as $tags
    | ($tasks | map(.existing_cluster_id // empty) | unique) as $existing_ids
    | ($tasks | map(.job_cluster_key // empty) | unique) as $job_keys
    | ($tasks | map(.new_cluster.node_type_id // empty) + ($jcs | map(.new_cluster.node_type_id // empty)) | unique) as $new_nodes
    | tag_missing($tags) as $missing
    | [ $ws, ($j.job_id // ""), ($s.name // ""), ($j.creator_user_name // $s.creator_user_name // ""), ($j.created_time // ""),
        (if ($s.continuous // null) != null then "continuous" elif ($s.trigger // null) != null then "trigger" elif ($s.schedule // null) != null then "scheduled" else "manual" end),
        (($s.schedule // null) != null or ($s.trigger // null) != null), (($s.continuous // null) != null), ($tasks | length),
        (($existing_ids | length) > 0), (($jcs | length) > 0 or (($job_keys | length) > 0)), (($tasks | map(select(.new_cluster != null)) | length) > 0),
        ($existing_ids | arrstr), ($job_keys | arrstr), ($new_nodes | arrstr), ($tags | tostring), ($missing | join(";")), ("databricks_jobs_details_raw_" + $base + ".json") ] | @csv
  ' "$job_details_jsonl" >> "$JOBS_CSV" || true

  page_token=""; offset=0
  while :; do
    page_tmp="$OUTPUT_DIR/raw/job_runs_list_${base}_${offset}.json"
    endpoint="/api/2.1/jobs/runs/list?limit=100&start_time_from=$lookback_start_ms&expand_tasks=true"
    if [[ -n "$page_token" ]]; then endpoint="$endpoint&page_token=$page_token"; else endpoint="$endpoint&offset=$offset"; fi
    set +e
    db_api_get "$ws_url" "$endpoint" "$token" > "$page_tmp" 2>"$page_tmp.err"
    rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then echo "  WARN: Jobs runs list API failed for $ws_url. See $page_tmp.err"; break; fi
    cat "$page_tmp" >> "$runs_pages"; printf '\n' >> "$runs_pages"
    has_more="$(jq -r '.has_more // false' "$page_tmp")"
    next_token="$(jq -r '.next_page_token // empty' "$page_tmp")"
    if [[ -n "$next_token" ]]; then page_token="$next_token"; elif [[ "$has_more" == "true" ]]; then offset=$((offset + 100)); page_token=""; else break; fi
  done

  jq -s '{runs: (map(.runs // []) | add // [])}' "$runs_pages" > "$runs_all" 2>/dev/null || echo '{"runs":[]}' > "$runs_all"
  cp "$runs_all" "$OUTPUT_DIR/databricks_job_runs_raw_${base}.json"

  local run_id run_tmp run_count=0
  while IFS= read -r run_id; do
    [[ -z "$run_id" ]] && continue
    run_tmp="$OUTPUT_DIR/raw/job_run_get_${base}_${run_id}.json"
    set +e
    db_api_get "$ws_url" "/api/2.1/jobs/runs/get?run_id=$run_id" "$token" > "$run_tmp" 2>"$run_tmp.err"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then jq -c '.' "$run_tmp" >> "$run_details_jsonl" || true; fi
    run_count=$((run_count + 1))
    if [[ $run_count -ge 1000 ]]; then echo "  WARN: Reached 1000 run detail calls for $ws_url; continuing with runs/list data for remaining runs."; break; fi
  done < <(jq -r '.runs[]?.run_id // empty' "$runs_all" | sort -u)
  jq -s '.' "$run_details_jsonl" > "$OUTPUT_DIR/databricks_job_run_details_raw_${base}.json" 2>/dev/null || echo '[]' > "$OUTPUT_DIR/databricks_job_run_details_raw_${base}.json"

  jq -r --arg ws "$ws_url" '
    .runs[]? as $r | [ $ws, ($r.job_id // ""), ($r.job_name // ""), ($r.run_id // ""), ($r.run_name // ""), ($r.run_type // ""), ($r.trigger // ""),
      ($r.start_time // ""), ($r.end_time // ""), (if (($r.start_time // 0) > 0 and ($r.end_time // 0) > 0) then (((($r.end_time - $r.start_time) / 60000) * 100 | round) / 100) else "" end),
      ($r.state.life_cycle_state // ""), ($r.state.result_state // ""), ($r.state.state_message // ""), ($r.attempt_number // 0), ($r.cluster_instance.cluster_id // ""), ($r.cluster_spec.existing_cluster_id // ""), ($r.run_page_url // "") ] | @csv
  ' "$runs_all" >> "$JOB_RUNS_CSV" || true

  if [[ -s "$run_details_jsonl" ]]; then
    jq -r --arg ws "$ws_url" '
      . as $r | ($r.tasks // [])[]? as $t | [ $ws, ($r.job_id // ""), ($r.job_name // ""), ($r.run_id // ""), ($t.task_key // ""), ($t.run_id // ""), ($t.start_time // ""), ($t.end_time // ""),
        (if (($t.start_time // 0) > 0 and ($t.end_time // 0) > 0) then (((($t.end_time - $t.start_time) / 60000) * 100 | round) / 100) else "" end),
        ($t.state.life_cycle_state // ""), ($t.state.result_state // ""), ($t.attempt_number // 0), ($t.cluster_instance.cluster_id // ""), ($t.existing_cluster_id // $t.cluster_spec.existing_cluster_id // ""), ($t.job_cluster_key // "") ] | @csv
    ' "$run_details_jsonl" >> "$JOB_TASK_RUNS_CSV" || true
  else
    jq -r --arg ws "$ws_url" '
      .runs[]? as $r | ($r.tasks // [])[]? as $t | [ $ws, ($r.job_id // ""), ($r.job_name // ""), ($r.run_id // ""), ($t.task_key // ""), ($t.run_id // ""), ($t.start_time // ""), ($t.end_time // ""),
        (if (($t.start_time // 0) > 0 and ($t.end_time // 0) > 0) then (((($t.end_time - $t.start_time) / 60000) * 100 | round) / 100) else "" end),
        ($t.state.life_cycle_state // ""), ($t.state.result_state // ""), ($t.attempt_number // 0), ($t.cluster_instance.cluster_id // ""), ($t.existing_cluster_id // $t.cluster_spec.existing_cluster_id // ""), ($t.job_cluster_key // "") ] | @csv
    ' "$runs_all" >> "$JOB_TASK_RUNS_CSV" || true
  fi

  jq -s --arg ws "$ws_url" --argjson lookback "$LOOKBACK_DAYS" '
    def large_node($s): ($s | test("(?i)(8xlarge|16xlarge|32xlarge|E64|E80|Standard_E64|Standard_E80|Standard_L|Standard_M|Standard_F(32|48|64|72)|L[0-9]+|M[0-9]+)"));
    def tag_missing($tags): (["Owner","Application","Environment"] | map(select((($tags[.] // "") == ""))) + (if ((($tags["CostCentre"] // $tags["CostCenter"] // "") == "")) then ["CostCentre"] else [] end));
    .[0].runs as $runs | .[1] as $jobs | [ $jobs[]? as $j | ($j.settings // {}) as $s | ($s.tasks // []) as $tasks | ($s.job_clusters // []) as $jcs | ($s.tags // {}) as $tags
      | ($runs | map(select((.job_id|tostring) == ($j.job_id|tostring)))) as $jruns
      | ($jruns | map(select((.state.result_state // "") == "SUCCESS"))) as $success_runs
      | ($jruns | map(select((.state.result_state // "") == "FAILED" or (.state.result_state // "") == "TIMEDOUT" or (.state.life_cycle_state // "") == "INTERNAL_ERROR"))) as $failed_runs
      | ($jruns | map(select((.state.result_state // "") == "CANCELED"))) as $cancelled_runs
      | ($jruns | map(select((.state.life_cycle_state // "") == "RUNNING" or (.state.life_cycle_state // "") == "PENDING"))) as $running_runs
      | ($jruns | map(select((.start_time // 0) > 0 and (.end_time // 0) > 0) | ((.end_time - .start_time) / 60000))) as $durations
      | ($jruns | map(.attempt_number // 0)) as $attempts
      | ($tasks | map(.existing_cluster_id // empty) | unique) as $existing_ids
      | ($tasks | map(.job_cluster_key // empty) | unique) as $job_keys
      | ($tasks | map(.new_cluster.node_type_id // empty) + ($jcs | map(.new_cluster.node_type_id // empty)) | unique) as $new_nodes
      | ($durations | length) as $duration_count | ($jruns | length) as $total | ($failed_runs | length) as $failed | ($success_runs | length) as $success
      | (if $duration_count > 0 then (($durations | add) / $duration_count) else 0 end) as $avg_duration
      | (if $duration_count > 0 then ($durations | max) else 0 end) as $max_duration
      | (if $duration_count > 0 then ($durations | min) else 0 end) as $min_duration
      | (if $total > 0 then (($failed / $total) * 100) else 0 end) as $failure_rate
      | (if ($attempts|length) > 0 then (($attempts | add) / ($attempts|length)) else 0 end) as $avg_attempts
      | ($total / $lookback) as $runs_per_day | tag_missing($tags) as $missing_tags
      | {workspace_url:$ws, job_id:($j.job_id // ""), job_name:($s.name // ""), total_runs:$total, successful_runs:$success, failed_runs:$failed, cancelled_runs:($cancelled_runs|length), running_runs:($running_runs|length), average_duration_minutes:$avg_duration, max_duration_minutes:$max_duration, min_duration_minutes:$min_duration, failure_rate_percent:$failure_rate, runs_per_day:$runs_per_day, average_attempts:$avg_attempts, last_run_time:(($jruns | map(.start_time // 0) | max) // 0), last_success_time:(($success_runs | map(.start_time // 0) | max) // 0), uses_existing_cluster:(($existing_ids | length) > 0), uses_job_cluster:(($job_keys | length) > 0 or ($jcs | length) > 0), uses_new_cluster_per_task:(($tasks | map(select(.new_cluster != null)) | length) > 0), missing_tags:$missing_tags, schedule_type:(if ($s.continuous // null) != null then "continuous" elif ($s.trigger // null) != null then "trigger" elif ($s.schedule // null) != null then "scheduled" else "manual" end), is_scheduled:(($s.schedule // null) != null or ($s.continuous // null) != null or ($s.trigger // null) != null), has_large_node_for_short_job:((($new_nodes | map(select(large_node(.))) | length) > 0) and ($avg_duration > 0 and $avg_duration < 10)), new_cluster_node_types:($new_nodes | join(";")) } ]
  ' "$runs_all" "$job_details_json" > "$job_stats_json" 2>/dev/null || echo '[]' > "$job_stats_json"

  jq -r '
    def round2: (. * 100 | round) / 100;
    .[]? as $j | [
      (if ($j.average_duration_minutes > 60) then [$j.workspace_url,($j.job_id|tostring),$j.job_name,"LongRunningJob","Medium","average_duration_minutes=" + (($j.average_duration_minutes|round2)|tostring),"Review job logic, cluster sizing, autoscaling and data processing design. Consider Photon, partitioning, Delta optimisation or workload tuning.","Potential cost impact: long-running job average duration is " + (($j.average_duration_minutes|round2)|tostring) + " minutes."] else empty end),
      (if ($j.average_duration_minutes > 180) then [$j.workspace_url,($j.job_id|tostring),$j.job_name,"VeryLongRunningJob","High","average_duration_minutes=" + (($j.average_duration_minutes|round2)|tostring),"Prioritise for performance and cost review. Long-running jobs are likely material compute cost drivers.","Potential cost impact: very long-running job average duration is " + (($j.average_duration_minutes|round2)|tostring) + " minutes."] else empty end),
      (if ($j.runs_per_day > 24) then [$j.workspace_url,($j.job_id|tostring),$j.job_name,"HighFrequencyJob","Medium","runs_per_day=" + (($j.runs_per_day|round2)|tostring),"Validate whether the frequency is required. Consider event-driven execution, batching, schedule reduction, or trigger consolidation.","Potential cost impact: job runs frequently with " + (($j.runs_per_day|round2)|tostring) + " runs/day and average duration " + (($j.average_duration_minutes|round2)|tostring) + " minutes."] else empty end),
      (if ($j.runs_per_day > 96) then [$j.workspace_url,($j.job_id|tostring),$j.job_name,"VeryHighFrequencyJob","High","runs_per_day=" + (($j.runs_per_day|round2)|tostring),"Review immediately. Jobs running every 15 minutes or more frequently can become major cost drivers.","Potential cost impact: very high run frequency with " + (($j.runs_per_day|round2)|tostring) + " runs/day."] else empty end),
      (if ($j.total_runs >= 5 and $j.failure_rate_percent > 20) then [$j.workspace_url,($j.job_id|tostring),$j.job_name,"HighFailureRateJob","High","failure_rate_percent=" + (($j.failure_rate_percent|round2)|tostring) + "; failed_runs=" + (($j.failed_runs//0)|tostring) + "; total_runs=" + (($j.total_runs//0)|tostring),"Investigate failures and retries. Failed runs still consume compute and should be fixed before right-sizing.","Potential waste: failed runs consumed compute. Failed runs in lookback: " + (($j.failed_runs//0)|tostring) + "."] else empty end),
      (if ($j.average_attempts > 1.2) then [$j.workspace_url,($j.job_id|tostring),$j.job_name,"RepeatedRetries","Medium","average_attempts=" + (($j.average_attempts|round2)|tostring),"Review retry policy, dependency failures, data quality issues and cluster startup reliability.","Potential waste: retries increase compute consumed per successful output."] else empty end),
      (if ($j.uses_existing_cluster == true) then [$j.workspace_url,($j.job_id|tostring),$j.job_name,"UsesAllPurposeCluster","High","One or more tasks use existing_cluster_id.","Review whether this job should run on a job cluster instead of an existing all-purpose cluster. Job clusters provide better lifecycle control and cost attribution.","Potential waste: job uses existing all-purpose cluster, which may remain running beyond job execution."] else empty end),
      (if (($j.uses_job_cluster == false) and ($j.uses_new_cluster_per_task == false)) then [$j.workspace_url,($j.job_id|tostring),$j.job_name,"NoJobClusterDefined","Medium","No job_clusters or task new_cluster found; likely relies on existing cluster or default config.","Define job clusters or task clusters for better isolation, auto-termination and cost control.","Potential waste: less lifecycle control and weaker job-level cost attribution."] else empty end),
      (if (($j.missing_tags|length) > 0) then [$j.workspace_url,($j.job_id|tostring),$j.job_name,"MissingJobTags","Medium","Missing required tags: " + ($j.missing_tags|join(";")),"Add required tags for cost attribution and chargeback/showback.","No direct waste estimate. Missing tags reduce ownership and cost accountability."] else empty end),
      (if (($j.is_scheduled == true) and (($j.successful_runs//0) == 0)) then [$j.workspace_url,($j.job_id|tostring),$j.job_name,"ScheduledButNoRecentSuccess","Medium","Scheduled/triggered job has no successful runs in lookback period.","Confirm whether the job is still required. Disable or delete unused scheduled workflows.","Potential waste: scheduled workflow may be failing, obsolete, or running without useful output."] else empty end),
      (if ($j.has_large_node_for_short_job == true) then [$j.workspace_url,($j.job_id|tostring),$j.job_name,"LargeClusterForShortJob","Medium","node_type_id contains large SKU and average_duration_minutes=" + (($j.average_duration_minutes|round2)|tostring),"Review whether a smaller job cluster or serverless option would be more cost-effective.","Potential cost impact: large node family used for short job duration."] else empty end),
      (if (($j.failed_runs//0) > 0 and ($j.max_duration_minutes > 60)) then [$j.workspace_url,($j.job_id|tostring),$j.job_name,"LongRunningFailedJob","High","failed_runs=" + (($j.failed_runs//0)|tostring) + "; max_duration_minutes=" + (($j.max_duration_minutes|round2)|tostring),"Failed long-running jobs are high-priority waste. Investigate root cause and stop repeated costly failures.","Potential waste: long failed runs consumed compute without producing successful output."] else empty end)
    ][] | @csv
  ' "$job_stats_json" >> "$JOB_FINDINGS_CSV" || true

  jq -r '
    .[]? as $j | [
      (if ($j.average_duration_minutes > 60) then ["Medium",$j.workspace_url,"Jobs","Job",$j.job_name,"LongRunningJob","Review job logic, cluster sizing, autoscaling and data processing design."] else empty end),
      (if ($j.average_duration_minutes > 180) then ["High",$j.workspace_url,"Jobs","Job",$j.job_name,"VeryLongRunningJob","Prioritise for performance and cost review."] else empty end),
      (if ($j.runs_per_day > 24) then ["Medium",$j.workspace_url,"Jobs","Job",$j.job_name,"HighFrequencyJob","Validate whether the frequency is required."] else empty end),
      (if ($j.runs_per_day > 96) then ["High",$j.workspace_url,"Jobs","Job",$j.job_name,"VeryHighFrequencyJob","Review immediately; very frequent jobs can become major cost drivers."] else empty end),
      (if ($j.total_runs >= 5 and $j.failure_rate_percent > 20) then ["High",$j.workspace_url,"Jobs","Job",$j.job_name,"HighFailureRateJob","Investigate failures and retries."] else empty end),
      (if ($j.average_attempts > 1.2) then ["Medium",$j.workspace_url,"Jobs","Job",$j.job_name,"RepeatedRetries","Review retry policy and dependency failures."] else empty end),
      (if ($j.uses_existing_cluster == true) then ["High",$j.workspace_url,"Jobs","Job",$j.job_name,"UsesAllPurposeCluster","Move to job cluster where suitable."] else empty end),
      (if (($j.uses_job_cluster == false) and ($j.uses_new_cluster_per_task == false)) then ["Medium",$j.workspace_url,"Jobs","Job",$j.job_name,"NoJobClusterDefined","Define job clusters or task clusters."] else empty end),
      (if (($j.missing_tags|length) > 0) then ["Medium",$j.workspace_url,"Jobs","Job",$j.job_name,"MissingJobTags","Add required tags for cost attribution."] else empty end),
      (if (($j.is_scheduled == true) and (($j.successful_runs//0) == 0)) then ["Medium",$j.workspace_url,"Jobs","Job",$j.job_name,"ScheduledButNoRecentSuccess","Confirm whether the job is still required."] else empty end),
      (if ($j.has_large_node_for_short_job == true) then ["Medium",$j.workspace_url,"Jobs","Job",$j.job_name,"LargeClusterForShortJob","Review whether a smaller job cluster or serverless option would be more cost-effective."] else empty end),
      (if (($j.failed_runs//0) > 0 and ($j.max_duration_minutes > 60)) then ["High",$j.workspace_url,"Jobs","Job",$j.job_name,"LongRunningFailedJob","Investigate root cause and stop repeated costly failures."] else empty end)
    ][] | @csv
  ' "$job_stats_json" >> "$RECS_CSV" || true

  jq -r --arg ws "$ws_url" --argjson lookback "$LOOKBACK_DAYS" '[ $ws, (length), (map(.total_runs // 0) | add // 0), (map(select((.failed_runs // 0) > 0)) | length), (map(select((.total_runs // 0) >= 5 and (.failure_rate_percent // 0) > 20)) | length), (map(select((.average_duration_minutes // 0) > 60)) | length), (map(select((.average_duration_minutes // 0) > 180)) | length), (map(select((.runs_per_day // 0) > 24)) | length), (map(select(.uses_existing_cluster == true)) | length), (map(select((.missing_tags | length) > 0)) | length), (map(select((.is_scheduled == true) and ((.successful_runs // 0) == 0))) | length), $lookback ] | @csv' "$job_stats_json" >> "$JOB_SUMMARY_CSV" || true
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

collect_instance_pools() {
  local ws_url="$1"
  local token="$2"
  [[ "${INCLUDE_POOLS,,}" != "true" ]] && return 0
  echo "[Databricks] Collecting instance pools: $ws_url"
  local base pools_tmp clusters_tmp enriched_tmp findings_tmp summary_tmp
  base="$(echo "$ws_url" | sed 's#https\?://##; s#[/:]#_#g')"
  pools_tmp="$OUTPUT_DIR/raw/instance_pools_${base}.json"
  clusters_tmp="$OUTPUT_DIR/raw/instance_pool_clusters_${base}.json"
  enriched_tmp="$OUTPUT_DIR/raw/instance_pools_enriched_${base}.json"
  findings_tmp="$OUTPUT_DIR/raw/instance_pool_findings_${base}.csv"
  summary_tmp="$OUTPUT_DIR/raw/instance_pool_summary_${base}.csv"

  set +e
  db_api_get "$ws_url" "/api/2.0/instance-pools/list" "$token" > "$pools_tmp" 2>"$pools_tmp.err"
  local rc_pools=$?
  db_api_get "$ws_url" "/api/2.0/clusters/list" "$token" > "$clusters_tmp" 2>"$clusters_tmp.err"
  local rc_clusters=$?
  set -e

  if [[ $rc_pools -ne 0 ]]; then
    echo "  WARN: Instance Pools API failed for $ws_url. See $pools_tmp.err"
    return 0
  fi
  if [[ $rc_clusters -ne 0 ]]; then
    echo "  WARN: Cluster API for pool correlation failed for $ws_url. See $clusters_tmp.err"
    printf '{"clusters":[]}' > "$clusters_tmp"
  fi

  jq --arg ws "$ws_url" -n --slurpfile pools "$pools_tmp" --slurpfile clusters "$clusters_tmp" '
    def arr(x): if x == null then [] elif (x|type) == "array" then x else [x] end;
    def tag_json: (.custom_tags // .custom_tags_map // {});
    def has_required_tags:
      (tag_json) as $t
      | (($t.Owner // $t.owner // "") != "")
        and (($t.CostCentre // $t.CostCenter // $t.costCentre // $t.cost_center // "") != "")
        and (($t.Application // $t.application // $t.App // "") != "")
        and (($t.Environment // $t.environment // $t.Env // "") != "");
    def expensive_node:
      ((.node_type_id // "") | test("(?i)(8xlarge|16xlarge|32xlarge|Standard_E64|Standard_E80|_E64|_E80|Standard_L|_L[0-9]|Standard_M|_M[0-9]|Standard_F48|Standard_F64|Standard_F72|_F48|_F64|_F72|Standard_NC|Standard_ND|Standard_NV|_NC|_ND|_NV|GPU)"));
    (($pools[0].instance_pools // []) | map(.)) as $poolList
    | (($clusters[0].clusters // []) | map(.)) as $clusterList
    | $poolList
    | map(
        . as $p
        | ($clusterList | map(select((.instance_pool_id // "") == ($p.instance_pool_id // "") or (.driver_instance_pool_id // "") == ($p.instance_pool_id // "")))) as $attached
        | . + {
            workspace_url: $ws,
            min_idle_instances_norm: ((.min_idle_instances // 0) | tonumber? // 0),
            max_capacity_norm: ((.max_capacity // 0) | tonumber? // 0),
            idle_autoterm_norm: (.idle_instance_autotermination_minutes // null),
            used_by_clusters_count: ($attached | length),
            attached_cluster_ids: ($attached | map(.cluster_id // "") | join(";")),
            attached_cluster_names: ($attached | map(.cluster_name // "") | join(";")),
            running_attached_clusters_count: ($attached | map(select((.state // "") | test("(?i)RUNNING|PENDING|RESIZING|RESTARTING"))) | length),
            terminated_attached_clusters_count: ($attached | map(select((.state // "") | test("(?i)TERMINATED|TERMINATING|ERROR|INTERNAL_ERROR"))) | length),
            custom_tags_json: ((tag_json) | tostring),
            preloaded_spark_versions_csv: ((arr(.preloaded_spark_versions)) | join(";")),
            has_required_tags: has_required_tags,
            expensive_node_type: expensive_node
          }
      )
  ' > "$enriched_tmp"

  jq -r --arg ws "$ws_url" '
    .[]? | [
      $ws,
      (.instance_pool_id // ""),
      (.instance_pool_name // ""),
      (.node_type_id // ""),
      (.min_idle_instances_norm // 0),
      (.max_capacity_norm // ""),
      (.idle_autoterm_norm // ""),
      (.enable_elastic_disk // ""),
      (.preloaded_spark_versions_csv // ""),
      (.custom_tags_json // "{}"),
      (.used_by_clusters_count // 0),
      (.attached_cluster_ids // ""),
      (.attached_cluster_names // ""),
      (.running_attached_clusters_count // 0),
      (.terminated_attached_clusters_count // 0)
    ] | @csv
  ' "$enriched_tmp" >> "$POOLS_RAW_CSV"

  jq -r --arg ws "$ws_url" '
    def waste_note($p):
      "Potential waste exists because this pool keeps " + (($p.min_idle_instances_norm // 0)|tostring) + " idle instances warm. Estimate savings by multiplying idle instances × node VM hourly cost × idle hours.";
    .[]? as $p
    | [
        (if (($p.used_by_clusters_count // 0) == 0) then [$ws,($p.instance_pool_id//""),($p.instance_pool_name//""),"UnusedPool",(if (($p.min_idle_instances_norm//0)>0) then "High" else "Low" end),"used_by_clusters_count=0; min_idle_instances=" + (($p.min_idle_instances_norm//0)|tostring),"Review and delete the pool if no longer required.",waste_note($p)] else empty end),
        (if (($p.min_idle_instances_norm // 0) > 0) then [$ws,($p.instance_pool_id//""),($p.instance_pool_name//""),"IdleCapacityRisk","Medium","min_idle_instances=" + (($p.min_idle_instances_norm//0)|tostring),"Reduce min_idle_instances to 0 or a lower value unless startup latency is business-critical.",waste_note($p)] else empty end),
        (if (($p.min_idle_instances_norm // 0) >= 2) then [$ws,($p.instance_pool_id//""),($p.instance_pool_name//""),"HighMinIdlePool","Medium","min_idle_instances=" + (($p.min_idle_instances_norm//0)|tostring),"Validate whether pre-warmed capacity is justified; otherwise reduce min idle capacity.",waste_note($p)] else empty end),
        (if (($p.idle_autoterm_norm // 0) == 0) then [$ws,($p.instance_pool_id//""),($p.instance_pool_name//""),"NoAutoTerminationForIdleInstances",(if (($p.min_idle_instances_norm//0)>0) then "High" else "Low" end),"idle_instance_autotermination_minutes is missing or 0; min_idle_instances=" + (($p.min_idle_instances_norm//0)|tostring),"Configure idle instance auto-termination.",waste_note($p)] else empty end),
        (if ($p.expensive_node_type == true) then [$ws,($p.instance_pool_id//""),($p.instance_pool_name//""),"ExpensiveNodeTypePool","Medium","node_type_id=" + ($p.node_type_id//""),"Validate whether the pool needs this node family; consider smaller/general-purpose nodes for non-critical workloads.","Pricing not calculated in API-only version. Estimate using Azure VM hourly cost for node type " + ($p.node_type_id//"") + "."] else empty end),
        (if ($p.has_required_tags == false) then [$ws,($p.instance_pool_id//""),($p.instance_pool_name//""),"UntaggedPool","Low","custom_tags missing one or more required keys: Owner, CostCentre/CostCenter, Application, Environment","Add required cost allocation tags to the pool or enforce through cluster policies.","No direct waste estimate. Missing tags reduce showback and cost accountability."] else empty end),
        (if ((($p.max_capacity_norm//0) >= 20) and (($p.running_attached_clusters_count//0) == 0)) then [$ws,($p.instance_pool_id//""),($p.instance_pool_name//""),"PotentiallyOversizedPool","Medium","max_capacity=" + (($p.max_capacity_norm//0)|tostring) + "; running_attached_clusters_count=" + (($p.running_attached_clusters_count//0)|tostring),"Review max capacity and reduce if not required.","Potential risk rather than exact waste. High max capacity can allow sudden scale-out spend."] else empty end)
      ][] | @csv
  ' "$enriched_tmp" > "$findings_tmp"
  cat "$findings_tmp" >> "$POOLS_FINDINGS_CSV"

  jq -r --arg ws "$ws_url" '
    [
      $ws,
      (length),
      (map(select((.used_by_clusters_count // 0) == 0)) | length),
      (map(select((.min_idle_instances_norm // 0) > 0)) | length),
      (map(select((.idle_autoterm_norm // 0) == 0)) | length),
      (map(select(.has_required_tags == false)) | length),
      (map(select(((.max_capacity_norm // 0) >= 20) and ((.running_attached_clusters_count // 0) == 0))) | length),
      (map(.min_idle_instances_norm // 0) | add // 0)
    ] | @csv
  ' "$enriched_tmp" > "$summary_tmp"
  cat "$summary_tmp" >> "$POOLS_SUMMARY_CSV"

  # Add pool findings to the consolidated recommendations file using jq so quoted CSV fields with commas remain valid.
  jq -r --arg ws "$ws_url" '
    .[]? as $p
    | [
        (if (($p.used_by_clusters_count // 0) == 0) then [(if (($p.min_idle_instances_norm//0)>0) then "High" else "Low" end),$ws,"Instance Pools","InstancePool",($p.instance_pool_name//""),"UnusedPool","Review and delete the pool if no longer required."] else empty end),
        (if (($p.min_idle_instances_norm // 0) > 0) then ["Medium",$ws,"Instance Pools","InstancePool",($p.instance_pool_name//""),"IdleCapacityRisk","Reduce min_idle_instances to 0 or a lower value unless startup latency is business-critical."] else empty end),
        (if (($p.min_idle_instances_norm // 0) >= 2) then ["Medium",$ws,"Instance Pools","InstancePool",($p.instance_pool_name//""),"HighMinIdlePool","Validate whether pre-warmed capacity is justified; otherwise reduce min idle capacity."] else empty end),
        (if (($p.idle_autoterm_norm // 0) == 0) then [(if (($p.min_idle_instances_norm//0)>0) then "High" else "Low" end),$ws,"Instance Pools","InstancePool",($p.instance_pool_name//""),"NoAutoTerminationForIdleInstances","Configure idle instance auto-termination."] else empty end),
        (if ($p.expensive_node_type == true) then ["Medium",$ws,"Instance Pools","InstancePool",($p.instance_pool_name//""),"ExpensiveNodeTypePool","Validate whether the pool needs this node family; consider smaller/general-purpose nodes for non-critical workloads."] else empty end),
        (if ($p.has_required_tags == false) then ["Low",$ws,"Instance Pools","InstancePool",($p.instance_pool_name//""),"UntaggedPool","Add required cost allocation tags to the pool or enforce through cluster policies."] else empty end),
        (if ((($p.max_capacity_norm//0) >= 20) and (($p.running_attached_clusters_count//0) == 0)) then ["Medium",$ws,"Instance Pools","InstancePool",($p.instance_pool_name//""),"PotentiallyOversizedPool","Review max capacity and reduce if not required."] else empty end)
      ][] | @csv
  ' "$enriched_tmp" >> "$RECS_CSV" || true
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

# Main collection loop. If --workspace-url is provided without --subs-file, run in Databricks-only mode.
if [[ -n "$SUBS_FILE" ]]; then
  while IFS= read -r sub || [[ -n "$sub" ]]; do
    sub="$(echo "$sub" | tr -d '\r' | xargs)"
    [[ -z "$sub" || "$sub" =~ ^# ]] && continue
    collect_workspaces_for_sub "$sub"
    collect_cost_for_sub "$sub"
  done < "$SUBS_FILE"
else
  ws_only="$(normalize_url "$WORKSPACE_URL_FILTER")"
  printf ',,,%s,,,,\n' "$(csv_escape "$ws_only")" >> "$WORKSPACES_CSV"
fi

# De-duplicate workspaces
awk 'NR==1 || !seen[$0]++' "$WORKSPACES_CSV" > "$WORKSPACES_CSV.tmp" && mv "$WORKSPACES_CSV.tmp" "$WORKSPACES_CSV"

if [[ "$SKIP_DATABRICKS_API" -eq 0 ]]; then
  tail -n +2 "$WORKSPACES_CSV" | while IFS=, read -r sub rg name url loc sku mrg id; do
    # Workspace URL is the 4th CSV field. Azure Databricks workspace URLs do not contain commas.
    line="$sub,$rg,$name,$url,$loc,$sku,$mrg,$id"
    ws_url="$(printf '%s\n' "$line" | awk -F, '{gsub(/"/,"",$4); print $4}')"
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
    collect_instance_pools "$ws_url" "$token_for_ws"
    collect_dbu_usage "$ws_url" "$token_for_ws"
  done
fi

# Summary
{
  echo "Databricks Cost Optimisation Collector Summary"
  echo "Generated UTC: $(date -u)"
  echo "Cost window:   $COST_START .. $COST_END"
  echo "Subs file:     ${SUBS_FILE:-<not provided - Databricks-only mode>}"
  echo "Output dir:    $OUTPUT_DIR"
  echo ""
  echo "Counts:"
  echo "- Workspaces:       $(($(wc -l < "$WORKSPACES_CSV") - 1))"
  echo "- Azure cost rows:  $(($(wc -l < "$AZURE_COST_CSV") - 1))"
  echo "- Clusters:         $(($(wc -l < "$CLUSTERS_CSV") - 1))"
  echo "- Cluster findings: $(($(wc -l < "$CLUSTER_FINDINGS_CSV") - 1))"
  echo "- Jobs rows:        $(($(wc -l < "$JOBS_CSV") - 1))"
  echo "- Job runs:         $(($(wc -l < "$JOB_RUNS_CSV") - 1))"
  echo "- Job task runs:    $(($(wc -l < "$JOB_TASK_RUNS_CSV") - 1))"
  echo "- Job findings:     $(($(wc -l < "$JOB_FINDINGS_CSV") - 1))"
  echo "- Warehouses:       $(($(wc -l < "$WAREHOUSES_CSV") - 1))"
  echo "- DBU rows:         $(($(wc -l < "$DBU_CSV") - 1))"
  echo "- Instance pools:   $(($(wc -l < "$POOLS_RAW_CSV") - 1))"
  echo "- Pool findings:    $(($(wc -l < "$POOLS_FINDINGS_CSV") - 1))"
  echo "- Recommendations:  $(($(wc -l < "$RECS_CSV") - 1))"
  echo ""
  echo "Job / Workflow Run Efficiency Analysis:"
  echo "- Job analysis enabled:                ${INCLUDE_JOBS,,}"
  echo "- Lookback days:                       $LOOKBACK_DAYS"
  echo "- Total jobs found:                    $(awk -F, 'NR>1 {s++} END{print s+0}' "$JOBS_CSV")"
  echo "- Total runs analysed:                 $(awk -F, 'NR>1 {s++} END{print s+0}' "$JOB_RUNS_CSV")"
  echo "- Long-running jobs:                   $(grep -c ',"LongRunningJob",' "$JOB_FINDINGS_CSV" 2>/dev/null || true)"
  echo "- High-frequency jobs:                 $(grep -c ',"HighFrequencyJob",' "$JOB_FINDINGS_CSV" 2>/dev/null || true)"
  echo "- Jobs with high failure rate:         $(grep -c ',"HighFailureRateJob",' "$JOB_FINDINGS_CSV" 2>/dev/null || true)"
  echo "- Jobs using all-purpose clusters:      $(grep -c ',"UsesAllPurposeCluster",' "$JOB_FINDINGS_CSV" 2>/dev/null || true)"
  echo "- Jobs missing tags:                   $(grep -c ',"MissingJobTags",' "$JOB_FINDINGS_CSV" 2>/dev/null || true)"
  echo ""
  echo "Instance Pool Optimisation Analysis:"
  echo "- Total pools found:                    $(awk -F, 'NR>1 {s++} END{print s+0}' "$POOLS_RAW_CSV")"
  echo "- Unused pools:                         $(grep -c ',"UnusedPool",' "$POOLS_FINDINGS_CSV" 2>/dev/null || true)"
  echo "- Pools with min idle instances:         $(awk -F, 'NR>1 {gsub(/"/,"",$5); if (($5+0)>0) s++} END{print s+0}' "$POOLS_RAW_CSV")"
  echo "- Pools missing idle auto-termination:   $(grep -c ',"NoAutoTerminationForIdleInstances",' "$POOLS_FINDINGS_CSV" 2>/dev/null || true)"
  echo "- Untagged pools:                       $(grep -c ',"UntaggedPool",' "$POOLS_FINDINGS_CSV" 2>/dev/null || true)"
  echo ""
  echo "Outputs:"
  echo "- $WORKSPACES_CSV"
  echo "- $AZURE_COST_CSV"
  echo "- $CLUSTERS_CSV"
  echo "- $CLUSTER_FINDINGS_CSV"
  echo "- $JOBS_CSV"
  echo "- $JOB_RUNS_CSV"
  echo "- $JOB_TASK_RUNS_CSV"
  echo "- $JOB_FINDINGS_CSV"
  echo "- $JOB_SUMMARY_CSV"
  echo "- $WAREHOUSES_CSV"
  echo "- $DBU_CSV"
  echo "- $RECS_CSV"
  echo "- $POOLS_RAW_CSV"
  echo "- $POOLS_FINDINGS_CSV"
  echo "- $POOLS_SUMMARY_CSV"
} > "$SUMMARY_TXT"

cat "$SUMMARY_TXT"
echo "Done."
