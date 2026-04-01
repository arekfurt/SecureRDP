# =============================================================================
# SecureRDP v0.848109 - SSH + RDP Basic Prototype Mode
# payload/OperationalCheck.psm1
#
# Exported function: Get-BasicOpState
# Called by ServerWizard.ps1 main dashboard to summarise this mode's status.
#
# Detects both Phase 1a installations (sshd service, $env:ProgramData\ssh)
# and future SSHProtoCore installations (SecureRDP-SSH service,
# C:\ProgramData\SecureRDP\ssh).
# =============================================================================
Set-StrictMode -Version Latest

function Get-BasicOpState {
    <#
    .SYNOPSIS
        Returns the operational state of the SSH + RDP Basic Prototype Mode.

    .OUTPUTS
        Hashtable:
            ModeName     : Display name of this mode
            LockStatus   : 'locked' | 'partial' | 'unlocked'
            Summary      : One-line human description of current state
            Details      : Array of detail strings (for expanded view)
            Errors       : Array of error strings (empty = no errors)
    #>

    $modeName = 'SSH + RDP Basic Prototype Mode'
    $details  = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    # --- Load state.json ---
    $stateFile = Join-Path $PSScriptRoot 'state.json'
    $state     = $null
    if (Test-Path $stateFile) {
        try {
            $state = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $details.Add("State file loaded.")
        } catch {
            $errMsg = $_.Exception.Message
            $errors.Add("state.json could not be read: $errMsg")
        }
    } else {
        $errors.Add('state.json not found -- mode may not be configured.')
    }

    # --- Check for reboot-required state ---
    # Engine1 succeeded with RequiresReboot=true and Engine2 not yet run
    if ($null -ne $state) {
        $stProps = $state.PSObject.Properties.Name
        if ($stProps -contains 'Engine1' -and $null -ne $state.Engine1 -and
            $state.Engine1.Success -eq $true) {
            try {
                $e1dProps = $state.Engine1.Data.PSObject.Properties.Name
                $needsReboot = ($e1dProps -contains 'RequiresReboot' -and
                                $state.Engine1.Data.RequiresReboot -eq $true)
                $e2Missing   = (-not ($stProps -contains 'Engine2') -or $null -eq $state.Engine2)
                if ($needsReboot -and $e2Missing) {
                    return @{
                        ModeName   = $modeName
                        LockStatus = 'reboot_required'
                        Summary    = 'System restart required to complete SSH installation.'
                        Details    = @('Engine 1 (SSH binary) installed successfully.',
                                       'A reboot is required before Engine 2 (service configuration) can run.')
                        Errors     = @()
                    }
                }
            } catch {}
        }
    }

    # --- Detect installation style ---
    # Phase 1a uses 'sshd' service and $env:ProgramData\ssh paths.
    # Future SSHProtoCore uses 'SecureRDP-SSH' and C:\ProgramData\SecureRDP\ssh.
    $phase1aConfigDir   = Join-Path $env:ProgramData 'ssh'
    $srdpConfigDir      = 'C:\ProgramData\SecureRDP\ssh'

    $svcPhase1a = Get-Service -Name 'sshd'            -ErrorAction SilentlyContinue
    $svcSrdp    = Get-Service -Name 'SecureRDP-SSH'   -ErrorAction SilentlyContinue

    $activeSvc     = $null
    $activeSvcName = $null
    $activeAkPath  = $null

    if ($null -ne $svcSrdp) {
        $activeSvc     = $svcSrdp
        $activeSvcName = 'SecureRDP-SSH'
        $details.Add("Detected SSHProtoCore installation (SecureRDP-SSH service).")
    } elseif ($null -ne $svcPhase1a) {
        $activeSvc     = $svcPhase1a
        $activeSvcName = 'sshd'
        $details.Add("Detected Phase 1a installation (sshd service).")
    }

    # authorized_keys is always in the SecureRDP data directory regardless of
    # which service is active. Add-SrdpAuthorizedKey always writes here, and
    # the SecureRDP-generated sshd_config always points here via AuthorizedKeysFile.
    $activeAkPath = Join-Path $srdpConfigDir 'authorized_keys'

    # --- Check SSH service ---
    if ($null -eq $activeSvc) {
        $errors.Add("SSH service not found (checked: sshd, SecureRDP-SSH). Phase 1a may not have completed.")
        try { Write-SrdpLog "OpCheck: SSH service not found." -Level ERROR -Component 'OpCheck' } catch {}
    } elseif ($activeSvc.Status -ne 'Running') {
        $errors.Add("$activeSvcName service is not running (status: $($activeSvc.Status)).")
    } else {
        $details.Add("$activeSvcName service: Running.")
        if ($activeSvc.StartType -ne 'Automatic') {
            $details.Add("Note: $activeSvcName startup type is '$($activeSvc.StartType)' (expected Automatic).")
        }
    }

    # --- Check authorized_keys ---
    $keyCount = 0
    if ($null -ne $activeAkPath) {
        if (Test-Path $activeAkPath) {
            $akLines = @(Get-Content $activeAkPath -Encoding UTF8 -ErrorAction SilentlyContinue |
                Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' })
            $keyCount = $akLines.Count
            if ($keyCount -gt 0) {
                $details.Add("authorized_keys: $keyCount active entr$(if ($keyCount -eq 1) {'y'} else {'ies'}).")
            } else {
                $details.Add("authorized_keys exists but is empty -- no client package generated yet.")
            }
        } else {
            $details.Add("authorized_keys not found -- no client package generated yet.")
        }
    }

    # --- Check firewall rules ---
    # SecureRDP-SSH-Inbound is created (disabled) by Phase 1a.
    # RDP block rules are created by Phase 2 (not yet built).
    # After Phase 1a only: SSH rule present-but-disabled is expected, RDP rules absent is expected.
    $sshRule = Get-NetFirewallRule -Name 'SecureRDP-SSH-Inbound' -ErrorAction SilentlyContinue
    $rdpBlockTcp = Get-NetFirewallRule -Name 'SecureRDP-RDP-BlockDirect' -ErrorAction SilentlyContinue
    $rdpBlockUdp = Get-NetFirewallRule -Name 'SecureRDP-RDP-BlockDirect-UDP' -ErrorAction SilentlyContinue

    if ($null -eq $sshRule) {
        $details.Add("SSH inbound firewall rule not yet created.")
    } elseif ($sshRule.Enabled -eq 'True') {
        $details.Add("SSH inbound firewall rule: Enabled.")
    } else {
        $details.Add("SSH inbound firewall rule: Present but disabled (enable to allow SSH connections).")
    }

    if ($null -eq $rdpBlockTcp -and $null -eq $rdpBlockUdp) {
        $details.Add("RDP block rules not yet created (created in next setup step).")
    } else {
        foreach ($r in @($rdpBlockTcp, $rdpBlockUdp) | Where-Object { $null -ne $_ }) {
            if ($r.Enabled -eq 'True') {
                $details.Add("Firewall rule enabled: $($r.Name).")
            } else {
                $details.Add("Firewall rule present but disabled: $($r.Name).")
            }
        }
    }

    # --- Authorized key count from state.json ---
    $stateKeyCount = 0
    if ($null -ne $state -and $null -ne $state.AuthorizedKeys) {
        $stateKeyCount = @($state.AuthorizedKeys).Count
    }

    # --- Determine LockStatus ---
    # After Phase 1a: sshd running, rules present (possibly disabled), no keys yet = partial
    # Locked requires: service running, SSH rule enabled, at least one key, RDP block rules enabled
    $sshRuleEnabled = ($null -ne $sshRule -and $sshRule.Enabled -eq 'True')
    $rdpBlocked     = ($null -ne $rdpBlockTcp -and $rdpBlockTcp.Enabled -eq 'True') -and
                      ($null -ne $rdpBlockUdp -and $rdpBlockUdp.Enabled -eq 'True')
    $svcRunning     = ($null -ne $activeSvc -and $activeSvc.Status -eq 'Running')
    $hasKeys        = ($keyCount -gt 0)

    $locked  = $svcRunning -and $sshRuleEnabled -and $rdpBlocked -and $hasKeys
    $anyWork = ($null -ne $state) -or ($null -ne $activeSvc)

    $lockStatus = if     ($locked)   { 'locked'   }
                  elseif ($anyWork)  { 'partial'  }
                  else               { 'unlocked' }

    $acctSuffix = if ($hasKeys) {
        "$keyCount authorized key$(if ($keyCount -ne 1) {'s'}) configured."
    } else { 'No client packages generated yet.' }

    $summary = switch ($lockStatus) {
        'locked'   { "SSH tunnel active. Direct RDP blocked. $acctSuffix" }
        'partial'  { "SSH installed and configured. Additional setup needed. $acctSuffix" }
        'unlocked' { "Not configured. Direct RDP may be accessible." }
    }

    return @{
        ModeName   = $modeName
        LockStatus = $lockStatus
        Summary    = $summary
        Details    = @($details)
        Errors     = @($errors)
    }
}

Export-ModuleMember -Function Get-BasicOpState
