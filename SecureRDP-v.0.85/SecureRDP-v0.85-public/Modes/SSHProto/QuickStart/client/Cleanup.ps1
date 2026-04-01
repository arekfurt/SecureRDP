#Requires -Version 5.1
# =============================================================================
# SecureRDP v0.821 - SSH + RDP Basic Prototype Mode
# Cleanup.ps1 - Client Certificate Removal
#
# Removes the RDP server certificate that was added to CurrentUser\Root
# by Connect-SecureRDP.ps1 on first connection.
#
# Run this script if you no longer want to connect to this server,
# or if you want to undo the one-time certificate install.
#
# Run via Cleanup.cmd, or right-click and Run with PowerShell.
# Does NOT require Administrator -- certificate is in CurrentUser store.
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Security
$ScriptDir = $PSScriptRoot

# ---------------------------------------------------------------------------
# Load config.json
# ---------------------------------------------------------------------------
$configPath = Join-Path $ScriptDir 'config.json'
if (-not (Test-Path $configPath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "config.json not found.`n`nExpected location:`n$configPath`n`nEnsure all package files are in the same folder as this script.",
        'SecureRDP - Cleanup',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    exit 1
}

$CFG = $null
try {
    $CFG = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "config.json could not be read.`n`nError: $($_.Exception.Message)",
        'SecureRDP - Cleanup',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    exit 1
}

$CERT_THUMB  = $CFG.rdpCertThumbprint
$SERVER_NAME = $CFG.serverName

if (-not $CERT_THUMB) {
    [System.Windows.Forms.MessageBox]::Show(
        "config.json does not contain a certificate thumbprint.`n`nNothing to remove.",
        'SecureRDP - Cleanup',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    exit 0
}

# ---------------------------------------------------------------------------
# Check whether the cert is actually installed
# ---------------------------------------------------------------------------
$store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
    'Root', [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
try {
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
    $found = @($store.Certificates.Find(
        [System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
        $CERT_THUMB, $false))
    $store.Close()
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Could not read certificate store.`n`nError: $($_.Exception.Message)",
        'SecureRDP - Cleanup',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    exit 1
}

if ($found.Count -eq 0) {
    [System.Windows.Forms.MessageBox]::Show(
        "The SecureRDP certificate for $SERVER_NAME is not installed in your trust store.`n`nNothing to remove.",
        'SecureRDP - Cleanup',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    exit 0
}

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
$confirm = [System.Windows.Forms.MessageBox]::Show(
    "Remove the SecureRDP RDP certificate for $SERVER_NAME from your certificate trust store?`n`nThumbprint: $CERT_THUMB`n`nAfter removal, connecting to this server will show a certificate warning in Remote Desktop unless a new client package is installed.",
    'SecureRDP - Remove Server Certificate',
    [System.Windows.Forms.MessageBoxButtons]::OKCancel,
    [System.Windows.Forms.MessageBoxIcon]::Warning)

if ($confirm -ne [System.Windows.Forms.DialogResult]::OK) { exit 0 }

# ---------------------------------------------------------------------------
# Remove certificate
# ---------------------------------------------------------------------------
try {
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
        'Root', [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    $certs = @($store.Certificates.Find(
        [System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
        $CERT_THUMB, $false))
    foreach ($c in $certs) { $store.Remove($c) }
    $store.Close()

    [System.Windows.Forms.MessageBox]::Show(
        "The SecureRDP RDP certificate for $SERVER_NAME has been removed from your trust store.",
        'SecureRDP - Cleanup Complete',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Could not remove the certificate.`n`nError: $($_.Exception.Message)`n`nYou can remove it manually via certmgr.msc (Certificate Manager).",
        'SecureRDP - Cleanup Failed',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    exit 1
}
