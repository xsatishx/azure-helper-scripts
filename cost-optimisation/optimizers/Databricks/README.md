# Azure Databricks Cost Optimisation Collector
**Author:** [Satish Balakrishnan](mailto:satishbal@microsoft.com)  
This package contains a read-only Bash script to collect Azure Databricks cost optimisation data across one or more Azure subscriptions or directly from a single Databricks workspace.

The script discovers Azure Databricks workspaces, collects Azure-side cost data, and optionally connects to Databricks workspaces to collect clusters, instance pools, jobs/workflow runs, SQL warehouses, DBU usage, findings, and recommendations.

The script is **read-only**. It does not change clusters, jobs, warehouses, pools, policies, or Azure resources.

## Files

| File | Purpose |
|---|---|
| `03_databricks_optimize_collector_v2.sh` | Main read-only Databricks cost optimisation collector script |
| `databricks_optimize_README.md` | Run guide and usage documentation |

## Version history

| Version | What changed |
|---|---|
| v1 | Initial Databricks cost optimisation collector. Covered Azure workspace discovery, Azure cost by resource, clusters, basic jobs inventory, SQL warehouses, optional DBU usage, cluster findings, and recommendations. |
| v2 | Added **Instance Pool Optimisation Analysis** using Databricks REST APIs only. Added `--include-pools true/false` and pool outputs for raw pools, pool findings, and pool summary. | Added **Job / Workflow Run Efficiency Analysis** using Databricks REST APIs only. Added `--include-jobs true/false`, `--lookback-days`, raw job configuration, recent run data, task run data, job findings, and job summary. |

## What the script does

| Area | What it checks |
|---|---|
| Azure Databricks workspaces | Workspace name, resource group, subscription, region, SKU, workspace URL |
| Azure cost | Cost by resource for the selected billing window |
| Clusters | Node type, worker count, autoscale settings, auto-termination, tags, runtime |
| Cluster findings | No auto-termination, high auto-termination, fixed-size clusters, missing tags, large clusters |
| Instance pools | Unused pools, idle capacity risk, high min idle capacity, missing idle auto-termination, expensive node types, missing tags, oversized max capacity |
| Jobs/workflows | Job settings, schedules, tasks, existing-cluster use, job-cluster use, new-cluster use, tags |
| Job/workflow runs | Recent runs within lookback window, duration, result state, failures, retries, run frequency, task runs |
| SQL warehouses | Warehouse size, state, auto-stop, warehouse type, scaling limits |
| DBU usage | Optional query against `system.billing.usage` when a SQL warehouse ID is provided |
| Recommendations | Prioritised optimisation actions based on discovered data |

## Prerequisites

Run this from Azure Cloud Shell or any machine with:

```bash
az --version
jq --version
curl --version
```

You must be logged in to Azure if using Azure discovery or Azure cost mode:

```bash
az login
az account show
```

Required Azure permissions:

| Permission | Why needed |
|---|---|
| Reader on subscriptions | Discover Databricks workspaces and resource inventory |
| Cost Management Reader or equivalent | Query Azure cost data |
| Access to Azure Resource Graph | Workspace inventory discovery |

Required Databricks permissions:

| Permission | Why needed |
|---|---|
| Databricks workspace token or AAD token | Query clusters, pools, jobs, runs, and SQL warehouses |
| Permission to read workspace objects | Collect cluster/job/warehouse/pool inventory |
| Permission to read job runs | Collect job/workflow run efficiency data |
| Optional access to SQL warehouse | Query `system.billing.usage` |

## Input files

### 1. `subs.txt`

Create a text file with one Azure subscription ID per line:

```text
e515e90a-9752-4b25-9580-dde58e6efa3b
a9b8193b-b2bc-493a-ab82-3c52eee35210
2894f99b-a12a-4705-bf46-29c434b871d2
```

Blank lines and lines starting with `#` are ignored.

### 2. Databricks token input

Choose one of the following methods.

#### Recommended: token file

```bash
echo "dapiXXXXXXXXXXXXXXXX" > databricks_token.txt
chmod 600 databricks_token.txt
```

#### Alternative: token in command line

This works, but it may be stored in shell history.

```bash
--token "dapiXXXXXXXXXXXXXXXX"
```

#### Multiple workspace tokens

Create `workspace_tokens.csv`:

```csv
WorkspaceUrl,Token
https://adb-xxxx.azuredatabricks.net,dapiXXXX
https://adb-yyyy.azuredatabricks.net,dapiYYYY
```

Use this when each workspace needs a different token.

## Basic run

```bash
chmod +x 03_databricks_optimize_collector_v2.sh

./03_databricks_optimize_collector_v2.sh \
  --subs-file subs.txt \
  --cost-start 2026-02-01 \
  --cost-end 2026-05-01 \
  --token-file ./databricks_token.txt
```

By default, this includes cluster analysis, instance pool analysis, job/workflow run efficiency analysis, SQL warehouse inventory, and Azure cost collection.

## Run with explicit output folder

```bash
./03_databricks_optimize_collector_v2.sh \
  --subs-file subs.txt \
  --cost-start 2026-02-01 \
  --cost-end 2026-05-01 \
  --token-file ./databricks_token.txt \
  --output-dir ./databricks-optimize-output
```

## Run for one workspace only

Use this when you want to run Databricks API collection for a single workspace without Azure subscription discovery.

```bash
./03_databricks_optimize_collector_v2.sh \
  --workspace-url https://adb-xxxx.azuredatabricks.net \
  --token-file ./databricks_token.txt \
  --output-dir ./databricks-optimize-output
```

## Run with workspace token map

```bash
./03_databricks_optimize_collector_v2.sh \
  --subs-file subs.txt \
  --cost-start 2026-02-01 \
  --cost-end 2026-05-01 \
  --token-map ./workspace_tokens.csv
```

## Run with DBU usage collection

To query `system.billing.usage`, provide a SQL warehouse ID.

```bash
./03_databricks_optimize_collector_v2.sh \
  --subs-file subs.txt \
  --cost-start 2026-02-01 \
  --cost-end 2026-05-01 \
  --token-file ./databricks_token.txt \
  --warehouse-id 1234567890abcdef
```

## Run job/workflow efficiency analysis

Job/workflow analysis is enabled by default.

```bash
./03_databricks_optimize_collector_v2.sh \
  --workspace-url https://adb-xxxx.azuredatabricks.net \
  --token-file ./databricks_token.txt \
  --include-jobs true \
  --lookback-days 30 \
  --output-dir ./databricks-job-analysis-output
```

To disable job analysis:

```bash
./03_databricks_optimize_collector_v2.sh \
  --workspace-url https://adb-xxxx.azuredatabricks.net \
  --token-file ./databricks_token.txt \
  --include-jobs false
```

## Run instance pool analysis

Instance pool analysis is enabled by default.

```bash
./03_databricks_optimize_collector_v2.sh \
  --workspace-url https://adb-xxxx.azuredatabricks.net \
  --token-file ./databricks_token.txt \
  --include-pools true \
  --output-dir ./databricks-pool-analysis-output
```

To disable pool analysis:

```bash
./03_databricks_optimize_collector_v2.sh \
  --workspace-url https://adb-xxxx.azuredatabricks.net \
  --token-file ./databricks_token.txt \
  --include-pools false
```

## Azure-only mode

Use this when you only want Azure workspace inventory and Azure cost, without calling Databricks APIs.

```bash
./03_databricks_optimize_collector_v2.sh \
  --subs-file subs.txt \
  --cost-start 2026-02-01 \
  --cost-end 2026-05-01 \
  --skip-databricks-api
```

## Skip Azure cost collection

Use this when you only want workspace and Databricks-side data.

```bash
./03_databricks_optimize_collector_v2.sh \
  --subs-file subs.txt \
  --cost-start 2026-02-01 \
  --cost-end 2026-05-01 \
  --token-file ./databricks_token.txt \
  --skip-azure-cost
```

## Command-line arguments

| Argument | Required | Description |
|---|---:|---|
| `--subs-file PATH` | Conditional | File with one Azure subscription ID per line. Required for Azure discovery/cost mode. |
| `--workspace-url URL` | Conditional | Databricks workspace URL. Required for Databricks-only mode. Also useful to limit collection to one workspace. |
| `--cost-start YYYY-MM-DD` | No | Start date for Azure cost and DBU query. Defaults to 90 days before today UTC. |
| `--cost-end YYYY-MM-DD` | No | End date for Azure cost and DBU query. Defaults to today UTC. |
| `--token TOKEN` | Conditional | One Databricks token for all workspaces. |
| `--token-file PATH` | Conditional | File containing one Databricks token. Recommended. |
| `--token-map PATH` | Conditional | CSV mapping workspace URLs to tokens. |
| `--output-dir PATH` | No | Output folder. Defaults to timestamped folder. |
| `--warehouse-id ID` | No | SQL warehouse ID used to query `system.billing.usage`. |
| `--include-pools true/false` | No | Include Databricks instance pool optimisation analysis. Default: `true`. |
| `--include-jobs true/false` | No | Include Databricks job/workflow run efficiency analysis. Default: `true`. |
| `--lookback-days NUMBER` | No | Lookback window for job/workflow run analysis. Default: `30`. |
| `--skip-azure-cost` | No | Skip Azure Cost Management collection. |
| `--skip-databricks-api` | No | Skip Databricks REST API calls. |
| `--help` | No | Show usage help. |

One of `--token`, `--token-file`, or `--token-map` is required unless `--skip-databricks-api` is used.

## Output files

The script creates a timestamped output folder unless `--output-dir` is supplied.

Expected outputs:

| Output file | Purpose |
|---|---|
| `01_databricks_workspaces.csv` | Azure Databricks workspaces discovered from Azure Resource Graph or manually supplied workspace URL |
| `02_azure_cost_by_resource.csv` | Azure cost by resource for the selected cost window |
| `03_clusters.csv` | Databricks cluster inventory |
| `04_cluster_findings.csv` | Cost optimisation findings from cluster configuration |
| `databricks_instance_pools_raw.csv` | Raw Databricks instance pool inventory with cluster correlation |
| `databricks_instance_pool_findings.csv` | Instance pool optimisation findings |
| `databricks_instance_pool_summary.csv` | Workspace-level pool summary |
| `databricks_jobs_raw.csv` | Raw job/workflow configuration summary |
| `databricks_job_runs_raw.csv` | Recent job/workflow runs in the lookback window |
| `databricks_job_task_runs_raw.csv` | Task-level run details where available |
| `databricks_job_findings.csv` | Job/workflow efficiency findings |
| `databricks_job_summary.csv` | Workspace-level job/workflow summary |
| `06_sql_warehouses.csv` | SQL warehouse inventory |
| `07_dbu_usage.csv` | Optional DBU usage data from `system.billing.usage` |
| `08_recommendations.csv` | Consolidated optimisation recommendations |
| `Summary.txt` | Run summary, counts, and output location |

Optional JSON outputs may also be created for raw Databricks jobs and runs, such as `databricks_jobs_raw_<workspace>.json`, `databricks_jobs_details_raw_<workspace>.json`, `databricks_job_runs_raw_<workspace>.json`, and `databricks_job_run_details_raw_<workspace>.json`.

## Job / Workflow Run Efficiency Analysis

This v2 feature uses Databricks REST APIs only. It does not require Azure Monitor, Log Analytics, or system tables.

APIs used:

| API | Purpose |
|---|---|
| `GET /api/2.1/jobs/list` | List jobs/workflows |
| `GET /api/2.1/jobs/get?job_id=<job_id>` | Get job settings, tasks, job clusters, schedule, tags, and cluster configuration |
| `GET /api/2.1/jobs/runs/list` | Get recent runs within the lookback period |
| `GET /api/2.1/jobs/runs/get?run_id=<run_id>` | Get task-level run details where accessible |

Findings generated:

| Finding | Meaning |
|---|---|
| `LongRunningJob` | Average job duration is greater than 60 minutes |
| `VeryLongRunningJob` | Average job duration is greater than 180 minutes |
| `HighFrequencyJob` | Job runs more than 24 times per day |
| `VeryHighFrequencyJob` | Job runs more than 96 times per day |
| `HighFailureRateJob` | Job has at least 5 runs and failure rate greater than 20% |
| `RepeatedRetries` | Average attempts is greater than 1.2 |
| `UsesAllPurposeCluster` | One or more tasks use `existing_cluster_id` |
| `NoJobClusterDefined` | Job does not define job clusters or task new clusters |
| `MissingJobTags` | Job tags are missing required keys: Owner, CostCentre/CostCenter, Application, Environment |
| `ScheduledButNoRecentSuccess` | Scheduled/triggered job has no successful run in lookback window |
| `LargeClusterForShortJob` | Large node type is used for a short-running job |
| `LongRunningFailedJob` | A failed job run lasted more than 60 minutes |

Cost estimates in this version are qualitative. The script adds cost impact notes instead of exact dollar savings unless pricing data is added later.

## Instance Pool Optimisation Analysis

This v2 feature uses Databricks REST APIs only. It does not require Azure Monitor, Log Analytics, or system tables.

APIs used:

| API | Purpose |
|---|---|
| `GET /api/2.0/instance-pools/list` | List Databricks instance pools |
| `GET /api/2.0/clusters/list` | Correlate pools to attached clusters through `instance_pool_id` and `driver_instance_pool_id` |

Findings generated:

| Finding | Meaning |
|---|---|
| `UnusedPool` | Pool is not attached to any listed cluster |
| `IdleCapacityRisk` | Pool has `min_idle_instances > 0` |
| `HighMinIdlePool` | Pool has `min_idle_instances >= 2` |
| `NoAutoTerminationForIdleInstances` | Pool has no idle instance auto-termination configured |
| `ExpensiveNodeTypePool` | Pool uses a large/expensive node type heuristic |
| `UntaggedPool` | Pool is missing required tags |
| `PotentiallyOversizedPool` | Pool has high `max_capacity` and low/no running cluster usage |

## Recommended first run

For the first customer run, use read-only full collection:

```bash
./03_databricks_optimize_collector_v2.sh \
  --subs-file subs.txt \
  --cost-start 2026-02-01 \
  --cost-end 2026-05-01 \
  --token-file ./databricks_token.txt \
  --include-pools true \
  --include-jobs true \
  --lookback-days 30
```

Then review:

```bash
cat ./databricks-costopt-out-*/Summary.txt
column -s, -t < ./databricks-costopt-out-*/04_cluster_findings.csv | head -30
column -s, -t < ./databricks-costopt-out-*/databricks_instance_pool_findings.csv | head -30
column -s, -t < ./databricks-costopt-out-*/databricks_job_findings.csv | head -30
column -s, -t < ./databricks-costopt-out-*/08_recommendations.csv | head -30
```

## Security notes

Do not commit Databricks tokens into Git.

Prefer `--token-file` with restricted permissions:

```bash
chmod 600 databricks_token.txt
```

Avoid using `--token` directly in shared terminals because it can remain in shell history.

## Troubleshooting

| Issue | What to check |
|---|---|
| No workspaces found | Confirm subscription IDs and Reader access |
| Azure cost file is empty | Confirm Cost Management Reader access and valid dates |
| Databricks API returns 401 | Token is invalid, expired, or for the wrong workspace |
| Databricks API returns 403 | Token user does not have workspace read permissions for jobs, runs, clusters, pools, or warehouses |
| Job files are empty | Confirm the workspace has jobs and the token can read job/workflow metadata |
| Job runs are empty | Increase `--lookback-days` or confirm jobs ran during the window |
| Pool files are empty | Confirm the workspace uses instance pools and the token can read pool metadata |
| DBU usage file is empty | Confirm `--warehouse-id`, SQL warehouse access, and system table availability |
| `jq: command not found` | Install jq or run from Azure Cloud Shell |
| Cost dates fail | Use `YYYY-MM-DD` format |

## Recommended next step

After the first run, the main files to inspect are:

1. `08_recommendations.csv`
2. `databricks_job_findings.csv`
3. `databricks_instance_pool_findings.csv`
4. `04_cluster_findings.csv`
5. `02_azure_cost_by_resource.csv`
6. `07_dbu_usage.csv`, if DBU collection was enabled
