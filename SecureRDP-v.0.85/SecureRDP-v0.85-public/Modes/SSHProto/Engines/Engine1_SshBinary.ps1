# =============================================================================
# SECURE-RDP PHASE 1: ENGINE 1 (SSH BINARY)
# =============================================================================

# -----------------------------------------------------------------------------
# TOP-LEVEL HELPER FUNCTIONS
# -----------------------------------------------------------------------------
function Get-SecureRdpSshVersion {
    [CmdletBinding()]
    param([string]$BinaryPath)

    if (-not (Test-Path $BinaryPath)) { return $null }

    # sshd -V writes to stderr and exits non-zero.
    # Save/restore EAP around native executable call.
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = & $BinaryPath -V 2>&1 | Out-String
    $ErrorActionPreference = $oldEAP
    if ($output -match 'OpenSSH_(?:for_Windows_)?(\d+\.\d+)') {
        return [version]$matches[1]
    }
    return [version]'0.0'
}

function Test-SecureRdpPendingReboot {
    [CmdletBinding()]
    param()

    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $true }
    }
    return $false
}

# -----------------------------------------------------------------------------
# ENGINE 1: MAIN EXECUTION
# -----------------------------------------------------------------------------
function Invoke-SshBinaryEngine {
    [CmdletBinding()]
    param()

    # ENGINE 1 OWNS ITS EAP -- never inherit from caller.
    # Save caller EAP and restore before every return path.
    $callerEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'

    # 1. Initialize Universal Result Schema
    $Result = [PSCustomObject]@{
        Success = $false
        Status  = 'Unknown'
        Data    = @{
            BinaryPath     = Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe'
            Version        = $null
            VersionNote    = $null
            InstallAction  = 'None'
            RequiresReboot = $false
        }
        Logs    = [System.Collections.Generic.List[string]]::new()
        Errors  = [System.Collections.Generic.List[string]]::new()
    }

    $Result.Logs.Add("Engine 1 starting. EAP set to Stop.")
    try { Write-SrdpLog "Engine 1 starting." -Level INFO -Component 'Engine1' } catch {}

    # 2. Check Windows Optional Feature state first -- authoritative source
    #    of truth for whether OpenSSH Server is installed on this machine.
    $featureState   = $null
    $featureChecked = $false
    try {
        $Result.Logs.Add("Querying Windows Optional Feature state for OpenSSH Server...")
        try { Write-SrdpLog "Querying Windows Optional Feature: OpenSSH.Server~~~~0.0.1.0" -Level DEBUG -Component 'Engine1' } catch {}
        $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' `
               -ErrorAction Stop
        if ($null -ne $cap) {
            $featureState   = $cap.State
            $featureChecked = $true
            $Result.Logs.Add("Windows Optional Features: OpenSSH Server state is '$featureState'.")
            try { Write-SrdpLog "OpenSSH Server feature state: $featureState" -Level INFO -Component 'Engine1' } catch {}
        }
    } catch {
        $errMsg = $_.Exception.Message
        $Result.Logs.Add("Could not query Windows Optional Feature state: $errMsg. Falling back to binary check.")
        try { Write-SrdpLog "Could not query feature state: $errMsg" -Level WARN -Component 'Engine1' } catch {}
    }

    # 3. Feature confirmed installed -- check binary version
    if ($featureChecked -and $featureState -eq 'Installed') {
        $Result.Logs.Add("OpenSSH Server feature is installed. Checking binary version at $($Result.Data.BinaryPath)...")
        try { Write-SrdpLog "Feature installed. Checking binary at $($Result.Data.BinaryPath)" -Level DEBUG -Component 'Engine1' } catch {}
        $currentVersion = Get-SecureRdpSshVersion -BinaryPath $Result.Data.BinaryPath

        if ($null -ne $currentVersion -and $currentVersion -ge [version]'8.1') {
            $Result.Success            = $true
            $Result.Status             = 'Verified'
            $Result.Data.Version       = $currentVersion
            $Result.Data.InstallAction = 'AlreadyPresent'
            $Result.Logs.Add("OpenSSH Server v$currentVersion is already installed via Windows Optional Features. No installation needed.")
            try { Write-SrdpLog "AlreadyPresent: OpenSSH v$currentVersion" -Level INFO -Component 'Engine1' } catch {}

            if ($currentVersion -lt [version]'9.5') {
                $Result.Data.VersionNote = "Note: This version of SSH Server supports all present functionality but may not be compatible with certain future quantum-resistant or hardware-key Modes. See documentation for more details."
                $Result.Logs.Add("Version is below 9.5; appended compatibility advisory to Data.VersionNote.")
                try { Write-SrdpLog "Version $currentVersion < 9.5 -- compatibility advisory appended." -Level WARN -Component 'Engine1' } catch {}
            }
            $ErrorActionPreference = $callerEAP
            return $Result
        } else {
            $msg = "Feature reports installed but binary not found or unreadable at expected path. Proceeding to install."
            $Result.Logs.Add("Warning: $msg")
            try { Write-SrdpLog $msg -Level WARN -Component 'Engine1' } catch {}
        }
    } elseif ($featureChecked -and $featureState -ne 'Installed') {
        $Result.Logs.Add("OpenSSH Server feature is not installed on this machine.")
        try { Write-SrdpLog "OpenSSH Server feature not installed. Will install via Optional Features." -Level INFO -Component 'Engine1' } catch {}
    } else {
        # Feature state check failed -- fall back to binary-on-disk check
        $Result.Logs.Add("Checking for OpenSSH binary at $($Result.Data.BinaryPath)...")
        try { Write-SrdpLog "Feature state unknown -- falling back to binary check at $($Result.Data.BinaryPath)" -Level WARN -Component 'Engine1' } catch {}
        $currentVersion = Get-SecureRdpSshVersion -BinaryPath $Result.Data.BinaryPath

        if ($null -ne $currentVersion -and $currentVersion -ge [version]'8.1') {
            $Result.Success            = $true
            $Result.Status             = 'Verified'
            $Result.Data.Version       = $currentVersion
            $Result.Data.InstallAction = 'AlreadyPresent'
            $Result.Logs.Add("OpenSSH Server v$currentVersion found on disk (feature state unknown). Proceeding with existing install.")
            try { Write-SrdpLog "Binary found on disk v$currentVersion (feature state unknown)" -Level WARN -Component 'Engine1' } catch {}

            if ($currentVersion -lt [version]'9.5') {
                $Result.Data.VersionNote = "Note: This version of SSH Server supports all present functionality but may not be compatible with certain future quantum-resistant or hardware-key Modes. See documentation for more details."
                $Result.Logs.Add("Version is below 9.5; appended compatibility advisory to Data.VersionNote.")
                try { Write-SrdpLog "Version $currentVersion < 9.5 -- compatibility advisory appended." -Level WARN -Component 'Engine1' } catch {}
            }
            $ErrorActionPreference = $callerEAP
            return $Result
        }
    }

    # 4. Install via Windows Optional Features
    $Result.Logs.Add("Installing OpenSSH Server via Windows Optional Features. This may take a moment...")
    try { Write-SrdpLog "Starting Add-WindowsCapability for OpenSSH Server..." -Level INFO -Component 'Engine1' } catch {}
    try {
        Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' -ErrorAction Stop | Out-Null
        $Result.Data.InstallAction = 'Installed'
        $Result.Logs.Add("Windows Optional Features install command completed.")
        try { Write-SrdpLog "Add-WindowsCapability completed successfully." -Level INFO -Component 'Engine1' } catch {}
    } catch {
        $errMsg = $_.Exception.Message
        $Result.Success = $false
        $Result.Status  = 'ManualRequired'
        $Result.Errors.Add("Capability install failed: $errMsg")
        $Result.Errors.Add("Please install OpenSSH Server manually via Windows Optional Features, CAB file, or independent binaries (Note: Independent binaries do not receive automatic Windows Updates). See project documentation at github.com/arekfurt/SecureRDP for more details.")
        try { Write-SrdpLog "CRITICAL: Add-WindowsCapability failed: $errMsg" -Level ERROR -Component 'Engine1' } catch {}
        $ErrorActionPreference = $callerEAP
        return $Result
    }

    # 5. Settling Pause & Re-verification
    $Result.Logs.Add("Pausing briefly to allow filesystem updates...")
    try { Write-SrdpLog "Settling pause (2s) after capability install." -Level DEBUG -Component 'Engine1' } catch {}
    Start-Sleep -Seconds 2

    $newVersion      = Get-SecureRdpSshVersion -BinaryPath $Result.Data.BinaryPath
    $isRebootPending = Test-SecureRdpPendingReboot
    $Result.Data.RequiresReboot = $isRebootPending

    try { Write-SrdpLog "Post-install check: version=$newVersion rebootPending=$isRebootPending" -Level DEBUG -Component 'Engine1' } catch {}

    if ($isRebootPending) {
        $Result.Logs.Add("System registry indicates a pending reboot is required.")
        try { Write-SrdpLog "Reboot pending detected after install." -Level WARN -Component 'Engine1' } catch {}
    }

    # 6. Determine Final State
    # Path A: Fresh install verified
    if ($null -ne $newVersion -and $newVersion -ge [version]'8.1') {
        $Result.Success      = $true
        $Result.Status       = 'Upgraded'
        $Result.Data.Version = $newVersion
        $Result.Logs.Add("Installation verified. OpenSSH Server v$newVersion is now installed.")
        try { Write-SrdpLog "Installation verified. OpenSSH Server v$newVersion installed." -Level INFO -Component 'Engine1' } catch {}

        if ($newVersion -lt [version]'9.5') {
            $Result.Data.VersionNote = "Note: This version of SSH Server supports all present functionality but may not be compatible with certain future quantum-resistant or hardware-key Modes. See documentation for more details."
            try { Write-SrdpLog "Version $newVersion < 9.5 -- compatibility advisory set." -Level WARN -Component 'Engine1' } catch {}
        }
    }
    # Path B: Ghost Install (Requires Reboot)
    elseif ($isRebootPending) {
        $Result.Success = $false
        $Result.Status  = 'PendingReboot'
        $Result.Errors.Add("Installation likely succeeded, but binaries are inaccessible until the system is rebooted.")
        try { Write-SrdpLog "PendingReboot: binaries inaccessible until reboot." -Level WARN -Component 'Engine1' } catch {}
    }
    # Path C: Hard Failure / Missing Binaries
    else {
        $Result.Success = $false
        $Result.Status  = 'ManualRequired'
        $Result.Errors.Add("Install command reported success, but binaries were not found at the expected System32 path.")
        $Result.Errors.Add("Please install OpenSSH Server manually.")
        try { Write-SrdpLog "CRITICAL: Install reported success but binary not found at $($Result.Data.BinaryPath)" -Level ERROR -Component 'Engine1' } catch {}
    }

    try { Write-SrdpLog "Engine 1 complete. Status=$($Result.Status) Success=$($Result.Success)" -Level INFO -Component 'Engine1' } catch {}
    $ErrorActionPreference = $callerEAP
    return $Result
}
