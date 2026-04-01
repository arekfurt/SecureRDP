# =============================================================================
# Secure RDP v0.821 - RDPCheckModules\CheckOtherRDPSecurity.psm1
#
# Pure logic module. No UI. Returns structured results to ServerWizard.ps1.
# Does NOT require Administrator. Uses [ADSI] WinNT provider for group reads
# (SAM-based, readable by standard users) and registry reads for policy data.
#
# Exported functions:
#   Get-RdpGroupMembers    - reads Administrators + Remote Desktop Users,
#                            classifies members, deduplicates, detects dangerous
#                            principals by SID
#   Get-RdpSecurityLayer   - reads SecurityLayer from WinStations\RDP-Tcp
#   Get-RdpCertExpiry      - reads RDP cert thumbprint via CIM, returns expiry
#   Test-SmartCardRequired - reads ScForceOption from System Policies registry
# =============================================================================
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Well-known SIDs for localization-safe group lookup
# ---------------------------------------------------------------------------
$Script:SID_ADMINISTRATORS       = 'S-1-5-32-544'
$Script:SID_REMOTE_DESKTOP_USERS = 'S-1-5-32-555'

# Dangerous principals -- variable SIDs matched by RID suffix
# Guest = *-501, Domain Users = *-513
$Script:DANGEROUS_SID_SUFFIXES = @('-501', '-513')

# Display names for widget output
$Script:DANGEROUS_SID_NAMES = @{
    'S-1-1-0'  = 'Everyone'
    'S-1-5-7'  = 'Anonymous Logon'
    'S-1-5-2'  = 'NETWORK'
    'S-1-5-11' = 'Authenticated Users'
}
$Script:DANGEROUS_SUFFIX_NAMES = @{
    '-501' = 'Guest'
    '-513' = 'Domain Users'
}

# ---------------------------------------------------------------------------
# Internal: translate a well-known SID to its local name (handles localization)
# ---------------------------------------------------------------------------
function Get-LocalGroupNameBySid {
    param([string]$SidString)
    try {
        $sid     = New-Object System.Security.Principal.SecurityIdentifier($SidString)
        $account = $sid.Translate([System.Security.Principal.NTAccount])
        return ($account.Value -split '\\')[-1]
    } catch {
        return $null
    }
}

# ---------------------------------------------------------------------------
# Internal: extract SID string from an [ADSI] member object
# ---------------------------------------------------------------------------
function Get-AdsiMemberSid {
    param($MemberAdsi)
    try {
        $sidProp = $MemberAdsi.psbase.Properties['objectSid']
        if ($null -eq $sidProp) { return $null }
        $count = @($sidProp).Count
        if ($count -eq 0) { return $null }
        $sidBytes = $sidProp.Value
        if ($null -eq $sidBytes) { return $null }
        $sid = New-Object System.Security.Principal.SecurityIdentifier($sidBytes, 0)
        return $sid.Value
    } catch {
        return $null
    }
}

# ---------------------------------------------------------------------------
# Internal: check whether a SID string is one of the dangerous six
# Returns display label string or $null
# ---------------------------------------------------------------------------
function Get-DangerousLabel {
    param([string]$SidString)
    if (-not $SidString) { return $null }
    if ($Script:DANGEROUS_SID_NAMES.ContainsKey($SidString)) {
        return $Script:DANGEROUS_SID_NAMES[$SidString]
    }
    foreach ($suffix in $Script:DANGEROUS_SID_SUFFIXES) {
        if ($SidString.EndsWith($suffix)) {
            return $Script:DANGEROUS_SUFFIX_NAMES[$suffix]
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Internal: read direct members of a single local group via [ADSI] WinNT
# Returns List[PSCustomObject] or error string
# ---------------------------------------------------------------------------
function Read-AdsiGroupMembers {
    param([string]$GroupName)
    $result = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        $computerName = $env:COMPUTERNAME
        $groupAdsi    = [ADSI]"WinNT://$computerName/$GroupName,group"
        $members      = @($groupAdsi.psbase.Invoke('Members'))

        foreach ($m in $members) {
            $ma = $null
            try {
                $ma    = [ADSI]$m
                $name  = $null
                $class = 'Other'
                $path  = $null
                $sid   = $null

                try { $name  = $ma.psbase.Name           } catch {}
                try { $class = $ma.psbase.SchemaClassName } catch {}
                try { $path  = $ma.psbase.Path            } catch {}
                try { $sid   = Get-AdsiMemberSid $ma      } catch {}

                if (-not $name) { $name = '(unknown)' }
                if (-not $class) { $class = 'Other'   }

                $result.Add([PSCustomObject]@{
                    Name  = [string]$name
                    Class = [string]$class
                    Path  = [string]$path
                    Sid   = [string]$sid
                })
            } catch {
                continue
            } finally {
                # Null the reference explicitly to prompt GC collection.
                # [ADSI] objects do not expose Dispose() and NativeObject
                # access is unreliable cross-version -- nulling is sufficient
                # for local groups of any realistic size on a non-DC machine.
                $ma = $null
            }
        }
        $groupAdsi = $null
        return $result
    } catch {
        return "error:Could not read group '$GroupName': $($_.Exception.Message)"
    }
}

# =============================================================================
# Get-RdpGroupMembers
#
# Reads direct members of Administrators and Remote Desktop Users.
# Groups are looked up by well-known SID for localization safety.
# Members are deduplicated across both groups by SID (fallback: path, name).
# Dangerous principals are detected by SID match.
# Nested group members are NOT expanded (by design).
#
# Returns hashtable on success:
#   @{
#     Result          = 'ok'
#     IndividualCount = [int]       # deduplicated user-class members
#     GroupCount      = [int]       # deduplicated group-class members
#     OtherCount      = [int]
#     DangerousPrincipals = [string[]]   # display names of dangerous entries
#     AdminGroupName  = [string]
#     RdpGroupName    = [string]
#     AdminError      = [string|$null]   # error if admin group unreadable
#     RdpError        = [string|$null]   # error if RDP group unreadable
#   }
#
# Returns: 'error:...' string if both groups are unreadable
# =============================================================================
function Get-RdpGroupMembers {
    # Resolve group names from SIDs (localization-safe)
    $adminGroupName = Get-LocalGroupNameBySid $Script:SID_ADMINISTRATORS
    $rdpGroupName   = Get-LocalGroupNameBySid $Script:SID_REMOTE_DESKTOP_USERS

    if (-not $adminGroupName) { $adminGroupName = 'Administrators'      }
    if (-not $rdpGroupName)   { $rdpGroupName   = 'Remote Desktop Users' }

    # Read both groups
    $adminResult = Read-AdsiGroupMembers $adminGroupName
    $rdpResult   = Read-AdsiGroupMembers $rdpGroupName

    $adminIsError = ($adminResult -is [string])
    $rdpIsError   = ($rdpResult   -is [string])

    if ($adminIsError -and $rdpIsError) {
        return "error:Could not read either RDP group. Administrators: $adminResult. Remote Desktop Users: $rdpResult"
    }

    # Combine into one list for processing
    $combined = [System.Collections.Generic.List[PSCustomObject]]::new()
    if (-not $adminIsError) {
        foreach ($m in $adminResult) { $combined.Add($m) }
    }
    if (-not $rdpIsError) {
        foreach ($m in $rdpResult) { $combined.Add($m) }
    }

    # Deduplicate by SID, then Path, then Name
    $seen      = [System.Collections.Generic.HashSet[string]]::new(
                     [System.StringComparer]::OrdinalIgnoreCase)
    $users     = [System.Collections.Generic.List[PSCustomObject]]::new()
    $groups    = [System.Collections.Generic.List[PSCustomObject]]::new()
    $others    = [System.Collections.Generic.List[PSCustomObject]]::new()
    $dangerous = [System.Collections.Generic.List[string]]::new()

    foreach ($m in $combined) {
        # Dangerous check runs before dedup -- a dangerous entry in both groups
        # should still only appear once in the output list
        $dangerLabel = $null
        if ($m.Sid) {
            $dangerLabel = Get-DangerousLabel $m.Sid
        }

        # Dedup key
        $key = if ($m.Sid -and $m.Sid -ne '') { $m.Sid }
               elseif ($m.Path -and $m.Path -ne '') { $m.Path }
               else { $m.Name }

        if (-not $key) { $key = '(unknown)' }
        $isNew = $seen.Add($key)

        # Record dangerous label if not already recorded
        if ($dangerLabel -and (-not $dangerous.Contains($dangerLabel))) {
            $dangerous.Add($dangerLabel)
        }

        if (-not $isNew) { continue }

        $classLower = if ($m.Class) { $m.Class.ToLower() } else { 'other' }
        switch ($classLower) {
            'user'  { $users.Add($m)  }
            'group' { $groups.Add($m) }
            default { $others.Add($m) }
        }
    }

    return @{
        Result              = 'ok'
        IndividualCount     = $users.Count
        GroupCount          = $groups.Count
        OtherCount          = $others.Count
        DangerousPrincipals = @($dangerous)
        AdminGroupName      = $adminGroupName
        RdpGroupName        = $rdpGroupName
        AdminError          = if ($adminIsError) { $adminResult } else { $null }
        RdpError            = if ($rdpIsError)   { $rdpResult   } else { $null }
    }
}

# =============================================================================
# Get-RdpSecurityLayer
#
# Reads the SecurityLayer value from WinStations\RDP-Tcp.
#   0 = RDP legacy encryption (weakest)
#   1 = Negotiate (TLS if available)
#   2 = SSL/TLS required
#
# Returns: 'tls' | 'negotiate' | 'legacy' |
#          'error:regKeyMissing' | 'error:regValueMissing' | 'error:...'
# =============================================================================
function Get-RdpSecurityLayer {
    try {
        $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
        $key     = Get-Item -Path $regPath -ErrorAction Stop
        $raw     = $key.GetValue('SecurityLayer', $null)

        if ($null -eq $raw) { return 'error:regValueMissing' }

        $val = $null
        if (-not [int]::TryParse($raw.ToString(), [ref]$val)) {
            return 'error:unexpected'
        }

        $layerResult = switch ($val) {
            0       { 'legacy'    }
            1       { 'negotiate' }
            2       { 'tls'       }
            default { 'error:unknownValue' }
        }
        return $layerResult
    } catch [System.Management.Automation.ItemNotFoundException] {
        return 'error:regKeyMissing'
    } catch {
        return "error:$($_.Exception.Message)"
    }
}

# =============================================================================
# Get-RdpCertExpiry
#
# Gets the thumbprint of the configured RDP certificate via CIM, then locates
# it in LocalMachine\My and returns expiry information.
#
# Returns hashtable on success:
#   @{
#     Result          = 'ok'
#     Thumbprint      = [string]
#     Subject         = [string]
#     NotAfter        = [DateTime]
#     DaysUntilExpiry = [int]   # negative if already expired
#   }
#
# Returns: 'error:cimUnavailable' | 'error:noThumbprintConfigured' |
#          'error:certNotInStore' | 'error:...'
# =============================================================================
function Get-RdpCertExpiry {
    # Get thumbprint from CIM
    $cimObj = $null
    try {
        $cimObj = Get-CimInstance -ClassName Win32_TSGeneralSetting `
            -Namespace 'root\cimv2\terminalservices' `
            -Filter "TerminalName='RDP-Tcp'" `
            -ErrorAction Stop
    } catch {
        return "error:cimUnavailable: $($_.Exception.Message)"
    }

    if ($null -eq $cimObj) { return 'error:cimUnavailable' }

    $thumbprint = $cimObj.SSLCertificateSHA1Hash
    if ([string]::IsNullOrWhiteSpace($thumbprint)) {
        return 'error:noThumbprintConfigured'
    }

    $thumbprint = $thumbprint.Trim().Replace(' ', '').ToUpper()
    if ($thumbprint -notmatch '^[0-9A-F]{40}$') {
        return 'error:unexpected'
    }

    # Locate cert in LocalMachine\My
    $certStore = $null
    $cert      = $null
    try {
        $certStore = New-Object System.Security.Cryptography.X509Certificates.X509Store(
            [System.Security.Cryptography.X509Certificates.StoreName]::My,
            [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
        )
        $certStore.Open(
            [System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly
        )
        $certMatches = @($certStore.Certificates.Find(
            [System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
            $thumbprint, $false
        ))
        if ($certMatches.Count -gt 0) { $cert = $certMatches[0] }
    } finally {
        if ($null -ne $certStore) { $certStore.Close() }
    }

    if ($null -eq $cert) { return 'error:certNotInStore' }

    $now             = Get-Date
    $daysUntilExpiry = [int][Math]::Ceiling(($cert.NotAfter - $now).TotalDays)

    return @{
        Result          = 'ok'
        Thumbprint      = $cert.Thumbprint
        Subject         = $cert.Subject
        NotAfter        = $cert.NotAfter
        DaysUntilExpiry = $daysUntilExpiry
    }
}

# =============================================================================
# Test-SmartCardRequired
#
# Checks the ScForceOption Group Policy value. When set to 1, a smart card is
# required for ALL interactive logins including RDP. This is a system-wide
# policy -- there is no supported mechanism to require smart cards for RDP
# sessions only.
#
# Registry path:
#   HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System
#   Value: ScForceOption
#     1 = smart card required for all interactive logins
#     0 or missing = not required
#
# Returns: 'required' | 'notrequired' | 'error:...'
# =============================================================================
function Test-SmartCardRequired {
    try {
        $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        $key     = Get-Item -Path $regPath -ErrorAction Stop
        $raw     = $key.GetValue('ScForceOption', $null)

        # Missing value means policy not configured = not required
        if ($null -eq $raw) { return 'notrequired' }

        $val = $null
        if (-not [int]::TryParse($raw.ToString(), [ref]$val)) {
            return 'error:unexpected'
        }

        if ($val -eq 1) { return 'required'    }
        if ($val -eq 0) { return 'notrequired' }
        return 'error:unexpected'

    } catch [System.Management.Automation.ItemNotFoundException] {
        # Key missing = policy not set = not required
        return 'notrequired'
    } catch {
        return "error:$($_.Exception.Message)"
    }
}


Export-ModuleMember -Function @(
    'Get-RdpGroupMembers'
    'Get-RdpSecurityLayer'
    'Get-RdpCertExpiry'
    'Test-SmartCardRequired'
)
