#Requires -Version 5.1
# =============================================================================
# Secure RDP v0.823 - RDPCheckModules\FirewallReadWriteElements.psm1
# GitHub: arekfurt/SecureRDP
#
# Generic Windows Firewall read and write module.
# No RDP-specific logic. No classification. No assessment.
# This is the only module in the project that calls Windows Firewall cmdlets.
#
# Exported functions:
#   Get-FirewallRawData        - retrieves all enabled inbound rules plus
#                                active profile names, port filters, and
#                                address filters; used by FirewallAssessor
#   New-FirewallRules          - creates one or more firewall rules from
#                                caller-supplied descriptors; idempotent
#   Remove-FirewallRulesByName - removes firewall rules by name array;
#                                non-fatal if a named rule does not exist
#   Test-FirewallRulesExist    - returns true if all named rules exist
#
# Import order requirement:
#   This module must be imported before FirewallVerdict.psm1 (which calls
#   Get-FirewallRawData via Get-PortFirewallStatus) and before any module
#   that calls New-FirewallRules or Remove-FirewallRulesByName.
# =============================================================================
Set-StrictMode -Version Latest
Import-Module NetSecurity -ErrorAction SilentlyContinue

# =============================================================================
# Get-FirewallRawData
#
# Queries Windows Firewall for all enabled inbound rules and the currently
# active connection profiles. Returns a single hashtable containing everything
# FirewallAssessor.psm1 needs to perform an assessment.
#
# Returns:
#   @{
#     ActiveProfiles = string[]    -- e.g. @('Private','Public')
#     Rules          = object[]    -- all enabled inbound NetFirewallRule objects
#     PortFilters    = hashtable   -- InstanceID -> NetFirewallPortFilter object
#     AddressFilters = hashtable   -- InstanceID -> NetFirewallAddressFilter object
#   }
# or 'error:...' on failure.
#
# Notes:
#   - All enabled inbound rules are returned regardless of action.
#     Filtering by action is the assessor's responsibility.
#   - If no active profile is detected, 'Public' is assumed (safe default).
#   - DomainAuthenticated is normalised to 'Domain' to match firewall profile
#     bitmask naming used by the assessor.
# =============================================================================
function Get-FirewallRawData {
    try {
        $activeProfiles = @(
            Get-NetConnectionProfile -ErrorAction SilentlyContinue |
            ForEach-Object {
                $cat = $_.NetworkCategory.ToString()
                if ($cat -eq 'DomainAuthenticated') { 'Domain' } else { $cat }
            }
        )
        if ($activeProfiles.Count -eq 0) { $activeProfiles = @('Public') }

        $rules = @(Get-NetFirewallRule -Direction Inbound -Enabled True -ErrorAction SilentlyContinue)

        $portFilters = @{}
        Get-NetFirewallPortFilter -ErrorAction SilentlyContinue |
            ForEach-Object { $portFilters[$_.InstanceID] = $_ }

        $addressFilters = @{}
        Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue |
            ForEach-Object { $addressFilters[$_.InstanceID] = $_ }

        return @{
            ActiveProfiles = $activeProfiles
            Rules          = $rules
            PortFilters    = $portFilters
            AddressFilters = $addressFilters
        }
    }
    catch {
        return "error:$($_.Exception.Message)"
    }
}

# =============================================================================
# New-FirewallRules
#
# Creates Windows Firewall rules from an array of rule descriptor hashtables.
# Any existing rule with the same Name is removed first (idempotent).
#
# Parameters:
#   RuleDefinitions - array of hashtables, each describing one rule.
#                     Required keys: Name, DisplayName, Direction, Protocol,
#                                    LocalPort, Action
#                     Optional keys: RemoteAddress (string[]), Description,
#                                    Profile (default: Any)
#
# Returns $true on success, or 'error:...' on failure.
#
# Example rule descriptor:
#   @{
#     Name          = 'MyApp-SSH-Inbound'
#     DisplayName   = 'MyApp SSH Inbound'
#     Direction     = 'Inbound'
#     Protocol      = 'TCP'
#     LocalPort     = 2222
#     Action        = 'Allow'
#     RemoteAddress = @('192.168.1.0/24')
#     Description   = 'SSH access for MyApp'
#   }
# =============================================================================
function New-FirewallRules {
    param(
        [Parameter(Mandatory)][object[]]$RuleDefinitions
    )
    try {
        foreach ($def in $RuleDefinitions) {
            # Remove existing rule with this name if present (idempotent)
            Remove-NetFirewallRule -Name $def.Name -ErrorAction SilentlyContinue

            $params = @{
                Name        = $def.Name
                DisplayName = $def.DisplayName
                Direction   = $def.Direction
                Protocol    = $def.Protocol
                LocalPort   = $def.LocalPort
                Action      = $def.Action
                Enabled     = 'True'
                ErrorAction = 'Stop'
            }
            if ($def.ContainsKey('RemoteAddress') -and $null -ne $def.RemoteAddress) {
                $params.RemoteAddress = $def.RemoteAddress
            }
            if ($def.ContainsKey('Description') -and $null -ne $def.Description) {
                $params.Description = $def.Description
            }
            if ($def.ContainsKey('Profile') -and $null -ne $def.Profile) {
                $params.Profile = $def.Profile
            }

            New-NetFirewallRule @params | Out-Null
        }
        return $true
    }
    catch {
        $errMsg = $_.Exception.Message
        try { Write-SrdpLog "Firewall rule creation failed: $errMsg" -Level ERROR -Component 'FWReadWrite' } catch {}
        return "error:Firewall rule creation failed: $errMsg"
    }
}

# =============================================================================
# Remove-FirewallRulesByName
#
# Removes Windows Firewall rules by name. Non-fatal if a named rule does
# not exist -- the goal is absence, not presence. Errors from rules that
# do exist but fail to be removed are collected and returned.
#
# Parameters:
#   Names - string[] of rule InstanceID/Name values to remove
#
# Returns $true if all removals succeeded (including rules that were already
# absent). Returns 'error:...' if one or more removals failed.
# =============================================================================
function Remove-FirewallRulesByName {
    param(
        [Parameter(Mandatory)][string[]]$Names
    )
    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $Names) {
        # Check existence first so we can distinguish "not found" from "failed to remove"
        $exists = @(Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue)
        if ($exists.Count -eq 0) { continue }
        try {
            Remove-NetFirewallRule -Name $name -ErrorAction Stop
        }
        catch {
            $errMsg = $_.Exception.Message
            $errors.Add("Could not remove rule '$name': $errMsg")
            try { Write-SrdpLog "Could not remove FW rule '$name': $errMsg" -Level ERROR -Component 'FWReadWrite' } catch {}
        }
    }
    if ($errors.Count -gt 0) { return "error:$($errors -join '; ')" }
    return $true
}

# =============================================================================
# Test-FirewallRulesExist
#
# Returns $true if every named rule exists (is present, regardless of
# enabled/disabled state). Returns $false if any are missing.
#
# Parameters:
#   Names - string[] of rule InstanceID/Name values to check
# =============================================================================
function Test-FirewallRulesExist {
    param(
        [Parameter(Mandatory)][string[]]$Names
    )
    foreach ($name in $Names) {
        $found = @(Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue)
        if ($found.Count -eq 0) { return $false }
    }
    return $true
}

Export-ModuleMember -Function @(
    'Get-FirewallRawData',
    'New-FirewallRules',
    'Remove-FirewallRulesByName',
    'Test-FirewallRulesExist'
)
