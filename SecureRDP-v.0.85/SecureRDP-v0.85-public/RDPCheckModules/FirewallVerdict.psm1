#Requires -Version 5.1
# =============================================================================
# Secure RDP v0.823 - RDPCheckModules\FirewallVerdict.psm1
# GitHub: arekfurt/SecureRDP
#
# Generic firewall verdict module.
# No RDP-specific logic. No system calls. Pure logic only.
# Takes accumulator output from FirewallAssessor.psm1 and produces the
# final worst-case verdict used to drive dashboard widget rendering.
#
# Exported functions:
#   Get-FirewallVerdict      - aggregates accumulators into a single verdict
#   Get-PortFirewallStatus   - convenience wrapper: calls all three pipeline
#                              stages (collector -> assessor -> verdict) and
#                              returns the complete result. This is the single
#                              call point for ServerWizard.ps1 and any other
#                              caller that does not need intermediate results.
#
# Import order requirement:
#   FirewallReadWriteElements.psm1 and FirewallAssessor.psm1 must be imported
#   before this module, as Get-PortFirewallStatus calls functions from both.
# =============================================================================
Set-StrictMode -Version Latest

# ===========================================================================
# Get-FirewallVerdict
#
# Aggregates the per-port per-profile accumulator array produced by
# Invoke-FirewallRuleAssessment into a single worst-case verdict.
# Only accumulators whose IsActive flag is true contribute to the verdict.
#
# Parameters:
#   Accumulators - array from Invoke-FirewallRuleAssessment, or error string
#
# Returns:
#   @{
#     Verdict          = string    # 'red'|'orange'|'yellow'|'green'|'blue'|'grey'
#     BadgeText        = string    # short human-readable label for the verdict
#     InternetVerdict  = string    # 'Any'|'Some'|'None'
#     PrivateVerdict   = string    # 'Any'|'Some'|'None'
#     LoopbackDisplay  = string    # '127.0.0.1 + ::1'|'127.0.0.1'|'::1'|'Denied'
#     MultipleProfiles = bool
#     MultiplePorts    = bool
#     ActiveProfiles   = string[]
#     Ports            = int[]
#     Accumulators     = object[]  # the full accumulator array passed in;
#                                  # callers needing per-rule detail use this
#   }
# or the original error string unchanged.
#
# Verdict levels (worst-case wins):
#   red    -- internet-routable sources have unrestricted access (Any Internet)
#   orange -- internet-routable sources have partial access (Some Internet)
#   yellow -- only private-range sources can reach the port
#   green  -- only loopback sources can reach the port
#   blue   -- no allow rules matched; port appears fully blocked
#   grey   -- no active profile found or no data
# ===========================================================================
function Get-FirewallVerdict {
    param($Accumulators)

    # Pass error strings straight through
    if ($Accumulators -is [string]) { return $Accumulators }

    $internetVerdict    = 'None'
    $privateVerdict     = 'None'
    $loopbackV4         = $false
    $loopbackV6         = $false
    $anyActive          = $false
    $activeProfileNames = [System.Collections.Generic.List[string]]::new()
    $portsSeen          = [System.Collections.Generic.List[int]]::new()

    foreach ($res in $Accumulators) {
        if (-not $res.IsActive) { continue }
        $anyActive = $true

        if ($res.ProfileName -notin $activeProfileNames) {
            $activeProfileNames.Add($res.ProfileName)
        }
        if ($res.Port -notin $portsSeen) {
            $portsSeen.Add($res.Port)
        }

        # Internet worst-case
        if ($res.InternetExposure -eq 'Any') {
            $internetVerdict = 'Any'
        } elseif ($res.InternetExposure -eq 'Some' -and $internetVerdict -ne 'Any') {
            $internetVerdict = 'Some'
        }

        # Private worst-case
        if ($res.PrivateExposure -eq 'Any') {
            $privateVerdict = 'Any'
        } elseif ($res.PrivateExposure -eq 'Some' -and $privateVerdict -ne 'Any') {
            $privateVerdict = 'Some'
        }

        # Loopback union
        if ($res.LoopbackV4) { $loopbackV4 = $true }
        if ($res.LoopbackV6) { $loopbackV6 = $true }
    }

    # Loopback display string
    $loopbackDisplay = if ($loopbackV4 -and $loopbackV6) { '127.0.0.1 + ::1' }
                       elseif ($loopbackV4)               { '127.0.0.1'       }
                       elseif ($loopbackV6)               { '::1'             }
                       else                               { 'Denied'          }

    # Final verdict (strictly ordered, worst-case wins)
    $verdict = if (-not $anyActive) {
        'grey'
    } elseif ($internetVerdict -ne 'None') {
        if ($internetVerdict -eq 'Any') { 'red' } else { 'orange' }
    } elseif ($privateVerdict -ne 'None') {
        'yellow'
    } elseif ($loopbackDisplay -ne 'Denied') {
        'green'
    } else {
        'blue'
    }

    $badgeText = switch ($verdict) {
        'red'    { 'Any Internet'  }
        'orange' { 'Some Internet' }
        'yellow' { 'Private Only'  }
        'green'  { 'Loopback Only' }
        'blue'   { 'Fully Blocked' }
        default  { 'No Profile'    }
    }

    return @{
        Verdict          = $verdict
        BadgeText        = $badgeText
        InternetVerdict  = $internetVerdict
        PrivateVerdict   = $privateVerdict
        LoopbackDisplay  = $loopbackDisplay
        MultipleProfiles = ($activeProfileNames.Count -gt 1)
        MultiplePorts    = ($portsSeen.Count -gt 1)
        ActiveProfiles   = $activeProfileNames.ToArray()
        Ports            = $portsSeen.ToArray()
        Accumulators     = $Accumulators
    }
}

# ===========================================================================
# Get-PortFirewallStatus
#
# Convenience wrapper that runs the complete three-stage firewall assessment
# pipeline for a given list of ports and returns the final verdict.
#
# This is the intended single call point for ServerWizard.ps1 and any other
# caller that wants a complete result without managing pipeline stages.
# Callers that need intermediate results (e.g. test scripts, raw address
# inspection) should call Get-FirewallRawData, Invoke-FirewallRuleAssessment,
# and Get-FirewallVerdict individually.
#
# The full accumulator array (including per-rule detail and address
# classifications) is available on the returned hashtable as .Accumulators.
#
# Parameters:
#   Ports - int[] of port numbers to assess
#
# Returns the same structure as Get-FirewallVerdict, or 'error:...' if any
# pipeline stage fails.
# ===========================================================================
function Get-PortFirewallStatus {
    param([Parameter(Mandatory)][int[]]$Ports)

    $rawData = Get-FirewallRawData
    if ($rawData -is [string]) { return $rawData }

    $accumulators = Invoke-FirewallRuleAssessment -RawData $rawData -Ports $Ports
    if ($accumulators -is [string]) { return $accumulators }

    return Get-FirewallVerdict -Accumulators $accumulators
}

Export-ModuleMember -Function @('Get-FirewallVerdict', 'Get-PortFirewallStatus')
