Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
# SECURE-RDP CLIENT KEY/PACKAGE WIZARD: CONTROLLER
# Orchestrates machine recon, client key generation, authorized_keys update,
# and package assembly.
# UI-agnostic -- no WinForms, no Write-Host, no Read-Host.
#
# All module imports are handled by the UI before dot-sourcing this file.
# Required modules: SSHProtoCore, AccountInventory, RDPStatus, SrdpLog
# =============================================================================

# =============================================================================
# HELPER: Write-ClientKeyEntry
# Appends a ClientKeys metadata entry to state.json after successful package
# creation. Non-fatal -- a state write failure must never cause the generation
# result to appear failed.
# =============================================================================
function Write-ClientKeyEntry {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$KeyLabel,
        [Parameter(Mandatory)][string]$SshUsername,
        [string]$RdpUsername         = '',
        [Parameter(Mandatory)][string]$ServerAddress,
        [int]$SshPort                = 22,
        [int]$RdpPort                = 3389,
        [string]$PublicKeyText       = '',
        [string]$HostFingerprint     = '',
        [string]$PackageFileName     = '',
        [string]$PackagePath         = ''
    )
    try {
        $stateFile = Join-Path $ProjectRoot 'InstalledModes\SSHProto\state.json'
        if (-not (Test-Path $stateFile)) {
            try { Write-SrdpLog "Write-ClientKeyEntry: state.json not found at $stateFile -- skipping." -Level WARN -Component 'CKW-Controller' } catch {}
            return
        }

        $state = Read-SrdpState -StateFile $stateFile
        if ($null -eq $state -or $state -is [string]) {
            try { Write-SrdpLog "Write-ClientKeyEntry: could not read state.json -- skipping." -Level WARN -Component 'CKW-Controller' } catch {}
            return
        }

        # Parse public key body (second whitespace-delimited field)
        $pubKeyBody = ''
        if ($PublicKeyText -and $PublicKeyText.Trim().Length -gt 0) {
            $parts = @($PublicKeyText.Trim() -split '\s+')
            if ($parts.Count -ge 2) { $pubKeyBody = $parts[1] }
        }

        $entry = [PSCustomObject]@{
            label            = $KeyLabel
            sshUsername      = $SshUsername
            rdpUsername      = $RdpUsername
            serverAddress    = $ServerAddress
            sshPort          = $SshPort
            rdpPort          = $RdpPort
            publicKeyBody    = $pubKeyBody
            hostFingerprint  = $HostFingerprint
            packageFileName  = $PackageFileName
            packagePath      = $PackagePath
            generatedDate    = (Get-Date -Format 'yyyy-MM-dd')
            generatedBy      = "$($env:COMPUTERNAME)\$($env:USERNAME)"
            encryptedPackage = $false
            passphrase       = ''
            linkedWindowsUser = ''
            deauthorized     = ''
            notes            = ''
        }

        # Append to existing ClientKeys or create new array
        $stProps = $state.PSObject.Properties.Name
        if ($stProps -contains 'ClientKeys' -and $null -ne $state.ClientKeys) {
            $existing = [System.Collections.Generic.List[object]]::new()
            foreach ($k in @($state.ClientKeys)) { if ($null -ne $k) { $existing.Add($k) } }
            $existing.Add($entry)
            $state | Add-Member -NotePropertyName 'ClientKeys' -NotePropertyValue $existing.ToArray() -Force
        } else {
            $state | Add-Member -NotePropertyName 'ClientKeys' -NotePropertyValue @($entry) -Force
        }

        $writeResult = Write-SrdpState -StateFile $stateFile -State $state
        if ($writeResult -is [string] -and $writeResult -like 'error:*') {
            try { Write-SrdpLog "Write-ClientKeyEntry: Write-SrdpState failed: $writeResult" -Level WARN -Component 'CKW-Controller' } catch {}
            return
        }

        try { Write-SrdpLog "Write-ClientKeyEntry: ClientKeys entry written for '$KeyLabel'." -Level INFO -Component 'CKW-Controller' } catch {}
    } catch {
        $errMsg = $_.Exception.Message
        try { Write-SrdpLog "Write-ClientKeyEntry: exception: $errMsg" -Level WARN -Component 'CKW-Controller' } catch {}
    }
}

# =============================================================================
# HELPER: Send-Progress
# =============================================================================
function Send-CkwProgress {
    param(
        [int]$CurrentStep,
        [int]$TotalSteps,
        [string]$StepName,
        [string]$Message,
        [bool]$IsWarning = $false,
        [scriptblock]$OnProgress = $null
    )
    if ($null -ne $OnProgress) {
        $progressObject = [PSCustomObject]@{
            CurrentStep = $CurrentStep
            TotalSteps  = $TotalSteps
            StepName    = $StepName
            Message     = $Message
            IsWarning   = $IsWarning
        }
        try { & $OnProgress $progressObject } catch {}
    }
}

# =============================================================================
# RECON: Invoke-ClientKeyRecon
# Gathers machine info for the orientation screen.
# =============================================================================
function Invoke-ClientKeyRecon {
    $Result = [PSCustomObject]@{
        Success = $false
        Status  = 'Unknown'
        Data    = @{
            ComputerName   = $env:COMPUTERNAME
            IsDomainJoined = $false
            DomainName     = ''
            RdpEnabled     = $false
            RdpPort        = 3389
            EligibleAccounts = @()
            AddressSuggestions = @()
            Hostname       = $env:COMPUTERNAME
            Fqdn           = ''
        }
        Logs   = [System.Collections.Generic.List[string]]::new()
        Errors = [System.Collections.Generic.List[string]]::new()
    }

    try {
        $Result.Logs.Add("Client key recon starting.")
        try { Write-SrdpLog "ClientKeyRecon: starting." -Level INFO -Component 'CKW-Controller' } catch {}

        # --- Machine info ---
        try {
            $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
            $Result.Data.IsDomainJoined = ($cs.PartOfDomain -eq $true)
            if ($Result.Data.IsDomainJoined -and $cs.Domain) {
                # Extract NetBIOS domain name from FQDN domain
                $Result.Data.DomainName = ($cs.Domain -split '\.')[0].ToUpper()
            }
            $Result.Logs.Add("Machine: $($cs.Name) Domain=$($Result.Data.IsDomainJoined) DomainName=$($Result.Data.DomainName)")
        } catch {
            $csErr = $_.Exception.Message
            $Result.Errors.Add("Machine info query failed: $csErr")
            try { Write-SrdpLog "ClientKeyRecon: Win32_ComputerSystem failed: $csErr" -Level WARN -Component 'CKW-Controller' } catch {}
        }

        # --- RDP state ---
        try {
            $rdpResult = Test-RdpEnabled
            # Test-RdpEnabled returns a string: 'enabled', 'disabled', or 'error:...'
            $Result.Data.RdpEnabled = ($rdpResult -eq 'enabled')
            $Result.Logs.Add("RDP state: $rdpResult -> RdpEnabled=$($Result.Data.RdpEnabled)")
        } catch {
            $rdpErr = $_.Exception.Message
            $Result.Logs.Add("RDP state check failed: $rdpErr")
        }

        try {
            $ports = Get-RdpPorts
            if ($ports -is [hashtable] -or $ports -is [PSCustomObject]) {
                $portsProps = $ports.PSObject.Properties.Name
                if ($portsProps -contains 'Ports') {
                    $portsArr = @($ports.Ports)
                    if ($portsArr.Count -gt 0) {
                        $Result.Data.RdpPort = [int]$portsArr[0]
                    }
                }
            }
        } catch {}

        # --- Eligible accounts ---
        try {
            $acctResult = Get-SrdpRdpEligibleAccounts
            if ($acctResult -is [string] -and $acctResult -like 'error:*') {
                $Result.Errors.Add("Account inventory failed: $acctResult")
            } else {
                $Result.Data.EligibleAccounts = @($acctResult.Accounts)
                $Result.Logs.Add("Found $($Result.Data.EligibleAccounts.Count) RDP-eligible account(s).")
            }
        } catch {
            $acctErr = $_.Exception.Message
            $Result.Errors.Add("Account inventory exception: $acctErr")
            try { Write-SrdpLog "ClientKeyRecon: account inventory failed: $acctErr" -Level WARN -Component 'CKW-Controller' } catch {}
        }

        # --- Address suggestions ---
        try {
            $addrResult = Get-SrdpSshAddressSuggestions
            if ($addrResult -is [string] -and $addrResult -like 'error:*') {
                $Result.Logs.Add("Address suggestions failed: $addrResult")
            } else {
                $Result.Data.AddressSuggestions = @($addrResult.Suggestions)
                $Result.Data.Hostname = $addrResult.Hostname
                $Result.Data.Fqdn     = $addrResult.Fqdn
                $Result.Logs.Add("Found $($Result.Data.AddressSuggestions.Count) address suggestion(s).")
            }
        } catch {
            $addrErr = $_.Exception.Message
            $Result.Logs.Add("Address suggestions exception: $addrErr")
        }

        $Result.Success = $true
        $Result.Status  = 'Ready'
        try { Write-SrdpLog "ClientKeyRecon: complete. Accounts=$($Result.Data.EligibleAccounts.Count) Suggestions=$($Result.Data.AddressSuggestions.Count)" -Level INFO -Component 'CKW-Controller' } catch {}

    } catch {
        $errMsg = $_.Exception.Message
        $Result.Errors.Add("Recon fatal error: $errMsg")
        $Result.Status = 'Failed'
        try { Write-SrdpLog "ClientKeyRecon fatal: $errMsg" -Level ERROR -Component 'CKW-Controller' } catch {}
    }

    return $Result
}

# =============================================================================
# GENERATION: Invoke-ClientKeyGeneration
# =============================================================================
function Invoke-ClientKeyGeneration {
    param(
        [Parameter(Mandatory)][string]$ServerAddress,
        [Parameter(Mandatory)][string]$SshUsername,
        [string]$RdpUsername = '',
        [Parameter(Mandatory)][string]$KeyLabel,
        [int]$SshPort = 22,
        [int]$RdpPort = 3389,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [scriptblock]$OnProgress = $null
    )

    $Result = [PSCustomObject]@{
        Success = $false
        Status  = 'Unknown'
        Data    = @{
            ZipPath         = $null
            PackageFileName = $null
            KeyLabel        = $KeyLabel
            SshUsername     = $SshUsername
            VerifiedFiles   = @()
        }
        Logs   = [System.Collections.Generic.List[string]]::new()
        Errors = [System.Collections.Generic.List[string]]::new()
    }

    $callerEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'

    $totalSteps = 6
    $currentStep = 0

    try {
        try { Write-SrdpLog "ClientKeyGen: starting. Address=$ServerAddress SshUsername=$SshUsername Label=$KeyLabel" -Level INFO -Component 'CKW-Controller' } catch {}

        # --- Step 1: Resolve SSH binary dir ---
        $currentStep++
        Send-CkwProgress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'ResolveBinary' -Message "Locating SSH binaries..." -OnProgress $OnProgress
        $Result.Logs.Add("Step $currentStep : Resolving SSH binary directory...")

        $modeDir = Join-Path $ProjectRoot 'Modes\SSHProto'
        $sshInfo = Get-SrdpSshInfo -ModeDir $modeDir
        $binDir  = Get-SrdpSshBinaryDir -SshInfo $sshInfo

        if ($binDir -is [string] -and $binDir -like 'error:*') {
            $Result.Errors.Add("SSH binary resolution failed: $binDir")
            Send-CkwProgress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'ResolveBinary' -Message "FAILED: $binDir" -IsWarning $true -OnProgress $OnProgress
            $Result.Status = 'Failed'
            $ErrorActionPreference = $callerEAP
            return $Result
        }

        $sshKeygenPath = Join-Path $binDir 'ssh-keygen.exe'
        Send-CkwProgress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'ResolveBinary' -Message "SSH binaries found at $binDir" -OnProgress $OnProgress
        try { Write-SrdpLog "ClientKeyGen: binDir=$binDir" -Level INFO -Component 'CKW-Controller' } catch {}

        # --- Step 2: Generate client key ---
        $currentStep++
        Send-CkwProgress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'GenerateKey' -Message "Generating SSH key pair for '$KeyLabel'..." -OnProgress $OnProgress
        $Result.Logs.Add("Step $currentStep : Generating client key '$KeyLabel'...")

        $keyResult = New-SrdpClientKey -Label $KeyLabel -SshBinaryDir $binDir
        if ($keyResult -is [string] -and $keyResult -like 'error:*') {
            $Result.Errors.Add("Key generation failed: $keyResult")
            Send-CkwProgress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'GenerateKey' -Message "FAILED: $keyResult" -IsWarning $true -OnProgress $OnProgress
            $Result.Status = 'Failed'
            $ErrorActionPreference = $callerEAP
            return $Result
        }

        Send-CkwProgress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'GenerateKey' -Message "Key pair generated." -OnProgress $OnProgress
        try { Write-SrdpLog "ClientKeyGen: key generated. Label=$KeyLabel" -Level INFO -Component 'CKW-Controller' } catch {}

        # --- Step 3: Add to authorized_keys ---
        $currentStep++
        Send-CkwProgress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'AuthorizeKey' -Message "Adding public key to authorized_keys..." -OnProgress $OnProgress
        $Result.Logs.Add("Step $currentStep : Adding to authorized_keys...")

        $authResult = Add-SrdpAuthorizedKey -PublicKeyText $keyResult.PublicKey -Label "SecureRDP-$KeyLabel"
        if ($authResult -is [string] -and $authResult -like 'error:*') {
            $Result.Errors.Add("Authorized key add failed: $authResult")
            Send-CkwProgress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'AuthorizeKey' -Message "FAILED: $authResult" -IsWarning $true -OnProgress $OnProgress
            $Result.Status = 'Failed'
            $ErrorActionPreference = $callerEAP
            return $Result
        }

        $authWarning = $null
        if ($authResult -is [hashtable] -and $authResult.ContainsKey('Warning') -and $authResult.Warning) {
            $authWarning = $authResult.Warning
            $Result.Logs.Add("Authorized key warning: $authWarning")
        }
        Send-CkwProgress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'AuthorizeKey' -Message "Public key authorized." -OnProgress $OnProgress
        try { Write-SrdpLog "ClientKeyGen: key authorized." -Level INFO -Component 'CKW-Controller' } catch {}

        # --- Step 4: Get host key info ---
        $currentStep++
        Send-CkwProgress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'HostKey' -Message "Reading server host key..." -OnProgress $OnProgress
        $Result.Logs.Add("Step $currentStep : Reading host key info...")

        $hostKeyInfo = Get-SrdpHostKeyInfo -SshKeygenPath $sshKeygenPath
        if ($hostKeyInfo -is [string] -and $hostKeyInfo -like 'error:*') {
            $Result.Errors.Add("Host key read failed: $hostKeyInfo")
            Send-CkwProgress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'HostKey' -Message "FAILED: $hostKeyInfo" -IsWarning $true -OnProgress $OnProgress
            $Result.Status = 'Failed'
            $ErrorActionPreference = $callerEAP
            return $Result
        }

        Send-CkwProgress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'HostKey' -Message "Host key read. Fingerprint: $($hostKeyInfo.Fingerprint)" -OnProgress $OnProgress
        try { Write-SrdpLog "ClientKeyGen: host key read. FP=$($hostKeyInfo.Fingerprint)" -Level INFO -Component 'CKW-Controller' } catch {}

        # --- Step 5: Build client package ---
        $currentStep++
        Send-CkwProgress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'BuildPackage' -Message "Assembling client package..." -OnProgress $OnProgress
        $Result.Logs.Add("Step $currentStep : Building client package...")

        $clientSrcDir = Join-Path $ProjectRoot 'Modes\SSHProto\QuickStart\client'
        $outputDir    = Join-Path $ProjectRoot "ClientPackages\$KeyLabel"

        $cfg = @{
            Address            = $ServerAddress
            SshPort            = $SshPort
            AdvertisedAccounts = @($SshUsername)
            SshClientPath      = $sshInfo.SshClientPath
            SshUsername        = $SshUsername
            RdpUsername        = $RdpUsername
            KeyLabel           = $KeyLabel
        }

        $certInfo = @{
            Thumbprint = ''
            DerBase64  = ''
        }

        $pkgResult = Build-SrdpClientPackage `
            -Cfg          $cfg `
            -Keys         $keyResult `
            -CertInfo     $certInfo `
            -HostKeyInfo  $hostKeyInfo `
            -RdpPort      $RdpPort `
            -OutputDir    $outputDir `
            -ClientSrcDir $clientSrcDir `
            -Passphrase   $null

        if ($pkgResult -is [string] -and $pkgResult -like 'error:*') {
            $Result.Errors.Add("Package build failed: $pkgResult")
            Send-CkwProgress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'BuildPackage' -Message "FAILED: $pkgResult" -IsWarning $true -OnProgress $OnProgress
            $Result.Status = 'Failed'
            $ErrorActionPreference = $callerEAP
            return $Result
        }

        $Result.Data.ZipPath         = $pkgResult.ZipPath
        $Result.Data.PackageFileName = $pkgResult.PackageFileName
        Send-CkwProgress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'BuildPackage' -Message "Package created: $($pkgResult.PackageFileName)" -OnProgress $OnProgress
        try { Write-SrdpLog "ClientKeyGen: package built at $($pkgResult.ZipPath)" -Level INFO -Component 'CKW-Controller' } catch {}

        # --- Step 6: Post-write verification ---
        $currentStep++
        Send-CkwProgress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'Verify' -Message "Verifying package contents..." -OnProgress $OnProgress
        $Result.Logs.Add("Step $currentStep : Verifying package...")

        $expectedFiles = @('config.json', 'known_hosts', 'client_key',
                           'Connect-SecureRDP.ps1', 'Launch.cmd', 'Connect.cmd', 'README.txt')
        $verified = [System.Collections.Generic.List[string]]::new()

        if (-not (Test-Path $pkgResult.ZipPath)) {
            $Result.Errors.Add("Package file not found after build: $($pkgResult.ZipPath)")
            Send-CkwProgress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'Verify' -Message "FAILED: Package file not found." -IsWarning $true -OnProgress $OnProgress
        } else {
            $zipSize = (Get-Item $pkgResult.ZipPath).Length
            if ($zipSize -eq 0) {
                $Result.Errors.Add("Package file is empty (0 bytes).")
                Send-CkwProgress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'Verify' -Message "WARNING: Package is empty." -IsWarning $true -OnProgress $OnProgress
            }

            try {
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $zip = [System.IO.Compression.ZipFile]::OpenRead($pkgResult.ZipPath)
                try {
                    $zipEntryNames = @($zip.Entries | ForEach-Object { $_.Name })
                    foreach ($expected in $expectedFiles) {
                        if ($zipEntryNames -contains $expected) {
                            $verified.Add($expected)
                        } else {
                            $Result.Logs.Add("Package missing expected file: $expected")
                        }
                    }
                } finally {
                    $zip.Dispose()
                }
            } catch {
                $zipErr = $_.Exception.Message
                $Result.Errors.Add("Could not read package for verification: $zipErr")
            }

            $Result.Data.VerifiedFiles = @($verified)
            $missingCount = $expectedFiles.Count - $verified.Count
            if ($missingCount -eq 0) {
                Send-CkwProgress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'Verify' -Message "All $($expectedFiles.Count) expected files verified." -OnProgress $OnProgress
            } else {
                Send-CkwProgress -CurrentStep $currentStep -TotalSteps $totalSteps -StepName 'Verify' -Message "WARNING: $missingCount expected file(s) missing from package." -IsWarning $true -OnProgress $OnProgress
            }
        }

        # --- Final status ---
        if ($Result.Errors.Count -eq 0) {
            $Result.Success = $true
            $Result.Status  = 'Created'
        } else {
            # Package may have been created with warnings
            if ($null -ne $Result.Data.ZipPath -and (Test-Path $Result.Data.ZipPath)) {
                $Result.Success = $true
                $Result.Status  = 'CreatedWithWarnings'
            } else {
                $Result.Status = 'Failed'
            }
        }

        # --- Write ClientKeys metadata to state.json ---
        # Non-fatal: a state write failure must never affect the generation result.
        if ($Result.Success) {
            Write-ClientKeyEntry `
                -ProjectRoot     $ProjectRoot `
                -KeyLabel        $KeyLabel `
                -SshUsername     $SshUsername `
                -RdpUsername     $RdpUsername `
                -ServerAddress   $ServerAddress `
                -SshPort         $SshPort `
                -RdpPort         $RdpPort `
                -PublicKeyText   $keyResult.PublicKey `
                -HostFingerprint $hostKeyInfo.Fingerprint `
                -PackageFileName $pkgResult.PackageFileName `
                -PackagePath     $pkgResult.ZipPath
        }

        try { Write-SrdpLog "ClientKeyGen complete. Status=$($Result.Status) ZipPath=$($Result.Data.ZipPath)" -Level INFO -Component 'CKW-Controller' } catch {}

    } catch {
        $errMsg = $_.Exception.Message
        $Result.Errors.Add("Client key generation fatal error: $errMsg")
        $Result.Status = 'Failed'
        try { Write-SrdpLog "ClientKeyGen fatal: $errMsg" -Level ERROR -Component 'CKW-Controller' } catch {}
    } finally {
        $ErrorActionPreference = $callerEAP
    }

    return $Result
}
