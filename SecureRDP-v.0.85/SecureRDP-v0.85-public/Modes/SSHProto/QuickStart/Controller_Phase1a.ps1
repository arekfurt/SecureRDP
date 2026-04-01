Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
# SECURE-RDP PHASE 1A: CONTROLLER
# Orchestrates Engine 1 (SSH Binary) and Engine 2 (SSH Service Takeover).
# UI-agnostic -- no WinForms, no Write-Host, no Read-Host.
#
# Usage (pre-flight / plan only):
#   $plan = Invoke-Phase1aController
#
# Usage (execute):
#   $result = Invoke-Phase1aController -Confirmed $true
#
# Usage (with progress callback):
#   $result = Invoke-Phase1aController -Confirmed $true -OnProgress {
#       param($p) Write-Host "[$($p.CurrentStep)/$($p.TotalSteps)] $($p.StepName): $($p.Message)"
#   }
# =============================================================================

. (Join-Path $PSScriptRoot '..\Engines\Engine1_SshBinary.ps1')
$ErrorActionPreference = 'Stop'  # Reset after dot-source per coding rule
. (Join-Path $PSScriptRoot '..\Engines\Engine2_SshService.ps1')
$ErrorActionPreference = 'Stop'  # Reset after dot-source per coding rule

# =============================================================================
# HELPER: Send-Progress
# Emits a structured progress update to the UI callback if one is registered.
# =============================================================================
function Send-Progress {
    param(
        [int]$CurrentStep,
        [int]$TotalSteps,
        [string]$StepName,
        [string]$Message,
        [bool]$IsWarning = $false,
        [scriptblock]$OnProgress = $null
    )
    if ($null -ne $OnProgress) {
        $progressObject = [PSCustomObject]@{
            CurrentStep = $CurrentStep
            TotalSteps  = $TotalSteps
            StepName    = $StepName
            Message     = $Message
            IsWarning   = $IsWarning
        }
        try { & $OnProgress $progressObject } catch {}
    }
}

# =============================================================================
# HELPER: Write-StateFile
# Writes engine results to the per-phase state JSON file.
# Called after Engine 1 and again after Engine 2 -- ensures BackupPath is
# persisted even if Engine 2 fails mid-execution.
# =============================================================================
function Write-StateFile {
    param(
        $Engine1Result,
        $Engine2Result,
        [string]$StateFilePath = 'C:\ProgramData\SecureRDP\phase1a_state.json',
        [int]$SshPort = 22
    )
    try {
        $stateDir = Split-Path $StateFilePath -Parent
        if (-not (Test-Path $stateDir)) {
            New-Item -Path $stateDir -ItemType Directory -Force | Out-Null
        }
        $state = @{
            Engine1   = $Engine1Result
            Engine2   = $Engine2Result
            Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            SshPort   = $SshPort
        }
        $state | ConvertTo-Json -Depth 10 | Set-Content $StateFilePath -Encoding UTF8
    } catch {
        $errMsg = $_.Exception.Message
        # State write failure must not halt execution but must be logged
        try { Write-SrdpLog "ERROR: Write-StateFile failed: $errMsg" -Level ERROR -Component 'Controller' } catch {}
    }
}

# =============================================================================
# HELPER: New-Phase1aPlan
# Inspects the current system state without making any changes.
# Returns a plan object describing what Invoke-Phase1aController will do.
# =============================================================================
function New-Phase1aPlan {
    param(
        [int]$SshPort = 22,
        [string]$BaseConfigDir = "$env:ProgramData\ssh"
    )
    $steps    = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    $sshdExe      = Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe'
    $configPath   = Join-Path $BaseConfigDir 'sshd_config'
    $svc          = Get-Service 'sshd' -ErrorAction SilentlyContinue
    $configExists = Test-Path $configPath
    $serviceExists = $null -ne $svc
    $currentVersion = Get-SecureRdpSshVersion -BinaryPath $sshdExe

    $rebootRisk  = $false
    $backupNeeded = $false

    # Determine what Engine 1 will do
    if ($null -ne $currentVersion -and $currentVersion -ge [version]'8.1') {
        $steps.Add("Verify existing OpenSSH v$currentVersion installation (no changes required).")
        if ($currentVersion -lt [version]'9.5') {
            $warnings.Add("OpenSSH v$currentVersion is below v9.5. Future SecureRDP Modes requiring quantum-resistant or hardware-key features may not be compatible. See documentation for details.")
        }
    } else {
        $steps.Add("Install OpenSSH Server via Windows Optional Features.")
        $rebootRisk = $true
        $warnings.Add("OpenSSH installation may require a system reboot before setup can continue.")
    }

    # Determine what Engine 2 will do
    if ($serviceExists -and $configExists) {
        $steps.Add("Stop the existing sshd service.")
        $steps.Add("Back up existing sshd_config and host keys to a timestamped folder in C:\ProgramData\SecureRDP\Backups\.")
        $steps.Add("Write a hardened SecureRDP sshd_config (port $SshPort, key-only auth, tunnel-only).")
        $steps.Add("Enforce strict ACLs on SSH host keys.")
        $steps.Add("Re-brand and restart the sshd service under SecureRDP management.")
        $backupNeeded = $true
        $warnings.Add("An existing SSH server configuration will be overwritten. Your current configuration will be backed up and can be restored using the revert option.")
        $impactLevel = 'High'
    } elseif ($serviceExists -and -not $configExists) {
        $steps.Add("Stop the existing sshd service.")
        $steps.Add("Write a hardened SecureRDP sshd_config (port $SshPort, key-only auth, tunnel-only).")
        $steps.Add("Enforce strict ACLs on SSH host keys.")
        $steps.Add("Re-brand and restart the sshd service under SecureRDP management.")
        $impactLevel = 'Medium'
    } elseif (-not $serviceExists -and $configExists) {
        $steps.Add("Back up existing SSH configuration files to a timestamped folder in C:\ProgramData\SecureRDP\Backups\.")
        $steps.Add("Write a hardened SecureRDP sshd_config (port $SshPort, key-only auth, tunnel-only).")
        $steps.Add("Enforce strict ACLs on SSH host keys.")
        $steps.Add("Configure and start the sshd service under SecureRDP management.")
        $backupNeeded = $true
        $impactLevel = 'Medium'
    } else {
        $steps.Add("Write a hardened SecureRDP sshd_config (port $SshPort, key-only auth, tunnel-only).")
        $steps.Add("Configure and start the sshd service under SecureRDP management.")
        $impactLevel = 'Low'
    }

    return [PSCustomObject]@{
        Steps        = $steps
        Warnings     = $warnings
        BackupNeeded = $backupNeeded
        RebootRisk   = $rebootRisk
        ImpactLevel  = $impactLevel
    }
}

# =============================================================================
# MAIN ENTRY POINT: Invoke-Phase1aController
# =============================================================================
function Invoke-Phase1aController {
    param(
        [int]$SshPort            = 22,
        [bool]$Confirmed         = $false,
        [string]$StateFilePath   = 'C:\ProgramData\SecureRDP\phase1a_state.json',
        [string]$BaseConfigDir   = "$env:ProgramData\ssh",
        [scriptblock]$OnProgress = $null
    )

    $Result = [PSCustomObject]@{
        Success = $false
        Status  = 'Unknown'
        Data    = @{
            Plan           = $null
            Engine1Result  = $null
            Engine2Result  = $null
            StateFilePath  = $StateFilePath
            RebootRequired = $false
        }
        Logs    = [System.Collections.Generic.List[string]]::new()
        Errors  = [System.Collections.Generic.List[string]]::new()
    }

    # -------------------------------------------------------------------------
    # PRE-FLIGHT: return plan only
    # -------------------------------------------------------------------------
    if (-not $Confirmed) {
        $Result.Logs.Add("Pre-flight assessment requested.")
        try {
            $plan = New-Phase1aPlan -SshPort $SshPort -BaseConfigDir $BaseConfigDir
            $Result.Success    = $true
            $Result.Status     = 'PlanReady'
            $Result.Data.Plan  = $plan
            $Result.Logs.Add("Plan generated. ImpactLevel=$($plan.ImpactLevel) RebootRisk=$($plan.RebootRisk)")
        } catch {
            $Result.Success = $false
            $Result.Status  = 'Failed'
            $Result.Errors.Add("Pre-flight assessment failed: $($_.Exception.Message)")
        }
        return $Result
    }

    # -------------------------------------------------------------------------
    # EXECUTION: run engines in sequence
    # -------------------------------------------------------------------------
    $Result.Logs.Add("Execution confirmed. Starting Phase 1a installation.")
    try { Write-SrdpLog "Phase 1a execution confirmed. Starting engines." -Level INFO -Component 'Controller' } catch {}

    # Capture pre-existing SSH firewall rule state BEFORE Engine 1 may
    # trigger OpenSSH installation (which auto-creates an enabled rule).
    # Engine 2 will only disable the rule if it was NOT already enabled.
    $preExistingSshRule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    $sshRuleWasEnabled = ($null -ne $preExistingSshRule -and $preExistingSshRule.Enabled -eq 'True')
    $Result.Logs.Add("Pre-existing SSH rule state: SshRuleWasEnabled=$sshRuleWasEnabled")
    try { Write-SrdpLog "Pre-existing OpenSSH-Server-In-TCP state: WasEnabled=$sshRuleWasEnabled" -Level INFO -Component 'Controller' } catch {}

    # --- Engine 1 ---
    Send-Progress 1 2 'Verifying SSH binaries' 'Checking for OpenSSH installation...' -OnProgress $OnProgress
    $Result.Logs.Add("Invoking Engine 1 (SSH Binary)...")

    $e1Result = Invoke-SshBinaryEngine
    $Result.Data.Engine1Result = $e1Result

    # Forward Engine 1 logs and errors
    foreach ($entry in $e1Result.Logs)   { $Result.Logs.Add("E1: $entry") }
    foreach ($entry in $e1Result.Errors) { $Result.Errors.Add("E1: $entry") }

    # Send descriptive progress based on what Engine 1 actually did
    $e1Action = $e1Result.Data.InstallAction
    $e1ProgressMsg = switch ($e1Action) {
        'AlreadyPresent' { "OpenSSH Server already installed (v$($e1Result.Data.Version))." }
        'Installed'      { "OpenSSH Server installed via Windows Optional Features." }
        'None'           { "OpenSSH Server check complete." }
        default          { if ($e1Result.Logs.Count -gt 0) { $e1Result.Logs[$e1Result.Logs.Count - 1] } else { '' } }
    }
    Send-Progress 1 2 'Verifying SSH binaries' $e1ProgressMsg `
        ($e1Result.Status -eq 'PendingReboot') -OnProgress $OnProgress

    # Forward ALL Engine 1 errors to UI -- every error surfaces, no exceptions
    foreach ($err in $e1Result.Errors) {
        Send-Progress 1 2 'Verifying SSH binaries' $err -IsWarning $true -OnProgress $OnProgress
        try { Write-SrdpLog "E1 ERROR forwarded to UI: $err" -Level ERROR -Component 'Controller' } catch {}
    }

    # Persist state after Engine 1 regardless of outcome
    Write-StateFile -Engine1Result $e1Result -Engine2Result $null -StateFilePath $StateFilePath -SshPort $SshPort

    # Gate: halt if Engine 1 requires reboot
    if ($e1Result.Status -eq 'PendingReboot') {
        $Result.Success              = $false
        $Result.Status               = 'PendingReboot'
        $Result.Data.RebootRequired  = $true
        $Result.Errors.Add("OpenSSH was installed but a system reboot is required before setup can continue. Please reboot and then run Quick Start again.")
        return $Result
    }

    # Gate: halt if Engine 1 failed outright
    if (-not $e1Result.Success) {
        $Result.Success = $false
        $Result.Status  = 'Failed'
        $Result.Errors.Add("Engine 1 failed. Engine 2 will not run.")
        return $Result
    }

    $Result.Logs.Add("Engine 1 complete. Status=$($e1Result.Status)")

    # --- Engine 2 ---
    Send-Progress 2 2 'Configuring SSH service' 'Taking over SSH service configuration...' -OnProgress $OnProgress
    $Result.Logs.Add("Invoking Engine 2 (SSH Service Takeover)...")

    $e2Result = Invoke-SshServiceEngine -SshPort $SshPort -BaseConfigDir $BaseConfigDir -SshRuleWasEnabled $sshRuleWasEnabled
    $Result.Data.Engine2Result = $e2Result

    # Forward Engine 2 logs and errors
    foreach ($entry in $e2Result.Logs)   { $Result.Logs.Add("E2: $entry") }
    foreach ($entry in $e2Result.Errors) { $Result.Errors.Add("E2: $entry") }

    $e2LastLog = if ($e2Result.Logs.Count -gt 0) { $e2Result.Logs[$e2Result.Logs.Count - 1] } else { '' }
    Send-Progress 2 2 'Configuring SSH service' $e2LastLog `
        ($e2Result.Success -eq $false) -OnProgress $OnProgress

    # Forward ALL Engine 2 errors to UI -- every error surfaces, no exceptions
    foreach ($err in $e2Result.Errors) {
        Send-Progress 2 2 'Configuring SSH service' $err -IsWarning $true -OnProgress $OnProgress
        try { Write-SrdpLog "E2 ERROR forwarded to UI: $err" -Level ERROR -Component 'Controller' } catch {}
    }

    # Persist state after Engine 2 -- captures BackupPath even on partial failure
    Write-StateFile -Engine1Result $e1Result -Engine2Result $e2Result -StateFilePath $StateFilePath -SshPort $SshPort

    $Result.Logs.Add("Engine 2 complete. Status=$($e2Result.Status)")

    # --- Final result ---
    if ($e1Result.Success -and $e2Result.Success) {
        $Result.Success = $true
        $Result.Status  = 'Installed'
    } else {
        $Result.Success = $false
        $Result.Status  = 'PartialFailure'
    }

    $Result.Data.RebootRequired = $e1Result.Data.RequiresReboot

    $Result.Logs.Add("Phase 1a complete. Status=$($Result.Status) RebootRequired=$($Result.Data.RebootRequired)")
    try { Write-SrdpLog "Phase 1a complete. Status=$($Result.Status) Success=$($Result.Success) Errors=$($Result.Errors.Count)" -Level INFO -Component 'Controller' } catch {}
    return $Result
}

# =============================================================================
# Script-level entry point: invoke controller if run directly (not when dot-sourced)
# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Phase1aController
}
