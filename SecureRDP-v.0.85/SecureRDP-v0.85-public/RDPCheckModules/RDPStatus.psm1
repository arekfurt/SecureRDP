# =============================================================================
# Secure RDP v0.821 - RDPCheckModules\RDPStatus.psm1
# GitHub: arekfurt/SecureRDP
#
# Pure logic module. No UI. Returns structured results to ServerWizard.ps1.
#
# Functions:
#   Confirm-StringResult    - validates any function return value is a safe string
#   Test-RdpEnabled         - checks global RDP enabled state + TermService
#   Test-NlaEnabled         - checks NLA requirement at registry
#   Get-RdpPorts            - enumerates all RDP listener ports and port proxies
#   Get-RdpCertificate      - retrieves and parses assigned RDP server certificate
#   Get-RdpIpsecStatus      - checks whether RDP ports are behind an IPsec policy
# =============================================================================
Set-StrictMode -Version Latest

# =============================================================================
# Confirm-StringResult
#
# Validates that a value returned by any check function is a non-null,
# non-empty string before the wizard attempts to use it in display logic.
# Prevents type errors propagating into the UI if a function returns
# $null, an object, or throws silently.
#
# Parameters:
#   $Value  - the value to validate
#
# Returns: the original value if valid, 'error:unexpected' otherwise
# =============================================================================
function Confirm-StringResult {
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()]
        $Value
    )
    if ($null -eq $Value)                    { return 'error:unexpected' }
    if ($Value -isnot [string])              { return 'error:unexpected' }
    if ([string]::IsNullOrWhiteSpace($Value)){ return 'error:unexpected' }
    return $Value
}

# =============================================================================
# Test-RdpEnabled
#
# Checks whether RDP is enabled on this machine by examining:
#   1. The global fDenyTSConnections registry value
#   2. The running state of the TermService Windows service
#
# Decision tree:
#   Reg key present:
#     Key=0, service running   -> 'enabled'
#     Key=0, service not running -> 'error:regTSmismatch'  (allowed but service down)
#     Key=1, service stopped   -> 'disabled'
#     Key=1, service running   -> 'error:regTSmismatch'   (denied but service up)
#   Reg key missing:
#     Service not running      -> 'error:regKeyMissing'
#     Service running          -> 'error:regKeyMissing2'  (no key but service is up)
#   Any unhandled exception    -> 'error:unexpected'
#
# Returns: 'enabled' | 'disabled' |
#          'error:regKeyMissing' | 'error:regKeyMissing2' |
#          'error:regTSmismatch' | 'error:unexpected'
# =============================================================================
function Test-RdpEnabled {
    try {
        $tsPath   = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
        $valueName = 'fDenyTSConnections'

        # Check TermService state - needed in all branches
        $svc = Get-Service -Name TermService -ErrorAction Stop
        $svcRunning = ($svc.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running)

        # Check registry key presence
        $tsKey = Get-Item -Path $tsPath -ErrorAction Stop
        $rawValue = $tsKey.GetValue($valueName, $null)

        if ($null -eq $rawValue) {
            # Key path exists but value is absent
            if ($svcRunning) { return 'error:regKeyMissing2' }
            return 'error:regKeyMissing'
        }

        # Validate value is an integer type before casting
        $denyValue = $null
        if (-not [int]::TryParse($rawValue.ToString(), [ref]$denyValue)) {
            return 'error:unexpected'
        }

        if ($denyValue -eq 0) {
            # Registry says RDP allowed
            if ($svcRunning) { return 'enabled' }
            return 'error:regTSmismatch'
        }
        elseif ($denyValue -eq 1) {
            # Registry says RDP denied
            if (-not $svcRunning) { return 'disabled' }
            return 'error:regTSmismatch'
        }
        else {
            # Unexpected value in registry
            return 'error:unexpected'
        }
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        # Registry path itself is missing - still check TermService
        try {
            $svc = Get-Service -Name TermService -ErrorAction Stop
            if ($svc.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
                return 'error:regKeyMissing2'
            }
            return 'error:regKeyMissing'
        }
        catch {
            return 'error:regKeyMissing'
        }
    }
    catch {
        return 'error:unexpected'
    }
}

# =============================================================================
# Test-NlaEnabled
#
# Checks whether Network Level Authentication is required for RDP connections
# by reading the UserAuthentication value from the RDP-Tcp WinStation registry
# key. Registry only - no WMI.
#
# Registry path:
#   HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\
#     WinStations\RDP-Tcp
#   Value: UserAuthentication
#     1 = NLA required
#     0 = NLA not required
#
# Returns: 'required' | 'notrequired' |
#          'error:regKeyMissing' | 'error:unexpected'
# =============================================================================
function Test-NlaEnabled {
    try {
        $nlaPath   = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
        $valueName = 'UserAuthentication'

        $wsKey = Get-Item -Path $nlaPath -ErrorAction Stop
        $rawValue = $wsKey.GetValue($valueName, $null)

        if ($null -eq $rawValue) {
            return 'error:regKeyMissing'
        }

        $nlaValue = $null
        if (-not [int]::TryParse($rawValue.ToString(), [ref]$nlaValue)) {
            return 'error:unexpected'
        }

        if ($nlaValue -eq 1) { return 'required'    }
        if ($nlaValue -eq 0) { return 'notrequired' }
        return 'error:unexpected'
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        return 'error:regKeyMissing'
    }
    catch {
        return 'error:unexpected'
    }
}

# =============================================================================
# Get-RdpPorts
#
# Enumerates all configured RDP listener ports on this machine by:
#   1. Scanning all WinStation registry entries for PortNumber values
#   2. Scanning Windows PortProxy rules that forward to any discovered RDP port
#
# Only WinStations with a PortNumber value present are included.
# PdClass -eq 2 indicates RDP protocol.
#
# PortProxy comparison uses explicit [int] cast to avoid type mismatch
# between integer registry values and string split results.
#
# Returns hashtable on success:
#   @{
#     Result   = 'ok'
#     Ports    = [int[]]        # all RDP listener port numbers
#     Stations = [PSCustomObject[]]  # WinStation detail
#     Proxies  = [PSCustomObject[]]  # PortProxy entries forwarding to RDP ports
#   }
#
# Returns: 'error:noWinStations' | 'error:unexpected'
# =============================================================================
function Get-RdpPorts {
    try {
        $tsPath       = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
        $wsBasePath   = "$tsPath\WinStations"
        $proxyBase    = 'HKLM:\SYSTEM\CurrentControlSet\Services\PortProxy'
        $proxyProtos  = @('v4tov4','v4tov6','v6tov4','v6tov6')

        $stations  = [System.Collections.Generic.List[PSCustomObject]]::new()
        $proxies   = [System.Collections.Generic.List[PSCustomObject]]::new()
        $rdpPorts  = [System.Collections.Generic.List[int]]::new()

        # --- 1. WinStation enumeration ---
        $wsKeys = Get-ChildItem -Path $wsBasePath -ErrorAction Stop

        foreach ($ws in $wsKeys) {
            try {
                $props = Get-ItemProperty -Path $ws.PSPath -ErrorAction Stop

                # Skip WinStations with no port number - not network listeners
                if ($null -eq $props.PortNumber) { continue }

                $portNum = $null
                if (-not [int]::TryParse($props.PortNumber.ToString(), [ref]$portNum)) {
                    continue  # Unparseable port - skip this station
                }

                # Validate port is in valid range
                if ($portNum -lt 1 -or $portNum -gt 65535) { continue }

                $isRdpProtocol = ($null -ne $props.PdClass -and $props.PdClass -eq 2)
                $isEnabled     = ($null -ne $props.fEnableWinStation -and
                                  $props.fEnableWinStation -eq 1)

                $rdpPorts.Add($portNum)

                $stations.Add([PSCustomObject]@{
                    Name       = $ws.PSChildName
                    Port       = $portNum
                    IsRdp      = $isRdpProtocol
                    IsEnabled  = $isEnabled
                })
            }
            catch {
                # Skip individual WinStation read failures - continue enumeration
                continue
            }
        }

        if ($stations.Count -eq 0) {
            return 'error:noWinStations'
        }

        # --- 2. PortProxy enumeration ---
        foreach ($proto in $proxyProtos) {
            $proxyPath = "$proxyBase\$proto\tcp"
            if (-not (Test-Path $proxyPath)) { continue }

            try {
                $proxyKey = Get-Item -Path $proxyPath -ErrorAction Stop

                foreach ($propName in $proxyKey.Property) {
                    try {
                        $targetRaw  = (Get-ItemProperty -Path $proxyPath `
                            -Name $propName -ErrorAction Stop).$propName

                        # Property name format: "ListenAddress/Port" or just port
                        # Value format: "ConnectAddress/Port"
                        $listenPort  = $null
                        $connectPort = $null

                        $listenStr  = ($propName  -split '[:/]')[-1]
                        $connectStr = ($targetRaw -split '[:/]')[-1]

                        if (-not [int]::TryParse($listenStr,  [ref]$listenPort))  { continue }
                        if (-not [int]::TryParse($connectStr, [ref]$connectPort)) { continue }

                        # Only include proxies forwarding to known RDP ports
                        # Explicit [int] comparison - avoids string/int type mismatch
                        if (-not $rdpPorts.Contains([int]$connectPort)) { continue }

                        $proxies.Add([PSCustomObject]@{
                            Protocol    = $proto
                            ListenPort  = $listenPort
                            ConnectPort = $connectPort
                            Target      = $targetRaw
                        })
                    }
                    catch { continue }
                }
            }
            catch { continue }
        }

        return @{
            Result   = 'ok'
            Ports    = $rdpPorts.ToArray()
            Stations = $stations.ToArray()
            Proxies  = $proxies.ToArray()
        }
    }
    catch {
        return 'error:unexpected'
    }
}

# =============================================================================
# Get-RdpCertificate
#
# Retrieves the certificate currently assigned to the RDP listener using
# WMI Win32_TSGeneralSetting to get the configured thumbprint, then locates
# the certificate in the local machine certificate store.
#
# Uses native X509Certificate2 properties - no raw DER/PEM parsing.
# IsSelfSigned is determined by comparing Subject and Issuer distinguished names.
#
# Returns hashtable on success:
#   @{
#     Thumbprint      = [string]
#     Subject         = [string]
#     Issuer          = [string]
#     IsSelfSigned    = [bool]
#     NotBefore       = [DateTime]
#     NotAfter        = [DateTime]
#     DaysUntilExpiry = [int]      # negative if already expired
#     KeyAlgorithm    = [string]
#     KeySize         = [int]
#     SerialNumber    = [string]
#   }
#
# Returns: 'error:noThumbprintConfigured' | 'error:certNotInStore' |
#          'error:wmiUnavailable'         | 'error:unexpected'
# =============================================================================
function Get-RdpCertificate {
    try {
        # --- Get thumbprint from WMI ---
        $wmiObj = $null
        try {
            $wmiObj = Get-CimInstance -ClassName Win32_TSGeneralSetting `
                -Namespace 'root\cimv2\terminalservices' `
                -Filter "TerminalName='RDP-Tcp'" `
                -ErrorAction Stop
        }
        catch {
            return 'error:wmiUnavailable'
        }

        if ($null -eq $wmiObj) {
            return 'error:wmiUnavailable'
        }

        $thumbprint = $wmiObj.SSLCertificateSHA1Hash

        # Empty or whitespace thumbprint means no cert is configured
        if ([string]::IsNullOrWhiteSpace($thumbprint)) {
            return 'error:noThumbprintConfigured'
        }

        # Sanitise thumbprint - strip spaces and normalise to uppercase
        # Only allow hex characters after sanitisation
        $thumbprint = $thumbprint.Trim().Replace(' ','').ToUpper()
        if ($thumbprint -notmatch '^[0-9A-F]{40}$') {
            # Not a valid SHA1 thumbprint format
            return 'error:unexpected'
        }

        # --- Locate cert by searching all stores where Windows may place RDP certs ---
        # Windows places auto-generated RDP certs in 'Remote Desktop' store, not 'My'.
        # Manually installed or CA-signed certs are typically in 'My'.
        # We search both to ensure we never miss an existing cert.
        $cert       = $null
        $certSource = $null
        $storeNames = @('My', 'Remote Desktop')
        foreach ($storeName in $storeNames) {
            $certStore = $null
            try {
                $certStore = New-Object System.Security.Cryptography.X509Certificates.X509Store(
                    $storeName,
                    [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
                )
                $certStore.Open(
                    [System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly
                )
                $found = $certStore.Certificates.Find(
                    [System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
                    $thumbprint,
                    $false  # do not require valid chain
                )
                if ($found.Count -gt 0) {
                    $cert       = $found[0]
                    $certSource = $storeName
                    break
                }
            } catch {
                # Store may not exist on all Windows SKUs -- continue to next
            } finally {
                if ($null -ne $certStore) { $certStore.Close() }
            }
        }

        if ($null -eq $cert) {
            return 'error:certNotInStore'
        }

        # --- Extract fields using native X509Certificate2 properties ---
        $now            = Get-Date
        $daysUntilExpiry = [int][Math]::Floor(($cert.NotAfter - $now).TotalDays)

        # IsSelfSigned: issuer and subject distinguished names are identical
        $isSelfSigned = ($cert.Subject -eq $cert.Issuer)

        # Key algorithm and size from public key
        $keyAlgorithm = 'Unknown'
        $keySize      = 0
        try {
            $keyAlgorithm = $cert.PublicKey.Oid.FriendlyName
            $keySize      = $cert.PublicKey.Key.KeySize
        }
        catch {
            # Non-critical - leave as defaults if unavailable
        }

        return @{
            Thumbprint      = $cert.Thumbprint
            CertStore       = $certSource
            Subject         = $cert.Subject
            Issuer          = $cert.Issuer
            IsSelfSigned    = $isSelfSigned
            NotBefore       = $cert.NotBefore
            NotAfter        = $cert.NotAfter
            DaysUntilExpiry = $daysUntilExpiry
            KeyAlgorithm    = $keyAlgorithm
            KeySize         = $keySize
            SerialNumber    = $cert.SerialNumber
        }
    }
    catch {
        return 'error:unexpected'
    }
}


Export-ModuleMember -Function @(
    'Confirm-StringResult'
    'Test-RdpEnabled'
    'Test-NlaEnabled'
    'Get-RdpPorts'
    'Get-RdpCertificate'
)
