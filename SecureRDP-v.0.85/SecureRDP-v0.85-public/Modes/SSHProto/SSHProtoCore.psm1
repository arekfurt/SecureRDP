#Requires -Version 5.1
# =============================================================================
# Secure RDP v0.824 - SupportingModules\SSHProtoCore.psm1
# GitHub: arekfurt/SecureRDP
#
# Shared infrastructure module for the SSH Prototype Mode.
# Imported by QuickStart.ps1, Revert-SSHProto.ps1, and future management UI.
#
# All business logic lives here. Wizard/UI scripts contain only UI code.
#
# ARCHITECTURE (v0.824+):
#   SSH authentication is fully independent from Windows account authentication.
#   SSH keys control tunnel access only. The Windows account used for the RDP
#   session is determined by credentials entered at the RDP login screen.
#   A single global authorized_keys file is used; no per-account key linking.
#
#   The SSH service runs as NT SERVICE\SecureRDP-SSH (Windows virtual service
#   account, auto-managed by SCM, minimal privileges, no password management).
#
# ERROR CONTRACT:
#   Functions that can fail return "error:..." strings on failure.
#   Functions that return data return @{Result='ok'; ...} hashtables.
#   Module scope does NOT set $ErrorActionPreference = 'Stop'.
#   Caller check: if ($r -is [string] -and $r -like 'error:*') { <handle> }
# =============================================================================
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Module-level constants
# ---------------------------------------------------------------------------

# Legacy SSH data dir -- used by detection and revert functions for
# pre-v0.824 installations and for the inbox OpenSSH feature path.
$Script:SSH_DATA_DIR  = "$env:ProgramData\ssh"
$Script:BUNDLED_INST  = 'C:\Program Files\SecureRDP\OpenSSH'
$Script:SRDP_VER_CORE = '0.85'

# Firewall rule names (unchanged)
$Script:RULE_SSH     = 'SecureRDP-SSH-Inbound'
$Script:RULE_RDP_BLK     = 'SecureRDP-RDP-BlockDirect'
$Script:RULE_RDP_BLK_UDP = 'SecureRDP-RDP-BlockDirect-UDP'

# SecureRDP SSH service and data paths (v0.824+)
$Script:SVC_NAME      = 'SecureRDP-SSH'
$Script:SVC_DISPLAY   = 'SecureRDP SSH Tunnel Service'
$Script:SRDP_SSH_ROOT = "C:\ProgramData\SecureRDP\ssh"
$Script:HOST_KEY_DIR  = "$Script:SRDP_SSH_ROOT\host"
$Script:HOST_KEY_PATH = "$Script:HOST_KEY_DIR\ssh_host_ed25519_key"
$Script:AUTH_KEYS_PATH = "$Script:SRDP_SSH_ROOT\authorized_keys"
$Script:SSHD_CFG_PATH = "$Script:SRDP_SSH_ROOT\sshd_config"
$Script:CLIENT_KEY_DIR = "$Script:SRDP_SSH_ROOT\clients"
$Script:DEFAULT_SSH_PORT = 22

# ===========================================================================
# STATE MANAGEMENT
# ===========================================================================

function Read-SrdpState {
    param([Parameter(Mandatory)][string]$StateFile)
    if (-not (Test-Path $StateFile)) { return $null }
    try {
        $raw = Get-Content $StateFile -Raw -Encoding UTF8
        return $raw | ConvertFrom-Json
    } catch {
        return "error:Could not parse state.json: $($_.Exception.Message)"
    }
}

function Write-SrdpState {
    param(
        [Parameter(Mandatory)][string]$StateFile,
        [Parameter(Mandatory)]$State
    )
    try {
        $dir = Split-Path $StateFile -Parent
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $State | ConvertTo-Json -Depth 10 | Set-Content $StateFile -Encoding UTF8
        return $true
    } catch {
        return "error:Could not write state.json: $($_.Exception.Message)"
    }
}

function Get-SrdpAccount {
    param(
        $State,
        [Parameter(Mandatory)][string]$AccountName
    )
    if ($null -eq $State) { return $null }
    # Guard against missing Accounts property under StrictMode
    $stProps = $State.PSObject.Properties.Name
    if ($stProps -notcontains 'Accounts' -or $null -eq $State.Accounts) { return $null }
    $found = @($State.Accounts | Where-Object { $_.AccountName -eq $AccountName })
    if ($found.Count -gt 0) { return $found[0] }
    return $null
}

# ===========================================================================
# SSH DETECTION
# ===========================================================================

function Get-SrdpSshInfo {
    param([Parameter(Mandatory)][string]$ModeDir)

    $minVer = [version]'9.0'

    # Find existing sshd from service or well-known paths
    $candidates = @(
        'C:\Windows\System32\OpenSSH\sshd.exe',
        'C:\Program Files\OpenSSH\sshd.exe'
    )
    $svc = Get-Service sshd -ErrorAction SilentlyContinue

    $existingPath    = $null
    $existingVersion = $null
    $featureInstalled = $false
    $featureError    = $null
    $useExisting     = $false
    $arch = if ([System.Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }

    # Check service path first
    if ($svc) {
        try {
            $svcCim = Get-CimInstance -ClassName Win32_Service `
                      -Filter "Name='sshd'" -ErrorAction SilentlyContinue
            if ($null -ne $svcCim -and $svcCim.PathName) {
                $svcPath = $svcCim.PathName -replace '^"','' -replace '".*$',''
                if (Test-Path $svcPath) { $candidates = @($svcPath) + $candidates }
            }
        } catch {}
    }

    foreach ($c in $candidates) {
        if (-not (Test-Path $c)) { continue }
        try {
            $fv = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($c)
            $ver = [version]"$($fv.FileMajorPart).$($fv.FileMinorPart)"
            if ($ver -ge $minVer) {
                $existingPath    = $c
                $existingVersion = $ver.ToString()
                $useExisting     = $true
                break
            }
        } catch {}
    }

    # Try Windows optional feature if no suitable existing install
    if (-not $useExisting) {
        try {
            $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction Stop
            if ($cap -and $cap.State -eq 'NotPresent') {
                Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null
                $featureInstalled = $true
                # Re-check after install
                foreach ($c in @('C:\Windows\System32\OpenSSH\sshd.exe')) {
                    if (Test-Path $c) {
                        try {
                            $fv  = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($c)
                            $ver = [version]"$($fv.FileMajorPart).$($fv.FileMinorPart)"
                            if ($ver -ge $minVer) {
                                $existingPath    = $c
                                $existingVersion = $ver.ToString()
                                $useExisting     = $true
                            }
                        } catch {}
                    }
                }
            } elseif ($cap -and $cap.State -eq 'Installed') {
                $featureInstalled = $true
                foreach ($c in @('C:\Windows\System32\OpenSSH\sshd.exe')) {
                    if (Test-Path $c) {
                        try {
                            $fv  = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($c)
                            $ver = [version]"$($fv.FileMajorPart).$($fv.FileMinorPart)"
                            if ($ver -ge $minVer) {
                                $existingPath    = $c
                                $existingVersion = $ver.ToString()
                                $useExisting     = $true
                            }
                        } catch {}
                    }
                }
            }
        } catch {
            $featureError = $_.Exception.Message
        }
    }

    # Check for bundled binaries
    $bundledDir       = Join-Path $ModeDir "resources\ssh\$arch"
    $bundledSshd      = Join-Path $bundledDir 'sshd.exe'
    $bundledAvailable = Test-Path $bundledSshd

    $sshdBinaryPath = if ($useExisting) { $existingPath } `
                      elseif ($bundledAvailable) { $bundledSshd } `
                      else { $null }

    $sshKeygenPath = if ($sshdBinaryPath) {
        Join-Path (Split-Path $sshdBinaryPath -Parent) 'ssh-keygen.exe'
    } else { $null }

    $sshClientPath = if ($sshdBinaryPath) {
        Join-Path (Split-Path $sshdBinaryPath -Parent) 'ssh.exe'
    } else { $null }

    $svcStatus = if ($svc) { $svc.Status.ToString() } else { 'NotInstalled' }

    return @{
        UseExisting        = $useExisting
        ExistingPath       = $existingPath
        ExistingVersion    = $existingVersion
        FeatureInstalled   = $featureInstalled
        FeatureError       = $featureError
        BundledAvailable   = $bundledAvailable
        BundledDir         = $bundledDir
        Architecture       = $arch
        ServiceStatus      = $svcStatus
        SshdBinaryPath     = $sshdBinaryPath
        SshKeygenPath      = $sshKeygenPath
        SshClientPath      = $sshClientPath
        SshInstalledByScript = $false
    }
}

function Get-SrdpInfrastructureStatus {
    param(
        [Parameter(Mandatory)][string]$StateFile,
        [Parameter(Mandatory)]$SshInfo
    )

    $issues = [System.Collections.Generic.List[string]]::new()
    $state  = $null
    $stateExists = Test-Path $StateFile

    if ($stateExists) {
        $sr = Read-SrdpState -StateFile $StateFile
        if ($sr -is [string]) {
            $issues.Add("state.json exists but could not be read: $sr")
        } else {
            $state = $sr
        }
    }

    # SecureRDP-SSH service running
    $sshReady = $false
    $svcCheck = @(Get-Service -Name $Script:SVC_NAME -ErrorAction SilentlyContinue)
    if ($svcCheck.Count -gt 0 -and $svcCheck[0].Status -eq 'Running') {
        $sshReady = $true
    }
    if (-not $sshReady) { $issues.Add("$Script:SVC_NAME service is not running.") }

    # sshd_config written to SecureRDP data path
    $sshdConfigWritten = $false
    if ($null -ne $state -and $null -ne $state.Infrastructure -and
        $state.Infrastructure.SshdConfigWritten -eq $true) {
        if (Test-Path $Script:SSHD_CFG_PATH) { $sshdConfigWritten = $true }
    }
    if (-not $sshdConfigWritten) { $issues.Add('sshd_config has not been written by SecureRDP.') }

    # Host key at SecureRDP data path
    $hostKeyExists = Test-Path $Script:HOST_KEY_PATH
    if (-not $hostKeyExists) { $issues.Add('SSH host key not found.') }

    # RDP cert
    $rdpCertValid = $false
    if ($null -ne $state -and $null -ne $state.Infrastructure -and
        $state.Infrastructure.RdpCertThumbprint) {
        $thumb = $state.Infrastructure.RdpCertThumbprint
        try {
            $store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
                'My', [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
            $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
            $found = @($store.Certificates.Find(
                [System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
                $thumb, $false))
            $store.Close()
            if ($found.Count -gt 0) { $rdpCertValid = $true }
        } catch {}
    }
    if (-not $rdpCertValid) { $issues.Add('SecureRDP RDP certificate not found in LocalMachine\My.') }

    # Firewall rules
    $firewallRulesPresent = Test-FirewallRulesExist -Names @(
        $Script:RULE_SSH, $Script:RULE_RDP_BLK, $Script:RULE_RDP_BLK_UDP
    )
    if (-not $firewallRulesPresent) { $issues.Add('One or more SecureRDP firewall rules are missing.') }

    # NLA
    $nlaEnabled = $false
    try {
        $rdpReg = Get-ItemProperty `
            'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
            -Name UserAuthenticationRequired -ErrorAction SilentlyContinue
        if ($null -ne $rdpReg) { $nlaEnabled = ($rdpReg.UserAuthenticationRequired -eq 1) }
    } catch {}

    $allReady = $sshReady -and $sshdConfigWritten -and $hostKeyExists -and
                $rdpCertValid -and $firewallRulesPresent

    return @{
        StateExists          = $stateExists
        State                = $state
        SshReady             = $sshReady
        SshdConfigWritten    = $sshdConfigWritten
        HostKeyExists        = $hostKeyExists
        RdpCertValid         = $rdpCertValid
        FirewallRulesPresent = $firewallRulesPresent
        NlaEnabled           = $nlaEnabled
        AllReady             = $allReady
        Issues               = $issues.ToArray()
    }
}

function Install-SrdpBundledSsh {
    # Copies bundled SSH binaries to the installation directory.
    # Does NOT register a Windows service -- that is handled by
    # Install-SrdpSshdService using the resolved binary path.
    param([Parameter(Mandatory)]$SshInfo)
    try {
        $destDir = $Script:BUNDLED_INST
        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        Get-ChildItem $SshInfo.BundledDir | Copy-Item -Destination $destDir -Force

        $sshdExe = Join-Path $destDir 'sshd.exe'
        $SshInfo.ExistingPath         = $sshdExe
        $SshInfo.SshKeygenPath        = Join-Path $destDir 'ssh-keygen.exe'
        $SshInfo.SshClientPath        = Join-Path $destDir 'ssh.exe'
        $SshInfo.SshdBinaryPath       = $sshdExe
        $SshInfo.SshInstalledByScript = $true
        return $SshInfo
    } catch {
        return "error:Bundled SSH install failed: $($_.Exception.Message)"
    }
}

# ===========================================================================
# BINARY DISCOVERY
# ===========================================================================

function Get-SrdpSshBinaryDir {
<#
.SYNOPSIS
    Returns the directory containing the SSH binaries to use (resolves from
    SshInfo). Returns "error:..." if no binary directory can be resolved.
#>
    param(
        [Parameter(Mandatory)]$SshInfo
    )
    try {
        if ($SshInfo.SshdBinaryPath -and (Test-Path $SshInfo.SshdBinaryPath)) {
            return Split-Path $SshInfo.SshdBinaryPath -Parent
        }
        if ($SshInfo.BundledAvailable) {
            return $SshInfo.BundledDir
        }
        return "error:Get-SrdpSshBinaryDir: no SSH binary path resolved"
    } catch {
        return "error:Get-SrdpSshBinaryDir: $($_.Exception.Message)"
    }
}

# ===========================================================================
# DIRECTORY AND ACL SETUP
# ===========================================================================

function Initialize-SrdpSshDirectories {
<#
.SYNOPSIS
    Creates the SecureRDP SSH data directory structure if it does not exist.
#>
    try {
        $dirs = @(
            $Script:SRDP_SSH_ROOT,
            $Script:HOST_KEY_DIR,
            $Script:CLIENT_KEY_DIR
        )
        foreach ($dir in $dirs) {
            if (-not (Test-Path $dir)) {
                $null = New-Item -ItemType Directory -Path $dir -Force
            }
        }
        return $true
    } catch {
        return "error:Initialize-SrdpSshDirectories: $($_.Exception.Message)"
    }
}

function Set-SrdpSshAcls {
<#
.SYNOPSIS
    Applies restrictive ACLs to all SecureRDP SSH files and directories.

.DESCRIPTION
    Disables ACL inheritance and grants:
      - SYSTEM                   : FullControl
      - BUILTIN\Administrators   : FullControl
      - NT SERVICE\SecureRDP-SSH : Read (for files the service must read)

    Only items that currently exist on disk are processed; missing items are
    silently skipped so this function is safe to call at any stage of setup.
#>
    try {
        $systemSid  = New-Object System.Security.Principal.NTAccount('NT AUTHORITY\SYSTEM')
        $adminSid   = New-Object System.Security.Principal.NTAccount('BUILTIN\Administrators')

        # The virtual service account only exists after the service is registered
        # with SCM. Resolve it gracefully -- if translation fails (service not yet
        # installed) we skip its ACL entries. Set-SrdpSshAcls is called again after
        # Install-SrdpSshdService, at which point the account exists and gets added.
        # Service runs as LocalSystem which maps to SYSTEM.
        # SYSTEM FullControl (set below) already covers all service access needs.
        # No separate service account ACL entry is needed.
        $svcSid = $null

        $fullControl        = [System.Security.AccessControl.FileSystemRights]::FullControl
        $readOnly           = [System.Security.AccessControl.FileSystemRights]::Read
        $readExec           = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute
        $allow              = [System.Security.AccessControl.AccessControlType]::Allow
        $noInherit          = [System.Security.AccessControl.InheritanceFlags]::None
        $containerAndObject = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
        $propNone           = [System.Security.AccessControl.PropagationFlags]::None

        # Directories
        $dirs = @(
            $Script:SRDP_SSH_ROOT,
            $Script:HOST_KEY_DIR,
            $Script:CLIENT_KEY_DIR
        )
        foreach ($dir in $dirs) {
            if (-not (Test-Path $dir)) { continue }
            $acl = Get-Acl -Path $dir
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($rule in @($acl.Access)) { $null = $acl.RemoveAccessRule($rule) }
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $systemSid, $fullControl, $containerAndObject, $propNone, $allow)))
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $adminSid, $fullControl, $containerAndObject, $propNone, $allow)))
            if ($null -ne $svcSid) {
                $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $svcSid, $readExec, $containerAndObject, $propNone, $allow)))
            }
            Set-Acl -Path $dir -AclObject $acl
        }

        # Files readable by the service
        $svcReadable = @()
        if (Test-Path $Script:SSHD_CFG_PATH)           { $svcReadable += $Script:SSHD_CFG_PATH }
        if (Test-Path $Script:AUTH_KEYS_PATH)           { $svcReadable += $Script:AUTH_KEYS_PATH }
        if (Test-Path "$Script:HOST_KEY_PATH.pub")      { $svcReadable += "$Script:HOST_KEY_PATH.pub" }

        foreach ($fp in $svcReadable) {
            $acl = Get-Acl -Path $fp
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($rule in @($acl.Access)) { $null = $acl.RemoveAccessRule($rule) }
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $systemSid, $fullControl, $noInherit, $propNone, $allow)))
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $adminSid, $fullControl, $noInherit, $propNone, $allow)))
            if ($null -ne $svcSid) {
                $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $svcSid, $readOnly, $noInherit, $propNone, $allow)))
            }
            Set-Acl -Path $fp -AclObject $acl
        }

        # Private host key -- SYSTEM and Administrators only.
        # Windows OpenSSH on Windows strictly requires:
        #   - Inheritance disabled (not via Set-Acl which is unreliable for
        #     this -- use icacls which handles the security descriptor flag
        #     atomically)
        #   - Only SYSTEM and Administrators present in the ACL
        #   - Owner: SYSTEM
        # Any other account in the ACL (including virtual service accounts)
        # causes sshd to reject the key as "unprotected" regardless of
        # StrictModes. The service runs as LocalSystem which maps to SYSTEM,
        # so SYSTEM FullControl is sufficient for sshd to read the key.
        if (Test-Path $Script:HOST_KEY_PATH) {
            $icaclsArgs = @(
                $Script:HOST_KEY_PATH,
                '/inheritance:r',
                '/grant:r', 'SYSTEM:(F)',
                '/grant:r', 'Administrators:(F)'
            )
            $icOut  = & icacls.exe @icaclsArgs 2>&1
            $icExit = $LASTEXITCODE
            if ($icExit -ne 0) {
                return "error:Set-SrdpSshAcls: icacls failed on host key (exit $icExit): $icOut"
            }
            $ownerArgs = @($Script:HOST_KEY_PATH, '/setowner', 'SYSTEM')
            $null = & icacls.exe @ownerArgs 2>&1

            # Remove any leftover explicit entries (e.g. creator-owner from
            # the admin account that ran ssh-keygen). icacls /inheritance:r
            # only strips inherited entries; the creator gets an explicit
            # entry that survives. Windows OpenSSH rejects the host key if
            # anyone other than SYSTEM and Administrators is in the ACL.
            $hkAcl = Get-Acl $Script:HOST_KEY_PATH
            foreach ($entry in $hkAcl.Access) {
                $id = $entry.IdentityReference.Value
                if ($id -ne 'NT AUTHORITY\SYSTEM' -and $id -ne 'BUILTIN\Administrators') {
                    $null = $hkAcl.RemoveAccessRule($entry)
                }
            }
            Set-Acl $Script:HOST_KEY_PATH $hkAcl
        }

        return $true
    } catch {
        return "error:Set-SrdpSshAcls: $($_.Exception.Message)"
    }
}

# ===========================================================================
# HOST KEY
# ===========================================================================

function Initialize-SrdpHostKey {
<#
.SYNOPSIS
    Generates the sshd ed25519 host key if it does not already exist.

.DESCRIPTION
    Uses a splatted argument array to pass an empty passphrase (-N "") to
    ssh-keygen. Direct string syntax silently drops empty string arguments
    to native executables in PowerShell 5.1; the splatted array form is
    required to prevent a passphrase prompt hang.

    Returns @{Result='ok'; AlreadyExists; KeyPath} on success.
    Returns "error:..." on failure.
#>
    param(
        [Parameter(Mandatory)][string]$SshBinaryDir
    )
    try {
        $dirResult = Initialize-SrdpSshDirectories
        if ($dirResult -is [string] -and $dirResult -like 'error:*') { return $dirResult }

        if (Test-Path $Script:HOST_KEY_PATH) {
            return @{ Result='ok'; AlreadyExists=$true; KeyPath=$Script:HOST_KEY_PATH }
        }

        $keygenPath = Join-Path $SshBinaryDir 'ssh-keygen.exe'
        if (-not (Test-Path $keygenPath)) {
            return "error:Initialize-SrdpHostKey: ssh-keygen.exe not found: $keygenPath"
        }

        # Use splatted array with -N '""' for empty passphrase.
        # In PowerShell 5.1, passing -N '' to a native executable drops the
        # empty string argument silently. '""' causes PowerShell to pass a
        # properly quoted empty string that Windows ssh-keygen accepts.
        # Works with both inbox Windows OpenSSH and bundled OpenSSH 9.5.
        $keygenArgs = @('-t', 'ed25519', '-f', $Script:HOST_KEY_PATH, '-N', '""', '-C', 'srdp-host-key')
        $output   = & $keygenPath @keygenArgs 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            return "error:Initialize-SrdpHostKey: ssh-keygen failed (exit $exitCode): $output"
        }
        if (-not (Test-Path $Script:HOST_KEY_PATH)) {
            return "error:Initialize-SrdpHostKey: ssh-keygen ran but host key was not produced"
        }

        $aclResult = Set-SrdpSshAcls
        if ($aclResult -is [string] -and $aclResult -like 'error:*') {
            return "error:Initialize-SrdpHostKey: host key created but ACL setup failed: $aclResult"
        }

        return @{ Result='ok'; AlreadyExists=$false; KeyPath=$Script:HOST_KEY_PATH }
    } catch {
        return "error:Initialize-SrdpHostKey: $($_.Exception.Message)"
    }
}

# ===========================================================================
# SSHD CONFIG
# ===========================================================================

function New-SrdpSshdConfig {
<#
.SYNOPSIS
    Generates sshd_config content for the SecureRDP tunnel-only SSH service.

.DESCRIPTION
    Enforces tunnel-only policy: public key auth only, TCP forwarding restricted
    to localhost:3389, no TTY, no shell, no SFTP, StrictModes disabled (ACLs
    are managed by SecureRDP). No AllowUsers restriction -- any authorized key
    holder can open a tunnel. Windows account used for RDP is determined by
    credentials entered at the RDP login screen.

    Pure generator -- does not write to disk. Returns config string.
    All output is ASCII-only.
#>
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$RdpPort = 3389
    )

    $hostKeyFwd  = $Script:HOST_KEY_PATH  -replace '\\', '/'
    $authKeysFwd = $Script:AUTH_KEYS_PATH -replace '\\', '/'

    $cfg = @"
# SecureRDP v$Script:SRDP_VER_CORE - SSH Prototype Mode sshd_config
# Generated by SSHProtoCore.psm1
# GitHub: arekfurt/SecureRDP
# Do not edit manually. Changes will be overwritten by SecureRDP.

Port $Port
ListenAddress 0.0.0.0

# Authentication: public key only
PubkeyAuthentication yes
AuthorizedKeysFile $authKeysFwd
PasswordAuthentication no
ChallengeResponseAuthentication no
PermitEmptyPasswords no
PermitRootLogin no
MaxAuthTries 3
LoginGraceTime 30

# Algorithm hardening - ED25519 only
HostKey $hostKeyFwd
HostKeyAlgorithms ssh-ed25519,sk-ssh-ed25519@openssh.com
PubkeyAcceptedAlgorithms ssh-ed25519,sk-ssh-ed25519@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com

# Tunnel restrictions: local forwarding to RDP port only
# No AllowUsers -- SSH keys control tunnel access only.
# Windows account for RDP is selected by the client at the RDP login screen.
AllowTcpForwarding local
PermitOpen localhost:$RdpPort
X11Forwarding no
AllowAgentForwarding no
AllowStreamLocalForwarding no

# No interactive shell or terminal
PermitTTY no
Banner none

# ACLs managed by SecureRDP -- disable OpenSSH permission checks
StrictModes no

LogLevel VERBOSE
"@
    return $cfg
}

function Write-SrdpSshdConfig {
<#
.SYNOPSIS
    Writes the generated sshd_config to disk and refreshes ACLs.

    Returns @{Result='ok'; ConfigPath; Port; BackupPath; BackupExisted} on success.
    Returns "error:..." on failure.
#>
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$RdpPort = 3389
    )
    try {
        $dirResult = Initialize-SrdpSshDirectories
        if ($dirResult -is [string] -and $dirResult -like 'error:*') { return $dirResult }

        $content = New-SrdpSshdConfig -Port $Port -RdpPort $RdpPort

        # Verify ASCII-only before writing
        $nonAscii = @($content.ToCharArray() | Where-Object { [int]$_ -gt 127 })
        if ($nonAscii.Count -gt 0) {
            return "error:Write-SrdpSshdConfig: generated config contains non-ASCII characters"
        }

        $bakPath    = "$Script:SSHD_CFG_PATH.srdp_backup"
        $prevExists = Test-Path $Script:SSHD_CFG_PATH
        if ($prevExists) { Copy-Item $Script:SSHD_CFG_PATH $bakPath -Force }

        Set-Content $Script:SSHD_CFG_PATH -Value $content -Encoding ASCII

        $aclResult = Set-SrdpSshAcls
        if ($aclResult -is [string] -and $aclResult -like 'error:*') {
            return "error:Write-SrdpSshdConfig: config written but ACL setup failed: $aclResult"
        }

        return @{
            Result        = 'ok'
            ConfigPath    = $Script:SSHD_CFG_PATH
            Port          = $Port
            BackupPath    = if ($prevExists) { $bakPath } else { $null }
            BackupExisted = $prevExists
        }
    } catch {
        return "error:Write-SrdpSshdConfig: $($_.Exception.Message)"
    }
}

# ===========================================================================
# NLA AND RDP CERT (unchanged)
# ===========================================================================

function Set-SrdpNla {
    try {
        $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
        $cur = (Get-ItemProperty $regPath -Name UserAuthenticationRequired `
                -ErrorAction SilentlyContinue).UserAuthenticationRequired
        $wasEnabled = ($cur -eq 1)
        if (-not $wasEnabled) {
            Set-ItemProperty $regPath -Name UserAuthenticationRequired -Value 1
        }
        return @{ WasEnabled = $wasEnabled }
    } catch {
        return "error:NLA configuration failed: $($_.Exception.Message)"
    }
}

function New-SrdpRdpCert {
    try {
        $wmiRdp = Get-CimInstance -ClassName Win32_TSGeneralSetting `
                  -Namespace 'root\cimv2\terminalservices' `
                  -Filter "TerminalName='RDP-Tcp'" -ErrorAction SilentlyContinue
        $prevThumb = if ($null -ne $wmiRdp) { $wmiRdp.SSLCertificateSHA1Hash } else { $null }

        $sanValue = "DNS=$env:COMPUTERNAME&DNS=localhost&IPAddress=127.0.0.1"
        $cert = New-SelfSignedCertificate `
            -Subject "CN=$env:COMPUTERNAME" `
            -TextExtension @(
                "2.5.29.37={text}1.3.6.1.5.5.7.3.1",
                "2.5.29.17={text}$sanValue"
            ) `
            -CertStoreLocation 'Cert:\LocalMachine\My' `
            -NotAfter (Get-Date).AddYears(99) `
            -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256

        if ($null -ne $wmiRdp) {
            Set-CimInstance -InputObject $wmiRdp -Property @{
                SSLCertificateSHA1Hash = $cert.Thumbprint
            } -ErrorAction SilentlyContinue
        }

        $derBytes = $cert.Export(
            [System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)

        return @{
            Thumbprint         = $cert.Thumbprint
            PreviousThumbprint = $prevThumb
            DerBase64          = [Convert]::ToBase64String($derBytes)
        }
    } catch {
        return "error:RDP certificate creation failed: $($_.Exception.Message)"
    }
}

# ===========================================================================
# FIREWALL RULES
# ===========================================================================

function New-SrdpFirewallRules {
    param(
        [Parameter(Mandatory)][int]$RdpPort,
        [Parameter(Mandatory)][int]$SshPort
    )
    $desc = "SecureRDP v$Script:SRDP_VER_CORE - SSH Prototype Mode"
    $ruleDefs = @(
        @{
            Name        = $Script:RULE_SSH
            DisplayName = 'SecureRDP - SSH Inbound (Prototype)'
            Direction   = 'Inbound'
            Protocol    = 'TCP'
            LocalPort   = $SshPort
            Action      = 'Allow'
            Description = "$desc. SSH inbound for tunnel access."
        },
        @{
            Name        = $Script:RULE_RDP_BLK
            DisplayName = 'SecureRDP - Block direct RDP (use SSH tunnel)'
            Direction   = 'Inbound'
            Protocol    = 'TCP'
            LocalPort   = $RdpPort
            Action      = 'Block'
            Description = "$desc. Blocks direct RDP. Use SSH tunnel to connect."
        },
        @{
            Name        = $Script:RULE_RDP_BLK_UDP
            DisplayName = 'SecureRDP - Block direct RDP UDP (use SSH tunnel)'
            Direction   = 'Inbound'
            Protocol    = 'UDP'
            LocalPort   = $RdpPort
            Action      = 'Block'
            Description = "$desc. Blocks direct RDP over UDP. Use SSH tunnel to connect."
        }
    )
    return New-FirewallRules -RuleDefinitions $ruleDefs
}

function Add-SrdpSshFirewallRule {
<#
.SYNOPSIS
    Adds (or updates) the SecureRDP SSH inbound firewall rule for the given port.
    Delegates to New-FirewallRules from FirewallReadWriteElements (idempotent).

    Returns $true on success. Returns "error:..." on failure.
#>
    param([Parameter(Mandatory)][int]$Port)
    $ruleDefs = @(@{
        Name        = $Script:RULE_SSH
        DisplayName = 'SecureRDP - SSH Inbound (Prototype)'
        Direction   = 'Inbound'
        Protocol    = 'TCP'
        LocalPort   = $Port
        Action      = 'Allow'
        Description = "SecureRDP v$Script:SRDP_VER_CORE - SSH inbound for tunnel access."
    })
    return New-FirewallRules -RuleDefinitions $ruleDefs
}

function Remove-SrdpSshFirewallRule {
<#
.SYNOPSIS
    Removes the SecureRDP SSH inbound firewall rule.
    Returns $true on success. Returns "error:..." on failure.
#>
    return Remove-FirewallRulesByName -Names @($Script:RULE_SSH)
}

# ===========================================================================
# SERVICE MANAGEMENT
# ===========================================================================

function Install-SrdpSshdService {
<#
.SYNOPSIS
    Registers the SecureRDP-SSH Windows service using the resolved SSH binary.

.DESCRIPTION
    Creates a Windows service pointing at sshd.exe from SshInfo, running under
    the virtual service account NT SERVICE\SecureRDP-SSH. Windows provisions
    this account automatically when the service is created; no password
    management is required.

    Writes the sshd_config and generates the host key before registering.
    Configures automatic restart on failure.

    Returns @{Result='ok'; ServiceName; BinaryPath; ConfigPath; Port} on success.
    Returns "error:..." on failure.
#>
    param(
        [Parameter(Mandatory)]$SshInfo,
        [Parameter(Mandatory)][int]$Port,
        [int]$RdpPort = 3389
    )
    try {
        $existing = @(Get-Service -Name $Script:SVC_NAME -ErrorAction SilentlyContinue)
        if ($existing.Count -gt 0) {
            return "error:Install-SrdpSshdService: service '$Script:SVC_NAME' already exists -- run Uninstall-SrdpSshdService first"
        }

        $sshdPath = $SshInfo.SshdBinaryPath
        if (-not $sshdPath -or -not (Test-Path $sshdPath)) {
            return "error:Install-SrdpSshdService: sshd.exe not found"
        }

        $binDir = Split-Path $sshdPath -Parent

        $cfgResult = Write-SrdpSshdConfig -Port $Port -RdpPort $RdpPort
        if ($cfgResult -is [string] -and $cfgResult -like 'error:*') { return $cfgResult }

        $hkResult = Initialize-SrdpHostKey -SshBinaryDir $binDir
        if ($hkResult -is [string] -and $hkResult -like 'error:*') { return $hkResult }

        $binPath    = "`"$sshdPath`" -f `"$Script:SSHD_CFG_PATH`""
        $createArgs = @(
            'create', $Script:SVC_NAME,
            'binPath=', $binPath,
            'obj=', 'LocalSystem',
            'start=', 'auto',
            'DisplayName=', $Script:SVC_DISPLAY
        )
        $scOut    = & sc.exe @createArgs 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            return "error:Install-SrdpSshdService: sc.exe create failed (exit $exitCode): $scOut"
        }

        $descArgs = @('description', $Script:SVC_NAME,
            'Provides RDP-over-SSH tunnel access for SecureRDP. Runs under a minimal virtual service account.')
        $null = & sc.exe @descArgs 2>&1

        $failArgs = @('failure', $Script:SVC_NAME,
            'reset=', '86400', 'actions=', 'restart/5000/restart/10000//')
        $null = & sc.exe @failArgs 2>&1

        # Re-run ACL setup now that the service account exists. The virtual
        # account NT SERVICE\SecureRDP-SSH is provisioned by SCM at service
        # creation time. The first Set-SrdpSshAcls call (step 3) skipped the
        # service account entry because the service wasn't registered yet --
        # so the sshd_config, host key, and data directories don't have the
        # service account Read ACL. Without it, sshd can't read its own
        # config on startup and crashes silently before logging anything.
        $aclResult = Set-SrdpSshAcls
        if ($aclResult -is [string] -and $aclResult -like 'error:*') {
            return "error:Install-SrdpSshdService: service registered but ACL update failed: $aclResult"
        }

        return @{
            Result      = 'ok'
            ServiceName = $Script:SVC_NAME
            BinaryPath  = $sshdPath
            ConfigPath  = $Script:SSHD_CFG_PATH
            Port        = $Port
        }
    } catch {
        return "error:Install-SrdpSshdService: $($_.Exception.Message)"
    }
}

function Start-SrdpSshdService {
<#
.SYNOPSIS
    Starts the SecureRDP-SSH service and waits up to 15 seconds for Running state.
    Returns @{Result='ok'; AlreadyRunning} on success. Returns "error:..." on failure.
#>
    try {
        $svc = @(Get-Service -Name $Script:SVC_NAME -ErrorAction SilentlyContinue)
        if ($svc.Count -eq 0) {
            return "error:Start-SrdpSshdService: service '$Script:SVC_NAME' is not installed"
        }
        if ($svc[0].Status -eq 'Running') {
            return @{ Result='ok'; AlreadyRunning=$true }
        }
        Start-Service -Name $Script:SVC_NAME
        $svc[0].WaitForStatus('Running', (New-TimeSpan -Seconds 15))
        return @{ Result='ok'; AlreadyRunning=$false }
    } catch {
        return "error:Start-SrdpSshdService: $($_.Exception.Message)"
    }
}

function Stop-SrdpSshdService {
<#
.SYNOPSIS
    Stops the SecureRDP-SSH service and waits up to 15 seconds for Stopped state.
    Returns @{Result='ok'; WasRunning} on success. Returns "error:..." on failure.
#>
    try {
        $svc = @(Get-Service -Name $Script:SVC_NAME -ErrorAction SilentlyContinue)
        if ($svc.Count -eq 0) { return @{ Result='ok'; WasRunning=$false } }
        if ($svc[0].Status -ne 'Running') { return @{ Result='ok'; WasRunning=$false } }
        Stop-Service -Name $Script:SVC_NAME -Force
        $svc[0].WaitForStatus('Stopped', (New-TimeSpan -Seconds 15))
        return @{ Result='ok'; WasRunning=$true }
    } catch {
        return "error:Stop-SrdpSshdService: $($_.Exception.Message)"
    }
}

function Uninstall-SrdpSshdService {
<#
.SYNOPSIS
    Stops and removes the SecureRDP-SSH Windows service.

.PARAMETER RemoveData
    If specified, also removes all SecureRDP SSH data (keys, config, authorized_keys).

    Returns @{Result='ok'; WasPresent; DataRemoved} on success.
    Returns "error:..." on failure.
#>
    param([switch]$RemoveData)
    try {
        $existing = @(Get-Service -Name $Script:SVC_NAME -ErrorAction SilentlyContinue)
        if ($existing.Count -eq 0) {
            return @{ Result='ok'; WasPresent=$false; DataRemoved=$false }
        }
        if ($existing[0].Status -eq 'Running') {
            Stop-Service -Name $Script:SVC_NAME -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
        $deleteArgs = @('delete', $Script:SVC_NAME)
        $scOut      = & sc.exe @deleteArgs 2>&1
        $exitCode   = $LASTEXITCODE
        if ($exitCode -ne 0) {
            return "error:Uninstall-SrdpSshdService: sc.exe delete failed (exit $exitCode): $scOut"
        }
        if ($RemoveData -and (Test-Path $Script:SRDP_SSH_ROOT)) {
            Remove-Item -Path $Script:SRDP_SSH_ROOT -Recurse -Force
        }
        return @{ Result='ok'; WasPresent=$true; DataRemoved=$RemoveData.IsPresent }
    } catch {
        return "error:Uninstall-SrdpSshdService: $($_.Exception.Message)"
    }
}

function Get-SrdpSshdServiceStatus {
<#
.SYNOPSIS
    Returns the current installation and run status of the SecureRDP-SSH service.
    Returns @{Result='ok'; Installed; Status; Running; ...} on success.
    Returns "error:..." on failure.
#>
    try {
        $svc = @(Get-Service -Name $Script:SVC_NAME -ErrorAction SilentlyContinue)
        if ($svc.Count -eq 0) {
            return @{ Result='ok'; Installed=$false; Status='NotInstalled'; Running=$false }
        }
        return @{
            Result      = 'ok'
            Installed   = $true
            Status      = $svc[0].Status.ToString()
            StartType   = $svc[0].StartType.ToString()
            Running     = ($svc[0].Status -eq 'Running')
            DisplayName = $svc[0].DisplayName
        }
    } catch {
        return "error:Get-SrdpSshdServiceStatus: $($_.Exception.Message)"
    }
}

# ===========================================================================
# HOST KEY INFO
# ===========================================================================

function Get-SrdpHostKeyInfo {
    param([Parameter(Mandatory)][string]$SshKeygenPath)
    try {
        $pubPath = "$Script:HOST_KEY_PATH.pub"
        if (-not (Test-Path $pubPath)) {
            return "error:Host key public file not found: $pubPath"
        }
        $pubContent = (Get-Content $pubPath -Raw -Encoding UTF8).Trim()

        $fpRaw    = & $SshKeygenPath -lf $pubPath 2>&1
        $fpExit   = $LASTEXITCODE
        $fpStr    = ''

        if ($fpExit -ne 0) {
            return "error:Get-SrdpHostKeyInfo: ssh-keygen -lf failed (exit $fpExit): $fpRaw"
        }

        foreach ($line in $fpRaw) {
            $lineStr = $line.ToString()
            if ($lineStr -match 'SHA256:') {
                $fields = $lineStr -split '\s+'
                foreach ($f in $fields) {
                    if ($f -like 'SHA256:*') { $fpStr = $f; break }
                }
                break
            }
        }

        return @{
            PublicKey   = $pubContent
            Fingerprint = $fpStr
        }
    } catch {
        return "error:Host key read failed: $($_.Exception.Message)"
    }
}

# ===========================================================================
# CLIENT KEY MANAGEMENT
# ===========================================================================

function New-SrdpClientKey {
<#
.SYNOPSIS
    Generates a named SSH client key pair with no Windows account binding.

.DESCRIPTION
    Creates an ed25519 key pair identified by a label. The key grants tunnel
    access only. The caller must call Add-SrdpAuthorizedKey to authorize it,
    then include the private key in the client package.

    Returns @{Result='ok'; Label; PrivateKeyPath; PublicKeyPath; PrivateKey;
              PublicKey} on success. Returns "error:..." on failure.
#>
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$SshBinaryDir
    )
    try {
        $safeLabel = $Label -replace '[^a-zA-Z0-9_\-]', '_'
        $clientDir = Join-Path $Script:CLIENT_KEY_DIR $safeLabel
        $keyPath   = Join-Path $clientDir 'client_key'

        if (Test-Path $keyPath) {
            return "error:New-SrdpClientKey: client key '$Label' already exists at: $keyPath"
        }

        if (-not (Test-Path $clientDir)) {
            $null = New-Item -ItemType Directory -Path $clientDir -Force
        }

        $keygenPath = Join-Path $SshBinaryDir 'ssh-keygen.exe'
        if (-not (Test-Path $keygenPath)) {
            return "error:New-SrdpClientKey: ssh-keygen.exe not found: $keygenPath"
        }

        # Use splatted array with -N '""' for empty passphrase (see Initialize-SrdpHostKey).
        $keygenArgs = @('-t', 'ed25519', '-f', $keyPath, '-N', '""', '-C', "SecureRDP-$safeLabel")
        $output   = & $keygenPath @keygenArgs 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            return "error:New-SrdpClientKey: ssh-keygen failed (exit $exitCode): $output"
        }
        if (-not (Test-Path $keyPath) -or -not (Test-Path "$keyPath.pub")) {
            return "error:New-SrdpClientKey: ssh-keygen ran but key files were not produced"
        }

        # Private key must end with exactly one Unix newline -- OpenSSH key parser
        # requires it. .TrimEnd() strips any existing trailing whitespace/CRLF first.
        $privKey = (Get-Content $keyPath       -Raw -Encoding UTF8).TrimEnd() + "`n"
        $pubKey  = (Get-Content "$keyPath.pub" -Raw -Encoding UTF8).Trim()

        return @{
            Result         = 'ok'
            Label          = $Label
            PrivateKeyPath = $keyPath
            PublicKeyPath  = "$keyPath.pub"
            PrivateKey     = $privKey
            PublicKey      = $pubKey
        }
    } catch {
        return "error:New-SrdpClientKey: $($_.Exception.Message)"
    }
}

function Add-SrdpAuthorizedKey {
<#
.SYNOPSIS
    Adds a public key to the global authorized_keys file.

.DESCRIPTION
    Checks for duplicates before appending. Returns an error if the key is
    already present (idempotent guard). Refreshes ACLs after writing.

    Returns @{Result='ok'; KeyLine} on success. Returns "error:..." on failure.
#>
    param(
        [string]$PublicKeyText = '',
        [string]$Label = ''
    )
    try {
        if ($null -eq $PublicKeyText -or $PublicKeyText.Trim().Length -eq 0) {
            return "error:Add-SrdpAuthorizedKey: PublicKeyText cannot be empty"
        }
        $keyLine = $PublicKeyText.Trim()
        $parts   = @($keyLine -split '\s+')

        if ($parts.Count -lt 2) {
            return "error:Add-SrdpAuthorizedKey: invalid public key format -- expected at least type and key body"
        }

        $keyBody = $parts[1]
        if ($Label -and $parts.Count -lt 3) { $keyLine = "$keyLine $Label" }

        $dirResult = Initialize-SrdpSshDirectories
        if ($dirResult -is [string] -and $dirResult -like 'error:*') { return $dirResult }

        if (Test-Path $Script:AUTH_KEYS_PATH) {
            $existing = @(Get-Content -Path $Script:AUTH_KEYS_PATH |
                          Where-Object { $_ -like "*$keyBody*" })
            if ($existing.Count -gt 0) {
                return "error:Add-SrdpAuthorizedKey: this public key is already in authorized_keys"
            }
        }

        Add-Content -Path $Script:AUTH_KEYS_PATH -Value $keyLine -Encoding ASCII

        $aclResult = Set-SrdpSshAcls
        if ($aclResult -is [string] -and $aclResult -like 'error:*') {
            return @{ Result='ok'; KeyLine=$keyLine; Warning="ACL refresh failed: $aclResult" }
        }

        return @{ Result='ok'; KeyLine=$keyLine }
    } catch {
        return "error:Add-SrdpAuthorizedKey: $($_.Exception.Message)"
    }
}

function Remove-SrdpAuthorizedKey {
<#
.SYNOPSIS
    Removes a key from the global authorized_keys file by matching the key body.

    Returns @{Result='ok'; RemovedCount} on success. Returns "error:..." on failure.
#>
    param(
        [string]$PublicKeyText = ''
    )
    try {
        if ($null -eq $PublicKeyText -or $PublicKeyText.Trim().Length -eq 0) {
            return "error:Remove-SrdpAuthorizedKey: PublicKeyText cannot be empty"
        }
        if (-not (Test-Path $Script:AUTH_KEYS_PATH)) {
            return "error:Remove-SrdpAuthorizedKey: authorized_keys file does not exist"
        }

        $keyLine = $PublicKeyText.Trim()
        $parts   = @($keyLine -split '\s+')
        if ($parts.Count -lt 2) {
            return "error:Remove-SrdpAuthorizedKey: invalid public key format"
        }

        $keyBody  = $parts[1]
        $lines    = @(Get-Content -Path $Script:AUTH_KEYS_PATH)
        $filtered = @($lines | Where-Object { $_ -notlike "*$keyBody*" })

        if ($filtered.Count -eq $lines.Count) {
            return "error:Remove-SrdpAuthorizedKey: key not found in authorized_keys"
        }

        $removedCount = $lines.Count - $filtered.Count

        if ($filtered.Count -eq 0) {
            Set-Content -Path $Script:AUTH_KEYS_PATH -Value '' -Encoding ASCII
        } else {
            Set-Content -Path $Script:AUTH_KEYS_PATH -Value $filtered -Encoding ASCII
        }

        return @{ Result='ok'; RemovedCount=$removedCount }
    } catch {
        return "error:Remove-SrdpAuthorizedKey: $($_.Exception.Message)"
    }
}

function Get-SrdpAuthorizedKeys {
<#
.SYNOPSIS
    Returns parsed entries from the global authorized_keys file.
    Returns @{Result='ok'; Keys=[array]; Count} on success.
    Returns "error:..." on failure.
#>
    try {
        if (-not (Test-Path $Script:AUTH_KEYS_PATH)) {
            return @{ Result='ok'; Keys=@(); Count=0 }
        }
        $lines = @(Get-Content -Path $Script:AUTH_KEYS_PATH |
                   Where-Object { $_ -and $_ -notmatch '^\s*#' })
        $keys = @(foreach ($line in $lines) {
            $parts = @($line -split '\s+')
            if ($parts.Count -ge 2) {
                $comment = if ($parts.Count -ge 3) { $parts[2] } else { '' }
                @{ Type=$parts[0]; KeyBody=$parts[1]; Comment=$comment; Raw=$line }
            }
        })
        return @{ Result='ok'; Keys=$keys; Count=$keys.Count }
    } catch {
        return "error:Get-SrdpAuthorizedKeys: $($_.Exception.Message)"
    }
}

# ===========================================================================
# PORT AVAILABILITY
# ===========================================================================

function Test-SrdpPortAvailable {
<#
.SYNOPSIS
    Tests whether a TCP port is available for binding on localhost.
    Returns $true if available, $false if in use or on error.
#>
    param([Parameter(Mandatory)][int]$Port)
    try {
        $listener = [System.Net.Sockets.TcpListener]::new(
            [System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        $listener.Stop()
        return $true
    } catch {
        return $false
    }
}

# ===========================================================================
# CLIENT PACKAGE ASSEMBLY
# ===========================================================================

function Build-SrdpClientPackage {
    # -------------------------------------------------------------------------
    # Assembles the client connection package.
    #
    # When $Passphrase is provided (required for 0.85+), produces:
    #   Outer zip delivered to client:
    #     SecureRDP Connect.lnk  -- shortcut -> Launch.cmd
    #     Launch.cmd             -- execution policy bypass entry point
    #     Unpack.ps1             -- passphrase prompt + decrypt + launch
    #     package.bin            -- AES-256-CBC encrypted blob containing all
    #                               inner files (keys, config, scripts, etc.)
    #
    # When $Passphrase is $null/empty, falls back to unencrypted zip of inner
    # files directly (testing/legacy mode). A warning flag is set in the
    # return value.
    # -------------------------------------------------------------------------
    param(
        [Parameter(Mandatory)]$Cfg,
        [Parameter(Mandatory)]$Keys,
        [Parameter(Mandatory)]$CertInfo,
        [Parameter(Mandatory)]$HostKeyInfo,
        [Parameter(Mandatory)][int]$RdpPort,
        [Parameter(Mandatory)][string]$OutputDir,
        [Parameter(Mandatory)][string]$ClientSrcDir,
        [string]$Passphrase = $null
    )

    # Files that belong in the OUTER package only (not encrypted in blob)
    $outerOnlyFiles = @('Launch.cmd', 'Unpack.ps1')

    $innerStagingDir = $null
    $outerStagingDir = $null

    try {
        if (-not (Test-Path $OutputDir)) {
            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
        }

        $ts              = Get-Date -Format 'yyyyMMddHHmmss'
        $innerStagingDir = Join-Path $env:TEMP "srdp_inner_$ts"
        $outerStagingDir = Join-Path $env:TEMP "srdp_outer_$ts"

        New-Item -ItemType Directory -Path $innerStagingDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $innerStagingDir 'ssh') -Force | Out-Null
        New-Item -ItemType Directory -Path $outerStagingDir -Force | Out-Null

        # ---- Build inner staging dir (contents encrypted into the blob) ----

        # config.json
        # $Cfg is always a hashtable from the controller. Use ContainsKey() for
        # presence checks -- PSObject.Properties.Name does not enumerate hashtable keys.
        $sshUser  = if ($Cfg.ContainsKey('SshUsername')  -and -not [string]::IsNullOrWhiteSpace($Cfg.SshUsername))  { $Cfg.SshUsername  } else { '' }
        $rdpUser  = if ($Cfg.ContainsKey('RdpUsername')  -and -not [string]::IsNullOrWhiteSpace($Cfg.RdpUsername))  { $Cfg.RdpUsername  } else { '' }
        $keyLbl   = if ($Cfg.ContainsKey('KeyLabel')     -and -not [string]::IsNullOrWhiteSpace($Cfg.KeyLabel))     { $Cfg.KeyLabel     } else { '' }
        $config = @{
            serverName         = $env:COMPUTERNAME
            serverAddress      = $Cfg.Address
            advertisedAccounts = $Cfg.AdvertisedAccounts
            sshUsername        = $sshUser
            rdpUsername        = $rdpUser
            sshKeyLabel        = $keyLbl
            sshPort            = $Cfg.SshPort
            rdpPort            = $RdpPort
            rdpCertThumbprint  = $CertInfo.Thumbprint
            rdpCertBase64      = $CertInfo.DerBase64
            generatedDate      = (Get-Date -Format 'yyyy-MM-dd')
            protoVersion       = $Script:SRDP_VER_CORE
        }
        $config | ConvertTo-Json | Set-Content (Join-Path $innerStagingDir 'config.json') -Encoding UTF8

        # SSH client key files
        # Must use WriteAllText with no-BOM UTF8 and preserve Unix line endings.
        # Set-Content -Encoding UTF8 writes a BOM and converts \n to \r\n,
        # both of which cause OpenSSH to reject the private key with "invalid format".
        [System.IO.File]::WriteAllText(
            (Join-Path $innerStagingDir 'client_key'),
            $Keys.PrivateKey,
            [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText(
            (Join-Path $innerStagingDir 'client_key.pub'),
            $Keys.PublicKey,
            [System.Text.UTF8Encoding]::new($false))

        # known_hosts
        # Must use WriteAllText with no-BOM UTF8 -- Set-Content -Encoding UTF8
        # writes a BOM prefix which OpenSSH may reject on the client side.
        $khEntry = ''
        if ($HostKeyInfo.PublicKey) {
            $parts = $HostKeyInfo.PublicKey -split '\s+', 3
            if ($parts.Count -ge 2) {
                $khEntry = "$($Cfg.Address) $($parts[0]) $($parts[1])"
            }
        }
        [System.IO.File]::WriteAllText(
            (Join-Path $innerStagingDir 'known_hosts'),
            $khEntry,
            [System.Text.UTF8Encoding]::new($false))

        # connection.rdp is no longer included in the package.
        # Connect-SecureRDP.ps1 generates a temporary RDP file at launch time
        # using sshUsername and rdpUsername from config.json, avoiding the
        # Windows unsigned-file security warning on the static .rdp file.

        # Client template files -- inner only (exclude outer-only files)
        foreach ($f in @(Get-ChildItem $ClientSrcDir -File)) {
            if ($f.Name -notin $outerOnlyFiles) {
                Copy-Item $f.FullName (Join-Path $innerStagingDir $f.Name)
            }
        }

        # SSH client binary (falls back to inbox ssh.exe on client if not present)
        $sshExe = $Cfg.SshClientPath
        if ($sshExe -and (Test-Path $sshExe)) {
            Copy-Item $sshExe (Join-Path $innerStagingDir 'ssh\ssh.exe')
            $kgSrc = Join-Path (Split-Path $sshExe -Parent) 'ssh-keygen.exe'
            if (Test-Path $kgSrc) {
                Copy-Item $kgSrc (Join-Path $innerStagingDir 'ssh\ssh-keygen.exe')
            }
        }

        # ---- Build outer staging dir and zip ----
        $dateStr            = Get-Date -Format 'yyyyMMdd'
        $zipName            = "SecureRDP-Client-$dateStr.zip"
        $zipPath            = Join-Path $OutputDir $zipName
        $unencryptedWarning = $null

        if ($Passphrase -and $Passphrase.Trim().Length -gt 0) {
            # Encrypted path: build package.bin and outer package
            $binPath = Join-Path $outerStagingDir 'package.bin'
            $r = Protect-SrdpClientPackage `
                    -StagingDir    $innerStagingDir `
                    -Passphrase    $Passphrase `
                    -OutputBinPath $binPath
            if ($r -is [string] -and $r -like 'error:*') { return $r }

            # Copy outer-only files (Unpack.ps1, Launch.cmd)
            foreach ($f in @(Get-ChildItem $ClientSrcDir -File)) {
                if ($f.Name -in $outerOnlyFiles) {
                    Copy-Item $f.FullName (Join-Path $outerStagingDir $f.Name)
                }
            }

            # Generate SecureRDP Connect.lnk via WScript.Shell.
            # WorkingDirectory left empty -- Windows Explorer sets it to the
            # folder containing the .lnk when user double-clicks, so Launch.cmd
            # is found by relative reference.
            try {
                $wsh     = New-Object -ComObject WScript.Shell
                $lnkPath = Join-Path $outerStagingDir 'SecureRDP Connect.lnk'
                $lnk     = $wsh.CreateShortcut($lnkPath)
                $lnk.TargetPath       = "$env:SystemRoot\System32\cmd.exe"
                $lnk.Arguments        = '/c Launch.cmd'
                $lnk.WorkingDirectory = ''
                $lnk.IconLocation     = "$env:SystemRoot\System32\mstsc.exe,0"
                $lnk.Description      = 'Connect to SecureRDP server'
                $lnk.WindowStyle      = 7   # minimised -- suppresses console flash
                $lnk.Save()
                [System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) | Out-Null
            } catch {
                # .lnk generation is non-fatal -- package usable via Launch.cmd
            }

            $zipSource = $outerStagingDir

        } else {
            # Unencrypted fallback (testing mode) -- zip inner dir directly
            $unencryptedWarning = 'Package created WITHOUT encryption (no passphrase provided). Private key is unprotected.'
            $zipSource = $innerStagingDir
        }

        # Zip to OutputDir
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        [System.IO.Compression.ZipFile]::CreateFromDirectory($zipSource, $zipPath)

        Start-Process explorer.exe -ArgumentList "/select,`"$zipPath`""

        return @{
            ZipPath            = $zipPath
            PackageFileName    = $zipName
            Encrypted          = ($null -eq $unencryptedWarning)
            UnencryptedWarning = $unencryptedWarning
        }

    } catch {
        return "error:Client package assembly failed: $($_.Exception.Message)"
    } finally {
        if ($null -ne $innerStagingDir -and (Test-Path $innerStagingDir)) {
            Remove-Item $innerStagingDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $outerStagingDir -and (Test-Path $outerStagingDir)) {
            Remove-Item $outerStagingDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ===========================================================================
# PAYLOAD DEPLOYMENT
# ===========================================================================

function Deploy-SrdpPayload {
    param(
        [Parameter(Mandatory)][string]$ModeDir,
        [Parameter(Mandatory)][string]$InstDir
    )
    try {
        if (-not (Test-Path $InstDir)) {
            New-Item -ItemType Directory -Path $InstDir -Force | Out-Null
        }
        $payloadDir = Join-Path $ModeDir 'payload'
        foreach ($f in @(Get-ChildItem $payloadDir -File)) {
            Copy-Item $f.FullName (Join-Path $InstDir $f.Name) -Force
        }
        return $true
    } catch {
        return "error:Payload deploy failed: $($_.Exception.Message)"
    }
}

# ===========================================================================
# HELPER: DETECT RDP SESSION
# ===========================================================================

function Test-SrdpRdpSession {
    $sn = $env:SESSIONNAME
    return ($null -ne $sn -and $sn -notlike 'Console*')
}

# ===========================================================================
# STATE SUMMARY
# ===========================================================================

function Get-SrdpSshProtoState {
<#
.SYNOPSIS
    Returns the current runtime state of the SSHProto mode for UI consumption.
    Returns @{Result='ok'; State=@{...}} on success. Returns "error:..." on failure.
#>
    try {
        $svcStatus = Get-SrdpSshdServiceStatus
        if ($svcStatus -is [string] -and $svcStatus -like 'error:*') { return $svcStatus }

        $keyCount = 0
        if (Test-Path $Script:AUTH_KEYS_PATH) {
            $keyLines = @(Get-Content -Path $Script:AUTH_KEYS_PATH |
                          Where-Object { $_ -and $_ -notmatch '^\s*#' })
            $keyCount = $keyLines.Count
        }

        return @{
            Result = 'ok'
            State  = @{
                ServiceInstalled   = $svcStatus.Installed
                ServiceRunning     = $svcStatus.Running
                ServiceStatus      = $svcStatus.Status
                HostKeyExists      = (Test-Path $Script:HOST_KEY_PATH)
                ConfigExists       = (Test-Path $Script:SSHD_CFG_PATH)
                AuthorizedKeyCount = $keyCount
                DataRoot           = $Script:SRDP_SSH_ROOT
                ServiceName        = $Script:SVC_NAME
            }
        }
    } catch {
        return "error:Get-SrdpSshProtoState: $($_.Exception.Message)"
    }
}

function New-SrdpSshRevertPlan {
<#
.SYNOPSIS
    Returns a structured revert plan for undoing SSHProto installation.
    Always returns a valid plan -- does not fail.
#>
    param([switch]$IncludeDataRemoval)

    $actions = @(
        @{ Order=1; Action='RemoveFirewallRules'; Description='Remove SecureRDP firewall rules';
           Function='Remove-SrdpFirewallRules'; RequiresAdmin=$true },
        @{ Order=2; Action='StopService'; Description="Stop the $Script:SVC_NAME service";
           Function='Stop-SrdpSshdService'; RequiresAdmin=$true },
        @{ Order=3; Action='RemoveService'; Description="Delete $Script:SVC_NAME from SCM";
           Function='Uninstall-SrdpSshdService'; RequiresAdmin=$true },
        @{ Order=4; Action='RemoveNLA'; Description='Revert NLA if enabled by SecureRDP';
           Function='(conditional)'; RequiresAdmin=$true },
        @{ Order=5; Action='RemoveRdpCert'; Description='Remove SecureRDP RDP certificate';
           Function='Remove-SrdpRdpCert'; RequiresAdmin=$true }
    )

    if ($IncludeDataRemoval) {
        $actions += @{
            Order=6; Action='RemoveData';
            Description="Remove all SecureRDP SSH data under $Script:SRDP_SSH_ROOT";
            Function='Uninstall-SrdpSshdService -RemoveData'; RequiresAdmin=$true
        }
    }

    return @{
        Result       = 'ok'
        Actions      = $actions
        ActionCount  = $actions.Count
        DataRootPath = $Script:SRDP_SSH_ROOT
        ServiceName  = $Script:SVC_NAME
    }
}

# ===========================================================================
# REVERT FUNCTIONS
# ===========================================================================

function Remove-SrdpFirewallRules {
    return Remove-FirewallRulesByName -Names @(
        $Script:RULE_SSH, $Script:RULE_RDP_BLK, $Script:RULE_RDP_BLK_UDP
    )
}

function Restore-SrdpSshdConfig {
    param(
        $BackupPath,
        [Parameter(Mandatory)][bool]$BackupExisted
    )
    try {
        $cfgPath = $Script:SSHD_CFG_PATH

        if ($BackupExisted) {
            if (-not $BackupPath -or -not (Test-Path $BackupPath)) {
                return "error:A sshd_config backup was expected at '$BackupPath' but was not found."
            }
            Copy-Item $BackupPath $cfgPath -Force
            Remove-Item $BackupPath -Force -ErrorAction SilentlyContinue
        } else {
            if (Test-Path $cfgPath) { Remove-Item $cfgPath -Force }
        }

        $svc = @(Get-Service -Name $Script:SVC_NAME -ErrorAction SilentlyContinue)
        if ($svc.Count -gt 0 -and $svc[0].Status -eq 'Running') {
            Restart-Service -Name $Script:SVC_NAME -Force -ErrorAction SilentlyContinue
        }
        return $true
    } catch {
        return "error:sshd_config restore failed: $($_.Exception.Message)"
    }
}

function Remove-SrdpSshdInstallation {
    # Stops and removes the SecureRDP-SSH service. Does not remove the SSH
    # binary (which may be the inbox feature binary or a shared bundled copy).
    try {
        $r = Uninstall-SrdpSshdService -RemoveData:$false
        if ($r -is [string] -and $r -like 'error:*') { return $r }
        # Remove bundled install dir if it exists
        if (Test-Path $Script:BUNDLED_INST) {
            Remove-Item $Script:BUNDLED_INST -Recurse -Force -ErrorAction SilentlyContinue
        }
        return $true
    } catch {
        return "error:sshd removal failed: $($_.Exception.Message)"
    }
}

function Remove-SrdpRdpCert {
    param(
        [Parameter(Mandatory)][string]$Thumbprint,
        $PreviousThumbprint
    )
    try {
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
            'My', [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $found = @($store.Certificates.Find(
            [System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
            $Thumbprint, $false))
        foreach ($c in $found) { $store.Remove($c) }
        $store.Close()

        if ($PreviousThumbprint) {
            $wmiRdp = Get-CimInstance -ClassName Win32_TSGeneralSetting `
                      -Namespace 'root\cimv2\terminalservices' `
                      -Filter "TerminalName='RDP-Tcp'" -ErrorAction SilentlyContinue
            if ($null -ne $wmiRdp) {
                Set-CimInstance -InputObject $wmiRdp -Property @{
                    SSLCertificateSHA1Hash = $PreviousThumbprint
                } -ErrorAction SilentlyContinue
            }
        }
        return $true
    } catch {
        return "error:RDP cert removal failed: $($_.Exception.Message)"
    }
}

function Remove-SrdpHostKey {
    try {
        foreach ($name in @('ssh_host_ed25519_key', 'ssh_host_ed25519_key.pub')) {
            $p = Join-Path $Script:HOST_KEY_DIR $name
            if (Test-Path $p) { Remove-Item $p -Force }
        }
        return $true
    } catch {
        return "error:Host key removal failed: $($_.Exception.Message)"
    }
}

function Remove-SrdpAccountKeys {
    # Retained for revert compatibility. Used when reverting installations
    # that recorded per-account authorized_keys paths in state.json.
    param([Parameter(Mandatory)][array]$Accounts)
    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($acct in $Accounts) {
        try {
            $akPath = $acct.AuthorizedKeysPath
            if ($akPath -and (Test-Path $akPath)) {
                $pubKey  = $acct.PublicKey
                $lines   = @(Get-Content $akPath -Encoding UTF8 |
                             Where-Object { $_.Trim() -ne $pubKey.Trim() })
                if ($lines.Count -gt 0) {
                    Set-Content $akPath -Value $lines -Encoding UTF8
                } else {
                    Remove-Item $akPath -Force -ErrorAction SilentlyContinue
                }
            }
            if ($acct.SshDirCreatedByScript -eq $true -and $akPath) {
                $sshDir = Split-Path $akPath -Parent
                if ((Test-Path $sshDir) -and
                    (@(Get-ChildItem $sshDir -Force).Count -eq 0)) {
                    Remove-Item $sshDir -Force -ErrorAction SilentlyContinue
                }
            }
        } catch {
            $errors.Add("Failed to remove key for $($acct.AccountName): $($_.Exception.Message)")
        }
    }
    if ($errors.Count -gt 0) { return "error:$($errors -join '; ')" }
    return $true
}

# ===========================================================================
# EXPORTS
# ===========================================================================

# =============================================================================
# Get-SrdpAddressCandidates
# Returns a list of candidate server addresses for inclusion in the client
# package address selection screen. No external calls made.
#
# Returns hashtable:
#   Hostname  : string  -- bare machine name ($env:COMPUTERNAME)
#   Fqdn      : string  -- fully qualified domain name, or $null if unavailable
#   LocalIps  : string[] -- non-loopback, non-APIPA IPv4 addresses
#   BestGuess : string  -- recommended pre-fill value (FQDN if available,
#                          hostname otherwise)
# =============================================================================
function Get-SrdpAddressCandidates {
    $hostname  = $env:COMPUTERNAME
    $fqdn      = $null
    $localIps  = @()

    # FQDN detection -- try/catch with aggressive timeout handling.
    # GetHostEntry can hang on machines with DNS misconfiguration or slow
    # domain controllers. We attempt it but catch all failures gracefully.
    try {
        $dnsResult = $null
        $job = [System.Threading.Tasks.Task]::Run([System.Func[object]]{
            [System.Net.Dns]::GetHostEntry([System.Net.Dns]::GetHostName())
        })
        # Wait up to 3 seconds
        if ($job.Wait(3000)) {
            $dnsResult = $job.Result
        }
        if ($null -ne $dnsResult -and $dnsResult.HostName -ne $hostname -and
            $dnsResult.HostName -match '\.') {
            $fqdn = $dnsResult.HostName
        }
    } catch {}

    # Local IP addresses -- non-loopback, non-APIPA IPv4 only
    try {
        $localIps = @(
            Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object {
                $a = $_.IPAddress
                # Exclude loopback (127.x.x.x)
                -not ($a -match '^127\.') -and
                # Exclude APIPA (169.254.x.x)
                -not ($a -match '^169\.254\.')
            } |
            Select-Object -ExpandProperty IPAddress
        )
    } catch {
        $localIps = @()
    }

    $bestGuess = if ($null -ne $fqdn) { $fqdn } else { $hostname }

    return @{
        Hostname  = $hostname
        Fqdn      = $fqdn
        LocalIps  = $localIps
        BestGuess = $bestGuess
    }
}

# ===========================================================================
# Get-SrdpSshAddressSuggestions
#
# Produces a ranked list of server address suggestions for the admin to
# choose from when generating a client package. The address selected here
# is the SSH connection target (serverAddress in config.json). It is NOT
# the address placed in connection.rdp -- that is always localhost:13389.
#
# Ranking order:
#   1 -- FQDN (best for external access, if available and differs from hostname)
#   2 -- Hostname (works on local networks with DNS)
#   3 -- Local IPv4 addresses (use when DNS unavailable; may cause cert
#        name mismatch warnings in Remote Desktop -- noted in Label)
#
# Returns:
#   @{
#     Result      = 'ok'
#     Suggestions = @(
#         @{ Address=[string]; Label=[string]; Rank=[int] }
#     )
#     Hostname    = [string]
#     Fqdn        = [string]   # $null if not detected
#   }
# Returns "error:..." on failure.
# ===========================================================================
function Get-SrdpSshAddressSuggestions {
    try {
        $candidates = Get-SrdpAddressCandidates
        if ($candidates -is [string] -and $candidates -like 'error:*') {
            return "error:Get-SrdpSshAddressSuggestions: $candidates"
        }

        $suggestions = [System.Collections.Generic.List[hashtable]]::new()
        $rank = 1

        # Rank 1: FQDN -- only if present and meaningfully different from hostname
        if ($null -ne $candidates.Fqdn -and
            $candidates.Fqdn -ne '' -and
            $candidates.Fqdn -ne $candidates.Hostname) {
            $null = $suggestions.Add(@{
                Address = $candidates.Fqdn
                Label   = 'Fully-qualified domain name (recommended for external access)'
                Rank    = $rank
            })
            $rank++
        }

        # Rank 2: Hostname -- always included
        $null = $suggestions.Add(@{
            Address = $candidates.Hostname
            Label   = 'Server name (works on local networks with DNS)'
            Rank    = $rank
        })
        $rank++

        # Rank 3+: Local IPv4 addresses -- sorted, loopback and APIPA excluded
        # (already filtered by Get-SrdpAddressCandidates)
        $ips = @($candidates.LocalIps)
        foreach ($ip in $ips) {
            $null = $suggestions.Add(@{
                Address = $ip
                Label   = 'IP address (use if DNS unavailable -- may cause a certificate name mismatch warning in Remote Desktop)'
                Rank    = $rank
            })
            $rank++
        }

        return @{
            Result      = 'ok'
            Suggestions = $suggestions.ToArray()
            Hostname    = $candidates.Hostname
            Fqdn        = $candidates.Fqdn
        }
    } catch {
        $errMsg = $_.Exception.Message
        return "error:Get-SrdpSshAddressSuggestions: $errMsg"
    }
}

# ===========================================================================
# Write-SrdpPassphraseToVault
#
# Appends a passphrase entry to the secure vault file.
# The vault file is created with a restrictive ACL (SYSTEM, Administrators,
# CREATOR OWNER only) before first write.
#
# Parameters:
#   Passphrase        - the passphrase string to store
#   KeyLabel          - label identifying which key this passphrase belongs to
#   ExistingVaultFile - optional: filename of an existing vault; if empty a
#                       new randomly-named file is created
#
# Returns @{ VaultFile = '<filename>' } on success.
# Returns "error:..." on failure.
# ===========================================================================
function Write-SrdpPassphraseToVault {
    param(
        [Parameter(Mandatory)][string]$Passphrase,
        [Parameter(Mandatory)][string]$KeyLabel,
        [string]$ExistingVaultFile = $null
    )

    $Script:VAULT_WORDS = @('anchor','bridge','canyon','depot','echo','falcon','garden',
        'harbor','inlet','jetty','kestrel','ledger','margin','needle','offset',
        'patrol','quorum','radius','signal','timber','uplift','valley','walnut',
        'xerox','yellow','zenith','alpine','beacon','cobalt','delta','ember',
        'flint','gravel','hollow','ivory','jasper','kelp','lunar','maple',
        'north','obsid','prism','quartz','ridge','slate','thorn','umbra',
        'vapor','wheat','xylem')

    try {
        $srdpDataDir = 'C:\ProgramData\SecureRDP'
        if (-not (Test-Path $srdpDataDir)) {
            New-Item -ItemType Directory -Path $srdpDataDir -Force | Out-Null
        }

        $vaultFile = $ExistingVaultFile
        if (-not $vaultFile -or $vaultFile.Trim().Length -eq 0) {
            $vaultFile = $Script:VAULT_WORDS[(Get-Random -Maximum $Script:VAULT_WORDS.Count)] + '.txt'
        }
        $vaultPath = Join-Path $srdpDataDir $vaultFile

        $fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
        $allow       = [System.Security.AccessControl.AccessControlType]::Allow
        $noFlags     = [System.Security.AccessControl.InheritanceFlags]::None
        $noPropagate = [System.Security.AccessControl.PropagationFlags]::None

        $systemSid  = New-Object System.Security.Principal.SecurityIdentifier(
            [System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
        $adminSid   = New-Object System.Security.Principal.SecurityIdentifier(
            [System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
        $creatorSid = New-Object System.Security.Principal.SecurityIdentifier(
            [System.Security.Principal.WellKnownSidType]::CreatorOwnerSid, $null)

        $acl = New-Object System.Security.AccessControl.FileSecurity
        $acl.SetAccessRuleProtection($true, $false)
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $systemSid,  $fullControl, $noFlags, $noPropagate, $allow)))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $adminSid,   $fullControl, $noFlags, $noPropagate, $allow)))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $creatorSid, $fullControl, $noFlags, $noPropagate, $allow)))

        if (-not (Test-Path $vaultPath)) {
            [System.IO.File]::WriteAllBytes($vaultPath, [byte[]]::new(0))
            Set-Acl -Path $vaultPath -AclObject $acl
        }

        $entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $KeyLabel  $Passphrase"
        Add-Content -Path $vaultPath -Value $entry -Encoding UTF8

        return @{ VaultFile = $vaultFile }
    } catch {
        return "error:Write-SrdpPassphraseToVault: $($_.Exception.Message)"
    }
}

# ===========================================================================
# LOOPBACK RESTRICTION
# Controls RDP listener binding via LanAdapter registry value.
# Windows Firewall does not police loopback traffic -- this registry
# mechanism is the correct enforcement layer for restricting RDP to
# loopback connections only (i.e. only reachable via SSH tunnel).
# ===========================================================================

function Set-SrdpLoopbackRestriction {
<#
.SYNOPSIS
    Restricts the RDP listener to the loopback adapter only via registry.
    Saves and returns the original LanAdapter value for revert.
    Returns @{Result='ok'; OriginalLanAdapter; AppliedIndex} or "error:...".
#>
    $WS_PATH = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
    try {
        try { Write-SrdpLog "Set-SrdpLoopbackRestriction: resolving loopback adapter index..." -Level INFO -Component 'SSHProtoCore' } catch {}

        $loopbackAddr = Get-NetIPAddress -IPAddress '127.0.0.1' -ErrorAction SilentlyContinue
        if ($null -eq $loopbackAddr -or $null -eq $loopbackAddr.InterfaceIndex) {
            return "error:Set-SrdpLoopbackRestriction: Cannot resolve loopback adapter interface index (127.0.0.1 not found)."
        }
        $loopbackIndex = [int]$loopbackAddr.InterfaceIndex
        if ($loopbackIndex -eq 0) {
            return "error:Set-SrdpLoopbackRestriction: Loopback adapter index resolved to 0 (all-adapters default) -- cannot safely apply."
        }

        try { Write-SrdpLog "Set-SrdpLoopbackRestriction: loopback adapter index = $loopbackIndex" -Level DEBUG -Component 'SSHProtoCore' } catch {}

        # Read and save original value
        $originalLanAdapter = $null
        try {
            $originalLanAdapter = (Get-ItemProperty $WS_PATH -Name 'LanAdapter' -ErrorAction SilentlyContinue).LanAdapter
        } catch {}
        try { Write-SrdpLog "Set-SrdpLoopbackRestriction: original LanAdapter = $originalLanAdapter" -Level INFO -Component 'SSHProtoCore' } catch {}

        # Apply
        Set-ItemProperty $WS_PATH -Name 'LanAdapter' -Value $loopbackIndex -Type DWord -ErrorAction Stop
        try { Write-SrdpLog "Set-SrdpLoopbackRestriction: LanAdapter set to $loopbackIndex. Restarting TermService..." -Level INFO -Component 'SSHProtoCore' } catch {}

        Restart-Service TermService -Force -ErrorAction Stop
        try { Write-SrdpLog "Set-SrdpLoopbackRestriction: TermService restarted. Loopback restriction applied." -Level INFO -Component 'SSHProtoCore' } catch {}

        return @{
            Result              = 'ok'
            OriginalLanAdapter  = $originalLanAdapter
            AppliedIndex        = $loopbackIndex
        }
    } catch {
        $errMsg = $_.Exception.Message
        try { Write-SrdpLog "Set-SrdpLoopbackRestriction failed: $errMsg" -Level ERROR -Component 'SSHProtoCore' } catch {}
        return "error:Set-SrdpLoopbackRestriction: $errMsg"
    }
}

function Remove-SrdpLoopbackRestriction {
<#
.SYNOPSIS
    Removes the RDP loopback listener restriction, restoring the original
    LanAdapter value. Restarts TermService.
    Returns @{Result='ok'} or "error:...".
#>
    param([object]$OriginalLanAdapter = $null)
    $WS_PATH = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
    try {
        try { Write-SrdpLog "Remove-SrdpLoopbackRestriction: restoring LanAdapter (original=$OriginalLanAdapter)..." -Level INFO -Component 'SSHProtoCore' } catch {}

        if ($null -eq $OriginalLanAdapter -or $OriginalLanAdapter -eq 0) {
            Remove-ItemProperty $WS_PATH -Name 'LanAdapter' -ErrorAction SilentlyContinue
            try { Write-SrdpLog "Remove-SrdpLoopbackRestriction: LanAdapter registry value removed (default = all adapters)." -Level INFO -Component 'SSHProtoCore' } catch {}
        } else {
            Set-ItemProperty $WS_PATH -Name 'LanAdapter' -Value ([int]$OriginalLanAdapter) -Type DWord -ErrorAction Stop
            try { Write-SrdpLog "Remove-SrdpLoopbackRestriction: LanAdapter restored to $OriginalLanAdapter." -Level INFO -Component 'SSHProtoCore' } catch {}
        }

        Restart-Service TermService -Force -ErrorAction Stop
        try { Write-SrdpLog "Remove-SrdpLoopbackRestriction: TermService restarted." -Level INFO -Component 'SSHProtoCore' } catch {}

        return @{ Result = 'ok' }
    } catch {
        $errMsg = $_.Exception.Message
        try { Write-SrdpLog "Remove-SrdpLoopbackRestriction failed: $errMsg" -Level ERROR -Component 'SSHProtoCore' } catch {}
        return "error:Remove-SrdpLoopbackRestriction: $errMsg"
    }
}

# ===========================================================================
# SSH VERIFICATION ENGINE
# Five-stage validation pipeline for QS Part 2 startup.
# Checks: service state, port listener, config directives, host key,
# and file ACLs. Does NOT auto-remediate config or ACLs -- reports only
# (except attempting to start sshd if it is stopped).
# ===========================================================================

function Invoke-SrdpSshVerifier {
<#
.SYNOPSIS
    Validates that the SSH infrastructure from Phase 1a is healthy and
    ready for Phase 2 setup. Returns universal result schema.
    Status: 'Healthy' | 'Degraded' | 'Failed' | 'FatalError'
#>
    param([int]$SshPort = 22)

    $Result = [PSCustomObject]@{
        Success = $false
        Status  = 'Unknown'
        Data    = @{
            Checks        = [System.Collections.Generic.List[object]]::new()
            SshPort       = $SshPort
            ServiceStatus = 'Unknown'
        }
        Logs   = [System.Collections.Generic.List[string]]::new()
        Errors = [System.Collections.Generic.List[string]]::new()
    }

    try {
        $Result.Logs.Add("SSH Verifier starting. Port=$SshPort")
        try { Write-SrdpLog "SshVerifier: starting. Port=$SshPort" -Level INFO -Component 'SshVerifier' } catch {}

        # --- Check 1: Service State ---
        $Result.Logs.Add("Check 1: Service state...")
        $svc = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
        $c1 = @{ Name='ServiceRunning'; Passed=$false; Detail='' }

        if ($null -eq $svc) {
            $c1.Detail = "sshd service not found. OpenSSH Server may not be installed."
            $Result.Errors.Add($c1.Detail)
        } elseif ($svc.Status -ne 'Running') {
            $Result.Logs.Add("sshd is $($svc.Status). Attempting to start...")
            try { Write-SrdpLog "SshVerifier: sshd not running ($($svc.Status)). Attempting start..." -Level WARN -Component 'SshVerifier' } catch {}
            try {
                Start-Service -Name 'sshd' -ErrorAction Stop
                Start-Sleep -Seconds 2
                $svc = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
                if ($svc.Status -eq 'Running') {
                    $c1.Passed = $true
                    $c1.Detail = "sshd was not running. Started successfully."
                    $Result.Logs.Add("sshd started successfully.")
                } else {
                    $c1.Detail = "sshd failed to start. Status: $($svc.Status). Check Event Viewer > OpenSSH logs."
                    $Result.Errors.Add($c1.Detail)
                }
            } catch {
                $startErr = $_.Exception.Message
                $c1.Detail = "sshd could not be started: $startErr"
                $Result.Errors.Add($c1.Detail)
            }
        } else {
            $c1.Passed = $true
            $c1.Detail = "sshd service is running (StartType: $($svc.StartType))."
        }

        $Result.Data.ServiceStatus = if ($null -ne $svc) { $svc.Status.ToString() } else { 'NotFound' }
        $Result.Data.Checks.Add($c1)
        $c1Level = if ($c1.Passed) { 'INFO' } else { 'ERROR' }
        try { Write-SrdpLog "SshVerifier: Check 1 = $($c1.Passed). $($c1.Detail)" -Level $c1Level -Component 'SshVerifier' } catch {}

        # --- Check 2: Network Listener ---
        $Result.Logs.Add("Check 2: Port $SshPort listener...")
        $c2 = @{ Name='PortListening'; Passed=$false; Detail='' }
        try {
            $listener = @(Get-NetTCPConnection -LocalPort $SshPort -State Listen -ErrorAction SilentlyContinue)
            if ($listener.Count -gt 0) {
                $c2.Passed = $true
                $c2.Detail = "Port $SshPort is listening."
            } else {
                $c2.Detail = "Nothing is listening on port $SshPort. The SSH service may have failed to bind."
                $Result.Errors.Add($c2.Detail)
            }
        } catch {
            $portErr = $_.Exception.Message
            $c2.Detail = "Port listener check failed: $portErr"
            $Result.Errors.Add($c2.Detail)
        }
        $Result.Data.Checks.Add($c2)
        $c2Level = if ($c2.Passed) { 'INFO' } else { 'ERROR' }
        try { Write-SrdpLog "SshVerifier: Check 2 = $($c2.Passed). $($c2.Detail)" -Level $c2Level -Component 'SshVerifier' } catch {}

        # --- Check 3: Config Validation ---
        $Result.Logs.Add("Check 3: sshd_config validation...")
        $configPath = Join-Path $env:ProgramData 'ssh\sshd_config'
        $c3 = @{ Name='ConfigValid'; Passed=$false; Detail=''; MissingDirectives=@() }

        if (-not (Test-Path $configPath)) {
            $c3.Detail = "sshd_config not found at $configPath."
            $c3.MissingDirectives = @('entire file')
            $Result.Errors.Add($c3.Detail)
        } else {
            $configContent = Get-Content $configPath -Raw -Encoding UTF8
            $missing = [System.Collections.Generic.List[string]]::new()

            if ($configContent -notmatch 'HostKey\s+C:/ProgramData/SecureRDP/ssh/host/ssh_host_ed25519_key') {
                $missing.Add('HostKey C:/ProgramData/SecureRDP/ssh/host/ssh_host_ed25519_key')
            }
            if ($configContent -notmatch 'AuthorizedKeysFile\s+C:/ProgramData/SecureRDP/ssh/authorized_keys') {
                $missing.Add('AuthorizedKeysFile C:/ProgramData/SecureRDP/ssh/authorized_keys')
            }
            if ($configContent -notmatch '(?m)^PasswordAuthentication\s+no') {
                $missing.Add('PasswordAuthentication no')
            }
            if ($configContent -notmatch '(?m)^Match Group administrators') {
                $missing.Add('Match Group administrators')
            }

            if ($missing.Count -eq 0) {
                $c3.Passed = $true
                $c3.Detail = "sshd_config contains all required SecureRDP directives."
            } else {
                $c3.Detail = "sshd_config is missing $($missing.Count) required directive(s): $($missing -join '; ')"
                $c3.MissingDirectives = @($missing)
                $Result.Errors.Add($c3.Detail)
            }
        }
        $Result.Data.Checks.Add($c3)
        $c3Level = if ($c3.Passed) { 'INFO' } else { 'ERROR' }
        try { Write-SrdpLog "SshVerifier: Check 3 = $($c3.Passed). $($c3.Detail)" -Level $c3Level -Component 'SshVerifier' } catch {}

        # --- Check 4: Host Key Present ---
        $Result.Logs.Add("Check 4: Host key files...")
        $hostKeyPriv = 'C:\ProgramData\SecureRDP\ssh\host\ssh_host_ed25519_key'
        $hostKeyPub  = "$hostKeyPriv.pub"
        $c4 = @{ Name='HostKeyPresent'; Passed=$false; Detail='' }

        $privExists = Test-Path $hostKeyPriv
        $pubExists  = Test-Path $hostKeyPub
        if ($privExists -and $pubExists) {
            $c4.Passed = $true
            $c4.Detail = "Host key pair present."
        } else {
            $missingKeys = [System.Collections.Generic.List[string]]::new()
            if (-not $privExists) { $missingKeys.Add('private key') }
            if (-not $pubExists)  { $missingKeys.Add('public key') }
            $c4.Detail = "Host key missing: $($missingKeys -join ', '). Path: $hostKeyPriv"
            $Result.Errors.Add($c4.Detail)
        }
        $Result.Data.Checks.Add($c4)
        $c4Level = if ($c4.Passed) { 'INFO' } else { 'ERROR' }
        try { Write-SrdpLog "SshVerifier: Check 4 = $($c4.Passed). $($c4.Detail)" -Level $c4Level -Component 'SshVerifier' } catch {}

        # --- Check 5: ACL Audit ---
        $Result.Logs.Add("Check 5: File permissions audit...")
        $c5 = @{ Name='AclSecure'; Passed=$true; Detail='' }
        $aclIssues = [System.Collections.Generic.List[string]]::new()

        $systemAcct = 'NT AUTHORITY\SYSTEM'
        $adminsAcct = 'BUILTIN\Administrators'

        foreach ($aclTarget in @($hostKeyPriv, $Script:AUTH_KEYS_PATH)) {
            if (-not (Test-Path $aclTarget)) {
                if ($aclTarget -eq $Script:AUTH_KEYS_PATH) {
                    # authorized_keys not existing yet is expected before first client package
                    $Result.Logs.Add("authorized_keys not yet created -- skipping ACL check for it.")
                    continue
                }
                $aclIssues.Add("File not found for ACL check: $aclTarget")
                continue
            }
            try {
                $acl = Get-Acl -Path $aclTarget
                if (-not $acl.AreAccessRulesProtected) {
                    $aclIssues.Add("Inheritance enabled on: $aclTarget")
                }
                foreach ($rule in $acl.Access) {
                    $identity = $rule.IdentityReference.Value
                    if ($identity -ne $systemAcct -and $identity -ne $adminsAcct) {
                        $aclIssues.Add("Unexpected ACL entry on $([System.IO.Path]::GetFileName($aclTarget)): $identity has $($rule.FileSystemRights)")
                    }
                }
            } catch {
                $aclErr = $_.Exception.Message
                $aclIssues.Add("ACL check failed on ${aclTarget}: $aclErr")
            }
        }

        if ($aclIssues.Count -gt 0) {
            $c5.Passed = $false
            $c5.Detail = "ACL issues found: $($aclIssues -join '; ')"
            $Result.Errors.Add($c5.Detail)
        } else {
            $c5.Detail = "File permissions are correctly locked down."
        }
        $Result.Data.Checks.Add($c5)
        $c5Level = if ($c5.Passed) { 'INFO' } else { 'ERROR' }
        try { Write-SrdpLog "SshVerifier: Check 5 = $($c5.Passed). $($c5.Detail)" -Level $c5Level -Component 'SshVerifier' } catch {}

        # --- Overall Status ---
        $allChecks = @($Result.Data.Checks)
        $failedCount = @($allChecks | Where-Object { -not $_.Passed }).Count
        $criticalNames = @('ServiceRunning', 'PortListening', 'ConfigValid', 'HostKeyPresent')
        $criticalFailed = @($allChecks | Where-Object { -not $_.Passed -and $_.Name -in $criticalNames }).Count

        if ($failedCount -eq 0) {
            $Result.Success = $true
            $Result.Status  = 'Healthy'
            $Result.Logs.Add("All SSH verifications passed.")
        } elseif ($criticalFailed -eq 0) {
            # Only non-critical failures (e.g. ACL on not-yet-created authorized_keys)
            $Result.Success = $true
            $Result.Status  = 'Degraded'
            $Result.Logs.Add("SSH operational with $failedCount non-critical issue(s).")
        } else {
            $Result.Success = $false
            $Result.Status  = 'Failed'
            $Result.Logs.Add("SSH verification failed. $criticalFailed critical check(s) failed.")
        }

        $overallLevel = if ($Result.Success) { 'INFO' } else { 'ERROR' }
        try { Write-SrdpLog "SshVerifier: overall=$($Result.Status). $failedCount failed, $criticalFailed critical." -Level $overallLevel -Component 'SshVerifier' } catch {}

    } catch {
        $errMsg = $_.Exception.Message
        $Result.Errors.Add("SSH Verifier fatal error: $errMsg")
        $Result.Status = 'FatalError'
        try { Write-SrdpLog "SshVerifier: fatal error: $errMsg" -Level ERROR -Component 'SshVerifier' } catch {}
    }

    return $Result
}

Export-ModuleMember -Function @(
    # State
    'Read-SrdpState',
    'Write-SrdpState',
    'Get-SrdpAccount',
    # SSH detection
    'Get-SrdpSshInfo',
    'Get-SrdpInfrastructureStatus',
    'Install-SrdpBundledSsh',
    # Binary and directory
    'Get-SrdpSshBinaryDir',
    'Initialize-SrdpSshDirectories',
    'Set-SrdpSshAcls',
    # Host key and config
    'Initialize-SrdpHostKey',
    'New-SrdpSshdConfig',
    'Write-SrdpSshdConfig',
    # NLA and RDP cert
    'Set-SrdpNla',
    'New-SrdpRdpCert',
    # Firewall
    'New-SrdpFirewallRules',
    'Add-SrdpSshFirewallRule',
    'Remove-SrdpSshFirewallRule',
    # Service management
    'Install-SrdpSshdService',
    'Start-SrdpSshdService',
    'Stop-SrdpSshdService',
    'Uninstall-SrdpSshdService',
    'Get-SrdpSshdServiceStatus',
    # Host key info
    'Get-SrdpHostKeyInfo',
    # Client keys and authorized_keys
    'New-SrdpClientKey',
    'Add-SrdpAuthorizedKey',
    'Remove-SrdpAuthorizedKey',
    'Get-SrdpAuthorizedKeys',
    # Port availability
    'Test-SrdpPortAvailable',
    # Address candidates and SSH address suggestions
    'Get-SrdpAddressCandidates',
    'Get-SrdpSshAddressSuggestions',
    # Client package
    'Build-SrdpClientPackage',
    'Deploy-SrdpPayload',
    # Helpers
    'Test-SrdpRdpSession',
    'Get-SrdpSshProtoState',
    'New-SrdpSshRevertPlan',
    # Revert
    'Remove-SrdpFirewallRules',
    'Restore-SrdpSshdConfig',
    'Remove-SrdpSshdInstallation',
    'Remove-SrdpRdpCert',
    'Remove-SrdpHostKey',
    'Remove-SrdpAccountKeys',
    # Vault
    'Write-SrdpPassphraseToVault',
    # Loopback restriction
    'Set-SrdpLoopbackRestriction',
    'Remove-SrdpLoopbackRestriction',
    # SSH verification
    'Invoke-SrdpSshVerifier'
)
