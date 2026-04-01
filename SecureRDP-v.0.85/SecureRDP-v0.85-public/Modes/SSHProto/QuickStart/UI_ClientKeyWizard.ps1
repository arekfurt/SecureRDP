#Requires -Version 5.1
# =============================================================================
# SecureRDP Client Key/Package Wizard UI
# Modes\SSHProto\QuickStart\UI_ClientKeyWizard.ps1
#
# Five-screen wizard:
#   Screen 1: Machine recon / orientation
#   Screen 2: SSH username and key label
#   Screen 3: Server address and Windows/RDP username
#   Screen 4: Review and confirm
#   Screen 5: Generation progress and results
#
# Launched by ClientKeyWizard.ps1 in the project root.
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

# =============================================================================
# MODULE LOADING -- UI owns all imports
# =============================================================================
foreach ($_modRel in @(
    'SupportingModules\SrdpLog.psm1',
    'SupportingModules\InitialChecks.psm1',
    'SupportingModules\AccountInventory.psm1',
    'RDPCheckModules\RDPStatus.psm1',
    'Modes\SSHProto\SSHProtoCore.psm1'
)) {
    $_modPath = Join-Path $ProjectRoot $_modRel
    if (Test-Path $_modPath) {
        Import-Module $_modPath -Force -DisableNameChecking
        $ErrorActionPreference = 'Stop'
    }
}
Initialize-SrdpLog -Component 'CKW-UI'
try { Write-SrdpLog "UI_ClientKeyWizard starting. SshPort=$SshPort ProjectRoot=$ProjectRoot" -Level INFO } catch {}

. (Join-Path $PSScriptRoot 'Controller_ClientKeyWizard.ps1')
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
$CLR_SUGGEST      = [System.Drawing.Color]::FromArgb(100, 100, 100)
$CLR_MSG_OK_BG    = [System.Drawing.Color]::FromArgb(240, 255, 240)
$CLR_MSG_ERR_BG   = [System.Drawing.Color]::FromArgb(255, 240, 240)
$CLR_MSG_WARN_BG  = [System.Drawing.Color]::FromArgb(255, 248, 230)
$CLR_LOG_BG       = [System.Drawing.Color]::FromArgb(238, 238, 238)
$CLR_BTN_BAR_BG   = [System.Drawing.Color]::FromArgb(232, 232, 232)
$CLR_SILVER       = [System.Drawing.Color]::Silver
$CLR_WHITE        = [System.Drawing.Color]::White

# =============================================================================
# FONTS -- Times New Roman Bold throughout; min 12pt body, 14pt headings
# =============================================================================
$FONT_TITLE   = [System.Drawing.Font]::new('Times New Roman', 16, [System.Drawing.FontStyle]::Bold)
$FONT_HEADING = [System.Drawing.Font]::new('Times New Roman', 14, [System.Drawing.FontStyle]::Bold)
$FONT_BODY    = [System.Drawing.Font]::new('Times New Roman', 12, [System.Drawing.FontStyle]::Bold)
$FONT_INPUT   = [System.Drawing.Font]::new('Times New Roman', 12, [System.Drawing.FontStyle]::Bold)
$FONT_SUGGEST = [System.Drawing.Font]::new('Times New Roman', 12, [System.Drawing.FontStyle]::Bold)
$FONT_STEP    = [System.Drawing.Font]::new('Times New Roman', 14, [System.Drawing.FontStyle]::Bold)
$FONT_MSG     = [System.Drawing.Font]::new('Times New Roman', 13, [System.Drawing.FontStyle]::Bold)
$FONT_LOG     = [System.Drawing.Font]::new('Times New Roman', 12, [System.Drawing.FontStyle]::Bold)

# =============================================================================
# CONSTANTS
# =============================================================================
$LOG_TB_HEIGHT  = 140
$CONTENT_WIDTH  = 640
$FORM_WIDTH     = 760
$FORM_HEIGHT    = 680

# =============================================================================
# FORM CONSTRUCTION
# =============================================================================
$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'SecureRDP - Client Package Creator'
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
$headerPanel.Height    = 54
$headerPanel.BackColor = $CLR_HEADER_BG

$script:HeaderLabel           = New-Object System.Windows.Forms.Label
$script:HeaderLabel.Text      = 'Client Package Creator'
$script:HeaderLabel.Font      = [System.Drawing.Font]::new('Times New Roman', 14, [System.Drawing.FontStyle]::Bold)
$script:HeaderLabel.ForeColor = $CLR_HEADER_FG
$script:HeaderLabel.Dock      = [System.Windows.Forms.DockStyle]::Fill
$script:HeaderLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$script:HeaderLabel.Padding   = New-Object System.Windows.Forms.Padding(14, 0, 0, 0)
$headerPanel.Controls.Add($script:HeaderLabel)

# Button bar
$btnBar           = New-Object System.Windows.Forms.Panel
$btnBar.Dock      = [System.Windows.Forms.DockStyle]::Bottom
$btnBar.Height    = 56
$btnBar.BackColor = $CLR_BTN_BAR_BG

$btnBarSep           = New-Object System.Windows.Forms.Panel
$btnBarSep.Dock      = [System.Windows.Forms.DockStyle]::Bottom
$btnBarSep.Height    = 1
$btnBarSep.BackColor = $CLR_SILVER

$btnBack              = New-Object System.Windows.Forms.Button
$btnBack.Text         = '< Back'
$btnBack.Width        = 100
$btnBack.Height       = 34
$btnBack.Top          = 11
$btnBack.Left         = 16
$btnBack.FlatStyle    = [System.Windows.Forms.FlatStyle]::Flat
$btnBack.BackColor    = $CLR_WHITE
$btnBack.Font         = $FONT_BODY
$btnBack.FlatAppearance.BorderColor = $CLR_SILVER
$btnBack.Visible      = $false
$btnBar.Controls.Add($btnBack)

$btnNext              = New-Object System.Windows.Forms.Button
$btnNext.Text         = 'Proceed'
$btnNext.Width        = 120
$btnNext.Height       = 34
$btnNext.Top          = 11
$btnNext.Left         = $FORM_WIDTH - 120 - 32
$btnNext.FlatStyle    = [System.Windows.Forms.FlatStyle]::Flat
$btnNext.BackColor    = $CLR_BTN_PRIMARY
$btnNext.ForeColor    = $CLR_BTN_FG
$btnNext.Font         = $FONT_BODY
$btnNext.FlatAppearance.BorderSize = 0
$btnBar.Controls.Add($btnNext)

# Content panel
$script:ContentPanel              = New-Object System.Windows.Forms.Panel
$script:ContentPanel.Dock         = [System.Windows.Forms.DockStyle]::Fill
$script:ContentPanel.AutoScroll   = $true
$script:ContentPanel.Padding      = New-Object System.Windows.Forms.Padding(40, 16, 40, 16)
$script:ContentPanel.BackColor    = $CLR_BODY_BG

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
    param([string]$Text, [int]$Y, [System.Drawing.Font]$Font = $FONT_BODY,
          [System.Drawing.Color]$Color = $CLR_DARK_TEXT, [int]$Width = $CONTENT_WIDTH)
    $lbl           = New-Object System.Windows.Forms.Label
    $lbl.Text      = $Text
    $lbl.Font      = $Font
    $lbl.ForeColor = $Color
    $lbl.Left      = 0; $lbl.Top = $Y; $lbl.Width = $Width
    $lbl.AutoSize  = $false
    $lbl.MaximumSize = New-Object System.Drawing.Size($Width, 2000)
    $lbl.AutoSize  = $true
    $script:ContentPanel.Controls.Add($lbl)
    return $lbl
}

function Add-CopyableText {
    param([string]$Text, [int]$Y, [System.Drawing.Font]$Font = $FONT_BODY,
          [System.Drawing.Color]$Color = $CLR_DARK_TEXT, [int]$Width = $CONTENT_WIDTH, [int]$Height = 26)
    $tb             = New-Object System.Windows.Forms.TextBox
    $tb.Text        = $Text
    $tb.Font        = $Font
    $tb.ForeColor   = $Color
    $tb.Left        = 0; $tb.Top = $Y; $tb.Width = $Width; $tb.Height = $Height
    $tb.ReadOnly    = $true
    $tb.BorderStyle = 'None'
    $tb.BackColor   = $CLR_BODY_BG
    $script:ContentPanel.Controls.Add($tb)
    return $tb
}

function Add-UIDivider {
    param([int]$Y)
    $sep           = New-Object System.Windows.Forms.Panel
    $sep.Left      = 0; $sep.Top = $Y
    $sep.Width     = $CONTENT_WIDTH; $sep.Height = 1
    $sep.BackColor = $CLR_DIVIDER
    $script:ContentPanel.Controls.Add($sep)
    return ($Y + 10)
}

# =============================================================================
# NAVIGATION STATE
# =============================================================================
$script:CurrentScreen      = 0
$script:BtnNextHandler     = $null
$script:BtnBackHandler     = $null
$script:ReconResult        = $null
$script:GenerateInProgress = $false

# User selections
$script:SshUsername     = ''
$script:RdpUsername     = ''
$script:SelectedAddress = ''
$script:SelectedKeyLabel = ''
$script:SelectedRdpPort  = 3389

# FormClosing guard
$form.Add_FormClosing({
    param($sender, $e)
    if ($script:GenerateInProgress) {
        $e.Cancel = $true
        [System.Windows.Forms.MessageBox]::Show(
            'Package generation is in progress. Please wait.',
            'SecureRDP', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
})

# =============================================================================
# SCREEN 1: Machine Recon / Orientation
# =============================================================================
function Show-Screen1 {
    Clear-ContentPanel
    $script:CurrentScreen      = 1
    $script:HeaderLabel.Text   = 'Server Information'
    $btnBack.Visible           = $false
    $btnNext.Text              = 'Loading...'
    $btnNext.Enabled           = $false

    if ($null -ne $script:BtnNextHandler) { $btnNext.remove_Click($script:BtnNextHandler) }
    if ($null -ne $script:BtnBackHandler) { $btnBack.remove_Click($script:BtnBackHandler) }

    $y = 4
    $y = (Add-UILabel -Text 'Gathering server information...' -Y $y -Font $FONT_HEADING -Color $CLR_HEADER_BG).Bottom + 8
    [System.Windows.Forms.Application]::DoEvents()

    $script:ReconResult = Invoke-ClientKeyRecon

    Clear-ContentPanel
    $y = 4

    $rd = $script:ReconResult.Data
    $script:SelectedRdpPort = $rd.RdpPort

    $y = (Add-UILabel -Text 'Server Information' -Y $y -Font $FONT_HEADING -Color $CLR_HEADER_BG).Bottom + 8

    $domainStr = if ($rd.IsDomainJoined) { "Yes ($($rd.DomainName))" } else { 'No (workgroup)' }
    $rdpStr    = if ($rd.RdpEnabled) { 'Enabled' } else { 'Disabled' }
    $rdpColor  = if ($rd.RdpEnabled) { $CLR_OK } else { $CLR_ERR }

    $y = (Add-CopyableText -Text "Computer name: $($rd.ComputerName)" -Y $y -Font $FONT_BODY).Bottom + 4
    $y = (Add-CopyableText -Text "Domain joined: $domainStr" -Y $y -Font $FONT_BODY).Bottom + 4
    $y = (Add-UILabel -Text "Remote Desktop: $rdpStr" -Y $y -Font $FONT_BODY -Color $rdpColor).Bottom + 4
    $y = (Add-CopyableText -Text "RDP port: $($rd.RdpPort)" -Y $y -Font $FONT_BODY).Bottom + 8

    $y = Add-UIDivider -Y $y

    $y = (Add-UILabel -Text "RDP-Eligible User Accounts ($($rd.EligibleAccounts.Count))" -Y $y -Font $FONT_HEADING -Color $CLR_HEADER_BG).Bottom + 6

    if ($rd.EligibleAccounts.Count -eq 0) {
        $y = (Add-UILabel -Text 'No RDP-eligible accounts found. Ensure at least one account is a member of Administrators or Remote Desktop Users.' -Y $y -Color $CLR_WARN).Bottom + 4
    } else {
        foreach ($acct in $rd.EligibleAccounts) {
            $qualName = if ($acct.PSObject.Properties.Name -contains 'QualifiedName') { $acct.QualifiedName } else { $acct.ShortName }
            $y = (Add-CopyableText -Text "  $qualName" -Y $y -Font $FONT_BODY).Bottom + 2
        }
        $y += 4
    }

    $y = Add-UIDivider -Y $y
    $y = (Add-UILabel -Text 'SecureRDP does not manage RDP settings or user account membership. Use Windows to configure those.' -Y $y -Font $FONT_BODY -Color $CLR_SUGGEST).Bottom + 4

    $btnNext.Text    = 'Proceed'
    $btnNext.Enabled = $true
    $script:BtnNextHandler = { Show-Screen2 }
    $btnNext.Add_Click($script:BtnNextHandler)
}

# =============================================================================
# SCREEN 2: SSH Username and Key Label
# =============================================================================
function Show-Screen2 {
    Clear-ContentPanel
    $script:CurrentScreen    = 2
    $script:HeaderLabel.Text = 'SSH Credentials'
    $btnBack.Visible         = $true
    $btnNext.Text            = 'Proceed'
    $btnNext.Enabled         = $true

    if ($null -ne $script:BtnNextHandler) { $btnNext.remove_Click($script:BtnNextHandler) }
    if ($null -ne $script:BtnBackHandler) { $btnBack.remove_Click($script:BtnBackHandler) }

    $script:BtnBackHandler = { Show-Screen1 }
    $btnBack.Add_Click($script:BtnBackHandler)

    $rd = $script:ReconResult.Data
    $y  = 4

    # -- SSH Username --
    $y = (Add-UILabel -Text 'SSH Username' -Y $y -Font $FONT_HEADING -Color $CLR_HEADER_BG).Bottom + 4
    $y = (Add-UILabel -Text 'The Windows account on the server that SSH will authenticate as. Must be a valid Windows account on the server. May be a dedicated tunnel-only account.' -Y $y -Font $FONT_BODY -Color $CLR_DARK_TEXT).Bottom + 8

    $script:TxtSshUsername        = New-Object System.Windows.Forms.TextBox
    $script:TxtSshUsername.Left   = 0; $script:TxtSshUsername.Top = $y
    $script:TxtSshUsername.Width  = $CONTENT_WIDTH
    $script:TxtSshUsername.Height = 28
    $script:TxtSshUsername.Font   = $FONT_INPUT
    $script:TxtSshUsername.Text   = $script:SshUsername
    $script:ContentPanel.Controls.Add($script:TxtSshUsername)
    $y += 34

    # Suggestions for SSH username
    $y = (Add-UILabel -Text 'Suggestions (copy and paste or type directly):' -Y $y -Font $FONT_BODY -Color $CLR_SUGGEST).Bottom + 4

    # Current user running the wizard
    $currentUserQual = "$($env:COMPUTERNAME)\$($env:USERNAME)"
    if ($rd.IsDomainJoined -and $rd.DomainName -ne '') {
        $currentUserQual = "$($rd.DomainName)\$($env:USERNAME)"
    }
    $y = (Add-CopyableText -Text "  $currentUserQual" -Y $y -Font $FONT_BODY -Color $CLR_HEADER_BG).Bottom + 2
    $y = (Add-UILabel -Text '    Current user running this wizard (most convenient for initial testing)' -Y $y -Font $FONT_BODY -Color $CLR_SUGGEST).Bottom + 4

    foreach ($acct in $rd.EligibleAccounts) {
        $qualName = if ($acct.PSObject.Properties.Name -contains 'QualifiedName') { $acct.QualifiedName } else { $acct.ShortName }
        if ($qualName -ne $currentUserQual) {
            $y = (Add-CopyableText -Text "  $qualName" -Y $y -Font $FONT_BODY -Color $CLR_HEADER_BG).Bottom + 2
            $y = (Add-UILabel -Text '    RDP-eligible account on this server' -Y $y -Font $FONT_BODY -Color $CLR_SUGGEST).Bottom + 4
        }
    }
    $y += 4

    $y = Add-UIDivider -Y $y

    # -- SSH Key Label --
    $y = (Add-UILabel -Text 'SSH Key Label' -Y $y -Font $FONT_HEADING -Color $CLR_HEADER_BG).Bottom + 4
    $y = (Add-UILabel -Text 'A unique label for this SSH key. Used to identify the key in authorized_keys and in the Manage screen.' -Y $y -Font $FONT_BODY -Color $CLR_DARK_TEXT).Bottom + 8

    $defaultLabel = if ($script:SelectedKeyLabel -ne '') {
        $script:SelectedKeyLabel
    } else {
        "client-$(Get-Date -Format 'yyyyMMdd')"
    }

    $script:TxtKeyLabel        = New-Object System.Windows.Forms.TextBox
    $script:TxtKeyLabel.Left   = 0; $script:TxtKeyLabel.Top = $y
    $script:TxtKeyLabel.Width  = $CONTENT_WIDTH
    $script:TxtKeyLabel.Height = 28
    $script:TxtKeyLabel.Font   = $FONT_INPUT
    $script:TxtKeyLabel.Text   = $defaultLabel
    $script:ContentPanel.Controls.Add($script:TxtKeyLabel)
    $y += 34

    # Duplicate label warning (hidden initially)
    $script:LblDupWarn           = New-Object System.Windows.Forms.Label
    $script:LblDupWarn.Text      = ''
    $script:LblDupWarn.Font      = $FONT_BODY
    $script:LblDupWarn.ForeColor = $CLR_ERR
    $script:LblDupWarn.Left      = 0; $script:LblDupWarn.Top = $y
    $script:LblDupWarn.Width     = $CONTENT_WIDTH
    $script:LblDupWarn.AutoSize  = $true
    $script:LblDupWarn.Visible   = $false
    $script:ContentPanel.Controls.Add($script:LblDupWarn)

    # Wire Proceed
    $script:BtnNextHandler = {
        $sshUser = $script:TxtSshUsername.Text.Trim()
        if ($sshUser -eq '') {
            [System.Windows.Forms.MessageBox]::Show(
                'Please enter an SSH username.',
                'SecureRDP', [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        $label = $script:TxtKeyLabel.Text.Trim()
        if ($label -eq '') {
            [System.Windows.Forms.MessageBox]::Show(
                'Please enter a key label.',
                'SecureRDP', [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        # Check for duplicate key label
        try {
            $existing = Get-SrdpAuthorizedKeys
            if ($existing.Result -eq 'ok' -and $existing.Count -gt 0) {
                foreach ($k in $existing.Keys) {
                    if ($k.Comment -eq "SecureRDP-$label") {
                        $script:LblDupWarn.Text    = "Warning: A key with label '$label' already exists. Choose a different label."
                        $script:LblDupWarn.Visible = $true
                        return
                    }
                }
            }
        } catch {}
        $script:LblDupWarn.Visible = $false

        $script:SshUsername      = $sshUser
        $script:SelectedKeyLabel = $label
        Show-Screen3
    }
    $btnNext.Add_Click($script:BtnNextHandler)
}

# =============================================================================
# SCREEN 3: Server Address and Windows/RDP Username
# =============================================================================
function Show-Screen3 {
    Clear-ContentPanel
    $script:CurrentScreen    = 3
    $script:HeaderLabel.Text = 'Connection Target'
    $btnBack.Visible         = $true
    $btnNext.Text            = 'Proceed'
    $btnNext.Enabled         = $true

    if ($null -ne $script:BtnNextHandler) { $btnNext.remove_Click($script:BtnNextHandler) }
    if ($null -ne $script:BtnBackHandler) { $btnBack.remove_Click($script:BtnBackHandler) }

    $script:BtnBackHandler = { Show-Screen2 }
    $btnBack.Add_Click($script:BtnBackHandler)

    $rd = $script:ReconResult.Data
    $y  = 4

    # -- Server Address --
    $y = (Add-UILabel -Text 'Server Address' -Y $y -Font $FONT_HEADING -Color $CLR_HEADER_BG).Bottom + 4
    $y = (Add-UILabel -Text 'The IP address or hostname that SSH will connect to. SSH port: 22.' -Y $y -Font $FONT_BODY -Color $CLR_DARK_TEXT).Bottom + 8

    $script:TxtAddress        = New-Object System.Windows.Forms.TextBox
    $script:TxtAddress.Left   = 0; $script:TxtAddress.Top = $y
    $script:TxtAddress.Width  = $CONTENT_WIDTH
    $script:TxtAddress.Height = 28
    $script:TxtAddress.Font   = $FONT_INPUT
    $script:TxtAddress.Text   = $script:SelectedAddress
    $script:ContentPanel.Controls.Add($script:TxtAddress)
    $y += 34

    # Address suggestions
    if ($rd.AddressSuggestions.Count -gt 0) {
        $y = (Add-UILabel -Text 'Suggestions (copy and paste to use):' -Y $y -Font $FONT_BODY -Color $CLR_SUGGEST).Bottom + 4
        foreach ($sug in $rd.AddressSuggestions) {
            $sugAddr  = $sug.Address
            $sugLabel = $sug.Label
            $y = (Add-CopyableText -Text "  $sugAddr" -Y $y -Font $FONT_BODY -Color $CLR_HEADER_BG).Bottom + 2
            $y = (Add-UILabel -Text "    $sugLabel" -Y $y -Font $FONT_BODY -Color $CLR_SUGGEST).Bottom + 4
        }
    }
    $y += 4

    $y = Add-UIDivider -Y $y

    # -- Windows/RDP Username --
    $y = (Add-UILabel -Text 'Windows/RDP Username (optional)' -Y $y -Font $FONT_HEADING -Color $CLR_HEADER_BG).Bottom + 4
    $y = (Add-UILabel -Text 'Pre-fills the Windows login prompt for the remote user''s convenience. Optional -- the user can enter any account at the login prompt regardless of what is entered here.' -Y $y -Font $FONT_BODY -Color $CLR_DARK_TEXT).Bottom + 8

    $script:TxtRdpUsername        = New-Object System.Windows.Forms.TextBox
    $script:TxtRdpUsername.Left   = 0; $script:TxtRdpUsername.Top = $y
    $script:TxtRdpUsername.Width  = $CONTENT_WIDTH
    $script:TxtRdpUsername.Height = 28
    $script:TxtRdpUsername.Font   = $FONT_INPUT
    $script:TxtRdpUsername.Text   = $script:RdpUsername
    $script:ContentPanel.Controls.Add($script:TxtRdpUsername)
    $y += 34

    # RDP username suggestions
    $y = (Add-UILabel -Text 'Suggestions (copy and paste or leave blank):' -Y $y -Font $FONT_BODY -Color $CLR_SUGGEST).Bottom + 4
    foreach ($acct in $rd.EligibleAccounts) {
        $qualName = if ($acct.PSObject.Properties.Name -contains 'QualifiedName') { $acct.QualifiedName } else { $acct.ShortName }
        $y = (Add-CopyableText -Text "  $qualName" -Y $y -Font $FONT_BODY -Color $CLR_HEADER_BG).Bottom + 2
        $y = (Add-UILabel -Text '    RDP-eligible account on this server' -Y $y -Font $FONT_BODY -Color $CLR_SUGGEST).Bottom + 4
    }

    # Wire Proceed
    $script:BtnNextHandler = {
        $addr = $script:TxtAddress.Text.Trim()
        if ($addr -eq '') {
            [System.Windows.Forms.MessageBox]::Show(
                'Please enter a server address.',
                'SecureRDP', [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        $script:SelectedAddress = $addr
        $script:RdpUsername     = $script:TxtRdpUsername.Text.Trim()
        Show-Screen4
    }
    $btnNext.Add_Click($script:BtnNextHandler)
}

# =============================================================================
# SCREEN 4: Review and Confirm
# =============================================================================
function Show-Screen4 {
    Clear-ContentPanel
    $script:CurrentScreen    = 4
    $script:HeaderLabel.Text = 'Review'
    $btnBack.Visible         = $true
    $btnNext.Text            = 'Create Package'
    $btnNext.Enabled         = $true

    if ($null -ne $script:BtnNextHandler) { $btnNext.remove_Click($script:BtnNextHandler) }
    if ($null -ne $script:BtnBackHandler) { $btnBack.remove_Click($script:BtnBackHandler) }

    $script:BtnBackHandler = { Show-Screen3 }
    $btnBack.Add_Click($script:BtnBackHandler)

    $y = 4

    $y = (Add-UILabel -Text 'Package Configuration' -Y $y -Font $FONT_HEADING -Color $CLR_HEADER_BG).Bottom + 10

    $rdpDisplay = if ($script:RdpUsername -ne '') { $script:RdpUsername } else { '(not specified)' }

    $y = (Add-CopyableText -Text "SSH username:       $($script:SshUsername)"   -Y $y -Font $FONT_BODY).Bottom + 6
    $y = (Add-CopyableText -Text "SSH key label:      $($script:SelectedKeyLabel)" -Y $y -Font $FONT_BODY).Bottom + 6
    $y = (Add-CopyableText -Text "Server address:     $($script:SelectedAddress)"  -Y $y -Font $FONT_BODY).Bottom + 6
    $y = (Add-CopyableText -Text "SSH port:           $SshPort"                   -Y $y -Font $FONT_BODY).Bottom + 6
    $y = (Add-CopyableText -Text "Windows/RDP username: $rdpDisplay"              -Y $y -Font $FONT_BODY).Bottom + 8

    $y = Add-UIDivider -Y $y

    $y = (Add-UILabel -Text "Click 'Create Package' to generate the SSH key pair, authorize it, and assemble the client package. Click '< Back' to change any settings." -Y $y -Font $FONT_BODY -Color $CLR_DARK_TEXT).Bottom + 4

    $script:BtnNextHandler = { Show-Screen5 }
    $btnNext.Add_Click($script:BtnNextHandler)
}

# =============================================================================
# SCREEN 5: Generation and Results
# =============================================================================
function Show-Screen5 {
    Clear-ContentPanel
    $script:CurrentScreen      = 5
    $script:HeaderLabel.Text   = 'Creating Package...'
    $btnBack.Visible           = $false
    $btnNext.Text              = 'Close'
    $btnNext.Enabled           = $false

    if ($null -ne $script:BtnNextHandler) { $btnNext.remove_Click($script:BtnNextHandler) }
    if ($null -ne $script:BtnBackHandler) { $btnBack.remove_Click($script:BtnBackHandler) }

    $y = 4

    $planSteps = @(
        'Locating SSH binaries...',
        "Generating SSH key pair '$($script:SelectedKeyLabel)'...",
        'Adding public key to authorized_keys...',
        'Reading server host key...',
        'Assembling client package...',
        'Verifying package contents...'
    )

    $stepLabels = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($step in $planSteps) {
        $markerLbl           = New-Object System.Windows.Forms.Label
        $markerLbl.Text      = [char]0x25CB
        $markerLbl.Left      = 0; $markerLbl.Top = $y
        $markerLbl.Width     = 28; $markerLbl.Height = 28
        $markerLbl.Font      = $FONT_STEP
        $markerLbl.ForeColor = $CLR_STEP_PENDING
        $markerLbl.AutoSize  = $false
        $markerLbl.TextAlign = 'MiddleCenter'
        $script:ContentPanel.Controls.Add($markerLbl)

        $stepLbl           = New-Object System.Windows.Forms.Label
        $stepLbl.Text      = $step
        $stepLbl.Left      = 32; $stepLbl.Top = $y
        $stepLbl.Width     = $CONTENT_WIDTH - 32
        $stepLbl.Font      = $FONT_STEP
        $stepLbl.ForeColor = $CLR_STEP_PENDING
        $stepLbl.AutoSize  = $false; $stepLbl.Height = 28
        $script:ContentPanel.Controls.Add($stepLbl)

        $null = $stepLabels.Add(@{ Marker = $markerLbl; Label = $stepLbl })
        $y += 32
    }
    $script:StepLabels = $stepLabels.ToArray()
    $y += 4
    $y = Add-UIDivider -Y $y

    $y = (Add-UILabel -Text 'Activity:' -Y $y -Font $FONT_HEADING -Color $CLR_HEADER_BG).Bottom + 4

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

    $script:MsgPanel             = New-Object System.Windows.Forms.Panel
    $script:MsgPanel.Left        = 0; $script:MsgPanel.Top = $y
    $script:MsgPanel.Width       = $CONTENT_WIDTH
    $script:MsgPanel.Height      = 80
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
    $script:MsgLabel.Text      = 'Generating package...'
    $script:MsgPanel.Controls.Add($script:MsgLabel)

    [System.Windows.Forms.Application]::DoEvents()

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

    $script:GenerateInProgress = $true

    $genResult = Invoke-ClientKeyGeneration `
        -ServerAddress  $script:SelectedAddress `
        -SshUsername    $script:SshUsername `
        -RdpUsername    $script:RdpUsername `
        -KeyLabel       $script:SelectedKeyLabel `
        -SshPort        $SshPort `
        -RdpPort        $script:SelectedRdpPort `
        -ProjectRoot    $ProjectRoot `
        -OnProgress     $onProgress

    $script:GenerateInProgress = $false

    if ($genResult.Errors.Count -gt 0 -and $null -ne $script:LogBox) {
        $script:LogBox.SelectionColor = [System.Drawing.Color]::FromArgb(192, 32, 14)
        $script:LogBox.AppendText("--- $($genResult.Errors.Count) error(s) ---`r`n")
        foreach ($err in $genResult.Errors) {
            $script:LogBox.AppendText("[ERROR] $err`r`n")
        }
        $script:LogBox.SelectionColor = $script:LogBox.ForeColor
        $script:LogBox.ScrollToCaret()
    }

    if ($genResult.Success) {
        foreach ($pair in $script:StepLabels) {
            if ($pair.Marker.Text -eq [string][char]0x25CB) {
                $pair.Marker.Text      = [char]0x2713
                $pair.Marker.ForeColor = $CLR_STEP_DONE
                $pair.Label.ForeColor  = $CLR_STEP_DONE
            }
        }
    }

    if ($genResult.Success) {
        $script:HeaderLabel.Text   = 'Package Created'
        $script:MsgPanel.BackColor = $CLR_MSG_OK_BG
        $script:MsgLabel.ForeColor = $CLR_OK
        $script:MsgLabel.Text      = 'Client package created successfully.'

        if ($genResult.Errors.Count -gt 0) {
            $script:MsgPanel.BackColor = $CLR_MSG_WARN_BG
            $script:MsgLabel.ForeColor = $CLR_WARN
            $script:MsgLabel.Text      = "Package created with $($genResult.Errors.Count) warning(s)."
        }

        $ry = $script:MsgPanel.Top + $script:MsgPanel.Height + 10

        $ry = (Add-UILabel -Text 'Package location:' -Y $ry -Font $FONT_BODY).Bottom + 4
        $ry = (Add-CopyableText -Text $genResult.Data.ZipPath -Y $ry -Font $FONT_BODY -Color $CLR_HEADER_BG).Bottom + 10

        $verFiles = @($genResult.Data.VerifiedFiles)
        $verColor = if ($verFiles.Count -ge 6) { $CLR_OK } else { $CLR_WARN }
        $ry = (Add-UILabel -Text "Verified files: $($verFiles.Count) of 7 expected" -Y $ry -Font $FONT_BODY -Color $verColor).Bottom + 10

        $ry = Add-UIDivider -Y $ry

        $warnPanel             = New-Object System.Windows.Forms.Panel
        $warnPanel.Left        = 0; $warnPanel.Top = $ry
        $warnPanel.Width       = $CONTENT_WIDTH; $warnPanel.Height = 80
        $warnPanel.BackColor   = $CLR_MSG_WARN_BG
        $warnPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $warnLbl               = New-Object System.Windows.Forms.Label
        $warnLbl.Text          = 'SECURITY: This package contains an unprotected SSH private key. Treat it as sensitive material. Transfer it securely and do not leave it on shared or untrusted machines. Passphrase-encrypted packaging is planned for a future build.'
        $warnLbl.Font          = $FONT_BODY
        $warnLbl.ForeColor     = $CLR_WARN
        $warnLbl.Dock          = [System.Windows.Forms.DockStyle]::Fill
        $warnLbl.Padding       = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)
        $warnPanel.Controls.Add($warnLbl)
        $script:ContentPanel.Controls.Add($warnPanel)
        $ry += 88

        $ry = (Add-UILabel -Text 'Copy the package to the remote user''s machine. The user extracts it and runs Launch.cmd. They will see a connecting window, then a normal Windows login prompt.' -Y $ry -Font $FONT_BODY -Color $CLR_DARK_TEXT).Bottom + 12

        $btnOpenFolder              = New-Object System.Windows.Forms.Button
        $btnOpenFolder.Text         = 'Open Folder'
        $btnOpenFolder.Width        = 120; $btnOpenFolder.Height = 34
        $btnOpenFolder.Left         = 0; $btnOpenFolder.Top = $ry
        $btnOpenFolder.FlatStyle    = [System.Windows.Forms.FlatStyle]::Flat
        $btnOpenFolder.BackColor    = $CLR_BTN_PRIMARY
        $btnOpenFolder.ForeColor    = $CLR_BTN_FG
        $btnOpenFolder.Font         = $FONT_BODY
        $btnOpenFolder.FlatAppearance.BorderSize = 0
        $btnOpenFolder.Cursor       = [System.Windows.Forms.Cursors]::Hand
        $script:ContentPanel.Controls.Add($btnOpenFolder)
        $zipPath = $genResult.Data.ZipPath
        $btnOpenFolder.Add_Click({
            Start-Process explorer.exe -ArgumentList "/select,`"$zipPath`""
        }.GetNewClosure())

        $btnAnother              = New-Object System.Windows.Forms.Button
        $btnAnother.Text         = 'Create Another'
        $btnAnother.Width        = 140; $btnAnother.Height = 34
        $btnAnother.Left         = 130; $btnAnother.Top = $ry
        $btnAnother.FlatStyle    = [System.Windows.Forms.FlatStyle]::Flat
        $btnAnother.BackColor    = $CLR_WHITE
        $btnAnother.Font         = $FONT_BODY
        $btnAnother.FlatAppearance.BorderColor = $CLR_SILVER
        $btnAnother.Cursor       = [System.Windows.Forms.Cursors]::Hand
        $script:ContentPanel.Controls.Add($btnAnother)
        $btnAnother.Add_Click({
            $script:SelectedKeyLabel = ''
            Show-Screen2
        })

        $btnNext.Text    = 'Done'
        $btnNext.Enabled = $true
        $script:BtnNextHandler = { $form.Close() }
        $btnNext.Add_Click($script:BtnNextHandler)

    } else {
        $script:HeaderLabel.Text   = 'Package Creation Failed'
        $script:MsgPanel.BackColor = $CLR_MSG_ERR_BG
        $script:MsgLabel.ForeColor = $CLR_ERR
        $firstErr = if ($genResult.Errors.Count -gt 0) { $genResult.Errors[0] } else { 'An unknown error occurred.' }
        $script:MsgLabel.Text = "Error: $firstErr"

        $btnNext.Text    = 'Close'
        $btnNext.Enabled = $true
        $script:BtnNextHandler = { $form.Close() }
        $btnNext.Add_Click($script:BtnNextHandler)
    }

    [System.Windows.Forms.Application]::DoEvents()
}

# =============================================================================
# STARTUP
# =============================================================================
$form.Add_Shown({
    Show-Screen1
})

[System.Windows.Forms.Application]::Run($form)
