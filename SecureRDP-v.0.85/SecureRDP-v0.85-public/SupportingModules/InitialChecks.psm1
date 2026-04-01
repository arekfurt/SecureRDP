# =============================================================================
# Secure RDP v0.807 - InitialChecks.psm1
# GitHub: arekfurt/SecureRDP
#
# Pure logic module. No UI. Returns structured results to ServerWizard.ps1.
# =============================================================================
Set-StrictMode -Version Latest

# =============================================================================
# Test-ArchiveIntegrity
# =============================================================================
function Test-ArchiveIntegrity {
    param([Parameter(Mandatory)][string]$ScriptRoot)

    # MANIFEST -- critical files and directories that must be present
    $expectedFiles = @(
        'ServerWizard.ps1',
        'SupportingModules\InitialChecks.psm1',
        'SupportingModules\AccountInventory.psm1',
        'RDPCheckModules\FirewallReadWriteElements.psm1',
        'RDPCheckModules\FirewallAssessor.psm1',
        'RDPCheckModules\FirewallVerdict.psm1',
        'RDPCheckModules\RDPStatus.psm1',
        'RDPCheckModules\CheckOtherRDPSecurity.psm1',
        'Modes\SSHProto\SSHProtoCore.psm1',
        'Modes\SSHProto\mode.ini',
        'Modes\SSHProto\QuickStart\Controller_Phase1a.ps1',
        'Modes\SSHProto\QuickStart\Revert_Phase1a.ps1',
        'Modes\SSHProto\QuickStart\UI_Phase1a.ps1',
        'Modes\SSHProto\QuickStart\client\Connect-SecureRDP.ps1',
        'Modes\SSHProto\QuickStart\client\Launch.cmd',
        'Modes\SSHProto\QuickStart\client\Unpack.ps1',
        'Modes\SSHProto\resources\ssh\x64\sshd.exe',
        'Modes\SSHProto\resources\ssh\x64\ssh.exe',
        'Modes\SSHProto\resources\ssh\x64\ssh-keygen.exe',
        'Modes\SSHProto\resources\ssh\x64\sftp-server.exe',
        'Modes\SSHProto\resources\ssh\x64\libcrypto.dll',
        'Modes\SSHProto\resources\ssh\x86\sshd.exe',
        'Modes\SSHProto\resources\ssh\x86\ssh.exe',
        'Modes\SSHProto\resources\ssh\x86\ssh-keygen.exe',
        'Modes\SSHProto\resources\ssh\x86\sftp-server.exe',
        'Modes\SSHProto\resources\ssh\x86\libcrypto.dll'
    )
    $expectedDirs = @(
        'SupportingModules',
        'RDPCheckModules',
        'Modes',
        'Modes\SSHProto',
        'Modes\SSHProto\QuickStart',
        'Modes\SSHProto\resources',
        'Modes\SSHProto\resources\ssh',
        'Modes\SSHProto\resources\ssh\x64',
        'Modes\SSHProto\resources\ssh\x86'
    )

    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $expectedFiles) {
        if (-not (Test-Path (Join-Path $ScriptRoot $f) -PathType Leaf)) {
            $missing.Add("File:   $f")
        }
    }
    foreach ($d in $expectedDirs) {
        if (-not (Test-Path (Join-Path $ScriptRoot $d) -PathType Container)) {
            $missing.Add("Folder: $d")
        }
    }

    if ($missing.Count -gt 0) { return @{ Result = 'missing'; Items = $missing.ToArray() } }
    return @{ Result = 'ok' }
}

# =============================================================================
# Test-WindowsSku
# =============================================================================
function Test-WindowsSku {
    try {
        $caption = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).Caption
        if ($caption -match '\bHome\b') { return 'ineligible' }
        return 'success'
    }
    catch { return 'success' }
}

# =============================================================================
# Test-AdminRights
# =============================================================================
function Test-AdminRights {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if ($p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) { return 'admin' }
    return 'not-admin'
}

# =============================================================================
# Test-RdpSession
# Checks both $env:SESSIONNAME and SystemInformation.TerminalServerSession.
# Returns 'rdp' if either fires.
# =============================================================================
function Test-RdpSession {
    # Method 1: session name - local console is always 'Console'
    if ($env:SESSIONNAME -and $env:SESSIONNAME -notmatch '^Console$') {
        return 'rdp'
    }

    # Method 2: WinForms SystemInformation
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop

        if ([System.Windows.Forms.SystemInformation]::TerminalServerSession) {
            return 'rdp'
        }
    }
    catch {}

    return 'local'
}

# =============================================================================
# Get-SessionType
# Determines whether the current session is local console, RDP via direct
# connection, or RDP via our loopback SSH tunnel. Re-check this at the
# moment you need it -- do not cache, as session type can change.
#
# Returns: 'local' | 'rdp-direct' | 'rdp-tunnel'
# On any failure defaults to 'rdp-direct' (safest -- most restrictive options).
# =============================================================================
function Get-SessionType {
    try {
        try { Write-SrdpLog "Get-SessionType: checking session type..." -Level DEBUG -Component 'InitialChecks' } catch {}

        $rdpCheck = Test-RdpSession
        if ($rdpCheck -eq 'local') {
            try { Write-SrdpLog "Get-SessionType: local console session." -Level INFO -Component 'InitialChecks' } catch {}
            return 'local'
        }

        # Session is RDP -- determine if via loopback tunnel or direct
        try { Write-SrdpLog "Get-SessionType: RDP session detected. Checking if tunnel or direct..." -Level DEBUG -Component 'InitialChecks' } catch {}

        # Get established connections to RDP port (3389) via netstat
        # Parse for foreign address -- if 127.0.0.1 or ::1, it is our tunnel
        $netstatOutput = netstat -ano 2>&1
        $rdpListenPort = '3389'

        $tunnelDetected = $false
        foreach ($line in $netstatOutput) {
            $lineStr = "$line".Trim()
            if ($lineStr -notmatch 'ESTABLISHED') { continue }
            if ($lineStr -notmatch ":$rdpListenPort\s") { continue }

            # Parse: Proto  LocalAddr  ForeignAddr  State  PID
            $parts = @($lineStr -split '\s+' | Where-Object { $_ -ne '' })
            if ($parts.Count -ge 5) {
                $foreignAddr = $parts[2]
                if ($foreignAddr -match '^127\.0\.0\.1:' -or $foreignAddr -match '^\[::1\]:' -or $foreignAddr -match '^::1:') {
                    $tunnelDetected = $true
                    break
                }
            }
        }

        if ($tunnelDetected) {
            try { Write-SrdpLog "Get-SessionType: RDP session via loopback tunnel." -Level INFO -Component 'InitialChecks' } catch {}
            return 'rdp-tunnel'
        }

        try { Write-SrdpLog "Get-SessionType: RDP session via direct connection." -Level INFO -Component 'InitialChecks' } catch {}
        return 'rdp-direct'

    } catch {
        $errMsg = $_.Exception.Message
        try { Write-SrdpLog "Get-SessionType failed: $errMsg -- defaulting to rdp-direct (safe)" -Level WARN -Component 'InitialChecks' } catch {}
        return 'rdp-direct'
    }
}

# =============================================================================
# Test-ThirdPartyFirewall
# Queries SecurityCenter2 for registered non-Windows firewall products,
# with a service-based fallback for server SKUs where SecurityCenter2
# is unavailable.
#
# Returns: @{ Result = 'none' }
#          @{ Result = 'detected'; Products = [string[]] }
# =============================================================================
function Test-ThirdPartyFirewall {
    $found = [System.Collections.Generic.List[string]]::new()

    # Method 1: Security Center 2 (workstation SKUs)
    try {
        $fwProducts = Get-CimInstance -Namespace 'root\SecurityCenter2' `
            -ClassName FirewallProduct -ErrorAction Stop
        foreach ($prod in $fwProducts) {
            if ($prod.displayName -notmatch 'Windows (Defender )?Firewall') {
                $found.Add($prod.displayName)
            }
        }
    }
    catch {}

    # Method 2: known third-party firewall services (server SKU fallback)
    if ($found.Count -eq 0) {
        # Note: only services that represent actual firewall products are listed.
        # Pure EDR/endpoint detection products (CrowdStrike, Cylance, SentinelOne)
        # have been removed -- they have no firewall component and would produce
        # false positives. FortiESNAC (NAC agent), McAfeeFramework (management
        # framework), and SYMIDSCO (IDS component) have been removed for the same
        # reason -- none are firewall products specifically.
        $knownServices = @{
            'NortonSecurity'    = 'Norton Security'
            'ekrn'              = 'ESET'
            'avgwd'             = 'AVG'
            'avast'             = 'Avast'
            'bdagent'           = 'Bitdefender'
            'TMiCRSrv'          = 'Trend Micro'
        }
        foreach ($svcName in $knownServices.Keys) {
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') {
                $found.Add($knownServices[$svcName])
            }
        }
    }

    if ($found.Count -gt 0) { return @{ Result = 'detected'; Products = $found.ToArray() } }
    return @{ Result = 'none' }
}

# =============================================================================
# Test-ManagedMachine
#
# Three high-confidence checks only:
#   1. Active Directory domain join    (Win32_ComputerSystem.PartOfDomain)
#   2. Intune MDM enrollment           (registry enrollment record with ProviderID)
#   3. Entra ID / Azure AD join        (dsregcmd /status)
#
# Returns 'evidenceofmanaged' if ANY check fires, 'noevidence' otherwise.
#
# NOTE: Remote access tool detection (TeamViewer, AnyDesk, RMM agents etc.)
# is intentionally omitted here. Those have security relevance but represent
# a different concern (persistent third-party access) and will be implemented
# separately as Test-RemoteAccessTools in a future version.
# =============================================================================
function Test-ManagedMachine {
    $evidence = [System.Collections.Generic.List[string]]::new()

    # 1. Active Directory domain join
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($cs.PartOfDomain) {
            $evidence.Add("Active Directory domain joined: $($cs.Domain)")
        }
    }
    catch {}

    # 2. Intune / MDM enrollment
    # Check for actual enrollment records with a ProviderID value present,
    # not just the existence of the Enrollments key which can exist on
    # unenrolled machines.
    try {
        $enrollPath = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
        if (Test-Path $enrollPath) {
            $enrolled = Get-ChildItem $enrollPath -ErrorAction SilentlyContinue |
                Where-Object {
                    $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                    $props.ProviderID -and $props.ProviderID -ne ''
                }
            if ($enrolled) {
                $providerIds = ($enrolled | ForEach-Object {
                    (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ProviderID
                }) -join ', '
                $evidence.Add("Intune/MDM enrollment found (ProviderID: $providerIds)")
            }
        }
    }
    catch {}

    # 3. Entra ID (Azure AD) join
    try {
        $dsreg = & dsregcmd /status 2>$null | Out-String
        if ($dsreg -match 'AzureAdJoined\s*:\s*YES') {
            $evidence.Add("Entra ID (Azure AD) joined")
        }
    }
    catch {}

    if ($evidence.Count -gt 0) {
        return @{ Result = 'evidenceofmanaged'; Evidence = $evidence.ToArray() }
    }
    return @{ Result = 'noevidence' }
}

# =============================================================================
# Test-ConfigFile
# =============================================================================
function Test-ConfigFile {
    param([Parameter(Mandatory)][string]$ConfigPath)

    if (-not (Test-Path $ConfigPath -PathType Leaf)) { return 'missing' }

    $MAX_LINE_LENGTH   = 512
    $DANGEROUS_PATTERN = '[\$`\(\)]'
    $SECTION_PATTERN   = '^\[[\w\-]+\]$'
    $KV_PATTERN        = '^[\w][\w\-\. ]*=[^\r\n]*$'

    try {
        $lines = Get-Content $ConfigPath -Encoding UTF8 -ErrorAction Stop
    }
    catch { return 'malformed' }

    if (-not $lines -or $lines.Count -eq 0) { return 'malformed' }

    $foundSection = $false
    foreach ($raw in $lines) {
        $line = $raw.TrimEnd()
        if ($line.Length -gt $MAX_LINE_LENGTH) { return 'malformed' }
        if ($line -eq '' -or $line -match '^[#;]') { continue }
        if ($line -match $SECTION_PATTERN) { $foundSection = $true; continue }
        if ($line -notmatch $KV_PATTERN) { return 'malformed' }
        $valuePart = ($line -split '=', 2)[1]
        if ($valuePart -match $DANGEROUS_PATTERN) { return 'malformed' }
    }

    if (-not $foundSection) { return 'malformed' }
    return 'valid'
}

# =============================================================================
# New-EmptyConfig
# Writes a skeleton config with no machine-identifying information.
# Machine data is populated only when the user initiates configuration.
# =============================================================================
function New-EmptyConfig {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$Version
    )

    $content = @"
# Secure RDP Configuration File
# Version: $Version
#
# This file tracks the configuration state of Secure RDP on this machine.
# It is safe to view and edit manually.
# Do not use dollar signs, backticks, or parentheses in any value -
# these will cause the file to be treated as malformed.

[Wizard]
Version           = $Version
WelcomeShown      = true
SetupComplete     = false

[Machine]
ComputerName      =
OSVersion         =
Domain            =

[SSHTunnel]
Configured        = false
SshPort           =
HostKeyFingerprint =

[Certificates]
CACertPath        =
ServerCertPath    =
SrvCertThumbprint =

[RDP]
Port              = 3389
CertAssigned      = false
LocalOnlyRule     = false
BlockDirectRule   = false

[AttackExposure]
WidgetState       = offline
"@

    # RULE: ensure directory exists before file write
    $configDir = Split-Path $ConfigPath -Parent
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }
    Set-Content -Path $ConfigPath -Value $content -Encoding UTF8
    # RULE: verify file was written
    if (-not (Test-Path $ConfigPath)) {
        throw "New-EmptyConfig: config file was not created at $ConfigPath after write."
    }
}

Export-ModuleMember -Function @(
    'Test-ArchiveIntegrity'
    'Test-WindowsSku'
    'Test-AdminRights'
    'Test-RdpSession'
    'Get-SessionType'
    'Test-ThirdPartyFirewall'
    'Test-ManagedMachine'
    'Test-ConfigFile'
    'New-EmptyConfig'
)
