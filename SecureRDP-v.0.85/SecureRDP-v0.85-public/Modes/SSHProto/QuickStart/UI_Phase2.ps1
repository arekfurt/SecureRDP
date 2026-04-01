#Requires -Version 5.1
# =============================================================================
# SecureRDP Phase 2 -- Security Configuration UI
# Modes\SSHProto\QuickStart\UI_Phase2.ps1
#
# Four-screen wizard:
#   Screen 1: SSH verification results
#   Screen 2: Security options (firewall + loopback toggles)
#   Screen 3: Execution with step checklist and activity log
#   Screen 4: Completion and transition to Client Key Wizard
#
# Launched by QuickStart-Phase2.ps1 in the project root.
# Must be run as Administrator via -STA powershell.exe process.
# =============================================================================

param(
    [int]$SshPort = 22,
    [Parameter(Mandatory)][string]$ProjectRoot,
    [IntPtr]$OwnerHandle = [IntPtr]::Zero,
    [switch]$SkipSshVerification
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# =============================================================================
# MODULE LOADING -- UI owns all imports
# =============================================================================
foreach ($_modRel in @(
    'SupportingModules\SrdpLog.psm1',
    'SupportingModules\InitialChecks.psm1',
    'RDPCheckModules\FirewallReadWriteElements.psm1',
    'RDPCheckModules\RDPStatus.psm1',
    'Modes\SSHProto\SSHProtoCore.psm1'
)) {
    $_modPath = Join-Path $ProjectRoot $_modRel
    if (Test-Path $_modPath) {
        Import-Module $_modPath -Force -DisableNameChecking
        $ErrorActionPreference = 'Stop'
    }
}
Initialize-SrdpLog -Component 'QS-Phase2'
try { Write-SrdpLog "UI_Phase2 starting. SshPort=$SshPort ProjectRoot=$ProjectRoot" -Level INFO } catch {}

. (Join-Path $PSScriptRoot 'Controller_Phase2.ps1')
$ErrorActionPreference = 'Stop'

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
$CLR_WHITE        = [System.Drawing.Color]::White
$CLR_TOGGLE_ON    = [System.Drawing.Color]::FromArgb(10, 110, 10)
$CLR_TOGGLE_OFF   = [System.Drawing.Color]::FromArgb(170, 170, 170)
$CLR_TAG_EXP_FG   = [System.Drawing.Color]::FromArgb(122, 72, 0)
$CLR_TAG_EXP_BG   = [System.Drawing.Color]::FromArgb(255, 243, 205)
$CLR_DISABLED_FG  = [System.Drawing.Color]::FromArgb(180, 180, 180)

# =============================================================================
# FONTS
# =============================================================================
$FONT_TITLE = [System.Drawing.Font]::new('Times New Roman', 16, [System.Drawing.FontStyle]::Bold)
$FONT_STEP  = [System.Drawing.Font]::new('Times New Roman', 14, [System.Drawing.FontStyle]::Bold)
$FONT_MSG   = [System.Drawing.Font]::new('Times New Roman', 13, [System.Drawing.FontStyle]::Bold)
$FONT_LOG   = [System.Drawing.Font]::new('Times New Roman', 12, [System.Drawing.FontStyle]::Bold)
$FONT_BODY  = [System.Drawing.Font]::new('Segoe UI', 10)
$FONT_BOLD  = [System.Drawing.Font]::new('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$FONT_SMALL = [System.Drawing.Font]::new('Segoe UI', 8.5)
$FONT_TAG   = [System.Drawing.Font]::new('Segoe UI', 7.5, [System.Drawing.FontStyle]::Bold)

# =============================================================================
# CONSTANTS
# =============================================================================
$LOG_TB_HEIGHT  = 160
$CONTENT_WIDTH  = 640
$FORM_WIDTH     = 760
$FORM_HEIGHT    = 620

$STATE_DIR  = Join-Path $ProjectRoot "InstalledModes\SSHProto"
$STATE_FILE = Join-Path $STATE_DIR   "state.json"

# =============================================================================
# FORM CONSTRUCTION
# =============================================================================
$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'SecureRDP - Quick Start Part 2'
$form.Width           = $FORM_WIDTH
$form.Height          = $FORM_HEIGHT
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox     = $false
$form.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.BackColor       = $CLR_BODY_BG
$form.KeyPreview      = $true

# Header bar
$headerPanel           = New-Object System.Windows.Forms.Panel
$headerPanel.Dock      = [System.Windows.Forms.DockStyle]::Top
$headerPanel.Height    = 50
$headerPanel.BackColor = $CLR_HEADER_BG

$script:HeaderLabel           = New-Object System.Windows.Forms.Label
$script:HeaderLabel.Text      = 'Quick Start Part 2'
$script:HeaderLabel.Font      = [System.Drawing.Font]::new('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$script:HeaderLabel.ForeColor = $CLR_HEADER_FG
$script:HeaderLabel.Dock      = [System.Windows.Forms.DockStyle]::Fill
$script:HeaderLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$script:HeaderLabel.Padding   = New-Object System.Windows.Forms.Padding(14, 0, 0, 0)
$headerPanel.Controls.Add($script:HeaderLabel)

# Button bar
$btnBar           = New-Object System.Windows.Forms.Panel
$btnBar.Dock      = [System.Windows.Forms.DockStyle]::Bottom
$btnBar.Height    = 52
$btnBar.BackColor = $CLR_BTN_BAR_BG

$btnBarSep           = New-Object System.Windows.Forms.Panel
$btnBarSep.Dock      = [System.Windows.Forms.DockStyle]::Bottom
$btnBarSep.Height    = 1
$btnBarSep.BackColor = $CLR_SILVER

# Back button
$btnBack              = New-Object System.Windows.Forms.Button
$btnBack.Text         = '< Back'
$btnBack.Width        = 90
$btnBack.Height       = 30
$btnBack.Top          = 11
$btnBack.Left         = 16
$btnBack.FlatStyle    = [System.Windows.Forms.FlatStyle]::Flat
$btnBack.BackColor    = $CLR_WHITE
$btnBack.FlatAppearance.BorderColor = $CLR_SILVER
$btnBack.Visible      = $false
$btnBar.Controls.Add($btnBack)

# Next button
$btnNext              = New-Object System.Windows.Forms.Button
$btnNext.Text         = 'Proceed'
$btnNext.Width        = 110
$btnNext.Height       = 30
$btnNext.Top          = 11
$btnNext.Left         = $FORM_WIDTH - 110 - 32
$btnNext.FlatStyle    = [System.Windows.Forms.FlatStyle]::Flat
$btnNext.BackColor    = $CLR_BTN_PRIMARY
$btnNext.ForeColor    = $CLR_BTN_FG
$btnNext.FlatAppearance.BorderSize = 0
$btnBar.Controls.Add($btnNext)

# Content panel (scrollable)
$script:ContentPanel              = New-Object System.Windows.Forms.Panel
$script:ContentPanel.Dock         = [System.Windows.Forms.DockStyle]::Fill
$script:ContentPanel.AutoScroll   = $true
$script:ContentPanel.Padding      = New-Object System.Windows.Forms.Padding(40, 16, 40, 16)
$script:ContentPanel.BackColor    = $CLR_BODY_BG

# Dock order
$form.Controls.Add($script:ContentPanel)
$form.Controls.Add($btnBarSep)
$form.Controls.Add($btnBar)
$form.Controls.Add($headerPanel)

# =============================================================================
# UI HELPERS
# =============================================================================
function Clear-ContentPanel {
    foreach ($ctrl in @($script:ContentPanel.Controls)) {
        try { $ctrl.Dispose() } catch {}
    }
    $script:ContentPanel.Controls.Clear()
}

function Add-UILabel {
    param(
        [string]$Text,
        [int]$Y,
        [System.Drawing.Font]$Font = $FONT_BODY,
        [System.Drawing.Color]$Color = $CLR_DARK_TEXT,
        [int]$Width = $CONTENT_WIDTH,
        [int]$Left = 0
    )
    $lbl           = New-Object System.Windows.Forms.Label
    $lbl.Text      = $Text
    $lbl.Font      = $Font
    $lbl.ForeColor = $Color
    $lbl.Left      = $Left
    $lbl.Top       = $Y
    $lbl.Width     = $Width
    $lbl.AutoSize  = $false
    $lbl.MaximumSize = New-Object System.Drawing.Size($Width, 2000)
    $lbl.AutoSize  = $true
    $script:ContentPanel.Controls.Add($lbl)
    return $lbl
}

function Add-CopyableText {
    param(
        [string]$Text,
        [int]$Y,
        [System.Drawing.Font]$Font = $FONT_BODY,
        [System.Drawing.Color]$Color = $CLR_DARK_TEXT,
        [int]$Width = $CONTENT_WIDTH,
        [int]$Height = 22
    )
    $tb             = New-Object System.Windows.Forms.TextBox
    $tb.Text        = $Text
    $tb.Font        = $Font
    $tb.ForeColor   = $Color
    $tb.Left        = 0
    $tb.Top         = $Y
    $tb.Width       = $Width
    $tb.Height      = $Height
    $tb.ReadOnly    = $true
    $tb.BorderStyle = 'None'
    $tb.BackColor   = $CLR_BODY_BG
    $script:ContentPanel.Controls.Add($tb)
    return $tb
}

function Add-UIDivider {
    param([int]$Y)
    $sep           = New-Object System.Windows.Forms.Panel
    $sep.Left      = 0
    $sep.Top       = $Y
    $sep.Width     = $CONTENT_WIDTH
    $sep.Height    = 1
    $sep.BackColor = $CLR_DIVIDER
    $script:ContentPanel.Controls.Add($sep)
    return ($Y + 8)
}

function Write-UIDebug {
    param([string]$Msg)
    try { Write-SrdpLog "UI_Phase2: $Msg" -Level DEBUG -Component 'QS-Phase2' } catch {}
}

# =============================================================================
# NAVIGATION STATE
# =============================================================================
$script:CurrentScreen   = 0
$script:BtnNextHandler  = $null
$script:BtnBackHandler  = $null
$script:PreflightResult = $null
$script:InstallInProgress = $false

# Toggle state (Screen 2)
$script:SshRuleEnabled  = $true
$script:RdpBlockEnabled = $true
$script:ApplyLoopback   = $false
$script:RdpPort         = 3389

# FormClosing guard
$form.Add_FormClosing({
    param($sender, $e)
    if ($script:InstallInProgress) {
        $e.Cancel = $true
        [System.Windows.Forms.MessageBox]::Show(
            'Configuration is in progress. Please wait for it to complete.',
            'SecureRDP',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
})

# =============================================================================
# SCREEN 1: SSH Verification
# =============================================================================
function Show-Screen1 {
    Clear-ContentPanel
    $script:CurrentScreen      = 1
    $script:HeaderLabel.Text   = 'SSH Server Verification'
    $btnBack.Visible           = $false
    $btnNext.Text              = 'Checking...'
    $btnNext.Enabled           = $false

    if ($null -ne $script:BtnNextHandler) { $btnNext.remove_Click($script:BtnNextHandler) }
    if ($null -ne $script:BtnBackHandler) { $btnBack.remove_Click($script:BtnBackHandler) }

    $y = 4
    $y = (Add-UILabel -Text "Verifying SSH server readiness..." -Y $y -Font $FONT_STEP -Color $CLR_HEADER_BG).Bottom + 8

    [System.Windows.Forms.Application]::DoEvents()

    # Run preflight
    $script:PreflightResult = Invoke-Phase2Preflight -SshPort $SshPort -StateFilePath $STATE_FILE

    Clear-ContentPanel
    $y = 4

    # --- Phase 1a not complete ---
    if ($script:PreflightResult.Status -eq 'Phase1aIncomplete') {
        $y = (Add-UILabel -Text "Quick Start Part 1 Required" -Y $y -Font $FONT_STEP -Color $CLR_ERR).Bottom + 8
        $y = (Add-UILabel -Text "Quick Start Part 1 (SSH server installation) has not been completed. The SSH server must be installed and configured before proceeding with security setup." -Y $y -Color $CLR_DARK_TEXT).Bottom + 8

        foreach ($err in $script:PreflightResult.Errors) {
            $y = (Add-CopyableText -Text $err -Y $y -Color $CLR_ERR).Bottom + 4
        }

        $btnNext.Text    = 'Exit'
        $btnNext.Enabled = $true
        $script:BtnNextHandler = { $form.Close() }
        $btnNext.Add_Click($script:BtnNextHandler)

        # Add a Launch Part 1 button
        $btnLaunch              = New-Object System.Windows.Forms.Button
        $btnLaunch.Text         = 'Launch Part 1'
        $btnLaunch.Width        = 120
        $btnLaunch.Height       = 30
        $btnLaunch.Top          = 11
        $btnLaunch.Left         = $FORM_WIDTH - 110 - 130 - 32
        $btnLaunch.FlatStyle    = [System.Windows.Forms.FlatStyle]::Flat
        $btnLaunch.BackColor    = $CLR_BTN_PRIMARY
        $btnLaunch.ForeColor    = $CLR_BTN_FG
        $btnLaunch.FlatAppearance.BorderSize = 0
        $btnBar.Controls.Add($btnLaunch)
        $btnLaunch.Add_Click({
            $qs1 = Join-Path $ProjectRoot 'QuickStart-Phase1a.ps1'
            if (Test-Path $qs1) {
                $launchArgs = "-STA -ExecutionPolicy Bypass -File `"$qs1`" -SshPort $SshPort"
                Start-Process 'powershell.exe' -ArgumentList $launchArgs
            }
            $form.Close()
        })
        return
    }

    # --- SSH verification results ---
    $verifier = $script:PreflightResult.Data.VerifierResult
    $script:RdpPort = $script:PreflightResult.Data.RdpPort

    $y = (Add-UILabel -Text "SSH Server Status" -Y $y -Font $FONT_STEP -Color $CLR_HEADER_BG).Bottom + 8

    foreach ($check in $verifier.Data.Checks) {
        $icon  = if ($check.Passed) { [char]0x2713 } else { [char]0x2717 }
        $color = if ($check.Passed) { $CLR_OK } else { $CLR_ERR }

        $markerLbl           = New-Object System.Windows.Forms.Label
        $markerLbl.Text      = $icon
        $markerLbl.Font      = $FONT_STEP
        $markerLbl.ForeColor = $color
        $markerLbl.Left      = 0
        $markerLbl.Top       = $y
        $markerLbl.Width     = 26
        $markerLbl.Height    = 24
        $markerLbl.TextAlign = 'MiddleCenter'
        $script:ContentPanel.Controls.Add($markerLbl)

        $detailTb = Add-CopyableText -Text "$($check.Name): $($check.Detail)" -Y $y -Left 30 -Width ($CONTENT_WIDTH - 30) -Font $FONT_BODY -Color $color
        $detailTb.Left = 30
        $y += [Math]::Max(26, $detailTb.Height) + 4
    }

    $y += 4
    $y = Add-UIDivider -Y $y

    if ($script:PreflightResult.Status -eq 'SshFailed') {
        $y = (Add-UILabel -Text "SSH server verification failed. The SSH infrastructure must be healthy before configuring security." -Y $y -Font $FONT_BOLD -Color $CLR_ERR).Bottom + 8
        $y = (Add-UILabel -Text "Suggestions: re-run Quick Start Part 1 to reinstall, troubleshoot the errors above, or file a bug report at the SecureRDP GitHub repository." -Y $y -Color $CLR_DARK_TEXT).Bottom + 8

        $btnNext.Text    = 'Exit'
        $btnNext.Enabled = $true
        $script:BtnNextHandler = { $form.Close() }
        $btnNext.Add_Click($script:BtnNextHandler)
        return
    }

    # Success or degraded
    $statusColor = if ($script:PreflightResult.Status -eq 'SshDegraded') { $CLR_WARN } else { $CLR_OK }
    $statusText  = if ($script:PreflightResult.Status -eq 'SshDegraded') {
        "SSH server is operational with minor issues. You may proceed."
    } else {
        "SSH server is healthy and operational."
    }
    $y = (Add-UILabel -Text $statusText -Y $y -Font $FONT_BOLD -Color $statusColor).Bottom + 8
    $y = (Add-UILabel -Text "The next step lets you configure firewall rules and optional security restrictions for RDP access." -Y $y -Color $CLR_DARK_TEXT).Bottom + 4

    $btnNext.Text    = 'Proceed'
    $btnNext.Enabled = $true
    $script:BtnNextHandler = { Show-Screen2 }
    $btnNext.Add_Click($script:BtnNextHandler)
}

# =============================================================================
# SCREEN 2: Security Options
# =============================================================================
function Show-Screen2 {
    Clear-ContentPanel
    $script:CurrentScreen    = 2
    $script:HeaderLabel.Text = 'Security Configuration'
    $btnBack.Visible         = $true
    $btnNext.Text            = 'Proceed'
    $btnNext.Enabled         = $true

    if ($null -ne $script:BtnNextHandler) { $btnNext.remove_Click($script:BtnNextHandler) }
    if ($null -ne $script:BtnBackHandler) { $btnBack.remove_Click($script:BtnBackHandler) }

    $script:BtnBackHandler = { Show-Screen1 }
    $btnBack.Add_Click($script:BtnBackHandler)

    $y = 4

    # --- Session type detection (fresh each render) ---
    $sessionType = Get-SessionType
    Write-UIDebug "Screen 2: sessionType=$sessionType"
    try { Write-SrdpLog "UI_Phase2 Screen 2: sessionType=$sessionType" -Level INFO } catch {}

    # --- RDP-direct warning banner ---
    if ($sessionType -eq 'rdp-direct') {
        $warnPanel           = New-Object System.Windows.Forms.Panel
        $warnPanel.Left      = 0
        $warnPanel.Top       = $y
        $warnPanel.Width     = $CONTENT_WIDTH
        $warnPanel.Height    = 50
        $warnPanel.BackColor = $CLR_MSG_WARN_BG
        $warnPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

        $warnLbl           = New-Object System.Windows.Forms.Label
        $warnLbl.Text      = "You are connected via direct RDP. For safety, some options are restricted in this session. Connect locally or via the SSH tunnel to access all options."
        $warnLbl.Font      = $FONT_SMALL
        $warnLbl.ForeColor = $CLR_WARN
        $warnLbl.Dock      = [System.Windows.Forms.DockStyle]::Fill
        $warnLbl.Padding   = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)
        $warnPanel.Controls.Add($warnLbl)
        $script:ContentPanel.Controls.Add($warnPanel)
        $y += 58
    }

    $y = (Add-UILabel -Text "Configure the security settings for this machine. Each option can be changed later via the Enhanced Security or Manage screens." -Y $y -Color $CLR_DARK_TEXT).Bottom + 12

    # --- Toggle blocks ---
    # We use CheckBox controls backed by panels for visual toggle appearance

    $sshAvailable  = ($sessionType -ne 'rdp-tunnel')
    $rdpAvailable  = ($sessionType -ne 'rdp-direct')
    $loopAvailable = ($sessionType -ne 'rdp-direct')

    # Toggle 1: SSH allow rule
    $script:ChkSsh = New-Object System.Windows.Forms.CheckBox
    $y = New-ToggleBlock -Y $y -Title "Enable SSH inbound firewall rule" `
        -Description "Allows inbound SSH connections on port $SshPort. Required for remote tunnel access." `
        -DefaultOn $true -Enabled $sshAvailable -CheckBoxRef ([ref]$script:ChkSsh)

    # Toggle 2: RDP block rules
    $script:ChkRdp = New-Object System.Windows.Forms.CheckBox
    $rdpDefault = if ($sessionType -eq 'rdp-direct') { $false } else { $true }
    $y = New-ToggleBlock -Y $y -Title "Block direct RDP connections" `
        -Description "Blocks direct inbound RDP on port $script:RdpPort (TCP and UDP). After enabling, use the SSH tunnel client package to connect." `
        -DefaultOn $rdpDefault -Enabled $rdpAvailable -CheckBoxRef ([ref]$script:ChkRdp)

    # Toggle 3: Loopback restriction
    $script:ChkLoop = New-Object System.Windows.Forms.CheckBox
    $y = New-ToggleBlock -Y $y -Title "Restrict RDP listener to loopback only" `
        -Description "Restricts the RDP listener to the loopback address (127.0.0.1). Provides enforcement beyond firewall rules. The Remote Desktop service will restart briefly." `
        -DefaultOn $false -Enabled $loopAvailable -ExtraTag 'Experimental' -CheckBoxRef ([ref]$script:ChkLoop)

    $y += 4
    $y = Add-UIDivider -Y $y
    $y = (Add-UILabel -Text "SecureRDP manages the default RDP-Tcp listener only. Additional RDP listeners on this machine are not affected." -Y $y -Font $FONT_SMALL -Color ([System.Drawing.Color]::FromArgb(120, 120, 120))).Bottom + 4

    # Wire Proceed button
    $script:BtnNextHandler = {
        $script:SshRuleEnabled  = $script:ChkSsh.Checked
        $script:RdpBlockEnabled = $script:ChkRdp.Checked
        $script:ApplyLoopback   = $script:ChkLoop.Checked
        Show-Screen3
    }
    $btnNext.Add_Click($script:BtnNextHandler)
}

# =============================================================================
# HELPER: New-ToggleBlock
# =============================================================================
function New-ToggleBlock {
    param(
        [int]$Y,
        [string]$Title,
        [string]$Description,
        [bool]$DefaultOn,
        [bool]$Enabled,
        [string]$ExtraTag = '',
        [ref]$CheckBoxRef
    )

    $blockPnl           = New-Object System.Windows.Forms.Panel
    $blockPnl.Left      = 0
    $blockPnl.Top       = $Y
    $blockPnl.Width     = $CONTENT_WIDTH
    $blockPnl.BackColor = $CLR_WHITE
    $blockPnl.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

    # Hidden checkbox for state
    $cb         = New-Object System.Windows.Forms.CheckBox
    $cb.Visible = $false
    $cb.Checked = if ($Enabled) { $DefaultOn } else { $false }
    $cb.Enabled = $Enabled
    $blockPnl.Controls.Add($cb)
    $CheckBoxRef.Value = $cb

    # Visual toggle panel
    $togOuter        = New-Object System.Windows.Forms.Panel
    $togOuter.Width  = 44; $togOuter.Height = 22
    $togOuter.Left   = 10; $togOuter.Top = 12
    $togOuter.Cursor = if ($Enabled) { [System.Windows.Forms.Cursors]::Hand } else { [System.Windows.Forms.Cursors]::Default }

    $togTrack           = New-Object System.Windows.Forms.Panel
    $togTrack.Width     = 44; $togTrack.Height = 22
    $togTrack.Left      = 0; $togTrack.Top = 0
    $initialColor = if (-not $Enabled) { $CLR_DISABLED_FG } elseif ($cb.Checked) { $CLR_TOGGLE_ON } else { $CLR_TOGGLE_OFF }
    $togTrack.BackColor = $initialColor

    $togThumb           = New-Object System.Windows.Forms.Panel
    $togThumb.Width     = 16; $togThumb.Height = 16
    $togThumb.Top       = 3
    $togThumb.Left      = if ($cb.Checked) { 25 } else { 3 }
    $togThumb.BackColor = $CLR_WHITE
    $togTrack.Controls.Add($togThumb)
    $togOuter.Controls.Add($togTrack)

    if ($Enabled) {
        $togClickScript = {
            $newState = -not $cb.Checked
            $cb.Checked = $newState
            $togTrack.BackColor = if ($newState) { $CLR_TOGGLE_ON } else { $CLR_TOGGLE_OFF }
            $togThumb.Left      = if ($newState) { 25 } else { 3 }
        }.GetNewClosure()
        $togOuter.Add_Click($togClickScript)
        $togTrack.Add_Click($togClickScript)
        $togThumb.Add_Click($togClickScript)
    }

    $blockPnl.Controls.Add($togOuter)

    # Title label
    $titleLbl           = New-Object System.Windows.Forms.Label
    $titleLbl.Text      = $Title
    $titleLbl.Font      = $FONT_BOLD
    $titleLbl.ForeColor = if ($Enabled) { [System.Drawing.Color]::Black } else { $CLR_DISABLED_FG }
    $titleLbl.Left      = 62; $titleLbl.Top = 12
    $titleLbl.AutoSize  = $true
    $blockPnl.Controls.Add($titleLbl)

    $tagX = 62 + $titleLbl.PreferredWidth + 8

    # Extra tag (e.g. Experimental)
    if ($ExtraTag -and $ExtraTag.Length -gt 0) {
        $expTag           = New-Object System.Windows.Forms.Label
        $expTag.Text      = $ExtraTag
        $expTag.Font      = $FONT_TAG
        $expTag.ForeColor = $CLR_TAG_EXP_FG
        $expTag.BackColor = $CLR_TAG_EXP_BG
        $expTag.Left      = $tagX; $expTag.Top = 14
        $expTag.Width     = 76; $expTag.Height = 16
        $expTag.TextAlign = 'MiddleCenter'
        $expTag.AutoSize  = $false
        $blockPnl.Controls.Add($expTag)
    }

    # Description
    $descLbl           = New-Object System.Windows.Forms.Label
    $descLbl.Text      = $Description
    $descLbl.Font      = $FONT_SMALL
    $descLbl.ForeColor = if ($Enabled) { [System.Drawing.Color]::FromArgb(80, 80, 80) } else { $CLR_DISABLED_FG }
    $descLbl.Left      = 62; $descLbl.Top = 36
    $descLbl.Width     = $CONTENT_WIDTH - 82
    $descLbl.MaximumSize = New-Object System.Drawing.Size(($CONTENT_WIDTH - 82), 2000)
    $descLbl.AutoSize  = $true
    $blockPnl.Controls.Add($descLbl)

    # Unavailable note
    $noteHeight = 0
    if (-not $Enabled) {
        $noteLbl           = New-Object System.Windows.Forms.Label
        $noteLbl.Text      = "Not available in this session type."
        $noteLbl.Font      = [System.Drawing.Font]::new('Segoe UI', 8, [System.Drawing.FontStyle]::Italic)
        $noteLbl.ForeColor = $CLR_DISABLED_FG
        $noteLbl.Left      = 62
        $noteLbl.Top       = $descLbl.Top + $descLbl.PreferredHeight + 4
        $noteLbl.AutoSize  = $true
        $blockPnl.Controls.Add($noteLbl)
        $noteHeight = $noteLbl.PreferredHeight + 4
    }

    $blockH = $descLbl.Top + $descLbl.PreferredHeight + $noteHeight + 14
    $blockPnl.Height = $blockH

    $script:ContentPanel.Controls.Add($blockPnl)
    return ($Y + $blockH + 10)
}

# =============================================================================
# SCREEN 3: Execution
# =============================================================================
function Show-Screen3 {
    Clear-ContentPanel
    $script:CurrentScreen      = 3
    $script:HeaderLabel.Text   = 'Configuring...'
    $btnBack.Visible           = $false
    $btnNext.Text              = 'Close'
    $btnNext.Enabled           = $false

    if ($null -ne $script:BtnNextHandler) { $btnNext.remove_Click($script:BtnNextHandler) }
    if ($null -ne $script:BtnBackHandler) { $btnBack.remove_Click($script:BtnBackHandler) }

    $y = 4

    # Get plan
    $planResult = Invoke-Phase2Controller `
        -SshPort       $SshPort `
        -RdpPort       $script:RdpPort `
        -EnableSshRule  $script:SshRuleEnabled `
        -EnableRdpBlock $script:RdpBlockEnabled `
        -ApplyLoopback  $script:ApplyLoopback `
        -StateFilePath  $STATE_FILE `
        -Confirmed      $false

    $steps = @($planResult.Data.Plan.Steps)

    # Step checklist
    $stepLabels = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($step in $steps) {
        $markerLbl           = New-Object System.Windows.Forms.Label
        $markerLbl.Text      = [char]0x25CB
        $markerLbl.Left      = 0; $markerLbl.Top = $y
        $markerLbl.Width     = 26; $markerLbl.Height = 26
        $markerLbl.Font      = $FONT_STEP
        $markerLbl.ForeColor = $CLR_STEP_PENDING
        $markerLbl.AutoSize  = $false
        $markerLbl.TextAlign = 'MiddleCenter'
        $script:ContentPanel.Controls.Add($markerLbl)

        $stepLbl           = New-Object System.Windows.Forms.Label
        $stepLbl.Text      = $step
        $stepLbl.Left      = 30; $stepLbl.Top = $y
        $stepLbl.Width     = $CONTENT_WIDTH - 30
        $stepLbl.Font      = $FONT_STEP
        $stepLbl.ForeColor = $CLR_STEP_PENDING
        $stepLbl.AutoSize  = $false; $stepLbl.Height = 26
        $script:ContentPanel.Controls.Add($stepLbl)

        $null = $stepLabels.Add(@{ Marker = $markerLbl; Label = $stepLbl })
        $y += 30
    }
    $script:StepLabels = $stepLabels.ToArray()
    $y += 4
    $y = Add-UIDivider -Y $y

    # Activity log
    $y = (Add-UILabel -Text 'Activity:' -Y $y -Font $FONT_STEP -Color $CLR_HEADER_BG).Bottom + 2

    $script:LogBox             = New-Object System.Windows.Forms.RichTextBox
    $script:LogBox.ReadOnly    = $true
    $script:LogBox.ScrollBars  = 'Vertical'
    $script:LogBox.WordWrap    = $false
    $script:LogBox.Left        = 0; $script:LogBox.Top = $y
    $script:LogBox.Width       = $CONTENT_WIDTH
    $script:LogBox.Height      = $LOG_TB_HEIGHT
    $script:LogBox.Font        = $FONT_LOG
    $script:LogBox.BackColor   = $CLR_LOG_BG
    $script:LogBox.BorderStyle = 'FixedSingle'
    $script:ContentPanel.Controls.Add($script:LogBox)
    $y += $LOG_TB_HEIGHT + 8
    $y = Add-UIDivider -Y $y

    # Message panel
    $script:MsgPanel             = New-Object System.Windows.Forms.Panel
    $script:MsgPanel.Left        = 0; $script:MsgPanel.Top = $y
    $script:MsgPanel.Width       = $CONTENT_WIDTH
    $script:MsgPanel.Height      = 100
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
    $script:MsgLabel.Text      = 'Running configuration...'
    $script:MsgPanel.Controls.Add($script:MsgLabel)

    [System.Windows.Forms.Application]::DoEvents()

    # Progress callback
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
                $script:LogBox.SelectionColor = [System.Drawing.Color]::FromArgb(200, 60, 0)
                $script:LogBox.AppendText("[WARN] $($p.Message)`r`n")
                $script:LogBox.SelectionColor = $script:LogBox.ForeColor
            } else {
                $script:LogBox.AppendText("$($p.Message)`r`n")
            }
            $script:LogBox.ScrollToCaret()
        }
        [System.Windows.Forms.Application]::DoEvents()
    }

    # Execute
    $script:InstallInProgress = $true

    $execResult = Invoke-Phase2Controller `
        -SshPort        $SshPort `
        -RdpPort        $script:RdpPort `
        -EnableSshRule  $script:SshRuleEnabled `
        -EnableRdpBlock $script:RdpBlockEnabled `
        -ApplyLoopback  $script:ApplyLoopback `
        -StateFilePath  $STATE_FILE `
        -Confirmed      $true `
        -OnProgress     $onProgress

    $script:InstallInProgress = $false
    try { Write-SrdpLog "Phase2 controller returned. Status=$($execResult.Status) Errors=$($execResult.Errors.Count)" -Level INFO } catch {}

    # Flush all errors to log box
    if ($execResult.Errors.Count -gt 0 -and $null -ne $script:LogBox) {
        $script:LogBox.SelectionColor = [System.Drawing.Color]::FromArgb(192, 32, 14)
        $script:LogBox.AppendText("--- $($execResult.Errors.Count) error(s) ---`r`n")
        foreach ($err in $execResult.Errors) {
            $script:LogBox.AppendText("[ERROR] $err`r`n")
        }
        $script:LogBox.SelectionColor = $script:LogBox.ForeColor
        $script:LogBox.ScrollToCaret()
    }

    # Mark remaining pending steps as done if success
    if ($execResult.Success) {
        foreach ($pair in $script:StepLabels) {
            if ($pair.Marker.Text -eq [string][char]0x25CB) {
                $pair.Marker.Text      = [char]0x2713
                $pair.Marker.ForeColor = $CLR_STEP_DONE
                $pair.Label.ForeColor  = $CLR_STEP_DONE
            }
        }
    }

    # Result display
    if ($execResult.Success) {
        $script:HeaderLabel.Text   = 'Configuration Complete'
        $script:MsgPanel.BackColor = $CLR_MSG_OK_BG
        $script:MsgLabel.ForeColor = $CLR_OK
        $errSuffix = if ($execResult.Errors.Count -gt 0) {
            "`r`n`r`nNote: $($execResult.Errors.Count) warning(s). Review the activity log."
        } else { '' }
        $script:MsgLabel.Text = "Security configuration complete.$errSuffix"

        if ($execResult.Errors.Count -gt 0) {
            $script:MsgPanel.BackColor = $CLR_MSG_WARN_BG
            $script:MsgLabel.ForeColor = $CLR_WARN
        }

        $btnNext.Text    = 'Continue'
        $btnNext.Enabled = $true
        $script:BtnNextHandler = { Show-Screen4 }
        $btnNext.Add_Click($script:BtnNextHandler)
    } else {
        $script:HeaderLabel.Text   = 'Configuration Issues'
        $script:MsgPanel.BackColor = $CLR_MSG_WARN_BG
        $script:MsgLabel.ForeColor = $CLR_WARN
        $firstErr = if ($execResult.Errors.Count -gt 0) { $execResult.Errors[0] } else { 'An unknown error occurred.' }
        $script:MsgLabel.Text = (
            "Some configuration steps did not complete: $firstErr`r`n`r`n" +
            "You can still proceed to create client packages. Firewall rules can be " +
            "created manually if needed -- see the SecureRDP documentation for details.")

        $btnNext.Text    = 'Continue Anyway'
        $btnNext.Enabled = $true
        $script:BtnNextHandler = { Show-Screen4 }
        $btnNext.Add_Click($script:BtnNextHandler)

        # Also offer Close
        $btnBack.Visible = $true
        $btnBack.Text    = 'Close'
        if ($null -ne $script:BtnBackHandler) { $btnBack.remove_Click($script:BtnBackHandler) }
        $script:BtnBackHandler = { $form.Close() }
        $btnBack.Add_Click($script:BtnBackHandler)
    }

    [System.Windows.Forms.Application]::DoEvents()
}

# =============================================================================
# SCREEN 4: Completion / Transition
# =============================================================================
function Show-Screen4 {
    Clear-ContentPanel
    $script:CurrentScreen      = 4
    $script:HeaderLabel.Text   = 'Setup Complete'
    $btnBack.Visible           = $false

    if ($null -ne $script:BtnNextHandler) { $btnNext.remove_Click($script:BtnNextHandler) }
    if ($null -ne $script:BtnBackHandler) { $btnBack.remove_Click($script:BtnBackHandler) }

    $y = 4

    $y = (Add-UILabel -Text "Phase 2 Configuration Summary" -Y $y -Font $FONT_STEP -Color $CLR_HEADER_BG).Bottom + 12

    $sshStr  = if ($script:SshRuleEnabled)  { 'Enabled' } else { 'Disabled' }
    $rdpStr  = if ($script:RdpBlockEnabled) { 'Enabled' } else { 'Disabled' }
    $loopStr = if ($script:ApplyLoopback)   { 'Applied' } else { 'Not applied' }

    $y = (Add-UILabel -Text "SSH inbound firewall rule: $sshStr" -Y $y -Font $FONT_BOLD -Color $(if ($script:SshRuleEnabled) { $CLR_OK } else { $CLR_DARK_TEXT })).Bottom + 4
    $y = (Add-UILabel -Text "RDP block firewall rules: $rdpStr" -Y $y -Font $FONT_BOLD -Color $(if ($script:RdpBlockEnabled) { $CLR_OK } else { $CLR_DARK_TEXT })).Bottom + 4
    $y = (Add-UILabel -Text "Loopback listener restriction: $loopStr" -Y $y -Font $FONT_BOLD -Color $(if ($script:ApplyLoopback) { $CLR_WARN } else { $CLR_DARK_TEXT })).Bottom + 12

    $y = Add-UIDivider -Y $y

    $y = (Add-UILabel -Text "Phase 2 setup is complete. To connect to this machine remotely via the SSH tunnel, you need to create at least one client package." -Y $y -Color $CLR_DARK_TEXT).Bottom + 8
    $y = (Add-UILabel -Text "The next wizard will guide you through generating a client connection package containing the SSH key, RDP configuration, and connection scripts for a user." -Y $y -Color $CLR_DARK_TEXT).Bottom + 12

    # Create Client Package button in content area (prominent)
    $btnCreatePkg              = New-Object System.Windows.Forms.Button
    $btnCreatePkg.Text         = 'Create Client Package'
    $btnCreatePkg.Width        = 200
    $btnCreatePkg.Height       = 36
    $btnCreatePkg.Left         = 0
    $btnCreatePkg.Top          = $y
    $btnCreatePkg.Font         = $FONT_BOLD
    $btnCreatePkg.FlatStyle    = [System.Windows.Forms.FlatStyle]::Flat
    $btnCreatePkg.BackColor    = $CLR_BTN_PRIMARY
    $btnCreatePkg.ForeColor    = $CLR_BTN_FG
    $btnCreatePkg.FlatAppearance.BorderSize = 0
    $btnCreatePkg.Cursor       = [System.Windows.Forms.Cursors]::Hand
    $script:ContentPanel.Controls.Add($btnCreatePkg)

    $btnCreatePkg.Add_Click({
        $ckwScript = Join-Path $ProjectRoot 'ClientKeyWizard.ps1'
        if (Test-Path $ckwScript) {
            $launchArgs = "-STA -ExecutionPolicy Bypass -File `"$ckwScript`" -SshPort $SshPort -ProjectRoot `"$ProjectRoot`""
            Start-Process 'powershell.exe' -ArgumentList $launchArgs
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "Client Key Wizard not found at:`n$ckwScript`n`nThis feature will be available in the next build.",
                'SecureRDP',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
        $form.Close()
    })

    # Done button in button bar
    $btnNext.Text    = 'Done'
    $btnNext.Enabled = $true
    $script:BtnNextHandler = { $form.Close() }
    $btnNext.Add_Click($script:BtnNextHandler)
}

# =============================================================================
# STARTUP
# =============================================================================
$form.Add_Shown({
    Write-UIDebug "form.Shown event fired. SkipSshVerification=$SkipSshVerification"
    # Check if Phase 2 was already completed
    if (Test-Path $STATE_FILE) {
        try {
            $existing = Get-Content $STATE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $existing.Phase2 -and $existing.Phase2.Success -eq $true) {
                # Phase 2 already done -- go to Screen 4 (summary/transition)
                $script:SshRuleEnabled  = $existing.Phase2.SshRuleEnabled
                $script:RdpBlockEnabled = $existing.Phase2.RdpBlockEnabled
                $script:ApplyLoopback   = $existing.Phase2.LoopbackRestrictionApplied
                Show-Screen4
                return
            }
        } catch {}
    }
    # If launched from QS Part 1 completion, skip SSH verification (just ran)
    if ($SkipSshVerification) {
        Write-UIDebug "SkipSshVerification=true -- going directly to Screen 2"
        try { Write-SrdpLog "UI_Phase2: skipping SSH verification (launched from QS Part 1)." -Level INFO } catch {}
        # Still need preflight for RDP port
        $script:PreflightResult = $null
        try {
            $script:PreflightResult = Invoke-Phase2Preflight -SshPort $SshPort -StateFilePath $STATE_FILE
            $script:RdpPort = $script:PreflightResult.Data.RdpPort
        } catch {}
        Show-Screen2
        return
    }
    Show-Screen1
})

[System.Windows.Forms.Application]::Run($form)
