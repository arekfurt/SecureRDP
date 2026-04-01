#Requires -Version 5.1
# =============================================================================
# SecureRDP -- SSH Prototype Mode
# Modes\SSHProto\QuickStart\Manage-SSHProto.ps1
#
# Management screen for SSH Prototype mode.
# Launched from the mode tile Manage button in ServerWizard.ps1.
# Must be run as Administrator.
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# WinForms -- loaded before module imports so error dialogs are available
# ---------------------------------------------------------------------------
[System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName('System.Drawing')       | Out-Null
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------------------
# Admin check
# ---------------------------------------------------------------------------
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    [System.Windows.Forms.MessageBox]::Show(
        'Manage must be run as Administrator.',
        'SecureRDP - Manage',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    exit 1
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$ScriptDir         = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ModeDir           = Split-Path -Parent $ScriptDir
$SrdpRoot          = Split-Path -Parent (Split-Path -Parent $ModeDir)
$InstDir           = Join-Path $SrdpRoot 'InstalledModes\SSHProto'
$StateFile         = Join-Path $InstDir  'state.json'
$QsScript          = Join-Path $SrdpRoot 'QuickStart-Phase2.ps1'
$RevertScript      = Join-Path $ScriptDir 'Revert_Phase1a.ps1'
$ClientKeyWizard   = Join-Path $SrdpRoot 'ClientKeyWizard.ps1'
$EsScript          = Join-Path $SrdpRoot 'EnhancedSecurity.ps1'

# Read version from mode.ini
$SRDP_VER = '0.85'
try {
    $modeIni = Join-Path $ModeDir 'mode.ini'
    if (Test-Path $modeIni) {
        $iniContent = Get-Content $modeIni -Raw -ErrorAction SilentlyContinue
        if ($iniContent -match 'Version\s*=\s*(.+)') { $SRDP_VER = $Matches[1].Trim() }
    }
} catch {}

# ---------------------------------------------------------------------------
# Load modules
# ---------------------------------------------------------------------------
$LogModule      = Join-Path $SrdpRoot 'SupportingModules\SrdpLog.psm1'
$CoreModule     = Join-Path $ModeDir  'SSHProtoCore.psm1'
$InitModule     = Join-Path $SrdpRoot 'SupportingModules\InitialChecks.psm1'

if (-not (Test-Path $LogModule)) {
    [System.Windows.Forms.MessageBox]::Show("SrdpLog.psm1 not found at:`n$LogModule",
        'SecureRDP - Manage', [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null; exit 1
}
Import-Module $LogModule -Force -DisableNameChecking -ErrorAction Stop
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $CoreModule)) {
    [System.Windows.Forms.MessageBox]::Show("SSHProtoCore.psm1 not found at:`n$CoreModule",
        'SecureRDP - Manage', [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null; exit 1
}
Import-Module $CoreModule -Force -DisableNameChecking -ErrorAction Stop
$ErrorActionPreference = 'Stop'

if (Test-Path $InitModule) {
    Import-Module $InitModule -Force -DisableNameChecking -ErrorAction SilentlyContinue
    $ErrorActionPreference = 'Stop'
}

try { Write-SrdpLog 'Manage-SSHProto starting.' -Level INFO -Component 'Manage' } catch {}

# ---------------------------------------------------------------------------
# UI CONSTANTS
# ---------------------------------------------------------------------------
$FW           = 760
$FONT_HEADING = New-Object System.Drawing.Font('Times New Roman', 14, [System.Drawing.FontStyle]::Bold)
$FONT_BODY    = New-Object System.Drawing.Font('Times New Roman', 12, [System.Drawing.FontStyle]::Bold)
$FONT_MONO    = New-Object System.Drawing.Font('Consolas', 10)
$FONT_BTN     = New-Object System.Drawing.Font('Times New Roman', 12, [System.Drawing.FontStyle]::Bold)
$FONT_ROW_BTN = New-Object System.Drawing.Font('Times New Roman', 11, [System.Drawing.FontStyle]::Bold)
$CLR_HDR      = [System.Drawing.Color]::FromArgb(0,   60, 120)
$CLR_OK       = [System.Drawing.Color]::FromArgb(10, 110,  10)
$CLR_WARN     = [System.Drawing.Color]::FromArgb(180, 80,  10)
$CLR_ERR      = [System.Drawing.Color]::FromArgb(170, 20,  10)
$CLR_BLUE     = [System.Drawing.Color]::FromArgb(0,   84, 166)
$CLR_AMBER    = [System.Drawing.Color]::FromArgb(200, 120,   0)
$CLR_GREY     = [System.Drawing.Color]::FromArgb(100, 100, 100)
$CLR_BG       = [System.Drawing.Color]::FromArgb(245, 245, 245)
$CLR_WHITE    = [System.Drawing.Color]::White
$CLR_SILVR    = [System.Drawing.Color]::Silver

$script:NoteControls       = @{}
$script:RevokeConfirmResult = $false
$script:ManageResult        = 'close'

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
    $sep         = New-Object System.Windows.Forms.Panel
    $sep.Left    = 0; $sep.Top = $Top + 26
    $sep.Width   = $Width; $sep.Height = 1
    $sep.BackColor = $CLR_HDR
    $Panel.Controls.Add($sep)
    return $Top + 34
}

# ---------------------------------------------------------------------------
# HELPER: Add-InfoRow
# ---------------------------------------------------------------------------
function Add-InfoRow {
    param(
        [System.Windows.Forms.Panel]$Panel,
        [string]$Label,
        [string]$Value,
        [System.Drawing.Color]$VColor,
        [int]$Top
    )
    $ll           = New-Object System.Windows.Forms.Label
    $ll.Text      = $Label
    $ll.Font      = $FONT_BODY
    $ll.ForeColor = $CLR_GREY
    $ll.Left      = 0; $ll.Top = $Top; $ll.Width = 200; $ll.Height = 22; $ll.AutoSize = $false
    $Panel.Controls.Add($ll)
    $vl           = New-Object System.Windows.Forms.Label
    $vl.Text      = $Value
    $vl.Font      = $FONT_BODY
    $vl.ForeColor = $VColor
    $vl.Left      = 204; $vl.Top = $Top; $vl.AutoSize = $true
    $Panel.Controls.Add($vl)
    return $Top + 26
}

# ---------------------------------------------------------------------------
# HELPER: Save-Notes
# Persists note text back to ClientKeys entries in state.json.
# ---------------------------------------------------------------------------
function Save-Notes {
    if ($script:NoteControls.Count -eq 0) { return }
    try {
        $currentState = Read-SrdpState -StateFile $StateFile
        if ($null -eq $currentState -or $currentState -is [string]) { return }
        $stProps = $currentState.PSObject.Properties.Name
        if ($stProps -notcontains 'ClientKeys') { return }
        if ($null -eq $currentState.ClientKeys) { return }
        $changed = $false
        foreach ($k in @($currentState.ClientKeys)) {
            if ($null -eq $k) { continue }
            $kProps = $k.PSObject.Properties.Name
            $kLabel = if ($kProps -contains 'label') { $k.label } else { '' }
            if ($kLabel.Length -eq 0) { continue }
            if (-not $script:NoteControls.ContainsKey($kLabel)) { continue }
            $newNote = $script:NoteControls[$kLabel].Text
            $oldNote = if ($kProps -contains 'notes') { $k.notes } else { '' }
            if ($oldNote -ne $newNote) {
                $k | Add-Member -NotePropertyName 'notes' -NotePropertyValue $newNote -Force
                $changed = $true
            }
        }
        if ($changed) {
            Write-SrdpState -StateFile $StateFile -State $currentState | Out-Null
            try { Write-SrdpLog 'Manage: notes saved to state.' -Level INFO -Component 'Manage' } catch {}
        }
    } catch {
        $errMsg = $_.Exception.Message
        try { Write-SrdpLog "Manage: Save-Notes failed: $errMsg" -Level WARN -Component 'Manage' } catch {}
    }
}

# ---------------------------------------------------------------------------
# HELPER: Get-ClientKeyMeta
# Returns hashtable of label->metadata from ClientKeys in state.json.
# ---------------------------------------------------------------------------
function Get-ClientKeyMeta {
    $meta = @{}
    try {
        $state = Read-SrdpState -StateFile $StateFile
        if ($null -eq $state -or $state -is [string]) { return $meta }
        $stProps = $state.PSObject.Properties.Name
        if ($stProps -notcontains 'ClientKeys') { return $meta }
        foreach ($k in @($state.ClientKeys)) {
            if ($null -eq $k) { continue }
            $kProps = $k.PSObject.Properties.Name
            $lbl = if ($kProps -contains 'label') { $k.label } else { '' }
            if ($lbl.Length -gt 0) { $meta[$lbl] = $k }
        }
    } catch {}
    return $meta
}

# ---------------------------------------------------------------------------
# HELPER: Mark-KeyDeauthorized
# Updates the ClientKeys entry in state.json with deauthorization info.
# Keeps the entry for audit purposes; does not remove it.
# ---------------------------------------------------------------------------
function Mark-KeyDeauthorized {
    param([string]$Label)
    try {
        $currentState = Read-SrdpState -StateFile $StateFile
        if ($null -eq $currentState -or $currentState -is [string]) { return }
        $stProps = $currentState.PSObject.Properties.Name
        if ($stProps -notcontains 'ClientKeys') { return }
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $whoami = "$($env:COMPUTERNAME)\$($env:USERNAME)"
        foreach ($k in @($currentState.ClientKeys)) {
            if ($null -eq $k) { continue }
            $kProps = $k.PSObject.Properties.Name
            $kLabel = if ($kProps -contains 'label') { $k.label } else { '' }
            if ($kLabel -eq $Label) {
                $k | Add-Member -NotePropertyName 'deauthorized' -NotePropertyValue "$stamp by $whoami" -Force
                break
            }
        }
        Write-SrdpState -StateFile $StateFile -State $currentState | Out-Null
        try { Write-SrdpLog "Manage: key '$Label' marked deauthorized in state.json." -Level INFO -Component 'Manage' } catch {}
    } catch {
        $errMsg = $_.Exception.Message
        try { Write-SrdpLog "Manage: Mark-KeyDeauthorized failed: $errMsg" -Level WARN -Component 'Manage' } catch {}
    }
}

# ---------------------------------------------------------------------------
# Show-RevokeConfirm
# ---------------------------------------------------------------------------
function Show-RevokeConfirm {
    param([string]$Label, [string]$Notes)

    $pf                 = New-Object System.Windows.Forms.Form
    $pf.Text            = 'Deauthorize Client Key'
    $pf.Width           = 460
    $pf.Height          = 290
    $pf.FormBorderStyle = 'FixedDialog'
    $pf.MaximizeBox     = $false
    $pf.MinimizeBox     = $false
    $pf.StartPosition   = 'CenterScreen'
    $pf.BackColor       = $CLR_BG

    $hdr           = New-Object System.Windows.Forms.Panel
    $hdr.Dock      = 'Top'; $hdr.Height = 34
    $hdr.BackColor = [System.Drawing.Color]::FromArgb(140, 20, 10)
    $hl            = New-Object System.Windows.Forms.Label
    $hl.Text       = 'Deauthorize Client Key -- Are you sure?'
    $hl.Font       = $FONT_BODY
    $hl.ForeColor  = $CLR_WHITE
    $hl.Dock       = 'Fill'
    $hl.TextAlign  = 'MiddleLeft'
    $hl.Padding    = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
    $hdr.Controls.Add($hl); $pf.Controls.Add($hdr)

    $bb           = New-Object System.Windows.Forms.Panel
    $bb.Dock      = 'Bottom'; $bb.Height = 50
    $bb.BackColor = [System.Drawing.Color]::FromArgb(232, 232, 232)
    $sep          = New-Object System.Windows.Forms.Panel
    $sep.Dock     = 'Top'; $sep.Height = 1; $sep.BackColor = $CLR_SILVR
    $bb.Controls.Add($sep); $pf.Controls.Add($bb)

    $pnl         = New-Object System.Windows.Forms.Panel
    $pnl.Padding = New-Object System.Windows.Forms.Padding(14, 10, 14, 10)
    $pnl.Dock    = 'Fill'
    $pf.Controls.Add($pnl)

    $y = 0
    $kl           = New-Object System.Windows.Forms.Label
    $kl.Text      = "Key: $Label"
    $kl.Font      = $FONT_BODY
    $kl.ForeColor = $CLR_ERR
    $kl.Left      = 0; $kl.Top = $y; $kl.AutoSize = $true
    $pnl.Controls.Add($kl); $y += 28

    if ($Notes -and $Notes.Trim().Length -gt 0) {
        $nl           = New-Object System.Windows.Forms.Label
        $nl.Text      = "Note: $Notes"
        $nl.Font      = $FONT_BODY
        $nl.ForeColor = $CLR_GREY
        $nl.Left      = 0; $nl.Top = $y; $nl.AutoSize = $true
        $pnl.Controls.Add($nl); $y += 26
    }

    $wl           = New-Object System.Windows.Forms.Label
    $wl.Text      = "This key will be removed from authorized_keys immediately.`nAny active SSH tunnel using this key will be disconnected.`nThe package file on disk is not deleted.`nThe key record is retained for audit purposes."
    $wl.Font      = $FONT_BODY
    $wl.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $wl.Left      = 0; $wl.Top = $y + 4
    $wl.Width     = 420; $wl.Height = 90
    $wl.MaximumSize = New-Object System.Drawing.Size(420, 200)
    $pnl.Controls.Add($wl)

    $script:RevokeConfirmResult = $false

    $bCancel              = New-Object System.Windows.Forms.Button
    $bCancel.Text         = 'Cancel'
    $bCancel.Width        = 100; $bCancel.Height = 30; $bCancel.Top = 10
    $bCancel.Left         = 460 - 18 - 140 - 8 - 100
    $bCancel.FlatStyle    = 'Flat'
    $bCancel.Font         = $FONT_BTN
    $bCancel.BackColor    = $CLR_WHITE
    $bCancel.FlatAppearance.BorderColor = $CLR_SILVR
    $bb.Controls.Add($bCancel)

    $bDeauth              = New-Object System.Windows.Forms.Button
    $bDeauth.Text         = 'Deauthorize'
    $bDeauth.Width        = 140; $bDeauth.Height = 30; $bDeauth.Top = 10
    $bDeauth.Left         = 460 - 18 - 140
    $bDeauth.FlatStyle    = 'Flat'
    $bDeauth.Font         = $FONT_BTN
    $bDeauth.BackColor    = [System.Drawing.Color]::FromArgb(170, 20, 10)
    $bDeauth.ForeColor    = $CLR_WHITE
    $bDeauth.FlatAppearance.BorderSize = 0
    $bb.Controls.Add($bDeauth)

    $bCancel.Add_Click({ $script:RevokeConfirmResult = $false; $pf.Close() })
    $bDeauth.Add_Click({ $script:RevokeConfirmResult = $true;  $pf.Close() })
    $pf.CancelButton = $bCancel
    $pf.AcceptButton = $bDeauth
    $pf.ShowDialog() | Out-Null
    return $script:RevokeConfirmResult
}

# ---------------------------------------------------------------------------
# SHOW-MANAGESCREEN
# ---------------------------------------------------------------------------
function Show-ManageScreen {

    # ---- Read state and live status ----
    $state         = $null
    $sshPort       = 22
    $setupComplete = $false
    $loopEnabled   = $false

    try {
        $state = Read-SrdpState -StateFile $StateFile
    } catch {
        $errMsg = $_.Exception.Message
        try { Write-SrdpLog "Manage: Read-SrdpState failed: $errMsg" -Level WARN -Component 'Manage' } catch {}
    }

    if ($null -ne $state -and $state -isnot [string]) {
        $stProps = $state.PSObject.Properties.Name
        if ($stProps -contains 'Phase2' -and $null -ne $state.Phase2) {
            $p2Props = $state.Phase2.PSObject.Properties.Name
            if ($p2Props -contains 'Success') { $setupComplete = ($state.Phase2.Success -eq $true) }
            if ($p2Props -contains 'LoopbackRestrictionApplied') { $loopEnabled = ($state.Phase2.LoopbackRestrictionApplied -eq $true) }
            if ($p2Props -contains 'SshPort' -and $null -ne $state.Phase2.SshPort) { $sshPort = [int]$state.Phase2.SshPort }
        }
        if ($sshPort -eq 22 -and $stProps -contains 'SshPort' -and $null -ne $state.SshPort) { $sshPort = [int]$state.SshPort }
        if ($sshPort -eq 22 -and $stProps -contains 'Infrastructure' -and $null -ne $state.Infrastructure) {
            $infProps = $state.Infrastructure.PSObject.Properties.Name
            if ($infProps -contains 'SshPort' -and $null -ne $state.Infrastructure.SshPort) { $sshPort = [int]$state.Infrastructure.SshPort }
        }
    }

    # Live service status
    $svcStatus  = 'Unknown'; $svcRunning = $false
    try {
        $svc = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
        if ($null -ne $svc) { $svcStatus = $svc.Status.ToString(); $svcRunning = ($svc.Status -eq 'Running') }
        else { $svcStatus = 'Not installed' }
    } catch { $errMsg = $_.Exception.Message; try { Write-SrdpLog "Manage: sshd check failed: $errMsg" -Level WARN -Component 'Manage' } catch {} }

    # Live SSH firewall rule
    $sshRule        = $null
    $sshRuleExists  = $false
    $sshRuleEnabled = $false
    try {
        $sshRule        = Get-NetFirewallRule -Name 'SecureRDP-SSH-Inbound' -ErrorAction SilentlyContinue
        $sshRuleExists  = ($null -ne $sshRule)
        $sshRuleEnabled = ($sshRuleExists -and $sshRule.Enabled -eq 'True')
    } catch { $errMsg = $_.Exception.Message; try { Write-SrdpLog "Manage: SSH rule check failed: $errMsg" -Level WARN -Component 'Manage' } catch {} }

    # Live RDP block rules
    $rdpBlockEnabled = $false
    try {
        $blockRule       = Get-NetFirewallRule -Name 'SecureRDP-RDP-BlockDirect' -ErrorAction SilentlyContinue
        $rdpBlockEnabled = ($null -ne $blockRule -and $blockRule.Enabled -eq 'True')
    } catch { $errMsg = $_.Exception.Message; try { Write-SrdpLog "Manage: RDP block check failed: $errMsg" -Level WARN -Component 'Manage' } catch {} }

    # Session type (for SSH rule disable guard)
    $sessionType = 'unknown'
    try {
        if (Get-Command 'Get-SessionType' -ErrorAction SilentlyContinue) {
            $sessionType = Get-SessionType
        }
    } catch {}

    # ES status
    $esStatus = if ($rdpBlockEnabled -and $loopEnabled) { 'Full' } elseif ($rdpBlockEnabled -or $loopEnabled) { 'Partial' } else { 'None' }

    # Live keys from authorized_keys file
    $liveKeys  = @()
    $keyResult = Get-SrdpAuthorizedKeys
    if ($keyResult -isnot [string] -and $keyResult.Result -eq 'ok') {
        $liveKeys = @($keyResult.Keys | Where-Object {
            # Only show keys that are not deauthorized -- deauthorized ones stay in state.json for audit
            # but are already removed from the physical authorized_keys file
            $null -ne $_
        })
    } else {
        try { Write-SrdpLog "Manage: Get-SrdpAuthorizedKeys failed or returned error." -Level WARN -Component 'Manage' } catch {}
    }

    # Key metadata from state.json ClientKeys
    $clientKeyMeta = Get-ClientKeyMeta

    # ---- Build form ----
    $f                 = New-Object System.Windows.Forms.Form
    $f.Text            = "SecureRDP v$SRDP_VER - Manage SSH Prototype Mode"
    $f.Width           = $FW + 18
    $f.Height          = 800
    $f.FormBorderStyle = 'FixedSingle'
    $f.MaximizeBox     = $false
    $f.StartPosition   = 'CenterScreen'
    $f.BackColor       = $CLR_BG

    # Header bar
    $hdr           = New-Object System.Windows.Forms.Panel
    $hdr.Dock      = 'Top'; $hdr.Height = 60
    $hdr.BackColor = $CLR_HDR
    $hl            = New-Object System.Windows.Forms.Label
    $hl.Text       = 'Manage -- SSH Prototype Mode'
    $hl.Font       = New-Object System.Drawing.Font('Times New Roman', 16, [System.Drawing.FontStyle]::Bold)
    $hl.ForeColor  = $CLR_WHITE
    $hl.Dock       = 'Fill'
    $hl.TextAlign  = 'MiddleLeft'
    $hl.Padding    = New-Object System.Windows.Forms.Padding(14, 0, 0, 0)
    $hdr.Controls.Add($hl); $f.Controls.Add($hdr)

    # Bottom button bar
    $bb           = New-Object System.Windows.Forms.Panel
    $bb.Dock      = 'Bottom'; $bb.Height = 58
    $bb.BackColor = [System.Drawing.Color]::FromArgb(232, 232, 232)
    $bbs          = New-Object System.Windows.Forms.Panel
    $bbs.Dock     = 'Top'; $bbs.Height = 1; $bbs.BackColor = $CLR_SILVR
    $bb.Controls.Add($bbs); $f.Controls.Add($bb)

    $bUninstall             = New-Object System.Windows.Forms.Button
    $bUninstall.Text        = 'Uninstall / Revert...'
    $bUninstall.Width       = 180; $bUninstall.Height = 34; $bUninstall.Top = 12
    $bUninstall.Left        = 12
    $bUninstall.FlatStyle   = 'Flat'
    $bUninstall.Font        = $FONT_BTN
    $bUninstall.BackColor   = [System.Drawing.Color]::FromArgb(170, 20, 10)
    $bUninstall.ForeColor   = $CLR_WHITE
    $bUninstall.FlatAppearance.BorderSize = 0
    $bUninstall.Cursor      = 'Hand'
    $bb.Controls.Add($bUninstall)

    $bClose             = New-Object System.Windows.Forms.Button
    $bClose.Text        = 'Close'
    $bClose.Width       = 100; $bClose.Height = 34; $bClose.Top = 12
    $bClose.Left        = $FW - 100
    $bClose.FlatStyle   = 'Flat'
    $bClose.Font        = $FONT_BTN
    $bClose.BackColor   = $CLR_WHITE
    $bClose.FlatAppearance.BorderColor = $CLR_SILVR
    $bb.Controls.Add($bClose)

    # Scroll panel
    $pnl            = New-Object System.Windows.Forms.Panel
    $pnl.AutoScroll = $true
    $pnl.Dock       = 'Fill'
    $pnl.Padding    = New-Object System.Windows.Forms.Padding(20, 14, 20, 8)
    $f.Controls.Add($pnl)
    $cW = $FW - 40

    $y = 0

    # Refresh button
    $bRefresh           = New-Object System.Windows.Forms.Button
    $bRefresh.Text      = 'Refresh'
    $bRefresh.Width     = 100; $bRefresh.Height = 28
    $bRefresh.Left      = $cW - 100; $bRefresh.Top = $y
    $bRefresh.FlatStyle = 'Flat'
    $bRefresh.Font      = $FONT_BTN
    $bRefresh.BackColor = $CLR_WHITE
    $bRefresh.FlatAppearance.BorderColor = $CLR_SILVR
    $bRefresh.Cursor    = 'Hand'
    $pnl.Controls.Add($bRefresh)
    $y += 40

    # ==========================================================================
    # SERVICE SECTION
    # ==========================================================================
    $y = Add-Sect -Panel $pnl -Text 'SSH Service' -Top $y -Width $cW

    $svcColor = if ($svcRunning) { $CLR_OK } elseif ($svcStatus -eq 'Not installed') { $CLR_GREY } else { $CLR_ERR }
    $y = Add-InfoRow -Panel $pnl -Label 'sshd service:' -Value $svcStatus -VColor $svcColor -Top $y

    $bStop            = New-Object System.Windows.Forms.Button
    $bStop.Text       = 'Stop'
    $bStop.Left       = 204; $bStop.Top = $y; $bStop.Width = 80; $bStop.Height = 28
    $bStop.FlatStyle  = 'Flat'; $bStop.Font = $FONT_BTN
    $bStop.BackColor  = $CLR_WHITE
    $bStop.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(170, 170, 170)
    $bStop.Enabled    = $svcRunning; $bStop.Cursor = 'Hand'
    $pnl.Controls.Add($bStop)

    $bStart           = New-Object System.Windows.Forms.Button
    $bStart.Text      = 'Start'
    $bStart.Left      = 292; $bStart.Top = $y; $bStart.Width = 80; $bStart.Height = 28
    $bStart.FlatStyle = 'Flat'; $bStart.Font = $FONT_BTN
    $bStart.BackColor = $CLR_WHITE
    $bStart.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(170, 170, 170)
    $bStart.Enabled   = (-not $svcRunning -and $svcStatus -ne 'Not installed'); $bStart.Cursor = 'Hand'
    $pnl.Controls.Add($bStart)
    $y += 34

    # SSH firewall rule row
    $sshRuleColor = if ($sshRuleEnabled) { $CLR_OK } elseif ($sshRuleExists) { $CLR_WARN } else { $CLR_GREY }
    $sshRuleText  = if ($sshRuleEnabled) { 'Enabled' } elseif ($sshRuleExists) { 'Disabled' } else { 'Not created' }
    $y = Add-InfoRow -Panel $pnl -Label "SSH port $sshPort inbound:" -Value $sshRuleText -VColor $sshRuleColor -Top $y

    # SSH rule toggle button -- hard blocked when on SSH tunnel
    $isTunnelSession = ($sessionType -eq 'rdp-tunnel')
    if (-not $sshRuleExists) {
        # Rule doesn't exist yet -- show disabled button
        $bSshToggle         = New-Object System.Windows.Forms.Button
        $bSshToggle.Text    = 'Rule not yet created'
        $bSshToggle.Left    = 204; $bSshToggle.Top = $y; $bSshToggle.Width = 200; $bSshToggle.Height = 28
        $bSshToggle.FlatStyle = 'Flat'; $bSshToggle.Font = $FONT_BTN
        $bSshToggle.BackColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
        $bSshToggle.ForeColor = $CLR_GREY
        $bSshToggle.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
        $bSshToggle.Enabled = $false
        $pnl.Controls.Add($bSshToggle)
        $y += 34
    } elseif ($sshRuleEnabled -and $isTunnelSession) {
        # Connected via tunnel -- hard block on disable
        $bSshToggle         = New-Object System.Windows.Forms.Button
        $bSshToggle.Text    = 'Cannot disable -- active tunnel session'
        $bSshToggle.Left    = 204; $bSshToggle.Top = $y; $bSshToggle.Width = 300; $bSshToggle.Height = 28
        $bSshToggle.FlatStyle = 'Flat'; $bSshToggle.Font = $FONT_BTN
        $bSshToggle.BackColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
        $bSshToggle.ForeColor = $CLR_GREY
        $bSshToggle.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
        $bSshToggle.Enabled = $false
        $ttSsh = New-Object System.Windows.Forms.ToolTip
        $ttSsh.SetToolTip($bSshToggle, 'You are connected via the SSH tunnel. Disabling this rule would disconnect your session. Use a direct session to disable.')
        $bSshToggle.Tag = $ttSsh
        $pnl.Controls.Add($bSshToggle)
        $y += 34
    } else {
        # Normal toggle
        $toggleText  = if ($sshRuleEnabled) { 'Disable SSH Inbound Rule' } else { 'Enable SSH Inbound Rule' }
        $toggleColor = if ($sshRuleEnabled) { $CLR_AMBER } else { $CLR_BLUE }
        $bSshToggle         = New-Object System.Windows.Forms.Button
        $bSshToggle.Text    = $toggleText
        $bSshToggle.Left    = 204; $bSshToggle.Top = $y; $bSshToggle.Width = 240; $bSshToggle.Height = 28
        $bSshToggle.FlatStyle = 'Flat'; $bSshToggle.Font = $FONT_BTN
        $bSshToggle.BackColor = $toggleColor
        $bSshToggle.ForeColor = $CLR_WHITE
        $bSshToggle.FlatAppearance.BorderSize = 0
        $bSshToggle.Cursor  = 'Hand'
        $pnl.Controls.Add($bSshToggle)
        $y += 34

        $capturedRuleEnabled = $sshRuleEnabled
        $bSshToggle.Add_Click({
            try {
                if ($capturedRuleEnabled) {
                    Disable-NetFirewallRule -Name 'SecureRDP-SSH-Inbound' -ErrorAction Stop
                    try { Write-SrdpLog 'Manage: SSH inbound rule disabled.' -Level INFO -Component 'Manage' } catch {}
                } else {
                    Enable-NetFirewallRule -Name 'SecureRDP-SSH-Inbound' -ErrorAction Stop
                    try { Write-SrdpLog 'Manage: SSH inbound rule enabled.' -Level INFO -Component 'Manage' } catch {}
                }
                $script:ManageResult = 'refresh'; $f.Close()
            } catch {
                $errMsg = $_.Exception.Message
                try { Write-SrdpLog "Manage: SSH rule toggle failed: $errMsg" -Level ERROR -Component 'Manage' } catch {}
                [System.Windows.Forms.MessageBox]::Show("Could not toggle SSH firewall rule.`n`n$errMsg",
                    'SecureRDP', [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            }
        }.GetNewClosure())
    }

    $y += 4

    # ==========================================================================
    # ENHANCED SECURITY SECTION
    # ==========================================================================
    $y = Add-Sect -Panel $pnl -Text 'Enhanced Security' -Top $y -Width $cW

    $esColor = if ($esStatus -eq 'Full') { $CLR_OK } elseif ($esStatus -eq 'Partial') { $CLR_WARN } else { $CLR_ERR }
    $esText  = if ($esStatus -eq 'Full') { 'Full -- RDP block and loopback restriction active' } `
               elseif ($esStatus -eq 'Partial') { 'Partial -- not all restrictions applied' } `
               else { 'None -- direct RDP is not restricted' }
    $y = Add-InfoRow -Panel $pnl -Label 'Security status:' -Value $esText -VColor $esColor -Top $y

    $rdpBlockText  = if ($rdpBlockEnabled) { 'Enabled' } else { 'Disabled / not configured' }
    $rdpBlockColor = if ($rdpBlockEnabled) { $CLR_OK } else { $CLR_WARN }
    $y = Add-InfoRow -Panel $pnl -Label 'RDP block rules:' -Value $rdpBlockText -VColor $rdpBlockColor -Top $y

    $loopText  = if ($loopEnabled) { 'Applied' } else { 'Not applied' }
    $loopColor = if ($loopEnabled) { $CLR_OK } else { $CLR_GREY }
    $y = Add-InfoRow -Panel $pnl -Label 'Adapter restriction:' -Value $loopText -VColor $loopColor -Top $y

    $esExists       = Test-Path $EsScript
    $bES            = New-Object System.Windows.Forms.Button
    $bES.Text       = 'Configure Enhanced Security...'
    $bES.Left       = 0; $bES.Top = $y; $bES.Width = 280; $bES.Height = 30
    $bES.FlatStyle  = 'Flat'; $bES.Font = $FONT_BTN
    if ($esExists) {
        $bES.BackColor = $CLR_BLUE; $bES.ForeColor = $CLR_WHITE
        $bES.FlatAppearance.BorderSize = 0; $bES.Cursor = 'Hand'
    } else {
        $bES.BackColor = [System.Drawing.Color]::FromArgb(210, 210, 210)
        $bES.ForeColor = $CLR_GREY
        $bES.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(190, 190, 190)
        $bES.Enabled = $false
        $ttES = New-Object System.Windows.Forms.ToolTip
        $ttES.SetToolTip($bES, 'Enhanced Security screen not yet available')
        $bES.Tag = $ttES
    }
    $pnl.Controls.Add($bES)
    $y += 38

    # Setup incomplete banner
    if (-not $setupComplete) {
        $bannerPnl           = New-Object System.Windows.Forms.Panel
        $bannerPnl.Left      = 0; $bannerPnl.Top = $y
        $bannerPnl.Width     = $cW; $bannerPnl.Height = 40
        $bannerPnl.BackColor = [System.Drawing.Color]::FromArgb(255, 248, 230)
        $bannerBorder        = New-Object System.Windows.Forms.Panel
        $bannerBorder.Left   = 0; $bannerBorder.Top = 0
        $bannerBorder.Width  = 4; $bannerBorder.Height = 40
        $bannerBorder.BackColor = $CLR_AMBER
        $bannerPnl.Controls.Add($bannerBorder)
        $bannerTxt           = New-Object System.Windows.Forms.Label
        $bannerTxt.Text      = 'Setup is not complete -- direct RDP access is not yet restricted.'
        $bannerTxt.Font      = $FONT_BODY
        $bannerTxt.ForeColor = [System.Drawing.Color]::FromArgb(122, 72, 0)
        $bannerTxt.Left      = 10; $bannerTxt.Top = 4
        $bannerTxt.Width     = ($cW - 160); $bannerTxt.Height = 32
        $bannerTxt.AutoSize  = $false
        $bannerPnl.Controls.Add($bannerTxt)
        $bOpenQS             = New-Object System.Windows.Forms.Button
        $bOpenQS.Text        = 'Open Quick Start...'
        $bOpenQS.Width       = 140; $bOpenQS.Height = 28; $bOpenQS.Top = 6
        $bOpenQS.Left        = $bannerPnl.Width - 148
        $bOpenQS.FlatStyle   = 'Flat'; $bOpenQS.Font = $FONT_BTN
        $bOpenQS.BackColor   = $CLR_AMBER; $bOpenQS.ForeColor = $CLR_WHITE
        $bOpenQS.FlatAppearance.BorderSize = 0; $bOpenQS.Cursor = 'Hand'
        $bannerPnl.Controls.Add($bOpenQS)
        $pnl.Controls.Add($bannerPnl)
        $y += 48

        $capturedQsScript = $QsScript
        $bOpenQS.Add_Click({
            if (Test-Path $capturedQsScript) {
                try {
                    $pi = New-Object System.Diagnostics.ProcessStartInfo
                    $pi.FileName = 'powershell.exe'
                    $pi.Arguments = "-ExecutionPolicy Bypass -STA -File `"$capturedQsScript`""
                    $pi.UseShellExecute = $false; $pi.RedirectStandardError = $true
                    [System.Diagnostics.Process]::Start($pi) | Out-Null
                    try { Write-SrdpLog 'Manage: launched QuickStart-Phase2.' -Level INFO -Component 'Manage' } catch {}
                    $script:ManageResult = 'refresh'; $f.Close()
                } catch {
                    $errMsg = $_.Exception.Message
                    [System.Windows.Forms.MessageBox]::Show("Could not launch Quick Start.`n`n$errMsg",
                        'SecureRDP', [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                }
            } else {
                [System.Windows.Forms.MessageBox]::Show("Quick Start script not found at:`n$capturedQsScript",
                    'SecureRDP', [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            }
        }.GetNewClosure())
    }

    $y += 4

    # ==========================================================================
    # AUTHORIZED CLIENT KEYS SECTION
    # ==========================================================================
    $y = Add-Sect -Panel $pnl -Text 'Authorized Client Keys' -Top $y -Width $cW

    $bAdd           = New-Object System.Windows.Forms.Button
    $bAdd.Text      = 'Create New Client Key && Package...'
    $bAdd.Left      = 0; $bAdd.Top = $y; $bAdd.Width = 300; $bAdd.Height = 30
    $bAdd.FlatStyle = 'Flat'; $bAdd.Font = $FONT_BTN
    $bAdd.BackColor = $CLR_BLUE; $bAdd.ForeColor = $CLR_WHITE
    $bAdd.FlatAppearance.BorderSize = 0; $bAdd.Cursor = 'Hand'
    $pnl.Controls.Add($bAdd)
    $y += 38

    # Column layout: Label(170) + Date(90) + Server(150) + SSHUser(140) + Notes(flex) + Deauth(130) = 680 = cW
    $colW    = @(170, 90, 150, 140, 0, 130)
    $colW[4] = $cW - ($colW[0]+$colW[1]+$colW[2]+$colW[3]+$colW[5])  # notes fills remaining
    $headers = @('Label', 'Generated', 'Server', 'SSH Username', 'Notes', '')

    $hdrPnl           = New-Object System.Windows.Forms.Panel
    $hdrPnl.Left      = 0; $hdrPnl.Top = $y
    $hdrPnl.Width     = $cW; $hdrPnl.Height = 24
    $hdrPnl.BackColor = [System.Drawing.Color]::FromArgb(210, 220, 235)
    $pnl.Controls.Add($hdrPnl)

    $hx = 0
    for ($i = 0; $i -lt $headers.Count; $i++) {
        $hlbl           = New-Object System.Windows.Forms.Label
        $hlbl.Text      = $headers[$i]
        $hlbl.Font      = $FONT_BODY
        $hlbl.ForeColor = $CLR_HDR
        $hlbl.Left      = $hx + 4; $hlbl.Top = 2; $hlbl.Width = $colW[$i]; $hlbl.Height = 20
        $hlbl.AutoSize  = $false
        $hdrPnl.Controls.Add($hlbl)
        $hx += $colW[$i]
    }
    $y += 26

    $rowColors = @([System.Drawing.Color]::White, [System.Drawing.Color]::FromArgb(245, 248, 252))

    $script:NoteControls = @{}

    if ($liveKeys.Count -eq 0) {
        $emptyLbl           = New-Object System.Windows.Forms.Label
        $emptyLbl.Text      = 'No authorized keys found. Click Create New Client Key && Package to add one.'
        $emptyLbl.Font      = $FONT_BODY
        $emptyLbl.ForeColor = $CLR_GREY
        $emptyLbl.Left      = 4; $emptyLbl.Top = $y; $emptyLbl.AutoSize = $true
        $pnl.Controls.Add($emptyLbl)
        $y += 30
    } else {
        for ($ri = 0; $ri -lt $liveKeys.Count; $ri++) {
            $k = $liveKeys[$ri]
            # Parse label from comment field (stored as "SecureRDP-[label]")
            $comment     = if ($null -ne $k.Comment) { $k.Comment } else { '' }
            $displayLabel = $comment -replace '^SecureRDP-', ''
            $keyBody     = if ($null -ne $k.KeyBody) { $k.KeyBody } else { '' }
            $keyType     = if ($null -ne $k.Type) { $k.Type } else { 'ssh-ed25519' }
            $fullKeyLine = "$keyType $keyBody $comment".Trim()

            # Look up metadata from ClientKeys
            $meta = if ($clientKeyMeta.ContainsKey($displayLabel)) { $clientKeyMeta[$displayLabel] } else { $null }
            $metaDate    = if ($null -ne $meta -and $meta.PSObject.Properties.Name -contains 'generatedDate') { $meta.generatedDate } else { '' }
            $metaServer  = if ($null -ne $meta -and $meta.PSObject.Properties.Name -contains 'serverAddress') { $meta.serverAddress } else { '' }
            $metaSshUser = if ($null -ne $meta -and $meta.PSObject.Properties.Name -contains 'sshUsername') { $meta.sshUsername } else { '' }
            $metaNotes   = if ($null -ne $meta -and $meta.PSObject.Properties.Name -contains 'notes') { $meta.notes } else { '' }

            $rowPnl           = New-Object System.Windows.Forms.Panel
            $rowPnl.Left      = 0; $rowPnl.Top = $y
            $rowPnl.Width     = $cW; $rowPnl.Height = 38
            $rowPnl.BackColor = $rowColors[$ri % 2]
            $pnl.Controls.Add($rowPnl)

            $rx = 0

            # Col 0: Label
            $lc         = New-Object System.Windows.Forms.Label
            $lc.Text    = $displayLabel
            $lc.Font    = $FONT_MONO
            $lc.Left    = $rx+4; $lc.Top = 8; $lc.Width = $colW[0]-4; $lc.Height = 22; $lc.AutoSize = $false
            $rowPnl.Controls.Add($lc); $rx += $colW[0]

            # Col 1: Date
            $dc         = New-Object System.Windows.Forms.Label
            $dc.Text    = $metaDate
            $dc.Font    = $FONT_BODY
            $dc.ForeColor = $CLR_GREY
            $dc.Left    = $rx+4; $dc.Top = 8; $dc.Width = $colW[1]-4; $dc.Height = 22; $dc.AutoSize = $false
            $rowPnl.Controls.Add($dc); $rx += $colW[1]

            # Col 2: Server
            $sc         = New-Object System.Windows.Forms.Label
            $sc.Text    = if ($metaServer) { $metaServer } else { '---' }
            $sc.Font    = $FONT_MONO
            $sc.ForeColor = if ($metaServer) { [System.Drawing.Color]::Black } else { $CLR_GREY }
            $sc.Left    = $rx+4; $sc.Top = 8; $sc.Width = $colW[2]-4; $sc.Height = 22; $sc.AutoSize = $false
            $rowPnl.Controls.Add($sc); $rx += $colW[2]

            # Col 3: SSH Username
            $uc         = New-Object System.Windows.Forms.Label
            $uc.Text    = if ($metaSshUser) { $metaSshUser } else { '---' }
            $uc.Font    = $FONT_BODY
            $uc.ForeColor = if ($metaSshUser) { [System.Drawing.Color]::Black } else { $CLR_GREY }
            $uc.Left    = $rx+4; $uc.Top = 8; $uc.Width = $colW[3]-4; $uc.Height = 22; $uc.AutoSize = $false
            $rowPnl.Controls.Add($uc); $rx += $colW[3]

            # Col 4: Notes (editable)
            $ntb        = New-Object System.Windows.Forms.TextBox
            $ntb.Text   = $metaNotes
            $ntb.Left   = $rx+4; $ntb.Top = 8; $ntb.Width = $colW[4]-8; $ntb.Height = 22
            $ntb.Font   = $FONT_BODY; $ntb.BorderStyle = 'FixedSingle'
            $rowPnl.Controls.Add($ntb)
            if ($displayLabel.Length -gt 0) { $script:NoteControls[$displayLabel] = $ntb }
            $rx += $colW[4]

            # Col 5: Deauthorize button
            $capturedLabel    = $displayLabel
            $capturedNotes    = $metaNotes
            $capturedKeyLine  = $fullKeyLine

            $bRvk         = New-Object System.Windows.Forms.Button
            $bRvk.Text    = 'Deauthorize'
            $bRvk.Left    = $rx+4; $bRvk.Top = 6; $bRvk.Width = $colW[5]-8; $bRvk.Height = 26
            $bRvk.FlatStyle = 'Flat'; $bRvk.Font = $FONT_ROW_BTN
            $bRvk.BackColor = [System.Drawing.Color]::FromArgb(170, 20, 10)
            $bRvk.ForeColor = $CLR_WHITE
            $bRvk.FlatAppearance.BorderSize = 0; $bRvk.Cursor = 'Hand'
            $rowPnl.Controls.Add($bRvk)

            $bRvk.Add_Click({
                $noteVal = if ($script:NoteControls.ContainsKey($capturedLabel)) { $script:NoteControls[$capturedLabel].Text } else { '' }
                try { Write-SrdpLog "Manage: deauthorize requested for key '$capturedLabel'." -Level INFO -Component 'Manage' } catch {}
                if (Show-RevokeConfirm -Label $capturedLabel -Notes $noteVal) {
                    try {
                        $r = Remove-SrdpAuthorizedKey -PublicKeyText $capturedKeyLine
                        if ($r -is [string] -and $r -like 'error:*') {
                            try { Write-SrdpLog "Manage: deauthorize failed for '$capturedLabel': $r" -Level ERROR -Component 'Manage' } catch {}
                            [System.Windows.Forms.MessageBox]::Show("Deauthorization failed.`n`n$r",
                                'SecureRDP', [System.Windows.Forms.MessageBoxButtons]::OK,
                                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                        } else {
                            try { Write-SrdpLog "Manage: key '$capturedLabel' deauthorized." -Level INFO -Component 'Manage' } catch {}
                            Mark-KeyDeauthorized -Label $capturedLabel
                            $script:ManageResult = 'refresh'; $f.Close()
                        }
                    } catch {
                        $errMsg = $_.Exception.Message
                        try { Write-SrdpLog "Manage: deauthorize exception for '$capturedLabel': $errMsg" -Level ERROR -Component 'Manage' } catch {}
                        [System.Windows.Forms.MessageBox]::Show("Deauthorization failed.`n`n$errMsg",
                            'SecureRDP', [System.Windows.Forms.MessageBoxButtons]::OK,
                            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                    }
                }
            }.GetNewClosure())

            $y += 38
        }
    }

    $y += 6
    $noteHint           = New-Object System.Windows.Forms.Label
    $noteHint.Text      = 'Deauthorizing removes the key from authorized_keys immediately. The key record is retained for audit. Notes are saved on close or refresh.'
    $noteHint.Font      = $FONT_BODY
    $noteHint.ForeColor = $CLR_GREY
    $noteHint.Left      = 0; $noteHint.Top = $y; $noteHint.Width = $cW; $noteHint.Height = 22
    $noteHint.AutoSize  = $false
    $pnl.Controls.Add($noteHint)

    # ---- Wire button handlers ----
    $script:ManageResult = 'close'

    $bRefresh.Add_Click({ Save-Notes; $script:ManageResult = 'refresh'; $f.Close() })

    $bStop.Add_Click({
        try { Write-SrdpLog 'Manage: requesting sshd stop.' -Level INFO -Component 'Manage' } catch {}
        try {
            $r = Stop-SrdpSshdService
            if ($r -is [string] -and $r -like 'error:*') {
                try { Write-SrdpLog "Manage: sshd stop failed: $r" -Level ERROR -Component 'Manage' } catch {}
                [System.Windows.Forms.MessageBox]::Show("Could not stop service.`n`n$r",
                    'SecureRDP', [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            } else {
                try { Write-SrdpLog 'Manage: sshd stopped.' -Level INFO -Component 'Manage' } catch {}
                $script:ManageResult = 'refresh'; $f.Close()
            }
        } catch {
            $errMsg = $_.Exception.Message
            try { Write-SrdpLog "Manage: sshd stop exception: $errMsg" -Level ERROR -Component 'Manage' } catch {}
            [System.Windows.Forms.MessageBox]::Show("Could not stop service.`n`n$errMsg",
                'SecureRDP', [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    })

    $bStart.Add_Click({
        try { Write-SrdpLog 'Manage: requesting sshd start.' -Level INFO -Component 'Manage' } catch {}
        try {
            $r = Start-SrdpSshdService
            if ($r -is [string] -and $r -like 'error:*') {
                try { Write-SrdpLog "Manage: sshd start failed: $r" -Level ERROR -Component 'Manage' } catch {}
                [System.Windows.Forms.MessageBox]::Show("Could not start service.`n`n$r",
                    'SecureRDP', [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            } else {
                try { Write-SrdpLog 'Manage: sshd started.' -Level INFO -Component 'Manage' } catch {}
                $script:ManageResult = 'refresh'; $f.Close()
            }
        } catch {
            $errMsg = $_.Exception.Message
            try { Write-SrdpLog "Manage: sshd start exception: $errMsg" -Level ERROR -Component 'Manage' } catch {}
            [System.Windows.Forms.MessageBox]::Show("Could not start service.`n`n$errMsg",
                'SecureRDP', [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    })

    $capturedEsScript = $EsScript
    if ($esExists) {
        $bES.Add_Click({
            try {
                $pi = New-Object System.Diagnostics.ProcessStartInfo
                $pi.FileName = 'powershell.exe'
                $pi.Arguments = "-ExecutionPolicy Bypass -STA -File `"$capturedEsScript`""
                $pi.UseShellExecute = $false; $pi.RedirectStandardError = $true
                [System.Diagnostics.Process]::Start($pi) | Out-Null
                try { Write-SrdpLog 'Manage: launched EnhancedSecurity.' -Level INFO -Component 'Manage' } catch {}
            } catch {
                $errMsg = $_.Exception.Message
                try { Write-SrdpLog "Manage: EnhancedSecurity launch failed: $errMsg" -Level ERROR -Component 'Manage' } catch {}
                [System.Windows.Forms.MessageBox]::Show("Could not launch Enhanced Security.`n`n$errMsg",
                    'SecureRDP', [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            }
        }.GetNewClosure())
    }

    $capturedRevertScript = $RevertScript
    $capturedStateFile    = $StateFile

    $bUninstall.Add_Click({
        if (-not (Test-Path $capturedRevertScript)) {
            [System.Windows.Forms.MessageBox]::Show("Revert script not found at:`n$capturedRevertScript",
                'SecureRDP', [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null; return
        }
        Save-Notes
        try { Write-SrdpLog 'Manage: launching Revert_Phase1a.' -Level INFO -Component 'Manage' } catch {}
        try {
            $pi = New-Object System.Diagnostics.ProcessStartInfo
            $pi.FileName = 'powershell.exe'
            $pi.Arguments = "-ExecutionPolicy Bypass -STA -File `"$capturedRevertScript`" -StateFilePath `"$capturedStateFile`""
            $pi.UseShellExecute = $false; $pi.RedirectStandardError = $true
            [System.Diagnostics.Process]::Start($pi) | Out-Null
            $script:ManageResult = 'refresh'; $f.Close()
        } catch {
            $errMsg = $_.Exception.Message
            try { Write-SrdpLog "Manage: revert launch failed: $errMsg" -Level ERROR -Component 'Manage' } catch {}
            [System.Windows.Forms.MessageBox]::Show("Could not launch revert script.`n`n$errMsg",
                'SecureRDP', [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    }.GetNewClosure())

    $capturedCkwScript = $ClientKeyWizard
    $bAdd.Add_Click({
        if (-not (Test-Path $capturedCkwScript)) {
            [System.Windows.Forms.MessageBox]::Show("Client Key Wizard not found at:`n$capturedCkwScript",
                'SecureRDP', [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null; return
        }
        try { Write-SrdpLog 'Manage: launching ClientKeyWizard.' -Level INFO -Component 'Manage' } catch {}
        try {
            $pi = New-Object System.Diagnostics.ProcessStartInfo
            $pi.FileName = 'powershell.exe'
            $pi.Arguments = "-ExecutionPolicy Bypass -STA -File `"$capturedCkwScript`""
            $pi.UseShellExecute = $false; $pi.RedirectStandardError = $true
            [System.Diagnostics.Process]::Start($pi) | Out-Null
        } catch {
            $errMsg = $_.Exception.Message
            try { Write-SrdpLog "Manage: ClientKeyWizard launch failed: $errMsg" -Level ERROR -Component 'Manage' } catch {}
            [System.Windows.Forms.MessageBox]::Show("Could not launch Client Key Wizard.`n`n$errMsg",
                'SecureRDP', [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    }.GetNewClosure())

    $bClose.Add_Click({ Save-Notes; $f.Close() })
    $f.CancelButton = $bClose
    $f.ShowDialog() | Out-Null
    return $script:ManageResult
}

# ===========================================================================
# MAIN
# ===========================================================================
$loop = $true
while ($loop) {
    $result = Show-ManageScreen
    if ($result -ne 'refresh') { $loop = $false }
}
exit 0
