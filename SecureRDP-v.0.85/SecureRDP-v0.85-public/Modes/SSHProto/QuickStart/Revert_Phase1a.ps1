param(
    [string]$StateFilePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Load central logging if available
# Try multiple paths since revert may run from different working dirs
$_srdpRevertLogPaths = @(
    (Join-Path $PSScriptRoot '..\..\..\..\SupportingModules\SrdpLog.psm1'),
    (Join-Path $PSScriptRoot '..\..\SupportingModules\SrdpLog.psm1')
)
foreach ($_p in $_srdpRevertLogPaths) {
    if (Test-Path $_p) {
        Import-Module $_p -Force
        $ErrorActionPreference = 'Stop'
        Initialize-SrdpLog -Component 'Revert-Phase1a'
        try { Write-SrdpLog "Revert_Phase1a starting." -Level INFO } catch {}
        break
    }
}

# Load SSHProtoCore for Remove-SrdpLoopbackRestriction (Phase 2 revert)
$_srdpCorePaths = @(
    (Join-Path $PSScriptRoot '..\SSHProtoCore.psm1'),
    (Join-Path $PSScriptRoot '..\..\Modes\SSHProto\SSHProtoCore.psm1')
)
foreach ($_cp in $_srdpCorePaths) {
    if (Test-Path $_cp) {
        Import-Module $_cp -Force -DisableNameChecking
        $ErrorActionPreference = 'Stop'
        break
    }
}

# =============================================================================
# SECURE-RDP PHASE 1A: REVERT SCRIPT
# Reverts changes made by Engine 1 (SSH Binary) and Engine 2 (SSH Service).
# Can be called standalone from the command line or invoked by the controller,
# the GUI reverter, or TestNow2.
#
# Usage:
#   .\Revert_Phase1a.ps1
#   .\Revert_Phase1a.ps1 -StateFilePath 'C:\custom\path\phase1a_state.json'
#   .\Revert_Phase1a.ps1 -Engine1Result $e1 -Engine2Result $e2
# =============================================================================

# =============================================================================
# SCRIPT-SCOPE HELPERS
# Helpers are at script scope (not nested inside Invoke-Phase1aRevert).
# They communicate via $script:RevertResult and $script:Revert* context vars
# set by Invoke-Phase1aRevert before calling them.
# =============================================================================

function Stop-Phase1aSshd {
    try {
        $svc = Get-Service 'sshd' -ErrorAction SilentlyContinue
        if ($null -ne $svc -and $svc.Status -eq 'Running') {
            Stop-Service 'sshd' -Force -ErrorAction SilentlyContinue
            $script:RevertResult.Logs.Add("Engine 2: sshd service stopped.")
        }
    } catch {}
}

function Restore-Phase1aBackupFiles {
    if ([string]::IsNullOrEmpty($script:RevertBackupPath) -or
        -not (Test-Path $script:RevertBackupPath)) {
        $script:RevertResult.Logs.Add(
            "Engine 2: No backup path available or backup folder missing -- skipping file restore.")
        return
    }
    $files = @(Get-ChildItem $script:RevertBackupPath -ErrorAction SilentlyContinue)
    foreach ($file in $files) {
        try {
            $dest = Join-Path $script:RevertBaseConfigDir $file.Name
            Copy-Item $file.FullName $dest -Force
            $script:RevertResult.Data.FilesRestored.Add($dest)
            $script:RevertResult.Logs.Add("Engine 2: Restored $($file.Name) to $dest")
        } catch {
            $script:RevertResult.Errors.Add(
                "Engine 2: Failed to restore $($file.Name): $($_.Exception.Message)")
        }
    }
}

function Restore-Phase1aServiceMetadata {
    try {
        Set-Service 'sshd' -DisplayName 'OpenSSH SSH Server' `
            -StartupType $script:RevertOrigStart -ErrorAction Stop
        $script:RevertResult.Logs.Add(
            "Engine 2: Service display name and start type restored (StartType=$script:RevertOrigStart).")
    } catch {
        $script:RevertResult.Errors.Add(
            "Engine 2: Failed to restore service metadata: $($_.Exception.Message)")
    }
}

function Restart-Phase1aSshdIfNeeded {
    if ($script:RevertOrigState -eq 'Running') {
        try {
            Start-Service 'sshd' -ErrorAction Stop
            $script:RevertResult.Logs.Add("Engine 2: sshd restarted (was originally running).")
        } catch {
            $script:RevertResult.Errors.Add(
                "Engine 2: Failed to restart sshd: $($_.Exception.Message)")
        }
    } else {
        $script:RevertResult.Logs.Add(
            "Engine 2: sshd was not originally running -- not restarting.")
    }
}

function Remove-Phase1aOurConfig {
    if (-not [string]::IsNullOrEmpty($script:RevertConfigPath) -and
        (Test-Path $script:RevertConfigPath)) {
        try {
            Remove-Item $script:RevertConfigPath -Force -ErrorAction Stop
            $script:RevertResult.Logs.Add(
                "Engine 2: Removed SecureRDP sshd_config at $script:RevertConfigPath")
        } catch {
            $script:RevertResult.Errors.Add(
                "Engine 2: Failed to remove config file: $($_.Exception.Message)")
        }
    }
}

# =============================================================================
# MAIN ENTRY POINT: Invoke-Phase1aRevert
# =============================================================================
function Invoke-Phase1aRevert {
    param(
        [string]$StateFilePath         = 'C:\ProgramData\SecureRDP\phase1a_state.json',
        [PSCustomObject]$Engine1Result = $null,
        [PSCustomObject]$Engine2Result = $null,
        [string]$BaseConfigDir         = "$env:ProgramData\ssh"
    )

    $script:RevertResult = [PSCustomObject]@{
        Success = $false
        Status  = 'Unknown'
        Data    = @{
            Engine1Reverted = $false
            Engine2Reverted = $false
            Phase2Reverted  = $false
            FilesRestored   = [System.Collections.Generic.List[string]]::new()
            RebootRequired  = $false
        }
        Logs    = [System.Collections.Generic.List[string]]::new()
        Errors  = [System.Collections.Generic.List[string]]::new()
    }

    $script:RevertResult.Logs.Add("Starting Phase 1a Revert...")

    # -------------------------------------------------------------------------
    # State loading
    # -------------------------------------------------------------------------
    if ($null -eq $Engine1Result -and $null -eq $Engine2Result) {
        $script:RevertResult.Logs.Add(
            "No result objects supplied. Reading state from: $StateFilePath")
        if (-not (Test-Path $StateFilePath)) {
            $script:RevertResult.Errors.Add("State file not found at: $StateFilePath")
        try { Write-SrdpLog "REVERT ERROR recorded" -Level ERROR } catch {}
            $script:RevertResult.Status = 'StateMissing'
            return $script:RevertResult
        }
        try {
            $state         = Get-Content $StateFilePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $Engine1Result = $state.Engine1
            $Engine2Result = $state.Engine2
            $script:RevertResult.Logs.Add("State loaded successfully from file.")
        } catch {
            $script:RevertResult.Errors.Add(
                "Failed to read or parse state file: $($_.Exception.Message)")
            $script:RevertResult.Status = 'StateMissing'
            return $script:RevertResult
        }
    } else {
        $script:RevertResult.Logs.Add("Using supplied result objects directly.")
    }

    if ($null -eq $Engine1Result) {
        $script:RevertResult.Errors.Add(
            "Engine1Result is null after state load -- cannot revert Engine 1.")
    }
    if ($null -eq $Engine2Result) {
        $script:RevertResult.Errors.Add(
            "Engine2Result is null after state load -- cannot revert Engine 2.")
    }
    if ($script:RevertResult.Errors.Count -gt 0) {
        $script:RevertResult.Status = 'StateMissing'
        return $script:RevertResult
    }

    # -------------------------------------------------------------------------
    # Engine 1 revert -- based on InstallAction
    # -------------------------------------------------------------------------
    $script:RevertResult.Logs.Add("--- Engine 1 Revert ---")
    try { Write-SrdpLog "--- Engine 1 Revert ---" -Level INFO } catch {}
    $e1Action = $Engine1Result.Data.InstallAction

    if ($e1Action -eq 'AlreadyPresent' -or $e1Action -eq 'None') {
        $script:RevertResult.Logs.Add(
            "Engine 1: InstallAction='$e1Action' -- no changes to revert.")
        $script:RevertResult.Data.Engine1Reverted = $true
    } elseif ($e1Action -eq 'Installed') {
        $script:RevertResult.Logs.Add(
            "Engine 1: OpenSSH was installed by SecureRDP. Removing via Remove-WindowsCapability...")
        try {
            Remove-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' `
                -ErrorAction Stop | Out-Null
            $script:RevertResult.Data.RebootRequired  = $true
            $script:RevertResult.Data.Engine1Reverted = $true
            $script:RevertResult.Logs.Add(
                "Engine 1: OpenSSH optional feature removed. Reboot required.")
        } catch {
            $script:RevertResult.Errors.Add(
                "Engine 1 revert failed (Remove-WindowsCapability): $($_.Exception.Message)")
            $script:RevertResult.Logs.Add(
                "Engine 1: Removal failed. Manual uninstall may be required.")
        }
    } else {
        $script:RevertResult.Logs.Add(
            "Engine 1: Unrecognised InstallAction '$e1Action' -- skipping.")
        $script:RevertResult.Data.Engine1Reverted = $true
    }

    # -------------------------------------------------------------------------
    # Engine 2 revert -- based on ActionTaken
    # Publish revert context to script scope so helper functions can access it
    # -------------------------------------------------------------------------
    $script:RevertResult.Logs.Add("--- Engine 2 Revert ---")
    try { Write-SrdpLog "--- Engine 2 Revert ---" -Level INFO } catch {}

    $script:RevertBackupPath     = $Engine2Result.Data.BackupPath
    $script:RevertConfigPath     = $Engine2Result.Data.SshdConfigPath
    $script:RevertOrigState      = $Engine2Result.Data.OriginalServiceState
    $script:RevertOrigStart      = $Engine2Result.Data.OriginalStartType
    $script:RevertBaseConfigDir  = $BaseConfigDir
    $e2Action                    = $Engine2Result.Data.ActionTaken

    $script:RevertResult.Logs.Add("Engine 2: ActionTaken='$e2Action'")

    switch ($e2Action) {
        'FreshConfig' {
            $script:RevertResult.Logs.Add(
                "Engine 2: FreshConfig -- stopping service and removing config.")
            Stop-Phase1aSshd
            Remove-Phase1aOurConfig
            $script:RevertResult.Data.Engine2Reverted = $true
        }
        'ServiceOnly' {
            $script:RevertResult.Logs.Add(
                "Engine 2: ServiceOnly -- removing config, restoring service metadata.")
            Stop-Phase1aSshd
            Remove-Phase1aOurConfig
            Restore-Phase1aServiceMetadata
            Restart-Phase1aSshdIfNeeded
            $script:RevertResult.Data.Engine2Reverted = $true
        }
        'ConfigOnly' {
            $script:RevertResult.Logs.Add(
                "Engine 2: ConfigOnly -- restoring backed-up files and restarting service.")
            Stop-Phase1aSshd
            Restore-Phase1aBackupFiles
            Restart-Phase1aSshdIfNeeded
            $script:RevertResult.Data.Engine2Reverted = $true
        }
        'FullTakeover' {
            $script:RevertResult.Logs.Add(
                "Engine 2: FullTakeover -- full restore.")
            Stop-Phase1aSshd
            Restore-Phase1aBackupFiles
            Restore-Phase1aServiceMetadata
            Restart-Phase1aSshdIfNeeded
            $script:RevertResult.Data.Engine2Reverted = $true
        }
        default {
            $script:RevertResult.Logs.Add(
                "Engine 2: Unrecognised ActionTaken '$e2Action' -- skipping.")
            $script:RevertResult.Data.Engine2Reverted = $true
        }
    }

    # -------------------------------------------------------------------------
    # Re-enable Windows OpenSSH firewall rule if SecureRDP disabled it
    # -------------------------------------------------------------------------
    $winRuleWasDisabled = $false
    $e2Props = $Engine2Result.Data.PSObject.Properties.Name
    if ($e2Props -contains 'WindowsRuleDisabled') {
        $winRuleWasDisabled = ($Engine2Result.Data.WindowsRuleDisabled -eq $true)
    }

    if ($winRuleWasDisabled) {
        $script:RevertResult.Logs.Add("Re-enabling Windows OpenSSH firewall rule 'OpenSSH-Server-In-TCP'...")
        try {
            $winRule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
            if ($null -ne $winRule) {
                Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction Stop
                $script:RevertResult.Logs.Add("Re-enabled Windows-created firewall rule 'OpenSSH-Server-In-TCP'.")
            } else {
                $script:RevertResult.Logs.Add("Windows firewall rule 'OpenSSH-Server-In-TCP' no longer present -- skipping re-enable.")
            }
        } catch {
            $errMsg = $_.Exception.Message
            $script:RevertResult.Logs.Add("Warning: Could not re-enable Windows OpenSSH firewall rule: $errMsg.")
        }
    }

    # -------------------------------------------------------------------------
    # Phase 2 revert -- remove SecureRDP firewall rules and loopback restriction
    # -------------------------------------------------------------------------
    $script:RevertResult.Logs.Add("--- Phase 2 Revert ---")
    try { Write-SrdpLog "--- Phase 2 Revert ---" -Level INFO } catch {}

    $phase2Data = $null
    if ($null -ne $state) {
        $stateTopProps = $state.PSObject.Properties.Name
        if ($stateTopProps -contains 'Phase2' -and $null -ne $state.Phase2) {
            $phase2Data = $state.Phase2
        }
    }

    if ($null -eq $phase2Data) {
        $script:RevertResult.Logs.Add("Phase 2: No Phase2 data in state file -- skipping.")
        $script:RevertResult.Data.Phase2Reverted = $true
    } else {
        # Remove SecureRDP firewall rules
        $p2Props = $phase2Data.PSObject.Properties.Name
        $rulesCreated = ($p2Props -contains 'FirewallRulesCreated' -and $phase2Data.FirewallRulesCreated -eq $true)

        if ($rulesCreated) {
            $script:RevertResult.Logs.Add("Phase 2: Removing SecureRDP firewall rules...")
            foreach ($ruleName in @('SecureRDP-SSH-Inbound', 'SecureRDP-RDP-BlockDirect', 'SecureRDP-RDP-BlockDirect-UDP')) {
                try {
                    $existingRule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
                    if ($null -ne $existingRule) {
                        Remove-NetFirewallRule -Name $ruleName -ErrorAction Stop
                        $script:RevertResult.Logs.Add("Phase 2: Removed firewall rule '$ruleName'.")
                        try { Write-SrdpLog "Phase 2 revert: removed rule '$ruleName'." -Level INFO } catch {}
                    } else {
                        $script:RevertResult.Logs.Add("Phase 2: Rule '$ruleName' not present -- skipping.")
                    }
                } catch {
                    $fwErr = $_.Exception.Message
                    $script:RevertResult.Errors.Add("Phase 2: Could not remove rule '$ruleName': $fwErr")
                    try { Write-SrdpLog "Phase 2 revert: failed to remove '$ruleName': $fwErr" -Level ERROR } catch {}
                }
            }
        } else {
            $script:RevertResult.Logs.Add("Phase 2: FirewallRulesCreated=false -- no rules to remove.")
        }

        # Remove loopback restriction
        $loopApplied = ($p2Props -contains 'LoopbackRestrictionApplied' -and $phase2Data.LoopbackRestrictionApplied -eq $true)

        if ($loopApplied) {
            $script:RevertResult.Logs.Add("Phase 2: Removing loopback listener restriction...")
            try { Write-SrdpLog "Phase 2 revert: removing loopback restriction..." -Level INFO } catch {}

            $origAdapter = $null
            if ($p2Props -contains 'OriginalLanAdapter') {
                $origAdapter = $phase2Data.OriginalLanAdapter
            }

            try {
                $loopRevert = Remove-SrdpLoopbackRestriction -OriginalLanAdapter $origAdapter
                if ($loopRevert -is [string] -and $loopRevert -like 'error:*') {
                    $script:RevertResult.Errors.Add("Phase 2: Loopback revert failed: $loopRevert")
                    try { Write-SrdpLog "Phase 2 revert: loopback failed: $loopRevert" -Level ERROR } catch {}
                } else {
                    $script:RevertResult.Logs.Add("Phase 2: Loopback restriction removed. TermService restarted.")
                    try { Write-SrdpLog "Phase 2 revert: loopback removed." -Level INFO } catch {}
                }
            } catch {
                $loopErr = $_.Exception.Message
                $script:RevertResult.Errors.Add("Phase 2: Loopback revert exception: $loopErr")
                try { Write-SrdpLog "Phase 2 revert: loopback exception: $loopErr" -Level ERROR } catch {}
            }
        } else {
            $script:RevertResult.Logs.Add("Phase 2: LoopbackRestrictionApplied=false -- no restriction to remove.")
        }

        $script:RevertResult.Data.Phase2Reverted = $true
        $script:RevertResult.Logs.Add("Phase 2 revert complete.")
    }

    # -------------------------------------------------------------------------
    # Final status
    # -------------------------------------------------------------------------
    if ($script:RevertResult.Errors.Count -eq 0) {
        $script:RevertResult.Success = $true
        $script:RevertResult.Status  = if ($script:RevertResult.Data.RebootRequired) {
            'RevertedPendingReboot'
        } else { 'Reverted' }
    } else {
        $script:RevertResult.Success = $false
        $script:RevertResult.Status  = 'PartialRevert'
    }

    $script:RevertResult.Logs.Add(
        "Phase 1a Revert complete. Status=$($script:RevertResult.Status) " +
        "Errors=$($script:RevertResult.Errors.Count)")
    return $script:RevertResult
}

# =============================================================================
# Script-level entry point: invoke if run directly (not when dot-sourced)
# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {
    if ($StateFilePath -and $StateFilePath -ne '') {
        Invoke-Phase1aRevert -StateFilePath $StateFilePath
    } else {
        Invoke-Phase1aRevert
    }
}
