#Requires -Version 5.1
# =============================================================================
# SecureRDP v0.848115 - SupportingModules\SrdpLog.psm1
#
# Central logging module for SecureRDP. All active code paths hook into this.
# Every error, warning, and significant event is written to a persistent
# append-only log file for post-mortem review.
#
# Log path:   C:\ProgramData\SecureRDP\Logs\srdp_yyyy-MM-dd.log
# Format:     [timestamp] [LEVEL] [Component] Message
# Levels:     DEBUG, INFO, WARN, ERROR
#
# Exported functions:
#   Initialize-SrdpLog  - call once at process startup with component name
#   Write-SrdpLog       - write a log entry; never throws
# =============================================================================
Set-StrictMode -Version Latest

$Script:SRDP_LOG_DIR       = 'C:\ProgramData\SecureRDP\Logs'
$Script:SRDP_LOG_FILE      = $null
$Script:SRDP_LOG_COMPONENT = 'Unknown'
$Script:SRDP_SESSION_ID    = $null

# =============================================================================
# Initialize-SrdpLog
#
# Call once at the start of each process (ServerWizard, QS wizard, Revert, etc.)
# Creates the log directory and file if needed, writes a session header.
#
# Parameters:
#   Component - identifies this process in log entries (e.g. 'ServerWizard',
#               'QS-Phase1a', 'Revert-Phase1a', 'NewTestClientConfig')
# =============================================================================
function Initialize-SrdpLog {
    [CmdletBinding()]
    param(
        [string]$Component = 'Unknown'
    )
    try {
        $Script:SRDP_LOG_COMPONENT = $Component
        $Script:SRDP_SESSION_ID    = [System.Guid]::NewGuid().ToString('N').Substring(0, 8).ToUpper()

        if (-not (Test-Path $Script:SRDP_LOG_DIR)) {
            New-Item -ItemType Directory -Path $Script:SRDP_LOG_DIR -Force | Out-Null
        }

        $date = Get-Date -Format 'yyyy-MM-dd'
        $Script:SRDP_LOG_FILE = Join-Path $Script:SRDP_LOG_DIR "srdp_$date.log"

        $header = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') =========================================="
        $header += "`r`n$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') SESSION START  Component=$Component  PID=$PID  SessionID=$($Script:SRDP_SESSION_ID)"
        $header += "`r`n$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') =========================================="
        Add-Content -Path $Script:SRDP_LOG_FILE -Value $header -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {
        # Cannot log the log failure -- silently continue
    }
}

# =============================================================================
# Write-SrdpLog
#
# Writes a timestamped log entry to the log file. Never throws.
# Safe to call even if Initialize-SrdpLog was not called (no-op).
#
# Parameters:
#   Message   - the log message text
#   Level     - DEBUG | INFO | WARN | ERROR  (default: INFO)
#   Component - override the component name for this entry (optional)
# =============================================================================
function Write-SrdpLog {
    [CmdletBinding()]
    param(
        [string]$Message,
        [ValidateSet('DEBUG','INFO','WARN','ERROR')]
        [string]$Level = 'INFO',
        [string]$Component = $null
    )
    try {
        if ($null -eq $Script:SRDP_LOG_FILE) { return }

        $ts        = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        $comp      = if ($Component) { $Component } else { $Script:SRDP_LOG_COMPONENT }
        $levelPad  = $Level.PadRight(5)
        $sessionId = if ($Script:SRDP_SESSION_ID) { $Script:SRDP_SESSION_ID } else { '--------' }
        $line      = "[$ts] [$levelPad] [$sessionId] [$comp] $Message"

        Add-Content -Path $Script:SRDP_LOG_FILE -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {
        # Never throw from logging
    }
}

Export-ModuleMember -Function Initialize-SrdpLog, Write-SrdpLog
