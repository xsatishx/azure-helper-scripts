<#
.SYNOPSIS
Azure Resiliency Assessment

.DESCRIPTION
- Reads one or more Azure Subscription IDs from a text file (one GUID per line).
- For each subscription:
  * Sets context (no WAM; uses device auth if needed).
  * Gathers resiliency-focused checks across core Azure resources.
  * Pulls Azure Advisor High Availability recommendations (REST-first, with cmdlet fallback).
  * Adds Microsoft Well-Architected "Reliability" (WARA) guidance:
      - Tries Microsoft.WellArchitected REST (if available in tenant/sub).
      - Falls back to curated reliability prompts if API unavailable.
  * Recovery Services Vaults are checked in a **non-interactive** way (policy presence + diagnostics only).
- Emits one combined CSV/JSON for all subscriptions and optional per-sub CSVs.
- Fully ASCII-safe (no smart quotes or Unicode symbols) to avoid PowerShell parser errors.

.PARAMETERS
-SubListPath <string>   Path to text file with one subscription ID per line. Default: .\subscriptions.txt
-NoPerSubFiles          Switch to disable per-subscription CSV emission.

.OUTPUTS
~\resiliency_reports\<timestamp>-ResiliencyReport.csv        (all subscriptions combined)
~\resiliency_reports\<timestamp>-ResiliencyReport.json       (all subscriptions combined)
~\resiliency_reports\<timestamp>\<subId>-Resiliency.csv      (per-subscription; unless -NoPerSubFiles)

.NOTES
Author: Satish
#>

param(
  # Text file with one subscription GUID per line.
  [string]$SubListPath = "./subscriptions.txt",

  # If set, the script will not write per-subscription CSV files (only the combined CSV/JSON).
  [switch]$NoPerSubFiles
)

# Fail fast for unexpected errors; individual sections handle their own errors gracefully.
$ErrorActionPreference = "Stop"

# Silence Az breaking-change warnings for cleaner output.
Set-Item -Path Env:\SuppressAzurePowerShellBreakingChangeWarnings -Value "true" -ErrorAction SilentlyContinue | Out-Null

# -----------------------------------------------------------------------------
# 1) Read and validate the subscription list
# -----------------------------------------------------------------------------
if (-not (Test-Path $SubListPath)) {
  Write-Error "Subscription list file not found: $SubListPath. Create a text file with one subscription ID per line."
  exit 1
}

# Normalize lines: trim blanks, keep order, keep only GUID-looking values, de-duplicate
$allLines = Get-Content -Path $SubListPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }
$guidRegex = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$subs = @()
$seen = @{}
foreach ($l in $allLines) {
  if ($l -match $guidRegex) {
    $key = $l.ToLower()
    if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $subs += $l }
  }
}
if ($subs.Count -eq 0) {
  Write-Error "No valid subscription GUIDs found in $SubListPath."
  exit 1
}

# -----------------------------------------------------------------------------
# 2) Login once (uses device auth in console); do NOT force WAM (interactive Windows broker)
# -----------------------------------------------------------------------------
try {
  if (-not (Get-AzContext)) {
    Write-Host "No active Azure login found. Connecting..."
    Connect-AzAccount -UseDeviceAuthentication | Out-Null
  }
} catch {
  Write-Error "Azure login failed: $($_.Exception.Message)"
  exit 1
}

# -----------------------------------------------------------------------------
# 3) Prepare output folders and global buffers (cover all subscriptions)
# -----------------------------------------------------------------------------
$reportDir = Join-Path $HOME "resiliency_reports"
if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir | Out-Null }
$timestamp = (Get-Date).ToString("yyyy-MM-dd-HHmmss")
$rootCsv   = Join-Path $reportDir "$timestamp-ResiliencyReport.csv"
$rootJson  = Join-Path $reportDir "$timestamp-ResiliencyReport.json"
$tsDir     = Join-Path $reportDir $timestamp
if (-not (Test-Path $tsDir)) { New-Item -ItemType Directory -Path $tsDir | Out-Null }

$AllFindings = New-Object System.Collections.Generic.List[object]   # master list of all findings
$AllSummary  = @{}                                                  # simple count per resource type

# Helper to append findings to both the global aggregate and per-sub buffers.
function Add-Finding {
  param(
    [string]$SubscriptionId,
    [string]$ResourceName,
    [string]$ResourceId,
    [string]$ResourceType,
    [string]$Check,
    [ValidateSet("High","Medium","Low")] [string]$Severity,
    [string]$Finding,
    [string]$Recommendation,
    [string]$Evidence,
    [string]$Pillar = "Reliability"  # map all findings to Reliability by default (resiliency focus)
  )
  $AllFindings.Add([PSCustomObject]@{
    SubscriptionId = $SubscriptionId
    ResourceName   = $ResourceName
    ResourceId     = $ResourceId
    ResourceType   = $ResourceType
    Check          = $Check
    Severity       = $Severity
    Finding        = $Finding
    Recommendation = $Recommendation
    Evidence       = $Evidence
    Pillar         = $Pillar
    LastUpdated    = (Get-Date)
  })
  if (-not $AllSummary.ContainsKey($ResourceType)) { $AllSummary[$ResourceType] = 0 }
  $AllSummary[$ResourceType]++
}

# Diagnostic settings check wrapped to never throw (returns $true if any setting exists)
function Test-DiagnosticSetting {
  param([string]$ResourceId)
  try {
    $d = Get-AzDiagnosticSetting -ResourceId $ResourceId -ErrorAction Stop
    return ($d -ne $null -and $d.Count -gt 0)
  } catch { return $false }
}

# -----------------------------------------------------------------------------
# 4) Per-subscription assessment function
#    Encapsulates the entire run for isolation and clear logs.
# -----------------------------------------------------------------------------
function Invoke-ResiliencyRunForSubscription {
  param([string]$SubId)

  # Local (per-subscription) buffers, used for optional per-sub CSV
  $Findings = New-Object System.Collections.Generic.List[object]
  $Summary  = @{}  # count per resource type

  # Helper to add to both local and global stores
  function Add-LocalFinding {
    param(
      [string]$ResourceName,
      [string]$ResourceId,
      [string]$ResourceType,
      [string]$Check,
      [ValidateSet("High","Medium","Low")] [string]$Severity,
      [string]$Finding,
      [string]$Recommendation,
      [string]$Evidence,
      [string]$Pillar = "Reliability"
    )
    $obj = [PSCustomObject]@{
      SubscriptionId = $SubId
      ResourceName   = $ResourceName
      ResourceId     = $ResourceId
      ResourceType   = $ResourceType
      Check          = $Check
      Severity       = $Severity
      Finding        = $Finding
      Recommendation = $Recommendation
      Evidence       = $Evidence
      Pillar         = $Pillar
      LastUpdated    = (Get-Date)
    }
    $Findings.Add($obj)
    if (-not $Summary.ContainsKey($ResourceType)) { $Summary[$ResourceType] = 0 }
    $Summary[$ResourceType]++

    Add-Finding -SubscriptionId $SubId -ResourceName $ResourceName -ResourceId $ResourceId -ResourceType $ResourceType `
      -Check $Check -Severity $Severity -Finding $Finding -Recommendation $Recommendation -Evidence $Evidence -Pillar $Pillar
  }

  # 4a) Set context to the target subscription (hardened for multi-tenant)
  try {
    Set-AzContext -SubscriptionId $SubId | Out-Null
    $ctx = Get-AzContext
    Write-Host ""
    Write-Host "===== Subscription: $($ctx.Subscription.Name) ($SubId) ====="
  } catch {
    Write-Warning "Failed to set context for ${SubId}: $($_.Exception.Message)"
    return
  }

  # 4b) Azure Advisor High Availability (REST-first with provider auto-register, then cmdlet fallback)
  Write-Host "Collecting Advisor High Availability recommendations via REST (per-sub)..."
  try {
    $prov = Get-AzResourceProvider -ProviderNamespace Microsoft.Advisor -ErrorAction SilentlyContinue
    if ($prov -and $prov.RegistrationState -ne "Registered") {
      Write-Warning "Microsoft.Advisor provider not registered for ${SubId}. Attempting to register..."
      try { Register-AzResourceProvider -ProviderNamespace Microsoft.Advisor -ErrorAction SilentlyContinue | Out-Null } catch {}
      $prov = Get-AzResourceProvider -ProviderNamespace Microsoft.Advisor -ErrorAction SilentlyContinue
    }

    $ctx = Get-AzContext
    $tenantId = $ctx.Tenant.Id
    $token = (Get-AzAccessToken -TenantId $tenantId -Resource "https://management.azure.com/").Token
    $uri   = "https://management.azure.com/subscriptions/${SubId}/providers/Microsoft.Advisor/recommendations?api-version=2023-01-01"

    $resp  = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $token" } -Method GET -ErrorAction Stop
    $ha    = $resp.value | Where-Object { $_.category -eq "HighAvailability" }
    foreach ($r in $ha) {
      Add-LocalFinding $r.impactedField $r.impactedResource $r.resourceMetadata.resourceType "Advisor:HighAvailability" "Medium" `
        $r.shortDescription.problem $r.shortDescription.solution ("RecommendationId=" + $r.name)
    }
    Write-Host "Advisor HA (REST) retrieved: $($ha.Count)"
  } catch {
    Write-Warning "Advisor REST failed for ${SubId} ($($_.Exception.Message)). Trying Az.Advisor cmdlet..."
    try {
      Import-Module Az.Advisor -ErrorAction SilentlyContinue | Out-Null
      $recs = Get-AzAdvisorRecommendation -Category HighAvailability -ErrorAction Stop
      foreach ($r in $recs) {
        $resType = $r.ImpactedValueDetails.ResourceType
        if (-not $resType) { $resType = $r.ImpactedValue }
        Add-LocalFinding $r.ImpactedValue $r.ImpactedValue $resType "Advisor:HighAvailability" "Medium" `
          $r.ShortDescription.Problem $r.ShortDescription.Solution ("RecommendationId=" + $r.Name)
      }
      Write-Host "Advisor HA (Az.Advisor) retrieved: $($recs.Count)"
    } catch {
      Write-Warning "Advisor query failed or unauthorized for ${SubId}. Skipping (non-fatal)."
    }
  }

  # 4c) Core Resource Checks (resiliency heuristics + diagnostics)
  #     NOTE: All Test-DiagnosticSetting calls are safe (never throw).
  try {
    # Virtual Machines
    $vms = Get-AzVM -Status -ErrorAction SilentlyContinue
    foreach ($vm in $vms) {
      $rid=$vm.Id; $rname=$vm.Name; $rtype="Microsoft.Compute/virtualMachines"
      if (-not $vm.Zones -and -not $vm.AvailabilitySetReference) {
        Add-LocalFinding $rname $rid $rtype "AZ/AS Coverage" "High" "VM not zone/AS redundant" "Place VM in Availability Zone or Availability Set" ("Location=" + $vm.Location)
      }
      if (-not (Test-DiagnosticSetting -ResourceId $rid)) {
        Add-LocalFinding $rname $rid $rtype "Diagnostics" "Medium" "No diagnostic settings" "Enable VM diagnostics to Log Analytics/Event Hub/Storage" "Diagnostics=disabled"
      }
    }

    # VM Scale Sets
    $vmssList = Get-AzVmss -ErrorAction SilentlyContinue
    foreach ($vmss in $vmssList) {
      $rid=$vmss.Id; $rname=$vmss.Name; $rtype="Microsoft.Compute/virtualMachineScaleSets"
      if (-not $vmss.Zones) {
        Add-LocalFinding $rname $rid $rtype "AZ Coverage" "High" "VMSS not zone-redundant" "Deploy VMSS across Availability Zones" ("Location=" + $vmss.Location)
      }
      if (-not (Test-DiagnosticSetting -ResourceId $rid)) {
        Add-LocalFinding $rname $rid $rtype "Diagnostics" "Medium" "No diagnostic settings" "Enable diagnostics to Log Analytics" "Diagnostics=disabled"
      }
    }

    # Storage Accounts
    $stgs = Get-AzStorageAccount -ErrorAction SilentlyContinue
    foreach ($sa in $stgs) {
      $rid=$sa.Id; $rname=$sa.StorageAccountName; $rtype="Microsoft.Storage/storageAccounts"
      if ($sa.Sku.Name -eq "Standard_LRS") {
        Add-LocalFinding $rname $rid $rtype "Redundancy" "High" "LRS redundancy" "Use ZRS/GZRS/GRS for higher availability" ("SKU=" + $sa.Sku.Name)
      }
      if (-not $sa.EnableHttpsTrafficOnly) {
        Add-LocalFinding $rname $rid $rtype "HTTPS Only" "High" "Secure transfer disabled" "Enable HTTPS only" "HTTPSOnly=false"
      }
      if (-not (Test-DiagnosticSetting -ResourceId $rid)) {
        Add-LocalFinding $rname $rid $rtype "Diagnostics" "Medium" "No diagnostic settings" "Enable storage diagnostics" "Diagnostics=disabled"
      }
    }

    # SQL Databases
    $servers = Get-AzSqlServer -ErrorAction SilentlyContinue
    foreach ($svr in $servers) {
      $dbs  = Get-AzSqlDatabase -ServerName $svr.ServerName -ResourceGroupName $svr.ResourceGroupName -ErrorAction SilentlyContinue | Where-Object { $_.DatabaseName -ne "master" }
      $fogs = Get-AzSqlDatabaseFailoverGroup -ServerName $svr.ServerName -ResourceGroupName $svr.ResourceGroupName -ErrorAction SilentlyContinue
      foreach ($db in $dbs) {
        $rid=$db.ResourceId; $rname=$db.DatabaseName; $rtype="Microsoft.Sql/servers/databases"
        $inFog = ($fogs | Where-Object { $_.Databases -contains $db.ResourceId })
        if (-not $inFog) {
          Add-LocalFinding $rname $rid $rtype "Geo Resiliency" "High" "DB not in Failover Group" "Enable Geo-replication/FOG" ("Server=" + $svr.ServerName)
        }
        if (-not (Test-DiagnosticSetting -ResourceId $rid)) {
          Add-LocalFinding $rname $rid $rtype "Diagnostics" "Medium" "No diagnostic settings" "Enable SQL diagnostics" "Diagnostics=disabled"
        }
      }
    }

    # App Service (Plans & Web Apps)
    $plans = Get-AzAppServicePlan -ErrorAction SilentlyContinue
    foreach ($plan in $plans) {
      $rid=$plan.Id; $rname=$plan.Name; $rtype="Microsoft.Web/serverfarms"
      if ($plan.NumberOfWorkers -lt 2) {
        Add-LocalFinding $rname $rid $rtype "Scale Out" "High" "Single worker instance" "Scale out to >=2 instances" ("Workers=" + $plan.NumberOfWorkers)
      }
      if (-not (Test-DiagnosticSetting -ResourceId $rid)) {
        Add-LocalFinding $rname $rid $rtype "Diagnostics" "Medium" "No diagnostic settings" "Enable App Service Plan diagnostics" "Diagnostics=disabled"
      }
    }
    $apps = Get-AzWebApp -ErrorAction SilentlyContinue
    foreach ($app in $apps) {
      $rid=$app.Id; $rname=$app.Name; $rtype="Microsoft.Web/sites"
      if (-not $app.SiteConfig.AlwaysOn) {
        Add-LocalFinding $rname $rid $rtype "Always On" "Medium" "Always On disabled" "Enable Always On for production apps" "AlwaysOn=false"
      }
      if (-not (Test-DiagnosticSetting -ResourceId $rid)) {
        Add-LocalFinding $rname $rid $rtype "Diagnostics" "Medium" "No diagnostic settings" "Enable Web App diagnostics" "Diagnostics=disabled"
      }
    }

    # Load Balancers
    $lbs = Get-AzLoadBalancer -ErrorAction SilentlyContinue
    foreach ($lb in $lbs) {
      $rid=$lb.Id; $rname=$lb.Name; $rtype="Microsoft.Network/loadBalancers"
      if ($lb.Sku.Name -eq "Basic") {
        Add-LocalFinding $rname $rid $rtype "SKU" "High" "Basic Load Balancer in use" "Migrate to Standard Load Balancer" "SKU=Basic"
      }
      if (-not (Test-DiagnosticSetting -ResourceId $rid)) {
        Add-LocalFinding $rname $rid $rtype "Diagnostics" "Medium" "No diagnostic settings" "Enable LB diagnostics" "Diagnostics=disabled"
      }
    }

    # VPN / ER Gateways
    $gws=@();$rgs=Get-AzResourceGroup -ErrorAction SilentlyContinue
    foreach ($rg in $rgs){$tmp=Get-AzVirtualNetworkGateway -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue;if($tmp){$gws+=$tmp}}
    foreach ($gw in $gws) {
      $rid=$gw.Id; $rname=$gw.Name; $rtype="Microsoft.Network/virtualNetworkGateways"
      if ($gw.GatewayType -eq "Vpn" -and -not $gw.ActiveActive) {
        Add-LocalFinding $rname $rid $rtype "Active-Active" "High" "VPN Gateway not Active-Active" "Enable Active-Active" ("ActiveActive=" + $gw.ActiveActive)
      }
      if (-not (Test-DiagnosticSetting -ResourceId $rid)) {
        Add-LocalFinding $rname $rid $rtype "Diagnostics" "Medium" "No diagnostic settings" "Enable gateway diagnostics" "Diagnostics=disabled"
      }
    }

    # Recovery Services Vaults (policy-only, non-interactive)
    $vaults = Get-AzRecoveryServicesVault -ErrorAction SilentlyContinue
    foreach ($vault in $vaults) {
      $rid=$vault.ID; $rname=$vault.Name; $rtype="Microsoft.RecoveryServices/vaults"
      try { Set-AzRecoveryServicesVaultContext -Vault $vault -ErrorAction Stop } catch {}

      # Policies presence (signals backup readiness without item/container prompts)
      $polCount = 0
      try { $pols = Get-AzRecoveryServicesBackupProtectionPolicy -VaultId $vault.ID -ErrorAction SilentlyContinue; if ($pols) { $polCount = @($pols).Count } } catch {}
      if ($polCount -eq 0) {
        Add-LocalFinding $rname $rid $rtype "Backup Policies" "High" "No backup protection policies found" "Create and assign appropriate backup policies" "Policies=0"
      }

      if (-not (Test-DiagnosticSetting -ResourceId $rid)) {
        Add-LocalFinding $rname $rid $rtype "Diagnostics" "Medium" "No diagnostic settings" "Enable vault diagnostics" "Diagnostics=disabled"
      }
    }

    # AKS
    $clusters = Get-AzAksCluster -ErrorAction SilentlyContinue
    foreach ($aks in $clusters) {
      $rid=$aks.Id; $rname=$aks.Name; $rtype="Microsoft.ContainerService/managedClusters"
      $pools = $aks.AgentPoolProfiles
      if (-not $pools) {
        Add-LocalFinding $rname $rid $rtype "Agent Pools" "High" "No agent pools found" "Ensure dedicated system and user pools exist" "AgentPools=0"
        continue
      }
      $systemPools = @($pools | Where-Object { $_.Mode -eq "System" })
      if ($systemPools.Count -lt 1) {
        Add-LocalFinding $rname $rid $rtype "System Pool" "High" "No dedicated system node pool" "Create a dedicated system node pool" "SystemPools=0"
      }
      foreach ($p in $pools) {
        if (-not $p.AvailabilityZones -or $p.AvailabilityZones.Count -lt 2) {
          Add-LocalFinding $rname $rid $rtype ("Zone Coverage (Pool:" + $p.Name + ")") "High" "Agent pool not zone-redundant" "Enable Availability Zones on pools" ("Zones=" + (($p.AvailabilityZones) -join ","))
        }
      }
      $isPrivate = $false
      if ($aks.ApiServerAccessProfile -and $aks.ApiServerAccessProfile.EnablePrivateCluster) { $isPrivate = $true }
      if (-not $isPrivate) {
        Add-LocalFinding $rname $rid $rtype "API Exposure" "Medium" "Public API server endpoint" "Prefer Private Cluster or authorized IP ranges" "PrivateCluster=false"
      }
      if (-not (Test-DiagnosticSetting -ResourceId $rid)) {
        Add-LocalFinding $rname $rid $rtype "Diagnostics" "Medium" "No diagnostic settings" "Enable AKS diagnostic categories" "Diagnostics=disabled"
      }
    }

    # Redis
    $redises = Get-AzRedisCache -ErrorAction SilentlyContinue
    foreach ($rc in $redises) {
      $rid=$rc.Id; $rname=$rc.Name; $rtype="Microsoft.Cache/Redis"
      $isZoneRedundant = $false
      try { if ($rc.Zones -and $rc.Zones.Count -ge 2) { $isZoneRedundant = $true } } catch {}
      try { if ($rc.ZoneRedundant) { $isZoneRedundant = $true } } catch {}
      if (-not $isZoneRedundant) {
        Add-LocalFinding $rname $rid $rtype "Zone Redundancy" "High" "Redis not zone-redundant" "Deploy Premium/Enterprise with zone redundancy" ("Zones?=" + (($rc.Zones) -join ","))
      }
      if (-not (Test-DiagnosticSetting -ResourceId $rid)) {
        Add-LocalFinding $rname $rid $rtype "Diagnostics" "Medium" "No diagnostic settings" "Enable Redis diagnostics" "Diagnostics=disabled"
      }
    }

    # Application Gateways
    $agws=@();$rgs=Get-AzResourceGroup -ErrorAction SilentlyContinue
    foreach ($rg in $rgs){$tmp=Get-AzApplicationGateway -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue;if($tmp){$agws+=$tmp}}
    foreach ($ag in $agws) {
      $rid=$ag.Id; $rname=$ag.Name; $rtype="Microsoft.Network/applicationGateways"
      $tier = $ag.Sku.Tier
      if ($tier -notmatch "Standard_v2|WAF_v2") {
        Add-LocalFinding $rname $rid $rtype "SKU" "High" "App Gateway not v2 SKU" "Migrate to Standard_v2/WAF_v2 for HA and autoscaling" ("SKU=" + $tier)
      }
      if (-not (Test-DiagnosticSetting -ResourceId $rid)) {
        Add-LocalFinding $rname $rid $rtype "Diagnostics" "Medium" "No diagnostic settings" "Enable AppGW diagnostics" "Diagnostics=disabled"
      }
    }

    # Front Door (CDN Profiles)
    $fdProfiles = Get-AzResource -ResourceType "Microsoft.Cdn/profiles" -ErrorAction SilentlyContinue
    foreach ($p in $fdProfiles) {
      $rid=$p.ResourceId; $rname=$p.Name; $rtype="Microsoft.Cdn/profiles"
      if ($p.Sku -and ($p.Sku.Name -notmatch "AzureFrontDoor")) {
        Add-LocalFinding $rname $rid $rtype "SKU" "Medium" "Profile not Front Door SKU" "Use Standard_AzureFrontDoor or Premium_AzureFrontDoor" ("SKU=" + $p.Sku.Name)
      }
      if (-not (Test-DiagnosticSetting -ResourceId $rid)) {
        Add-LocalFinding $rname $rid $rtype "Diagnostics" "Medium" "No diagnostic settings" "Enable diagnostics for Front Door profile" "Diagnostics=disabled"
      }
    }

    # Public IPs
    $pips = Get-AzPublicIpAddress -ErrorAction SilentlyContinue
    foreach ($pip in $pips) {
      $rid=$pip.Id; $rname=$pip.Name; $rtype="Microsoft.Network/publicIPAddresses"
      if ($pip.Sku.Name -eq "Basic") {
        Add-LocalFinding $rname $rid $rtype "SKU" "High" "Basic Public IP in use" "Migrate to Standard Public IP" "SKU=Basic"
      }
      $zoneCount = 0; try { if ($pip.Zones) { $zoneCount = $pip.Zones.Count } } catch {}
      if ($zoneCount -lt 1 -and $pip.Sku.Name -eq "Standard") {
        Add-LocalFinding $rname $rid $rtype "Zone Redundancy" "Medium" "Public IP not zonal/zone-redundant" "Use zonal/zone-redundant Standard Public IPs" ("Zones=" + $zoneCount)
      }
      # Diagnostics on Public IPs are informational (not always supported)
      if (-not (Test-DiagnosticSetting -ResourceId $rid)) {
        Add-LocalFinding $rname $rid $rtype "Diagnostics" "Low" "No diagnostic settings" "Enable diagnostics if supported/required" "Diagnostics=disabled"
      }
    }

    # Azure Firewalls
    $fws=@();$rgs=Get-AzResourceGroup -ErrorAction SilentlyContinue
    foreach ($rg in $rgs){$tmp=Get-AzFirewall -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue;if($tmp){$fws+=$tmp}}
    foreach ($fw in $fws) {
      $rid=$fw.Id; $rname=$fw.Name; $rtype="Microsoft.Network/azureFirewalls"
      $zonesPresent=$false; try { if ($fw.Zones -and $fw.Zones.Count -ge 2) { $zonesPresent = $true } } catch {}
      if (-not $zonesPresent) {
        Add-LocalFinding $rname $rid $rtype "Zone Redundancy" "High" "Firewall not deployed across zones" "Deploy Azure Firewall with Availability Zones" ("Zones=" + (($fw.Zones) -join ","))
      }
      $ti=$fw.ThreatIntelMode
      if ($ti -eq "Off") {
        Add-LocalFinding $rname $rid $rtype "Threat Intel" "Medium" "Threat Intelligence mode is Off" "Set ThreatIntelMode to Alert or Deny" "ThreatIntelMode=Off"
      }
      if (-not (Test-DiagnosticSetting -ResourceId $rid)) {
        Add-LocalFinding $rname $rid $rtype "Diagnostics" "Medium" "No diagnostic settings" "Enable Firewall diagnostics" "Diagnostics=disabled"
      }
    }

    # Virtual WAN / Virtual Hubs
    $vwans=@();$hubs=@();$rgs=Get-AzResourceGroup -ErrorAction SilentlyContinue
    foreach ($rg in $rgs){$tmp=Get-AzVirtualWan -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue;if($tmp){$vwans+=$tmp}}
    foreach ($rg in $rgs){$tmp=Get-AzVirtualHub -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue;if($tmp){$hubs+=$tmp}}
    foreach ($vwan in $vwans){
      $rid=$vwan.Id;$rname=$vwan.Name;$rtype="Microsoft.Network/virtualWans"
      if(-not (Test-DiagnosticSetting -ResourceId $rid)){
        Add-LocalFinding $rname $rid $rtype "Diagnostics" "Medium" "No diagnostic settings" "Enable diagnostics for VWAN" "Diagnostics=disabled"
      }
    }
    foreach ($hub in $hubs){
      $rid=$hub.Id;$rname=$hub.Name;$rtype="Microsoft.Network/virtualHubs"
      if(-not (Test-DiagnosticSetting -ResourceId $rid)){
        Add-LocalFinding $rname $rid $rtype "Diagnostics" "Medium" "No diagnostic settings" "Enable diagnostics for Virtual Hub" "Diagnostics=disabled"
      }
      $rtCount=0; try { if($hub.RouteTables -and $hub.RouteTables.Count -ge 1){ $rtCount=$hub.RouteTables.Count } } catch {}
      if($rtCount -lt 1){
        Add-LocalFinding $rname $rid $rtype "Routing Tables" "Low" "No user-defined route tables found" "Review vHub routing and define route tables as needed" ("RouteTables=" + $rtCount)
      }
    }
  } catch {
    Write-Warning "Resource checks failed for ${SubId}: $($_.Exception.Message)"
  }

  # 4d) Auto-WARA (Reliability): REST-first with graceful fallback to curated guidance
  Write-Host "Running WARA Reliability for ${SubId} (auto)..."
  $waraMergedCount = 0
  try {
    $token = (Get-AzAccessToken -Resource "https://management.azure.com/").Token
    $apiVersions = @("2023-10-01-preview","2023-06-01-preview","2022-12-01-preview")
    $endpoints = @(
      ("https://management.azure.com/subscriptions/{0}/providers/Microsoft.WellArchitected/recommendations?api-version={1}"),
      ("https://management.azure.com/providers/Microsoft.WellArchitected/recommendations?api-version={1}")
    )

    $waraItems = @()
    :outer foreach ($ver in $apiVersions) {
      foreach ($tpl in $endpoints) {
        $uri = [string]::Format($tpl, $SubId, $ver)
        try {
          $resp = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $token" } -Method GET -ErrorAction Stop
          if ($resp -and $resp.value) { $waraItems = $resp.value; break outer }
        } catch {}
      }
    }

    if ($waraItems -and $waraItems.Count -gt 0) {
      foreach ($item in $waraItems) {
        $title = $item.title; if (-not $title) { $title = $item.questionTitle }
        $rec   = $item.recommendation; if (-not $rec) { $rec = $item.recommendationText }
        $pillar= $item.pillar; if (-not $pillar) { $pillar = "Reliability" }
        $id    = $item.name; if (-not $id) { $id = $item.id }
        $cat   = $item.category
        Add-LocalFinding ("(WARA Pillar: " + $pillar + ")") "" "WellArchitected" ("WARA:" + $pillar) "Medium" $title $rec ("Category=" + $cat + "; Id=" + $id) $pillar
        $waraMergedCount++
      }
      Write-Host "WARA merged for ${SubId}: $waraMergedCount item(s)."
    } else {
      throw "No WARA items returned."
    }
  } catch {
    Write-Warning "WARA API not available for ${SubId}. Using fallback."
    $fallback = @(
      @{ Q="Define and test RTO/RPO for critical workloads"; R="Document RTO/RPO and validate through DR tests."; C="BCDR" },
      @{ Q="Multi-AZ or equivalent for critical components"; R="Deploy across zones/regions to remove single-zone failure."; C="HighAvailability" },
      @{ Q="Automated backups, retention, and restoration testing"; R="Enable backups and schedule restore drills."; C="DataProtection" },
      @{ Q="Health probes and graceful failover paths"; R="Use health probes and implement connection draining and retries."; C="FaultIsolation" },
      @{ Q="Autoscaling or headroom for expected bursts"; R="Configure autoscale or maintain capacity buffers."; C="Capacity" },
      @{ Q="Runbooks and alerts for failure modes"; R="Create runbooks and wire alerts for key failure patterns."; C="Ops" }
    )
    foreach ($f in $fallback) {
      Add-LocalFinding "(WARA Pillar: Reliability)" "" "WellArchitected" "WARA:Reliability" "Medium" $f.Q $f.R ("Category=" + $f.C) "Reliability"
    }
  }

  # 4e) Emit per-subscription CSV (unless disabled)
  if (-not $NoPerSubFiles) {
    $perCsv = Join-Path $tsDir ("{0}-Resiliency.csv" -f $SubId)
    if ($Findings.Count -gt 0) {
      $Findings | Sort-Object ResourceType, ResourceName, Check | Export-Csv -NoTypeInformation -Path $perCsv
      Write-Host "Per-subscription CSV: $perCsv"
    } else {
      Write-Warning "No findings for ${SubId}. No CSV emitted."
    }
  }

  # 4f) Per-subscription summary
  Write-Host "Summary for ${SubId}:"
  foreach ($k in $Summary.Keys) { Write-Host (" {0,-50} {1,5}" -f $k,$Summary[$k]) }
}

# -----------------------------------------------------------------------------
# 5) Execute across all subscriptions
# -----------------------------------------------------------------------------
Write-Host "Found $($subs.Count) subscription(s) in $SubListPath."
foreach ($sid in $subs) {
  Invoke-ResiliencyRunForSubscription -SubId $sid
}

# -----------------------------------------------------------------------------
# 6) Export combined outputs and print a global summary
# -----------------------------------------------------------------------------
if ($AllFindings.Count -gt 0) {
  $AllFindings | Sort-Object SubscriptionId, ResourceType, ResourceName, Check | Export-Csv -NoTypeInformation -Path $rootCsv
  $AllFindings | ConvertTo-Json -Depth 8 | Out-File $rootJson -Force
  Write-Host ""
  Write-Host "Completed all subscriptions: $($AllFindings.Count) total findings."
  Write-Host "All-Subs CSV:  $rootCsv"
  Write-Host "All-Subs JSON: $rootJson"
} else {
  Write-Warning ""
  Write-Warning "No findings collected across any subscription."
}

Write-Host ""
Write-Host "Global Summary (by Resource Type):"
foreach ($k in $AllSummary.Keys) { Write-Host (" {0,-50} {1,5}" -f $k,$AllSummary[$k]) }
Write-Host ""
Write-Host "All tasks completed successfully."
