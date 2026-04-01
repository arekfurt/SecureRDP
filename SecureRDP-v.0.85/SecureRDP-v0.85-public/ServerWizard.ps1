#Requires -Version 5.1
# =============================================================================
# SecureRDP v0.835 - Server Wizard
# GitHub: arekfurt/SecureRDP
# =============================================================================

# =============================================================================
# SELF-ELEVATION: Ensure we are running as Administrator in STA mode with
# execution policy bypass, regardless of how the script was launched.
# If any condition is not met, relaunch with correct parameters and exit.
# =============================================================================
$_needsRelaunch = $false
$_isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$_isSTA   = ([System.Threading.Thread]::CurrentThread.ApartmentState -eq 'STA')

if (-not $_isAdmin -or -not $_isSTA) { $_needsRelaunch = $true }

if ($_needsRelaunch) {
    $argList = "-ExecutionPolicy Bypass -STA -File `"$PSCommandPath`""
    if ($_isAdmin) {
        Start-Process powershell.exe -ArgumentList $argList
    } else {
        Start-Process powershell.exe -ArgumentList $argList -Verb RunAs
    }
    exit
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


$SRDP_VER = '0.85'

# Load central logging module -- must happen early, before any module imports
$_swLogMod = Join-Path $PSScriptRoot 'SupportingModules\SrdpLog.psm1'
if (Test-Path $_swLogMod) {
    Import-Module $_swLogMod -Force
    $ErrorActionPreference = 'Stop'
    Initialize-SrdpLog -Component 'ServerWizard'
    try { Write-SrdpLog "ServerWizard starting. Version=$SRDP_VER PID=$PID" -Level INFO -Component 'ServerWizard' } catch {}
}

$CONFIG_FILE = Join-Path $PSScriptRoot 'config.ini'
$CONFIG_BAK  = Join-Path $PSScriptRoot 'config.ini.bak'
$MODULES_DIR = Join-Path $PSScriptRoot 'SupportingModules'
$RDPCHECK_DIR = Join-Path $PSScriptRoot 'RDPCheckModules'

# =============================================================================
# UI CONSTANTS
# =============================================================================
[System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName('System.Drawing')       | Out-Null

$FONT_NORMAL  = New-Object System.Drawing.Font('Calibri', 12)
$FONT_TITLE   = New-Object System.Drawing.Font('Georgia', 14, [System.Drawing.FontStyle]::Bold)
$FONT_HEADING = New-Object System.Drawing.Font('Georgia', 13, [System.Drawing.FontStyle]::Bold)
$FONT_MONO    = New-Object System.Drawing.Font('Consolas', 10)

# Left/centre column fonts -- Calibri
$FONT_SMALL        = New-Object System.Drawing.Font('Calibri', 11)
$FONT_SMALL_BOLD   = New-Object System.Drawing.Font('Calibri', 12,   [System.Drawing.FontStyle]::Bold)
$FONT_SMALL_ITALIC = New-Object System.Drawing.Font('Calibri', 12,   [System.Drawing.FontStyle]::Italic)
$FONT_QS_TITLE     = New-Object System.Drawing.Font('Calibri', 13,   [System.Drawing.FontStyle]::Bold)
$FONT_QS_DESC      = New-Object System.Drawing.Font('Calibri', 11)
$FONT_QS_KICKER    = New-Object System.Drawing.Font('Calibri', 10,   [System.Drawing.FontStyle]::Bold)
$FONT_QS_FINISH    = New-Object System.Drawing.Font('Calibri', 12,   [System.Drawing.FontStyle]::Bold)
$FONT_QS_SUB       = New-Object System.Drawing.Font('Calibri', 10.5)
$FONT_REVERT_TITLE = New-Object System.Drawing.Font('Calibri', 12,   [System.Drawing.FontStyle]::Bold)
$FONT_REVERT_DESC  = New-Object System.Drawing.Font('Calibri', 10.5)
$FONT_REVERT_DESC2 = New-Object System.Drawing.Font('Calibri', 10.5)
$FONT_REPO_NOTE    = New-Object System.Drawing.Font('Calibri', 10,   [System.Drawing.FontStyle]::Italic)

# Right column / widget fonts -- Times New Roman Bold
$FONT_WIDGET_TITLE = New-Object System.Drawing.Font('Times New Roman', 10,   [System.Drawing.FontStyle]::Bold)
$FONT_WIDGET_LABEL = New-Object System.Drawing.Font('Times New Roman',  9,   [System.Drawing.FontStyle]::Bold)
$FONT_WIDGET_BOLD  = New-Object System.Drawing.Font('Times New Roman',  9,   [System.Drawing.FontStyle]::Bold)
$FONT_TINY         = New-Object System.Drawing.Font('Times New Roman',  9,   [System.Drawing.FontStyle]::Bold)
$FONT_PORT_HINT    = New-Object System.Drawing.Font('Times New Roman',  8.5, [System.Drawing.FontStyle]::Bold)

$CLR_BG      = [System.Drawing.Color]::FromArgb(245, 245, 245)
$CLR_ACCENT  = [System.Drawing.Color]::FromArgb(0, 60, 120)
$CLR_WARN    = [System.Drawing.Color]::FromArgb(160, 60, 0)
$CLR_ERROR   = [System.Drawing.Color]::FromArgb(160, 20, 10)
$CLR_OK      = [System.Drawing.Color]::FromArgb(10, 110, 10)
$CLR_DIMGRAY   = [System.Drawing.Color]::FromArgb(60, 60, 60)  # retained for widget fg fallback
$CLR_SECONDARY = [System.Drawing.Color]::FromArgb(50, 50, 50)  # dark grey for label/hint text
$CLR_SILVER  = [System.Drawing.Color]::FromArgb(160, 160, 160)

# Widget border/title colors
$CLR_BLUE_BORDER  = [System.Drawing.Color]::FromArgb(91,  155, 213)
$CLR_BLUE_TITLE   = [System.Drawing.Color]::FromArgb(234, 242, 251)
$CLR_BLUE_FG      = [System.Drawing.Color]::FromArgb(42,  96,  153)
$CLR_GREEN_BORDER = [System.Drawing.Color]::FromArgb(26,  158, 58)
$CLR_GREEN_TITLE  = [System.Drawing.Color]::FromArgb(234, 250, 240)
$CLR_GREEN_FG     = [System.Drawing.Color]::FromArgb(26,  122, 46)
$CLR_RED_TITLE    = [System.Drawing.Color]::FromArgb(253, 232, 230)
$CLR_GREY_BORDER  = [System.Drawing.Color]::FromArgb(80, 80, 80)
$CLR_GREY_TITLE   = [System.Drawing.Color]::FromArgb(232, 232, 232)
$CLR_VAL_BLUE     = [System.Drawing.Color]::FromArgb(50,  110, 190)

# Additional widget verdict colors
$CLR_RED_BORDER   = [System.Drawing.Color]::FromArgb(192, 32,  14)
$CLR_RED_BG       = [System.Drawing.Color]::FromArgb(253, 232, 230)
$CLR_RED_FG       = [System.Drawing.Color]::FromArgb(160, 20,  10)
$CLR_ORANGE_BORDER = [System.Drawing.Color]::FromArgb(210, 110, 20)
$CLR_ORANGE_BG    = [System.Drawing.Color]::FromArgb(255, 243, 224)
$CLR_ORANGE_FG    = [System.Drawing.Color]::FromArgb(170, 80,  10)
$CLR_YELLOW_BORDER = [System.Drawing.Color]::FromArgb(180, 155, 20)
$CLR_YELLOW_BG    = [System.Drawing.Color]::FromArgb(255, 252, 220)
$CLR_YELLOW_FG    = [System.Drawing.Color]::FromArgb(100, 75,  0)
$CLR_LGREEN_BORDER = [System.Drawing.Color]::FromArgb(80,  170, 80)
$CLR_LGREEN_BG    = [System.Drawing.Color]::FromArgb(236, 252, 236)
$CLR_LGREEN_FG    = [System.Drawing.Color]::FromArgb(40,  130, 40)

$FORM_WIDTH   = 1020
$BTN_BAR_H    = 64   # height of the fixed button bar at the bottom
$BTN_H        = 34
$BTN_W_NORM   = 120
$BTN_W_WIDE   = 360

# =============================================================================
# GUI HELPER FUNCTIONS
# =============================================================================

# -----------------------------------------------------------------------------
# New-SrdpForm
# Creates a base form. Content goes in the scrollable panel returned alongside
# the form. Button bar is a separate fixed panel at the bottom.
#
# Returns hashtable: @{ Form = ...; Panel = ...; BtnBar = ... }
#   Form   - the Form object (call .ShowDialog() on this)
#   Panel  - AutoScroll panel; add all content controls to this
#   BtnBar - fixed panel at bottom; add buttons to this
# -----------------------------------------------------------------------------
function New-SrdpForm {
    param([string]$Title = 'SecureRDP', [int]$Height = 600)

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = $Title
    $form.Width           = $FORM_WIDTH
    $form.Height          = $Height
    $form.BackColor       = $CLR_BG
    $form.Font            = $FONT_NORMAL
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
    $form.MinimumSize     = New-Object System.Drawing.Size($FORM_WIDTH, 400)
    $form.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.KeyPreview      = $true

    # Title bar strip
    $bar            = New-Object System.Windows.Forms.Panel
    $bar.Dock       = [System.Windows.Forms.DockStyle]::Top
    $bar.Height     = 56
    $bar.BackColor  = $CLR_ACCENT

    $titleLbl           = New-Object System.Windows.Forms.Label
    $titleLbl.Text      = $Title
    $titleLbl.Font      = $FONT_TITLE
    $titleLbl.ForeColor = [System.Drawing.Color]::White
    $titleLbl.AutoSize  = $false
    $titleLbl.Left      = 0
    $titleLbl.Top       = 0
    $titleLbl.Width     = $FORM_WIDTH - 90
    $titleLbl.Height    = 56
    $titleLbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $titleLbl.Padding   = New-Object System.Windows.Forms.Padding(14, 0, 0, 0)
    $bar.Controls.Add($titleLbl)

    # Fixed button bar at bottom
    $btnBar           = New-Object System.Windows.Forms.Panel
    $btnBar.Dock      = [System.Windows.Forms.DockStyle]::Bottom
    $btnBar.Height    = $BTN_BAR_H
    $btnBar.BackColor = $CLR_BG

    # Separator line above button bar
    $sep           = New-Object System.Windows.Forms.Panel
    $sep.Dock      = [System.Windows.Forms.DockStyle]::Bottom
    $sep.Height    = 1
    $sep.BackColor = $CLR_SILVER

    # Scrollable content panel
    $scroll              = New-Object System.Windows.Forms.Panel
    $scroll.Dock         = [System.Windows.Forms.DockStyle]::Fill
    $scroll.AutoScroll   = $true
    $scroll.Padding      = New-Object System.Windows.Forms.Padding(24, 20, 24, 20)
    $scroll.BackColor    = $CLR_BG

    # Add in correct dock order (Bottom docks first, then Fill takes remainder)
    $form.Controls.Add($scroll)
    $form.Controls.Add($sep)
    $form.Controls.Add($btnBar)
    $form.Controls.Add($bar)

    return @{ Form = $form; Panel = $scroll; BtnBar = $btnBar; TitleBar = $bar }
}

# -----------------------------------------------------------------------------
# Add-Label  - adds a label to a panel, returns the label
# -----------------------------------------------------------------------------
function Add-Label {
    param(
        [System.Windows.Forms.Control]$Parent,
        [string]$Text,
        [int]$Top,
        [int]$Left      = 0,
        [int]$Width     = 720,
        [System.Drawing.Font]$Font      = $null,
        [System.Drawing.Color]$ForeColor = [System.Drawing.Color]::Black
    )
    $lbl             = New-Object System.Windows.Forms.Label
    $lbl.Text        = $Text
    $lbl.Left        = $Left
    $lbl.Top         = $Top
    $lbl.Width       = $Width
    $lbl.AutoSize    = $false
    $lbl.Font        = if ($Font) { $Font } else { $FONT_NORMAL }
    $lbl.ForeColor   = $ForeColor
    $lbl.MaximumSize = New-Object System.Drawing.Size($Width, 2000)
    $lbl.AutoSize    = $true
    $Parent.Controls.Add($lbl)
    return $lbl
}

# -----------------------------------------------------------------------------
# Add-DetailBox
# Read-only, selectable, scrollable TextBox for technical detail the user
# may need to copy (file paths, error messages, evidence lists, etc.)
# -----------------------------------------------------------------------------
function Add-DetailBox {
    param(
        [System.Windows.Forms.Control]$Parent,
        [string]$Text,
        [int]$Top,
        [int]$Left   = 0,
        [int]$Width  = 720,
        [int]$Height = 120
    )
    $tb                = New-Object System.Windows.Forms.TextBox
    $tb.Text           = $Text
    $tb.Left           = $Left
    $tb.Top            = $Top
    $tb.Width          = $Width
    $tb.Height         = $Height
    $tb.Multiline      = $true
    $tb.ReadOnly       = $true
    $tb.ScrollBars     = [System.Windows.Forms.ScrollBars]::Vertical
    $tb.Font           = $FONT_MONO
    $tb.BackColor      = [System.Drawing.Color]::FromArgb(235, 235, 235)
    $tb.BorderStyle    = [System.Windows.Forms.BorderStyle]::FixedSingle
    $tb.TabStop        = $false
    $Parent.Controls.Add($tb)
    return $tb
}

# -----------------------------------------------------------------------------
# Add-Button  - adds a styled button to a panel, returns the button
# -----------------------------------------------------------------------------
function Add-Button {
    param(
        [System.Windows.Forms.Control]$Parent,
        [string]$Text,
        [int]$Left,
        [int]$Top,
        [int]$Width    = $BTN_W_NORM,
        [int]$Height   = $BTN_H,
        [bool]$Primary = $false,
        [bool]$Danger  = $false,
        [int]$TabIndex = 0
    )
    $btn           = New-Object System.Windows.Forms.Button
    $btn.Text      = $Text
    $btn.Left      = $Left
    $btn.Top       = $Top
    $btn.Width     = $Width
    $btn.Height    = $Height
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $btn.TabIndex  = $TabIndex

    if ($Danger) {
        $btn.BackColor = $CLR_ERROR
        $btn.ForeColor = [System.Drawing.Color]::White
        $btn.FlatAppearance.BorderSize = 0
    } elseif ($Primary) {
        $btn.BackColor = $CLR_ACCENT
        $btn.ForeColor = [System.Drawing.Color]::White
        $btn.FlatAppearance.BorderSize = 0
    } else {
        $btn.BackColor = [System.Drawing.Color]::White
        $btn.ForeColor = [System.Drawing.Color]::Black
        $btn.FlatAppearance.BorderColor = $CLR_SILVER
        $btn.FlatAppearance.BorderSize  = 1
    }
    $Parent.Controls.Add($btn)
    return $btn
}

function Show-WaitCursor {
    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
    [System.Windows.Forms.Application]::DoEvents()
}
function Hide-WaitCursor {
    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
}

# =============================================================================
# SCREEN FUNCTIONS
# Button layout convention:
#   Safe/Exit/Cancel : left side, TabIndex 0, form.CancelButton
#   Proceed/Next     : right side, TabIndex 1, form.AcceptButton (neutral screens)
# On WARNING screens: Enter defaults to Exit (safe). Tab moves to Proceed.
# On NEUTRAL screens: Enter defaults to Next/OK.
# On BLOCKER screens: single Exit button is both Accept and Cancel.
# =============================================================================

# Button bar Y center helper
function Get-BtnTop {
    param([int]$BarHeight = $BTN_BAR_H, [int]$BtnHeight = $BTN_H)
    return [int](($BarHeight - $BtnHeight) / 2)
}

# -----------------------------------------------------------------------------
# Show-Welcome
# Neutral screen. Next is AcceptButton (Enter). Exit is CancelButton (Escape).
# Returns 'next' or 'exit'.
# -----------------------------------------------------------------------------
function Show-Welcome {
    $ui = New-SrdpForm 'SecureRDP Server Wizard' 720
    $f  = $ui.Form; $p = $ui.Panel; $bb = $ui.BtnBar
    $y  = 0

    $lbl = Add-Label $p 'Welcome to SecureRDP' $y -Font $FONT_HEADING
    $y  += $lbl.Height + 16

    $body = Add-Label $p @"
SecureRDP is a project designed with the intent of eventually enabling some Windows-using organizations and individuals to far better secure their use of RDP, and do so at no additional cost, with relatively little additional time commitment, and without possessing a super-abundance of Windows or RDP security expertise.

Today, this test build will try to guide you through:
  - Better understanding your current RDP-related security posture and risk.
  - Setting up protective SSH tunnels between Windows machines, with the tunnels employing cryptographic mutual authentication to defeat all password and phishing-based attacks and strong encryption to protect traffic.
  - Shoring up your riskiest RDP-related attack surface/s by closing off machines to direct inbound access from the Internet or from high-risk internal networks.

The program features an information dashboard, plus a number of wizards that can be run and re-run at any time to generate packages for client machines, to review configurations, etc. No changes should be made to your machines until you confirm them.

IMPORTANT NOTICE: This build is primarily intended for bughunting and to encourage the solicitation and provision of feedback. It is not ready or suitable for use by ordinary users yet. If you use it, expect to find bugs. Do not expect it to be reliable or stable. THIS BUILD IS FOR USE ON TEST MACHINES AND IN TEST ENVIRONMENTS ONLY.

For docs and to report issues or submit feedback visit:
github.com/arekfurt/SecureRDP

Version 0.85  |  Initial public release
"@ $y
    $y += $body.Height + 16

    $btnY    = Get-BtnTop
    $bExit   = Add-Button $bb 'Exit'   16  $btnY $BTN_W_NORM -TabIndex 0
    $bNext   = Add-Button $bb 'Next >' ($FORM_WIDTH - $BTN_W_NORM - 32) $btnY $BTN_W_NORM -Primary $true -TabIndex 1

    $f.AcceptButton = $bNext
    $f.CancelButton = $bExit

    $script:WelcomeResult = 'exit'
    $bExit.Add_Click({ $script:WelcomeResult = 'exit'; $f.Close() })
    $bNext.Add_Click({ $script:WelcomeResult = 'next'; $f.Close() })
    $f.ShowDialog() | Out-Null
    return $script:WelcomeResult
}

# -----------------------------------------------------------------------------
# Show-MalformedConfigDialog
# Warning screen. Exit is AcceptButton (Enter = safe default). Tab to Backup.
# Returns 'exit' or 'backup'.
# -----------------------------------------------------------------------------
function Show-MalformedConfigDialog {
    $ui = New-SrdpForm 'SecureRDP - Configuration File Problem' 520
    $f  = $ui.Form; $p = $ui.Panel; $bb = $ui.BtnBar
    $y  = 0

    $h = Add-Label $p 'Configuration File Problem' $y -Font $FONT_HEADING -ForeColor $CLR_WARN
    $y += $h.Height + 16

    $body = Add-Label $p @"
The SecureRDP configuration file on this machine appears to be malformed
or corrupted and cannot be read safely.

Location:
"@ $y
    $y += $body.Height + 4

    Add-DetailBox $p $CONFIG_FILE $y -Height 36 | Out-Null
    $y += 52

    $opts = Add-Label $p @"
You have two options:

EXIT
Leave the file in place and exit the wizard. You can inspect the file
manually before running the wizard again.

BACKUP AND CONTINUE
The malformed file will be renamed config.ini.bak and a fresh configuration
file will be created. The wizard will then start from the beginning.
Any previously recorded configuration state will be lost.
"@ $y
    $y += $opts.Height + 16

    $btnY    = Get-BtnTop
    $bExit   = Add-Button $bb 'Exit'                16  $btnY $BTN_W_NORM -TabIndex 0
    $bBackup = Add-Button $bb 'Backup and Continue' ($FORM_WIDTH - $BTN_W_WIDE - 32) $btnY $BTN_W_WIDE -Primary $true -TabIndex 1

    # Warning screen: Enter = safe choice (Exit)
    $f.AcceptButton = $bExit
    $f.CancelButton = $bExit

    $script:MalformedResult = 'exit'
    $bExit.Add_Click({   $script:MalformedResult = 'exit';   $f.Close() })
    $bBackup.Add_Click({ $script:MalformedResult = 'backup'; $f.Close() })
    $f.ShowDialog() | Out-Null
    return $script:MalformedResult
}

# -----------------------------------------------------------------------------
# Show-IneligibleSku  - hard blocker, Exit only
# -----------------------------------------------------------------------------
function Show-IneligibleSku {
    $ui = New-SrdpForm 'SecureRDP - Unsupported Windows Edition' 380
    $f  = $ui.Form; $p = $ui.Panel; $bb = $ui.BtnBar
    $y  = 0

    $h = Add-Label $p 'Unsupported Windows Edition' $y -Font $FONT_HEADING -ForeColor $CLR_ERROR
    $y += $h.Height + 16

    Add-Label $p @"
Unfortunately, Windows Home simply doesn't support RDP inbound connectivity,
giving this script nothing to secure. Sorry.
"@ $y | Out-Null

    $btnY  = Get-BtnTop
    $bExit = Add-Button $bb 'Exit' ($FORM_WIDTH - $BTN_W_NORM - 32) $btnY $BTN_W_NORM -Primary $true -TabIndex 0

    $f.AcceptButton = $bExit
    $f.CancelButton = $bExit
    $bExit.Add_Click({ $f.Close() })
    $f.ShowDialog() | Out-Null
}

# -----------------------------------------------------------------------------
# Show-NotAdmin  - hard blocker, Exit only
# -----------------------------------------------------------------------------
function Show-NotAdmin {
    $ui = New-SrdpForm 'SecureRDP - Administrator Rights Required' 380
    $f  = $ui.Form; $p = $ui.Panel; $bb = $ui.BtnBar
    $y  = 0

    $h = Add-Label $p 'Administrator Rights Required' $y -Font $FONT_HEADING -ForeColor $CLR_ERROR
    $y += $h.Height + 16

    Add-Label $p @"
This wizard must be run as Administrator.

Please close this window, right-click ServerWizard.ps1 (or its shortcut),
and choose 'Run as administrator'.
"@ $y | Out-Null

    $btnY  = Get-BtnTop
    $bExit = Add-Button $bb 'Exit' ($FORM_WIDTH - $BTN_W_NORM - 32) $btnY $BTN_W_NORM -Primary $true -TabIndex 0

    $f.AcceptButton = $bExit
    $f.CancelButton = $bExit
    $bExit.Add_Click({ $f.Close() })
    $f.ShowDialog() | Out-Null
}

# -----------------------------------------------------------------------------
# Show-RdpSessionWarning
# Warning screen. Enter = Exit (safe). Tab to Proceed.
# Returns 'exit' or 'proceed'.
# -----------------------------------------------------------------------------
function Show-RdpSessionWarning {
    $ui = New-SrdpForm 'SecureRDP - RDP Session Detected' 620
    $f  = $ui.Form; $p = $ui.Panel; $bb = $ui.BtnBar
    $y  = 0

    $h = Add-Label $p 'CAUTION: You Are Currently Connected Over RDP' $y -Font $FONT_HEADING -ForeColor $CLR_WARN
    $y += $h.Height + 16

    $body = Add-Label $p @"
This script has detected that you are currently using RDP in this Windows session itself.

There are some safeguards built into this program to attempt to prevent you from doing things that would inadvertently result in you losing connectivity from client to server. However, using a piece of software--especially one in testing/dev/alpha phase--that configures RDP and SSH over a connection created by RDP and/or SSH inherently carries some additional risk.

Let me suggest you either wait for a version that might be better suited for this
case, or, if you choose to proceed, expect you may lose connectivity to your server machine at any time. And may not be able to get it back except by some mechanism not involving SSH or RDP.

You have been warned.

If you have the option to exit and run this locally on the server machine in question
instead that would be the safer course.
"@ $y
    $y += $body.Height + 16

    $btnY    = Get-BtnTop
    $bExit   = Add-Button $bb 'Exit' 16 $btnY $BTN_W_NORM -TabIndex 0
    $bProceed = Add-Button $bb 'I understand the risk - Proceed' ($FORM_WIDTH - $BTN_W_WIDE - 32) $btnY $BTN_W_WIDE -Primary $true -TabIndex 1

    # Warning: Enter = safe (Exit)
    $f.AcceptButton = $bExit
    $f.CancelButton = $bExit
    $bExit.Add_Click({    $script:RdpResult = 'exit';    $f.Close() })
    $bProceed.Add_Click({ $script:RdpResult = 'proceed'; $f.Close() })
    $script:RdpResult = 'exit'
    $f.ShowDialog() | Out-Null
    return $script:RdpResult
}

# -----------------------------------------------------------------------------
# Show-ThirdPartyFirewallWarning
# Warning screen. Enter = Exit (safe). Tab to Proceed.
# Returns 'exit' or 'proceed'.
# -----------------------------------------------------------------------------
function Show-ThirdPartyFirewallWarning {
    param([string[]]$Products)

    $ui = New-SrdpForm 'SecureRDP - Third-Party Firewall Detected' 560
    $f  = $ui.Form; $p = $ui.Panel; $bb = $ui.BtnBar
    $y  = 0

    $h = Add-Label $p 'Third-Party Firewall Detected' $y -Font $FONT_HEADING -ForeColor $CLR_WARN
    $y += $h.Height + 12

    $prod = Add-Label $p 'Detected product(s):' $y
    $y   += $prod.Height + 6

    Add-DetailBox $p ($Products -join "`r`n") $y -Height ([Math]::Min($Products.Count, 4) * 24 + 16) | Out-Null
    $y += ([Math]::Min($Products.Count, 4) * 24 + 32)

    $body = Add-Label $p @"
This script has detected that a third-party firewall or security product may be
active on this machine. Windows Firewall rules created by this script may not be
sufficient to control network access if another firewall product is also running.

Please consult the documentation for your security product to ensure that the
rules this script creates will be respected, or disable the third-party product
before proceeding.
"@ $y
    $y += $body.Height + 16

    $btnY     = Get-BtnTop
    $bExit    = Add-Button $bb 'Exit'    16 $btnY $BTN_W_NORM -TabIndex 0
    $bProceed = Add-Button $bb 'Proceed' ($FORM_WIDTH - $BTN_W_NORM - 32) $btnY $BTN_W_NORM -Primary $true -TabIndex 1

    $f.AcceptButton = $bExit
    $f.CancelButton = $bExit
    $script:FwResult = 'exit'
    $bExit.Add_Click({    $script:FwResult = 'exit';    $f.Close() })
    $bProceed.Add_Click({ $script:FwResult = 'proceed'; $f.Close() })
    $f.ShowDialog() | Out-Null
    return $script:FwResult
}

# -----------------------------------------------------------------------------
# Show-ManagedMachineWarning
# Warning screen. Enter = Exit (safe). Tab to Proceed.
# Returns 'exit' or 'proceed'.
# -----------------------------------------------------------------------------
function Show-ManagedMachineWarning {
    param([string[]]$Evidence)

    $ui = New-SrdpForm 'SecureRDP - Managed Machine Detected' 640
    $f  = $ui.Form; $p = $ui.Panel; $bb = $ui.BtnBar
    $y  = 0

    $h = Add-Label $p 'Organizational Management Detected' $y -Font $FONT_HEADING -ForeColor $CLR_WARN
    $y += $h.Height + 12

    $ev = Add-Label $p 'Evidence found:' $y
    $y += $ev.Height + 6

    Add-DetailBox $p ($Evidence -join "`r`n") $y -Height ([Math]::Min($Evidence.Count, 4) * 24 + 16) | Out-Null
    $y += ([Math]::Min($Evidence.Count, 4) * 24 + 32)

    $body = Add-Label $p @"
NOTICE: This script has detected apparent signs that this machine is
organizationally managed - whether by Active Directory Group Policy, Intune,
or other centralised software mechanisms, or even by an external management
services provider.

Please only use this script on a test machine where you know you have proper
authority to make modifications to its security configuration. Moreover, be
aware that centralised management mechanisms may clash with this script's
attempts to modify firewall configurations and server certificates in place,
with potentially unpredictable results for the soundness of the machine's
configuration.
"@ $y
    $y += $body.Height + 16

    $btnY     = Get-BtnTop
    $bExit    = Add-Button $bb 'Exit' 16 $btnY $BTN_W_NORM -TabIndex 0
    $bProceed = Add-Button $bb 'This is a test machine I have authority over, and I understand. Proceed.' `
        ($FORM_WIDTH - ($BTN_W_WIDE + 120) - 32) $btnY ($BTN_W_WIDE + 120) -Primary $true -TabIndex 1

    $f.AcceptButton = $bExit
    $f.CancelButton = $bExit
    $script:ManagedResult = 'exit'
    $bExit.Add_Click({    $script:ManagedResult = 'exit';    $f.Close() })
    $bProceed.Add_Click({ $script:ManagedResult = 'proceed'; $f.Close() })
    $f.ShowDialog() | Out-Null
    return $script:ManagedResult
}

# =============================================================================
# MAIN
# =============================================================================
function Main {
    [System.Windows.Forms.Application]::EnableVisualStyles()

    # -------------------------------------------------------------------------
    # Step 1: Load required modules
    # -------------------------------------------------------------------------
    try {
        Import-Module (Join-Path $MODULES_DIR 'InitialChecks.psm1') -Force -ErrorAction Stop
    }
    catch {
        Show-ModuleLoadError `
            -ModulePath 'SupportingModules\InitialChecks.psm1' `
            -ErrorDetail $_.ToString()
        exit 1
    }

    try {
        Import-Module (Join-Path $RDPCHECK_DIR 'RDPStatus.psm1') -Force -ErrorAction Stop
    }
    catch {
        Show-ModuleLoadError `
            -ModulePath 'RDPCheckModules\RDPStatus.psm1' `
            -ErrorDetail $_.ToString()
        exit 1
    }

    try {
        Import-Module (Join-Path $RDPCHECK_DIR 'FirewallReadWriteElements.psm1') -Force -ErrorAction Stop
    }
    catch {
        Show-ModuleLoadError `
            -ModulePath 'RDPCheckModules\FirewallReadWriteElements.psm1' `
            -ErrorDetail $_.ToString()
        exit 1
    }

    try {
        Import-Module (Join-Path $RDPCHECK_DIR 'FirewallAssessor.psm1') -Force -ErrorAction Stop
    }
    catch {
        Show-ModuleLoadError `
            -ModulePath 'RDPCheckModules\FirewallAssessor.psm1' `
            -ErrorDetail $_.ToString()
        exit 1
    }

    try {
        Import-Module (Join-Path $RDPCHECK_DIR 'FirewallVerdict.psm1') -Force -ErrorAction Stop
    }
    catch {
        Show-ModuleLoadError `
            -ModulePath 'RDPCheckModules\FirewallVerdict.psm1' `
            -ErrorDetail $_.ToString()
        exit 1
    }

    try {
        Import-Module (Join-Path $RDPCHECK_DIR 'CheckOtherRDPSecurity.psm1') -Force -ErrorAction Stop
    }
    catch {
        Show-ModuleLoadError `
            -ModulePath 'RDPCheckModules\CheckOtherRDPSecurity.psm1' `
            -ErrorDetail $_.ToString()
        exit 1
    }

    try {
        Import-Module (Join-Path $MODULES_DIR 'AttackExposure.psm1') -Force -ErrorAction Stop
    }
    catch {
        Show-ModuleLoadError `
            -ModulePath 'SupportingModules\AttackExposure.psm1' `
            -ErrorDetail $_.ToString()
        exit 1
    }

    # -------------------------------------------------------------------------
    # Step 2: SKU and admin checks
    # -------------------------------------------------------------------------

    # Windows SKU check
    $sku = Test-WindowsSku
    if ($sku -eq 'ineligible') { Show-IneligibleSku; exit 0 }

    # Admin rights check
    if ((Test-AdminRights) -eq 'not-admin') { Show-NotAdmin; exit 0 }

    # -------------------------------------------------------------------------
    # Step 3: Config file check and Welcome screen
    # -------------------------------------------------------------------------
    $configState = Test-ConfigFile -ConfigPath $CONFIG_FILE

    switch ($configState) {
        'missing' {
            New-EmptyConfig -ConfigPath $CONFIG_FILE -Version $SRDP_VER
            $welcomeResult = Show-Welcome
            if ($welcomeResult -eq 'exit') { exit 0 }
        }
        'malformed' {
            if ((Show-MalformedConfigDialog) -eq 'exit') { exit 0 }
            try {
                if (Test-Path $CONFIG_BAK) { Remove-Item $CONFIG_BAK -Force -ErrorAction Stop }
                Rename-Item -Path $CONFIG_FILE -NewName (Split-Path $CONFIG_BAK -Leaf) -ErrorAction Stop
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show(
                    "Could not back up the malformed config file.`n`nError: $($_.Exception.Message)`n`n" +
                    "Please check that config.ini is not open in another program, then try again.",
                    'SecureRDP - Backup Failed',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                ) | Out-Null
                exit 1
            }
            New-EmptyConfig -ConfigPath $CONFIG_FILE -Version $SRDP_VER
            $welcomeResult = Show-Welcome
            if ($welcomeResult -eq 'exit') { exit 0 }
        }
        'valid' {
        }
    }

    # -------------------------------------------------------------------------
    # Step 4: Gateway pre-checks (after user has seen Welcome)
    # -------------------------------------------------------------------------
    if ((Test-RdpSession) -eq 'rdp') {
        if ((Show-RdpSessionWarning) -eq 'exit') { exit 0 }
    }

    $fwCheck = Test-ThirdPartyFirewall
    if ($fwCheck.Result -eq 'detected') {
        if ((Show-ThirdPartyFirewallWarning -Products $fwCheck.Products) -eq 'exit') { exit 0 }
    }

    $managedCheck = Test-ManagedMachine
    if ($managedCheck.Result -eq 'evidenceofmanaged') {
        if ((Show-ManagedMachineWarning -Evidence $managedCheck.Evidence) -eq 'exit') { exit 0 }
    }

    # -------------------------------------------------------------------------
    # Step 5: Loading form appears
    # -------------------------------------------------------------------------
    # -------------------------------------------------------------------------
    try {
        $script:LoadingForm              = New-Object System.Windows.Forms.Form
        $script:LoadingForm.Width        = 440
        $script:LoadingForm.Height       = 110
        $script:LoadingForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
        $script:LoadingForm.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $script:LoadingForm.BackColor       = $CLR_ACCENT
        $script:LoadingForm.TopMost         = $true
        $script:LoadingForm.ControlBox      = $false
        $script:LoadingForm.Text            = 'SecureRDP'
        $loadLbl              = New-Object System.Windows.Forms.Label
        $loadLbl.Text         = 'Loading -- gathering system data, please wait...'
        $loadLbl.Font         = $FONT_SMALL_BOLD
        $loadLbl.ForeColor    = [System.Drawing.Color]::White
        $loadLbl.Dock         = [System.Windows.Forms.DockStyle]::Fill
        $loadLbl.TextAlign    = [System.Drawing.ContentAlignment]::MiddleCenter
        $script:LoadingForm.Controls.Add($loadLbl)
        $script:LoadingForm.Show()
        [System.Windows.Forms.Application]::DoEvents()
    } catch {
        $errMsg = $_.Exception.Message
        try { Write-SrdpLog "Loading form show failed: $errMsg" -Level WARN -Component 'ServerWizard' } catch {}
    }

    # -------------------------------------------------------------------------
    # Step 6: Archive integrity check (runs while loading form is visible)
    # -------------------------------------------------------------------------
    $integrity = Test-ArchiveIntegrity -ScriptRoot $PSScriptRoot
    if ($integrity.Result -eq 'missing') {
        $missingList = $integrity.Items -join "`n"
        try {
            if ($null -ne $script:LoadingForm -and -not $script:LoadingForm.IsDisposed) {
                $script:LoadingForm.Close(); $script:LoadingForm.Dispose()
            }
        } catch {
            $errMsg = $_.Exception.Message
            try { Write-SrdpLog "Loading form close failed: $errMsg" -Level WARN -Component 'ServerWizard' } catch {}
        }
        [System.Windows.Forms.MessageBox]::Show(
            "Some necessary files appear to be missing from the script's archive:`n`n" +
            "$missingList`n`n" +
            "Please try re-extracting the contents of the archive using the built-in Windows " +
            "zip 'Extract All' option and then, without changing or moving any files or " +
            "directories, re-run this script.`n`n" +
            "If you continue to get this message please try re-downloading the archive from " +
            "its GitHub repository at:`n  github.com/arekfurt/SecureRDP`n`n" +
            "If you still continue getting this message after that I'd much appreciate it " +
            "if you could file an issue there.",
            'SecureRDP - Missing Files',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        exit 1
    }

    Show-MainScreen
}

# =============================================================================
# MODE DISCOVERY
# Scans Modes\* for mode.ini files and QuickStart\UI_Phase1a.ps1
# Returns array of mode descriptors.
# =============================================================================
function Get-InstalledModes {
    $modesRoot = Join-Path $PSScriptRoot 'Modes'
    $result    = [System.Collections.Generic.List[object]]::new()

    if (-not (Test-Path $modesRoot)) { return $result }

    foreach ($dir in Get-ChildItem $modesRoot -Directory) {
        $iniPath = Join-Path $dir.FullName 'mode.ini'
        if (-not (Test-Path $iniPath)) { continue }

        $mode = @{
            DirName             = $dir.Name
            DirPath             = $dir.FullName
            Name                = $dir.Name
            Description         = ''
            Version             = ''
            Author              = ''
            QuickStartDesc      = ''
            HasQuickStart       = $false
            QuickStartScript    = $null
            InstalledDir        = $null
            OpCheckModule       = $null
        }

        # Parse mode.ini
        foreach ($line in (Get-Content $iniPath -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            if ($line -match '^\s*Name\s*=\s*(.+)$')                    { $mode.Name             = $Matches[1].Trim() }
            if ($line -match '^\s*Description\s*=\s*(.+)$')             { $mode.Description      = $Matches[1].Trim() }
            if ($line -match '^\s*Version\s*=\s*(.+)$')                 { $mode.Version          = $Matches[1].Trim() }
            if ($line -match '^\s*Author\s*=\s*(.+)$')                  { $mode.Author           = $Matches[1].Trim() }
            if ($line -match '^\s*QuickStartDescription\s*=\s*(.+)$')   { $mode.QuickStartDesc   = $Matches[1].Trim() }
        }

        # QuickStart
        $qsScript = Join-Path $dir.FullName 'QuickStart\UI_Phase1a.ps1'
        if (Test-Path $qsScript) {
            $mode.HasQuickStart    = $true
            $mode.QuickStartScript = $qsScript
        }

        # InstalledModes counterpart
        $instDir = Join-Path $PSScriptRoot "InstalledModes\$($dir.Name)"
        if (Test-Path $instDir) {
            $mode.InstalledDir  = $instDir
            $opCheck = Join-Path $instDir 'OperationalCheck.psm1'
            if (Test-Path $opCheck) { $mode.OpCheckModule = $opCheck }
        }

        $result.Add([pscustomobject]$mode)
    }

    return $result
}

# =============================================================================
# GET MODE INSTALL STATE
# Returns 'available', 'partial', or 'installed' based on state.json presence
# and Phase2Complete flag.
# =============================================================================
function Get-ModeInstallState {
    param([object]$Mode)
    $stateFile = Join-Path $PSScriptRoot "InstalledModes\$($Mode.DirName)\state.json"
    if (-not (Test-Path $stateFile)) { return 'available' }
    try {
        $st = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $st -or $st -is [string]) { return 'available' }

        $props = $st.PSObject.Properties.Name

        # Future: SSHProtoCore full install sets Infrastructure.Phase2Complete
        if ($props -contains 'Infrastructure' -and $null -ne $st.Infrastructure) {
            $iProps = $st.Infrastructure.PSObject.Properties.Name
            if ($iProps -contains 'Phase2Complete' -and $st.Infrastructure.Phase2Complete -eq $true) {
                return 'installed'
            }
        }

        # Phase 1a install: state.json has Engine1 + Engine2, both Success=$true
        if ($props -contains 'Engine1' -and $props -contains 'Engine2') {
            $e1 = $st.Engine1
            $e2 = $st.Engine2
            if ($null -ne $e1 -and $null -ne $e2 -and
                $e1.Success -eq $true -and $e2.Success -eq $true) {
                return 'partial'  # Phase 1a done, Phase 2 not yet built
            }
            if ($null -ne $e1 -and $e1.Success -eq $true) {
                return 'partial'  # Engine 1 succeeded, Engine 2 may have failed
            }
            return 'available'    # Neither engine succeeded -- treat as not installed
        }

        return 'partial'
    } catch {
        $errMsg = $_.Exception.Message
        try { Write-SrdpLog "Get-ModeInstallState parse failed: $errMsg" -Level WARN -Component 'ServerWizard' } catch {}
        return 'available'
    }
}

# =============================================================================
# GET OPERATIONAL STATE FOR A MODE
# =============================================================================
function Get-ModeOpState {
    param([object]$Mode)
    if (-not $Mode.OpCheckModule) { return $null }
    try {
        Import-Module -Name $Mode.OpCheckModule -Force -ErrorAction Stop
        $state = Get-BasicOpState
        Remove-Module -Name (Split-Path $Mode.OpCheckModule -LeafBase) -ErrorAction SilentlyContinue
        return $state
    } catch {
        return @{ LockStatus='partial'; Summary="Operational check failed: $_"; Errors=@("$_") }
    }
}

# =============================================================================
# LAUNCH QUICKSTART (runs QuickStart.ps1 as a new elevated PowerShell process)
# =============================================================================
# =============================================================================
# MAIN SCREEN HELPERS
# =============================================================================

# New-ColPanel: creates a bare column panel inside the scroll panel
function New-ColPanel {
    param(
        [System.Windows.Forms.Control]$Parent,
        [int]$Left,
        [int]$Width,
        [int]$PanelHeight,
        [int]$Top = 0
    )
    $col           = New-Object System.Windows.Forms.Panel
    $col.Left      = $Left
    $col.Top       = $Top
    $col.Width     = $Width
    $col.Height    = $PanelHeight
    $col.BackColor = $CLR_BG
    $Parent.Controls.Add($col)
    return $col
}

# Add-ColHeading: blue heading label + 1px rule; returns new Y below rule
function Add-ColHeading {
    param(
        [System.Windows.Forms.Control]$Col,
        [string]$Text,
        [int]$Top
    )
    $h           = New-Object System.Windows.Forms.Label
    $h.Text      = $Text
    $h.Left      = 0
    $h.Top       = $Top
    $h.Width     = $Col.Width
    $h.Height    = 22
    $h.Font      = $FONT_HEADING
    $h.ForeColor = $CLR_ACCENT
    $h.AutoSize  = $false
    $Col.Controls.Add($h)

    $sep           = New-Object System.Windows.Forms.Panel
    $sep.Left      = 0
    $sep.Top       = $Top + 24
    $sep.Width     = $Col.Width - 4
    $sep.Height    = 1
    $sep.BackColor = $CLR_ACCENT
    $Col.Controls.Add($sep)

    return ($Top + 34)
}

# New-WidgetPanel: creates colored-border widget with title bar.
# Returns hashtable: @{ Outer; Inner; Body; TitleLabel }
# Caller fills Body, then calls Resize-WidgetToFit.
function New-WidgetPanel {
    param(
        [System.Windows.Forms.Control]$Parent,
        [string]$Title,
        [string]$BadgeText,
        [System.Drawing.Color]$BorderColor,
        [System.Drawing.Color]$TitleBgColor,
        [System.Drawing.Color]$TitleFgColor,
        [int]$Top,
        [int]$Width,
        [int]$TitleHeight = 28
    )

    $BORDER   = 2
    $TITLE_H  = $TitleHeight
    $INIT_H   = 70

    $outer           = New-Object System.Windows.Forms.Panel
    $outer.Left      = 0
    $outer.Top       = $Top
    $outer.Width     = $Width
    $outer.Height    = ($BORDER + $TITLE_H + 1 + $INIT_H + $BORDER)
    $outer.BackColor = $BorderColor
    $Parent.Controls.Add($outer)

    $inner           = New-Object System.Windows.Forms.Panel
    $inner.Left      = $BORDER
    $inner.Top       = $BORDER
    $inner.Width     = ($Width - ($BORDER * 2))
    $inner.Height    = ($outer.Height - ($BORDER * 2))
    $inner.BackColor = [System.Drawing.Color]::White
    $outer.Controls.Add($inner)

    $titleBar           = New-Object System.Windows.Forms.Panel
    $titleBar.Left      = 0
    $titleBar.Top       = 0
    $titleBar.Width     = $inner.Width
    $titleBar.Height    = $TITLE_H
    $titleBar.BackColor = $TitleBgColor
    $inner.Controls.Add($titleBar)

    $titleW   = if ($BadgeText) { $inner.Width - 90 } else { $inner.Width - 16 }
    $titleLbl           = New-Object System.Windows.Forms.Label
    $titleLbl.Text      = $Title
    $titleLbl.Left      = 8
    $titleLbl.Top       = 0
    $titleLbl.Width     = $titleW
    $titleLbl.Height    = $TITLE_H
    $titleLbl.Font      = $FONT_WIDGET_TITLE
    $titleLbl.ForeColor = $TitleFgColor
    $titleLbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $titleLbl.AutoSize  = $false
    $titleBar.Controls.Add($titleLbl)

    if ($BadgeText) {
        $badge           = New-Object System.Windows.Forms.Label
        $badge.Text      = $BadgeText
        $badge.Font      = $FONT_TINY
        $badge.ForeColor = [System.Drawing.Color]::White
        $badge.BackColor = $BorderColor
        $badge.AutoSize  = $false
        $badge.Width     = 84
        $badge.Height    = ($TITLE_H - 8)
        $badge.Left      = ($inner.Width - 90)
        $badge.Top       = 4
        $badge.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $badge.MaximumSize = New-Object System.Drawing.Size(84, 60)
        $titleBar.Controls.Add($badge)
    }

    $sep           = New-Object System.Windows.Forms.Panel
    $sep.Left      = 0
    $sep.Top       = $TITLE_H
    $sep.Width     = $inner.Width
    $sep.Height    = 1
    $sep.BackColor = $BorderColor
    $inner.Controls.Add($sep)

    $body           = New-Object System.Windows.Forms.Panel
    $body.Left      = 0
    $body.Top       = ($TITLE_H + 1)
    $body.Width     = $inner.Width
    $body.Height    = $INIT_H
    $body.BackColor = [System.Drawing.Color]::White
    $inner.Controls.Add($body)

    return @{ Outer = $outer; Inner = $inner; Body = $body; TitleLabel = $titleLbl }
}

# Resize-WidgetToFit: resizes widget panels after body content is placed.
# contentBottom = Top + Height of last control in body (relative to body panel)
function Resize-WidgetToFit {
    param(
        [hashtable]$Widget,
        [int]$ContentBottom,
        [int]$BottomPad = 8
    )
    $BORDER  = 2
    # Derive actual title height from the body panel's Top offset within inner
    $TITLE_H = $Widget.Body.Top - 1
    if ($TITLE_H -le 0) { $TITLE_H = 28 }
    $bodyH   = $ContentBottom + $BottomPad
    $innerH  = ($TITLE_H + 1 + $bodyH)
    $outerH  = ($BORDER + $innerH + $BORDER)
    $Widget.Body.Height  = $bodyH
    $Widget.Inner.Height = $innerH
    $Widget.Outer.Height = $outerH
}

# Add-WidgetRow: label on left, bold value on right; returns new Y
function Add-WidgetRow {
    param(
        [System.Windows.Forms.Control]$Body,
        [string]$LabelText,
        [string]$ValueText,
        [System.Drawing.Color]$ValueColor,
        [int]$Top,
        [int]$RowHeight = 28,
        [System.Drawing.Color]$LabelColor = [System.Drawing.Color]::Empty
    )
    $lW = [int]($Body.Width * 0.58)
    $vW = $Body.Width - $lW - 16

    $resolvedLblClr = if (-not $LabelColor.IsEmpty) { $LabelColor } else { $CLR_SECONDARY }

    $lbl           = New-Object System.Windows.Forms.Label
    $lbl.Text      = $LabelText
    $lbl.Left      = 8
    $lbl.Top       = $Top
    $lbl.Width     = $lW
    $lbl.Height    = $RowHeight
    $lbl.Font      = $FONT_WIDGET_LABEL
    $lbl.ForeColor = $resolvedLblClr
    $lbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $lbl.AutoSize  = $false
    $Body.Controls.Add($lbl)

    $val           = New-Object System.Windows.Forms.Label
    $val.Text      = $ValueText
    $val.Left      = ($lW + 8)
    $val.Top       = $Top
    $val.Width     = $vW
    $val.Height    = $RowHeight
    $val.Font      = $FONT_WIDGET_BOLD
    $val.ForeColor = $ValueColor
    $val.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $val.AutoSize  = $false
    $Body.Controls.Add($val)

    return ($Top + $RowHeight)
}

# Add-WidgetDivider: thin grey rule inside a widget body; returns new Y
function Add-WidgetDivider {
    param([System.Windows.Forms.Control]$Body, [int]$Top)
    $div           = New-Object System.Windows.Forms.Panel
    $div.Left      = 8
    $div.Top       = ($Top + 3)
    $div.Width     = ($Body.Width - 16)
    $div.Height    = 1
    $div.BackColor = [System.Drawing.Color]::FromArgb(232, 232, 232)
    $Body.Controls.Add($div)
    return ($Top + 8)
}

# Add-WidgetMoreLink: right-aligned greyed link text; returns new Y
function Add-WidgetMoreLink {
    param([System.Windows.Forms.Control]$Body, [string]$Text, [int]$Top)
    $lnk           = New-Object System.Windows.Forms.Label
    $lnk.Text      = $Text
    $lnk.Left      = 8
    $lnk.Top       = ($Top + 2)
    $lnk.Width     = ($Body.Width - 16)
    $lnk.Height    = 14
    $lnk.Font      = $FONT_TINY
    $lnk.ForeColor = [System.Drawing.Color]::FromArgb(187, 187, 187)
    $lnk.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $lnk.AutoSize  = $false
    $Body.Controls.Add($lnk)
    return ($Top + 18)
}

# =============================================================================
# Dispose-PanelControls
# Recursively disposes all controls in a panel before clearing, preventing
# GDI handle leaks from repeated dashboard refreshes.
# =============================================================================
function Dispose-PanelControls {
    param([System.Windows.Forms.Control]$Panel)
    foreach ($ctrl in @($Panel.Controls)) {
        if ($ctrl.Controls.Count -gt 0) {
            Dispose-PanelControls -Panel $ctrl
        }
        # Dispose ToolTip if stored in Tag (set by New-ModeBtn to prevent GDI leak)
        if ($null -ne $ctrl.Tag -and $ctrl.Tag -is [System.Windows.Forms.ToolTip]) {
            try { $ctrl.Tag.Dispose() } catch {}
        }
        try { $ctrl.Dispose() } catch {}
    }
    $Panel.Controls.Clear()
}

# =============================================================================
# Show-ModuleLoadError
# Displays a module load failure with a selectable TextBox so the error
# text can be copied. Used instead of MessageBox for all module load failures.
# =============================================================================
function Show-ModuleLoadError {
    param(
        [string]$ModulePath,
        [string]$ErrorDetail
    )

    $ef = New-Object System.Windows.Forms.Form
    $ef.Text            = 'SecureRDP - Module Load Failure'
    $ef.Width           = 560
    $ef.Height          = 320
    $ef.FormBorderStyle = 'FixedDialog'
    $ef.MaximizeBox     = $false
    $ef.MinimizeBox     = $false
    $ef.StartPosition   = 'CenterScreen'
    $ef.BackColor       = [System.Drawing.Color]::White

    $hdr           = New-Object System.Windows.Forms.Panel
    $hdr.Dock      = 'Top'
    $hdr.Height    = 36
    $hdr.BackColor = [System.Drawing.Color]::FromArgb(170, 20, 10)
    $hl            = New-Object System.Windows.Forms.Label
    $hl.Text       = 'Module Load Failure'
    $hl.Font       = New-Object System.Drawing.Font('Calibri', 10, [System.Drawing.FontStyle]::Bold)
    $hl.ForeColor  = [System.Drawing.Color]::White
    $hl.Dock       = 'Fill'
    $hl.TextAlign  = 'MiddleLeft'
    $hl.Padding    = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
    $hdr.Controls.Add($hl)
    $ef.Controls.Add($hdr)

    $bb           = New-Object System.Windows.Forms.Panel
    $bb.Dock      = 'Bottom'
    $bb.Height    = 48
    $bb.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
    $bOk           = New-Object System.Windows.Forms.Button
    $bOk.Text      = 'OK'
    $bOk.Width     = 80
    $bOk.Height    = 28
    $bOk.Top       = 10
    $bOk.Left      = $bb.Width - 96
    $bOk.FlatStyle = 'Flat'
    $bOk.BackColor = [System.Drawing.Color]::White
    $bOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $bb.Controls.Add($bOk)
    $ef.Controls.Add($bb)
    $ef.AcceptButton = $bOk

    $pnl         = New-Object System.Windows.Forms.Panel
    $pnl.Dock    = 'Fill'
    $pnl.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 4)
    $ef.Controls.Add($pnl)

    $intro           = New-Object System.Windows.Forms.Label
    $intro.Text      = "SecureRDP could not load a required module:`n$ModulePath`n`nError detail (select all and copy with Ctrl+C):"
    $intro.Font      = New-Object System.Drawing.Font('Calibri', 8.5)
    $intro.ForeColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
    $intro.Dock      = 'Top'
    $intro.Height    = 58
    $intro.AutoSize  = $false
    $pnl.Controls.Add($intro)

    $tb              = New-Object System.Windows.Forms.TextBox
    $tb.Multiline    = $true
    $tb.ReadOnly     = $true
    $tb.ScrollBars   = 'Vertical'
    $tb.Dock         = 'Fill'
    $tb.Font         = New-Object System.Drawing.Font('Consolas', 8.5)
    $tb.BackColor    = [System.Drawing.Color]::FromArgb(250, 250, 250)
    $tb.BorderStyle  = 'FixedSingle'
    $tb.Text         = $ErrorDetail
    $pnl.Controls.Add($tb)

    # Ctrl+A selects all text in the error box
    $ef.KeyPreview = $true
    $ef.Add_KeyDown({
        param($s, $e)
        if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::A) {
            $tb.SelectAll()
            $e.Handled = $true
            $e.SuppressKeyPress = $true
        }
    })

    $ef.ShowDialog() | Out-Null
}

# =============================================================================
# New-ModeBtn: creates a small flat mode action button.
# Extracted from foreach loop to satisfy no-nested-function rule.
# =============================================================================
function New-ModeBtn {
    param(
        [string]$Text,
        [bool]$Enabled,
        [int]$X,
        [int]$Top,
        [int]$Height,
        [string]$Tip,
        [System.Drawing.Color]$Bg,
        [System.Drawing.Color]$Fg,
        [bool]$BorderOnly = $false,
        [bool]$Danger = $false
    )
    $mb           = New-Object System.Windows.Forms.Button
    $mb.Text      = $Text
    $mb.Left      = $X
    $mb.Top       = $Top
    $mb.Width     = [int]([System.Windows.Forms.TextRenderer]::MeasureText($Text, $FONT_TINY).Width + 18)
    $mb.Height    = $Height
    $mb.Font      = $FONT_TINY
    $mb.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $mb.Cursor    = [System.Windows.Forms.Cursors]::Hand
    if ($Enabled) {
        $mb.BackColor = [System.Drawing.Color]::White
        if ($Danger) {
            $mb.ForeColor = [System.Drawing.Color]::FromArgb(140, 18, 8)
            $mb.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(140, 18, 8)
            $mb.FlatAppearance.BorderSize  = 2
        } else {
            $mb.ForeColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
            $mb.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(130, 130, 130)
            $mb.FlatAppearance.BorderSize  = 1
        }
    } else {
        $mb.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
        $mb.ForeColor = [System.Drawing.Color]::FromArgb(187, 187, 187)
        $mb.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(221, 221, 221)
        $mb.FlatAppearance.BorderSize  = 1
        $mb.Enabled   = $false
    }
    $tt = New-Object System.Windows.Forms.ToolTip
    $tt.SetToolTip($mb, $Tip)
    $mb.Tag = $tt
    $tt.InitialDelay = 300
    $tt.ReshowDelay  = 100
    return $mb
}

# =============================================================================
# SHOW-MAINSCREEN
# Three-column dashboard. Loops until user clicks Exit.
# =============================================================================
function Show-MainScreen {


    $CLR_BG      = [System.Drawing.Color]::FromArgb(245, 245, 245)
    $CLR_ACCENT  = [System.Drawing.Color]::FromArgb(0, 60, 120)
    $CLR_WARN    = [System.Drawing.Color]::FromArgb(160, 60, 0)
    $CLR_ERROR   = [System.Drawing.Color]::FromArgb(160, 20, 10)
    $CLR_OK      = [System.Drawing.Color]::FromArgb(10, 110, 10)
    $CLR_DIMGRAY   = [System.Drawing.Color]::FromArgb(60, 60, 60)  # retained for widget fg fallback
    $CLR_SECONDARY = [System.Drawing.Color]::FromArgb(50, 50, 50)  # dark grey for label/hint text
    $CLR_SILVER  = [System.Drawing.Color]::FromArgb(160, 160, 160)

    # Widget border/title colors
    $CLR_BLUE_BORDER  = [System.Drawing.Color]::FromArgb(91,  155, 213)
    $CLR_BLUE_TITLE   = [System.Drawing.Color]::FromArgb(234, 242, 251)
    $CLR_BLUE_FG      = [System.Drawing.Color]::FromArgb(42,  96,  153)
    $CLR_GREEN_BORDER = [System.Drawing.Color]::FromArgb(26,  158, 58)
    $CLR_GREEN_TITLE  = [System.Drawing.Color]::FromArgb(234, 250, 240)
    $CLR_GREEN_FG     = [System.Drawing.Color]::FromArgb(26,  122, 46)
    $CLR_RED_TITLE    = [System.Drawing.Color]::FromArgb(253, 232, 230)
    $CLR_GREY_BORDER  = [System.Drawing.Color]::FromArgb(80, 80, 80)
    $CLR_GREY_TITLE   = [System.Drawing.Color]::FromArgb(232, 232, 232)
    $CLR_VAL_BLUE     = [System.Drawing.Color]::FromArgb(50,  110, 190)

    # Additional widget verdict colors
    $CLR_RED_BORDER   = [System.Drawing.Color]::FromArgb(192, 32,  14)
    $CLR_RED_BG       = [System.Drawing.Color]::FromArgb(253, 232, 230)
    $CLR_RED_FG       = [System.Drawing.Color]::FromArgb(160, 20,  10)
    $CLR_ORANGE_BORDER = [System.Drawing.Color]::FromArgb(210, 110, 20)
    $CLR_ORANGE_BG    = [System.Drawing.Color]::FromArgb(255, 243, 224)
    $CLR_ORANGE_FG    = [System.Drawing.Color]::FromArgb(170, 80,  10)
    $CLR_YELLOW_BORDER = [System.Drawing.Color]::FromArgb(180, 155, 20)
    $CLR_YELLOW_BG    = [System.Drawing.Color]::FromArgb(255, 252, 220)
    $CLR_YELLOW_FG    = [System.Drawing.Color]::FromArgb(100, 75,  0)
    $CLR_LGREEN_BORDER = [System.Drawing.Color]::FromArgb(80,  170, 80)
    $CLR_LGREEN_BG    = [System.Drawing.Color]::FromArgb(236, 252, 236)
    $CLR_LGREEN_FG    = [System.Drawing.Color]::FromArgb(40,  130, 40)

    # Create the persistent main window once -- it stays open throughout the session.
    $formH = [Math]::Min(820, [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height - 40)
    $ui    = New-SrdpForm "SecureRDP v. $SRDP_VER" $formH
    $script:MainForm    = $ui.Form
    $script:MainPanel   = $ui.Panel
    $script:MainBtnBar  = $ui.BtnBar
    $script:MainTitleBar = $ui.TitleBar

    # Add Refresh button to title bar -- right-aligned, created once
    $titleRefresh           = New-Object System.Windows.Forms.Button
    $titleRefresh.Text      = 'Refresh'
    $titleRefresh.Font      = New-Object System.Drawing.Font('Segoe UI', 9)
    $titleRefresh.Width     = 90
    $titleRefresh.Height    = 28
    $titleRefresh.Top       = 14
    $titleRefresh.Left      = $FORM_WIDTH - 90 - 14
    $titleRefresh.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $titleRefresh.BackColor = [System.Drawing.Color]::FromArgb(0, 82, 163)
    $titleRefresh.ForeColor = [System.Drawing.Color]::White
    $titleRefresh.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(60, 120, 200)
    $titleRefresh.FlatAppearance.BorderSize  = 1
    $titleRefresh.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $script:MainTitleBar.Controls.Add($titleRefresh)

    # & $rdHolder[0]: rebuilds all column content in place.
    # Called on first show and after any child window closes.
    $rdHolder = [object[]]@($null)  # reference container for GetNewClosure() self-reference
    $script:RefreshDashboard = {
        Dispose-PanelControls -Panel $script:MainPanel
        Dispose-PanelControls -Panel $script:MainBtnBar

        # Column layout
        $colGap    = 10
        $colLeftW  = 200
        $colRightW = 240
        $colMidW   = 510
        $colH      = 1100

        $colTopPad = 12
        $colLeft  = New-ColPanel $script:MainPanel 0                                              $colLeftW  $colH -Top $colTopPad
        $colMid   = New-ColPanel $script:MainPanel ($colLeftW + $colGap)                          $colMidW   $colH -Top $colTopPad
        $colRight = New-ColPanel $script:MainPanel ($colLeftW + $colGap + $colMidW + $colGap)     $colRightW $colH -Top $colTopPad

        # ---- Collect mode data ----
        $modes = Get-InstalledModes

        # ---- Pre-compute op states (avoids multiple module loads per mode per render) ----
        $opStates = @{}
        foreach ($mode in $modes) {
            $opStates[$mode.DirName] = Get-ModeOpState $mode
        }

        # ---- Compute install states ----
        $installStates  = @{}
        foreach ($mode in $modes) {
            $installStates[$mode.DirName] = Get-ModeInstallState $mode
        }
        $installedModes = @($modes | Where-Object { $installStates[$_.DirName] -ne 'available' })
        $availableModes = @($modes | Where-Object { $installStates[$_.DirName] -eq 'available' })

        # ---- Collect RDP status ----
        $rdpEnabled = Test-RdpEnabled
        $rdpPorts   = Get-RdpPorts

        # ---- Collect Widget 4 data ----
        $w4Groups    = Get-RdpGroupMembers
        $w4SecLayer  = Get-RdpSecurityLayer
        $w4CertExpiry = Get-RdpCertExpiry
        $w4NLA       = Test-NlaEnabled
        $w4SmartCard = Test-SmartCardRequired


        # ---- Collect firewall state ----
        $fwPortsFallback = $false
        $fwPortsForCheck = @(3389)
        if ($rdpPorts -is [hashtable] -and $rdpPorts.Result -eq 'ok') {
            $fwPortsArr = @($rdpPorts.Ports)
            if ($fwPortsArr.Count -gt 0) {
                $fwPortsForCheck = $fwPortsArr
            } else {
                $fwPortsFallback = $true
            }
        } else {
            $fwPortsFallback = $true
        }

        # Bug 24/25 fix: fwPortsFallback warning shown inline in widget, not as blocking dialog.
        # Suppressed entirely if RDP is disabled (expected state).

        $fwAssessment = Get-PortFirewallStatus -Ports $fwPortsForCheck
        if ($fwAssessment -is [string]) {
            $fwDiagError  = $fwAssessment
            $fwAssessment = $null
        } else {
            $fwDiagError = $null
        }

        # ---- Determine global lock state ----
        $anyInstalled = ($installedModes.Count -gt 0)
        $anyLocked    = $false
        $lockingModeShortName = 'Unknown'
        foreach ($mode in $modes) {
            $os = $opStates[$mode.DirName]
            if ($null -ne $os -and $os.LockStatus -eq 'locked') {
                $anyLocked = $true
                $rawName   = $mode.Name
                $lockingModeShortName = $rawName -replace '\s+Basic\s+Prototype\s+Mode$', '' `
                                                  -replace '\s+Prototype\s+Mode$', '' `
                                                  -replace '\s+Mode$', ''
                break
            }
        }

        # Close loading form now -- all data collected, rendering begins
        try {
            if ($null -ne $script:LoadingForm -and -not $script:LoadingForm.IsDisposed) {
                $script:LoadingForm.Close()
                $script:LoadingForm.Dispose()
                $script:LoadingForm = $null
            }
        } catch {
            $errMsg = $_.Exception.Message
            try { Write-SrdpLog "Loading form dispose failed: $errMsg" -Level WARN -Component 'ServerWizard' } catch {}
        }

        # =================================================================
        # LEFT COLUMN -- Quick Start tiles
        # =================================================================
        $ly = 33  # top spacer aligns with column heading baselines

        $qsModes = @($modes | Where-Object { $_.HasQuickStart })

        foreach ($qsMode in $qsModes) {
            # Detect QS tile state: available / phase1a_done / complete
            $qsStateFile = Join-Path $PSScriptRoot "InstalledModes\$($qsMode.DirName)\state.json"
            $qsTileState = 'available'
            if (Test-Path $qsStateFile) {
                try {
                    $qsSt = Get-Content $qsStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($null -ne $qsSt) {
                        $qsProps = $qsSt.PSObject.Properties.Name
                        # Check Phase 2 completion first
                        if ($qsProps -contains 'Phase2') {
                            try {
                                $p2Props = $qsSt.Phase2.PSObject.Properties.Name
                                if ($p2Props -contains 'Success' -and $qsSt.Phase2.Success -eq $true) {
                                    $qsTileState = 'complete'
                                }
                            } catch {}
                        }
                        # If not complete, check Phase 1a
                        if ($qsTileState -ne 'complete' -and
                            $qsProps -contains 'Engine1' -and $qsProps -contains 'Engine2') {
                            $e1Ok = ($null -ne $qsSt.Engine1 -and $qsSt.Engine1.Success -eq $true)
                            $e2Ok = ($null -ne $qsSt.Engine2 -and $qsSt.Engine2.Success -eq $true)
                            if ($e1Ok -and $e2Ok) {
                                $qsTileState = 'phase1a_done'
                            }
                        }
                        # Check for reboot-required (Engine1 done + reboot pending, Engine2 not run)
                        if ($qsTileState -eq 'available' -and $qsProps -contains 'Engine1') {
                            try {
                                if ($qsSt.Engine1.Success -eq $true) {
                                    $e1dProps = $qsSt.Engine1.Data.PSObject.Properties.Name
                                    if ($e1dProps -contains 'RequiresReboot' -and
                                        $qsSt.Engine1.Data.RequiresReboot -eq $true -and
                                        (-not ($qsProps -contains 'Engine2') -or $null -eq $qsSt.Engine2)) {
                                        $qsTileState = 'reboot_required'
                                    }
                                }
                            } catch {}
                        }
                    }
                } catch {
                    $errMsg = $_.Exception.Message
                    try { Write-SrdpLog "QS tile state read failed: $errMsg" -Level WARN -Component 'ServerWizard' } catch {}
                }
            }

            $tileH  = 120
            $tileW  = ($colLeftW - 4)

            $tile           = New-Object System.Windows.Forms.Panel
            $tile.Left      = 0
            $tile.Top       = $ly
            $tile.Width     = $tileW
            $tile.Height    = $tileH
            $tile.Cursor    = [System.Windows.Forms.Cursors]::Hand
            $colLeft.Controls.Add($tile)

            $tLine1 = $null
            $tLine2 = $null

            if ($qsTileState -eq 'available') {
                # Not yet installed: solid accent (blue) tile
                $tile.BackColor = $CLR_ACCENT

                $tLine1           = New-Object System.Windows.Forms.Label
                $tLine1.Text      = 'Quick Start'
                $tLine1.Font      = $FONT_QS_TITLE
                $tLine1.ForeColor = [System.Drawing.Color]::White
                $tLine1.BackColor = [System.Drawing.Color]::Transparent
                $tLine1.Left      = 10; $tLine1.Top = 10
                $tLine1.Width     = ($tileW - 16); $tLine1.Height = 24
                $tLine1.AutoSize  = $false
                $tile.Controls.Add($tLine1)

                $tDescText = if ($qsMode.QuickStartDesc) { $qsMode.QuickStartDesc } else { $qsMode.Name }
                $tLine2           = New-Object System.Windows.Forms.Label
                $tLine2.Text      = $tDescText
                $tLine2.Font      = $FONT_QS_DESC
                $tLine2.ForeColor = [System.Drawing.Color]::FromArgb(217, 217, 217)
                $tLine2.BackColor = [System.Drawing.Color]::Transparent
                $tLine2.Left      = 10; $tLine2.Top = 40
                $tLine2.Width     = ($tileW - 16); $tLine2.Height = 48
                $tLine2.AutoSize  = $false
                $tile.Controls.Add($tLine2)

            } elseif ($qsTileState -eq 'phase1a_done') {
                # Phase 1a done, Phase 2 needed: white tile with amber left border
                $tile.BackColor = [System.Drawing.Color]::White

                $amberBar           = New-Object System.Windows.Forms.Panel
                $amberBar.Left      = 0; $amberBar.Top = 0
                $amberBar.Width     = 4; $amberBar.Height = $tileH
                $amberBar.BackColor = [System.Drawing.Color]::FromArgb(232, 160, 0)
                $tile.Controls.Add($amberBar)

                $tKicker           = New-Object System.Windows.Forms.Label
                $tKicker.Text      = 'Quick Start'
                $tKicker.Font      = $FONT_QS_KICKER
                $tKicker.ForeColor = [System.Drawing.Color]::FromArgb(0, 50, 100)
                $tKicker.BackColor = [System.Drawing.Color]::Transparent
                $tKicker.Left      = 10; $tKicker.Top = 6
                $tKicker.AutoSize  = $true
                $tile.Controls.Add($tKicker)

                $tTitle           = New-Object System.Windows.Forms.Label
                $tTitle.Text      = 'Continue Quick Start'
                $tTitle.Font      = $FONT_QS_FINISH
                $tTitle.ForeColor = [System.Drawing.Color]::FromArgb(100, 55, 0)
                $tTitle.BackColor = [System.Drawing.Color]::Transparent
                $tTitle.Left      = 10; $tTitle.Top = 22
                $tTitle.Width     = ($tileW - 16); $tTitle.Height = 22
                $tTitle.AutoSize  = $false
                $tile.Controls.Add($tTitle)

                $tSub           = New-Object System.Windows.Forms.Label
                $tSub.Text      = 'Phase 1 complete. Click to configure firewall rules and security settings.'
                $tSub.Font      = $FONT_QS_SUB
                $tSub.ForeColor = [System.Drawing.Color]::FromArgb(80, 50, 0)
                $tSub.BackColor = [System.Drawing.Color]::Transparent
                $tSub.Left      = 10; $tSub.Top = 48
                $tSub.Width     = ($tileW - 16); $tSub.Height = 38
                $tSub.AutoSize  = $false
                $tile.Controls.Add($tSub)

            } elseif ($qsTileState -eq 'reboot_required') {
                # Reboot required: orange tile, no action
                $tile.BackColor = [System.Drawing.Color]::FromArgb(200, 80, 0)

                $tLine1           = New-Object System.Windows.Forms.Label
                $tLine1.Text      = 'Reboot Required'
                $tLine1.Font      = $FONT_QS_TITLE
                $tLine1.ForeColor = [System.Drawing.Color]::White
                $tLine1.BackColor = [System.Drawing.Color]::Transparent
                $tLine1.Left      = 10; $tLine1.Top = 10
                $tLine1.Width     = ($tileW - 16); $tLine1.Height = 24
                $tLine1.AutoSize  = $false
                $tile.Controls.Add($tLine1)

                $tLine2           = New-Object System.Windows.Forms.Label
                $tLine2.Text      = 'A system restart is needed before SSH setup can continue. Please restart and return to this screen.'
                $tLine2.Font      = $FONT_QS_DESC
                $tLine2.ForeColor = [System.Drawing.Color]::FromArgb(255, 210, 170)
                $tLine2.BackColor = [System.Drawing.Color]::Transparent
                $tLine2.Left      = 10; $tLine2.Top = 40
                $tLine2.Width     = ($tileW - 16); $tLine2.Height = 48
                $tLine2.AutoSize  = $false
                $tile.Controls.Add($tLine2)

            } else {
                # complete: green tile for client package creation
                $tile.BackColor = [System.Drawing.Color]::FromArgb(15, 120, 40)

                $tLine1           = New-Object System.Windows.Forms.Label
                $tLine1.Text      = 'Create Client Package'
                $tLine1.Font      = $FONT_QS_TITLE
                $tLine1.ForeColor = [System.Drawing.Color]::White
                $tLine1.BackColor = [System.Drawing.Color]::Transparent
                $tLine1.Left      = 10; $tLine1.Top = 10
                $tLine1.Width     = ($tileW - 16); $tLine1.Height = 24
                $tLine1.AutoSize  = $false
                $tile.Controls.Add($tLine1)

                $tLine2           = New-Object System.Windows.Forms.Label
                $tLine2.Text      = 'Generate an SSH key and connection package for a user.'
                $tLine2.Font      = $FONT_QS_DESC
                $tLine2.ForeColor = [System.Drawing.Color]::FromArgb(200, 240, 200)
                $tLine2.BackColor = [System.Drawing.Color]::Transparent
                $tLine2.Left      = 10; $tLine2.Top = 40
                $tLine2.Width     = ($tileW - 16); $tLine2.Height = 48
                $tLine2.AutoSize  = $false
                $tile.Controls.Add($tLine2)
            }

            # Capture path to the appropriate launcher based on tile state
            $capturedQsTileState = $qsTileState
            $capturedQsLauncher = switch ($qsTileState) {
                'available'    { Join-Path $PSScriptRoot 'QuickStart-Phase1a.ps1' }
                'phase1a_done' { Join-Path $PSScriptRoot 'QuickStart-Phase2.ps1' }
                'complete'     { Join-Path $PSScriptRoot 'ClientKeyWizard.ps1' }
                default        { $null }
            }
            $capturedRdHolderQs = $rdHolder
            $tileClickScript = {
                if ($capturedQsTileState -eq 'reboot_required') {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Please restart your computer, then return to this screen to continue setup.",
                        'SecureRDP - Reboot Required',
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
                    return
                }
                if ($null -eq $capturedQsLauncher -or -not (Test-Path $capturedQsLauncher)) {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Launcher not found:`n$capturedQsLauncher",
                        'SecureRDP',
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                    return
                }
                try {
                    $qsProc = Start-Process powershell.exe `
                        -ArgumentList "-ExecutionPolicy Bypass -STA -File `"$capturedQsLauncher`"" `
                        -Verb RunAs -PassThru
                    if ($null -ne $qsProc) {
                        while (-not $qsProc.HasExited) {
                            [System.Windows.Forms.Application]::DoEvents()
                            Start-Sleep -Milliseconds 100
                        }
                    }
                } catch {}
                & $capturedRdHolderQs[0]
            }.GetNewClosure()

            # Hover color depends on tile state
            $tileHoverColor = switch ($qsTileState) {
                'available'        { [System.Drawing.Color]::FromArgb(0, 82, 163) }
                'phase1a_done'     { [System.Drawing.Color]::FromArgb(255, 235, 180) }
                'reboot_required'  { [System.Drawing.Color]::FromArgb(220, 100, 20) }
                'complete'         { [System.Drawing.Color]::FromArgb(20, 140, 50) }
            }
            $tileNormalColor = switch ($qsTileState) {
                'available'        { $CLR_ACCENT }
                'phase1a_done'     { [System.Drawing.Color]::White }
                'reboot_required'  { [System.Drawing.Color]::FromArgb(200, 80, 0) }
                'complete'         { [System.Drawing.Color]::FromArgb(15, 120, 40) }
            }
            $tileEnterScript  = { $tile.BackColor = $tileHoverColor }.GetNewClosure()
            $tileLeaveScript  = { $tile.BackColor = $tileNormalColor }.GetNewClosure()

            # Wire click/hover to tile and all child controls.
            # Child labels consume mouse events -- must be wired or
            # tile appears unclickable.
            $allTileControls = @($tile) + @($tile.Controls)
            foreach ($ctrl in $allTileControls | Where-Object { $null -ne $_ }) {
                $ctrl.Add_Click($tileClickScript)
                $ctrl.Add_MouseEnter($tileEnterScript)
                $ctrl.Add_MouseLeave($tileLeaveScript)
            }

            $ly += ($tileH + 8)
        }

        # -----------------------------------------------------------------
        # REVERT TILE -- shown when SSHProto state.json exists
        # -----------------------------------------------------------------
        $revertStateFile = Join-Path $PSScriptRoot 'InstalledModes\SSHProto\state.json'
        $revertScript    = Join-Path $PSScriptRoot 'Modes\SSHProto\QuickStart\Revert_Phase1a.ps1'
        if ((Test-Path $revertStateFile) -and (Test-Path $revertScript)) {
            $rtileH  = 72
            $rtileW  = ($colLeftW - 4)
            $rtile           = New-Object System.Windows.Forms.Panel
            $rtile.Left      = 0
            $rtile.Top       = $ly
            $rtile.Width     = $rtileW
            $rtile.Height    = $rtileH
            $rtile.BackColor = [System.Drawing.Color]::FromArgb(120, 40, 0)
            $rtile.Cursor    = [System.Windows.Forms.Cursors]::Hand
            $colLeft.Controls.Add($rtile)

            $rl1           = New-Object System.Windows.Forms.Label
            $rl1.Text      = 'Revert SSH Prototype Mode'
            $rl1.Font      = $FONT_REVERT_TITLE
            $rl1.ForeColor = [System.Drawing.Color]::White
            $rl1.BackColor = [System.Drawing.Color]::Transparent
            $rl1.Left      = 10; $rl1.Top = 10
            $rl1.Width     = ($rtileW - 16); $rl1.Height = 22
            $rl1.AutoSize  = $false
            $rtile.Controls.Add($rl1)

            $rl2           = New-Object System.Windows.Forms.Label
            $rl2.Text      = 'Undo all Quick Start changes and restore previous server state.'
            $rl2.Font      = $FONT_QS_SUB
            $rl2.ForeColor = [System.Drawing.Color]::FromArgb(220, 180, 160)
            $rl2.BackColor = [System.Drawing.Color]::Transparent
            $rl2.Left      = 10; $rl2.Top = 36
            $rl2.Width     = ($rtileW - 16); $rl2.Height = 28
            $rl2.AutoSize  = $false
            $rtile.Controls.Add($rl2)

            $capturedRevertScript = $revertScript
            $capturedRdHolderRv   = $rdHolder
            $capturedRevertState  = Join-Path $PSScriptRoot "InstalledModes\SSHProto\state.json"
            $rtileClick = {
                try {
                    $pinfo2                 = New-Object System.Diagnostics.ProcessStartInfo
                    $pinfo2.FileName        = 'powershell.exe'
                    $revertStatePath = $capturedRevertState
                    $pinfo2.Arguments       = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$capturedRevertScript`" -StateFilePath `"$revertStatePath`""
                    $pinfo2.Verb            = 'runas'
                    $pinfo2.UseShellExecute = $true
                    $proc2 = [System.Diagnostics.Process]::Start($pinfo2)
                    while (-not $proc2.HasExited) {
                        [System.Windows.Forms.Application]::DoEvents()
                        Start-Sleep -Milliseconds 50
                    }
                } catch {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Could not launch Revert.`n`nError: $_",
                        'SecureRDP', [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                }
                # Always refresh dashboard after Revert exits.
                & $capturedRdHolderRv[0]
            }.GetNewClosure()

            $rtileNormal = [System.Drawing.Color]::FromArgb(120, 40, 0)
            $rtileHover  = [System.Drawing.Color]::FromArgb(160, 55, 0)
            $rtileEnter  = { $rtile.BackColor = $rtileHover }.GetNewClosure()
            $rtileLeave  = { $rtile.BackColor = $rtileNormal }.GetNewClosure()

            foreach ($ctrl in @($rtile, $rl1, $rl2)) {
                $ctrl.Add_Click($rtileClick)
                $ctrl.Add_MouseEnter($rtileEnter)
                $ctrl.Add_MouseLeave($rtileLeave)
            }

            $ly += ($rtileH + 8)
        }

        # =================================================================
        # CENTER COLUMN -- Installed Modes, Available Modes, other sections
        # =================================================================
        $my = Add-ColHeading $colMid 'Installed Modes' 0

        if ($installedModes.Count -eq 0) {
            $nm           = New-Object System.Windows.Forms.Label
            $nm.Text      = 'No Modes Currently Installed.'
            $nm.Left      = 0
            $nm.Top       = $my
            $nm.Width     = ($colMidW - 4)
            $nm.Font      = $FONT_NORMAL
            $nm.ForeColor = $CLR_SECONDARY
            $nm.AutoSize  = $true
            $colMid.Controls.Add($nm)
            $my += 24
        }

        foreach ($mode in $installedModes) {
            $os   = $opStates[$mode.DirName]
            $isOp = $false

            if ($null -eq $os) {
                $statusText  = '[!] Error -- operational check unavailable'
                $statusColor = $CLR_ERROR
            } else {
                switch ($os.LockStatus) {
                    'locked' {
                        $statusText  = '[+] Operational -- tunnel active, RDP locked'
                        $statusColor = $CLR_OK
                        $isOp        = $true
                    }
                    'partial' {
                        $statusText  = '[~] Partial -- ' + $os.Summary
                        $statusColor = $CLR_WARN
                    }
                    'reboot_required' {
                        $statusText  = '[!] Reboot required -- restart to complete SSH installation'
                        $statusColor = $CLR_WARN
                    }
                    default {
                        $statusText  = '[ ] Not operational -- ' + $os.Summary
                        $statusColor = $CLR_ERROR
                    }
                }
            }

            # Fixed row heights -- no AutoSize height tracking, no shadow panels
            $R_NAME   = 18   # mode name row
            $R_DESC   = 40   # description (fits ~2 wrapped lines at 8pt)
            $R_STATUS = 34   # status line (two wrapped lines at 12pt bold)
            $R_PORT   = 16   # port hint (SSHProto only)
            $R_BTNS   = 26   # button row
            $PAD_T    = 8    # top inner padding
            $PAD_B    = 8    # bottom inner padding
            $GAP      = 4    # gap between rows

            $showPort = ($mode.DirName -eq 'SSHProto' -and $isOp)
            $cardH = $PAD_T + $R_NAME + $GAP + $R_DESC + $GAP + $R_STATUS +
                     $(if ($showPort) { $GAP + $R_PORT } else { 0 }) +
                     $GAP + $R_BTNS + $PAD_B

            $cardW = ($colMidW - 4)

            $mCard             = New-Object System.Windows.Forms.Panel
            $mCard.Left        = 0
            $mCard.Top         = $my
            $mCard.Width       = $cardW
            $mCard.Height      = $cardH
            $mCard.BackColor   = [System.Drawing.Color]::FromArgb(240, 243, 248)
            $mCard.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
            $colMid.Controls.Add($mCard)

            # Left accent bar
            $mAccent           = New-Object System.Windows.Forms.Panel
            $mAccent.Left      = 0; $mAccent.Top = 0
            $mAccent.Width     = 3; $mAccent.Height = $cardH
            $mAccent.BackColor = $CLR_ACCENT
            $mCard.Controls.Add($mAccent)

            $cy = $PAD_T

            # Mode name
            $mnl           = New-Object System.Windows.Forms.Label
            $mnl.Text      = $mode.Name
            $mnl.Font      = $FONT_SMALL_BOLD
            $mnl.ForeColor = [System.Drawing.Color]::Black
            $mnl.Left      = 11
            $mnl.Top       = $cy
            $mnl.Width     = ($cardW - 18)
            $mnl.Height    = $R_NAME
            $mnl.AutoSize  = $false
            $mCard.Controls.Add($mnl)
            $cy += ($R_NAME + $GAP)

            # Description
            $mdl           = New-Object System.Windows.Forms.Label
            $mdl.Text      = $mode.Description
            $mdl.Font      = $FONT_SMALL
            $mdl.ForeColor = [System.Drawing.Color]::FromArgb(68, 68, 68)
            $mdl.Left      = 11
            $mdl.Top       = $cy
            $mdl.Width     = ($cardW - 18)
            $mdl.Height    = $R_DESC
            $mdl.AutoSize  = $false
            $mCard.Controls.Add($mdl)
            $cy += ($R_DESC + $GAP)

            # Status line
            $sl           = New-Object System.Windows.Forms.Label
            $sl.Text      = $statusText
            $sl.Font      = $FONT_SMALL_BOLD
            $sl.ForeColor = $statusColor
            $sl.Left      = 11
            $sl.Top       = $cy
            $sl.Width     = ($cardW - 18)
            $sl.Height    = $R_STATUS
            $sl.AutoSize  = $false
            $sl.MaximumSize = New-Object System.Drawing.Size(($cardW - 18), 60)
            $mCard.Controls.Add($sl)
            $cy += $R_STATUS

            # Port hint (SSHProto, operational only)
            if ($showPort) {
                $cy += $GAP
                # Read actual SSH port from state.json
                $ph22PortHint = 22
                $ph22State    = Join-Path $PSScriptRoot "InstalledModes\$($mode.DirName)\state.json"
                if (Test-Path $ph22State) {
                    try {
                        $ph22St = Get-Content $ph22State -Raw -Encoding UTF8 | ConvertFrom-Json
                        $ph22Props = $ph22St.PSObject.Properties.Name
                        if ($ph22Props -contains 'SshPort') { $ph22PortHint = [int]$ph22St.SshPort }
                        elseif ($ph22Props -contains 'Infrastructure' -and
                                $ph22St.Infrastructure.PSObject.Properties.Name -contains 'SshPort') {
                            $ph22PortHint = [int]$ph22St.Infrastructure.SshPort
                        }
                    } catch {}
                }
                $ph           = New-Object System.Windows.Forms.Label
                $ph.Text      = "port $ph22PortHint" 
                $ph.Font      = $FONT_TINY
                $ph.ForeColor = $CLR_SECONDARY
                $ph.Left      = 13
                $ph.Top       = $cy
                $ph.Width     = ($cardW - 20)
                $ph.Height    = $R_PORT
                $ph.AutoSize  = $false
                $mCard.Controls.Add($ph)
                $cy += $R_PORT
            }

            $cy += $GAP

            # Button row -- Stop, Start, Enhanced Security, Manage, Uninstall
            # Context-sensitive: Stop/Start enabled based on service state.
            # Enhanced Security and Manage always enabled when mode is installed.

            $capturedModeDirName  = $mode.DirName
            $capturedRdHolderMc  = $rdHolder
            $capturedModeDir      = $mode.DirPath
            $capturedManageScript = Join-Path $mode.DirPath 'QuickStart\Manage-SSHProto.ps1'
            $capturedRevertScript2 = Join-Path $mode.DirPath 'QuickStart\Revert_Phase1a.ps1'

            $modeSvcName  = 'SecureRDP-SSH'
            $modeSvcObj   = @(Get-Service -Name $modeSvcName -ErrorAction SilentlyContinue)
            $modeSvcRunning = ($modeSvcObj.Count -gt 0 -and $modeSvcObj[0].Status -eq 'Running')
            $modeSvcInstalled = ($modeSvcObj.Count -gt 0)

            $bx = 11

            $svcToggleText = if ($modeSvcRunning) { 'Stop' } else { 'Start' }
            $svcToggleTip  = if ($modeSvcRunning) { 'Stop the SSH tunnel service' } else { 'Start the SSH tunnel service' }
            $bSvcToggle = New-ModeBtn $svcToggleText $modeSvcInstalled $bx $cy $R_BTNS $svcToggleTip -Bg ([System.Drawing.Color]::White) -Fg ([System.Drawing.Color]::Black)
            $mCard.Controls.Add($bSvcToggle); $bx += $bSvcToggle.Width + 4

            # Manage -- enable when mode is installed
            $mgAvailable = (Test-Path $capturedManageScript)
            $bManage2 = New-ModeBtn 'Manage' $mgAvailable $bx $cy $R_BTNS $(if ($mgAvailable) { 'View and manage SSH keys and settings' } else { 'Not yet available' }) -Bg ([System.Drawing.Color]::White) -Fg ([System.Drawing.Color]::Black)
            $mCard.Controls.Add($bManage2); $bx += $bManage2.Width + 4

            $bUninstall2 = New-ModeBtn 'Uninstall' $true $bx $cy $R_BTNS 'Remove this mode and revert all changes' -Bg ([System.Drawing.Color]::White) -Fg ([System.Drawing.Color]::Black) -Danger $true
            $mCard.Controls.Add($bUninstall2)

            # Wire Stop/Start toggle
            $capturedSvcRunning = $modeSvcRunning
            $bSvcToggle.Add_Click({
                try {
                    if ($capturedSvcRunning) {
                        Stop-Service -Name $modeSvcName -Force -ErrorAction Stop
                        [System.Windows.Forms.MessageBox]::Show("$modeSvcName stopped.", 'SecureRDP',
                            [System.Windows.Forms.MessageBoxButtons]::OK,
                            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
                    } else {
                        Start-Service -Name $modeSvcName -ErrorAction Stop
                        [System.Windows.Forms.MessageBox]::Show("$modeSvcName started.", 'SecureRDP',
                            [System.Windows.Forms.MessageBoxButtons]::OK,
                            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
                    }
                } catch {
                    [System.Windows.Forms.MessageBox]::Show("Could not change service state: $_", 'SecureRDP',
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                }
                & $capturedRdHolderMc[0]
            }.GetNewClosure())

            $bManage2.Add_Click({
                if (Test-Path $capturedManageScript) {
                    $piMg               = New-Object System.Diagnostics.ProcessStartInfo
                    $piMg.FileName      = 'powershell.exe'
                    $piMg.Arguments     = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$capturedManageScript`""
                    $piMg.Verb          = 'runas'
                    $piMg.UseShellExecute = $true
                    $proc4 = [System.Diagnostics.Process]::Start($piMg)
                    while (-not $proc4.HasExited) {
                        [System.Windows.Forms.Application]::DoEvents()
                        Start-Sleep -Milliseconds 50
                    }
                    & $capturedRdHolderMc[0]
                }
            }.GetNewClosure())

            $bUninstall2.Add_Click({
                if (Test-Path $capturedRevertScript2) {
                    $piRv               = New-Object System.Diagnostics.ProcessStartInfo
                    $piRv.FileName      = 'powershell.exe'
                    $piRv.Arguments     = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$capturedRevertScript2`""
                    $piRv.Verb          = 'runas'
                    $piRv.UseShellExecute = $true
                    $proc5 = [System.Diagnostics.Process]::Start($piRv)
                    while (-not $proc5.HasExited) {
                        [System.Windows.Forms.Application]::DoEvents()
                        Start-Sleep -Milliseconds 50
                    }
                    & $capturedRdHolderMc[0]
                }
            }.GetNewClosure())

            $my += ($cardH + 10)
        }

        # ---- Available Modes section ----
        $my = Add-ColHeading $colMid 'Available Modes' ($my + 4)

        foreach ($avMode in $availableModes) {
            $avCardW = ($colMidW - 4)
            $avCard             = New-Object System.Windows.Forms.Panel
            $avCard.Left        = 0
            $avCard.Top         = $my
            $avCard.Width       = $avCardW
            $avCard.Height      = 150
            $avCard.BackColor   = [System.Drawing.Color]::FromArgb(240, 243, 248)
            $avCard.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
            $colMid.Controls.Add($avCard)

            # Left accent bar
            $avAccent           = New-Object System.Windows.Forms.Panel
            $avAccent.Left      = 0; $avAccent.Top = 0
            $avAccent.Width     = 3; $avAccent.Height = 150
            $avAccent.BackColor = $CLR_ACCENT
            $avCard.Controls.Add($avAccent)

            $avName           = New-Object System.Windows.Forms.Label
            $avName.Text      = $avMode.Name
            $avName.Font      = $FONT_SMALL_BOLD
            $avName.ForeColor = [System.Drawing.Color]::Black
            $avName.Left      = 11; $avName.Top = 10
            $avName.Width     = ($avCardW - 22); $avName.Height = 18
            $avName.AutoSize  = $false
            $avCard.Controls.Add($avName)

            $avDesc           = New-Object System.Windows.Forms.Label
            $avDesc.Text      = $avMode.Description
            $avDesc.Font      = $FONT_SMALL
            $avDesc.ForeColor = [System.Drawing.Color]::FromArgb(68, 68, 68)
            $avDesc.Left      = 11; $avDesc.Top = 32
            $avDesc.Width     = ($avCardW - 22); $avDesc.Height = 48
            $avDesc.AutoSize  = $false
            $avCard.Controls.Add($avDesc)

            $avBx = 11
            $CLR_BTN_PLAIN = [System.Drawing.Color]::White
            $CLR_BTN_DARK  = [System.Drawing.Color]::FromArgb(51, 51, 51)
            $CLR_BTN_BLUE  = [System.Drawing.Color]::FromArgb(0, 84, 166)

            # Install button
            $bInstall           = New-Object System.Windows.Forms.Button
            $bInstall.Text      = 'Install'
            $bInstall.Font      = $FONT_TINY
            $bInstall.Left      = $avBx; $bInstall.Top = 112
            $bInstall.Width     = [int]([System.Windows.Forms.TextRenderer]::MeasureText('Install', $FONT_TINY).Width + 14)
            $bInstall.Height    = 22
            $bInstall.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            $bInstall.BackColor = $CLR_BTN_BLUE
            $bInstall.ForeColor = [System.Drawing.Color]::White
            $bInstall.FlatAppearance.BorderSize = 0
            $bInstall.Cursor    = [System.Windows.Forms.Cursors]::Hand
            $avCard.Controls.Add($bInstall)
            $avBx += $bInstall.Width + 6

            # More Info button
            $bInfo           = New-Object System.Windows.Forms.Button
            $bInfo.Text      = 'More Info'
            $bInfo.Font      = $FONT_TINY
            $bInfo.Left      = $avBx; $bInfo.Top = 112
            $bInfo.Width     = [int]([System.Windows.Forms.TextRenderer]::MeasureText('More Info', $FONT_TINY).Width + 14)
            $bInfo.Height    = 22
            $bInfo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            $bInfo.BackColor = $CLR_BTN_PLAIN
            $bInfo.ForeColor = $CLR_BTN_DARK
            $bInfo.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(170, 170, 170)
            $bInfo.FlatAppearance.BorderSize  = 1
            $bInfo.Cursor    = [System.Windows.Forms.Cursors]::Hand
            $avCard.Controls.Add($bInfo)

            # Wire Install button
            $capturedAvQsLauncher = Join-Path $PSScriptRoot 'QuickStart-Phase1a.ps1'
            $capturedRdHolderAv = $rdHolder
            $bInstall.Add_Click({
                if (-not (Test-Path $capturedAvQsLauncher)) {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Quick Start launcher not found:`n$capturedAvQsLauncher",
                        'SecureRDP',
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                    return
                }
                try {
                    $avProc = Start-Process powershell.exe `
                        -ArgumentList "-ExecutionPolicy Bypass -STA -File `"$capturedAvQsLauncher`"" `
                        -Verb RunAs -PassThru
                    if ($null -ne $avProc) {
                        while (-not $avProc.HasExited) {
                            [System.Windows.Forms.Application]::DoEvents()
                            Start-Sleep -Milliseconds 100
                        }
                    }
                } catch {}
                # Refresh dashboard after wizard exits
                & $capturedRdHolderAv[0]
            }.GetNewClosure())

            # Wire More Info button
            $capturedAvName = $avMode.Name
            $capturedAvDesc = $avMode.Description
            $bInfo.Add_Click({
                $infoMsg  = "$capturedAvName`r`n`r`n"
                $infoMsg += "$capturedAvDesc`r`n`r`n"
                $infoMsg += "This mode secures RDP by routing all connections through an SSH tunnel "
                $infoMsg += "using public key authentication. Direct RDP access from the network is "
                $infoMsg += "blocked. Remote users connect via an encrypted SSH tunnel, then RDP "
                $infoMsg += "to localhost through that tunnel.`r`n`r`n"
                $infoMsg += "Click Install to run the Quick Start wizard and configure this mode."
                [System.Windows.Forms.MessageBox]::Show(
                    $infoMsg,
                    'SecureRDP - Mode Information',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            }.GetNewClosure())

            $my += (150 + 8)
        }

        $repoNote           = New-Object System.Windows.Forms.Label
        $repoNote.Text      = '(leave your feedback/ideas in the Issues portion of the repo)'
        $repoNote.Font      = $FONT_REPO_NOTE
        $repoNote.ForeColor = [System.Drawing.Color]::FromArgb(170, 170, 170)
        $repoNote.Left      = 2
        $repoNote.Top       = $my
        $repoNote.Width     = ($colMidW - 8)
        $repoNote.AutoSize  = $true
        $colMid.Controls.Add($repoNote)
        $my += ($repoNote.Height + 8)

        # ---- Client / User Management section ----
        $my = Add-ColHeading $colMid 'Client / User Management' ($my + 6)

        $csLbl1           = New-Object System.Windows.Forms.Label
        $csLbl1.Text      = 'Coming in v0.9'
        $csLbl1.Font      = $FONT_SMALL_BOLD
        $csLbl1.ForeColor = [System.Drawing.Color]::Black
        $csLbl1.Left      = 2
        $csLbl1.Top       = $my
        $csLbl1.AutoSize  = $true
        $colMid.Controls.Add($csLbl1)
        $my += ($csLbl1.Height + 8)

        # ---- Enhanced Security panel ----
        $my = Add-ColHeading $colMid 'Enhanced Security' ($my + 6)

        # Live ES status
        $esPanelRdpBlocked = $false
        $esPanelLoopEnabled = $false
        try {
            $esPanelRdpTcp = Get-NetFirewallRule -Name 'SecureRDP-RDP-BlockDirect' -ErrorAction SilentlyContinue
            $esPanelRdpUdp = Get-NetFirewallRule -Name 'SecureRDP-RDP-BlockDirect-UDP' -ErrorAction SilentlyContinue
            $esPanelRdpBlocked = ($null -ne $esPanelRdpTcp -and $esPanelRdpTcp.Enabled -eq 'True') -and
                                 ($null -ne $esPanelRdpUdp -and $esPanelRdpUdp.Enabled -eq 'True')
        } catch {}
        try {
            $esPanelWsPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
            $esPanelLan = (Get-ItemProperty $esPanelWsPath -Name 'LanAdapter' -ErrorAction SilentlyContinue).LanAdapter
            if ($null -ne $esPanelLan -and $esPanelLan -ne 0) {
                $esPanelLoop = Get-NetIPAddress -IPAddress '127.0.0.1' -ErrorAction SilentlyContinue
                $esPanelLoopEnabled = ($null -ne $esPanelLoop -and [int]$esPanelLan -eq [int]$esPanelLoop.InterfaceIndex)
            }
        } catch {}

        $esOverall = if ($esPanelRdpBlocked -and $esPanelLoopEnabled) { 'Full' } `
                     elseif ($esPanelRdpBlocked -or $esPanelLoopEnabled) { 'Partial' } `
                     else { 'None' }
        $esOverallColor = if ($esOverall -eq 'Full') { $CLR_OK } elseif ($esOverall -eq 'Partial') { $CLR_WARN } else { $CLR_ERROR }
        $esOverallText  = if ($esOverall -eq 'Full') { 'Full -- RDP block and listener restriction active' } `
                          elseif ($esOverall -eq 'Partial') { 'Partial -- not all restrictions applied' } `
                          else { 'None -- direct RDP is not restricted' }
        $esRdpText  = if ($esPanelRdpBlocked) { 'Enabled' } else { 'Disabled / not configured' }
        $esLoopText = if ($esPanelLoopEnabled) { 'Applied' } else { 'Not applied' }

        $esStatusLbl           = New-Object System.Windows.Forms.Label
        $esStatusLbl.Text      = $esOverallText
        $esStatusLbl.Font      = $FONT_SMALL_BOLD
        $esStatusLbl.ForeColor = $esOverallColor
        $esStatusLbl.Left      = 2; $esStatusLbl.Top = $my
        $esStatusLbl.Width     = ($colMidW - 8); $esStatusLbl.AutoSize = $true
        $colMid.Controls.Add($esStatusLbl)
        $my += ($esStatusLbl.Height + 2)

        $esDetailLbl           = New-Object System.Windows.Forms.Label
        $esDetailLbl.Text      = "RDP block rules: $esRdpText   |   Listener restriction: $esLoopText"
        $esDetailLbl.Font      = $FONT_SMALL
        $esDetailLbl.ForeColor = $CLR_SECONDARY
        $esDetailLbl.Left      = 2; $esDetailLbl.Top = $my
        $esDetailLbl.Width     = ($colMidW - 8); $esDetailLbl.AutoSize = $true
        $colMid.Controls.Add($esDetailLbl)
        $my += ($esDetailLbl.Height + 8)

        $esScriptPath   = Join-Path $PSScriptRoot 'EnhancedSecurity.ps1'
        $esAvailableNav = Test-Path $esScriptPath
        $bEsNav              = New-Object System.Windows.Forms.Button
        $bEsNav.Text         = 'Configure Enhanced Security...'
        $bEsNav.Left         = 2; $bEsNav.Top = $my
        $bEsNav.Width        = 240; $bEsNav.Height = 28
        $bEsNav.Font         = $FONT_SMALL_BOLD
        $bEsNav.FlatStyle    = [System.Windows.Forms.FlatStyle]::Flat
        $bEsNav.Cursor       = [System.Windows.Forms.Cursors]::Hand
        if ($esAvailableNav) {
            $bEsNav.BackColor = $CLR_ACCENT
            $bEsNav.ForeColor = [System.Drawing.Color]::White
            $bEsNav.FlatAppearance.BorderSize = 0
        } else {
            $bEsNav.BackColor = [System.Drawing.Color]::FromArgb(210, 210, 210)
            $bEsNav.ForeColor = [System.Drawing.Color]::FromArgb(140, 140, 140)
            $bEsNav.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(190, 190, 190)
            $bEsNav.Enabled = $false
        }
        $colMid.Controls.Add($bEsNav)
        $my += ($bEsNav.Height + 14)

        if ($esAvailableNav) {
            $capturedEsNavScript = $esScriptPath
            $capturedRdHolderEs  = $rdHolder
            $bEsNav.Add_Click({
                try {
                    $piEsNav               = New-Object System.Diagnostics.ProcessStartInfo
                    $piEsNav.FileName      = 'powershell.exe'
                    $piEsNav.Arguments     = "-ExecutionPolicy Bypass -STA -File `"$capturedEsNavScript`""
                    $piEsNav.Verb          = 'runas'
                    $piEsNav.UseShellExecute = $true
                    $proc5 = [System.Diagnostics.Process]::Start($piEsNav)
                    while (-not $proc5.HasExited) {
                        [System.Windows.Forms.Application]::DoEvents()
                        Start-Sleep -Milliseconds 50
                    }
                    & $capturedRdHolderEs[0]
                } catch {
                    [System.Windows.Forms.MessageBox]::Show("Could not launch Enhanced Security.`n`n$_",
                        'SecureRDP', [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                }
            }.GetNewClosure())
        }

        # ---- Version / build info block ----
        $my += 8
        $verBlock           = New-Object System.Windows.Forms.Label
        $verBlock.Text      = "SecureRDP version $SRDP_VER -- initial public release`r`nPlease file bug reports and feedback at`r`ngithub.com/arekfurt/SecureRDP"
        $verBlock.Font      = $FONT_SMALL_BOLD
        $verBlock.ForeColor = [System.Drawing.Color]::FromArgb(0, 60, 140)
        $verBlock.Left      = 2; $verBlock.Top = $my
        $verBlock.Width     = ($colMidW - 8)
        $verBlock.MaximumSize = New-Object System.Drawing.Size(($colMidW - 8), 200)
        $verBlock.AutoSize  = $true
        $colMid.Controls.Add($verBlock)
        $my += ($verBlock.Height + 8)

        # =================================================================
        # RIGHT COLUMN -- Four status widgets
        # =================================================================
        $ry      = 0
        $widgetW = ($colRightW - 4)

        # ---- Widget 1: RDP Status ----
        $rdpIsOn  = ($rdpEnabled -eq 'enabled')
        $rdpError = ($rdpEnabled -like 'error:*')

        if ($rdpIsOn -and (-not $rdpError)) {
            $w1Bc = $CLR_BLUE_BORDER
            $w1Bg = $CLR_BLUE_TITLE
            $w1Fg = $CLR_BLUE_FG
        } else {
            $w1Bc = $CLR_GREY_BORDER
            $w1Bg = $CLR_GREY_TITLE
            $w1Fg = $CLR_DIMGRAY
        }

        $w1 = New-WidgetPanel $colRight 'RDP Status' '' $w1Bc $w1Bg $w1Fg $ry $widgetW
        $wb = $w1.Body
        $by = 8

        $svcText  = switch ($rdpEnabled) {
            'enabled'  { 'On'      }
            'disabled' { 'Off'     }
            default    { 'Unknown' }
        }
        $svcColor = switch ($rdpEnabled) {
            'enabled'  { $CLR_OK    }
            'disabled' { $CLR_ERROR }
            default    { $CLR_WARN  }
        }
        $by = Add-WidgetRow $wb 'Service' $svcText $svcColor $by

        $portsText  = 'Unknown'
        $portsColor = $CLR_WARN
        if ($rdpPorts -is [hashtable] -and $rdpPorts.Result -eq 'ok') {
            $portsArr = @($rdpPorts.Ports)
            if ($portsArr.Count -gt 0) {
                $portsText  = $portsArr -join ', '
                $portsColor = $CLR_ACCENT
            } else {
                $portsText  = 'None found'
                $portsColor = $CLR_WARN
            }
        } elseif ($rdpEnabled -eq 'disabled') {
            $portsText  = 'N/A'
            $portsColor = $CLR_SECONDARY
        }
        $by = Add-WidgetRow $wb 'Port(s)' $portsText $portsColor $by
        $by = Add-WidgetMoreLink $wb 'more (TODO)' $by
        Resize-WidgetToFit $w1 $by
        $ry += ($w1.Outer.Height + 8)

        # ---- Widget 5: Attack Exposure (Active) ----
        $widgetState = Get-SrdpIniValue -Path $CONFIG_FILE -Section 'AttackExposure' -Key 'WidgetState'
        if ($null -eq $widgetState) { $widgetState = 'offline' }

        if ($widgetState -eq 'offline') {
            # Offline: grey widget with Enable button
            $w5Bc = [System.Drawing.Color]::FromArgb(130, 130, 130)
            $w5Bg = [System.Drawing.Color]::FromArgb(200, 200, 200)
            $w5Fg = [System.Drawing.Color]::FromArgb(80, 80, 80)
            $w5 = New-WidgetPanel $colRight 'Attack Exposure' 'Offline' $w5Bc $w5Bg $w5Fg $ry $widgetW -TitleHeight 44
            $wb5 = $w5.Body; $by5 = 8

            $w5Desc           = New-Object System.Windows.Forms.Label
            $w5Desc.Text      = 'SecureRDP can monitor Windows Event Log 261 to detect if your RDP port is receiving connections from public internet addresses. No IP addresses are stored or displayed.'
            $w5Desc.Font      = $FONT_WIDGET_LABEL
            $w5Desc.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
            $w5Desc.Left      = 8; $w5Desc.Top = $by5
            $w5Desc.Width     = ($widgetW - 20)
            $w5Desc.MaximumSize = New-Object System.Drawing.Size(($widgetW - 20), 200)
            $w5Desc.AutoSize  = $true
            $wb5.Controls.Add($w5Desc)
            $by5 += $w5Desc.PreferredHeight + 8

            $w5BtnEnable              = New-Object System.Windows.Forms.Button
            $w5BtnEnable.Text         = 'Enable Monitoring'
            $w5BtnEnable.Width        = ($widgetW - 32)
            $w5BtnEnable.Height       = 30
            $w5BtnEnable.Left         = 8; $w5BtnEnable.Top = $by5
            $w5BtnEnable.FlatStyle    = [System.Windows.Forms.FlatStyle]::Flat
            $w5BtnEnable.BackColor    = $CLR_ACCENT
            $w5BtnEnable.ForeColor    = [System.Drawing.Color]::White
            $w5BtnEnable.Font         = $FONT_WIDGET_BOLD
            $w5BtnEnable.FlatAppearance.BorderSize = 0
            $w5BtnEnable.Cursor       = [System.Windows.Forms.Cursors]::Hand
            $wb5.Controls.Add($w5BtnEnable)
            $by5 += 38

            $capturedConfigFile = $CONFIG_FILE
            $capturedRdHolderW5 = $rdHolder
            $w5BtnEnable.Add_Click({
                $confirmMsg = "SecureRDP will enable the Windows Event Log for RDP connection monitoring (Event 261).`n`n" +
                              "This analyzes connection metadata from the last 72 hours to detect public internet exposure. " +
                              "No IP addresses are stored or displayed -- only a safe/exposed verdict is shown.`n`n" +
                              "If this log is already enabled on your system, your existing configuration will not be changed.`n`n" +
                              "Enable exposure monitoring?"
                $confirmResult = [System.Windows.Forms.MessageBox]::Show(
                    $confirmMsg,
                    'SecureRDP - Enable Attack Exposure Monitoring',
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Question)
                if ($confirmResult -eq [System.Windows.Forms.DialogResult]::Yes) {
                    $setupResult = Invoke-SrdpEvent261Setup
                    Set-SrdpIniValue -Path $capturedConfigFile -Section 'AttackExposure' -Key 'WidgetState' -Value $setupResult
                    & $capturedRdHolderW5[0]
                }
            }.GetNewClosure())

        } elseif ($widgetState -eq 'error') {
            # Error state
            $w5Bc = [System.Drawing.Color]::FromArgb(160, 40, 40)
            $w5Bg = [System.Drawing.Color]::FromArgb(255, 240, 240)
            $w5Fg = [System.Drawing.Color]::FromArgb(120, 20, 20)
            $w5 = New-WidgetPanel $colRight 'Attack Exposure' 'Error' $w5Bc $w5Bg $w5Fg $ry $widgetW -TitleHeight 44
            $wb5 = $w5.Body; $by5 = 8

            $w5Err           = New-Object System.Windows.Forms.Label
            $w5Err.Text      = 'Could not initialize event log monitoring. Verify this application is running with Administrator rights and that the TerminalServices event log is accessible.'
            $w5Err.Font      = $FONT_WIDGET_LABEL
            $w5Err.ForeColor = [System.Drawing.Color]::FromArgb(140, 20, 20)
            $w5Err.Left      = 8; $w5Err.Top = $by5
            $w5Err.Width     = ($widgetW - 20)
            $w5Err.MaximumSize = New-Object System.Drawing.Size(($widgetW - 20), 200)
            $w5Err.AutoSize  = $true
            $wb5.Controls.Add($w5Err)
            $by5 += $w5Err.PreferredHeight + 8

        } else {
            # Active states: enabled-new or enabled-preexisting
            $verdict = Get-SrdpAttackExposureVerdict

            if ($verdict -eq $true) {
                # Exposed
                $w5Bc = [System.Drawing.Color]::FromArgb(180, 30, 30)
                $w5Bg = [System.Drawing.Color]::FromArgb(255, 235, 235)
                $w5Fg = [System.Drawing.Color]::White
                $w5Badge = 'EXPOSED'
            } elseif ($verdict -eq $false) {
                # Safe
                $w5Bc = $CLR_GREEN_BORDER
                $w5Bg = [System.Drawing.Color]::FromArgb(235, 255, 235)
                $w5Fg = [System.Drawing.Color]::White
                $w5Badge = 'No Exposure'
            } else {
                # Engine error
                $w5Bc = [System.Drawing.Color]::FromArgb(130, 130, 130)
                $w5Bg = [System.Drawing.Color]::FromArgb(245, 245, 245)
                $w5Fg = [System.Drawing.Color]::FromArgb(80, 80, 80)
                $w5Badge = 'Check Failed'
            }

            $w5 = New-WidgetPanel $colRight 'Attack Exposure' $w5Badge $w5Bc $w5Bg $w5Fg $ry $widgetW -TitleHeight 44
            $wb5 = $w5.Body; $by5 = 8

            if ($verdict -eq $true) {
                $w5Status           = New-Object System.Windows.Forms.Label
                $w5Status.Text      = 'WARNING: Public internet exposure detected in the last 72 hours.'
                $w5Status.Font      = $FONT_WIDGET_TITLE
                $w5Status.ForeColor = [System.Drawing.Color]::FromArgb(160, 20, 10)
                $w5Status.Left      = 8; $w5Status.Top = $by5
                $w5Status.Width     = ($widgetW - 20)
                $w5Status.MaximumSize = New-Object System.Drawing.Size(($widgetW - 20), 200)
                $w5Status.AutoSize  = $true
                $wb5.Controls.Add($w5Status)
                $by5 += $w5Status.PreferredHeight + 8
            } elseif ($verdict -eq $false) {
                $w5Status           = New-Object System.Windows.Forms.Label
                $w5Status.Text      = 'No public internet exposure detected in the last 72 hours. All RDP connections originated from private or loopback addresses.'
                $w5Status.Font      = $FONT_WIDGET_LABEL
                $w5Status.ForeColor = [System.Drawing.Color]::FromArgb(10, 100, 10)
                $w5Status.Left      = 8; $w5Status.Top = $by5
                $w5Status.Width     = ($widgetW - 20)
                $w5Status.MaximumSize = New-Object System.Drawing.Size(($widgetW - 20), 200)
                $w5Status.AutoSize  = $true
                $wb5.Controls.Add($w5Status)
                $by5 += $w5Status.PreferredHeight + 8
            } else {
                $w5Status           = New-Object System.Windows.Forms.Label
                $w5Status.Text      = 'The exposure check encountered an error. Check the log for details.'
                $w5Status.Font      = $FONT_WIDGET_LABEL
                $w5Status.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 100)
                $w5Status.Left      = 8; $w5Status.Top = $by5
                $w5Status.Width     = ($widgetW - 20)
                $w5Status.MaximumSize = New-Object System.Drawing.Size(($widgetW - 20), 200)
                $w5Status.AutoSize  = $true
                $wb5.Controls.Add($w5Status)
                $by5 += $w5Status.PreferredHeight + 8
            }

            if ($widgetState -eq 'enabled-preexisting') {
                $w5Note           = New-Object System.Windows.Forms.Label
                $w5Note.Text      = '(Using existing system log configuration)'
                $w5Note.Font      = $FONT_SMALL
                $w5Note.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
                $w5Note.Left      = 8; $w5Note.Top = $by5
                $w5Note.AutoSize  = $true
                $wb5.Controls.Add($w5Note)
                $by5 += $w5Note.PreferredHeight + 4
            }
        }

        Resize-WidgetToFit $w5 $by5
        $ry += ($w5.Outer.Height + 8)


        # ---- Widget 2: SecureRDP ----
        if ($anyLocked) {
            $w2Bc     = $CLR_GREEN_BORDER
            $w2Bg     = $CLR_GREEN_TITLE
            $w2Fg     = $CLR_GREEN_FG
            $w2Badge  = 'Locked'
        } elseif ($anyInstalled) {
            $w2Bc     = $CLR_ERROR
            $w2Bg     = $CLR_RED_TITLE
            $w2Fg     = $CLR_ERROR
            $w2Badge  = ''
        } else {
            $w2Bc     = $CLR_GREY_BORDER
            $w2Bg     = $CLR_GREY_TITLE
            $w2Fg     = $CLR_DIMGRAY
            $w2Badge  = 'No modes'
        }

        $w2 = New-WidgetPanel $colRight 'SRDP Mode Statuses' $w2Badge $w2Bc $w2Bg $w2Fg $ry $widgetW -TitleHeight 44
        $wb = $w2.Body
        $by = 8

        if ($anyInstalled) {
            $firstModeRow = $true
            foreach ($mode in $modes) {
                $os2   = $opStates[$mode.DirName]
                $isOp2 = $false

                if ($null -eq $os2) {
                    $mValText  = 'Error'
                    $mValColor = $CLR_ERROR
                } else {
                    switch ($os2.LockStatus) {
                        'locked'  { $mValText = 'Operational';     $mValColor = $CLR_OK;    $isOp2 = $true  }
                        'partial' { $mValText = 'Partial';         $mValColor = $CLR_WARN              }
                        default   { $mValText = 'Not operational'; $mValColor = $CLR_ERROR             }
                    }
                }

                $shortName = $mode.Name -replace '\s+Basic\s+Prototype\s+Mode$', '' `
                                        -replace '\s+Prototype\s+Mode$', '' `
                                        -replace '\s+Mode$', ''

                if (-not $firstModeRow) { $by = Add-WidgetDivider $wb $by }
                $firstModeRow = $false

                # Mode name (small bold label)
                $mnw           = New-Object System.Windows.Forms.Label
                $mnw.Text      = $shortName
                $mnw.Font      = $FONT_WIDGET_BOLD
                $mnw.ForeColor = [System.Drawing.Color]::Black
                $mnw.Left      = 8; $mnw.Top = $by; $mnw.AutoSize = $true
                $wb.Controls.Add($mnw)
                $by += 22

                # Operational status row
                $by = Add-WidgetRow $wb 'Status:' $mValText $mValColor $by

                # Port hint for SSHProto
                if ($mode.DirName -eq 'SSHProto' -and $isOp2) {
                    $sshPortHint = 22
                    $sshStateF = Join-Path $PSScriptRoot "InstalledModes\SSHProto\state.json"
                    if (Test-Path $sshStateF) {
                        try {
                            $sshSt = Get-Content $sshStateF -Raw -Encoding UTF8 | ConvertFrom-Json
                            $sshStProps = $sshSt.PSObject.Properties.Name
                            if ($sshStProps -contains 'Infrastructure' -and $null -ne $sshSt.Infrastructure -and
                                $sshSt.Infrastructure.PSObject.Properties.Name -contains 'SshPort') {
                                $sshPortHint = [int]$sshSt.Infrastructure.SshPort
                            } elseif ($sshStProps -contains 'SshPort') {
                                $sshPortHint = [int]$sshSt.SshPort
                            }
                        } catch {
                            try { Write-SrdpLog "SSH port hint read failed: $($_.Exception.Message)" -Level WARN -Component 'ServerWizard' } catch {}
                        }
                    }
                    $ph2           = New-Object System.Windows.Forms.Label
                    $ph2.Text      = "SSH port $sshPortHint"
                    $ph2.Font      = $FONT_PORT_HINT
                    $ph2.ForeColor = $CLR_SECONDARY
                    $ph2.Left      = 8; $ph2.Top = $by; $ph2.AutoSize = $true
                    $wb.Controls.Add($ph2)
                    $by += 26

                    # SSH firewall row -- one-word verdict for SSH port
                    $sshFwVerdict = Get-PortFirewallStatus -Ports @($sshPortHint)
                    $sshFwText  = 'Unknown'
                    $sshFwColor = $CLR_SECONDARY
                    if ($sshFwVerdict -isnot [string]) {
                        $sshFwText  = switch ($sshFwVerdict.Verdict) {
                            'red'    { 'Internet' }
                            'orange' { 'Internet' }
                            'yellow' { 'Private'  }
                            'green'  { 'Blocked'  }
                            'lgreen' { 'Blocked'  }
                            'blue'   { 'Blocked'  }
                            default  { 'Unknown'  }
                        }
                        $sshFwColor = switch ($sshFwVerdict.Verdict) {
                            'red'    { $CLR_ERROR    }
                            'orange' { $CLR_WARN     }
                            'yellow' { $CLR_WARN     }
                            'green'  { $CLR_OK       }
                            'lgreen' { $CLR_OK       }
                            'blue'   { $CLR_OK       }
                            default  { $CLR_SECONDARY }
                        }
                    }
                    $by = Add-WidgetRow $wb 'SSH Firewall:' $sshFwText $sshFwColor $by
                }

                # Enhanced Security status row
                $esW2Status = 'Unknown'
                $esW2Color  = $CLR_SECONDARY
                if ($mode.DirName -eq 'SSHProto') {
                    $blockW2 = $false; $loopW2 = $false
                    try {
                        $brW2 = Get-NetFirewallRule -Name 'SecureRDP-RDP-BlockDirect' -ErrorAction SilentlyContinue
                        $blockW2 = ($null -ne $brW2 -and $brW2.Enabled -eq $true)
                    } catch {
                        try { Write-SrdpLog "Block rule query failed: $($_.Exception.Message)" -Level WARN -Component 'ServerWizard' } catch {}
                    }
                    try {
                        $WS2 = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
                        $lanW2 = (Get-ItemProperty $WS2 -Name 'LanAdapter' -ErrorAction SilentlyContinue).LanAdapter
                        $loopW2 = ($null -ne $lanW2 -and $lanW2 -gt 0)
                    } catch {
                        try { Write-SrdpLog "LoopW2 registry query failed: $($_.Exception.Message)" -Level WARN -Component 'ServerWizard' } catch {}
                    }
                    $esW2Status = if ($blockW2 -and $loopW2) { 'Full'    }
                                  elseif ($blockW2 -or $loopW2) { 'Partial' }
                                  else                          { 'None'    }
                    $esW2Color  = switch ($esW2Status) {
                        'Full'    { $CLR_OK   }
                        'Partial' { $CLR_WARN }
                        default   { $CLR_ERROR }
                    }
                }
                $by = Add-WidgetRow $wb 'Enhanced Security:' $esW2Status $esW2Color $by
            }
        } else {
            $noMl           = New-Object System.Windows.Forms.Label
            $noMl.Text      = 'No Modes Currently Installed.'
            $noMl.Font      = $FONT_WIDGET_LABEL
            $noMl.ForeColor = $CLR_SECONDARY
            $noMl.Left      = 8; $noMl.Top = $by; $noMl.AutoSize = $true
            $wb.Controls.Add($noMl)
            $by += 24
        }

        Resize-WidgetToFit $w2 $by
        $ry += ($w2.Outer.Height + 8)

        # ---- Widget 3: Traffic to RDP Allowed by Firewall ----
        # Verdict from assessment. Lock constraint: if any mode is locked,
        # the port is blocked at mode level so firewall verdict is capped up.
        $w3Verdict = 'grey'
        $w3Badge   = ''
        if ($null -ne $fwAssessment) {
            $w3Verdict = $fwAssessment.Verdict
            $w3Badge   = $fwAssessment.BadgeText
        }
        if ($anyLocked) {
            if ($w3Verdict -eq 'red' -or $w3Verdict -eq 'orange') { $w3Verdict = 'green'  }
            if ($w3Verdict -eq 'yellow')                          { $w3Verdict = 'lgreen' }
        }

        $w3Bc = switch ($w3Verdict) {
            'red'    { $CLR_RED_BORDER    }
            'orange' { $CLR_ORANGE_BORDER }
            'yellow' { $CLR_YELLOW_BORDER }
            'lgreen' { $CLR_LGREEN_BORDER }
            'green'  { $CLR_GREEN_BORDER  }
            'blue'   { $CLR_BLUE_BORDER   }
            default  { $CLR_GREY_BORDER   }
        }
        $w3Bg = switch ($w3Verdict) {
            'red'    { $CLR_RED_BG      }
            'orange' { $CLR_ORANGE_BG   }
            'yellow' { $CLR_YELLOW_BG   }
            'lgreen' { $CLR_LGREEN_BG   }
            'green'  { $CLR_GREEN_TITLE }
            'blue'   { $CLR_BLUE_TITLE  }
            default  { $CLR_GREY_TITLE  }
        }
        $w3Fg = switch ($w3Verdict) {
            'red'    { $CLR_RED_FG    }
            'orange' { $CLR_ORANGE_FG }
            'yellow' { $CLR_YELLOW_FG }
            'lgreen' { $CLR_LGREEN_FG }
            'green'  { $CLR_GREEN_FG  }
            'blue'   { $CLR_BLUE_FG   }
            default  { $CLR_DIMGRAY   }
        }

        $w3 = New-WidgetPanel $colRight 'Traffic to RDP Allowed by Firewall' $w3Badge $w3Bc $w3Bg $w3Fg $ry $widgetW -TitleHeight 50
        $wb = $w3.Body
        $by = 8

        if ($null -ne $fwAssessment) {

            # Internet exposure row
            $inetText = $fwAssessment.InternetVerdict
            $inetClr  = switch ($inetText) {
                'Any'  { $CLR_ERROR    }
                'Some' { $CLR_WARN     }
                'None' { $CLR_VAL_BLUE }
                default{ $CLR_DIMGRAY  }
            }
            $by = Add-WidgetRow $wb 'Internet' $inetText $inetClr $by

            # Private exposure row
            $privText = $fwAssessment.PrivateVerdict
            $privClr  = switch ($privText) {
                'Any'  { $CLR_WARN     }
                'Some' { $CLR_WARN     }
                'None' { $CLR_VAL_BLUE }
                default{ $CLR_DIMGRAY  }
            }
            $by = Add-WidgetRow $wb 'Private' $privText $privClr $by

            # Divider before notes
            $by = Add-WidgetDivider $wb $by

            # Port note
            $portNoteText = if ($fwPortsFallback) {
                'Port: 3389 (fallback -- detection failed)'
            } else {
                'Port: ' + ($fwPortsForCheck -join ', ')
            }
            $portNoteLbl           = New-Object System.Windows.Forms.Label
            $portNoteLbl.Text      = $portNoteText
            $portNoteLbl.Font      = $FONT_TINY
            $portNoteLbl.ForeColor = if ($fwPortsFallback) { $CLR_WARN } else { $CLR_SECONDARY }
            $portNoteLbl.Left      = 8
            $portNoteLbl.Top       = $by
            $portNoteLbl.Width     = ($wb.Width - 16)
            $portNoteLbl.Height    = 18
            $portNoteLbl.AutoSize  = $false
            $wb.Controls.Add($portNoteLbl)
            $by += 26

            # Multi-port / multi-profile summary note
            $showMultiNote = $fwAssessment.MultiplePorts -or $fwAssessment.MultipleProfiles
            if ($showMultiNote) {
                $multiParts = [System.Collections.Generic.List[string]]::new()
                if ($fwAssessment.MultiplePorts) {
                    $multiParts.Add('ports: ' + ($fwAssessment.Ports -join ', '))
                }
                if ($fwAssessment.MultipleProfiles) {
                    $multiParts.Add('profiles: ' + ($fwAssessment.ActiveProfiles -join ', '))
                }
                $multiText = 'Summed across ' + ($multiParts -join ' and ')
                $multiLbl           = New-Object System.Windows.Forms.Label
                $multiLbl.Text      = $multiText
                $multiLbl.Font      = $FONT_TINY
                $multiLbl.ForeColor = $CLR_SECONDARY
                $multiLbl.Left      = 8
                $multiLbl.Top       = $by
                $multiLbl.Width     = ($wb.Width - 16)
                $multiLbl.Height    = 18
                $multiLbl.AutoSize  = $false
                $wb.Controls.Add($multiLbl)
                $by += 26
            }

        } else {
            # Assessment failed -- show full error text
            $diagText = if ($null -ne $fwDiagError) { $fwDiagError } else { 'Firewall assessment failed.' }
            $errLbl           = New-Object System.Windows.Forms.Label
            $errLbl.Text      = $diagText
            $errLbl.Font      = $FONT_SMALL
            $errLbl.ForeColor = $CLR_ERROR
            $errLbl.Left      = 8
            $errLbl.Top       = $by
            $errLbl.Width     = ($wb.Width - 16)
            $errLbl.Height    = 80
            $errLbl.AutoSize  = $false
            $wb.Controls.Add($errLbl)
            $by += 86
        }

        $by = Add-WidgetMoreLink $wb 'Deep Firewall Risk Check (TODO)' $by
        Resize-WidgetToFit $w3 $by
        $ry += ($w3.Outer.Height + 8)

        # ---- Widget 4: Other RDP Security ----

        # --- Compute row values and per-row verdict scores ---
        # Score: 0=green 1=yellow 2=orange 3=red
        # Widget border = worst score across all rows.
        $w4Score = 0

        # -- Groups block --
        $w4GroupsOk  = ($w4Groups -is [hashtable] -and $w4Groups.Result -eq 'ok')

        # Individual account count
        $indivCount = 0
        $indivText  = 'Unknown'
        $indivColor = $CLR_SECONDARY
        $indivScore = 0
        if ($w4GroupsOk) {
            $indivCount = $w4Groups.IndividualCount
            $indivText  = "$indivCount"
            if     ($indivCount -le 4) { $indivColor = $CLR_OK;    $indivScore = 0 }
            elseif ($indivCount -le 6) { $indivColor = $CLR_WARN;  $indivScore = 1
                                         $indivText  = "$indivCount  (!)" }
            else                       { $indivColor = $CLR_ERROR; $indivScore = 3
                                         $indivText  = "$indivCount  (!)" }
        } elseif ($w4Groups -is [string] -and $w4Groups -like 'error:*') {
            $indivText = 'Error'; $indivScore = 0
        }
        if ($indivScore -gt $w4Score) { $w4Score = $indivScore }

        # Group count
        $grpCount = 0
        $grpText  = 'Unknown'
        $grpColor = $CLR_SECONDARY
        $grpScore = 0
        if ($w4GroupsOk) {
            $grpCount = $w4Groups.GroupCount
            $grpText  = "$grpCount"
            if     ($grpCount -eq 0) { $grpColor = $CLR_OK;          $grpScore = 0 }
            elseif ($grpCount -le 2) { $grpColor = $CLR_WARN;        $grpScore = 1
                                       $grpText  = "$grpCount  (!)" }
            else                     { $grpColor = $CLR_ORANGE_FG;   $grpScore = 2
                                       $grpText  = "$grpCount  (!)" }
        } elseif ($w4Groups -is [string] -and $w4Groups -like 'error:*') {
            $grpText = 'Error'; $grpScore = 0
        }
        if ($grpScore -gt $w4Score) { $w4Score = $grpScore }

        # Dangerous principals
        $dangText  = 'None detected'
        $dangColor = $CLR_OK
        $dangScore = 0
        if ($w4GroupsOk) {
            $dangList = @($w4Groups.DangerousPrincipals)
            if ($dangList.Count -gt 0) {
                $dangText  = $dangList -join ', '
                $dangColor = $CLR_ERROR
                $dangScore = 3
            }
        } elseif ($w4Groups -is [string] -and $w4Groups -like 'error:*') {
            $dangText = 'Error'; $dangScore = 0
        }
        if ($dangScore -gt $w4Score) { $w4Score = $dangScore }

        # -- Auth block --
        # NLA
        $nlaText  = 'Unknown'
        $nlaColor = $CLR_SECONDARY
        $nlaScore = 0
        switch ($w4NLA) {
            'required'    { $nlaText = 'Required';     $nlaColor = $CLR_OK;   $nlaScore = 0 }
            'notrequired' { $nlaText = 'Not required'; $nlaColor = $CLR_WARN; $nlaScore = 1 }
            default       { $nlaText = 'Unknown';      $nlaColor = $CLR_SECONDARY }
        }
        if ($nlaScore -gt $w4Score) { $w4Score = $nlaScore }

        # Smart card
        $scText  = 'Unknown'
        $scColor = $CLR_SECONDARY
        switch ($w4SmartCard) {
            'required'    { $scText = 'Required';     $scColor = $CLR_OK      }
            'notrequired' { $scText = 'No';           $scColor = $CLR_SECONDARY }
            default       { $scText = 'Unknown';      $scColor = $CLR_SECONDARY }
        }
        # Smart card not required is informational only -- no score impact

        # -- Protocol block --
        # TLS security layer
        $tlsText  = 'Unknown'
        $tlsColor = $CLR_SECONDARY
        $tlsScore = 0
        switch ($w4SecLayer) {
            'tls'       { $tlsText = 'TLS required'; $tlsColor = $CLR_OK;      $tlsScore = 0 }
            'negotiate' { $tlsText = 'Negotiate';    $tlsColor = $CLR_WARN;    $tlsScore = 1 }
            'legacy'    { $tlsText = 'RDP legacy';   $tlsColor = $CLR_ORANGE_FG; $tlsScore = 2 }
            default     { $tlsText = 'Unknown';      $tlsColor = $CLR_SECONDARY }
        }
        if ($tlsScore -gt $w4Score) { $w4Score = $tlsScore }

        # Cert expiry
        $certText  = 'Unknown'
        $certColor = $CLR_SECONDARY
        $certScore = 0
        $certOk    = ($w4CertExpiry -is [hashtable] -and $w4CertExpiry.Result -eq 'ok')
        if ($certOk) {
            $days = $w4CertExpiry.DaysUntilExpiry
            if     ($days -lt 0)   { $certText = 'Expired';
                                     $certColor = $CLR_ERROR; $certScore = 3 }
            elseif ($days -lt 30)  { $certText = "$days days (!!)";
                                     $certColor = $CLR_ORANGE_FG; $certScore = 2 }
            elseif ($days -lt 60)  { $certText = "$days days (!)";
                                     $certColor = $CLR_WARN; $certScore = 1 }
            else                   { $certText = "$days days";
                                     $certColor = $CLR_OK;  $certScore = 0 }
        } elseif ($w4CertExpiry -is [string]) {
            $certText = switch ($w4CertExpiry) {
                'error:noThumbprintConfigured' { 'None configured' }
                'error:certNotInStore'         { 'Not in store'    }
                'error:cimUnavailable'         { 'CIM error'       }
                default                        { 'Error'           }
            }
        }
        if ($certScore -gt $w4Score) { $w4Score = $certScore }

        # --- Widget border color from worst score ---
        $w4Verdict = switch ($w4Score) {
            3       { 'red'    }
            2       { 'orange' }
            1       { 'yellow' }
            default { 'green'  }
        }
        # If RDP is off, grey out entire widget
        if ($rdpEnabled -ne 'enabled') { $w4Verdict = 'grey' }

        $w4Bc = switch ($w4Verdict) {
            'red'    { $CLR_RED_BORDER    }
            'orange' { $CLR_ORANGE_BORDER }
            'yellow' { $CLR_YELLOW_BORDER }
            'green'  { $CLR_GREEN_BORDER  }
            default  { $CLR_GREY_BORDER   }
        }
        $w4Bg = switch ($w4Verdict) {
            'red'    { $CLR_RED_BG     }
            'orange' { $CLR_ORANGE_BG  }
            'yellow' { $CLR_YELLOW_BG  }
            'green'  { $CLR_GREEN_TITLE }
            default  { $CLR_GREY_TITLE  }
        }
        $w4Fg = switch ($w4Verdict) {
            'red'    { $CLR_RED_FG    }
            'orange' { $CLR_ORANGE_FG }
            'yellow' { $CLR_YELLOW_FG }
            'green'  { $CLR_GREEN_FG  }
            default  { $CLR_DIMGRAY   }
        }

        $w4 = New-WidgetPanel $colRight 'Other RDP Security' '' ([System.Drawing.Color]::Black) $CLR_GREY_TITLE $CLR_DIMGRAY $ry $widgetW
        $wb = $w4.Body
        $by = 8

        $w4ComingSoon           = New-Object System.Windows.Forms.Label
        $w4ComingSoon.Text      = 'Coming soon'
        $w4ComingSoon.Font      = $FONT_WIDGET_LABEL
        $w4ComingSoon.ForeColor = $CLR_SECONDARY
        $w4ComingSoon.Left      = 8
        $w4ComingSoon.Top       = $by
        $w4ComingSoon.AutoSize  = $true
        $wb.Controls.Add($w4ComingSoon)
        $by += $w4ComingSoon.PreferredHeight + 6

        Resize-WidgetToFit $w4 $by
        $ry += ($w4.Outer.Height + 8)

        # =====================================================================
        # BOTTOM SPACER -- forces AutoScroll to compute true content extent
        # =====================================================================
        $contentBottom = [Math]::Max($ly, [Math]::Max($my, $ry)) + 16

        # Forces AutoScroll panel to compute its extent to the true bottom
        # of content. Without this, content can detach when resizing.
        $bottomSpacer        = New-Object System.Windows.Forms.Label
        $bottomSpacer.Top    = $contentBottom + 30
        $bottomSpacer.Left   = 0
        $bottomSpacer.Height = 1
        $bottomSpacer.Width  = 1
        $script:MainPanel.Controls.Add($bottomSpacer)

        # ---- BUTTON BAR ----
        $btnY     = Get-BtnTop
        $bExit    = Add-Button $script:MainBtnBar 'Exit' 16 $btnY -TabIndex 0

        $bExit.Add_Click({ $script:MainForm.Close() })
        $script:MainForm.CancelButton = $bExit

    } # end $script:RefreshDashboard
    $rdHolder[0] = $script:RefreshDashboard

    # Wire title bar Refresh button -- rdHolder[0] now assigned
    $titleRefresh.Add_Click({ & $rdHolder[0] })

    # Initial population
    & $rdHolder[0]

    # Show and run -- $f stays open; child processes launch without hiding it
    $script:MainForm.Add_FormClosed({ [System.Windows.Forms.Application]::ExitThread() })
    [System.Windows.Forms.Application]::Run($script:MainForm)
}

Main
