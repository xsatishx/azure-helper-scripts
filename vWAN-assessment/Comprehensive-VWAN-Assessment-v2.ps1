<#
.SYNOPSIS
    Comprehensive VWAN Assessment v1.1

.DESCRIPTION
    Author : Satish Balakrishnan <satishbal@microsoft.com>

    This script performs a comprehensive end-to-end assessment of Azure Virtual WAN
    environments to validate configuration consistency, security alignment, and
    operational readiness across all associated Virtual Hubs.

    The assessment collects configuration details and relationships between VWAN, vHubs,
    VNets, Route Tables, Effective Routes, Azure Firewalls (managed and standalone),
    Firewall Policies (tier, RCGs), Diagnostic settings, Routing Intent, and vHub Gateway resources
    (VPN Gateway, ExpressRoute Gateway, and P2S VPN Gateway).

    v2 adds the following
     - Added discovery of VPN, ExpressRoute, and P2S VPN Gateways per hub.
     - Integrated Routing Intent capture (where explicitly configured).
     - Enhanced Firewall details — includes Policy Tier, Threat Intelligence Mode, and Rule Collection Groups.
#>

Write-Host ""
Write-Host "=== Comprehensive VWAN Assessment v1.1 ==="
Write-Host ""

# Auto-install missing CLI extensions silently
az config set extension.use_dynamic_install=yes_without_prompt | Out-Null

# Suppress noisy Python warnings from Azure CLI extensions
$env:PYTHONWARNINGS = "ignore"

# ---------- Inputs ----------
$subscriptionId = Read-Host "Enter Azure Subscription ID (leave blank to use current CLI session)"
if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
    $subscriptionId = (az account show --query "id" -o tsv)
    if (-not $subscriptionId) {
        Write-Error "No active Azure CLI session found. Run 'az login' first."
        exit 1
    }
    Write-Host "Using active subscription: $subscriptionId"
} else {
    Write-Host "Switching to subscription: $subscriptionId"
    az account set --subscription $subscriptionId | Out-Null
}

$vwanFilter = Read-Host "Enter a specific Virtual WAN name to audit (press Enter for all VWANs)"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$outputFile = "ComprehensiveVWANAssessment-v1.1-$timestamp.json"

# ---------- Helpers ----------
function Test-IsJson {
    param([string]$text)
    if (-not $text) { return $false }
    $trim = $text.TrimStart()
    if (-not $trim) { return $false }
    return ($trim[0] -in @('{','['))
}

function Convert-FromJsonSafe {
    param([string]$text)
    if (Test-IsJson $text) { return ($text | ConvertFrom-Json) }
    return $null
}

# ---------- Diagnostics ----------
function Get-Diagnostics {
    param([string]$ResourceId)
    try {
        $raw = az monitor diagnostic-settings list --resource $ResourceId 2>$null
        $diag = Convert-FromJsonSafe $raw
        if ($diag -and $diag.value) {
            return $diag.value | ForEach-Object {
                [PSCustomObject]@{
                    Name         = $_.name
                    Metrics      = ($_.metrics | ForEach-Object { $_.category })
                    Logs         = ($_.logs | ForEach-Object { $_.category })
                    Destinations = @($_.workspaceId, $_.storageAccountId, $_.eventHubAuthorizationRuleId) | Where-Object { $_ }
                }
            }
        } else {
            return @("No diagnostics configured")
        }
    } catch {
        return @("Diagnostics error: $_")
    }
}

# ---------- Effective Routes ----------
function Get-EffectiveRoutes {
    param([string]$VHubId)
    try {
        $uri = "https://management.azure.com$VHubId/getEffectiveRoutes?api-version=2023-09-01"
        $raw = az rest --method post --uri $uri --output json 2>$null
        $er = Convert-FromJsonSafe $raw
        if ($er -and $er.value) {
            return $er.value | ForEach-Object {
                [PSCustomObject]@{
                    AddressPrefixes = $_.addressPrefixes
                    NextHopType     = $_.nextHopType
                    NextHop         = $_.nextHop
                    Source          = $_.source
                }
            }
        } else {
            return @("No effective routes returned")
        }
    } catch {
        return @("Effective routes error: $_")
    }
}

# ---------- Firewall Details ----------
function Get-FirewallDetails {
    param(
        [string]$FirewallId,
        [string]$FirewallName,
        [string]$ResourceGroup
    )
    try {
        $raw = $null
        if ($FirewallId) {
            $raw = az network firewall show --ids $FirewallId 2>$null
        } elseif ($FirewallName -and $ResourceGroup) {
            $raw = az network firewall show --name $FirewallName --resource-group $ResourceGroup 2>$null
        }
        $fw = Convert-FromJsonSafe $raw
        if (-not $fw) { return @("Firewall not found or invalid response") }

        $policy      = $null
        $policyName  = $null
        $policyRg    = $null
        if ($fw.firewallPolicy -and $fw.firewallPolicy.id) {
            $praw = az network firewall policy show --ids $fw.firewallPolicy.id 2>$null
            $policy = Convert-FromJsonSafe $praw
            if ($policy) { $policyName = $policy.name; $policyRg = $policy.resourceGroup }
        }

        $rcgs = @()
        if ($policy -and $policyName -and $policyRg) {
            $rcgRaw = az network firewall policy rule-collection-group list --policy-name $policyName --resource-group $policyRg 2>$null
            $rcg = Convert-FromJsonSafe $rcgRaw
            if ($rcg) { $rcgs = @($rcg | ForEach-Object { $_.name }) }
        }

        return [PSCustomObject]@{
            Id                   = $fw.id
            Name                 = $fw.name
            SKU                  = $fw.sku.tier
            ThreatIntelMode      = $fw.threatIntelMode
            PolicyId             = if ($policy) { $policy.id } else { $fw.firewallPolicy.id }
            PolicyTier           = if ($policy -and $policy.sku) { $policy.sku.tier } else { $null }
            RuleCollectionGroups = $rcgs
            PublicIPs            = ($fw.ipConfigurations | ForEach-Object { $_.publicIpAddress.id })
            PrivateIPs           = ($fw.ipConfigurations | ForEach-Object { $_.privateIpAddress })
            Diagnostics          = Get-Diagnostics -ResourceId $fw.id
        }
    } catch {
        return @("Firewall retrieval error: $_")
    }
}

# ---------- Route Tables ----------
function Get-VHubRouteTables {
    param([string]$VHubName, [string]$ResourceGroup)
    try {
        $listRaw = az network vhub route-table list --resource-group $ResourceGroup --vhub-name $VHubName 2>$null
        $list = Convert-FromJsonSafe $listRaw
        if (-not $list) { return @("No route tables found or invalid response") }

        $results = @()
        foreach ($rt in $list) {
            $showRaw = az network vhub route-table show --resource-group $ResourceGroup --vhub-name $VHubName --name $rt.name 2>$null
            $show = Convert-FromJsonSafe $showRaw
            if ($show) {
                $routes = @()
                foreach ($r in ($show.routes)) {
                    $routes += [PSCustomObject]@{
                        AddressPrefixes   = $r.addressPrefixes
                        NextHopType       = $r.nextHopType
                        NextHopResourceId = $r.nextHop
                    }
                }
                $results += [PSCustomObject]@{
                    Name   = $show.name
                    Labels = $show.labels
                    Routes = $routes
                }
            } else {
                $results += [PSCustomObject]@{
                    Name   = $rt.name
                    Labels = $rt.labels
                    Routes = @("Unable to expand route details")
                }
            }
        }
        return $results
    } catch {
        return @("Route table retrieval error: $_")
    }
}

# ---------- Connected VNets ----------
function Get-ConnectedVnets {
    param([string]$VHubName, [string]$ResourceGroup)
    try {
        $raw = az network vhub connection list --resource-group $ResourceGroup --vhub-name $VHubName 2>$null
        $cons = Convert-FromJsonSafe $raw
        if ($cons) {
            return $cons | ForEach-Object { $_.remoteVirtualNetwork.id }
        } else {
            return @("No VNet connections found")
        }
    } catch {
        return @("Error retrieving VNet connections: $_")
    }
}

# ---------- Firewall Discovery (triple-fallback) ----------
function Find-FirewallsForHub {
    param(
        [string]$VHubId,
        [string]$VHubName,
        [array]$RouteTables
    )
    $found = @()

    try {
        $fwAssocRaw = az network firewall list --query "[?contains(hub.id, '$VHubId')]" 2>$null
        $fwAssoc = Convert-FromJsonSafe $fwAssocRaw
        if ($fwAssoc -and ($fwAssoc | Measure-Object).Count -gt 0) {
            $found += ($fwAssoc | ForEach-Object { $_.id })
        }
    } catch {}

    if (-not $found -or $found.Count -eq 0) {
        try {
            $expectedName = "AzureFirewall_$VHubName"
            $fwByNameRaw = az network firewall list --query "[?name=='$expectedName']" 2>$null
            $fwByName = Convert-FromJsonSafe $fwByNameRaw
            if ($fwByName -and ($fwByName | Measure-Object).Count -gt 0) {
                $found += ($fwByName | ForEach-Object { $_.id })
            }
        } catch {}
    }

    if (-not $found -or $found.Count -eq 0) {
        try {
            $ids = @()
            foreach ($rt in $RouteTables) {
                if ($rt -and $rt.Routes) {
                    foreach ($r in $rt.Routes) {
                        if ($r -and $r.NextHopResourceId -and ($r.NextHopResourceId -match "Microsoft.Network/azureFirewalls")) {
                            $ids += $r.NextHopResourceId
                        }
                    }
                }
            }
            if ($ids.Count -gt 0) {
                $found += ($ids | Select-Object -Unique)
            }
        } catch {}
    }

    return ($found | Select-Object -Unique)
}

# ---------- Main ----------
Write-Host ""
Write-Host "Collecting Virtual WANs in Subscription: $subscriptionId"
Write-Host ""

if ([string]::IsNullOrWhiteSpace($vwanFilter)) {
    $vWANs = az network vwan list --query "[].{Name:name, Id:id, ResourceGroup:resourceGroup, Location:location}" | ConvertFrom-Json
} else {
    $vWANs = az network vwan list --query "[?name=='$vwanFilter'].{Name:name, Id:id, ResourceGroup:resourceGroup, Location:location}" | ConvertFrom-Json
}

if (-not $vWANs) {
    Write-Warning "No Virtual WANs found for this filter."
    exit 0
}

$globalReport = @()

foreach ($vwan in $vWANs) {
    Write-Host ""
    Write-Host "Processing VWAN: $($vwan.Name) ($($vwan.Location))"
    Write-Host ""
    $vHubList = az network vhub list --query "[?virtualWan.id=='$($vwan.Id)']" | ConvertFrom-Json
    if (-not $vHubList) {
        Write-Warning "No Virtual Hubs found under VWAN $($vwan.Name)"
        continue
    }

    $hubReport = @()

    foreach ($vhub in $vHubList) {
        Write-Host "   Collecting data for vHub: $($vhub.name)"
        $vHubData = @()

        $vHubRaw = az network vhub show --name $vhub.name --resource-group $vhub.resourceGroup 2>$null
        $vHubDetails = Convert-FromJsonSafe $vHubRaw
        if (-not $vHubDetails) {
            Write-Warning "vHub $($vhub.name) returned non-JSON output or not found."
            continue
        }

        $vHubData = @{
            Location          = $vHubDetails.location
            RoutingPreference = if ($vHubDetails.routingPreference) { $vHubDetails.routingPreference } elseif ($vHubDetails.routingConfiguration -and $vHubDetails.routingConfiguration.routingPreference) { $vHubDetails.routingConfiguration.routingPreference } elseif ($vHubDetails.routingState) { $vHubDetails.routingState } else { "Not specified" }
            ConnectedVNets    = Get-ConnectedVnets -VHubName $vhub.name -ResourceGroup $vhub.resourceGroup
            RouteTables       = Get-VHubRouteTables -VHubName $vhub.name -ResourceGroup $vhub.resourceGroup
            EffectiveRoutes   = Get-EffectiveRoutes -VHubId $vhub.id
            Diagnostics       = Get-Diagnostics -ResourceId $vhub.id
        }

        # Routing Intent
        try {
            $routingIntentRaw = az network vhub routing-intent show --resource-group $vhub.resourceGroup --vhub-name $vhub.name 2>$null
            $vHubData["RoutingIntent"] = Convert-FromJsonSafe $routingIntentRaw
        } catch {
            $vHubData["RoutingIntent"] = "Routing intent not found or unsupported in this region."
        }

        # Gateways
        try {
            $vpnGwRaw = az network vpn-gateway list --query "[?contains(virtualHub.id, '$($vhub.id)')]" 2>$null
            $vHubData["VpnGateways"] = Convert-FromJsonSafe $vpnGwRaw
        } catch {
            $vHubData["VpnGateways"] = "Error retrieving VPN gateways."
        }
        try {
            $erGwRaw = az network express-route-gateway list --query "[?contains(virtualHub.id, '$($vhub.id)')]" 2>$null
            $vHubData["ExpressRouteGateways"] = Convert-FromJsonSafe $erGwRaw
        } catch {
            $vHubData["ExpressRouteGateways"] = "Error retrieving ExpressRoute gateways."
        }
        try {
            $p2sGwRaw = az network p2s-vpn-gateway list --query "[?contains(virtualHub.id, '$($vhub.id)')]" 2>$null
            $vHubData["P2SVpnGateways"] = Convert-FromJsonSafe $p2sGwRaw
        } catch {
            $vHubData["P2SVpnGateways"] = "Error retrieving P2S VPN gateways."
        }

        # Firewalls
        $firewallIds = Find-FirewallsForHub -VHubId $vhub.id -VHubName $vhub.name -RouteTables $vHubData["RouteTables"]
        $firewalls = @()
        if ($firewallIds -and $firewallIds.Count -gt 0) {
            foreach ($fid in $firewallIds) {
                $fwBlock = Get-FirewallDetails -FirewallId $fid
                $firewalls += $fwBlock
            }
        } else {
            $firewalls = @("No firewall associated with this hub")
        }
        $vHubData["Firewalls"] = $firewalls

        $hubReport += @{ ($vhub.name) = $vHubData }
    }

    $vwanDiag = Get-Diagnostics -ResourceId $vwan.Id

    $globalReport += @{
        ($vwan.Name) = [PSCustomObject]@{
            Location    = $vwan.Location
            Diagnostics = $vwanDiag
            Hubs        = $hubReport
        }
    }
}

# ---------- Output ----------
Write-Host ""
Write-Host "Writing Results to JSON File"
Write-Host ""
$globalReport | ConvertTo-Json -Depth 24 | Out-File $outputFile -Encoding utf8
Write-Host "Network audit completed. Output saved to: $outputFile"
