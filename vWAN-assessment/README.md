# Comprehensive VWAN Assessment v1

**Author:** [Satish Balakrishnan](mailto:satishbal@microsoft.com)  
**Version:** 2.0  
**Category:** Azure Networking | Azure Virtual WAN | Assessment Script  
**Compatibility:** Azure Cloud Shell • Azure CLI 2.60+ • PowerShell 7+

---

##  Overview

The **Comprehensive VWAN Assessment v1** script  attempts to perform an end-to-end analysis of an **Azure Virtual WAN** environment to validate configuration alignment, security posture, and operational readiness.
The output is a json file that captures configurations (as listed below) for all resources within the VWAN architecture. Please note that this script itself does not perform an assessment but it gives you all the data in json format to do the assessment.

It automatically discovers all Virtual WANs, Virtual Hubs, Connected VNets, Azure Firewalls, and Route Tables, producing a single **JSON report** for architecture reviews, compliance assessments, or automation pipelines.

---

## Key Features

| Feature | Description |
|----------|-------------|
| **Virtual WAN Discovery** | Enumerates all VWANs and vHubs within the selected subscription. |
| **Expanded Route Tables** | Retrieves every route entry (AddressPrefixes, NextHopType, NextHopResourceId) for each route table in every vHub. |
| **Effective Routes** | Uses the ARM `getEffectiveRoutes` API to capture actual routing after propagation and association. |
| **Firewall & Policy Details** | Supports Secure Hub (managed) and standalone firewalls with full policy details (tier, rule groups, IPs, ThreatIntel). |
| **Triple Firewall Detection Logic** | Detects firewalls via hub ID, firewall name pattern, and route-table fallback for complete coverage. |
| **Diagnostics Summary** | Captures diagnostic settings for each VWAN, vHub, and Firewall (metrics, logs, and destinations). |
| **Cloud Shell Friendly** | Runs in Azure Cloud Shell or any PowerShell session with Azure CLI authentication. |
| **Portable JSON Output** | Generates a single file `ComprehensiveVWANAssessment-<timestamp>.json` for downstream analysis. |

---



## Usage

### Run from Cloud Shell or PowerShell
```bash
./Comprehensive-VWAN-Assessment-v2.ps1

When Prompted:

Enter Azure Subscription ID (leave blank to use current CLI session): <your-subscription-id>
Enter a specific Virtual WAN name to audit (press Enter for all VWANs): <your-vwan-name>


## Changelog
    v2 adds the following on top of v1
     - Added discovery of VPN, ExpressRoute, and P2S VPN Gateways per hub.
     - Integrated Routing Intent capture (where explicitly configured).
     - Enhanced Firewall details — includes Policy Tier, Threat Intelligence Mode, and Rule Collection Groups.