#Requires -Version 5.1
# =============================================================================
# Secure RDP v0.823 - RDPCheckModules\FirewallDataCollector.psm1
# GitHub: arekfurt/SecureRDP
#
# Generic Windows Firewall data retrieval module.
# No RDP-specific logic. No classification. No assessment.
# Returns raw firewall data structures for use by FirewallAssessor.psm1.
#
# Exported functions:
#   Get-FirewallRawData  - retrieves all enabled inbound rules plus active
#                          profile names, port filters, and address filters
#
# Import order requirement:
#   This module must be imported before FirewallVerdict.psm1, which calls
#   Get-FirewallRawData from its Get-PortFirewallStatus convenience wrapper.
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
#   - All enabled inbound rules are returned regardless of action (Allow or Block).
#     Filtering by action is the assessor's responsibility.
#   - If no active profile is detected, 'Public' is assumed (safe default).
#   - DomainAuthenticated is normalised to 'Domain' to match firewall profile
#     bitmask naming used by the assessor.
# =============================================================================
function Get-FirewallRawData {
    try {
        # Active profile detection
        $activeProfiles = @(
            Get-NetConnectionProfile -ErrorAction SilentlyContinue |
            ForEach-Object {
                $cat = $_.NetworkCategory.ToString()
                if ($cat -eq 'DomainAuthenticated') { 'Domain' } else { $cat }
            }
        )
        if ($activeProfiles.Count -eq 0) { $activeProfiles = @('Public') }

        # Bulk fetch all enabled inbound rules
        $rules = @(Get-NetFirewallRule -Direction Inbound -Enabled True -ErrorAction SilentlyContinue)

        # Port filters indexed by InstanceID for O(1) lookup in assessor
        $portFilters = @{}
        Get-NetFirewallPortFilter -ErrorAction SilentlyContinue |
            ForEach-Object { $portFilters[$_.InstanceID] = $_ }

        # Address filters indexed by InstanceID for O(1) lookup in assessor
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

Export-ModuleMember -Function @('Get-FirewallRawData')
