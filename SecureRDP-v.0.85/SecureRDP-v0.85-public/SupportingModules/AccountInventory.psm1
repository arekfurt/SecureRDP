#Requires -Version 5.1
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# AccountInventory.psm1
# SecureRDP - Windows Account Inventory
# Version 0.824
#
# Enumerates local and domain accounts that are members of RDP-relevant
# local groups, producing fully-qualified account name strings that work
# directly in RDP/CredSSP authentication without modification by the user.
#
# SCOPE:
#   Local accounts: fully enumerated via Get-LocalUser.
#   Domain accounts: enumerated only as they appear in the local RDP-relevant
#     groups via Get-LocalGroupMember. No AD queries are performed. This covers
#     all domain accounts that are actually RDP-eligible on this machine.
#
# RDP ELIGIBILITY:
#   An account is RDP-eligible if it is a direct member of either:
#     - BUILTIN\Administrators  (S-1-5-32-544)
#     - BUILTIN\Remote Desktop Users  (S-1-5-32-555)
#   Both groups are queried by well-known SID to avoid localization issues.
#
# FULLY-QUALIFIED NAME FORMAT:
#   Local accounts:  MACHINENAME\username
#   Domain accounts: DOMAIN\username  (as returned by Get-LocalGroupMember)
#
# NO GROUP DENESTING:
#   Only direct members of the two RDP groups are enumerated. Nested groups
#   are returned as group-type entries and their members are NOT expanded.
#
# ERROR CONTRACT:
#   Functions that can fail return "error:..." strings on failure.
#   Functions that return data return @{Result='ok'; ...} hashtables.
#   Module scope does NOT set $ErrorActionPreference = 'Stop'.
# ---------------------------------------------------------------------------

# Well-known SIDs for RDP-relevant groups -- localization-safe
$script:SidAdministrators    = 'S-1-5-32-544'
$script:SidRemoteDesktopUsers = 'S-1-5-32-555'

# ===========================================================================
# INTERNAL HELPERS
# ===========================================================================

function Get-LocalGroupBySid {
<#
.SYNOPSIS
    Returns the LocalGroup object for a well-known SID, localization-safe.
    Returns $null if the group is not found.
#>
    param([string]$Sid)

    try {
        $secId     = New-Object System.Security.Principal.SecurityIdentifier($Sid)
        $groupName = $secId.Translate([System.Security.Principal.NTAccount]).Value
        # groupName comes back as BUILTIN\Administrators -- strip the prefix
        $shortName = $groupName -replace '^[^\\]+\\', ''
        $group     = Get-LocalGroup -Name $shortName -ErrorAction SilentlyContinue
        return $group
    }
    catch {
        return $null
    }
}

function Get-MembersOfLocalGroupBySid {
<#
.SYNOPSIS
    Returns direct members of a local group identified by well-known SID.
    Returns an empty array on any error; errors are surfaced in the Error field.
#>
    param([string]$Sid)

    $result = @{ Members = @(); Error = $null; GroupName = '' }

    try {
        $group = Get-LocalGroupBySid -Sid $Sid
        if ($null -eq $group) {
            $result.Error = "Group with SID $Sid not found"
            return $result
        }

        $result.GroupName = $group.Name
        $members = @(Get-LocalGroupMember -Group $group.Name -ErrorAction SilentlyContinue)
        $result.Members = $members
    }
    catch {
        $result.Error = $_.Exception.Message
    }

    return $result
}

function Get-ComputerNetbiosName {
<#
.SYNOPSIS
    Returns the NETBIOS computer name in uppercase for use in fully-qualified
    local account names (MACHINENAME\username format).
#>
    try {
        return $env:COMPUTERNAME.ToUpper()
    }
    catch {
        return 'LOCALHOST'
    }
}

function Test-IsDomainJoined {
<#
.SYNOPSIS
    Returns $true if the machine is currently joined to a domain.
#>
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($null -eq $cs) { return $false }
        return ($cs.PartOfDomain -eq $true)
    }
    catch {
        return $false
    }
}

# ===========================================================================
# PRIMARY EXPORT
# ===========================================================================

function Get-SrdpAccountInventory {
<#
.SYNOPSIS
    Returns a full inventory of Windows accounts relevant to RDP access on
    this machine, with fully-qualified names ready for CredSSP authentication.

.DESCRIPTION
    Enumerates:
      - All local user accounts (via Get-LocalUser)
      - All direct members of BUILTIN\Administrators (by SID)
      - All direct members of BUILTIN\Remote Desktop Users (by SID)

    For each account the following fields are returned:
      QualifiedName   Fully-qualified name for use in mstsc/CredSSP:
                        Local:  MACHINENAME\username
                        Domain: DOMAIN\username (as provided by Windows)
      ShortName       Bare username without domain or machine prefix
      AccountType     'local' | 'domain' | 'group' (for nested group entries)
      IsEnabled       $true if account is enabled; $false if disabled or unknown
      InAdmins        $true if direct member of BUILTIN\Administrators
      InRdpUsers      $true if direct member of BUILTIN\Remote Desktop Users
      RdpEligible     $true if InAdmins or InRdpUsers (and account is enabled)
      Source          'local-enum' | 'group-member' | 'group-member-only'

    Local accounts are always enumerated from Get-LocalUser regardless of
    group membership, then group membership is overlaid. Domain accounts and
    nested groups appear only if they are present in one of the two groups.

    Returns @{Result='ok'; Accounts=[array]; ComputerName; IsDomainJoined;
              AdminGroupName; RdpGroupName; AdminError; RdpError} on success.
    Returns "error:..." string on hard failure (e.g. Get-LocalUser unavailable).

.NOTES
    No group denesting. Nested groups are returned as AccountType='group'
    entries with RdpEligible=$false -- they are informational only.

    Domain accounts are enumerated from local group membership only. Full AD
    account enumeration is not performed. This covers all domain accounts that
    are actually RDP-eligible on this machine without requiring AD queries.
#>
    [CmdletBinding()]
    param()

    try {
        $computerName   = Get-ComputerNetbiosName
        $isDomainJoined = Test-IsDomainJoined

        # --- Enumerate local user accounts ---
        $localUsers = @()
        try {
            $localUsers = @(Get-LocalUser -ErrorAction Stop)
        }
        catch {
            return "error:Get-SrdpAccountInventory: Get-LocalUser failed: $($_.Exception.Message)"
        }

        # --- Enumerate group members ---
        $adminMembers  = Get-MembersOfLocalGroupBySid -Sid $script:SidAdministrators
        $rdpMembers    = Get-MembersOfLocalGroupBySid -Sid $script:SidRemoteDesktopUsers

        $adminGroupName = $adminMembers.GroupName
        $rdpGroupName   = $rdpMembers.GroupName
        $adminError     = $adminMembers.Error
        $rdpError       = $rdpMembers.Error

        # Build lookup sets for group membership by SID
        # Get-LocalGroupMember returns objects with .SID property
        $adminSids = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $rdpSids   = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)

        foreach ($m in $adminMembers.Members) {
            if ($null -ne $m.SID) { $null = $adminSids.Add($m.SID.Value) }
        }
        foreach ($m in $rdpMembers.Members) {
            if ($null -ne $m.SID) { $null = $rdpSids.Add($m.SID.Value) }
        }

        # --- Build account list ---
        $accounts = [System.Collections.Generic.List[hashtable]]::new()

        # Track which SIDs we have already added from local user enumeration
        $addedSids = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)

        # Pass 1: all local accounts from Get-LocalUser
        foreach ($user in $localUsers) {
            $sidStr    = if ($null -ne $user.SID) { $user.SID.Value } else { '' }
            $inAdmins  = ($sidStr -ne '') -and $adminSids.Contains($sidStr)
            $inRdp     = ($sidStr -ne '') -and $rdpSids.Contains($sidStr)
            $isEnabled = ($user.Enabled -eq $true)

            $entry = @{
                QualifiedName = "$computerName\$($user.Name)"
                ShortName     = $user.Name
                AccountType   = 'local'
                IsEnabled     = $isEnabled
                InAdmins      = $inAdmins
                InRdpUsers    = $inRdp
                RdpEligible   = $isEnabled -and ($inAdmins -or $inRdp)
                Source        = 'local-enum'
                SID           = $sidStr
            }

            $null = $accounts.Add($entry)
            if ($sidStr -ne '') { $null = $addedSids.Add($sidStr) }
        }

        # Pass 2: domain accounts and nested groups from group membership
        # that were not already covered by Get-LocalUser
        $allGroupMembers = [System.Collections.Generic.List[object]]::new()
        foreach ($m in $adminMembers.Members) { $null = $allGroupMembers.Add($m) }
        foreach ($m in $rdpMembers.Members)   { $null = $allGroupMembers.Add($m) }

        # Track which SIDs we have added in this pass to avoid duplicates
        $addedInPass2 = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)

        foreach ($member in $allGroupMembers) {
            $sidStr = if ($null -ne $member.SID) { $member.SID.Value } else { '' }

            # Skip if already covered by local user enumeration
            if ($sidStr -ne '' -and $addedSids.Contains($sidStr)) { continue }
            # Skip if already added in this pass
            if ($sidStr -ne '' -and $addedInPass2.Contains($sidStr)) { continue }

            $inAdmins = ($sidStr -ne '') -and $adminSids.Contains($sidStr)
            $inRdp    = ($sidStr -ne '') -and $rdpSids.Contains($sidStr)

            # Determine account type from the member's PrincipalSource and ObjectClass
            $objClass   = if ($member.PSObject.Properties['ObjectClass']) { $member.ObjectClass } else { '' }
            $acctType   = 'domain'
            if ($objClass -eq 'Group') { $acctType = 'group' }

            # Build qualified name
            # For domain accounts Get-LocalGroupMember returns Name as DOMAIN\user
            # For local accounts it returns MACHINENAME\user (already handled in Pass 1)
            $qualifiedName = $member.Name
            $shortName     = $member.Name -replace '^[^\\]+\\', ''

            $entry = @{
                QualifiedName = $qualifiedName
                ShortName     = $shortName
                AccountType   = $acctType
                IsEnabled     = $true   # Cannot determine for domain accounts without AD query
                InAdmins      = $inAdmins
                InRdpUsers    = $inRdp
                RdpEligible   = ($acctType -ne 'group') -and ($inAdmins -or $inRdp)
                Source        = 'group-member-only'
                SID           = $sidStr
            }

            $null = $accounts.Add($entry)
            if ($sidStr -ne '') { $null = $addedInPass2.Add($sidStr) }
        }

        return @{
            Result          = 'ok'
            Accounts        = $accounts.ToArray()
            ComputerName    = $computerName
            IsDomainJoined  = $isDomainJoined
            AdminGroupName  = $adminGroupName
            RdpGroupName    = $rdpGroupName
            AdminError      = $adminError
            RdpError        = $rdpError
        }
    }
    catch {
        $errMsg = $_.Exception.Message
    try { Write-SrdpLog "Get-SrdpAccountInventory failed: $errMsg" -Level ERROR -Component 'AccountInventory' } catch {}
    return "error:Get-SrdpAccountInventory: $errMsg"
    }
}

function Get-SrdpRdpEligibleAccounts {
<#
.SYNOPSIS
    Convenience wrapper that returns only RDP-eligible accounts from the
    inventory -- i.e. enabled accounts that are members of Administrators
    or Remote Desktop Users.

    Returns @{Result='ok'; Accounts=[array]; ...} (same shape as
    Get-SrdpAccountInventory but Accounts filtered to RdpEligible=$true).
    Returns "error:..." string on failure.
#>
    [CmdletBinding()]
    param()

    $inv = Get-SrdpAccountInventory
    if ($inv -is [string] -and $inv -like 'error:*') { return $inv }

    $eligible = @($inv.Accounts | Where-Object { $_.RdpEligible -eq $true })

    return @{
        Result         = 'ok'
        Accounts       = $eligible
        ComputerName   = $inv.ComputerName
        IsDomainJoined = $inv.IsDomainJoined
        AdminGroupName = $inv.AdminGroupName
        RdpGroupName   = $inv.RdpGroupName
        AdminError     = $inv.AdminError
        RdpError       = $inv.RdpError
    }
}

# ===========================================================================
# EXPORTS
# ===========================================================================

Export-ModuleMember -Function @(
    'Get-SrdpAccountInventory',
    'Get-SrdpRdpEligibleAccounts'
)
