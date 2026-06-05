# Azure Cost Data Collector
**Author:** [Satish Balakrishnan](mailto:satishbal@microsoft.com)  
## Script

`00_azure_cost_data_collector_v1.sh`

This is the first script in the Azure Cost Optimization Engine. It collects the base cost and Advisor data across multiple Azure subscriptions and creates the input file required by the downstream optimizer scripts.

---

## What this script does

- Reads subscription IDs from `subs.txt`
- Switches Azure context for each subscription
- Pulls 3-month amortized cost data from Azure Cost Management
- Aggregates cost by resource
- Pulls Azure Advisor cost recommendations
- Merges cost and Advisor findings
- Produces a ranked resource-level report
- Adds retry/backoff handling for transient Azure API failures and 429 throttling
- Writes logs and raw cost JSON for troubleshooting

---

## Input files

### `subs.txt`

Create a file named `subs.txt` with one subscription ID per line.

Example:

```text
c199c690-252a-4d2d-a990-df2551613a08
5d27b5bc-2bf9-4c6e-82b9-77a88c4a7c52
cea680fe-7d4c-40b7-8280-87ed79103434
```

Blank lines are ignored. Lines starting with `#` are treated as comments.

---

## Prerequisites

The machine or Cloud Shell session must have:

- Azure CLI
- `jq`
- Python 3
- Azure login completed with appropriate access
- Reader access to the target subscriptions
- Permission to query Cost Management and Advisor data

Check Azure login:

```bash
az account show
```

If not logged in:

```bash
az login
```

---

## How to run

Make the script executable:

```bash
chmod +x 00_azure_cost_data_collector_v1.sh
```

Run normally:

```bash
./00_azure_cost_data_collector_v1.sh subs.txt FinalRankedReport.csv
```

Recommended long-running execution:

```bash
nohup ./00_azure_cost_data_collector_v1.sh \
  subs.txt \
  FinalRankedReport.csv \
  > collector.log 2>&1 &
```

Monitor progress:

```bash
tail -f collector.log
```

---

## Optional environment variables

You can override the defaults before running the script.

| Variable | Default | Purpose |
|---|---:|---|
| `MONTHS` | `3` | Number of months of amortized cost to collect |
| `CURRENCY` | `USD` | Currency label used in output |
| `TOP_N` | `0` | Limit final output to top N resources. `0` means all rows |
| `SLEEP_SECONDS` | `2` | Delay between subscription calls to reduce throttling |

Example:

```bash
MONTHS=3 TOP_N=100 SLEEP_SECONDS=5 ./00_azure_cost_data_collector_v1.sh subs.txt FinalRankedReport.csv
```

---

## Output files

The script creates the following files:

| Output | Description |
|---|---|
| `FinalRankedReport.csv` | Main output used by downstream optimizer scripts |
| `CostByResource.csv` | Raw resource-level 3-month amortized cost output |
| `AdvisorCostRecommendations.csv` | Azure Advisor cost recommendations |
| `phase0_raw_cost_json/` | Raw Cost Management API JSON responses per subscription |
| `phase0_logs/phase0.log` | Detailed execution log |

---

## Main output: `FinalRankedReport.csv`

This file is the key handoff into the next optimization stages.

It includes columns such as:

- `SubscriptionId`
- `ResourceId`
- `ResourceGroup`
- `ResourceName`
- `ResourceType`
- `ServiceName`
- `Location`
- `FindingType`
- `Severity`
- `Recommendation`
- `TotalCost3Mo`
- `ObservedMonthlyCostUSD`
- `Kind`
- `Evidence`
- `SourceResourceId`

This file can then be passed into:

```bash
./01_azure_vm_optimizer_v1.sh FinalRankedReport.csv VM_Optimization_Output.csv
```

and later disk/snapshot optimizer scripts.

---

## End-to-end flow

```text
subs.txt
   ↓
00_azure_cost_data_collector_v1.sh
   ↓
FinalRankedReport.csv
   ↓
01_azure_vm_optimizer_v1.sh
   ↓
VM_Optimization_Output.csv
```

---

## Troubleshooting

### Script says Azure CLI is not logged in

Run:

```bash
az login
```

or in Cloud Shell, refresh the session and run:

```bash
az account show
```

---

### Subscription is skipped

The script skips a subscription if it cannot run:

```bash
az account set --subscription <subscription-id>
```

Check that the subscription ID is correct and that you have access.

---

### Cost data is missing

Common reasons:

- No Cost Management access
- Subscription has no spend in the selected period
- Cost API temporarily throttled
- Incorrect subscription ID

Check:

```bash
cat phase0_logs/phase0.log
```

---

### Advisor recommendations are missing

This is not always a failure. Some subscriptions may not have Advisor cost recommendations.

The script still includes high-spend resources from Cost Management even when Advisor has no matching recommendation.

---

### Script is slow

This is expected for many subscriptions. The script calls Azure Cost Management and Advisor APIs per subscription and includes retry/backoff handling.

Run with `nohup` and monitor logs:

```bash
nohup ./00_azure_cost_data_collector_v1.sh subs.txt FinalRankedReport.csv > collector.log 2>&1 &
tail -f collector.log
```

---

## Notes

- The script currently collects amortized cost for the last 3 months by default.
- It does not perform VM rightsizing or RI savings calculations. That is handled by the VM optimizer script.
- It does not require the VM optimizer to run, but the VM optimizer requires `FinalRankedReport.csv` from this script.
