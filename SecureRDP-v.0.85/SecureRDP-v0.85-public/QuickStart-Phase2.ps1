#Requires -Version 5.1
# =============================================================================
# SecureRDP Phase 2 Quick Start Launcher -- QuickStart-Phase2.ps1
#
# Run from the project root folder.
# Launches UI_Phase2.ps1 in a new powershell.exe -STA process.
#
# Phase 2 configures firewall rules and optional RDP listener restriction.
# Phase 1a must be completed first.
#
# Requires Administrator.
#
# Usage:
#   .\QuickStart-Phase2.ps1
#   .\QuickStart-Phase2.ps1 -SshPort 2222
# =============================================================================
[CmdletBinding()]
param(
    [int]$SshPort = 22,
    [switch]$SkipSshVerification
)

$UIScript = Join-Path $PSScriptRoot 'Modes\SSHProto\QuickStart\UI_Phase2.ps1'

if (-not (Test-Path $UIScript)) {
    Write-Host ''
    Write-Host "ERROR: UI script not found at: $UIScript" -ForegroundColor Red
    Write-Host 'Ensure the project folder structure is intact.' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

$argList  = "-STA -ExecutionPolicy Bypass -File `"$UIScript`""
$argList += " -ProjectRoot `"$PSScriptRoot`""
$argList += " -SshPort $SshPort"
if ($SkipSshVerification) { $argList += " -SkipSshVerification" }

# Load logging for the launcher process itself
$_launcherLog = Join-Path $PSScriptRoot 'SupportingModules\SrdpLog.psm1'
if (Test-Path $_launcherLog) {
    Import-Module $_launcherLog -Force
    Initialize-SrdpLog -Component 'QS-Phase2-Launcher'
    try { Write-SrdpLog "QuickStart-Phase2 launcher starting. SshPort=$SshPort" -Level INFO } catch {}
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
    Write-Host "ERROR: Could not launch Quick Start Phase 2 UI: $errMsg" -ForegroundColor Red
    try { Write-SrdpLog "FATAL: Launcher exception: $errMsg" -Level ERROR } catch {}
    exit 1
}
