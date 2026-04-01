#Requires -Version 5.1
# =============================================================================
# Secure RDP v0.823 - RDPCheckModules\FirewallAssessor.psm1
# GitHub: arekfurt/SecureRDP
#
# Generic firewall rule assessment module.
# No RDP-specific logic. No system calls. Pure logic only.
# All functions are independently callable and fully unit-testable without
# a live Windows Firewall or administrator rights.
#
# Exported functions:
#   Invoke-FirewallRuleAssessment  - takes RawData from FirewallReadWriteElements
#                                    and a list of ports; returns per-port
#                                    per-profile accumulators with full rule
#                                    detail and address classifications
#
# Private functions (callable directly in tests by dot-sourcing):
#   ConvertTo-IPv4U64        - parses an IPv4 string to uint64
#   Test-IsPrivateV4         - tests whether a uint64 IPv4 is private/special
#   Test-IsLoopbackV4        - tests whether a uint64 IPv4 is loopback
#   Get-CidrMask             - parses a CIDR prefix length string
#   Get-IPv6AddressClass     - classifies a parsed IPv6 address by RFC prefix
#   Classify-AddressString   - classifies a raw firewall address string
# =============================================================================
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Private / special-use IPv4 ranges stored as uint64 pairs.
# Covers: 0.0.0.0/8, 10/8, 100.64/10 (CGNAT), 127/8 (loopback),
#         169.254/16 (APIPA), 172.16/12, 192.168/16, 198.18/15 (benchmark),
#         224+/4 (multicast/reserved).
# No hex literals used -- all values are decimal to avoid PS cast issues.
# ---------------------------------------------------------------------------
$Script:PRIV4 = @(
    @{ S = [uint64]0;          E = [uint64]16777215    }  # 0.0.0.0/8
    @{ S = [uint64]167772160;  E = [uint64]184549375   }  # 10.0.0.0/8
    @{ S = [uint64]1682800640; E = [uint64]1686110207  }  # 100.64.0.0/10 CGNAT
    @{ S = [uint64]2130706432; E = [uint64]2147483647  }  # 127.0.0.0/8 loopback
    @{ S = [uint64]2852126720; E = [uint64]2852192255  }  # 169.254.0.0/16 APIPA
    @{ S = [uint64]2886729728; E = [uint64]2887778303  }  # 172.16.0.0/12
    @{ S = [uint64]3232235520; E = [uint64]3232301055  }  # 192.168.0.0/16
    @{ S = [uint64]3322798080; E = [uint64]3322863615  }  # 198.18.0.0/15 benchmark
    @{ S = [uint64]3758096384; E = [uint64]4294967295  }  # 224.0.0.0+ multicast/reserved
)

$Script:LB4_S = [uint64]2130706432   # 127.0.0.0
$Script:LB4_E = [uint64]2147483647   # 127.255.255.255
$Script:LB4   = [uint64]2130706433   # 127.0.0.1 specifically

# Address count threshold for broad internet classification.
# IPv4 ranges covering this many addresses or more are classified as
# IsBroadInternet (-> red verdict). Below this threshold = IsSomeInternet
# (-> orange). 65536 = 2^16 = equivalent to a /16 CIDR or larger.
# Any internet-routable IPv6 address is always broad (conservative).
$Script:BROAD_INTERNET_THRESHOLD = [uint64]65536

# ===========================================================================
# PRIVATE: IP address classification helpers
# ===========================================================================

# ---------------------------------------------------------------------------
# ConvertTo-IPv4U64
# Parses an IPv4 address string to a uint64 integer for range comparisons.
# Returns null if the string is not a valid IPv4 address.
# ---------------------------------------------------------------------------
function ConvertTo-IPv4U64 {
    param([string]$IPString)
    $addr = $null
    if ([System.Net.IPAddress]::TryParse($IPString.Trim(), [ref]$addr)) {
        if ($addr.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
            $b = $addr.GetAddressBytes()
            return [uint64](
                ([uint64]$b[0] -shl 24) -bor
                ([uint64]$b[1] -shl 16) -bor
                ([uint64]$b[2] -shl 8)  -bor
                [uint64]$b[3]
            )
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Test-IsPrivateV4
# Returns $true if the uint64 IPv4 value falls within any private or
# special-use range defined in $Script:PRIV4.
# ---------------------------------------------------------------------------
function Test-IsPrivateV4 {
    param([uint64]$IP)
    foreach ($r in $Script:PRIV4) {
        if ($IP -ge $r.S -and $IP -le $r.E) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Test-IsLoopbackV4
# Returns $true if the uint64 IPv4 value falls within 127.0.0.0/8.
# ---------------------------------------------------------------------------
function Test-IsLoopbackV4 {
    param([uint64]$IP)
    return ($IP -ge $Script:LB4_S -and $IP -le $Script:LB4_E)
}

# ---------------------------------------------------------------------------
# Get-CidrMask
# Parses a CIDR prefix length string (e.g. '24') to an integer.
# Returns -1 if the string cannot be parsed.
# ---------------------------------------------------------------------------
function Get-CidrMask {
    param([string]$MaskStr)
    $m = 0
    if ([int]::TryParse($MaskStr.Trim(), [ref]$m)) { return $m }
    return -1
}

# ---------------------------------------------------------------------------
# Get-IPv6AddressClass
#
# Classifies a parsed [System.Net.IPAddress] IPv6 address by its prefix.
# Returns one of: 'any' | 'loopback6' | 'private' | 'internet'
#
# Classification rules (RFC-based):
#   ::              (unspecified, all zeros)  -> 'any'
#   ::1             (loopback)                -> 'loopback6'
#   fe80::/10       (link-local)              -> 'private'
#   fc00::/7        (ULA)                     -> 'private'
#   ff00::/8        (multicast)               -> 'private'
#   2000::/3        (global unicast)          -> 'internet'
#   everything else                           -> 'internet' (safe default;
#                                               never underreport exposure)
# ---------------------------------------------------------------------------
function Get-IPv6AddressClass {
    param([System.Net.IPAddress]$Addr)
    $b = $Addr.GetAddressBytes()   # 16 bytes, network (big-endian) order

    # :: unspecified (all bytes zero)
    $allZero = $true
    foreach ($byte in $b) { if ($byte -ne 0) { $allZero = $false; break } }
    if ($allZero) { return 'any' }

    # ::1 loopback (first 15 bytes zero, last byte 1)
    $isLB6 = $true
    for ($i = 0; $i -lt 15; $i++) { if ($b[$i] -ne 0) { $isLB6 = $false; break } }
    if ($isLB6 -and $b[15] -eq 1) { return 'loopback6' }

    # fe80::/10 link-local (first byte 0xFE, top 2 bits of second byte == 10b)
    if ($b[0] -eq 254 -and ($b[1] -band 192) -eq 128) { return 'private' }

    # fc00::/7 ULA (top 7 bits of first byte == 1111110b)
    if (($b[0] -band 254) -eq 252) { return 'private' }

    # ff00::/8 multicast
    if ($b[0] -eq 255) { return 'private' }

    # 2000::/3 global unicast (top 3 bits of first byte == 001b)
    if (($b[0] -band 224) -eq 32) { return 'internet' }

    # Safe default: treat as internet -- do not underreport exposure
    return 'internet'
}

# ---------------------------------------------------------------------------
# Get-IPv4RangeAddressCount
# Returns the number of IPv4 addresses covered by a start/end uint64 pair.
# Capped at uint64 max to avoid overflow on 0.0.0.0/0 style ranges.
# ---------------------------------------------------------------------------
function Get-IPv4RangeAddressCount {
    param([uint64]$Start, [uint64]$End)
    if ($End -lt $Start) { return [uint64]0 }
    # Add 1 for inclusive range; cap at threshold*2 to avoid giant numbers
    $diff = $End - $Start
    if ($diff -ge [uint64]4294967295) { return [uint64]4294967296 }
    return $diff + [uint64]1
}

# ---------------------------------------------------------------------------
# Classify-AddressString
#
# Classifies a single RemoteAddress string as Windows Firewall presents it.
# Handles: 'Any'/'*', single IPv4, single IPv6, IPv4 CIDR, IPv6 CIDR,
#          IPv4 range, IPv6 range. Unknown formats default to internet
#          exposure (safe default -- do not underreport).
#
# Returns:
#   @{
#     IsAny       = bool  -- literally any source (includes all sub-flags)
#     IsInternet  = bool  -- at least one internet-routable address is covered
#     IsPrivate   = bool  -- at least one private/special-use address is covered
#     IsLoopback4 = bool  -- 127.x.x.x is covered
#     IsLoopback6 = bool  -- ::1 is covered
#     Ambiguous   = bool  -- could not fully classify; treated as internet
#   }
# ---------------------------------------------------------------------------
function Classify-AddressString {
    param([string]$AddrStr)

    $result = @{
        IsAny           = $false
        IsInternet      = $false
        IsBroadInternet = $false   # true when internet range covers >= BROAD_INTERNET_THRESHOLD
        IsPrivate       = $false
        IsLoopback4     = $false
        IsLoopback6     = $false
        Ambiguous       = $false
    }

    $s = $AddrStr.Trim()

    # ---- Literal Any / wildcard -------------------------------------------
    if ($s -eq 'Any' -or $s -eq '*') {
        $result.IsAny           = $true
        $result.IsInternet      = $true
        $result.IsBroadInternet = $true
        $result.IsPrivate       = $true
        $result.IsLoopback4     = $true
        $result.IsLoopback6     = $true
        return $result
    }

    # ---- Single IPv6 address (must check before range: colons before dash) -
    $addr6 = $null
    if ([System.Net.IPAddress]::TryParse($s, [ref]$addr6)) {
        if ($addr6.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
            $cls6 = Get-IPv6AddressClass $addr6
            switch ($cls6) {
                'any'       {
                    $result.IsAny       = $true
                    $result.IsInternet  = $true
                    $result.IsPrivate   = $true
                    $result.IsLoopback4 = $true
                    $result.IsLoopback6 = $true
                }
                'loopback6' { $result.IsLoopback6 = $true }
                'private'   { $result.IsPrivate   = $true }
                'internet'  { $result.IsInternet = $true; $result.IsBroadInternet = $true }
            }
            return $result
        }
    }

    # ---- CIDR notation: 192.168.1.0/24 or fe80::/10 ----------------------
    if ($s.Contains('/')) {
        $parts = $s -split '/'
        if ($parts.Count -eq 2) {
            # IPv4 CIDR
            $ip   = ConvertTo-IPv4U64 $parts[0]
            $mask = Get-CidrMask $parts[1]
            if ($null -ne $ip -and $mask -ge 0 -and $mask -le 32) {
                if ($mask -eq 0) {
                    # 0.0.0.0/0 = everything
                    $result.IsAny           = $true
                    $result.IsInternet      = $true
                    $result.IsBroadInternet = $true
                    $result.IsPrivate       = $true
                    $result.IsLoopback4     = $true
                    $result.IsLoopback6     = $true
                    return $result
                }
                $isLB   = Test-IsLoopbackV4 $ip
                $isPriv = Test-IsPrivateV4  $ip
                if ($isLB) {
                    $result.IsLoopback4 = $true
                } elseif ($isPriv) {
                    $result.IsPrivate = $true
                } else {
                    $result.IsInternet = $true
                    # Compute number of addresses in this CIDR.
                    # mask=16 -> 65536 addresses (threshold); mask<16 -> broader -> broad.
                    $cidrCount = [uint64]([Math]::Pow(2, (32 - $mask)))
                    if ($cidrCount -ge $Script:BROAD_INTERNET_THRESHOLD) {
                        $result.IsBroadInternet = $true
                    }
                }
                return $result
            }
            # IPv6 CIDR -- classify by network address prefix
            $addr6Cidr = $null
            if ([System.Net.IPAddress]::TryParse($parts[0].Trim(), [ref]$addr6Cidr)) {
                if ($addr6Cidr.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
                    $cls6 = Get-IPv6AddressClass $addr6Cidr
                    switch ($cls6) {
                        'any'       {
                            $result.IsAny           = $true
                            $result.IsInternet      = $true
                            $result.IsBroadInternet = $true
                            $result.IsPrivate       = $true
                            $result.IsLoopback4     = $true
                            $result.IsLoopback6     = $true
                        }
                        'loopback6' { $result.IsLoopback6 = $true }
                        'private'   { $result.IsPrivate   = $true }
                        'internet'  { $result.IsInternet = $true; $result.IsBroadInternet = $true }
                    }
                    return $result
                }
            }
        }
        # Unparseable CIDR -- safe default
        $result.Ambiguous       = $true
        $result.IsInternet      = $true
        $result.IsBroadInternet = $true
        return $result
    }

    # ---- Range notation: 10.0.0.1-10.0.0.254 or fe80::1-fe80::ffff -------
    if ($s.Contains('-')) {
        $parts = $s -split '-'
        if ($parts.Count -eq 2) {
            # IPv4 range
            $ip1 = ConvertTo-IPv4U64 $parts[0]
            $ip2 = ConvertTo-IPv4U64 $parts[1]
            if ($null -ne $ip1 -and $null -ne $ip2) {
                $lo = [Math]::Min($ip1, $ip2)
                $hi = [Math]::Max($ip1, $ip2)
                $loLB   = Test-IsLoopbackV4 $lo
                $hiLB   = Test-IsLoopbackV4 $hi
                $loPriv = Test-IsPrivateV4  $lo
                $hiPriv = Test-IsPrivateV4  $hi
                if ($loLB -and $hiLB) {
                    $result.IsLoopback4 = $true
                } elseif ($loPriv -and $hiPriv) {
                    $result.IsPrivate = $true
                    # Check whether the loopback range (127.x) is spanned
                    if ($lo -le $Script:LB4 -and $hi -ge $Script:LB4) {
                        $result.IsLoopback4 = $true
                    }
                } elseif (-not $loPriv -or -not $hiPriv) {
                    # Range spans or touches internet space
                    $result.IsInternet = $true
                    if ($loPriv -or $hiPriv) { $result.IsPrivate = $true }
                    # Broad if range covers >= threshold addresses
                    $rangeCount = Get-IPv4RangeAddressCount -Start $lo -End $hi
                    if ($rangeCount -ge $Script:BROAD_INTERNET_THRESHOLD) {
                        $result.IsBroadInternet = $true
                    }
                } else {
                    $result.Ambiguous       = $true
                    $result.IsInternet      = $true
                    $result.IsBroadInternet = $true
                }
                return $result
            }
            # IPv6 range -- classify both endpoints, take worst case
            $addr6a = $null
            $addr6b = $null
            $aOk = [System.Net.IPAddress]::TryParse($parts[0].Trim(), [ref]$addr6a)
            $bOk = [System.Net.IPAddress]::TryParse($parts[1].Trim(), [ref]$addr6b)
            if ($aOk -and $bOk -and
                $addr6a.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6 -and
                $addr6b.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
                foreach ($ep in @($addr6a, $addr6b)) {
                    $cls6 = Get-IPv6AddressClass $ep
                    switch ($cls6) {
                        'any'       {
                            $result.IsAny       = $true
                            $result.IsInternet  = $true
                            $result.IsPrivate   = $true
                            $result.IsLoopback4 = $true
                            $result.IsLoopback6 = $true
                        }
                        'loopback6' { $result.IsLoopback6 = $true }
                        'private'   { $result.IsPrivate   = $true }
                        'internet'  { $result.IsInternet = $true; $result.IsBroadInternet = $true }
                    }
                }
                return $result
            }
        }
        # Unparseable range -- safe default
        $result.Ambiguous       = $true
        $result.IsInternet      = $true
        $result.IsBroadInternet = $true
        return $result
    }

    # ---- Single IPv4 address ----------------------------------------------
    $ip = ConvertTo-IPv4U64 $s
    if ($null -ne $ip) {
        if (Test-IsLoopbackV4 $ip) {
            $result.IsLoopback4 = $true
        } elseif (Test-IsPrivateV4 $ip) {
            $result.IsPrivate = $true
        } else {
            # Single internet IPv4 address -- specific, not broad (stays orange)
            $result.IsInternet = $true
            # IsBroadInternet remains $false
        }
        return $result
    }

    # ---- Windows Firewall special keywords ----------------------------------
    # These keywords appear as RemoteAddress values in Windows Firewall rules.
    # Must be handled before the unrecognised fallback to avoid false positives.
    $sLower = $s.ToLower()
    switch ($sLower) {
        'localsubnet'   { $result.IsPrivate = $true; return $result }
        'defaultgateway'{ $result.IsPrivate = $true; return $result }
        'dns'           { $result.IsPrivate = $true; return $result }
        'wins'          { $result.IsPrivate = $true; return $result }
        'dhcp'          { $result.IsPrivate = $true; return $result }
        'intranet'      { $result.IsPrivate = $true; return $result }
        'rmtintranet'   { $result.IsPrivate = $true; return $result }
        'internet'      { $result.IsInternet = $true; $result.IsBroadInternet = $true; return $result }
    }

    # ---- Unrecognised format -- safe default (do not underreport exposure) --
    $result.Ambiguous       = $true
    $result.IsInternet      = $true
    $result.IsBroadInternet = $true
    return $result
}

# ===========================================================================
# Invoke-FirewallRuleAssessment
#
# Takes RawData from Get-FirewallRawData and a list of ports.
# Matches enabled inbound rules to each port and active profile, classifies
# every remote address string, and accumulates worst-case exposure.
#
# Both Allow and Block rules that match a port/profile are recorded in
# MatchedRules. Only Allow rules contribute to exposure accumulation.
# Block rules are recorded with WasSkipped = $true.
#
# NOTE: Once a port/profile accumulator reaches 'Any' internet exposure it
# stops processing further rules for that combination (worst case reached).
# MatchedRules may therefore be incomplete for worst-case accumulators --
# rules after the break point are not recorded.
#
# Parameters:
#   RawData  - hashtable from Get-FirewallRawData, or error string (passed through)
#   Ports    - int[] of port numbers to assess
#
# Returns array of accumulators, one per port per profile (9 total for 3 ports):
#   @{
#     Port             = int
#     ProfileName      = string          # 'Domain' | 'Private' | 'Public'
#     IsActive         = bool
#     InternetExposure = string          # 'None' | 'Some' | 'Any'
#     PrivateExposure  = string          # 'None' | 'Some' | 'Any'
#     LoopbackV4       = bool
#     LoopbackV6       = bool
#     MatchedRules     = object[]        # see below
#   }
#
# Each MatchedRules entry:
#   @{
#     RuleName        = string           # InstanceID
#     DisplayName     = string
#     Action          = string           # 'Allow' | 'Block'
#     WasSkipped      = bool             # true for Block rules
#     EdgeTraversal   = string
#     RemoteAddresses = string[]         # raw address strings from firewall
#     Classifications = object[]         # one per address, see Classify-AddressString
#   }
#
# or 'error:...' if RawData is an error string or processing fails.
# ===========================================================================
function Invoke-FirewallRuleAssessment {
    param(
        [Parameter(Mandatory)]$RawData,
        [Parameter(Mandatory)][int[]]$Ports
    )

    # Pass error strings straight through
    if ($RawData -is [string]) { return $RawData }

    try {
        $activeProfiles = $RawData.ActiveProfiles
        $rules          = $RawData.Rules
        $pFilters       = $RawData.PortFilters
        $aFilters       = $RawData.AddressFilters

        $results = [System.Collections.Generic.List[object]]::new()

        foreach ($profileName in @('Domain', 'Private', 'Public')) {
            $localProfileName = $profileName
            $isActive         = ($localProfileName -in $activeProfiles)

            foreach ($port in $Ports) {
                $localPort   = $port
                $matchedRules = [System.Collections.Generic.List[object]]::new()

                $acc = @{
                    Port             = $localPort
                    ProfileName      = $localProfileName
                    IsActive         = $isActive
                    InternetExposure = 'None'
                    PrivateExposure  = 'None'
                    LoopbackV4       = $false
                    LoopbackV6       = $false
                    MatchedRules     = $matchedRules
                }

                foreach ($r in $rules) {
                    # --- Action ---
                    $actionStr = ''
                    try { $actionStr = $r.Action.ToString() } catch { continue }

                    # --- Profile match ---
                    # Profile is a bitmask: 1=Domain, 2=Private, 4=Public.
                    # 0 and MaxInt both mean 'Any profile'.
                    $pVal = 0
                    try { $pVal = [int]$r.Profile } catch { $pVal = 2147483647 }
                    $profileMatch = $false
                    if ($pVal -eq 0 -or $pVal -eq 2147483647) {
                        $profileMatch = $true
                    } else {
                        $profileMatch = switch ($localProfileName) {
                            'Domain'  { ($pVal -band 1) -ne 0 }
                            'Private' { ($pVal -band 2) -ne 0 }
                            'Public'  { ($pVal -band 4) -ne 0 }
                            default   { $false }
                        }
                    }
                    if (-not $profileMatch) { continue }

                    # --- Port match ---
                    # LocalPort from Get-NetFirewallPortFilter is a string array.
                    # Use -contains for correct array membership check.
                    $pf = $pFilters[$r.InstanceID]
                    if ($null -eq $pf) { continue }
                    $localPorts = @($pf.LocalPort)
                    $portMatch = ($localPorts -contains 'Any') -or ($localPorts -contains $localPort.ToString())
                    if (-not $portMatch) { continue }

                    # --- Edge traversal ---
                    $edgeTraversal = 'Block'
                    try { $edgeTraversal = $r.EdgeTraversalPolicy.ToString() } catch {}

                    # --- Remote addresses ---
                    $af = $aFilters[$r.InstanceID]
                    $rawAddresses = @()
                    if ($null -ne $af) {
                        $rawAddresses = @(
                            @($af.RemoteAddress) |
                            Where-Object { $null -ne $_ } |
                            ForEach-Object { $_.ToString() }
                        )
                    }

                    # --- Classify each address ---
                    $classifications = [System.Collections.Generic.List[object]]::new()
                    foreach ($addrStr in $rawAddresses) {
                        $cls = Classify-AddressString $addrStr
                        $classifications.Add(@{
                            Address         = $addrStr
                            IsAny           = $cls.IsAny
                            IsInternet      = $cls.IsInternet
                            IsBroadInternet = $cls.IsBroadInternet
                            IsPrivate       = $cls.IsPrivate
                            IsLoopback4     = $cls.IsLoopback4
                            IsLoopback6     = $cls.IsLoopback6
                            Ambiguous       = $cls.Ambiguous
                        })
                    }

                    # --- Record matched rule (Allow and Block) ---
                    $isBlock = ($actionStr -eq 'Block')
                    $matchedRules.Add(@{
                        RuleName        = $r.InstanceID
                        DisplayName     = $r.DisplayName
                        Action          = $actionStr
                        WasSkipped      = $isBlock
                        EdgeTraversal   = $edgeTraversal
                        RemoteAddresses = $rawAddresses
                        Classifications = $classifications.ToArray()
                    })

                    # Block rules do not contribute to exposure -- stop here
                    if ($isBlock) { continue }

                    # --- Edge traversal: immediate worst case ---------------
                    $edgeAny = ($edgeTraversal -ne 'Block' -and
                                $edgeTraversal -ne 'DeferToApp' -and
                                $edgeTraversal -ne 'DeferToUser')
                    if ($edgeAny) {
                        $acc.InternetExposure = 'Any'
                        $acc.PrivateExposure  = 'Any'
                        $acc.LoopbackV4       = $true
                        $acc.LoopbackV6       = $true
                        break   # worst case for this port+profile -- stop iterating rules
                    }

                    # --- Accumulate exposure from address classifications ---
                    # IsBroadInternet -> 'Any' (red): covers >= BROAD_INTERNET_THRESHOLD
                    # IsInternet only  -> 'Some' (orange): small/specific range
                    foreach ($cls in $classifications) {
                        if ($cls.IsAny -or $cls.Ambiguous -or $cls.IsBroadInternet) {
                            $acc.InternetExposure = 'Any'
                            $acc.PrivateExposure  = 'Any'
                        } elseif ($cls.IsInternet -and $acc.InternetExposure -ne 'Any') {
                            $acc.InternetExposure = 'Some'
                        }

                        if ($cls.IsPrivate -and $acc.PrivateExposure -ne 'Any') {
                            $acc.PrivateExposure = 'Some'
                        }

                        if ($cls.IsLoopback4) { $acc.LoopbackV4 = $true }
                        if ($cls.IsLoopback6) { $acc.LoopbackV6 = $true }
                    }

                    # Short-circuit: worst case reached for this port+profile
                    if ($acc.InternetExposure -eq 'Any') { break }
                }

                $results.Add($acc)
            }
        }

        return $results.ToArray()
    }
    catch {
        return "error:$($_.Exception.Message)"
    }
}

Export-ModuleMember -Function @('Invoke-FirewallRuleAssessment')
