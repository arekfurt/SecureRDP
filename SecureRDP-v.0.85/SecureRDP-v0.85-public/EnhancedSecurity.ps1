#Requires -Version 5.1
# =============================================================================
# SecureRDP -- Enhanced Security
# EnhancedSecurity.ps1
#
# App-wide Enhanced Security configuration screen.
# Launched from the ServerWizard dashboard and from mode Manage screens.
# Controls and status apply machine-wide regardless of active mode.
# State persisted in config.ini under [EnhancedSecurity].
# Must be run as Administrator.
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName('System.Drawing')       | Out-Null
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------------------
# Admin check
# ---------------------------------------------------------------------------
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    [System.Windows.Forms.MessageBox]::Show(
        'Enhanced Security must be run as Administrator.',
        'SecureRDP - Enhanced Security',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    exit 1
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigFile = Join-Path $ScriptDir 'config.ini'

$SRDP_VER = '0.848'
try {
    $modeIni = Join-Path $ScriptDir 'Modes\SSHProto\mode.ini'
    if (Test-Path $modeIni) {
        $iniContent = Get-Content $modeIni -Raw -ErrorAction SilentlyContinue
        if ($iniContent -match 'Version\s*=\s*(.+)') { $SRDP_VER = $Matches[1].Trim() }
    }
} catch {}

# ---------------------------------------------------------------------------
# Module imports -- all with existence guard + EAP reset
# ---------------------------------------------------------------------------
$LogModule    = Join-Path $ScriptDir 'SupportingModules\SrdpLog.psm1'
$InitModule   = Join-Path $ScriptDir 'SupportingModules\InitialChecks.psm1'
$AEModule     = Join-Path $ScriptDir 'SupportingModules\AttackExposure.psm1'
$CoreModule   = Join-Path $ScriptDir 'Modes\SSHProto\SSHProtoCore.psm1'

foreach ($mod in @($LogModule, $InitModule, $AEModule, $CoreModule)) {
    if (Test-Path $mod) {
        try {
            Import-Module $mod -Force -DisableNameChecking -ErrorAction SilentlyContinue
            $ErrorActionPreference = 'Stop'
        } catch {}
    }
}
try { Write-SrdpLog 'EnhancedSecurity.ps1 starting.' -Level INFO -Component 'EnhancedSecurity' } catch {}

# ---------------------------------------------------------------------------
# UI CONSTANTS
# ---------------------------------------------------------------------------
$FW           = 640
$FONT_HEADING = New-Object System.Drawing.Font('Times New Roman', 14, [System.Drawing.FontStyle]::Bold)
$FONT_BODY    = New-Object System.Drawing.Font('Times New Roman', 12, [System.Drawing.FontStyle]::Bold)
$FONT_BTN     = New-Object System.Drawing.Font('Times New Roman', 12, [System.Drawing.FontStyle]::Bold)
$CLR_HDR      = [System.Drawing.Color]::FromArgb(0,   60, 120)
$CLR_OK       = [System.Drawing.Color]::FromArgb(10, 110,  10)
$CLR_WARN     = [System.Drawing.Color]::FromArgb(180,  80,  10)
$CLR_ERR      = [System.Drawing.Color]::FromArgb(170,  20,  10)
$CLR_BLUE     = [System.Drawing.Color]::FromArgb(0,   84, 166)
$CLR_AMBER    = [System.Drawing.Color]::FromArgb(200, 120,   0)
$CLR_GREY     = [System.Drawing.Color]::FromArgb(100, 100, 100)
$CLR_BG       = [System.Drawing.Color]::FromArgb(245, 245, 245)
$CLR_WHITE    = [System.Drawing.Color]::White
$CLR_SILVR    = [System.Drawing.Color]::Silver
$CLR_DISABLED = [System.Drawing.Color]::FromArgb(210, 210, 210)
$CLR_DIS_FG   = [System.Drawing.Color]::FromArgb(140, 140, 140)

$script:ESResult = 'close'

# ---------------------------------------------------------------------------
# HELPER: Read-LoopbackState
# Detects whether the loopback restriction is currently applied by reading
# the LanAdapter registry value and comparing to the loopback adapter index.
# Returns $true if applied, $false otherwise.
# ---------------------------------------------------------------------------
function Read-LoopbackState {
    $WS_PATH = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
    try {
        $lanAdapter = $null
        try {
            $lanAdapter = (Get-ItemProperty $WS_PATH -Name 'LanAdapter' -ErrorAction SilentlyContinue).LanAdapter
        } catch {}
        if ($null -eq $lanAdapter -or $lanAdapter -eq 0) { return $false }
        $loopbackAddr = Get-NetIPAddress -IPAddress '127.0.0.1' -ErrorAction SilentlyContinue
        if ($null -eq $loopbackAddr -or $null -eq $loopbackAddr.InterfaceIndex) { return $false }
        return ([int]$lanAdapter -eq [int]$loopbackAddr.InterfaceIndex)
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# HELPER: Add-Sect
# ---------------------------------------------------------------------------
function Add-Sect {
    param(
        [System.Windows.Forms.Panel]$Panel,
        [string]$Text,
        [int]$Top,
        [int]$Width
    )
    $l           = New-Object System.Windows.Forms.Label
    $l.Text      = $Text
    $l.Font      = $FONT_HEADING
    $l.ForeColor = $CLR_HDR
    $l.Left      = 0; $l.Top = $Top; $l.AutoSize = $true
    $Panel.Controls.Add($l)
    $sep           = New-Object System.Windows.Forms.Panel
    $sep.Left      = 0; $sep.Top = $Top + 26
    $sep.Width     = $Width; $sep.Height = 1
    $sep.BackColor = $CLR_HDR
    $Panel.Controls.Add($sep)
    return $Top + 34
}

# ---------------------------------------------------------------------------
# HELPER: Add-StatusRow
# Adds a label+value pair. Returns updated Top.
# ---------------------------------------------------------------------------
function Add-StatusRow {
    param(
        [System.Windows.Forms.Panel]$Panel,
        [string]$Label,
        [string]$Value,
        [System.Drawing.Color]$VColor,
        [int]$Top,
        [int]$Width
    )
    $ll           = New-Object System.Windows.Forms.Label
    $ll.Text      = $Label
    $ll.Font      = $FONT_BODY
    $ll.ForeColor = $CLR_GREY
    $ll.Left      = 0; $ll.Top = $Top; $ll.Width = 220; $ll.Height = 24; $ll.AutoSize = $false
    $Panel.Controls.Add($ll)
    $vl           = New-Object System.Windows.Forms.Label
    $vl.Text      = $Value
    $vl.Font      = $FONT_BODY
    $vl.ForeColor = $VColor
    $vl.Left      = 224; $vl.Top = $Top; $vl.Width = $Width - 224; $vl.AutoSize = $false
    $Panel.Controls.Add($vl)
    return $Top + 26
}

# ---------------------------------------------------------------------------
# HELPER: Add-BlockedBtn
# Renders a greyed-out disabled button with a tooltip explanation.
# ---------------------------------------------------------------------------
function Add-BlockedBtn {
    param(
        [System.Windows.Forms.Panel]$Panel,
        [string]$Text,
        [string]$Tooltip,
        [int]$Top,
        [int]$Width
    )
    $btn              = New-Object System.Windows.Forms.Button
    $btn.Text         = $Text
    $btn.Left         = 0; $btn.Top = $Top; $btn.Width = $Width; $btn.Height = 30
    $btn.FlatStyle    = 'Flat'
    $btn.Font         = $FONT_BTN
    $btn.BackColor    = $CLR_DISABLED
    $btn.ForeColor    = $CLR_DIS_FG
    $btn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(190, 190, 190)
    $btn.Enabled      = $false
    $tt               = New-Object System.Windows.Forms.ToolTip
    $tt.SetToolTip($btn, $Tooltip)
    $btn.Tag          = $tt
    $Panel.Controls.Add($btn)
    return $Top + 36
}

# ---------------------------------------------------------------------------
# Show-ESScreen
# ---------------------------------------------------------------------------
function Show-ESScreen {

    # ---- Live status ----
    $rdpBlockTcp     = $null
    $rdpBlockUdp     = $null
    $rdpBlockEnabled = $false
    try {
        $rdpBlockTcp     = Get-NetFirewallRule -Name 'SecureRDP-RDP-BlockDirect'     -ErrorAction SilentlyContinue
        $rdpBlockUdp     = Get-NetFirewallRule -Name 'SecureRDP-RDP-BlockDirect-UDP' -ErrorAction SilentlyContinue
        $rdpBlockEnabled = ($null -ne $rdpBlockTcp -and $rdpBlockTcp.Enabled -eq 'True') -and
                           ($null -ne $rdpBlockUdp -and $rdpBlockUdp.Enabled -eq 'True')
    } catch {
        $errMsg = $_.Exception.Message
        try { Write-SrdpLog "EnhancedSecurity: RDP block rule check failed: $errMsg" -Level WARN -Component 'EnhancedSecurity' } catch {}
    }

    $rdpRulesExist = ($null -ne $rdpBlockTcp -or $null -ne $rdpBlockUdp)

    $loopEnabled = Read-LoopbackState

    $sessionType = 'local'
    try {
        if (Get-Command 'Get-SessionType' -ErrorAction SilentlyContinue) {
            $sessionType = Get-SessionType
        }
    } catch {}
    $isDirectRdp = ($sessionType -eq 'rdp-direct')

    try { Write-SrdpLog "EnhancedSecurity: rdpBlockEnabled=$rdpBlockEnabled  loopEnabled=$loopEnabled  sessionType=$sessionType" -Level INFO -Component 'EnhancedSecurity' } catch {}

    # Read OriginalLanAdapter from config.ini for removal
    $savedOriginalLanAdapter = $null
    try {
        if (Get-Command 'Get-SrdpIniValue' -ErrorAction SilentlyContinue) {
            $raw = Get-SrdpIniValue -Path $ConfigFile -Section 'EnhancedSecurity' -Key 'OriginalLanAdapter'
            if ($null -ne $raw -and $raw -ne '') {
                $n = 0
                if ([int]::TryParse($raw, [ref]$n)) { $savedOriginalLanAdapter = $n }
            }
        }
    } catch {}

    # ---- Build form ----
    $f                 = New-Object System.Windows.Forms.Form
    $f.Text            = "SecureRDP v$SRDP_VER - Enhanced Security"
    $f.Width           = $FW + 18
    $f.Height          = 560
    $f.FormBorderStyle = 'FixedSingle'
    $f.MaximizeBox     = $false
    $f.StartPosition   = 'CenterScreen'
    $f.BackColor       = $CLR_BG

    # Header
    $hdr           = New-Object System.Windows.Forms.Panel
    $hdr.Dock      = 'Top'; $hdr.Height = 60
    $hdr.BackColor = $CLR_HDR
    $hl            = New-Object System.Windows.Forms.Label
    $hl.Text       = 'Enhanced Security'
    $hl.Font       = New-Object System.Drawing.Font('Times New Roman', 16, [System.Drawing.FontStyle]::Bold)
    $hl.ForeColor  = $CLR_WHITE
    $hl.Dock       = 'Fill'; $hl.TextAlign = 'MiddleLeft'
    $hl.Padding    = New-Object System.Windows.Forms.Padding(14, 0, 0, 0)
    $hdr.Controls.Add($hl); $f.Controls.Add($hdr)

    # Bottom button bar
    $bb           = New-Object System.Windows.Forms.Panel
    $bb.Dock      = 'Bottom'; $bb.Height = 58
    $bb.BackColor = [System.Drawing.Color]::FromArgb(232, 232, 232)
    $bbs          = New-Object System.Windows.Forms.Panel
    $bbs.Dock     = 'Top'; $bbs.Height = 1; $bbs.BackColor = $CLR_SILVR
    $bb.Controls.Add($bbs); $f.Controls.Add($bb)

    $bClose             = New-Object System.Windows.Forms.Button
    $bClose.Text        = 'Close'
    $bClose.Width       = 100; $bClose.Height = 34; $bClose.Top = 12
    $bClose.Left        = $bb.Width - 118
    $bClose.FlatStyle   = 'Flat'; $bClose.Font = $FONT_BTN
    $bClose.BackColor   = $CLR_WHITE
    $bClose.FlatAppearance.BorderColor = $CLR_SILVR
    $bb.Controls.Add($bClose)

    # Scroll panel
    $pnl            = New-Object System.Windows.Forms.Panel
    $pnl.AutoScroll = $true
    $pnl.Dock       = 'Fill'
    $pnl.Padding    = New-Object System.Windows.Forms.Padding(24, 14, 24, 8)
    $f.Controls.Add($pnl)
    $cW = $FW - 48

    $y = 0

    # Refresh button
    $bRefresh           = New-Object System.Windows.Forms.Button
    $bRefresh.Text      = 'Refresh'
    $bRefresh.Width     = 100; $bRefresh.Height = 28
    $bRefresh.Left      = $cW - 100; $bRefresh.Top = $y
    $bRefresh.FlatStyle = 'Flat'; $bRefresh.Font = $FONT_BTN
    $bRefresh.BackColor = $CLR_WHITE
    $bRefresh.FlatAppearance.BorderColor = $CLR_SILVR
    $bRefresh.Cursor    = 'Hand'
    $pnl.Controls.Add($bRefresh)
    $y += 40

    # =========================================================================
    # SECTION 1: RDP Block Rules
    # =========================================================================
    $y = Add-Sect -Panel $pnl -Text 'RDP Block Rules' -Top $y -Width $cW

    $rdpStatusText  = if ($rdpBlockEnabled) { 'Enabled -- direct RDP connections are blocked' } `
                      elseif ($rdpRulesExist) { 'Rules present but disabled' } `
                      else { 'Not configured' }
    $rdpStatusColor = if ($rdpBlockEnabled) { $CLR_OK } elseif ($rdpRulesExist) { $CLR_WARN } else { $CLR_GREY }
    $y = Add-StatusRow -Panel $pnl -Label 'Status:' -Value $rdpStatusText -VColor $rdpStatusColor -Top $y -Width $cW
    $y += 6

    $descLbl1           = New-Object System.Windows.Forms.Label
    $descLbl1.Text      = 'When enabled, Windows Firewall blocks inbound connections on the RDP port. Users must connect via the SecureRDP SSH tunnel instead of directly.'
    $descLbl1.Font      = $FONT_BODY
    $descLbl1.ForeColor = $CLR_GREY
    $descLbl1.Left      = 0; $descLbl1.Top = $y
    $descLbl1.Width     = $cW; $descLbl1.Height = 50
    $descLbl1.MaximumSize = New-Object System.Drawing.Size($cW, 200)
    $descLbl1.AutoSize  = $true
    $pnl.Controls.Add($descLbl1)
    $y += 54

    if (-not $rdpRulesExist) {
        # Rules haven't been created -- hard block, redirect to QS Phase 2
        $y = Add-BlockedBtn -Panel $pnl -Text 'Enable RDP Block Rules' `
            -Tooltip 'RDP block rules have not been created yet. Run Quick Start Phase 2 to create them.' `
            -Top $y -Width 260
        $noteQs           = New-Object System.Windows.Forms.Label
        $noteQs.Text      = 'RDP block rules are created during Quick Start Phase 2 setup. Return to the dashboard and complete Phase 2 first.'
        $noteQs.Font      = $FONT_BODY
        $noteQs.ForeColor = $CLR_WARN
        $noteQs.Left      = 0; $noteQs.Top = $y
        $noteQs.Width     = $cW; $noteQs.Height = 26
        $noteQs.MaximumSize = New-Object System.Drawing.Size($cW, 200)
        $noteQs.AutoSize  = $true
        $pnl.Controls.Add($noteQs)
        $y += 36
    } elseif ($isDirectRdp -and -not $rdpBlockEnabled) {
        # Hard block: direct RDP session, would lock user out
        $y = Add-BlockedBtn -Panel $pnl -Text 'Enable RDP Block Rules' `
            -Tooltip 'You are connected directly via RDP. Enabling this rule would block your current session type. Use a local or SSH tunnel session to enable.' `
            -Top $y -Width 260
        $noteDirect           = New-Object System.Windows.Forms.Label
        $noteDirect.Text      = 'Cannot enable from a direct RDP session -- this would block your current connection. Log in locally or via SSH tunnel to enable.'
        $noteDirect.Font      = $FONT_BODY
        $noteDirect.ForeColor = $CLR_ERR
        $noteDirect.Left      = 0; $noteDirect.Top = $y
        $noteDirect.Width     = $cW; $noteDirect.Height = 26
        $noteDirect.MaximumSize = New-Object System.Drawing.Size($cW, 200)
        $noteDirect.AutoSize  = $true
        $pnl.Controls.Add($noteDirect)
        $y += 36
    } else {
        $toggleRdpText  = if ($rdpBlockEnabled) { 'Disable RDP Block Rules' } else { 'Enable RDP Block Rules' }
        $toggleRdpColor = if ($rdpBlockEnabled) { $CLR_AMBER } else { $CLR_BLUE }
        $bRdpToggle             = New-Object System.Windows.Forms.Button
        $bRdpToggle.Text        = $toggleRdpText
        $bRdpToggle.Left        = 0; $bRdpToggle.Top = $y; $bRdpToggle.Width = 260; $bRdpToggle.Height = 30
        $bRdpToggle.FlatStyle   = 'Flat'; $bRdpToggle.Font = $FONT_BTN
        $bRdpToggle.BackColor   = $toggleRdpColor; $bRdpToggle.ForeColor = $CLR_WHITE
        $bRdpToggle.FlatAppearance.BorderSize = 0; $bRdpToggle.Cursor = 'Hand'
        $pnl.Controls.Add($bRdpToggle)
        $y += 36

        $capturedRdpEnabled   = $rdpBlockEnabled
        $capturedConfigFile   = $ConfigFile
        $bRdpToggle.Add_Click({
            try {
                if ($capturedRdpEnabled) {
                    Disable-NetFirewallRule -Name 'SecureRDP-RDP-BlockDirect'     -ErrorAction Stop
                    Disable-NetFirewallRule -Name 'SecureRDP-RDP-BlockDirect-UDP' -ErrorAction Stop
                    try { Write-SrdpLog 'EnhancedSecurity: RDP block rules disabled.' -Level INFO -Component 'EnhancedSecurity' } catch {}
                    if (Get-Command 'Set-SrdpIniValue' -ErrorAction SilentlyContinue) {
                        Set-SrdpIniValue -Path $capturedConfigFile -Section 'EnhancedSecurity' -Key 'RdpBlockEnabled' -Value 'false'
                    }
                } else {
                    Enable-NetFirewallRule -Name 'SecureRDP-RDP-BlockDirect'     -ErrorAction Stop
                    Enable-NetFirewallRule -Name 'SecureRDP-RDP-BlockDirect-UDP' -ErrorAction Stop
                    try { Write-SrdpLog 'EnhancedSecurity: RDP block rules enabled.' -Level INFO -Component 'EnhancedSecurity' } catch {}
                    if (Get-Command 'Set-SrdpIniValue' -ErrorAction SilentlyContinue) {
                        Set-SrdpIniValue -Path $capturedConfigFile -Section 'EnhancedSecurity' -Key 'RdpBlockEnabled' -Value 'true'
                    }
                }
                $script:ESResult = 'refresh'; $f.Close()
            } catch {
                $errMsg = $_.Exception.Message
                try { Write-SrdpLog "EnhancedSecurity: RDP block toggle failed: $errMsg" -Level ERROR -Component 'EnhancedSecurity' } catch {}
                [System.Windows.Forms.MessageBox]::Show("Could not toggle RDP block rules.`n`n$errMsg",
                    'SecureRDP', [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            }
        }.GetNewClosure())
    }

    $y += 8

    # =========================================================================
    # SECTION 2: Adapter / Loopback Restriction
    # =========================================================================
    $y = Add-Sect -Panel $pnl -Text 'RDP Listener Restriction' -Top $y -Width $cW

    $loopStatusText  = if ($loopEnabled) { 'Applied -- RDP listener restricted to loopback adapter' } else { 'Not applied' }
    $loopStatusColor = if ($loopEnabled) { $CLR_OK } else { $CLR_GREY }
    $y = Add-StatusRow -Panel $pnl -Label 'Status:' -Value $loopStatusText -VColor $loopStatusColor -Top $y -Width $cW
    $y += 6

    $descLbl2           = New-Object System.Windows.Forms.Label
    $descLbl2.Text      = 'When applied, the RDP listener is bound to the loopback adapter only. This means RDP is only reachable via an SSH tunnel -- even if the firewall rules are disabled. Applying or removing this restriction restarts the Remote Desktop service momentarily.'
    $descLbl2.Font      = $FONT_BODY
    $descLbl2.ForeColor = $CLR_GREY
    $descLbl2.Left      = 0; $descLbl2.Top = $y
    $descLbl2.Width     = $cW; $descLbl2.Height = 70
    $descLbl2.MaximumSize = New-Object System.Drawing.Size($cW, 200)
    $descLbl2.AutoSize  = $true
    $pnl.Controls.Add($descLbl2)
    $y += 74

    if ($isDirectRdp -and -not $loopEnabled) {
        # Hard block: direct RDP session, applying would lock user out
        $y = Add-BlockedBtn -Panel $pnl -Text 'Apply Loopback Restriction' `
            -Tooltip 'You are connected directly via RDP. Applying this restriction would prevent your current connection type. Use a local or SSH tunnel session to apply.' `
            -Top $y -Width 280
        $noteLoop           = New-Object System.Windows.Forms.Label
        $noteLoop.Text      = 'Cannot apply from a direct RDP session -- this would block your current connection. Log in locally or via SSH tunnel to apply.'
        $noteLoop.Font      = $FONT_BODY
        $noteLoop.ForeColor = $CLR_ERR
        $noteLoop.Left      = 0; $noteLoop.Top = $y
        $noteLoop.Width     = $cW; $noteLoop.Height = 26
        $noteLoop.MaximumSize = New-Object System.Drawing.Size($cW, 200)
        $noteLoop.AutoSize  = $true
        $pnl.Controls.Add($noteLoop)
        $y += 36
    } else {
        $toggleLoopText  = if ($loopEnabled) { 'Remove Loopback Restriction' } else { 'Apply Loopback Restriction' }
        $toggleLoopColor = if ($loopEnabled) { $CLR_AMBER } else { $CLR_BLUE }
        $bLoopToggle             = New-Object System.Windows.Forms.Button
        $bLoopToggle.Text        = $toggleLoopText
        $bLoopToggle.Left        = 0; $bLoopToggle.Top = $y; $bLoopToggle.Width = 280; $bLoopToggle.Height = 30
        $bLoopToggle.FlatStyle   = 'Flat'; $bLoopToggle.Font = $FONT_BTN
        $bLoopToggle.BackColor   = $toggleLoopColor; $bLoopToggle.ForeColor = $CLR_WHITE
        $bLoopToggle.FlatAppearance.BorderSize = 0; $bLoopToggle.Cursor = 'Hand'
        $pnl.Controls.Add($bLoopToggle)
        $y += 36

        $capturedLoopEnabled          = $loopEnabled
        $capturedSavedOriginalAdapter = $savedOriginalLanAdapter
        $capturedConfigFile2          = $ConfigFile
        $bLoopToggle.Add_Click({
            try {
                if ($capturedLoopEnabled) {
                    # Remove restriction -- restore original LanAdapter value
                    $r = Remove-SrdpLoopbackRestriction -OriginalLanAdapter $capturedSavedOriginalAdapter
                    if ($r -is [string] -and $r -like 'error:*') {
                        try { Write-SrdpLog "EnhancedSecurity: Remove-SrdpLoopbackRestriction failed: $r" -Level ERROR -Component 'EnhancedSecurity' } catch {}
                        [System.Windows.Forms.MessageBox]::Show("Could not remove loopback restriction.`n`n$r",
                            'SecureRDP', [System.Windows.Forms.MessageBoxButtons]::OK,
                            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                        return
                    }
                    try { Write-SrdpLog 'EnhancedSecurity: loopback restriction removed.' -Level INFO -Component 'EnhancedSecurity' } catch {}
                    if (Get-Command 'Set-SrdpIniValue' -ErrorAction SilentlyContinue) {
                        Set-SrdpIniValue -Path $capturedConfigFile2 -Section 'EnhancedSecurity' -Key 'LoopbackRestrictionEnabled' -Value 'false'
                    }
                } else {
                    # Apply restriction
                    $r = Set-SrdpLoopbackRestriction
                    if ($r -is [string] -and $r -like 'error:*') {
                        try { Write-SrdpLog "EnhancedSecurity: Set-SrdpLoopbackRestriction failed: $r" -Level ERROR -Component 'EnhancedSecurity' } catch {}
                        [System.Windows.Forms.MessageBox]::Show("Could not apply loopback restriction.`n`n$r",
                            'SecureRDP', [System.Windows.Forms.MessageBoxButtons]::OK,
                            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                        return
                    }
                    try { Write-SrdpLog 'EnhancedSecurity: loopback restriction applied.' -Level INFO -Component 'EnhancedSecurity' } catch {}
                    # Save OriginalLanAdapter for future removal
                    if (Get-Command 'Set-SrdpIniValue' -ErrorAction SilentlyContinue) {
                        $origVal = if ($null -ne $r.OriginalLanAdapter) { [string]$r.OriginalLanAdapter } else { '0' }
                        Set-SrdpIniValue -Path $capturedConfigFile2 -Section 'EnhancedSecurity' -Key 'OriginalLanAdapter' -Value $origVal
                        Set-SrdpIniValue -Path $capturedConfigFile2 -Section 'EnhancedSecurity' -Key 'LoopbackRestrictionEnabled' -Value 'true'
                    }
                }
                $script:ESResult = 'refresh'; $f.Close()
            } catch {
                $errMsg = $_.Exception.Message
                try { Write-SrdpLog "EnhancedSecurity: loopback toggle failed: $errMsg" -Level ERROR -Component 'EnhancedSecurity' } catch {}
                [System.Windows.Forms.MessageBox]::Show("Could not toggle loopback restriction.`n`n$errMsg",
                    'SecureRDP', [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            }
        }.GetNewClosure())
    }

    $y += 8

    # =========================================================================
    # SECTION 3: Overall Status
    # =========================================================================
    $y = Add-Sect -Panel $pnl -Text 'Overall Status' -Top $y -Width $cW

    $overallText  = if ($rdpBlockEnabled -and $loopEnabled) { 'Full -- all restrictions active' } `
                    elseif ($rdpBlockEnabled -or $loopEnabled) { 'Partial -- some restrictions not yet applied' } `
                    else { 'None -- direct RDP is accessible' }
    $overallColor = if ($rdpBlockEnabled -and $loopEnabled) { $CLR_OK } `
                    elseif ($rdpBlockEnabled -or $loopEnabled) { $CLR_WARN } `
                    else { $CLR_ERR }
    $y = Add-StatusRow -Panel $pnl -Label 'Status:' -Value $overallText -VColor $overallColor -Top $y -Width $cW

    # ---- Wire buttons ----
    $script:ESResult = 'close'

    $bRefresh.Add_Click({ $script:ESResult = 'refresh'; $f.Close() })
    $bClose.Add_Click({ $script:ESResult = 'close'; $f.Close() })
    $f.CancelButton = $bClose

    try { Write-SrdpLog 'EnhancedSecurity: form ready.' -Level INFO -Component 'EnhancedSecurity' } catch {}
    $f.ShowDialog() | Out-Null
    return $script:ESResult
}

# ---------------------------------------------------------------------------
# MAIN -- refresh loop
# ---------------------------------------------------------------------------
$loop = $true
while ($loop) {
    $result = Show-ESScreen
    if ($result -ne 'refresh') { $loop = $false }
}
exit 0
