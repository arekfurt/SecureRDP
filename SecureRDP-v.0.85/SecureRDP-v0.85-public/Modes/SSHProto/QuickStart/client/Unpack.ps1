#Requires -Version 5.1
# =============================================================================
# SecureRDP - Client Package Unpacker
# Unpack.ps1
#
# Prompts for the package passphrase, decrypts package.bin, extracts the
# client files to a temporary directory, and launches Connect-SecureRDP.ps1.
# The temporary directory is cleaned up automatically on exit.
#
# Run via Launch.cmd or "SecureRDP Connect.lnk" -- do not run directly
# unless PowerShell execution policy permits it on this machine.
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security
$ScriptDir = $PSScriptRoot

# =============================================================================
# VERIFY PACKAGE.BIN IS PRESENT
# =============================================================================
$blobPath = Join-Path $ScriptDir 'package.bin'
if (-not (Test-Path $blobPath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "package.bin not found.`n`nExpected location:`n$blobPath`n`n" +
        "Ensure all package files are in the same folder as this script.",
        'SecureRDP - Missing Package',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    exit 1
}

# =============================================================================
# LOAD PACKAGECRYPTO MODULE
# Tries several locations: alongside Unpack.ps1 (temp dir after extraction),
# and known relative paths for testing within the project tree.
# =============================================================================
$cryptoModule = $null
$cryptoCandidates = @(
    (Join-Path $ScriptDir 'PackageCrypto.psm1'),
    (Join-Path $ScriptDir '..\..\..\..\..\SupportingModules\PackageCrypto.psm1')
)
foreach ($c in $cryptoCandidates) {
    if (Test-Path $c) { $cryptoModule = $c; break }
}

if ($null -eq $cryptoModule) {
    [System.Windows.Forms.MessageBox]::Show(
        "PackageCrypto.psm1 not found.`n`n" +
        "This package may be incomplete. Please request a new package from the server administrator.",
        'SecureRDP - Missing Module',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    exit 1
}

try {
    Import-Module $cryptoModule -Force -ErrorAction Stop
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Could not load the package module.`n`nError: $_",
        'SecureRDP - Module Error',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    exit 1
}

# =============================================================================
# PASSPHRASE PROMPT
# =============================================================================
[System.Windows.Forms.Application]::EnableVisualStyles()

$pf = New-Object System.Windows.Forms.Form
$pf.Text            = 'SecureRDP - Enter Passphrase'
$pf.Width           = 420
$pf.Height          = 220
$pf.FormBorderStyle = 'FixedDialog'
$pf.MaximizeBox     = $false
$pf.MinimizeBox     = $false
$pf.StartPosition   = 'CenterScreen'
$pf.BackColor       = [System.Drawing.Color]::FromArgb(245, 245, 245)

$FONT_NORM = New-Object System.Drawing.Font('Segoe UI', 9)
$FONT_HEAD = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

$hdr           = New-Object System.Windows.Forms.Label
$hdr.Text      = 'SecureRDP - Enter Package Passphrase'
$hdr.Font      = $FONT_HEAD
$hdr.ForeColor = [System.Drawing.Color]::FromArgb(0, 60, 120)
$hdr.Left      = 16; $hdr.Top = 16; $hdr.Width = 380; $hdr.Height = 22
$hdr.AutoSize  = $false
$pf.Controls.Add($hdr)

$desc           = New-Object System.Windows.Forms.Label
$desc.Text      = 'Enter the passphrase provided by the server administrator:'
$desc.Font      = $FONT_NORM
$desc.Left      = 16; $desc.Top = 46; $desc.Width = 380; $desc.Height = 18
$desc.AutoSize  = $false
$pf.Controls.Add($desc)

$tb              = New-Object System.Windows.Forms.TextBox
$tb.Left         = 16; $tb.Top = 72; $tb.Width = 370
$tb.Font         = $FONT_NORM
$tb.PasswordChar = [char]0x2022
$pf.Controls.Add($tb)

$errLbl           = New-Object System.Windows.Forms.Label
$errLbl.Text      = ''
$errLbl.Font      = $FONT_NORM
$errLbl.ForeColor = [System.Drawing.Color]::FromArgb(170, 20, 10)
$errLbl.Left      = 16; $errLbl.Top = 100; $errLbl.Width = 370; $errLbl.Height = 18
$errLbl.AutoSize  = $false
$pf.Controls.Add($errLbl)

$bCancel              = New-Object System.Windows.Forms.Button
$bCancel.Text         = 'Cancel'
$bCancel.Left         = 204; $bCancel.Top = 136
$bCancel.Width        = 90; $bCancel.Height = 28
$bCancel.Font         = $FONT_NORM
$bCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$pf.Controls.Add($bCancel)

$bOk              = New-Object System.Windows.Forms.Button
$bOk.Text         = 'Connect'
$bOk.Left         = 302; $bOk.Top = 136
$bOk.Width        = 90; $bOk.Height = 28
$bOk.Font         = $FONT_NORM
$bOk.BackColor    = [System.Drawing.Color]::FromArgb(0, 60, 120)
$bOk.ForeColor    = [System.Drawing.Color]::White
$bOk.FlatStyle    = 'Flat'
$pf.Controls.Add($bOk)

$pf.AcceptButton = $bOk
$pf.CancelButton = $bCancel

$script:PassphraseResult = $null

$bOk.Add_Click({
    $v = $tb.Text
    if ($v.Length -eq 0) {
        $errLbl.Text = 'Please enter the passphrase.'
        return
    }
    $errLbl.Text             = ''
    $script:PassphraseResult = $v
    $pf.Close()
})

$bCancel.Add_Click({
    $script:PassphraseResult = $null
    $pf.Close()
})

$pf.ShowDialog() | Out-Null

if ($null -eq $script:PassphraseResult) {
    exit 0
}

$passphrase = $script:PassphraseResult

# =============================================================================
# DECRYPT AND EXPAND PACKAGE
# =============================================================================
$tempDir = $null
try {
    $tempDir = Expand-SrdpClientPackage -BlobPath $blobPath -Passphrase $passphrase
} catch {
    $msg = $_.Exception.Message
    $friendly = if ($msg -like 'WRONG_PASSPHRASE*') {
        'The passphrase is incorrect. Please check the passphrase and try again.'
    } elseif ($msg -like 'INVALID_BLOB*') {
        'The package file appears to be corrupted or is not a valid SecureRDP package.'
    } else {
        "Could not decrypt the package.`n`nError: $msg"
    }
    [System.Windows.Forms.MessageBox]::Show(
        $friendly,
        'SecureRDP - Decryption Failed',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    exit 1
}

# =============================================================================
# COPY PackageCrypto.psm1 INTO TEMP DIR SO Connect-SecureRDP.ps1 CAN FIND IT
# (not needed by Connect-SecureRDP.ps1 itself -- just ensures Cleanup.ps1
#  has everything it needs if it references the module in future)
# =============================================================================

# =============================================================================
# LAUNCH Connect-SecureRDP.ps1 FROM TEMP DIR
# Connect-SecureRDP.ps1 blocks until the RDP session ends.
# =============================================================================
$connectScript = Join-Path $tempDir 'Connect-SecureRDP.ps1'
if (-not (Test-Path $connectScript)) {
    [System.Windows.Forms.MessageBox]::Show(
        "The package was decrypted but Connect-SecureRDP.ps1 was not found inside.`n`n" +
        "Expected: $connectScript`n`n" +
        "The package may be incomplete. Please request a new package.",
        'SecureRDP - Incomplete Package',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

try {
    & $connectScript
} finally {
    # Clean up temp dir regardless of how Connect-SecureRDP.ps1 exits
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
