# Azure Cost Optimization Toolkit

This toolkit provides a structured set of scripts to collect Azure cost data and run targeted cost optimization analysis across Azure subscriptions.

The toolkit is designed around a simple flow:

1. Run the core data collector.
2. Generate the baseline cost report.
3. Run one or more optimization modules such as VM, disks, Databricks, and future AKS optimizers.
4. Review the generated CSV outputs and action the highest-value recommendations.

---

## Repository Structure

```text
cost-optimization/
├── README.md
├── core/
│   ├── 00_azure_cost_data_collector_v1.sh
│   └── README.md
└── optimizers/
    ├── vm/
    │   ├── 01_azure_vm_optimizer_v1.sh
    │   └── README.md
    ├── disks/
    │   ├── 02_azure_disk_snapshot_optimizer_v1.sh
    │   └── README.md
    └── databricks/
        ├── databricks_optimize_collector_v1.sh
        └── README.md
```

---

## Folder Purpose

| Folder | Purpose |
|---|---|
| `core/` | Common cost data collection layer. This produces the baseline cost and Advisor reports used by downstream optimizers. |
| `optimizers/vm/` | VM-specific cost optimization analysis such as rightsizing, low-utilization review, and cost ranking. |
| `optimizers/disks/` | Managed disk and snapshot optimization analysis, including unattached disks and potential cleanup opportunities. |
| `optimizers/databricks/` | Databricks-specific cost optimization data collection and analysis. |
| `optimizers/aks/` | Future location for AKS-specific cost optimization modules. |

---

## Core Flow

The core collector is the first script to run.

```text
subs.txt
   ↓
core/00_azure_cost_data_collector_v1.sh
   ↓
FinalRankedReport.csv
   ↓
optimizer modules
```

The main purpose of the core collector is to create the baseline files required by downstream optimizer scripts.

Typical outputs include:

| Output | Description |
|---|---|
| `FinalRankedReport.csv` | Main ranked cost report used as input by optimizer modules. |
| `CostByResource.csv` | Resource-level amortized cost data. |
| `AdvisorCostRecommendations.csv` | Azure Advisor cost recommendations. |
| `phase0_raw_cost_json/` | Raw Cost Management API responses for troubleshooting. |
| `phase0_logs/` | Collector execution logs. |

---

## Optimizer Modules

Each optimizer should live in its own folder under `optimizers/`.

### VM Optimizer

```text
optimizers/vm/
├── 01_azure_vm_optimizer_v1.sh
└── README.md
```

The VM optimizer uses the cost collector output and Azure metrics to identify VM optimization opportunities.

Example output:

```text
VM_Optimization_Output.csv
```

### Disk and Snapshot Optimizer

```text
optimizers/disks/
├── 02_azure_disk_snapshot_optimizer_v1.sh
└── README.md
```

The disk optimizer focuses on disk and snapshot-related savings opportunities, such as unattached managed disks and unused snapshots.

Example output:

```text
Disk_Snapshot_Optimization_Output.csv
```

### Databricks Optimizer

```text
optimizers/databricks/
├── databricks_optimize_collector_v1.sh
└── README.md
```

The Databricks optimizer is separate from the core collector because Databricks has service-specific cost and configuration signals.

---

## Recommended Execution Order

Run the scripts in this order:

```bash
# 1. Run the core collector
cd cost-optimization/core
chmod +x 00_azure_cost_data_collector_v1.sh
./00_azure_cost_data_collector_v1.sh subs.txt FinalRankedReport.csv

# 2. Run the VM optimizer
cd ../optimizers/vm
chmod +x 01_azure_vm_optimizer_v1.sh
./01_azure_vm_optimizer_v1.sh ../../core/FinalRankedReport.csv VM_Optimization_Output.csv

# 3. Run the disk and snapshot optimizer
cd ../disks
chmod +x 02_azure_disk_snapshot_optimizer_v1.sh
./02_azure_disk_snapshot_optimizer_v1.sh ../../core/FinalRankedReport.csv Disk_Snapshot_Optimization_Output.csv
```

For Databricks, refer to:

```text
optimizers/databricks/README.md
```

---

## Prerequisites

The environment running these scripts should have:

- Azure CLI
- `jq`
- Python 3, if required by specific modules
- Azure login completed
- Reader access to the target subscriptions
- Permission to query Azure Cost Management data
- Permission to query Azure Advisor recommendations
- Permission to read Azure Monitor metrics, where optimizer modules require metrics

Check Azure login:

```bash
az account show
```

If not logged in:

```bash
az login
```

---

## Input File

The collector expects a `subs.txt` file containing one Azure subscription ID per line.

Example format:

```text
00000000-0000-0000-0000-000000000000
11111111-1111-1111-1111-111111111111
22222222-2222-2222-2222-222222222222
```

Blank lines are ignored. Lines starting with `#` are treated as comments.

Do not commit real customer subscription IDs to the repository.

---

## What Should Not Be Committed

Do not commit customer-generated output files or sensitive data.

Avoid committing files such as:

```text
subs.txt
FinalRankedReport.csv
CostByResource.csv
AdvisorCostRecommendations.csv
VM_Optimization_Output.csv
Disk_Snapshot_Optimization_Output.csv
phase0_raw_cost_json/
phase0_logs/
costopt-out-*/
*.ndjson
```

Use `.gitignore` to prevent accidental commits of generated files.

---

## Suggested `.gitignore` Entries

Add the following entries to the repository `.gitignore`:

```gitignore
# Azure cost optimization inputs and outputs
subs.txt
FinalRankedReport.csv
CostByResource.csv
AdvisorCostRecommendations.csv
VM_Optimization_Output*.csv
Disk_Snapshot_Optimization_Output*.csv
phase0_raw_cost_json/
phase0_logs/
costopt-out-*/
databricks-costopt-out-*/
*.ndjson
```

---

## Future Extensions

Future optimizer modules should follow the same pattern:

```text
optimizers/<service-name>/
├── <service>_optimizer_v1.sh
└── README.md
```

Potential future modules:

- `optimizers/aks/`
- `optimizers/appservice/`
- `optimizers/sql/`
- `optimizers/storage/`
- `optimizers/networking/`

Each optimizer should have its own README explaining:

- Purpose
- Inputs
- Prerequisites
- How to run
- Outputs
- Troubleshooting
- Known limitations

---

## Notes

- The core collector should remain focused on common cost and Advisor data collection.
- Service-specific logic should be placed under `optimizers/`.
- Generated outputs should be reviewed locally and not committed unless they are fully anonymized.
- The toolkit can be extended incrementally by adding new optimizer folders without changing the core collector.
