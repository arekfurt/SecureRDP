#Requires -Version 5.1
# =============================================================================
# SecureRDP v0.848139 - SSH + RDP Basic Prototype Mode
# Connect-SecureRDP.ps1 - Portable Tunnel Launcher
#
# Connects to the configured SSH server, establishes a local port forward to
# the remote RDP service, and launches mstsc against the loopback endpoint.
#
# Design goals:
#   - Fail fast on missing or malformed package data
#   - Keep SSH process arguments deterministic by using a temporary config file
#   - Copy private key to temp file at launch (avoids ACL ownership issues)
#   - Optionally add the server RDP certificate to CurrentUser\Root (deferred)
#   - Keep cleanup reliable even when launch or connection setup fails
#   - Verbose diagnostic log for connection troubleshooting
#
# (!)  PROTOTYPE: The private key in this package is NOT passphrase-protected.
#      Do not leave this package on shared or untrusted machines.
#      Generate a separate package per user -- do not share packages.
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName('System.Drawing')       | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName('System.Security')      | Out-Null
[System.Windows.Forms.Application]::EnableVisualStyles()

$ScriptDir        = $PSScriptRoot
$LocalRdpPort     = 13389
$TunnelTimeoutSec = 35

# =============================================================================
# LOGGING
# Set $script:LogEnabled = $false to disable before public release.
# When enabled, a timestamped log is written to the package folder.
# =============================================================================
$script:LogEnabled = $true
$script:LogFile    = $null

function Write-ConnectLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Level = 'INFO'
    )
    if (-not $script:LogEnabled) { return }
    try {
        $ts   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
        $line = "[$ts] [$Level] $Message"
        if ($null -ne $script:LogFile) {
            Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Initialize-ConnectLog {
    if (-not $script:LogEnabled) { return }
    try {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $script:LogFile = Join-Path $ScriptDir "SecureRDP-connect-$stamp.log"
        $header = @(
            ('=' * 72),
            'SecureRDP Connect-SecureRDP.ps1 -- Diagnostic Log',
            "Started : $(Get-Date)",
            "Script  : $PSCommandPath",
            "PID     : $PID",
            "User    : $($env:USERNAME)  ComputerName: $($env:COMPUTERNAME)",
            ('=' * 72)
        )
        [System.IO.File]::WriteAllLines($script:LogFile, $header, [System.Text.UTF8Encoding]::new($false))
    } catch {
        $script:LogFile = $null
    }
}

# =============================================================================
# UI CONSTANTS
# =============================================================================
$FontNormal  = [System.Drawing.Font]::new('Segoe UI', 9)
$FontHeader  = [System.Drawing.Font]::new('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$FontMono    = [System.Drawing.Font]::new('Consolas', 9)
$ColorHeader = [System.Drawing.Color]::FromArgb(0,   60, 120)
$ColorError  = [System.Drawing.Color]::FromArgb(170, 20,  10)
$ColorOk     = [System.Drawing.Color]::FromArgb(15, 120,  40)

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

function Show-SrdpMessage {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [System.Windows.Forms.MessageBoxIcon]$Icon    = [System.Windows.Forms.MessageBoxIcon]::Information,
        [System.Windows.Forms.MessageBoxButtons]$Buttons = [System.Windows.Forms.MessageBoxButtons]::OK
    )
    return [System.Windows.Forms.MessageBox]::Show(
        $Message, "SecureRDP - $Title", $Buttons, $Icon)
}

function Show-SrdpMessageTopmost {
    # Rule 31: off-screen owner form for reliable focus steal.
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [System.Windows.Forms.MessageBoxIcon]$Icon    = [System.Windows.Forms.MessageBoxIcon]::Information,
        [System.Windows.Forms.MessageBoxButtons]$Buttons = [System.Windows.Forms.MessageBoxButtons]::OK
    )
    $owner                 = New-Object System.Windows.Forms.Form
    $owner.TopMost         = $true
    $owner.Width           = 1; $owner.Height = 1
    $owner.Left            = -2000; $owner.Top = -2000
    $owner.FormBorderStyle = 'None'
    $owner.Show()
    $result = [System.Windows.Forms.MessageBox]::Show(
        $owner, $Message, "SecureRDP - $Title", $Buttons, $Icon)
    try { $owner.Close() } catch {}
    return $result
}

function Show-ErrorScreen {
    # Persistent error screen shown on connection failure.
    # Uses ShowDialog() for a proper modal message pump -- will not be
    # swept away by PowerShell process teardown unlike MessageBox.
    param(
        [Parameter(Mandatory)][string]$ErrorText
    )
    Write-ConnectLog 'Showing error screen.' -Level 'DEBUG'

    $f                  = New-Object System.Windows.Forms.Form
    $f.Text             = 'SecureRDP - Connection Failed'
    $f.Width            = 640
    $f.Height           = 460
    $f.FormBorderStyle  = 'FixedDialog'
    $f.MaximizeBox      = $false
    $f.MinimizeBox      = $false
    $f.StartPosition    = 'CenterScreen'
    $f.TopMost          = $true
    $f.BackColor        = [System.Drawing.Color]::FromArgb(245, 245, 245)

    # Red header bar
    $hdr                = New-Object System.Windows.Forms.Panel
    $hdr.Dock           = 'Top'
    $hdr.Height         = 36
    $hdr.BackColor      = $ColorError
    $hdrLbl             = New-Object System.Windows.Forms.Label
    $hdrLbl.Text        = 'Connection Failed'
    $hdrLbl.Font        = $FontHeader
    $hdrLbl.ForeColor   = [System.Drawing.Color]::White
    $hdrLbl.Dock        = 'Fill'
    $hdrLbl.TextAlign   = 'MiddleLeft'
    $hdrLbl.Padding     = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
    $hdr.Controls.Add($hdrLbl)
    $f.Controls.Add($hdr)

    # Bottom button bar
    $bb                 = New-Object System.Windows.Forms.Panel
    $bb.Dock            = 'Bottom'
    $bb.Height          = 48
    $bb.BackColor       = [System.Drawing.Color]::FromArgb(232, 232, 232)
    $bbSep              = New-Object System.Windows.Forms.Panel
    $bbSep.Dock         = 'Top'
    $bbSep.Height       = 1
    $bbSep.BackColor    = [System.Drawing.Color]::Silver
    $bb.Controls.Add($bbSep)
    $f.Controls.Add($bb)

    $btnCopy            = New-Object System.Windows.Forms.Button
    $btnCopy.Text       = 'Copy to Clipboard'
    $btnCopy.Width      = 140; $btnCopy.Height = 30; $btnCopy.Top = 9
    $btnCopy.Left       = 12
    $btnCopy.FlatStyle  = 'Flat'
    $btnCopy.BackColor  = [System.Drawing.Color]::White
    $btnCopy.FlatAppearance.BorderColor = [System.Drawing.Color]::Silver
    $btnCopy.Font       = $FontNormal
    $bb.Controls.Add($btnCopy)

    $btnClose           = New-Object System.Windows.Forms.Button
    $btnClose.Text      = 'Close'
    $btnClose.Width     = 90; $btnClose.Height = 30; $btnClose.Top = 9
    $btnClose.Left      = 640 - 90 - 20
    $btnClose.FlatStyle = 'Flat'
    $btnClose.BackColor = [System.Drawing.Color]::White
    $btnClose.FlatAppearance.BorderColor = [System.Drawing.Color]::Silver
    $btnClose.Font      = $FontNormal
    $bb.Controls.Add($btnClose)

    # Scrollable text area
    $tb                 = New-Object System.Windows.Forms.RichTextBox
    $tb.Dock            = 'Fill'
    $tb.ReadOnly        = $true
    $tb.ScrollBars      = 'Vertical'
    $tb.WordWrap        = $true
    $tb.Font            = $FontMono
    $tb.BackColor       = [System.Drawing.Color]::FromArgb(250, 250, 250)
    $tb.BorderStyle     = 'None'
    $tb.Padding         = New-Object System.Windows.Forms.Padding(8)
    $tb.Text            = $ErrorText
    $f.Controls.Add($tb)

    $capturedText = $ErrorText
    $btnCopy.Add_Click({
        try { [System.Windows.Forms.Clipboard]::SetText($capturedText) } catch {}
    }.GetNewClosure())

    $btnClose.Add_Click({ $f.Close() })
    $f.CancelButton = $btnClose

    $f.ShowDialog() | Out-Null
}

function Fail-Srdp {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [int]$ExitCode = 1
    )
    Write-ConnectLog "FATAL: $Title -- $Message" -Level 'ERROR'
    if ($script:LogEnabled -and $null -ne $script:LogFile -and (Test-Path -LiteralPath $script:LogFile)) {
        $Message = "$Message`n`nDiagnostic log: $($script:LogFile)"
    }
    [void](Show-SrdpMessage -Title $Title -Message $Message -Icon ([System.Windows.Forms.MessageBoxIcon]::Error))
    exit $ExitCode
}

function Get-ConfigProperty {
    param(
        [Parameter(Mandatory)][psobject]$Object,
        [Parameter(Mandatory)][string[]]$Names
    )
    foreach ($name in $Names) {
        foreach ($prop in $Object.PSObject.Properties) {
            if ($prop.Name -ieq $name) { return $prop.Value }
        }
    }
    return $null
}

function Convert-ToTrimmedString {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    return $s.Trim()
}

function Convert-ToPositiveInt {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Name,
        [int]$Min = 1,
        [int]$Max = 65535
    )
    $n = 0
    if (-not [int]::TryParse(([string]$Value), [ref]$n)) {
        throw "$Name must be an integer between $Min and $Max."
    }
    if ($n -lt $Min -or $n -gt $Max) {
        throw "$Name must be between $Min and $Max."
    }
    return $n
}

function Normalize-ServerAddress {
    param([Parameter(Mandatory)][string]$Address)
    $a = $Address.Trim()
    if ([string]::IsNullOrWhiteSpace($a)) { throw 'serverAddress is empty.' }
    if ($a -match '^[a-z][a-z0-9+.-]*://') {
        throw 'serverAddress must not include a URL scheme such as http:// or ssh://.'
    }
    if ($a -match '^(\[[^\]]+\]|[^:]+):\d+$') {
        throw 'serverAddress must not include an embedded port. Use the sshPort field instead.'
    }
    return $a
}

function Convert-ToSshConfigPath {
    param([Parameter(Mandatory)][string]$Path)
    $p = $Path.Replace('\', '/')
    if ($p -match '\s') { return '"' + $p.Replace('"', '\"') + '"' }
    return $p
}

function Convert-ToSshConfigValue {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -match '\s|\\|"') { return '"' + $Value.Replace('"', '\"') + '"' }
    return $Value
}

function Test-PortOpen {
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 500
    )
    $client = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $async  = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok     = $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        try { $client.EndConnect($async) } catch {}
        if ($ok -and -not $client.Connected) { $ok = $false }
        return $ok
    } catch {
        return $false
    } finally {
        if ($null -ne $client) {
            try { $client.Close()   } catch {}
            try { $client.Dispose() } catch {}
        }
    }
}

function Find-SshExe {
    $candidates = @(
        'C:\Windows\System32\OpenSSH\ssh.exe',
        'C:\Program Files\OpenSSH\ssh.exe',
        (Join-Path $ScriptDir 'resources\ssh\x64\ssh.exe'),
        (Join-Path $ScriptDir 'resources\ssh\x86\ssh.exe'),
        (Join-Path $ScriptDir 'ssh\ssh.exe')
    )
    foreach ($c in $candidates) {
        Write-ConnectLog "Find-SshExe: checking $c" -Level 'DEBUG'
        if (Test-Path -LiteralPath $c) {
            Write-ConnectLog "Find-SshExe: found at $c" -Level 'INFO'
            return $c
        }
    }
    Write-ConnectLog 'Find-SshExe: ssh.exe not found in any candidate path.' -Level 'ERROR'
    return $null
}

function Read-Config {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        return $raw | ConvertFrom-Json
    } catch {
        throw "config.json could not be read: $($_.Exception.Message)"
    }
}

function Assert-LeafCertificate {
    param([Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert)
    foreach ($ext in $Cert.Extensions) {
        if ($ext.Oid -and $ext.Oid.Value -eq '2.5.29.19') {
            $bcExt = [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]$ext
            if ($bcExt.CertificateAuthority) {
                throw 'The supplied RDP certificate is a CA certificate. Installation refused.'
            }
        }
    }
}

function Install-RdpCertificateIfRequested {
    # RDP certificate pinning deferred from initial public release.
    # Function retained for future use. Call site is commented out below.
    param(
        [string]$ServerName,
        [string]$Thumbprint,
        [string]$Base64Der
    )
    Write-ConnectLog 'Install-RdpCertificateIfRequested: deferred -- skipping.' -Level 'DEBUG'

    $thumb = Convert-ToTrimmedString $Thumbprint
    $der   = Convert-ToTrimmedString $Base64Der
    if ([string]::IsNullOrWhiteSpace($thumb) -or [string]::IsNullOrWhiteSpace($der)) { return }

    $thumbNorm = ($thumb -replace '\s', '').ToUpperInvariant()
    $store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
        'Root', [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    try {
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
        $found = $store.Certificates.Find(
            [System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
            $thumbNorm, $false)
        if ($found.Count -gt 0) { return }
    } finally {
        try { $store.Close() } catch {}
    }

    try {
        $derBytes = [Convert]::FromBase64String($der)
        $cert     = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (,$derBytes)
        Assert-LeafCertificate -Cert $cert

        $answer = Show-SrdpMessage -Title 'Add Server Certificate' -Message @"
SecureRDP can add this server's RDP certificate to your current user trust store.
This avoids repeated certificate warnings from Remote Desktop for this server.

Server:      $ServerName
Thumbprint:  $thumbNorm

The certificate is stored only in CurrentUser\Root and can be removed later.

Add certificate now?
"@ -Icon ([System.Windows.Forms.MessageBoxIcon]::Information) `
   -Buttons ([System.Windows.Forms.MessageBoxButtons]::YesNo)

        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
            'Root', [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        try { $store.Add($cert) } finally { try { $store.Close() } catch {} }

    } catch {
        $errMsg = $_.Exception.Message
        Write-ConnectLog "Install-RdpCertificateIfRequested failed: $errMsg" -Level 'WARN'
        [void](Show-SrdpMessage -Title 'Certificate Warning' -Message @"
Could not install the server certificate.

Error: $errMsg

The tunnel can still be used, but Remote Desktop may show a warning.
"@ -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning))
    }
}

function Copy-KeyToTemp {
    # Copies the private key to a new temp file owned by the current user.
    # This avoids ACL ownership issues when the package was created by a
    # different account (e.g. an admin generating a package for a standard user).
    # The temp file is always owned by the process owner -- no SetOwner needed.
    # ACEs are purged and set to current-user-only on the temp file.
    # The temp file is deleted in the finally block after use.
    param([Parameter(Mandatory)][string]$SourcePath)

    Write-ConnectLog "Copy-KeyToTemp: reading key from $SourcePath" -Level 'DEBUG'

    # Read raw bytes to preserve exact content -- no encoding transformation.
    $keyContent = [System.IO.File]::ReadAllText($SourcePath, [System.Text.UTF8Encoding]::new($false))

    $tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) `
        ("SecureRDP-$PID-$([guid]::NewGuid().ToString('N')).key")

    [System.IO.File]::WriteAllText($tmpPath, $keyContent, [System.Text.UTF8Encoding]::new($false))
    Write-ConnectLog "Copy-KeyToTemp: key written to $tmpPath" -Level 'DEBUG'

    # Lock down ACEs on the temp file to current user only.
    # We own this file (we just created it) so no SetOwner needed.
    try {
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = Get-Acl -LiteralPath $tmpPath
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.Access)) {
            try { [void]$acl.RemoveAccessRule($rule) } catch {}
        }
        $newRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.InheritanceFlags]::None,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($newRule)
        Set-Acl -LiteralPath $tmpPath -AclObject $acl
        Write-ConnectLog "Copy-KeyToTemp: ACLs secured on temp key. SID=$($sid.Value)" -Level 'INFO'
    } catch {
        $errMsg = $_.Exception.Message
        Write-ConnectLog "Copy-KeyToTemp: ACL hardening failed (non-fatal): $errMsg" -Level 'WARN'
    }

    return $tmpPath
}

function New-SshConfigFile {
    param(
        [Parameter(Mandatory)][string]$ServerAddress,
        [Parameter(Mandatory)][string]$Account,
        [Parameter(Mandatory)][int]$SshPort,
        [Parameter(Mandatory)][int]$RdpPort,
        [Parameter(Mandatory)][string]$KeyFile,
        [Parameter(Mandatory)][string]$KnownHostsFile,
        [Parameter(Mandatory)][int]$LocalRdpPort,
        [Parameter(Mandatory)][string]$LogLevel
    )

    $accountVal     = Convert-ToSshConfigValue $Account
    $keyFilePath    = Convert-ToSshConfigPath  $KeyFile
    $knownHostsPath = Convert-ToSshConfigPath  $KnownHostsFile
    $addrAlias      = Convert-ToSshConfigValue $ServerAddress

    $lines = @(
        'Host SecureRDP',
        "    HostName $ServerAddress",
        "    User $accountVal",
        "    Port $SshPort",
        "    IdentityFile $keyFilePath",
        '    IdentitiesOnly yes',
        "    UserKnownHostsFile $knownHostsPath",
        '    GlobalKnownHostsFile NUL',
        '    StrictHostKeyChecking yes',
        '    PasswordAuthentication no',
        '    KbdInteractiveAuthentication no',
        '    PubkeyAuthentication yes',
        '    HostKeyAlgorithms ssh-ed25519',
        '    ServerAliveInterval 15',
        '    ServerAliveCountMax 3',
        '    ConnectTimeout 20',
        '    ExitOnForwardFailure yes',
        "    LogLevel $LogLevel",
        "    HostKeyAlias $addrAlias",
        "    LocalForward $LocalRdpPort 127.0.0.1:$RdpPort"
    )

    $content = $lines -join "`n"
    $tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) `
        ("SecureRDP-$PID-$([guid]::NewGuid().ToString('N')).sshconfig")
    [System.IO.File]::WriteAllText($tmpPath, $content, [System.Text.UTF8Encoding]::new($false))
    Write-ConnectLog "New-SshConfigFile: written to $tmpPath  LogLevel=$LogLevel" -Level 'DEBUG'
    return $tmpPath
}

function New-RdpFile {
    # Generates a temporary RDP file for mstsc at launch time.
    # Avoids the Windows unsigned-file security warning that appears when
    # launching a static .rdp file from an untrusted location.
    # The temp file is deleted in the finally block after mstsc exits.
    param(
        [Parameter(Mandatory)][int]$LocalRdpPort,
        [Parameter(Mandatory)][int]$RdpPort,
        [string]$RdpUsername = ''
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("full address:s:127.0.0.1:$LocalRdpPort")
    $lines.Add('prompt for credentials:i:1')
    $lines.Add('authentication level:i:2')
    $lines.Add('enablecredsspsupport:i:1')
    $lines.Add('negotiate security layer:i:1')
    $lines.Add('autoreconnection enabled:i:0')
    $lines.Add('compression:i:1')
    $lines.Add('connection type:i:7')
    $lines.Add('networkautodetect:i:1')
    $lines.Add('bandwidthautodetect:i:1')
    $lines.Add('displayconnectionbar:i:1')
    $lines.Add('disable wallpaper:i:0')
    $lines.Add('allow font smoothing:i:1')
    if (-not [string]::IsNullOrWhiteSpace($RdpUsername)) {
        $lines.Add("username:s:$RdpUsername")
    }
    $content = ($lines -join "`r`n") + "`r`n"
    $tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) `
        ("SecureRDP-$PID-$([guid]::NewGuid().ToString('N')).rdp")
    [System.IO.File]::WriteAllText($tmpPath, $content, [System.Text.UTF8Encoding]::new($false))
    Write-ConnectLog "New-RdpFile: written to $tmpPath  RdpUsername='$RdpUsername'" -Level 'DEBUG'
    return $tmpPath
}

function Show-ConnectingWindow {
    param([Parameter(Mandatory)][string]$ServerName)
    $form                  = New-Object System.Windows.Forms.Form
    $form.Text             = "SecureRDP - Connecting to $ServerName"
    $form.Width            = 420; $form.Height = 150
    $form.FormBorderStyle  = 'FixedDialog'
    $form.MaximizeBox      = $false; $form.MinimizeBox = $false
    $form.StartPosition    = 'CenterScreen'
    $form.BackColor        = [System.Drawing.Color]::FromArgb(245, 245, 245)
    $form.ControlBox       = $false

    $lbl          = New-Object System.Windows.Forms.Label
    $lbl.Text     = "Connecting to $ServerName..."
    $lbl.Left     = 16; $lbl.Top = 20; $lbl.Width = 380; $lbl.Height = 24
    $lbl.Font     = $FontHeader
    $form.Controls.Add($lbl)

    $bar                       = New-Object System.Windows.Forms.ProgressBar
    $bar.Style                 = 'Marquee'
    $bar.Left                  = 16; $bar.Top = 52; $bar.Width = 380; $bar.Height = 18
    $bar.MarqueeAnimationSpeed = 30
    $form.Controls.Add($bar)

    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    return [pscustomobject]@{ Form = $form; Label = $lbl }
}

function New-StatusWindow {
    param(
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][string]$ServerAddress,
        [Parameter(Mandatory)][int]$SshPort,
        [Parameter(Mandatory)][int]$LocalRdpPort
    )
    $form                  = New-Object System.Windows.Forms.Form
    $form.Text             = "SecureRDP - $ServerName"
    $form.Width            = 360; $form.Height = 210
    $form.FormBorderStyle  = 'FixedToolWindow'
    $form.ShowInTaskbar    = $true
    $form.TopMost          = $false
    $form.StartPosition    = 'CenterScreen'
    $form.BackColor        = [System.Drawing.Color]::FromArgb(245, 245, 245)

    $statusLbl            = New-Object System.Windows.Forms.Label
    $statusLbl.Text       = "Connected to $ServerName"
    $statusLbl.Font       = $FontHeader
    $statusLbl.ForeColor  = $ColorOk
    $statusLbl.Left       = 16; $statusLbl.Top = 14
    $statusLbl.Width      = 320; $statusLbl.Height = 22
    $form.Controls.Add($statusLbl)

    $addrLbl              = New-Object System.Windows.Forms.Label
    $addrLbl.Text         = "Server: $ServerAddress  (port $SshPort)"
    $addrLbl.Font         = $FontNormal
    $addrLbl.ForeColor    = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $addrLbl.Left         = 16; $addrLbl.Top = 38
    $addrLbl.Width        = 320; $addrLbl.Height = 18
    $form.Controls.Add($addrLbl)

    $detailLbl            = New-Object System.Windows.Forms.Label
    $detailLbl.Text       = "SSH tunnel active -> localhost:$LocalRdpPort"
    $detailLbl.Font       = $FontNormal
    $detailLbl.ForeColor  = [System.Drawing.Color]::FromArgb(80, 80, 80)
    $detailLbl.Left       = 16; $detailLbl.Top = 58
    $detailLbl.Width      = 320; $detailLbl.Height = 18
    $form.Controls.Add($detailLbl)

    $elapsedLbl           = New-Object System.Windows.Forms.Label
    $elapsedLbl.Text      = 'Connected for: 0m 0s'
    $elapsedLbl.Font      = $FontNormal
    $elapsedLbl.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 100)
    $elapsedLbl.Left      = 16; $elapsedLbl.Top = 80
    $elapsedLbl.Width     = 320; $elapsedLbl.Height = 18
    $form.Controls.Add($elapsedLbl)

    $disconnBtn           = New-Object System.Windows.Forms.Button
    $disconnBtn.Text      = 'Disconnect'
    $disconnBtn.Font      = $FontNormal
    $disconnBtn.Width     = 100; $disconnBtn.Height = 30
    $disconnBtn.Left      = 360 - 100 - 16 - 8; $disconnBtn.Top = 118
    $disconnBtn.FlatStyle = 'Flat'
    $disconnBtn.BackColor = $ColorError
    $disconnBtn.ForeColor = [System.Drawing.Color]::White
    $disconnBtn.FlatAppearance.BorderSize = 0
    $disconnBtn.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $form.Controls.Add($disconnBtn)

    return [pscustomobject]@{
        Form             = $form
        StatusLabel      = $statusLbl
        DetailLabel      = $detailLbl
        ElapsedLabel     = $elapsedLbl
        DisconnectButton = $disconnBtn
        StartTime        = Get-Date
    }
}

# =============================================================================
# STARTUP
# =============================================================================
Initialize-ConnectLog
Write-ConnectLog "Connect-SecureRDP.ps1 starting. ScriptDir=$ScriptDir  PID=$PID" -Level 'INFO'
Write-ConnectLog "LocalRdpPort=$LocalRdpPort  TunnelTimeoutSec=$TunnelTimeoutSec  LogEnabled=$($script:LogEnabled)" -Level 'DEBUG'

# =============================================================================
# LOAD AND VALIDATE CONFIGURATION
# =============================================================================
$configPath = Join-Path $ScriptDir 'config.json'
Write-ConnectLog "Config path: $configPath" -Level 'DEBUG'

if (-not (Test-Path -LiteralPath $configPath)) {
    Fail-Srdp -Title 'Missing Configuration' -Message @"
config.json not found.

Expected location:
$configPath

Ensure all package files are in the same folder as this script.
"@
}

try {
    $CFG = Read-Config -Path $configPath
    Write-ConnectLog 'config.json loaded successfully.' -Level 'INFO'
} catch {
    Fail-Srdp -Title 'Configuration Error' -Message $_.Exception.Message
}

try {
    $ServerName = Convert-ToTrimmedString (Get-ConfigProperty -Object $CFG -Names @('serverName', 'ServerName'))

    $ServerAddress = Convert-ToTrimmedString (Get-ConfigProperty -Object $CFG -Names @('serverAddress', 'ServerAddress', 'address', 'Address'))
    if (-not $ServerAddress) { throw 'config.json is missing serverAddress. This must be the IP address or hostname of the server.' }
    $ServerAddress = Normalize-ServerAddress -Address $ServerAddress

    $SshPort = 22
    $rawSshPort = Get-ConfigProperty -Object $CFG -Names @('sshPort', 'SshPort')
    if ($null -ne $rawSshPort) {
        $n = 0
        if ([int]::TryParse([string]$rawSshPort, [ref]$n) -and $n -ge 1 -and $n -le 65535) {
            $SshPort = $n
        }
    }

    $RdpPort = 3389
    $rawRdpPort = Get-ConfigProperty -Object $CFG -Names @('rdpPort', 'RdpPort')
    if ($null -ne $rawRdpPort) {
        $n = 0
        if ([int]::TryParse([string]$rawRdpPort, [ref]$n) -and $n -ge 1 -and $n -le 65535) {
            $RdpPort = $n
        }
    }

    $CertThumb  = Convert-ToTrimmedString (Get-ConfigProperty -Object $CFG -Names @('rdpCertThumbprint', 'rdpCertThumb', 'RdpCertThumbprint'))
    $CertBase64 = Convert-ToTrimmedString (Get-ConfigProperty -Object $CFG -Names @('rdpCertBase64', 'RdpCertBase64'))

    $Account = Convert-ToTrimmedString (Get-ConfigProperty -Object $CFG -Names @('sshUsername', 'SshUsername'))
    if (-not $Account) {
        throw 'config.json is missing sshUsername. This must be a valid Windows account on the server.'
    }

    $RdpUsername = Convert-ToTrimmedString (Get-ConfigProperty -Object $CFG -Names @('rdpUsername', 'RdpUsername'))
    if (-not $RdpUsername) { $RdpUsername = '' }

    $SshKeyLabel = Convert-ToTrimmedString (Get-ConfigProperty -Object $CFG -Names @('sshKeyLabel', 'SshKeyLabel'))
    if (-not $SshKeyLabel) { $SshKeyLabel = '' }

} catch {
    Fail-Srdp -Title 'Invalid Configuration' -Message $_.Exception.Message
}

$DisplayName = if ($ServerName) { $ServerName } else { $ServerAddress }

Write-ConnectLog "Config parsed: ServerName='$ServerName'  DisplayName=$DisplayName  ServerAddress=$ServerAddress  SshPort=$SshPort  RdpPort=$RdpPort  SshUsername=$Account  RdpUsername='$RdpUsername'  KeyLabel='$SshKeyLabel'" -Level 'INFO'
Write-ConnectLog "CertThumb present: $(-not [string]::IsNullOrWhiteSpace($CertThumb))  CertBase64 present: $(-not [string]::IsNullOrWhiteSpace($CertBase64))" -Level 'DEBUG'

# =============================================================================
# RESOLVE REQUIRED FILES AND TOOLS
# =============================================================================
$keyFile    = Join-Path $ScriptDir 'client_key'
$knownHosts = Join-Path $ScriptDir 'known_hosts'
$sshExe     = Find-SshExe

$missing = [System.Collections.Generic.List[string]]::new()
foreach ($item in @($keyFile, $knownHosts, $configPath)) {
    $exists = Test-Path -LiteralPath $item
    Write-ConnectLog "File check: $item -- $(if ($exists) { 'found' } else { 'MISSING' })" -Level 'DEBUG'
    if (-not $exists) { [void]$missing.Add($item) }
}
if (-not $sshExe) {
    [void]$missing.Add('ssh.exe (not found in system OpenSSH or bundled package paths)')
}
if ($missing.Count -gt 0) {
    $missingList = $missing -join "`n"
    Write-ConnectLog "Missing required files:`n$missingList" -Level 'ERROR'
    Fail-Srdp -Title 'Missing Files' -Message @"
Required files are missing:

$missingList

Ensure all package files are present and re-extract if needed.
"@
}

$keyFileFull    = (Resolve-Path -LiteralPath $keyFile).Path
$knownHostsFull = (Resolve-Path -LiteralPath $knownHosts).Path
Write-ConnectLog "Resolved paths: key=$keyFileFull  knownHosts=$knownHostsFull" -Level 'DEBUG'
Write-ConnectLog "SSH executable: $sshExe" -Level 'INFO'

# =============================================================================
# PROCESS-LEVEL STATE -- initialized before top-level try so finally can
# always safely reference and clean up these variables.
# =============================================================================
$sshConfigPath        = $null
$tempKeyPath          = $null
$rdpFilePath          = $null
$sshProc              = $null
$mstscProc            = $null
$connectWindow        = $null
$statusWindow         = $null
$script:tunnelHandled = $false

try {
    # -------------------------------------------------------------------------
    # Copy private key to temp file owned by current user
    # -------------------------------------------------------------------------
    Write-ConnectLog 'Copying private key to temp file...' -Level 'INFO'
    $tempKeyPath = Copy-KeyToTemp -SourcePath $keyFileFull

    # -------------------------------------------------------------------------
    # Local tunnel port preflight
    # -------------------------------------------------------------------------
    Write-ConnectLog "Checking local port $LocalRdpPort availability..." -Level 'DEBUG'
    if (Test-PortOpen -Port $LocalRdpPort -TimeoutMs 200) {
        throw "SecureRDP - Port In Use`nLocal port $LocalRdpPort is already in use.`n`nClose any other applications using this port and try again."
    }
    Write-ConnectLog "Local port $LocalRdpPort is available." -Level 'INFO'

    # -------------------------------------------------------------------------
    # Optional certificate install (deferred from initial public release)
    # -------------------------------------------------------------------------
    # Install-RdpCertificateIfRequested -ServerName $DisplayName -Thumbprint $CertThumb -Base64Der $CertBase64

    # -------------------------------------------------------------------------
    # Connecting dialog
    # -------------------------------------------------------------------------
    Write-ConnectLog 'Showing connecting window.' -Level 'DEBUG'
    $connectWindow = Show-ConnectingWindow -ServerName $DisplayName

    # -------------------------------------------------------------------------
    # Build temporary SSH config and launch process
    # -------------------------------------------------------------------------
    $sshLogLevel = if ($script:LogEnabled) { 'DEBUG' } else { 'ERROR' }
    Write-ConnectLog "Building SSH config. sshLogLevel=$sshLogLevel" -Level 'DEBUG'

    $sshConfigPath = New-SshConfigFile `
        -ServerAddress  $ServerAddress `
        -Account        $Account `
        -SshPort        $SshPort `
        -RdpPort        $RdpPort `
        -KeyFile        $tempKeyPath `
        -KnownHostsFile $knownHostsFull `
        -LocalRdpPort   $LocalRdpPort `
        -LogLevel       $sshLogLevel

    $sshArgs = @('-F', $sshConfigPath, '-N', 'SecureRDP')

    $psi                        = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $sshExe
    $psi.Arguments              = ($sshArgs | ForEach-Object {
        if ($_ -match '\s') { '"' + $_.Replace('"', '\"') + '"' } else { $_ }
    }) -join ' '
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardOutput = $true

    $sshProc           = New-Object System.Diagnostics.Process
    $sshProc.StartInfo = $psi

    $stderrLines = [System.Collections.Generic.List[string]]::new()
    $stdoutLines = [System.Collections.Generic.List[string]]::new()
    $stderrSync  = [System.Object]::new()
    $stdoutSync  = [System.Object]::new()

    $null = $sshProc.add_ErrorDataReceived({
        param($sender, $e)
        if ($e.Data) {
            [System.Threading.Monitor]::Enter($stderrSync)
            try   { [void]$stderrLines.Add($e.Data) }
            finally { [System.Threading.Monitor]::Exit($stderrSync) }
        }
    })
    $null = $sshProc.add_OutputDataReceived({
        param($sender, $e)
        if ($e.Data) {
            [System.Threading.Monitor]::Enter($stdoutSync)
            try   { [void]$stdoutLines.Add($e.Data) }
            finally { [System.Threading.Monitor]::Exit($stdoutSync) }
        }
    })

    Write-ConnectLog "Launching ssh.exe. Args: $($psi.Arguments)" -Level 'INFO'
    try {
        if (-not $sshProc.Start()) { throw 'ssh.exe did not start.' }
        $sshProc.BeginErrorReadLine()
        $sshProc.BeginOutputReadLine()
        Write-ConnectLog "ssh.exe started. PID=$($sshProc.Id)" -Level 'INFO'
    } catch {
        $errMsg = $_.Exception.Message
        Write-ConnectLog "ssh.exe failed to start: $errMsg" -Level 'ERROR'
        throw "Could not start ssh.exe. Path: $sshExe. Error: $errMsg"
    }

    # -------------------------------------------------------------------------
    # Wait for tunnel readiness
    # -------------------------------------------------------------------------
    Write-ConnectLog "Polling for tunnel readiness on port $LocalRdpPort (timeout=${TunnelTimeoutSec}s)..." -Level 'INFO'
    $deadline    = (Get-Date).AddSeconds($TunnelTimeoutSec)
    $tunnelState = 'timeout'
    $pollCount   = 0

    while ((Get-Date) -lt $deadline) {
        if ($sshProc.HasExited) {
            Write-ConnectLog "ssh.exe exited during poll. ExitCode=$($sshProc.ExitCode)" -Level 'WARN'
            $tunnelState = 'exited'
            break
        }
        if (Test-PortOpen -Port $LocalRdpPort -TimeoutMs 150) {
            $tunnelState = 'ready'
            break
        }
        $pollCount++
        if ($pollCount % 10 -eq 0) {
            $elapsed = [int]((Get-Date) - ($deadline.AddSeconds(-$TunnelTimeoutSec))).TotalSeconds
            Write-ConnectLog "Tunnel poll: ${elapsed}s elapsed  polls=$pollCount" -Level 'DEBUG'
        }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 300
    }

    Write-ConnectLog "Tunnel poll complete. tunnelState=$tunnelState  polls=$pollCount" -Level 'INFO'

    try { $connectWindow.Form.Close() } catch {}
    $connectWindow = $null

    if ($tunnelState -ne 'ready') {
        try { if (-not $sshProc.HasExited) { $sshProc.Kill() } } catch {}
        try { $sshProc.WaitForExit(500) | Out-Null } catch {}

        $stderr = if ($stderrLines.Count -gt 0) { $stderrLines -join "`n" } else { '' }
        $stdout = if ($stdoutLines.Count -gt 0) { $stdoutLines -join "`n" } else { '' }

        Write-ConnectLog "SSH stderr:`n$stderr" -Level 'DEBUG'
        if ($stdout) { Write-ConnectLog "SSH stdout:`n$stdout" -Level 'DEBUG' }
        Write-ConnectLog "SSH exit code: $($sshProc.ExitCode)" -Level 'DEBUG'

        $hint = if ($stderr -match 'Permission denied') {
            "The server rejected your SSH key. Check authorized_keys on the server."
        } elseif ($stderr -match 'Connection refused') {
            "The server refused the connection. Check that the SSH service is running and the firewall rule is enabled."
        } elseif ($stderr -match 'Host key.*changed|REMOTE HOST IDENTIFICATION') {
            "The server host key has changed. Request a new client package from the server administrator."
        } elseif ($stderr -match 'No route to host|Network unreachable') {
            "The server is not reachable. Check the address ($ServerAddress) and network connectivity."
        } elseif ($stderr -match 'Bad local forwarding|ExitOnForwardFailure') {
            "The local port forward could not be established. Port $LocalRdpPort may be in use."
        } elseif ($tunnelState -eq 'timeout') {
            "Connection timed out. Verify the server address ($ServerAddress) and that SSH port $SshPort is reachable."
        } else { 'An unknown error occurred.' }

        $tech = "Tunnel state : $tunnelState`nSSH exit code: $($sshProc.ExitCode)"

        $errorLines = [System.Collections.Generic.List[string]]::new()
        $errorLines.Add("Could not establish the secure tunnel to $DisplayName.")
        $errorLines.Add('')
        $errorLines.Add($hint)
        $errorLines.Add('')
        $errorLines.Add('--- Technical Detail ---')
        $errorLines.Add($tech)
        if ($stderr) {
            $errorLines.Add('')
            $errorLines.Add('--- SSH Output ---')
            $errorLines.Add($stderr)
        }
        if ($stdout) {
            $errorLines.Add('')
            $errorLines.Add('--- SSH Stdout ---')
            $errorLines.Add($stdout)
        }
        if ($script:LogEnabled -and $null -ne $script:LogFile) {
            $errorLines.Add('')
            $errorLines.Add("--- Log File ---")
            $errorLines.Add($script:LogFile)
        }

        $errorText = $errorLines -join "`r`n"
        Write-ConnectLog "Connection failed. Showing error screen." -Level 'ERROR'
        Show-ErrorScreen -ErrorText $errorText
        exit 1
    }

    Write-ConnectLog 'Tunnel ready. Generating RDP file and launching mstsc.' -Level 'INFO'

    # -------------------------------------------------------------------------
    # Generate temporary RDP file
    # -------------------------------------------------------------------------
    Write-ConnectLog "Generating temp RDP file. RdpUsername='$RdpUsername'" -Level 'DEBUG'
    $rdpFilePath = New-RdpFile -LocalRdpPort $LocalRdpPort -RdpPort $RdpPort -RdpUsername $RdpUsername

    # -------------------------------------------------------------------------
    # Launch mstsc against the local forwarded port
    # -------------------------------------------------------------------------
    $statusWindow = New-StatusWindow -ServerName $DisplayName -ServerAddress $ServerAddress -SshPort $SshPort -LocalRdpPort $LocalRdpPort

    try {
        $mstscProc = Start-Process -FilePath 'mstsc.exe' -ArgumentList @($rdpFilePath) -PassThru
        Write-ConnectLog "mstsc.exe launched. PID=$($mstscProc.Id)" -Level 'INFO'
    } catch {
        $errMsg = $_.Exception.Message
        Write-ConnectLog "mstsc.exe failed to launch: $errMsg" -Level 'ERROR'
        throw "Could not launch Remote Desktop. Error: $errMsg"
    }

    try { $null = $mstscProc.WaitForInputIdle(5000) } catch {}
    Write-ConnectLog 'mstsc WaitForInputIdle complete. Entering status monitor.' -Level 'DEBUG'

    # -------------------------------------------------------------------------
    # Status window -- timer and event handlers
    # -------------------------------------------------------------------------
    $statusTimer          = New-Object System.Windows.Forms.Timer
    $statusTimer.Interval = 1000

    $statusTimer.Add_Tick({
        if ($null -eq $statusWindow -or $null -eq $sshProc -or $null -eq $mstscProc) { return }

        $elapsed = (Get-Date) - $statusWindow.StartTime
        $statusWindow.ElapsedLabel.Text = "Connected for: $([int]$elapsed.TotalMinutes)m $($elapsed.Seconds)s"

        if ($sshProc.HasExited -and -not $script:tunnelHandled) {
            $script:tunnelHandled = $true
            $statusTimer.Stop()
            Write-ConnectLog "SSH tunnel lost unexpectedly. ExitCode=$($sshProc.ExitCode)" -Level 'WARN'
            $statusWindow.StatusLabel.Text      = 'Tunnel Lost'
            $statusWindow.StatusLabel.ForeColor = $ColorError
            $statusWindow.DetailLabel.Text      = 'The SSH tunnel was interrupted.'
            [System.Windows.Forms.Application]::DoEvents()
            [void](Show-SrdpMessageTopmost -Title 'Tunnel Lost' -Message @"
The secure tunnel to $DisplayName was interrupted.

The RDP session may have dropped. Please close the RDP window and reconnect.
"@ -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning))
            try { $statusWindow.Form.Close() } catch {}
            return
        }

        if ($mstscProc.HasExited -and -not $sshProc.HasExited -and -not $script:tunnelHandled) {
            $script:tunnelHandled = $true
            $statusTimer.Stop()
            Write-ConnectLog 'mstsc exited cleanly. Shutting down tunnel.' -Level 'INFO'
            $statusWindow.StatusLabel.Text      = 'Session ended'
            $statusWindow.StatusLabel.ForeColor = $ColorHeader
            $statusWindow.DetailLabel.Text      = 'Remote Desktop session closed.'
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Seconds 1
            try { if (-not $sshProc.HasExited) { $sshProc.Kill() } } catch {}
            try { $statusWindow.Form.Close() } catch {}
            return
        }
    })

    $statusWindow.DisconnectButton.Add_Click({
        $script:tunnelHandled = $true
        $statusTimer.Stop()
        Write-ConnectLog 'User clicked Disconnect button.' -Level 'INFO'
        try { if ($null -ne $sshProc   -and -not $sshProc.HasExited)   { $sshProc.Kill()   } } catch {}
        try { if ($null -ne $mstscProc -and -not $mstscProc.HasExited) { $mstscProc.Kill() } } catch {}
        try { $statusWindow.Form.Close() } catch {}
    })

    $statusWindow.Form.Add_FormClosing({
        param($sender, $e)
        if (-not $script:tunnelHandled -and $null -ne $sshProc -and -not $sshProc.HasExited) {
            $e.Cancel = $true
            $answer = Show-SrdpMessageTopmost -Title 'Confirm Disconnect' -Message @"
The SSH tunnel is still connected.

Disconnect and close?
"@ -Icon ([System.Windows.Forms.MessageBoxIcon]::Question) `
   -Buttons ([System.Windows.Forms.MessageBoxButtons]::YesNo)

            if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
                $script:tunnelHandled = $true
                $statusTimer.Stop()
                Write-ConnectLog 'User confirmed disconnect via form close.' -Level 'INFO'
                try { if (-not $sshProc.HasExited)                             { $sshProc.Kill()   } } catch {}
                try { if ($null -ne $mstscProc -and -not $mstscProc.HasExited) { $mstscProc.Kill() } } catch {}
                $e.Cancel = $false
            } else {
                Write-ConnectLog 'User cancelled form close -- staying connected.' -Level 'DEBUG'
            }
        }
    })

    $statusTimer.Start()
    Write-ConnectLog 'Entering Application::Run message pump.' -Level 'DEBUG'
    [System.Windows.Forms.Application]::Run($statusWindow.Form)
    Write-ConnectLog 'Application::Run returned. Session complete.' -Level 'INFO'
}
catch {
    $errMsg = $_.Exception.Message
    Write-ConnectLog "TOP-LEVEL CATCH: $errMsg" -Level 'ERROR'
    try { if ($null -ne $connectWindow) { $connectWindow.Form.Close() } } catch {}
    $displayMsg = if ($errMsg -notmatch '^SecureRDP - ') {
        "Could not complete the connection workflow.`n`nError: $errMsg"
    } else {
        $errMsg -replace '^SecureRDP - [^`n]+`n', ''
    }
    if ($script:LogEnabled -and $null -ne $script:LogFile) {
        $displayMsg += "`r`n`r`n--- Log File ---`r`n$($script:LogFile)"
    }
    Show-ErrorScreen -ErrorText $displayMsg
    exit 1
}
finally {
    Write-ConnectLog 'Cleanup starting.' -Level 'DEBUG'
    if ($null -ne $connectWindow) {
        try { $connectWindow.Form.Close() } catch {}
    }
    if ($null -ne $statusWindow) {
        try { $statusWindow.Form.Close() } catch {}
    }
    if ($null -ne $sshProc) {
        try { if (-not $sshProc.HasExited) { $sshProc.Kill() } } catch {}
        try { $sshProc.Dispose() } catch {}
    }
    if ($null -ne $mstscProc) {
        try { if (-not $mstscProc.HasExited) { $mstscProc.Kill() } } catch {}
        try { $mstscProc.Dispose() } catch {}
    }
    if ($null -ne $sshConfigPath -and (Test-Path -LiteralPath $sshConfigPath)) {
        try {
            Remove-Item -LiteralPath $sshConfigPath -Force -ErrorAction SilentlyContinue
            Write-ConnectLog "Temp SSH config deleted: $sshConfigPath" -Level 'DEBUG'
        } catch {}
    }
    if ($null -ne $tempKeyPath -and (Test-Path -LiteralPath $tempKeyPath)) {
        try {
            Remove-Item -LiteralPath $tempKeyPath -Force -ErrorAction SilentlyContinue
            Write-ConnectLog "Temp key file deleted: $tempKeyPath" -Level 'DEBUG'
        } catch {}
    }
    if ($null -ne $rdpFilePath -and (Test-Path -LiteralPath $rdpFilePath)) {
        try {
            Remove-Item -LiteralPath $rdpFilePath -Force -ErrorAction SilentlyContinue
            Write-ConnectLog "Temp RDP file deleted: $rdpFilePath" -Level 'DEBUG'
        } catch {}
    }
    Write-ConnectLog 'Cleanup complete. Exiting.' -Level 'INFO'
}
