Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
# SecureRDP v0.848132 -- AttackExposure.psm1
# SupportingModules\AttackExposure.psm1
#
# Provides two functions for the dashboard Attack Exposure widget:
#   Invoke-SrdpEvent261Setup  -- enables the TerminalServices event log
#   Get-SrdpAttackExposureVerdict -- scans Event 261 for public IP exposure
#
# Design: Event 261 fires on every RDP connection receipt regardless of
# authentication outcome, making it the correct source for detecting
# external exposure. IP addresses are validated, classified as
# public/private/loopback, and immediately discarded -- only the boolean
# verdict (public exposure yes/no) is returned to the UI.
#
# Requires Administrator (Event Log configuration).
# =============================================================================

# =============================================================================
# INI HELPERS
# Simple read/write for the config.ini [AttackExposure] section.
# =============================================================================

function Get-SrdpIniValue {
<#
.SYNOPSIS
    Reads a single value from a .ini file by section and key name.
    Returns the value string, or $null if not found.
#>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key
    )
    if (-not (Test-Path $Path)) { return $null }
    try {
        $inSection = $false
        foreach ($line in (Get-Content $Path -Encoding UTF8)) {
            $trimmed = $line.Trim()
            if ($trimmed -match '^\[(.+)\]$') {
                $inSection = ($Matches[1] -eq $Section)
                continue
            }
            if ($inSection -and $trimmed -match '^([^#=]+?)\s*=\s*(.*)$') {
                if ($Matches[1].Trim() -eq $Key) {
                    return $Matches[2].Trim()
                }
            }
        }
    } catch {}
    return $null
}

function Set-SrdpIniValue {
<#
.SYNOPSIS
    Writes a single value to a .ini file under the specified section.
    Creates the section if it does not exist. Creates the key if absent.
    Updates the key in-place if it already exists.
#>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )
    try {
        if (-not (Test-Path $Path)) { return }

        $lines      = @(Get-Content $Path -Encoding UTF8)
        $newLines   = [System.Collections.Generic.List[string]]::new()
        $inSection  = $false
        $keyWritten = $false
        $sectionFound = $false

        foreach ($line in $lines) {
            $trimmed = $line.Trim()

            # Detect section headers
            if ($trimmed -match '^\[(.+)\]$') {
                # If we were in our target section and haven't written the key yet, append it
                if ($inSection -and -not $keyWritten) {
                    $newLines.Add("$Key = $Value")
                    $keyWritten = $true
                }
                $inSection = ($Matches[1] -eq $Section)
                if ($inSection) { $sectionFound = $true }
                $newLines.Add($line)
                continue
            }

            # If in our section, check for existing key
            if ($inSection -and $trimmed -match '^([^#=]+?)\s*=') {
                if ($Matches[1].Trim() -eq $Key) {
                    $newLines.Add("$Key = $Value")
                    $keyWritten = $true
                    continue
                }
            }

            $newLines.Add($line)
        }

        # If section existed but key was never written (end of file reached while in section)
        if ($inSection -and -not $keyWritten) {
            $newLines.Add("$Key = $Value")
            $keyWritten = $true
        }

        # If section was never found, append it
        if (-not $sectionFound) {
            $newLines.Add('')
            $newLines.Add("[$Section]")
            $newLines.Add("$Key = $Value")
            $keyWritten = $true
        }

        Set-Content -Path $Path -Value $newLines -Encoding UTF8
    } catch {
        $errMsg = $_.Exception.Message
        try { Write-SrdpLog "Set-SrdpIniValue failed: $errMsg" -Level ERROR -Component 'AttackExposure' } catch {}
    }
}

# =============================================================================
# EVENT LOG SETUP
# =============================================================================

function Invoke-SrdpEvent261Setup {
<#
.SYNOPSIS
    Enables the TerminalServices-RemoteConnectionManager/Operational event log
    for Event 261 monitoring. Respects pre-existing configurations.
    Returns 'enabled-new', 'enabled-preexisting', or 'error'.
#>
    $logName = 'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational'
    try {
        try { Write-SrdpLog "Invoke-SrdpEvent261Setup: checking log '$logName'..." -Level INFO -Component 'AttackExposure' } catch {}

        $logConfig = New-Object System.Diagnostics.Eventing.Reader.EventLogConfiguration($logName)

        if ($logConfig.IsEnabled) {
            try { Write-SrdpLog "Event log already enabled. Returning 'enabled-preexisting'." -Level INFO -Component 'AttackExposure' } catch {}
            return 'enabled-preexisting'
        }

        # Enable with modest 1MB cap and circular retention
        $logConfig.IsEnabled          = $true
        $logConfig.MaximumSizeInBytes = 1048576
        $logConfig.LogMode            = [System.Diagnostics.Eventing.Reader.EventLogMode]::Circular
        $logConfig.SaveChanges()

        try { Write-SrdpLog "Event log enabled (1MB circular). Returning 'enabled-new'." -Level INFO -Component 'AttackExposure' } catch {}
        return 'enabled-new'
    } catch {
        $errMsg = $_.Exception.Message
        try { Write-SrdpLog "Invoke-SrdpEvent261Setup failed: $errMsg" -Level ERROR -Component 'AttackExposure' } catch {}
        return 'error'
    }
}

# =============================================================================
# EXPOSURE VERDICT ENGINE
# =============================================================================

function Get-SrdpAttackExposureVerdict {
<#
.SYNOPSIS
    Scans Event 261 entries from the last 72 hours. Returns $true if any
    connection originated from a public IP address, $false if all connections
    were private/loopback/local, or $null on engine failure.
    No IP addresses are stored or returned to the caller.
#>
    $logName   = 'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational'
    $startTime = (Get-Date).ToUniversalTime().AddHours(-72)

    try {
        try { Write-SrdpLog "Get-SrdpAttackExposureVerdict: scanning last 72h of Event 261..." -Level DEBUG -Component 'AttackExposure' } catch {}

        $xmlQuery = @"
<QueryList>
  <Query Id="0" Path="$logName">
    <Select Path="$logName">*[System[(EventID=261) and TimeCreated[@SystemTime&gt;='$($startTime.ToString("o"))']]]</Select>
  </Query>
</QueryList>
"@

        $events = @(Get-WinEvent -FilterXml $xmlQuery -ErrorAction SilentlyContinue)

        if ($events.Count -eq 0) {
            try { Write-SrdpLog "No Event 261 entries in last 72h. Verdict=false." -Level INFO -Component 'AttackExposure' } catch {}
            return $false
        }

        try { Write-SrdpLog "Found $($events.Count) Event 261 entries. Classifying..." -Level DEBUG -Component 'AttackExposure' } catch {}

        foreach ($ev in $events) {
            # Property index 2 is SourceIP in Event 261
            $rawIp = $null
            try { $rawIp = $ev.Properties[2].Value } catch { continue }
            if ($null -eq $rawIp -or $rawIp -eq '') { continue }

            # Validate -- discard anything that is not a parseable IP
            $parsedIp = $null
            if (-not [System.Net.IPAddress]::TryParse("$rawIp", [ref]$parsedIp)) {
                continue
            }

            # Classification: loopback, private (RFC 1918 + APIPA), or public
            if ([System.Net.IPAddress]::IsLoopback($parsedIp)) { continue }

            $bytes = $parsedIp.GetAddressBytes()

            if ($parsedIp.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                # IPv4 private ranges
                $isPrivate = (
                    $bytes[0] -eq 10 -or
                    ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
                    ($bytes[0] -eq 192 -and $bytes[1] -eq 168) -or
                    ($bytes[0] -eq 169 -and $bytes[1] -eq 254)
                )
                if ($isPrivate) { continue }
            } else {
                # IPv6: unique local (FC/FD) and link-local (FE80)
                $isPrivateV6 = (
                    $bytes[0] -eq 0xFC -or
                    $bytes[0] -eq 0xFD -or
                    ($bytes[0] -eq 0xFE -and ($bytes[1] -band 0xC0) -eq 0x80)
                )
                if ($isPrivateV6) { continue }
            }

            # If we reach here, the IP is public
            try { Write-SrdpLog "Public IP connection detected in Event 261. Verdict=true." -Level WARN -Component 'AttackExposure' } catch {}
            return $true
        }

        try { Write-SrdpLog "All Event 261 connections were private/loopback. Verdict=false." -Level INFO -Component 'AttackExposure' } catch {}
        return $false

    } catch {
        $errMsg = $_.Exception.Message
        try { Write-SrdpLog "Get-SrdpAttackExposureVerdict failed: $errMsg" -Level ERROR -Component 'AttackExposure' } catch {}
        return $null
    }
}

# =============================================================================
# EXPORTS
# =============================================================================
Export-ModuleMember -Function @(
    'Get-SrdpIniValue',
    'Set-SrdpIniValue',
    'Invoke-SrdpEvent261Setup',
    'Get-SrdpAttackExposureVerdict'
)
