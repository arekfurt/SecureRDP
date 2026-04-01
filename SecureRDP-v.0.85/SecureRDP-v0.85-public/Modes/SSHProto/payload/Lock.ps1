# =============================================================================
# SecureRDP v0.821 - SSH + RDP Basic Prototype Mode
# InstalledModes\SSHProto\Lock.ps1
#
# Enables all three SecureRDP firewall rules.
# Called by ServerWizard.ps1 when user clicks Lock.
# =============================================================================

# Load logging if available (deployed to InstalledModes\SSHProto\)
$_lkLogMod = Join-Path $PSScriptRoot '..\..\..\SupportingModules\SrdpLog.psm1'
if (Test-Path $_lkLogMod) {
    Import-Module $_lkLogMod -Force
    Initialize-SrdpLog -Component 'Lock'
}

$rules = @(
    'SecureRDP-SSH-Inbound',
    'SecureRDP-RDP-BlockDirect',
    'SecureRDP-RDP-BlockDirect-UDP'
)

$errors = @()
foreach ($rn in $rules) {
    try {
        $r = Get-NetFirewallRule -Name $rn -ErrorAction Stop
        $r | Enable-NetFirewallRule -ErrorAction Stop
    } catch {
        $errors += "Failed to enable $rn : $_"
        try { Write-SrdpLog "ERROR enabling $rn : $_" -Level ERROR } catch {}
    }
}

if ($errors) {
    Write-Warning ($errors -join "`n")
    exit 1
}

# Ensure sshd is running
try {
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') { Start-Service sshd -ErrorAction SilentlyContinue }
} catch {}

exit 0
