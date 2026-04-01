Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
# SECURE-RDP PHASE 2: CONTROLLER
# Orchestrates firewall rule creation, enable/disable, and optional
# loopback listener restriction.
# UI-agnostic -- no WinForms, no Write-Host, no Read-Host.
#
# All module imports are handled by the UI before dot-sourcing this file.
# Required modules: SSHProtoCore, FirewallReadWriteElements, InitialChecks,
#                   RDPStatus, SrdpLog
#
# Usage (pre-flight):
#   $pf = Invoke-Phase2Preflight -SshPort 22 -StateFilePath $path
#
# Usage (plan only):
#   $plan = Invoke-Phase2Controller -StateFilePath $path
#
# Usage (execute):
#   $result = Invoke-Phase2Controller -Confirmed $true -StateFilePath $path
# =============================================================================

# =============================================================================
# HELPER: Send-Progress
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
# HELPER: Write-Phase2State
# Reads existing state.json, preserves Engine1/Engine2, adds/updates Phase2.
# =============================================================================
function Write-Phase2State {
    param(
        [Parameter(Mandatory)][string]$StateFilePath,
        [Parameter(Mandatory)][hashtable]$Phase2Data,
        [int]$SshPort = 22
    )
    try {
        try { Write-SrdpLog "Write-Phase2State: writing to $StateFilePath" -Level INFO -Component 'Controller-Phase2' } catch {}

        $stateDir = Split-Path $StateFilePath -Parent
        if (-not (Test-Path $stateDir)) {
            New-Item -Path $stateDir -ItemType Directory -Force | Out-Null
        }

        # Read existing state to preserve Engine1/Engine2
        $existing = $null
        if (Test-Path $StateFilePath) {
            try {
                $existing = Get-Content $StateFilePath -Raw -Encoding UTF8 | ConvertFrom-Json
            } catch {}
        }

        $state = @{
            Engine1   = if ($null -ne $existing -and $null -ne $existing.Engine1) { $existing.Engine1 } else { $null }
            Engine2   = if ($null -ne $existing -and $null -ne $existing.Engine2) { $existing.Engine2 } else { $null }
            Phase2    = $Phase2Data
            Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            SshPort   = $SshPort
        }
        $state | ConvertTo-Json -Depth 10 | Set-Content $StateFilePath -Encoding UTF8
        try { Write-SrdpLog "Write-Phase2State: state written successfully." -Level INFO -Component 'Controller-Phase2' } catch {}
    } catch {
        $errMsg = $_.Exception.Message
        try { Write-SrdpLog "Write-Phase2State failed: $errMsg" -Level ERROR -Component 'Controller-Phase2' } catch {}
    }
}

# =============================================================================
# PREFLIGHT: Invoke-Phase2Preflight
# Checks Phase 1a completion and runs SSH verifier.
# =============================================================================
function Invoke-Phase2Preflight {
    param(
        [int]$SshPort        = 22,
        [string]$StateFilePath
    )

    $Result = [PSCustomObject]@{
        Success = $false
        Status  = 'Unknown'
        Data    = @{
            Phase1aComplete = $false
            StateData       = $null
            VerifierResult  = $null
            RdpPort         = 3389
        }
        Logs   = [System.Collections.Generic.List[string]]::new()
        Errors = [System.Collections.Generic.List[string]]::new()
    }

    try {
        $Result.Logs.Add("Phase 2 preflight starting.")
        try { Write-SrdpLog "Phase2 preflight: checking state at $StateFilePath" -Level INFO -Component 'Controller-Phase2' } catch {}

        # --- Check Phase 1a completion ---
        if (-not (Test-Path $StateFilePath)) {
            $Result.Errors.Add("State file not found at $StateFilePath. Quick Start Part 1 has not been run.")
            $Result.Status = 'Phase1aIncomplete'
            try { Write-SrdpLog "Phase2 preflight: state file not found." -Level ERROR -Component 'Controller-Phase2' } catch {}
            return $Result
        }

        $stateData = $null
        try {
            $stateData = Get-Content $StateFilePath -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            $parseErr = $_.Exception.Message
            $Result.Errors.Add("State file could not be read: $parseErr")
            $Result.Status = 'Phase1aIncomplete'
            return $Result
        }
        $Result.Data.StateData = $stateData

        # Check Engine1 and Engine2 success
        $e1Ok = ($null -ne $stateData.Engine1 -and $stateData.Engine1.Success -eq $true)
        $e2Ok = ($null -ne $stateData.Engine2 -and $stateData.Engine2.Success -eq $true)

        if (-not $e1Ok -or -not $e2Ok) {
            $Result.Errors.Add("Quick Start Part 1 has not been completed successfully. Engine1=$e1Ok Engine2=$e2Ok")
            $Result.Status = 'Phase1aIncomplete'
            try { Write-SrdpLog "Phase2 preflight: Phase 1a incomplete. E1=$e1Ok E2=$e2Ok" -Level ERROR -Component 'Controller-Phase2' } catch {}
            return $Result
        }

        $Result.Data.Phase1aComplete = $true
        $Result.Logs.Add("Phase 1a verified complete.")

        # Get RDP port from state or default -- use PSObject.Properties to avoid
        # StrictMode throw on missing property
        try {
            if ($null -ne $stateData.Engine2 -and $null -ne $stateData.Engine2.Data) {
                $e2Props = $stateData.Engine2.Data.PSObject.Properties.Name
                if ($e2Props -contains 'RdpPort') {
                    $Result.Data.RdpPort = [int]$stateData.Engine2.Data.RdpPort
                }
            }
        } catch {}

        # --- Run SSH Verifier ---
        $Result.Logs.Add("Running SSH verifier...")
        try { Write-SrdpLog "Phase2 preflight: running SSH verifier on port $SshPort" -Level INFO -Component 'Controller-Phase2' } catch {}

        $verResult = Invoke-SrdpSshVerifier -SshPort $SshPort
        $Result.Data.VerifierResult = $verResult

        if ($verResult.Status -eq 'Failed' -or $verResult.Status -eq 'FatalError') {
            $Result.Errors.Add("SSH verification failed: $($verResult.Status). See check details.")
            foreach ($err in $verResult.Errors) { $Result.Errors.Add($err) }
            $Result.Status = 'SshFailed'
            try { Write-SrdpLog "Phase2 preflight: SSH verifier failed." -Level ERROR -Component 'Controller-Phase2' } catch {}
            return $Result
        }

        if ($verResult.Status -eq 'Degraded') {
            $Result.Success = $true
            $Result.Status  = 'SshDegraded'
            $Result.Logs.Add("SSH verifier: Degraded (non-critical issues). Proceeding.")
            try { Write-SrdpLog "Phase2 preflight: SSH degraded but operational." -Level WARN -Component 'Controller-Phase2' } catch {}
        } else {
            $Result.Success = $true
            $Result.Status  = 'Ready'
            $Result.Logs.Add("SSH verifier: Healthy. Ready to proceed.")
            try { Write-SrdpLog "Phase2 preflight: ready." -Level INFO -Component 'Controller-Phase2' } catch {}
        }

    } catch {
        $errMsg = $_.Exception.Message
        $Result.Errors.Add("Preflight fatal error: $errMsg")
        $Result.Status = 'FatalError'
        try { Write-SrdpLog "Phase2 preflight fatal: $errMsg" -Level ERROR -Component 'Controller-Phase2' } catch {}
    }

    return $Result
}

# =============================================================================
# MAIN: Invoke-Phase2Controller
# =============================================================================
function Invoke-Phase2Controller {
    param(
        [int]$SshPort             = 22,
        [int]$RdpPort             = 3389,
        [bool]$Confirmed          = $false,
        [bool]$EnableSshRule      = $true,
        [bool]$EnableRdpBlock     = $true,
        [bool]$ApplyLoopback      = $false,
        [Parameter(Mandatory)][string]$StateFilePath,
        [scriptblock]$OnProgress  = $null
    )

    $Result = [PSCustomObject]@{
        Success = $false
        Status  = 'Unknown'
        Data    = @{
            Plan                = $null
            FirewallRulesCreated = $false
            SshRuleEnabled      = $false
            RdpBlockEnabled     = $false
            LoopbackApplied     = $false
            OriginalLanAdapter  = $null
        }
        Logs   = [System.Collections.Generic.List[string]]::new()
        Errors = [System.Collections.Generic.List[string]]::new()
    }

    # ---- Build plan ----
    $planSteps = [System.Collections.Generic.List[string]]::new()
    $planSteps.Add("Create SecureRDP firewall rules (SSH allow, RDP block TCP, RDP block UDP).")

    if ($EnableSshRule) {
        $planSteps.Add("Enable SSH inbound rule on port $SshPort.")
    } else {
        $planSteps.Add("Leave SSH inbound rule disabled.")
    }

    if ($EnableRdpBlock) {
        $planSteps.Add("Enable RDP block rules on port $RdpPort (TCP + UDP).")
    } else {
        $planSteps.Add("Leave RDP block rules disabled.")
    }

    if ($ApplyLoopback) {
        $planSteps.Add("Restrict RDP listener to loopback adapter only (experimental). Remote Desktop service will restart.")
    }

    $planSteps.Add("Write configuration state.")
    $planSteps.Add("Verify configuration.")

    $Result.Data.Plan = [PSCustomObject]@{
        Steps = @($planSteps)
    }

    if (-not $Confirmed) {
        $Result.Status = 'PlanOnly'
        $Result.Logs.Add("Plan generated. Awaiting confirmation.")
        return $Result
    }

    # ---- Execute ----
    $callerEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'

    $totalSteps = $planSteps.Count
    $currentStep = 0
    $criticalFailure = $false

    try {
        try { Write-SrdpLog "Phase2 controller: executing. SSH=$EnableSshRule RDP=$EnableRdpBlock Loop=$ApplyLoopback" -Level INFO -Component 'Controller-Phase2' } catch {}

        # --- Step 1: Create firewall rules ---
        $currentStep++
        Send-Progress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'CreateRules' -Message "Creating firewall rules..." -OnProgress $OnProgress
        $Result.Logs.Add("Step $currentStep : Creating firewall rules...")
        try { Write-SrdpLog "Phase2: Step $currentStep - creating firewall rules" -Level INFO -Component 'Controller-Phase2' } catch {}

        try {
            $fwResult = New-SrdpFirewallRules -RdpPort $RdpPort -SshPort $SshPort
            if ($fwResult -is [string] -and $fwResult -like 'error:*') {
                $Result.Errors.Add("Firewall rule creation failed: $fwResult")
                Send-Progress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'CreateRules' -Message "FAILED: $fwResult" -IsWarning $true -OnProgress $OnProgress
                $criticalFailure = $true
                try { Write-SrdpLog "Phase2: firewall rule creation failed: $fwResult" -Level ERROR -Component 'Controller-Phase2' } catch {}
            } else {
                $Result.Data.FirewallRulesCreated = $true
                Send-Progress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'CreateRules' -Message "Firewall rules created." -OnProgress $OnProgress
                try { Write-SrdpLog "Phase2: firewall rules created successfully." -Level INFO -Component 'Controller-Phase2' } catch {}
            }
        } catch {
            $fwErr = $_.Exception.Message
            $Result.Errors.Add("Firewall rule creation exception: $fwErr")
            Send-Progress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'CreateRules' -Message "FAILED: $fwErr" -IsWarning $true -OnProgress $OnProgress
            $criticalFailure = $true
            try { Write-SrdpLog "Phase2: firewall exception: $fwErr" -Level ERROR -Component 'Controller-Phase2' } catch {}
        }

        # --- Step 2: SSH rule enable/disable ---
        $currentStep++
        if ($EnableSshRule) {
            Send-Progress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'SshRule' -Message "Enabling SSH inbound rule..." -OnProgress $OnProgress
            $Result.Logs.Add("Step $currentStep : Enabling SSH inbound rule...")
        } else {
            Send-Progress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'SshRule' -Message "Disabling SSH inbound rule..." -OnProgress $OnProgress
            $Result.Logs.Add("Step $currentStep : Disabling SSH inbound rule...")
        }

        if ($Result.Data.FirewallRulesCreated) {
            try {
                if (-not $EnableSshRule) {
                    Disable-NetFirewallRule -Name 'SecureRDP-SSH-Inbound' -ErrorAction Stop
                }
                # Verify
                $sshRule = Get-NetFirewallRule -Name 'SecureRDP-SSH-Inbound' -ErrorAction Stop
                $expectedEnabled = if ($EnableSshRule) { 'True' } else { 'False' }
                if ($sshRule.Enabled.ToString() -eq $expectedEnabled) {
                    $Result.Data.SshRuleEnabled = $EnableSshRule
                    $stateStr = if ($EnableSshRule) { 'enabled' } else { 'disabled' }
                    Send-Progress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'SshRule' -Message "SSH inbound rule $stateStr and verified." -OnProgress $OnProgress
                    try { Write-SrdpLog "Phase2: SSH rule $stateStr and verified." -Level INFO -Component 'Controller-Phase2' } catch {}
                } else {
                    $Result.Errors.Add("SSH rule state verification failed. Expected=$expectedEnabled Got=$($sshRule.Enabled)")
                    Send-Progress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'SshRule' -Message "WARNING: SSH rule state mismatch." -IsWarning $true -OnProgress $OnProgress
                    try { Write-SrdpLog "Phase2: SSH rule verification mismatch." -Level WARN -Component 'Controller-Phase2' } catch {}
                }
            } catch {
                $sshErr = $_.Exception.Message
                $Result.Errors.Add("SSH rule configuration failed: $sshErr")
                Send-Progress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'SshRule' -Message "FAILED: $sshErr" -IsWarning $true -OnProgress $OnProgress
                try { Write-SrdpLog "Phase2: SSH rule error: $sshErr" -Level ERROR -Component 'Controller-Phase2' } catch {}
            }
        } else {
            Send-Progress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'SshRule' -Message "Skipped (firewall rule creation failed)." -IsWarning $true -OnProgress $OnProgress
            $Result.Logs.Add("Step $currentStep : Skipped -- rules not created.")
        }

        # --- Step 3: RDP block rules enable/disable ---
        $currentStep++
        if ($EnableRdpBlock) {
            Send-Progress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'RdpBlock' -Message "Enabling RDP block rules..." -OnProgress $OnProgress
            $Result.Logs.Add("Step $currentStep : Enabling RDP block rules...")
        } else {
            Send-Progress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'RdpBlock' -Message "Disabling RDP block rules..." -OnProgress $OnProgress
            $Result.Logs.Add("Step $currentStep : Disabling RDP block rules...")
        }

        if ($Result.Data.FirewallRulesCreated) {
            try {
                if (-not $EnableRdpBlock) {
                    Disable-NetFirewallRule -Name 'SecureRDP-RDP-BlockDirect' -ErrorAction Stop
                    Disable-NetFirewallRule -Name 'SecureRDP-RDP-BlockDirect-UDP' -ErrorAction Stop
                }
                # Verify both rules
                $rdpTcp = Get-NetFirewallRule -Name 'SecureRDP-RDP-BlockDirect' -ErrorAction Stop
                $rdpUdp = Get-NetFirewallRule -Name 'SecureRDP-RDP-BlockDirect-UDP' -ErrorAction Stop
                $expectedEnabled = if ($EnableRdpBlock) { 'True' } else { 'False' }
                $tcpOk = ($rdpTcp.Enabled.ToString() -eq $expectedEnabled)
                $udpOk = ($rdpUdp.Enabled.ToString() -eq $expectedEnabled)

                if ($tcpOk -and $udpOk) {
                    $Result.Data.RdpBlockEnabled = $EnableRdpBlock
                    $stateStr = if ($EnableRdpBlock) { 'enabled' } else { 'disabled' }
                    Send-Progress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'RdpBlock' -Message "RDP block rules $stateStr and verified." -OnProgress $OnProgress
                    try { Write-SrdpLog "Phase2: RDP block rules $stateStr and verified." -Level INFO -Component 'Controller-Phase2' } catch {}
                } else {
                    $Result.Errors.Add("RDP block rule verification failed. TCP=$tcpOk UDP=$udpOk")
                    Send-Progress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'RdpBlock' -Message "WARNING: RDP block rule state mismatch." -IsWarning $true -OnProgress $OnProgress
                    try { Write-SrdpLog "Phase2: RDP block verification mismatch. TCP=$tcpOk UDP=$udpOk" -Level WARN -Component 'Controller-Phase2' } catch {}
                }
            } catch {
                $rdpErr = $_.Exception.Message
                $Result.Errors.Add("RDP block rule configuration failed: $rdpErr")
                Send-Progress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'RdpBlock' -Message "FAILED: $rdpErr" -IsWarning $true -OnProgress $OnProgress
                try { Write-SrdpLog "Phase2: RDP block error: $rdpErr" -Level ERROR -Component 'Controller-Phase2' } catch {}
            }
        } else {
            Send-Progress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'RdpBlock' -Message "Skipped (firewall rule creation failed)." -IsWarning $true -OnProgress $OnProgress
            $Result.Logs.Add("Step $currentStep : Skipped -- rules not created.")
        }

        # --- Step 4 (conditional): Loopback restriction ---
        if ($ApplyLoopback) {
            $currentStep++
            Send-Progress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'Loopback' -Message "Applying loopback listener restriction..." -OnProgress $OnProgress
            $Result.Logs.Add("Step $currentStep : Applying loopback restriction...")
            try { Write-SrdpLog "Phase2: applying loopback restriction..." -Level INFO -Component 'Controller-Phase2' } catch {}

            try {
                $loopResult = Set-SrdpLoopbackRestriction
                if ($loopResult -is [string] -and $loopResult -like 'error:*') {
                    $Result.Errors.Add("Loopback restriction failed: $loopResult")
                    Send-Progress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'Loopback' -Message "FAILED: $loopResult" -IsWarning $true -OnProgress $OnProgress
                    try { Write-SrdpLog "Phase2: loopback failed: $loopResult" -Level ERROR -Component 'Controller-Phase2' } catch {}
                } else {
                    $Result.Data.LoopbackApplied    = $true
                    $Result.Data.OriginalLanAdapter = $loopResult.OriginalLanAdapter
                    Send-Progress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'Loopback' -Message "Loopback restriction applied (adapter index $($loopResult.AppliedIndex)). TermService restarted." -OnProgress $OnProgress
                    try { Write-SrdpLog "Phase2: loopback applied. Original=$($loopResult.OriginalLanAdapter) Index=$($loopResult.AppliedIndex)" -Level INFO -Component 'Controller-Phase2' } catch {}
                }
            } catch {
                $loopErr = $_.Exception.Message
                $Result.Errors.Add("Loopback restriction exception: $loopErr")
                Send-Progress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'Loopback' -Message "FAILED: $loopErr" -IsWarning $true -OnProgress $OnProgress
                try { Write-SrdpLog "Phase2: loopback exception: $loopErr" -Level ERROR -Component 'Controller-Phase2' } catch {}
            }
        }

        # --- Step N-1: Write state ---
        $currentStep++
        Send-Progress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'WriteState' -Message "Saving configuration state..." -OnProgress $OnProgress
        $Result.Logs.Add("Step $currentStep : Writing state...")

        $overallSuccess = $Result.Data.FirewallRulesCreated -and (-not $criticalFailure)
        $phase2State = @{
            Success                    = $overallSuccess
            Timestamp                  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            FirewallRulesCreated       = $Result.Data.FirewallRulesCreated
            SshRuleEnabled             = $Result.Data.SshRuleEnabled
            RdpBlockEnabled            = $Result.Data.RdpBlockEnabled
            LoopbackRestrictionApplied = $Result.Data.LoopbackApplied
            OriginalLanAdapter         = $Result.Data.OriginalLanAdapter
        }
        Write-Phase2State -StateFilePath $StateFilePath -Phase2Data $phase2State -SshPort $SshPort
        Send-Progress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'WriteState' -Message "Configuration state saved." -OnProgress $OnProgress

        # --- Step N: Verify ---
        $currentStep++
        Send-Progress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'Verify' -Message "Verifying configuration..." -OnProgress $OnProgress
        $Result.Logs.Add("Step $currentStep : Verifying...")

        try {
            $verifyState = Get-Content $StateFilePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $verifyState.Phase2 -and $verifyState.Phase2.Success -eq $overallSuccess) {
                Send-Progress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'Verify' -Message "Configuration verified." -OnProgress $OnProgress
                try { Write-SrdpLog "Phase2: state verification passed." -Level INFO -Component 'Controller-Phase2' } catch {}
            } else {
                $Result.Errors.Add("State file verification: Phase2 section missing or success mismatch.")
                Send-Progress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'Verify' -Message "WARNING: State verification mismatch." -IsWarning $true -OnProgress $OnProgress
                try { Write-SrdpLog "Phase2: state verification mismatch." -Level WARN -Component 'Controller-Phase2' } catch {}
            }
        } catch {
            $verErr = $_.Exception.Message
            $Result.Errors.Add("State verification failed: $verErr")
            Send-Progress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'Verify' -Message "WARNING: Could not verify state file." -IsWarning $true -OnProgress $OnProgress
        }

        # --- Final status ---
        if ($overallSuccess -and $Result.Errors.Count -eq 0) {
            $Result.Success = $true
            $Result.Status  = 'Configured'
        } elseif ($overallSuccess) {
            $Result.Success = $true
            $Result.Status  = 'Configured'
            $Result.Logs.Add("Configuration complete with $($Result.Errors.Count) non-fatal warning(s).")
        } else {
            $Result.Success = $false
            $Result.Status  = if ($criticalFailure) { 'Failed' } else { 'PartialFailure' }
        }

        try { Write-SrdpLog "Phase2 controller complete. Status=$($Result.Status) Errors=$($Result.Errors.Count)" -Level INFO -Component 'Controller-Phase2' } catch {}

    } catch {
        $errMsg = $_.Exception.Message
        $Result.Errors.Add("Phase 2 controller fatal error: $errMsg")
        $Result.Status = 'Failed'
        try { Write-SrdpLog "Phase2 controller fatal: $errMsg" -Level ERROR -Component 'Controller-Phase2' } catch {}
    } finally {
        $ErrorActionPreference = $callerEAP
    }

    return $Result
}
