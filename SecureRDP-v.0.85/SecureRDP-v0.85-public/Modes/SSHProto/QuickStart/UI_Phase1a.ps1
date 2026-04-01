#Requires -Version 5.1
# =============================================================================
# SecureRDP Phase 1a -- Installation UI
# Modes\SSHProto\QuickStart\UI_Phase1a.ps1
#
# Two-screen wizard:
#   Screen 1: Pre-flight plan and informed consent
#   Screen 2: Execution with step checklist, activity log, result message
#
# Launched by QuickStart-Phase1a.ps1 in the project root.
# Must be run as Administrator via -STA powershell.exe process.
# =============================================================================

param(
    [int]$SshPort = 22,
    [Parameter(Mandatory)][string]$ProjectRoot,
    [IntPtr]$OwnerHandle = [IntPtr]::Zero
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Load central logging module before dot-sourcing anything else
$_srdpLogMod = Join-Path $ProjectRoot 'SupportingModules\SrdpLog.psm1'
if (Test-Path $_srdpLogMod) {
    Import-Module $_srdpLogMod -Force
    $ErrorActionPreference = 'Stop'  # Reset after Import-Module
    Initialize-SrdpLog -Component 'QS-Phase1a'
    try { Write-SrdpLog "UI_Phase1a starting. SshPort=$SshPort ProjectRoot=$ProjectRoot" -Level INFO } catch {}
}

# Load InitialChecks for Get-SessionType (tunnel guard)
$_initChecksMod = Join-Path $ProjectRoot 'SupportingModules\InitialChecks.psm1'
if (Test-Path $_initChecksMod) {
    Import-Module $_initChecksMod -Force
    $ErrorActionPreference = 'Stop'  # Reset after Import-Module
}

. (Join-Path $PSScriptRoot 'Controller_Phase1a.ps1')
$ErrorActionPreference = 'Stop'  # Reset after dot-source -- MUST be Stop, not Continue

# =============================================================================
# COLORS
# =============================================================================
$CLR_HEADER_BG    = [System.Drawing.Color]::FromArgb(0, 60, 120)
$CLR_HEADER_FG    = [System.Drawing.Color]::White
$CLR_BODY_BG      = [System.Drawing.Color]::FromArgb(245, 245, 245)
$CLR_BTN_PRIMARY  = [System.Drawing.Color]::FromArgb(0, 84, 166)
$CLR_BTN_FG       = [System.Drawing.Color]::White
$CLR_OK           = [System.Drawing.Color]::FromArgb(10, 110, 10)
$CLR_ERR          = [System.Drawing.Color]::FromArgb(160, 20, 10)
$CLR_WARN         = [System.Drawing.Color]::FromArgb(160, 100, 0)
$CLR_STEP_PENDING = [System.Drawing.Color]::FromArgb(160, 160, 160)
$CLR_STEP_DONE    = [System.Drawing.Color]::FromArgb(10, 110, 10)
$CLR_STEP_WARN    = [System.Drawing.Color]::FromArgb(160, 100, 0)
$CLR_DIVIDER      = [System.Drawing.Color]::FromArgb(210, 210, 210)
$CLR_DARK_TEXT    = [System.Drawing.Color]::FromArgb(60, 60, 60)
$CLR_MSG_OK_BG    = [System.Drawing.Color]::FromArgb(240, 255, 240)
$CLR_MSG_ERR_BG   = [System.Drawing.Color]::FromArgb(255, 240, 240)
$CLR_MSG_WARN_BG  = [System.Drawing.Color]::FromArgb(255, 248, 230)
$CLR_LOG_BG       = [System.Drawing.Color]::FromArgb(238, 238, 238)
$CLR_BTN_BAR_BG   = [System.Drawing.Color]::FromArgb(232, 232, 232)
$CLR_SILVER       = [System.Drawing.Color]::Silver

# =============================================================================
# FONTS
# =============================================================================
$FONT_TITLE = [System.Drawing.Font]::new('Times New Roman', 16, [System.Drawing.FontStyle]::Bold)
$FONT_STEP  = [System.Drawing.Font]::new('Times New Roman', 14, [System.Drawing.FontStyle]::Bold)
$FONT_MSG   = [System.Drawing.Font]::new('Times New Roman', 13, [System.Drawing.FontStyle]::Bold)
$FONT_LOG   = [System.Drawing.Font]::new('Times New Roman', 12, [System.Drawing.FontStyle]::Bold)
$FONT_BODY  = [System.Drawing.Font]::new('Times New Roman', 11)
$CLR_BODY_TEXT = [System.Drawing.Color]::FromArgb(30, 30, 30)

# =============================================================================
# CONSTANTS
# =============================================================================
$LOG_TB_HEIGHT  = 180
$CONTENT_WIDTH  = 640

# State file lives under InstalledModes so the dashboard can find it.
# $ProjectRoot is passed as a mandatory parameter from the launcher.
$STATE_DIR  = Join-Path $ProjectRoot "InstalledModes\SSHProto"
$STATE_FILE = Join-Path $STATE_DIR   "state.json"

# InstalledModes\SSHProto directory is created by the controller
# immediately before writing state.json, after user consent and engine execution.

# Script-scoped handler references for remove_Click before re-add (Bug 5 fix)
$script:BtnBackHandler = $null
$script:BtnNextHandler = $null

# =============================================================================
# DEBUG LOGGING
# =============================================================================
$script:DebugLog = 'C:\ProgramData\SecureRDP\ui_debug.txt'
function Write-UIDebug {
    param([string]$Msg)
    $ts = Get-Date -Format 'HH:mm:ss.fff'
    $line = "[$ts] $Msg"
    try {
        $dir = Split-Path $script:DebugLog -Parent
        if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        Add-Content -Path $script:DebugLog -Value $line -Encoding UTF8
    } catch {}
}

# =============================================================================
# SCRIPT-SCOPE STATE
# =============================================================================
$script:InstallInProgress = $false
$script:PlanResult        = $null
$script:StepLabels        = @()
$script:LogBox            = $null
$script:MsgPanel          = $null
$script:MsgLabel          = $null
$script:HeaderLabel       = $null
$script:ContentPanel      = $null

# =============================================================================
# FORM CONSTRUCTION
# =============================================================================
$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'SecureRDP -- Phase 1 Infrastructure Setup'
$form.Width           = 700
$form.Height          = 620
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false
$form.MinimizeBox     = $true
$form.StartPosition   = 'CenterScreen'
$form.BackColor       = $CLR_BODY_BG

# Header
$hdrPanel           = New-Object System.Windows.Forms.Panel
$hdrPanel.Dock      = 'Top'
$hdrPanel.Height    = 56
$hdrPanel.BackColor = $CLR_HEADER_BG

$script:HeaderLabel           = New-Object System.Windows.Forms.Label
$script:HeaderLabel.Dock      = 'Fill'
$script:HeaderLabel.Font      = $FONT_TITLE
$script:HeaderLabel.ForeColor = $CLR_HEADER_FG
$script:HeaderLabel.TextAlign = 'MiddleLeft'
$script:HeaderLabel.Padding   = New-Object System.Windows.Forms.Padding(16, 0, 0, 0)
$script:HeaderLabel.Text      = 'Phase 1: Infrastructure Setup'
$hdrPanel.Controls.Add($script:HeaderLabel)
$form.Controls.Add($hdrPanel)

# Button bar
$btnBar           = New-Object System.Windows.Forms.Panel
$btnBar.Dock      = 'Bottom'
$btnBar.Height    = 58
$btnBar.BackColor = $CLR_BTN_BAR_BG

$btnBarSep           = New-Object System.Windows.Forms.Panel
$btnBarSep.Dock      = 'Top'
$btnBarSep.Height    = 1
$btnBarSep.BackColor = $CLR_SILVER
$btnBar.Controls.Add($btnBarSep)

$btnBack           = New-Object System.Windows.Forms.Button
$btnBack.Text      = '< Back'
$btnBack.Width     = 100
$btnBack.Height    = 34
$btnBack.Top       = 12
$btnBack.Left      = 16
$btnBack.FlatStyle = 'Flat'
$btnBack.BackColor = [System.Drawing.Color]::White
$btnBack.Font      = $FONT_LOG
$btnBack.FlatAppearance.BorderColor = $CLR_SILVER
$btnBack.FlatAppearance.BorderSize  = 1
$btnBack.Visible   = $false
$btnBar.Controls.Add($btnBack)

$btnNext           = New-Object System.Windows.Forms.Button
$btnNext.Text      = 'Proceed >'
$btnNext.Width     = 140
$btnNext.Height    = 34
$btnNext.Top       = 12
$btnNext.Left      = $form.ClientSize.Width - 156
$btnNext.FlatStyle = 'Flat'
$btnNext.BackColor = $CLR_BTN_PRIMARY
$btnNext.ForeColor = $CLR_BTN_FG
$btnNext.Font      = $FONT_LOG
$btnNext.FlatAppearance.BorderSize = 0
$btnBar.Controls.Add($btnNext)

$form.Controls.Add($btnBar)

# Content panel
$script:ContentPanel              = New-Object System.Windows.Forms.Panel
$script:ContentPanel.Dock         = 'Fill'
$script:ContentPanel.AutoScroll   = $true
$script:ContentPanel.Padding      = New-Object System.Windows.Forms.Padding(20)
$script:ContentPanel.BackColor    = $CLR_BODY_BG
$form.Controls.Add($script:ContentPanel)

# FormClosing guard
$form.Add_FormClosing({
    param($sender, $e)
    if ($script:InstallInProgress) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Installation is in progress. Closing now may leave the SSH service in an unstable state." +
            "`n`nAre you sure you want to close?",
            'Installation In Progress',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) {
            $e.Cancel = $true
        }
    }
})

# =============================================================================
# HELPER: Clear-ContentPanel
# =============================================================================
function Clear-ContentPanel {
    $controls = @($script:ContentPanel.Controls)
    foreach ($ctrl in $controls) {
        try { $ctrl.Dispose() } catch {}
    }
    $script:ContentPanel.Controls.Clear()
    $script:StepLabels = @()
    $script:LogBox     = $null
    $script:MsgPanel   = $null
    $script:MsgLabel   = $null
}

# =============================================================================
# HELPER: Add-Divider
# Adds a horizontal divider line to the content panel at position $Y.
# Returns new Y position.
# =============================================================================
function Add-Divider {
    param([int]$Y)
    $div           = New-Object System.Windows.Forms.Panel
    $div.Left      = 0
    $div.Top       = $Y
    $div.Width     = $CONTENT_WIDTH
    $div.Height    = 1
    $div.BackColor = $CLR_DIVIDER
    $script:ContentPanel.Controls.Add($div)
    return ($Y + 10)
}

# =============================================================================
# HELPER: Add-Label
# Adds a label to the content panel. Returns new Y position.
# =============================================================================
function Add-Label {
    param(
        [string]$Text,
        [int]$Y,
        [System.Drawing.Font]$Font,
        [System.Drawing.Color]$Color,
        [int]$Width      = 0,
        [int]$LeftPad    = 0,
        [bool]$AutoSize  = $true
    )
    $lbl           = New-Object System.Windows.Forms.Label
    $lbl.Text      = $Text
    $lbl.Left      = $LeftPad
    $lbl.Top       = $Y
    $lbl.Font      = $Font
    $lbl.ForeColor = $Color
    $lbl.AutoSize  = $AutoSize
    if ($Width -gt 0) {
        $lbl.Width        = $Width
        $lbl.MaximumSize  = New-Object System.Drawing.Size($Width, 2000)
        $lbl.AutoSize     = $true
    }
    $script:ContentPanel.Controls.Add($lbl)
    $lbl.Refresh()
    return ($Y + $lbl.PreferredHeight + 6)
}

# =============================================================================
# TUNNEL WARNING: Cannot run Phase 1a over our own SSH tunnel
# =============================================================================
function Show-TunnelWarning {
    Write-UIDebug "Show-TunnelWarning called"
    Clear-ContentPanel

    $script:HeaderLabel.Text = 'SSH Tunnel Session Detected'
    $btnBack.Text            = 'Exit'
    $btnBack.Visible         = $true
    $btnNext.Visible         = $true
    $btnNext.Text            = 'Open Part 2'
    $btnNext.Enabled         = $true

    if ($null -ne $script:BtnNextHandler) { $btnNext.remove_Click($script:BtnNextHandler) }
    if ($null -ne $script:BtnBackHandler) { $btnBack.remove_Click($script:BtnBackHandler) }

    $script:BtnBackHandler = { $form.Close() }
    $btnBack.Add_Click($script:BtnBackHandler)

    $script:BtnNextHandler = {
        $qs2 = Join-Path $ProjectRoot 'QuickStart-Phase2.ps1'
        if (Test-Path $qs2) {
            $launchArgs = "-STA -ExecutionPolicy Bypass -File `"$qs2`" -SshPort $SshPort"
            Start-Process 'powershell.exe' -ArgumentList $launchArgs
        }
        $form.Close()
    }
    $btnNext.Add_Click($script:BtnNextHandler)

    $y = 4

    $y = Add-Label `
        -Text  'You are connected via the SecureRDP SSH tunnel.' `
        -Y     $y `
        -Font  $FONT_STEP `
        -Color $CLR_WARN `
        -Width $CONTENT_WIDTH
    $y += 8

    $y = Add-Label `
        -Text  ('Running Quick Start Part 1 in this session would disrupt the SSH service ' +
                'and break your active tunnel connection. To run Part 1, please connect ' +
                'locally or via direct RDP instead.') `
        -Y     $y `
        -Font  $FONT_LOG `
        -Color $CLR_DARK_TEXT `
        -Width $CONTENT_WIDTH
    $y += 16

    $y = Add-Label `
        -Text  ('If you need to configure security settings (firewall rules, RDP listener ' +
                'restriction), click "Open Part 2" to launch Quick Start Part 2, which is ' +
                'safe to run over the tunnel.') `
        -Y     $y `
        -Font  $FONT_LOG `
        -Color $CLR_DARK_TEXT `
        -Width $CONTENT_WIDTH

    $form.AcceptButton = $btnBack
    $form.CancelButton = $btnBack
}

# =============================================================================
# SCREEN 1: Plan and Permission
# =============================================================================
function Show-Screen1 {
    param([bool]$AlreadyInstalled = $false)

    Write-UIDebug "Show-Screen1 called (AlreadyInstalled=$AlreadyInstalled)"
    Clear-ContentPanel

    $script:HeaderLabel.Text = 'Phase 1: Infrastructure Setup'
    $btnBack.Text            = 'Exit'
    $btnBack.Visible         = $true
    if ($null -ne $script:BtnBackHandler) { $btnBack.remove_Click($script:BtnBackHandler) }
    $script:BtnBackHandler = { $form.Close() }
    $btnBack.Add_Click($script:BtnBackHandler)
    $btnNext.Text            = 'Proceed >'
    $btnNext.Enabled         = $true

    if ($null -ne $script:BtnNextHandler) { $btnNext.remove_Click($script:BtnNextHandler) }
    $script:BtnNextHandler = {
        $btnNext.Enabled = $false
        Show-Screen2
    }
    $btnNext.Add_Click($script:BtnNextHandler)

    $y = 4

    if ($AlreadyInstalled) {
        $y = Add-Label `
            -Text  'Phase 1 infrastructure is already installed on this machine.' `
            -Y     $y `
            -Font  $FONT_STEP `
            -Color $CLR_OK `
            -Width $CONTENT_WIDTH
        $y = Add-Label `
            -Text  'To reinstall or reconfigure, use the revert option first.' `
            -Y     $y `
            -Font  $FONT_LOG `
            -Color $CLR_DARK_TEXT `
            -Width $CONTENT_WIDTH
        $btnNext.Enabled = $false
        return
    }

    # Get plan from controller
    Write-UIDebug "Calling Invoke-Phase1aController..."
    try {
        $script:PlanResult = Invoke-Phase1aController -SshPort $SshPort -StateFilePath $STATE_FILE
        Write-UIDebug "Controller returned: Status=$($script:PlanResult.Status) Success=$($script:PlanResult.Success)"
        try { Write-UIDebug ($script:PlanResult | ConvertTo-Json -Depth 3 -Compress) } catch {}
    } catch {
        Write-UIDebug "Controller THREW: $($_.Exception.Message)"
        $y = Add-Label `
            -Text  "Pre-flight assessment error: $($_.Exception.Message)" `
            -Y     $y `
            -Font  $FONT_STEP `
            -Color $CLR_ERR `
            -Width $CONTENT_WIDTH
        $btnNext.Enabled = $false
        return
    }
    if ($null -eq $script:PlanResult -or $script:PlanResult.Status -ne 'PlanReady') {
        $errMsg = if ($null -ne $script:PlanResult -and $script:PlanResult.Errors.Count -gt 0) {
            $script:PlanResult.Errors[0]
        } else {
            $statusStr = if ($null -ne $script:PlanResult) { $script:PlanResult.Status } else { 'null result' }
            "Status: $statusStr"
        }
        $y = Add-Label `
            -Text  "Pre-flight assessment failed: $errMsg" `
            -Y     $y `
            -Font  $FONT_STEP `
            -Color $CLR_ERR `
            -Width $CONTENT_WIDTH
        $btnNext.Enabled = $false
        return
    }

    $plan = $script:PlanResult.Data.Plan
    Write-UIDebug "Plan object retrieved. ImpactLevel=$($plan.ImpactLevel) Steps=$($plan.Steps.Count)"

    # Impact badge
    $impactColor = switch ($plan.ImpactLevel) {
        'Low'    { $CLR_OK }
        'Medium' { $CLR_WARN }
        'High'   { $CLR_ERR }
        default  { $CLR_DARK_TEXT }
    }
    $y = Add-Label `
        -Text  "Impact Level: $($plan.ImpactLevel)" `
        -Y     $y `
        -Font  $FONT_STEP `
        -Color $impactColor
    Write-UIDebug "Impact badge added. y=$y"
    $y += 4

    $y = Add-Divider -Y $y
    Write-UIDebug "Divider added. y=$y"

    # What will happen
    $y = Add-Label `
        -Text  'What will happen:' `
        -Y     $y `
        -Font  $FONT_STEP `
        -Color $CLR_HEADER_BG
    Write-UIDebug "Rendering $($plan.Steps.Count) steps..."
    foreach ($step in $plan.Steps) {
        Write-UIDebug "  Adding step label at y=$y : $step"
        $y = Add-Label `
            -Text    "  $([char]0x2022)  $step" `
            -Y       $y `
            -Font    $FONT_LOG `
            -Color   $CLR_DARK_TEXT `
            -Width   $CONTENT_WIDTH
        Write-UIDebug "  Step label added. new y=$y"
    }

    # Warnings
    if ($plan.Warnings.Count -gt 0) {
        $y += 4
        $y = Add-Divider -Y $y
        $y = Add-Label `
            -Text  'Warnings:' `
            -Y     $y `
            -Font  $FONT_STEP `
            -Color $CLR_WARN
        foreach ($w in $plan.Warnings) {
            $y = Add-Label `
                -Text  "  !  $w" `
                -Y     $y `
                -Font  $FONT_LOG `
                -Color $CLR_WARN `
                -Width $CONTENT_WIDTH
        }
    }

    # Reboot risk note
    if ($plan.RebootRisk) {
        $y += 4
        $y = Add-Divider -Y $y
        $y = Add-Label `
            -Text  ('Note: This setup may require a system reboot. You will be notified ' +
                    'if a reboot is needed before you can continue.') `
            -Y     $y `
            -Font  $FONT_LOG `
            -Color $CLR_WARN `
            -Width $CONTENT_WIDTH
    }

    # SSH firewall rule note
    $y += 4
    $y = Add-Divider -Y $y
    $y = Add-Label `
        -Text  ('Note: When Windows installs the SSH server it also creates an enabled ' +
                'inbound firewall rule allowing SSH traffic from any source. As this may ' +
                'be undesirable for security reasons in some cases, SecureRDP immediately ' +
                'disables that new rule. However, your existing firewall rules will be ' +
                'unaffected.') `
        -Y     $y `
        -Font  $FONT_BODY `
        -Color $CLR_BODY_TEXT `
        -Width $CONTENT_WIDTH

    Write-UIDebug "Show-Screen1 complete. Calling Refresh(). ContentPanel control count=$($script:ContentPanel.Controls.Count)"
    $script:ContentPanel.Refresh()
    Write-UIDebug "Refresh() done."
}

# =============================================================================
# SCREEN 2: Execution
# =============================================================================
function Show-Screen2 {
    param([bool]$IsPostReboot = $false)

    Clear-ContentPanel

    $script:HeaderLabel.Text = 'Installing...'
    $btnBack.Visible         = $false
    $btnBack.Text            = '< Back'
    $btnNext.Text            = 'Close'
    $btnNext.Enabled         = $false
    if ($null -ne $script:BtnNextHandler) { $btnNext.remove_Click($script:BtnNextHandler) }
    $script:BtnNextHandler = { $form.Close() }
    $btnNext.Add_Click($script:BtnNextHandler)

    $y = 4

    # ------------------------------------------------------------------
    # Step checklist
    # ------------------------------------------------------------------
    $steps = if ($IsPostReboot -or $null -eq $script:PlanResult) {
        @('Completing SSH service configuration...')
    } else {
        @($script:PlanResult.Data.Plan.Steps)
    }

    $stepLabels = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($step in $steps) {
        $markerLbl           = New-Object System.Windows.Forms.Label
        $markerLbl.Text      = [char]0x25CB   # hollow circle
        $markerLbl.Left      = 0
        $markerLbl.Top       = $y
        $markerLbl.Width     = 26
        $markerLbl.Height    = 26
        $markerLbl.Font      = $FONT_STEP
        $markerLbl.ForeColor = $CLR_STEP_PENDING
        $markerLbl.AutoSize  = $false
        $markerLbl.TextAlign = 'MiddleCenter'
        $script:ContentPanel.Controls.Add($markerLbl)

        $stepLbl           = New-Object System.Windows.Forms.Label
        $stepLbl.Text      = $step
        $stepLbl.Left      = 30
        $stepLbl.Top       = $y
        $stepLbl.Width     = $CONTENT_WIDTH - 30
        $stepLbl.Font      = $FONT_STEP
        $stepLbl.ForeColor = $CLR_STEP_PENDING
        $stepLbl.AutoSize  = $false
        $stepLbl.Height    = 26
        $script:ContentPanel.Controls.Add($stepLbl)

        $null = $stepLabels.Add(@{ Marker = $markerLbl; Label = $stepLbl })
        $y += 30
    }

    $script:StepLabels = $stepLabels.ToArray()
    $y += 4

    $y = Add-Divider -Y $y

    # ------------------------------------------------------------------
    # Activity log
    # ------------------------------------------------------------------
    $y = Add-Label `
        -Text  'Activity:' `
        -Y     $y `
        -Font  $FONT_STEP `
        -Color $CLR_HEADER_BG
    $y -= 2

    $script:LogBox             = New-Object System.Windows.Forms.RichTextBox
    $script:LogBox.ReadOnly    = $true
    $script:LogBox.ScrollBars  = 'Vertical'
    $script:LogBox.WordWrap    = $false
    $script:LogBox.Left        = 0
    $script:LogBox.Top         = $y
    $script:LogBox.Width       = $CONTENT_WIDTH
    $script:LogBox.Height      = $LOG_TB_HEIGHT
    $script:LogBox.Font        = $FONT_LOG
    $script:LogBox.BackColor   = $CLR_LOG_BG
    $script:LogBox.BorderStyle = 'FixedSingle'
    $script:ContentPanel.Controls.Add($script:LogBox)
    $y += $LOG_TB_HEIGHT + 8

    $y = Add-Divider -Y $y

    # ------------------------------------------------------------------
    # Bottom message area
    # ------------------------------------------------------------------
    $script:MsgPanel             = New-Object System.Windows.Forms.Panel
    $script:MsgPanel.Left        = 0
    $script:MsgPanel.Top         = $y
    $script:MsgPanel.Width       = $CONTENT_WIDTH
    $script:MsgPanel.Height      = 120
    $script:MsgPanel.BorderStyle = 'FixedSingle'
    $script:MsgPanel.BackColor   = $CLR_BODY_BG
    $script:ContentPanel.Controls.Add($script:MsgPanel)

    $script:MsgLabel           = New-Object System.Windows.Forms.Label
    $script:MsgLabel.Dock      = 'Fill'
    $script:MsgLabel.Font      = $FONT_MSG
    $script:MsgLabel.ForeColor = $CLR_DARK_TEXT
    $script:MsgLabel.AutoSize  = $false
    $script:MsgLabel.TextAlign = 'MiddleLeft'
    $script:MsgLabel.Padding   = New-Object System.Windows.Forms.Padding(12)
    $script:MsgLabel.Text      = 'Running installation...'
    $script:MsgPanel.Controls.Add($script:MsgLabel)

    [System.Windows.Forms.Application]::DoEvents()

    # ------------------------------------------------------------------
    # Progress callback
    # ------------------------------------------------------------------
    $onProgress = {
        param($p)
        $idx = $p.CurrentStep - 1
        if ($idx -ge 0 -and $idx -lt $script:StepLabels.Count) {
            if ($p.IsWarning) {
                $script:StepLabels[$idx].Marker.Text      = '!'
                $script:StepLabels[$idx].Marker.ForeColor = $CLR_STEP_WARN
                $script:StepLabels[$idx].Label.ForeColor  = $CLR_STEP_WARN
            } else {
                $script:StepLabels[$idx].Marker.Text      = [char]0x2713
                $script:StepLabels[$idx].Marker.ForeColor = $CLR_STEP_DONE
                $script:StepLabels[$idx].Label.ForeColor  = $CLR_STEP_DONE
            }
        }
        if (-not [string]::IsNullOrEmpty($p.Message)) {
            if ($p.IsWarning) {
                # Errors and warnings shown in orange-red so they stand out
                $script:LogBox.SelectionColor = [System.Drawing.Color]::FromArgb(200, 60, 0)
                $script:LogBox.AppendText("[ERROR] $($p.Message)`r`n")
                $script:LogBox.SelectionColor = $script:LogBox.ForeColor
            } else {
                $script:LogBox.AppendText("$($p.Message)`r`n")
            }
            $script:LogBox.ScrollToCaret()
        }
        [System.Windows.Forms.Application]::DoEvents()
    }

    # ------------------------------------------------------------------
    # Execute
    # ------------------------------------------------------------------
    $script:InstallInProgress = $true

    $installResult = Invoke-Phase1aController `
        -SshPort       $SshPort `
        -StateFilePath $STATE_FILE `
        -Confirmed     $true `
        -OnProgress    $onProgress

    $script:InstallInProgress = $false
    try { Write-SrdpLog "Invoke-Phase1aController returned. Status=$($installResult.Status) Success=$($installResult.Success) Errors=$($installResult.Errors.Count)" -Level INFO } catch {}

    # Always flush ALL errors to log box regardless of success status
    # Users must see every error even if installation ultimately succeeded
    if ($installResult.Errors.Count -gt 0 -and $null -ne $script:LogBox) {
        $script:LogBox.SelectionColor = [System.Drawing.Color]::FromArgb(192, 32, 14)
        $script:LogBox.AppendText("--- $($installResult.Errors.Count) error(s) recorded during installation ---`r`n")
        foreach ($err in $installResult.Errors) {
            $script:LogBox.AppendText("[ERROR] $err`r`n")
            try { Write-SrdpLog "Installation error: $err" -Level ERROR } catch {}
        }
        $script:LogBox.SelectionColor = $script:LogBox.ForeColor
        $script:LogBox.ScrollToCaret()
    }

    # Bug 10 fix: Deploy OperationalCheck.psm1 to InstalledModes on success
    if ($installResult.Success) {
        try {
            $srcOpCheck  = Join-Path $ProjectRoot 'Modes\SSHProto\payload\OperationalCheck.psm1'
            $destOpCheck = Join-Path $STATE_DIR 'OperationalCheck.psm1'
            if (Test-Path $srcOpCheck) {
                Copy-Item $srcOpCheck $destOpCheck -Force
                Write-UIDebug "OperationalCheck.psm1 deployed to $destOpCheck"
            } else {
                Write-UIDebug "Warning: OperationalCheck.psm1 not found at $srcOpCheck"
            }
        } catch {
            Write-UIDebug "Warning: Could not deploy OperationalCheck.psm1: $($_.Exception.Message)"
        }
    }

    # Mark any remaining pending steps as done if install succeeded
    if ($installResult.Success) {
        foreach ($pair in $script:StepLabels) {
            if ($pair.Marker.Text -eq [string][char]0x25CB) {
                $pair.Marker.Text      = [char]0x2713
                $pair.Marker.ForeColor = $CLR_STEP_DONE
                $pair.Label.ForeColor  = $CLR_STEP_DONE
            }
        }
    }

    # ------------------------------------------------------------------
    # Result handling
    # ------------------------------------------------------------------
    switch ($installResult.Status) {
        'PendingReboot' {
            $script:HeaderLabel.Text   = 'Restart Required'
            $script:MsgPanel.BackColor = $CLR_MSG_WARN_BG
            $script:MsgLabel.ForeColor = $CLR_WARN
            $script:MsgLabel.Text      = (
                'OpenSSH was installed but your computer needs to restart before ' +
                'setup can continue. Please restart your computer and then run ' +
                'QuickStart-Phase1a.ps1 again.')
        }
        'Installed' {
            $script:HeaderLabel.Text   = 'Installation Complete'
            $script:MsgPanel.BackColor = $CLR_MSG_OK_BG
            $script:MsgLabel.ForeColor = $CLR_OK
            $e1 = $installResult.Data.Engine1Result
            $version = if ($null -ne $e1 -and $null -ne $e1.Data.Version) {
                $e1.Data.Version.ToString()
            } else { 'unknown' }
            $versionNote = if ($null -ne $e1 -and
                               -not [string]::IsNullOrEmpty($e1.Data.VersionNote)) {
                "`r`n`r`n$($e1.Data.VersionNote)"
            } else { '' }
            $errSuffix = if ($installResult.Errors.Count -gt 0) {
                "`r`n`r`nNote: $($installResult.Errors.Count) error(s) occurred during installation. Review the activity log above."
            } else { '' }
            $script:MsgLabel.Text = (
                "Installation complete. SSH service is running on port $SshPort. " +
                "OpenSSH version: $version.$versionNote$errSuffix")
            if ($installResult.Errors.Count -gt 0) {
                $script:MsgPanel.BackColor = $CLR_MSG_WARN_BG
                $script:MsgLabel.ForeColor = $CLR_WARN
            }
            # Rewire Close button to launch QS Part 2
            $btnNext.Text = 'Continue to Part 2'
            if ($null -ne $script:BtnNextHandler) { $btnNext.remove_Click($script:BtnNextHandler) }
            $script:BtnNextHandler = {
                $qs2Path = Join-Path $ProjectRoot 'QuickStart-Phase2.ps1'
                if (Test-Path $qs2Path) {
                    Start-Process 'powershell.exe' `
                        -ArgumentList "-STA -ExecutionPolicy Bypass -File `"$qs2Path`" -SshPort $SshPort -SkipSshVerification"
                }
                $form.Close()
            }
            $btnNext.Add_Click($script:BtnNextHandler)
        }
        'Failed' {
            # Check if this is a ManualRequired from Engine 1
            $e1Status = $null
            try { $e1Status = $installResult.Data.Engine1Result.Status } catch {}
            if ($e1Status -eq 'ManualRequired') {
                $script:HeaderLabel.Text   = 'SSH Server Installation Required'
                $script:MsgPanel.BackColor = $CLR_MSG_WARN_BG
                $script:MsgLabel.ForeColor = $CLR_WARN
                $script:MsgLabel.Text      = 'The automatic installation of the OpenSSH Server could not be completed.'

                # Show detailed popup with placeholder text
                [System.Windows.Forms.MessageBox]::Show(
                    ("The automatic installation of the OpenSSH Server optional feature " +
                     "was not successful.`n`n" +
                     "This can happen for several reasons, including:`n" +
                     "  - No internet connectivity to Windows Update`n" +
                     "  - Windows Update service is disabled or restricted by policy`n" +
                     "  - The optional feature is blocked by group policy`n" +
                     "  - Insufficient disk space`n`n" +
                     "To proceed, you will need to install the OpenSSH Server manually. " +
                     "Options include:`n" +
                     "  - Install via Settings > Apps > Optional Features`n" +
                     "  - Install from a CAB file (for offline machines)`n" +
                     "  - Install standalone OpenSSH binaries`n`n" +
                     "Once the SSH server is installed, run Quick Start again to continue setup."),
                    'SecureRDP - SSH Server Installation',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            } else {
                $script:HeaderLabel.Text   = 'Installation Failed'
                $script:MsgPanel.BackColor = $CLR_MSG_ERR_BG
                $script:MsgLabel.ForeColor = $CLR_ERR
                $errMsg = if ($installResult.Errors.Count -gt 0) {
                    $installResult.Errors[0]
                } else { 'An unknown error occurred.' }
                $script:MsgLabel.Text = "Error: $errMsg"
            }
        }
        'PartialFailure' {
            $script:HeaderLabel.Text   = 'Installation Failed'
            $script:MsgPanel.BackColor = $CLR_MSG_ERR_BG
            $script:MsgLabel.ForeColor = $CLR_ERR
            $errMsg = if ($installResult.Errors.Count -gt 0) {
                $installResult.Errors[0]
            } else { 'Installation did not complete successfully.' }
            $script:MsgLabel.Text = "Error: $errMsg"
        }
        default {
            $script:HeaderLabel.Text   = 'Installation Failed'
            $script:MsgPanel.BackColor = $CLR_MSG_ERR_BG
            $script:MsgLabel.ForeColor = $CLR_ERR
            $script:MsgLabel.Text      = "Unexpected status: $($installResult.Status)"
        }
    }

    $btnNext.Enabled = $true
    [System.Windows.Forms.Application]::DoEvents()
}

# =============================================================================
# STARTUP LOGIC
# =============================================================================
# Populate screen inside Shown event so the graphics context exists
# (PreferredHeight returns 0 before the form is visible)
$form.Add_Shown({
    Write-UIDebug "form.Shown event fired"

    # Tunnel guard -- do not run Phase 1a over our own SSH tunnel
    $_sessionType = 'local'
    try { $_sessionType = Get-SessionType } catch {}
    Write-UIDebug "Session type: $_sessionType"
    if ($_sessionType -eq 'rdp-tunnel') {
        try { Write-SrdpLog "UI_Phase1a: tunnel session detected -- blocking Phase 1a execution." -Level WARN } catch {}
        Show-TunnelWarning
        return
    }

    if (Test-Path $STATE_FILE) {
        try {
            $existing    = Get-Content $STATE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
            $e1Done      = $null -ne $existing.Engine1
            $e2Done      = $null -ne $existing.Engine2
            $e1Installed = $e1Done -and $existing.Engine1.Data.InstallAction -eq 'Installed'

            if ($e1Done -and -not $e2Done -and $e1Installed) {
                Show-Screen2 -IsPostReboot $true
            } elseif ($e1Done -and $e2Done -and $existing.Engine2.Success -eq $true) {
                Show-Screen1 -AlreadyInstalled $true
            } else {
                Show-Screen1
            }
        } catch {
            Show-Screen1
        }
    } else {
        Show-Screen1
    }
})

[System.Windows.Forms.Application]::Run($form)
