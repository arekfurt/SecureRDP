# =============================================================================
# SECURE-RDP PHASE 1: ENGINE 2 (SSH SERVICE TAKEOVER)
# =============================================================================

function Invoke-SshServiceEngine {
    [CmdletBinding()]
    param(
        [int]$SshPort = 22,
        [string]$BaseConfigDir = "$env:ProgramData\ssh",
        [bool]$SshRuleWasEnabled = $false
    )

    # ENGINE 2 OWNS ITS EAP -- never inherit from caller.
    # Save caller EAP and restore before every return path.
    $callerEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'

    $ServiceName    = 'sshd'
    $ConfigPath     = Join-Path $BaseConfigDir 'sshd_config'
    $SrdpSshRoot    = 'C:\ProgramData\SecureRDP\ssh'
    $SrdpHostKeyDir = 'C:\ProgramData\SecureRDP\ssh\host'
    $SrdpHostKey    = 'C:\ProgramData\SecureRDP\ssh\host\ssh_host_ed25519_key'
    $SrdpAuthKeys   = 'C:\ProgramData\SecureRDP\ssh\authorized_keys'

    $Result = [PSCustomObject]@{
        Success = $false
        Status  = 'Unknown'
        Data    = @{
            BackupPath           = $null
            SshdConfigPath       = $ConfigPath
            ServicePort          = $SshPort
            OriginalServiceState = 'NotInstalled'
            OriginalStartType    = 'None'
            ActionTaken          = 'None'
            KeysSecured          = 0
            WindowsRuleDisabled  = $false
            WindowsRuleWasEnabled = $SshRuleWasEnabled
        }
        Logs    = [System.Collections.Generic.List[string]]::new()
        Errors  = [System.Collections.Generic.List[string]]::new()
    }

    $Result.Logs.Add("Engine 2 starting. EAP set to Stop.")
    $Result.Logs.Add("BaseConfigDir: $BaseConfigDir")
    $Result.Logs.Add("ConfigPath: $ConfigPath")
    $Result.Logs.Add("SrdpSshRoot: $SrdpSshRoot")
    try { Write-SrdpLog "Engine 2 starting. BaseConfigDir=$BaseConfigDir SshPort=$SshPort" -Level INFO -Component 'Engine2' } catch {}

    try {
        # 1. Capture Original Service State
        $Result.Logs.Add("Step 1: Capturing original service state...")
        try { Write-SrdpLog "Step 1: Querying sshd service state." -Level DEBUG -Component 'Engine2' } catch {}
        $svc           = Get-Service $ServiceName -ErrorAction SilentlyContinue
        $configExists  = Test-Path $ConfigPath
        $serviceExists = $null -ne $svc

        $Result.Data.ActionTaken = switch ($true) {
            { $serviceExists -and $configExists      } { 'FullTakeover'; break }
            { $serviceExists -and -not $configExists } { 'ServiceOnly';  break }
            { -not $serviceExists -and $configExists } { 'ConfigOnly';   break }
            default { 'FreshConfig' }
        }
        $Result.Logs.Add("ActionTaken determined: $($Result.Data.ActionTaken)")
        try { Write-SrdpLog "ActionTaken=$($Result.Data.ActionTaken) serviceExists=$serviceExists configExists=$configExists" -Level INFO -Component 'Engine2' } catch {}

        if ($serviceExists) {
            $Result.Data.OriginalServiceState = $svc.Status.ToString()
            $Result.Data.OriginalStartType    = $svc.StartType.ToString()
            $Result.Logs.Add("Detected existing '$ServiceName' service (State: $($Result.Data.OriginalServiceState), StartType: $($Result.Data.OriginalStartType)).")
            $Result.Logs.Add("Stopping service to allow configuration changes...")
            try { Write-SrdpLog "Stopping sshd service (was: $($Result.Data.OriginalServiceState))" -Level INFO -Component 'Engine2' } catch {}
            Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
            $Result.Logs.Add("Service stop command issued.")
            try { Write-SrdpLog "sshd stop command issued." -Level DEBUG -Component 'Engine2' } catch {}
        } else {
            $Result.Logs.Add("Service '$ServiceName' not found. Proceeding as fresh configuration.")
            try { Write-SrdpLog "sshd service not found. FreshConfig path." -Level INFO -Component 'Engine2' } catch {}
        }

        # 2. Disable Windows-created OpenSSH firewall rule if present AND new
        # When Windows installs OpenSSH Server it auto-creates an enabled inbound
        # rule 'OpenSSH-Server-In-TCP'. We disable it to prevent unexpected SSH
        # exposure -- but only if the rule was NOT already enabled before QS started
        # (i.e. we do not touch pre-existing admin-enabled rules).
        $Result.Logs.Add("Step 2: Checking for Windows-created OpenSSH firewall rule...")
        try { Write-SrdpLog "Step 2: Checking OpenSSH-Server-In-TCP. SshRuleWasEnabled=$SshRuleWasEnabled" -Level DEBUG -Component 'Engine2' } catch {}
        try {
            $winRule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
            if ($null -ne $winRule) {
                if ($winRule.Enabled -eq 'True') {
                    if ($SshRuleWasEnabled) {
                        # Rule was already enabled before QS -- leave it alone
                        $Result.Logs.Add("Windows SSH firewall rule 'OpenSSH-Server-In-TCP' was already enabled before Quick Start. Leaving it enabled.")
                        try { Write-SrdpLog "OpenSSH-Server-In-TCP was pre-existing enabled -- not touching." -Level INFO -Component 'Engine2' } catch {}
                    } else {
                        # Rule was just created by Engine 1's install -- disable it
                        Disable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction Stop
                        $Result.Data.WindowsRuleDisabled = $true
                        $Result.Logs.Add("Disabled newly-created Windows firewall rule 'OpenSSH-Server-In-TCP'. SecureRDP will manage SSH firewall access via its own rule in Quick Start Part 2.")
                        try { Write-SrdpLog "Disabled new OpenSSH-Server-In-TCP firewall rule." -Level INFO -Component 'Engine2' } catch {}
                    }
                } else {
                    $Result.Logs.Add("Windows-created firewall rule 'OpenSSH-Server-In-TCP' is already disabled. No action needed.")
                    try { Write-SrdpLog "OpenSSH-Server-In-TCP already disabled -- no action." -Level DEBUG -Component 'Engine2' } catch {}
                }
            } else {
                $Result.Logs.Add("Windows-created firewall rule 'OpenSSH-Server-In-TCP' not present.")
                try { Write-SrdpLog "OpenSSH-Server-In-TCP rule not present." -Level DEBUG -Component 'Engine2' } catch {}
            }
        } catch {
            $errMsg = $_.Exception.Message
            $Result.Logs.Add("Warning: Could not check/disable Windows OpenSSH firewall rule: $errMsg. Continuing.")
            try { Write-SrdpLog "WARN: Could not handle OpenSSH-Server-In-TCP: $errMsg" -Level WARN -Component 'Engine2' } catch {}
        }

        # 3. Define hardened config
        $Result.Logs.Add("Step 3: Defining hardened sshd_config content...")
        try { Write-SrdpLog "Step 3: Building sshd_config content for port $SshPort." -Level DEBUG -Component 'Engine2' } catch {}
        $config = @(
            "Port $SshPort",
            "HostKey C:/ProgramData/SecureRDP/ssh/host/ssh_host_ed25519_key",
            "AuthorizedKeysFile C:/ProgramData/SecureRDP/ssh/authorized_keys",
            "PubkeyAuthentication yes",
            "PasswordAuthentication no",
            "PermitEmptyPasswords no",
            "AllowTcpForwarding local",
            "GatewayPorts no",
            "PermitTTY no",
            "X11Forwarding no",
            "Match Group administrators",
            "    AuthorizedKeysFile C:/ProgramData/SecureRDP/ssh/authorized_keys"
        )

        # 4. Perform Surgical Backup (skipped if existing config is identical to ours)
        $Result.Logs.Add("Step 4: Performing surgical backup check...")
        if ($configExists) {
            try { Write-SrdpLog "Step 4: Existing config found -- computing hashes for comparison." -Level DEBUG -Component 'Engine2' } catch {}
            $pendingContent = $config -join "`r`n"
            $pendingBytes   = [System.Text.Encoding]::UTF8.GetBytes($pendingContent)
            $sha            = [System.Security.Cryptography.SHA256]::Create()
            $pendingHash    = [BitConverter]::ToString($sha.ComputeHash($pendingBytes)) -replace '-', ''
            $sha.Dispose()

            $existingHash = (Get-FileHash -Path $ConfigPath -Algorithm SHA256).Hash

            if ($existingHash -eq $pendingHash) {
                $Result.Logs.Add("Existing sshd_config is identical to SecureRDP config -- skipping backup.")
                try { Write-SrdpLog "Existing config matches SecureRDP config -- backup skipped." -Level INFO -Component 'Engine2' } catch {}
            } else {
                $timestamp    = Get-Date -Format 'yyyyMMdd_HHmmss'
                $backupFolder = Join-Path $env:ProgramData "SecureRDP\Backups\sshd_$timestamp"
                New-Item -Path $backupFolder -ItemType Directory -Force | Out-Null
                $Result.Logs.Add("Existing configuration found. Backing up to: $backupFolder")
                try { Write-SrdpLog "Backing up existing config to: $backupFolder" -Level INFO -Component 'Engine2' } catch {}

                $filesToBackUp = @('sshd_config', 'authorized_keys', 'ssh_host_*')
                foreach ($pattern in $filesToBackUp) {
                    Get-ChildItem -Path $BaseConfigDir -Filter $pattern -ErrorAction SilentlyContinue |
                        Copy-Item -Destination $backupFolder -Force
                }
                $Result.Data.BackupPath = $backupFolder
                $Result.Logs.Add("Backup complete.")
                try { Write-SrdpLog "Backup complete: $backupFolder" -Level INFO -Component 'Engine2' } catch {}
            }
        } else {
            $Result.Logs.Add("No existing configuration to back up.")
            try { Write-SrdpLog "No existing sshd_config -- backup skipped." -Level DEBUG -Component 'Engine2' } catch {}
        }

        # 5. Ensure BaseConfigDir exists then write hardened config
        $Result.Logs.Add("Step 5: Writing hardened sshd_config...")
        try { Write-SrdpLog "Step 5: Ensuring $BaseConfigDir exists before writing config." -Level DEBUG -Component 'Engine2' } catch {}

        # RULE: every file write must be preceded by a directory existence guard
        if (-not (Test-Path $BaseConfigDir)) {
            New-Item -ItemType Directory -Path $BaseConfigDir -Force | Out-Null
            $Result.Logs.Add("Created directory: $BaseConfigDir")
            try { Write-SrdpLog "Created BaseConfigDir: $BaseConfigDir" -Level INFO -Component 'Engine2' } catch {}
        }

        try { Write-SrdpLog "Writing sshd_config to: $ConfigPath" -Level INFO -Component 'Engine2' } catch {}
        $config | Set-Content $ConfigPath -Force -Encoding UTF8

        # RULE: every file write must be followed by verification
        if (-not (Test-Path $ConfigPath)) {
            $msg = "CRITICAL: sshd_config was not found at $ConfigPath after write. Cannot continue."
            $Result.Errors.Add($msg)
            $Result.Logs.Add($msg)
            $Result.Success = $false
            $Result.Status  = 'FatalError'
            try { Write-SrdpLog $msg -Level ERROR -Component 'Engine2' } catch {}
            $ErrorActionPreference = $callerEAP
            return $Result
        }
        $writtenSize = (Get-Item $ConfigPath).Length
        if ($writtenSize -eq 0) {
            $msg = "CRITICAL: sshd_config at $ConfigPath exists but is empty after write."
            $Result.Errors.Add($msg)
            $Result.Logs.Add($msg)
            $Result.Success = $false
            $Result.Status  = 'FatalError'
            try { Write-SrdpLog $msg -Level ERROR -Component 'Engine2' } catch {}
            $ErrorActionPreference = $callerEAP
            return $Result
        }
        $Result.Logs.Add("sshd_config written and verified: $ConfigPath ($writtenSize bytes)")
        try { Write-SrdpLog "sshd_config written and verified: $ConfigPath ($writtenSize bytes)" -Level INFO -Component 'Engine2' } catch {}

        # 5a. Bootstrap SecureRDP SSH data directory and authorized_keys file
        $Result.Logs.Add("Step 5a: Bootstrapping SecureRDP SSH data directory...")
        try { Write-SrdpLog "Step 5a: Bootstrapping $SrdpSshRoot" -Level DEBUG -Component 'Engine2' } catch {}
        $system = New-Object System.Security.Principal.NTAccount('NT AUTHORITY\SYSTEM')
        $admins = New-Object System.Security.Principal.NTAccount('BUILTIN\Administrators')

        if (-not (Test-Path $SrdpSshRoot)) {
            New-Item -Path $SrdpSshRoot -ItemType Directory -Force | Out-Null
            $Result.Logs.Add("Created SecureRDP SSH root: $SrdpSshRoot")
            try { Write-SrdpLog "Created $SrdpSshRoot" -Level INFO -Component 'Engine2' } catch {}
        }
        if (-not (Test-Path $SrdpHostKeyDir)) {
            New-Item -Path $SrdpHostKeyDir -ItemType Directory -Force | Out-Null
            $Result.Logs.Add("Created SecureRDP host key directory: $SrdpHostKeyDir")
            try { Write-SrdpLog "Created $SrdpHostKeyDir" -Level INFO -Component 'Engine2' } catch {}
        }
        if (-not (Test-Path $SrdpAuthKeys)) {
            [System.IO.File]::WriteAllText($SrdpAuthKeys, '', [System.Text.UTF8Encoding]::new($false))
            # Verify
            if (-not (Test-Path $SrdpAuthKeys)) {
                $msg = "CRITICAL: authorized_keys could not be created at $SrdpAuthKeys"
                $Result.Errors.Add($msg)
                $Result.Logs.Add($msg)
                try { Write-SrdpLog $msg -Level ERROR -Component 'Engine2' } catch {}
            } else {
                $Result.Logs.Add("Created empty authorized_keys at: $SrdpAuthKeys")
                try { Write-SrdpLog "Created empty authorized_keys: $SrdpAuthKeys" -Level INFO -Component 'Engine2' } catch {}
            }
        } else {
            $Result.Logs.Add("authorized_keys already exists at: $SrdpAuthKeys")
            try { Write-SrdpLog "authorized_keys already exists: $SrdpAuthKeys" -Level DEBUG -Component 'Engine2' } catch {}
        }

        # Set ACLs on authorized_keys
        try {
            $akAcl = Get-Acl $SrdpAuthKeys
            $akAcl.SetAccessRuleProtection($true, $false)
            foreach ($rule in @($akAcl.Access)) { $akAcl.RemoveAccessRule($rule) | Out-Null }
            $akAcl.SetOwner($system)
            $akAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $system, 'FullControl', 'Allow')))
            $akAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $admins, 'FullControl', 'Allow')))
            Set-Acl $SrdpAuthKeys $akAcl
            $Result.Logs.Add("ACLs set on authorized_keys (SYSTEM + Administrators only).")
            try { Write-SrdpLog "ACLs set on authorized_keys." -Level INFO -Component 'Engine2' } catch {}
        } catch {
            $errMsg = $_.Exception.Message
            $Result.Logs.Add("Warning: Could not set ACLs on authorized_keys: $errMsg")
            try { Write-SrdpLog "WARN: Could not set ACLs on authorized_keys: $errMsg" -Level WARN -Component 'Engine2' } catch {}
        }

        # 6. Generate host key in SecureRDP host key directory
        $Result.Logs.Add("Step 6: Generating SSH host key at $SrdpHostKey...")
        try { Write-SrdpLog "Step 6: Host key generation to $SrdpHostKey" -Level INFO -Component 'Engine2' } catch {}
        $sshKeygenPath = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh-keygen.exe'
        if (Test-Path $sshKeygenPath) {
            if (Test-Path $SrdpHostKey) {
                $Result.Logs.Add("Host key already exists at $SrdpHostKey -- skipping generation.")
                try { Write-SrdpLog "Host key already exists -- skipping generation." -Level INFO -Component 'Engine2' } catch {}
            } else {
                # Rule: empty passphrase must use '""' not '' -- in PS 5.1,
                # '' is silently dropped before reaching the native executable.
                # '""' passes a properly quoted empty string that ssh-keygen accepts.
                $keygenArgs = @('-t', 'ed25519', '-f', $SrdpHostKey, '-N', '""', '-C', 'srdp-host-key')
                try { Write-SrdpLog "Running ssh-keygen: $sshKeygenPath $($keygenArgs -join ' ')" -Level DEBUG -Component 'Engine2' } catch {}
                $oldEAP2 = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                $keygenOutput = & $sshKeygenPath @keygenArgs 2>&1
                $keygenExit   = $LASTEXITCODE
                $ErrorActionPreference = $oldEAP2
                try { Write-SrdpLog "ssh-keygen exit=$keygenExit output=$($keygenOutput -join ' | ')" -Level DEBUG -Component 'Engine2' } catch {}
                if ($keygenExit -ne 0) {
                    $msg = "CRITICAL: ssh-keygen failed (exit $keygenExit): $($keygenOutput -join '; ')"
                    $Result.Errors.Add($msg)
                    $Result.Logs.Add($msg)
                    try { Write-SrdpLog $msg -Level ERROR -Component 'Engine2' } catch {}
                }

                # Verify host key was created
                if (Test-Path $SrdpHostKey) {
                    $Result.Logs.Add("Host key generated successfully at $SrdpHostKey")
                    try { Write-SrdpLog "Host key generated: $SrdpHostKey" -Level INFO -Component 'Engine2' } catch {}
                } else {
                    $msg = "CRITICAL: Host key generation ran but key not found at: $SrdpHostKey"
                    $Result.Errors.Add($msg)
                    $Result.Logs.Add($msg)
                    try { Write-SrdpLog $msg -Level ERROR -Component 'Engine2' } catch {}
                }

                # Verify public key was created
                if (Test-Path "$SrdpHostKey.pub") {
                    $Result.Logs.Add("Host public key verified: $SrdpHostKey.pub")
                    try { Write-SrdpLog "Host public key verified: $SrdpHostKey.pub" -Level INFO -Component 'Engine2' } catch {}
                } else {
                    $msg = "CRITICAL: Host public key not found at: $SrdpHostKey.pub"
                    $Result.Errors.Add($msg)
                    $Result.Logs.Add($msg)
                    try { Write-SrdpLog $msg -Level ERROR -Component 'Engine2' } catch {}
                }
            }
        } else {
            $msg = "CRITICAL: ssh-keygen.exe not found at $sshKeygenPath -- cannot generate host key."
            $Result.Errors.Add($msg)
            $Result.Logs.Add($msg)
            try { Write-SrdpLog $msg -Level ERROR -Component 'Engine2' } catch {}
        }

        # 7. Enforce ACLs on host keys
        $Result.Logs.Add("Step 7: Securing host key permissions (SYSTEM and Administrators only)...")
        try { Write-SrdpLog "Step 7: Setting ACLs on host keys in $SrdpHostKeyDir" -Level DEBUG -Component 'Engine2' } catch {}
        $privateKeys = @(Get-ChildItem $SrdpHostKeyDir -Filter '*_key' -ErrorAction SilentlyContinue)
        try { Write-SrdpLog "Found $($privateKeys.Count) key file(s) to secure." -Level DEBUG -Component 'Engine2' } catch {}

        $keysFixed = 0
        foreach ($key in $privateKeys) {
            try {
                $acl = Get-Acl $key.FullName
                $acl.SetAccessRuleProtection($true, $false)
                foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRule($rule) | Out-Null }
                $acl.SetOwner($system)
                $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $system, 'FullControl', 'Allow')))
                $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $admins, 'FullControl', 'Allow')))
                Set-Acl $key.FullName $acl
                $keysFixed++
                try { Write-SrdpLog "ACL set on: $($key.Name)" -Level DEBUG -Component 'Engine2' } catch {}
            } catch {
                $errMsg = $_.Exception.Message
                $Result.Logs.Add("Warning: Could not set ACL on $($key.Name): $errMsg")
                try { Write-SrdpLog "WARN: ACL failed on $($key.Name): $errMsg" -Level WARN -Component 'Engine2' } catch {}
            }
        }
        $Result.Data.KeysSecured = $keysFixed
        $Result.Logs.Add("ACL enforcement complete. Keys secured: $keysFixed")
        try { Write-SrdpLog "ACL enforcement complete. $keysFixed key(s) secured." -Level INFO -Component 'Engine2' } catch {}

        # Gate: halt if critical errors recorded before attempting service start.
        # sshd cannot start without host keys -- no point attempting it.
        if ($Result.Errors.Count -gt 0) {
            $Result.Success = $false
            $Result.Status  = 'FatalError'
            $Result.Logs.Add("FATAL: Critical errors recorded before service start -- halting. See Errors list.")
            try { Write-SrdpLog "Engine 2 halting before service start: $($Result.Errors.Count) critical error(s)." -Level ERROR -Component 'Engine2' } catch {}
            $ErrorActionPreference = $callerEAP
            return $Result
        }

        # 8. Service Re-branding and Start
        $Result.Logs.Add("Step 8: Service re-branding and start...")
        if ($serviceExists) {
            try { Write-SrdpLog "Step 8: Rebranding and starting sshd service." -Level INFO -Component 'Engine2' } catch {}
            $Result.Logs.Add("Updating service metadata...")
            Set-Service $ServiceName -DisplayName 'OpenSSH SSH Server (SecureRDP Managed)' -StartupType Automatic
            $Result.Logs.Add("Service display name updated.")
            try { Write-SrdpLog "Service display name set to 'OpenSSH SSH Server (SecureRDP Managed)'" -Level DEBUG -Component 'Engine2' } catch {}

            $Result.Logs.Add("Starting sshd service...")
            try { Write-SrdpLog "Starting sshd service..." -Level INFO -Component 'Engine2' } catch {}
            Start-Service $ServiceName -ErrorAction Stop

            # Verify service is running
            $svcAfter = Get-Service $ServiceName -ErrorAction SilentlyContinue
            if ($null -ne $svcAfter -and $svcAfter.Status -eq 'Running') {
                $Result.Logs.Add("Service takeover complete. sshd is running on port $SshPort.")
                try { Write-SrdpLog "sshd running. Port=$SshPort Status=Running" -Level INFO -Component 'Engine2' } catch {}
            } else {
                $actualStatus = if ($null -ne $svcAfter) { $svcAfter.Status.ToString() } else { 'NotFound' }
                $msg = "WARNING: sshd service start was requested but status is '$actualStatus' (expected Running)."
                $Result.Errors.Add($msg)
                $Result.Logs.Add($msg)
                try { Write-SrdpLog $msg -Level ERROR -Component 'Engine2' } catch {}
            }
        } else {
            $Result.Logs.Add("No existing service to rebrand -- config written, service management skipped.")
            try { Write-SrdpLog "No existing sshd service -- service management skipped." -Level INFO -Component 'Engine2' } catch {}
        }

        # Only set Success=true if no errors were recorded
        if ($Result.Errors.Count -eq 0) {
            $Result.Success = $true
            $Result.Status  = 'Verified'
            try { Write-SrdpLog "Engine 2 complete. Status=Verified Success=true" -Level INFO -Component 'Engine2' } catch {}
        } else {
            $Result.Success = $false
            $Result.Status  = 'PartialSuccess'
            try { Write-SrdpLog "Engine 2 complete with $($Result.Errors.Count) error(s). Status=PartialSuccess" -Level WARN -Component 'Engine2' } catch {}
        }
        $ErrorActionPreference = $callerEAP
        return $Result

    } catch {
        $errMsg = $_.Exception.Message
        $Result.Success = $false
        $Result.Status  = 'FatalError'
        $Result.Errors.Add("Engine 2 fatal error: $errMsg")
        $Result.Logs.Add("FATAL: Unhandled exception in Engine 2: $errMsg")
        try { Write-SrdpLog "FATAL: Unhandled exception in Engine 2: $errMsg" -Level ERROR -Component 'Engine2' } catch {}
        $ErrorActionPreference = $callerEAP
        return $Result
    }
}
