#Requires -Version 5.1
# =============================================================================
# SecureRDP Client Key/Package Wizard Launcher -- ClientKeyWizard.ps1
#
# Run from the project root folder.
# Launches UI_ClientKeyWizard.ps1 in a new powershell.exe -STA process.
#
# Requires Administrator (for SSH key generation and authorized_keys write).
#
# Usage:
#   .\ClientKeyWizard.ps1
#   .\ClientKeyWizard.ps1 -SshPort 2222
# =============================================================================
[CmdletBinding()]
param(
    [int]$SshPort = 22,
    [string]$ProjectRoot = $PSScriptRoot
)

# Fallback: if $ProjectRoot is empty (e.g. run via Start-Process without
# $PSScriptRoot context), derive from the script's own path.
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path $MyInvocation.MyCommand.Path -Parent
}

$UIScript = Join-Path $ProjectRoot 'Modes\SSHProto\QuickStart\UI_ClientKeyWizard.ps1'

if (-not (Test-Path $UIScript)) {
    Write-Host ''
    Write-Host "ERROR: UI script not found at: $UIScript" -ForegroundColor Red
    Write-Host 'Ensure the project folder structure is intact.' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

$argList  = "-STA -ExecutionPolicy Bypass -File `"$UIScript`""
$argList += " -ProjectRoot `"$ProjectRoot`""
$argList += " -SshPort $SshPort"

# Load logging for the launcher process itself
$_launcherLog = Join-Path $ProjectRoot 'SupportingModules\SrdpLog.psm1'
if (Test-Path $_launcherLog) {
    Import-Module $_launcherLog -Force
    Initialize-SrdpLog -Component 'ClientKeyWizard-Launcher'
    try { Write-SrdpLog "ClientKeyWizard launcher starting. SshPort=$SshPort" -Level INFO } catch {}
}

try {
    $pinfo                 = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName        = 'powershell.exe'
    $pinfo.Arguments       = $argList
    $pinfo.UseShellExecute = $true
    $pinfo.CreateNoWindow  = $false

    $proc = [System.Diagnostics.Process]::Start($pinfo)
    if ($null -eq $proc) {
        $msg = "ERROR: Start-Process returned null -- UI process did not start."
        Write-Host $msg -ForegroundColor Red
        try { Write-SrdpLog $msg -Level ERROR } catch {}
        exit 1
    }
    try { Write-SrdpLog "UI process started. PID=$($proc.Id)" -Level INFO } catch {}
    $proc.WaitForExit()
    try { Write-SrdpLog "UI process exited. ExitCode=$($proc.ExitCode)" -Level INFO } catch {}
    exit $proc.ExitCode
} catch {
    $errMsg = $_.Exception.Message
    Write-Host "ERROR: Could not launch Client Key Wizard UI: $errMsg" -ForegroundColor Red
    try { Write-SrdpLog "FATAL: Launcher exception: $errMsg" -Level ERROR } catch {}
    exit 1
}
