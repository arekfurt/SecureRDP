# =============================================================================
# SecureRDP v0.821 - SSH + RDP Basic Prototype Mode
# InstalledModes\SSHProto\Unlock.ps1
#
# Disables the block/restrict firewall rules and disables the SSH rule.
# Called by ServerWizard.ps1 when user clicks Unlock.
# Note: this re-exposes direct RDP — use with caution.
# =============================================================================

# Load logging if available (deployed to InstalledModes\SSHProto\)
$_lkLogMod = Join-Path $PSScriptRoot '..\..\..\SupportingModules\SrdpLog.psm1'
if (Test-Path $_lkLogMod) {
    Import-Module $_lkLogMod -Force
    Initialize-SrdpLog -Component 'Unlock'
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
        $r | Disable-NetFirewallRule -ErrorAction Stop
    } catch {
        $errors += "Failed to disable $rn : $_"
        try { Write-SrdpLog "ERROR disabling $rn : $_" -Level ERROR } catch {}
    }
}

if ($errors) {
    Write-Warning ($errors -join "`n")
    exit 1
}

exit 0
