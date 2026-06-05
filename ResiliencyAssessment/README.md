# Azure Resiliency Assessment

**Author:** [Satish Balakrishnan](mailto:satishbal@microsoft.com)  
**Version:** 6.3g
**Category:** Resiliency assessment 
**Compatibility:** Azure Cloud Shell • Azure CLI 2.60+ • PowerShell 7+


This script runs a **resiliency assessment** across one or more Azure subscriptions. It gathers high‑signal checks
on core services, merges **Azure Advisor (High Availability)** recommendations, and folds in **Microsoft Well‑Architected**
(**WARA**) Reliability guidance

---

## What it checks

- **Virtual Machines / VMSS**: zone/availability set coverage, diagnostics
- **Storage Accounts**: redundancy (LRS detection), HTTPS-only, diagnostics
- **SQL Databases**: Failover Group presence, diagnostics
- **App Service**: plans (scale-out), web apps (Always On), diagnostics
- **Load Balancers**: basic vs standard, diagnostics
- **VPN/ER Gateways**: Active‑Active on VPN, diagnostics
- **Recovery Services Vaults**: **policy presence** and diagnostics (**no item/container prompts**)
- **AKS**: system pool, zonal pools, API exposure, diagnostics
- **Redis**: zone redundancy, diagnostics
- **Application Gateway**: v2 SKU, diagnostics
- **Front Door (CDN Profiles)**: AzureFrontDoor SKUs, diagnostics
- **Public IPs**: basic vs standard; zonal redundancy (informational diagnostics)
- **Azure Firewall**: zones, threat intel mode, diagnostics
- **Virtual WAN/Virtual Hubs**: diagnostics and basic routing‑table presence
- **Azure Advisor**: High Availability recommendations (REST first, cmdlet fallback)
- **WARA Reliability**: via Microsoft.WellArchitected REST where available; curated fallback otherwise

---

## Prerequisites

- **Az PowerShell** installed (Cloud Shell already has this).
- Access to target subscriptions (Reader or higher). For Advisor API, **Reader at subscription scope**.
- If using **PIM**, activate your role before running.
- Some tenants may need: `Register-AzResourceProvider -ProviderNamespace Microsoft.Advisor`

> The script uses **device authentication** when needed and **does not enable WAM**.

---

## Files

- `subscriptions.txt` — one subscription **GUID** per line (sample provided).

---

## How to run

1. Put your subscription IDs into `subscriptions.txt` (one GUID per line).
2. Run the script:
   ```powershell
   .\ResiliencyAssessment-v6.3g-MultiSub-AutoWARA.ps1 -SubListPath ".\subscriptions.txt"
   ```
 

**Outputs** (created in `~\resiliency_reports\`):

---

## Notes on WARA (Reliability)

- The script attempts Microsoft.WellArchitected **REST** for recommendations using your ARM token.
- API endpoints and versions are **preview** and may vary by tenant/region/features.
- If not available or unauthorized, a curated Reliability checklist is added so reports still capture pillar guidance.

---

## Troubleshooting

- **Advisor 401/403**: ensure the **Microsoft.Advisor** provider is registered and you have **Reader** on the subscription.
- **Tenant mismatch**: the script scopes the token to the **current context tenant**; re‑`Connect-AzAccount` if needed.
- **RSV prompts**: intentionally avoided by using **policy‑only** checks; upgrade Az.RecoveryServices if you want deep item coverage.
- **Empty report**: verify resources exist in the subscription and your role has read permissions.

---


