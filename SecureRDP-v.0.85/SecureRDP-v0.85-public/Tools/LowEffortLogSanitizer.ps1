#Requires -Version 5.1
# =============================================================================
# SecureRDP -- Low Effort Log Sanitizer
# Tools\LowEffortLogSanitizer.ps1
#
# Scans *.log files in the same directory as this script, applies best-effort
# redaction of identifiable information, and writes screened copies to
# Tools\partlysanitized\.
#
# What it replaces:
#   - Usernames (from paths, log fields, qualified account names)
#   - Computer names (from log fields and qualified account names)
#   - Private IPv4 addresses  -> [PRIVATE-IP]
#   - Public IPv4 addresses   -> [EXTERNAL-IP]
#   - Windows SIDs            -> [WINDOWS-SID]
#   - SSH public key bodies   -> [SSH-PUBLIC-KEY]
#   - Key labels              -> [Key Label-<digits>] or [Key Label]
#
# What it does NOT reliably replace:
#   - Hostnames and domain names in freeform SSH debug output
#   - Custom labels or names embedded in error message text
#   - IPv6 addresses
#
# Review output files before submitting.
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$OutputDir  = Join-Path $ScriptDir 'partlysanitized'

# =============================================================================
# HELPERS
# =============================================================================

function Get-IpCategory {
    param([string]$Ip)
    try {
        $parts = $Ip -split '\.'
        if ($parts.Count -ne 4) { return 'other' }
        $a = [int]$parts[0]; $b = [int]$parts[1]
        if ($a -eq 127)                              { return 'loopback' }
        if ($a -eq 10)                               { return 'private'  }
        if ($a -eq 172 -and $b -ge 16 -and $b -le 31) { return 'private' }
        if ($a -eq 192 -and $b -eq 168)              { return 'private'  }
        if ($a -eq 169 -and $b -eq 254)              { return 'loopback' }
        return 'external'
    } catch { return 'other' }
}

function Redact-KeyLabel {
    param([string]$Label)
    $digits = ($Label -replace '[^0-9]', '')
    if ($digits.Length -gt 0) { return "[Key Label-$digits]" }
    return '[Key Label]'
}

function Sanitize-Log {
    param(
        [string]$InputPath,
        [string]$OutputPath
    )

    $lines = @(Get-Content -LiteralPath $InputPath -Encoding UTF8 -ErrorAction Stop)
    $allText = $lines -join "`n"

    # -------------------------------------------------------------------------
    # EXTRACTION PASS -- build replacement table before touching any text
    # -------------------------------------------------------------------------

    # Track unique values -> replacement tag
    $replacements = [System.Collections.Generic.List[hashtable]]::new()

    # Helper: add a replacement if value is non-empty and not already tracked
    $addReplacement = {
        param([string]$Raw, [string]$Tag)
        if ([string]::IsNullOrWhiteSpace($Raw)) { return }
        $Raw = $Raw.Trim()
        foreach ($r in $replacements) { if ($r.Raw -eq $Raw) { return } }
        $replacements.Add(@{ Raw = $Raw; Tag = $Tag }) | Out-Null
    }

    # -- Computer names --
    $computerNames = [System.Collections.Generic.List[string]]::new()

    # From "ComputerName: X" or "ComputerName=X"
    foreach ($m in [regex]::Matches($allText, '(?i)ComputerName[=:]\s*([A-Za-z0-9_\-]+)')) {
        $v = $m.Groups[1].Value
        if ($v -notin $computerNames) { $computerNames.Add($v) | Out-Null }
    }
    # From "generatedBy":"MACHINE\user" and "MACHINE\user" patterns
    foreach ($m in [regex]::Matches($allText, '([A-Za-z0-9_\-]+)\\[A-Za-z0-9_\-]+')) {
        $v = $m.Groups[1].Value
        if ($v -notin $computerNames) { $computerNames.Add($v) | Out-Null }
    }

    $cnIdx = 1
    foreach ($cn in $computerNames) {
        & $addReplacement $cn "[COMPUTER-$cnIdx]"
        $cnIdx++
    }

    # -- Usernames --
    $userNames = [System.Collections.Generic.List[string]]::new()

    # From C:\Users\<name>\ paths
    foreach ($m in [regex]::Matches($allText, '(?i)C:\\Users\\([A-Za-z0-9_\-\.]+)\\')) {
        $v = $m.Groups[1].Value
        if ($v -notin $userNames) { $userNames.Add($v) | Out-Null }
    }
    # From USERNAME=X, SshUsername=X, generatedBy fields
    foreach ($m in [regex]::Matches($allText, '(?i)(?:USERNAME|SshUsername|sshUsername)\s*[=:]\s*([A-Za-z0-9_\-\.]+)')) {
        $v = $m.Groups[1].Value
        if ($v -notin $userNames) { $userNames.Add($v) | Out-Null }
    }
    # From MACHINE\user patterns (second part)
    foreach ($m in [regex]::Matches($allText, '[A-Za-z0-9_\-]+\\([A-Za-z0-9_\-]+)')) {
        $v = $m.Groups[1].Value
        if ($v -notin $userNames) { $userNames.Add($v) | Out-Null }
    }
    # From generatedBy field value "MACHINE\user"
    foreach ($m in [regex]::Matches($allText, '(?i)generatedBy["\s:=]+([A-Za-z0-9_\-]+)\\([A-Za-z0-9_\-]+)')) {
        $v = $m.Groups[2].Value
        if ($v -notin $userNames) { $userNames.Add($v) | Out-Null }
    }

    $unIdx = 1
    foreach ($un in $userNames) {
        & $addReplacement $un "[USERNAME-$unIdx]"
        $unIdx++
    }

    # -- Key labels --
    $keyLabels = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($allText, '(?i)(?:KeyLabel|Label|sshKeyLabel)[=:\s"]+([A-Za-z0-9_\-]+)')) {
        $v = $m.Groups[1].Value
        # Skip obvious non-labels
        if ($v -match '^\d+$') { continue }
        if ($v -notin $keyLabels) { $keyLabels.Add($v) | Out-Null }
    }
    # Also from SecureRDP-<label> in authorized_keys comment patterns
    foreach ($m in [regex]::Matches($allText, 'SecureRDP-([A-Za-z0-9_\-]+)')) {
        $v = $m.Groups[1].Value
        if ($v -notin $keyLabels) { $keyLabels.Add($v) | Out-Null }
    }
    foreach ($lbl in $keyLabels) {
        $tag = Redact-KeyLabel -Label $lbl
        & $addReplacement $lbl $tag
        # Also replace the prefixed form
        & $addReplacement "SecureRDP-$lbl" "[SecureRDP-$tag]"
    }

    # -- IPv4 addresses --
    $ipPattern = '\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b'
    $privateIps  = [System.Collections.Generic.List[string]]::new()
    $externalIps = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($allText, $ipPattern)) {
        $ip  = $m.Groups[1].Value
        $cat = Get-IpCategory -Ip $ip
        if ($cat -eq 'private'  -and $ip -notin $privateIps)  { $privateIps.Add($ip)  | Out-Null }
        if ($cat -eq 'external' -and $ip -notin $externalIps) { $externalIps.Add($ip) | Out-Null }
    }
    $piIdx = 1
    foreach ($ip in $privateIps) {
        $tag = if ($privateIps.Count -gt 1) { "[PRIVATE-IP-$piIdx]" } else { '[PRIVATE-IP]' }
        & $addReplacement $ip $tag
        $piIdx++
    }
    $eiIdx = 1
    foreach ($ip in $externalIps) {
        $tag = if ($externalIps.Count -gt 1) { "[EXTERNAL-IP-$eiIdx]" } else { '[EXTERNAL-IP]' }
        & $addReplacement $ip $tag
        $eiIdx++
    }

    # -- SIDs --
    $sidIdx = 1
    foreach ($m in [regex]::Matches($allText, 'S-1-5-\d+-\d+-\d+-\d+-\d+')) {
        & $addReplacement $m.Value "[WINDOWS-SID-$sidIdx]"
        $sidIdx++
    }
    # Shorter SIDs (e.g. S-1-5-18)
    foreach ($m in [regex]::Matches($allText, 'S-1-[0-9\-]+')) {
        & $addReplacement $m.Value '[WINDOWS-SID]'
    }

    # -- SSH public key bodies --
    $keyBodyIdx = 1
    foreach ($m in [regex]::Matches($allText, 'AAAA[A-Za-z0-9+/]{20,}={0,2}')) {
        & $addReplacement $m.Value "[SSH-PUBLIC-KEY-$keyBodyIdx]"
        $keyBodyIdx++
    }

    # -------------------------------------------------------------------------
    # REPLACEMENT PASS
    # Order matters: longer/more-specific values first to avoid partial matches.
    # Usernames before paths (transitive), computer names before qualified names.
    # -------------------------------------------------------------------------

    # Sort by raw length descending so longer strings replace before substrings
    $sortedReplacements = @($replacements | Sort-Object { $_.Raw.Length } -Descending)

    $output = $allText
    foreach ($r in $sortedReplacements) {
        if ([string]::IsNullOrEmpty($r.Raw)) { continue }
        $escaped = [regex]::Escape($r.Raw)
        $output  = [regex]::Replace($output, $escaped, $r.Tag, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }

    # -------------------------------------------------------------------------
    # WRITE OUTPUT
    # -------------------------------------------------------------------------
    $outputLines = $output -split "`n"
    [System.IO.File]::WriteAllLines($OutputPath, $outputLines, [System.Text.UTF8Encoding]::new($false))

    # -------------------------------------------------------------------------
    # STATS FOR SCREEN DISPLAY
    # -------------------------------------------------------------------------
    $hasSshDebug = $lines | Where-Object { $_ -match '^\s*debug[12]\s*:|Warning:\s|ssh_dispatch_run' }

    return @{
        ComputerNames = $computerNames.Count
        UserNames     = $userNames.Count
        KeyLabels     = $keyLabels.Count
        PrivateIps    = $privateIps.Count
        ExternalIps   = $externalIps.Count
        Sids          = ($sidIdx - 1)
        KeyBodies     = ($keyBodyIdx - 1)
        HasSshDebug   = (@($hasSshDebug).Count -gt 0)
        TotalReplaced = $replacements.Count
    }
}

# =============================================================================
# MAIN
# =============================================================================

Write-Host ''
Write-Host '  SecureRDP -- Low Effort Log Sanitizer' -ForegroundColor Cyan
Write-Host '  ======================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '  Scanning for *.log files in:' -ForegroundColor Gray
Write-Host "    $ScriptDir" -ForegroundColor Gray
Write-Host ''

$logFiles = @(Get-ChildItem -LiteralPath $ScriptDir -Filter '*.log' -File -ErrorAction SilentlyContinue |
              Where-Object { $_.DirectoryName -ne $OutputDir })

if ($logFiles.Count -eq 0) {
    Write-Host '  No *.log files found in this directory.' -ForegroundColor Yellow
    Write-Host ''
    exit 0
}

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

$totalFiles     = 0
$totalReplaced  = 0
$anyWarnings    = $false

foreach ($logFile in $logFiles) {
    $outName = [System.IO.Path]::GetFileNameWithoutExtension($logFile.Name) + '_screened.log'
    $outPath = Join-Path $OutputDir $outName

    Write-Host "  Processing: $($logFile.Name)" -ForegroundColor White

    try {
        $stats = Sanitize-Log -InputPath $logFile.FullName -OutputPath $outPath

        $ipDesc = ''
        if ($stats.PrivateIps -gt 0 -or $stats.ExternalIps -gt 0) {
            $parts = @()
            if ($stats.PrivateIps  -gt 0) { $parts += "$($stats.PrivateIps) private" }
            if ($stats.ExternalIps -gt 0) { $parts += "$($stats.ExternalIps) external" }
            $ipDesc = " [$($parts -join ', ')]"
        }

        $clr = if ($stats.TotalReplaced -gt 0) { 'Green' } else { 'Gray' }

        Write-Host "    Usernames:    $($stats.UserNames)   Computer names: $($stats.ComputerNames)   Key labels: $($stats.KeyLabels)" -ForegroundColor $clr
        Write-Host "    IP addresses: $($stats.PrivateIps + $stats.ExternalIps)$ipDesc   SIDs: $($stats.Sids)   SSH key bodies: $($stats.KeyBodies)" -ForegroundColor $clr

        if ($stats.HasSshDebug) {
            Write-Host '    WARNING: SSH debug output detected -- may contain unredacted hostnames' -ForegroundColor Yellow
            Write-Host '             or addresses in freeform text. Review before submitting.' -ForegroundColor Yellow
            $anyWarnings = $true
        }

        Write-Host "    Output:       $outName" -ForegroundColor Gray
        Write-Host ''

        $totalFiles++
        $totalReplaced += $stats.TotalReplaced

    } catch {
        $errMsg = $_.Exception.Message
        Write-Host "    ERROR: Could not process this file: $errMsg" -ForegroundColor Red
        Write-Host ''
    }
}

Write-Host '  ----------------------------------------' -ForegroundColor Gray
Write-Host "  Files processed: $totalFiles   Total replacements: $totalReplaced" -ForegroundColor Cyan
Write-Host "  Screened files written to: partlysanitized\" -ForegroundColor Cyan
Write-Host ''
Write-Host '  NOTE: This screener handles common patterns. Review the output files' -ForegroundColor Yellow
Write-Host '  before submitting -- key labels, hostnames in SSH debug output, domain' -ForegroundColor Yellow
Write-Host '  names, and IPv6 addresses may not be fully redacted.' -ForegroundColor Yellow
Write-Host ''
