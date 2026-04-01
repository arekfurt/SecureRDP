# SecureRDP — Coding Conventions & Hard-Won Rules
## Comprehensive Reference for Code Generation
## Last updated: SRDPtest0074 / 2026-03-28

This document records every coding rule, pattern, and known pitfall
for the SecureRDP codebase. Many of these were learned by breaking
things in live testing. All rules are mandatory unless explicitly noted.

---

## SECTION 1: MANDATORY LANGUAGE RULES

### Rule 1: ASCII-only encoding
All generated PowerShell files must contain only ASCII characters.
No Unicode, no smart quotes, no em-dashes, no non-breaking spaces.
PSScriptAnalyzer will flag non-ASCII chars and the test suite will fail.

### Rule 2: StrictMode .Count wrapping
Under `Set-StrictMode -Version Latest`, `Where-Object` returns `$null`
rather than an empty collection when no items match.
ALWAYS wrap pipeline results in `@()` before accessing `.Count`:

```powershell
# WRONG -- crashes under StrictMode if Where-Object returns null
$items = Get-Something | Where-Object { $_.Active }
if ($items.Count -gt 0) { ... }

# CORRECT
$items = @(Get-Something | Where-Object { $_.Active })
if ($items.Count -gt 0) { ... }
```

### Rule 3: Get-WmiObject is banned
ALWAYS use `Get-CimInstance` instead. `Get-WmiObject` is deprecated,
unavailable in PowerShell 6+, and will fail PSScriptAnalyzer checks.

```powershell
# BANNED
Get-WmiObject Win32_TSGeneralSetting ...

# CORRECT
Get-CimInstance -ClassName Win32_TSGeneralSetting ...
```

### Rule 4: ssh-keygen empty passphrase — splatted array with '""'
In PowerShell 5.1, passing `-N ''` to a native executable drops the
empty string silently before handing to the executable. ssh-keygen
then hangs waiting for interactive passphrase input, OR misparses
the argument list and reports "Too many arguments".

ALWAYS use `'\"\"'` (not `''`) for the -N argument:

```powershell
# WRONG -- empty string dropped, ssh-keygen hangs or fails
$keygenArgs = @('-t', 'ed25519', '-f', $keyPath, '-N', '', '-C', 'label')

# CORRECT -- '""' passes a properly-quoted empty string
$keygenArgs = @('-t', 'ed25519', '-f', $keyPath, '-N', '\"\"', '-C', 'label')
$output   = & $keygenPath @keygenArgs 2>&1
$exitCode = $LASTEXITCODE
# Always check exit code AND verify key file exists
```

### Rule 5: Error contract — return 'error:...' strings
Functions that can fail return structured error strings, not throw.
Format: `return "error:FunctionName: $($_.Exception.Message)"`
Callers check: `if ($result -is [string] -and $result -like 'error:*')`
OR more simply: `if ($result -isnot [string])` for success check.

**Do NOT check `-is [hashtable]`** — most functions return PSCustomObject,
not hashtable. Always use `-isnot [string]` for the success check.

### Rule 6: No nested function declarations
PowerShell does not support nested function declarations the way
other languages do. All functions must be at module/script scope.

### Rule 7: RandomNumberGenerator.Fill() is banned
Use `GetBytes()` instead:

```powershell
# BANNED
[System.Security.Cryptography.RandomNumberGenerator]::Fill($buffer)

# CORRECT
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$rng.GetBytes($buffer)
$rng.Dispose()
```

### Rule 8: return switch(...) is banned
PowerShell's `return switch(...)` pattern is not valid syntax.
Use a variable to capture the switch result then return it.

### Rule 9: Backtick+pipe+scriptblock pattern is banned
The pattern `` ` `` at end of line followed by `|` then scriptblock
causes parse errors in some PS versions. Restructure to avoid it.

### Rule 10: Private key files require Unix line endings
OpenSSH's key parser requires the private key file to end with
exactly one Unix newline (`\n`). When reading a key file written by
ssh-keygen and storing it as a string:

```powershell
# WRONG -- .Trim() strips the required trailing newline
$privKey = (Get-Content $keyPath -Raw -Encoding UTF8).Trim()

# CORRECT -- TrimEnd() strips whitespace, then add exactly one \n
$privKey = (Get-Content $keyPath -Raw -Encoding UTF8).TrimEnd() + "`n"
```

Without the trailing newline, ssh.exe will accept the key fingerprint
from the server (showing it can read the public portion) but then fail
with "invalid format" when trying to sign the authentication challenge.

---

## SECTION 2: ERROR HANDLING RULES

### Rule 11: Universal Result Schema
All engine entry functions return a PSCustomObject with this schema:

```powershell
$Result = [PSCustomObject]@{
    Success = $false
    Status  = 'Unknown'
    Data    = @{ ... }
    Logs    = [System.Collections.Generic.List[string]]::new()
    Errors  = [System.Collections.Generic.List[string]]::new()
}
```

`return $Result` in engines/controllers is intentional and correct
for result-object functions. Do not change to pipeline output.

### Rule 12: Engine EAP ownership
Every engine entry function MUST own its ErrorActionPreference.
Save caller EAP as first statement, set Stop, restore before every return:

```powershell
function Invoke-MyEngine {
    $callerEAP = $ErrorActionPreference  # FIRST STATEMENT
    $ErrorActionPreference = 'Stop'
    
    # ... engine logic ...
    
    $ErrorActionPreference = $callerEAP
    return $Result  # restore before EVERY return path
}
```

Never inherit EAP from caller. Engines called from UI (which may have
EAP=Continue) will silently swallow errors if they don't own their EAP.

### Rule 13: Post-dot-source EAP reset
After dot-sourcing ANY script, immediately re-assert EAP:

```powershell
. (Join-Path $PSScriptRoot 'Engine1_SshBinary.ps1')
$ErrorActionPreference = 'Stop'  # MUST reset -- dot-sourced script overwrites it
. (Join-Path $PSScriptRoot 'Engine2_SshService.ps1')
$ErrorActionPreference = 'Stop'  # MUST reset again
```

### Rule 14: Post-Import-Module EAP reset
Same rule applies after Import-Module -Force:

```powershell
Import-Module $SrdpLogMod -Force
$ErrorActionPreference = 'Stop'  # Reset after module load
```

### Rule 15: Capture exception message FIRST in catch blocks
Always assign `$errMsg = $_.Exception.Message` as the FIRST line
inside any catch block before calling anything else. Subsequent calls
may overwrite `$_`:

```powershell
} catch {
    $errMsg = $_.Exception.Message  # FIRST -- $_ may be overwritten after this
    $Result.Errors.Add("Operation failed: $errMsg")
    try { Write-SrdpLog $errMsg -Level ERROR } catch {}
}
```

### Rule 16: Every error goes to SrdpLog
All error paths must call `Write-SrdpLog` with Level ERROR.
Wrap log calls in `try { } catch {}` since log calls must never
propagate failures back to the engine:

```powershell
try { Write-SrdpLog "Error description: $errMsg" -Level ERROR -Component 'MyEngine' } catch {}
```

### Rule 17: No silent empty catch blocks
`} catch {}` is banned in all active code paths.
Every catch block must at minimum log the error:

```powershell
# BANNED in active code
} catch {}

# CORRECT
} catch {
    $errMsg = $_.Exception.Message
    try { Write-SrdpLog "Operation failed: $errMsg" -Level WARN -Component 'X' } catch {}
}
```

**Exception:** `try { Write-SrdpLog ... } catch {}` — log calls themselves
use empty catch because a logging failure must never propagate.
Also: `try { $ctrl.Dispose() } catch {}` in UI cleanup — acceptable.

---

## SECTION 3: FILE I/O RULES

### Rule 18: Directory existence guard before every file write
EVERY `Set-Content`, `Out-File`, `Add-Content`, or `[IO.File]::Write*`
call must be preceded by a directory existence check:

```powershell
$dir = Split-Path $FilePath -Parent
if (-not (Test-Path $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}
Set-Content $FilePath -Value $content -Encoding UTF8
```

### Rule 19: Post-write verification for critical files
Every critical file write must be followed by verification:

```powershell
Set-Content $ConfigPath -Value $content -Encoding UTF8
if (-not (Test-Path $ConfigPath)) {
    throw "CRITICAL: $ConfigPath not found after write."
}
$size = (Get-Item $ConfigPath).Length
if ($size -eq 0) {
    throw "CRITICAL: $ConfigPath is empty after write."
}
```

### Rule 20: UTF-8 without BOM for all key/config files
PowerShell 5.1's `Set-Content -Encoding UTF8` writes UTF-8 WITH BOM.
For files consumed by OpenSSH (key files, known_hosts, authorized_keys,
sshd_config), ALWAYS use:

```powershell
[System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
```

The `$false` parameter disables BOM. OpenSSH's parser chokes on BOM bytes.

### Rule 21: SSH private key ACL — server host keys
sshd refuses to start if the host key is readable by any account
other than SYSTEM and Administrators. The ACL must be set with an
explicit purge of all existing rules BEFORE adding new ones.
`SetAccessRuleProtection` alone does NOT remove existing explicit ACEs.

The ONLY reliable pattern (confirmed working in live testing):

```powershell
$system = New-Object System.Security.Principal.NTAccount('NT AUTHORITY\SYSTEM')
$admins = New-Object System.Security.Principal.NTAccount('BUILTIN\Administrators')
$acl = Get-Acl $keyPath
$acl.SetAccessRuleProtection($true, $false)
foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRule($rule) | Out-Null }
$acl.SetOwner($system)
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    $system, 'FullControl', 'Allow')))
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    $admins, 'FullControl', 'Allow')))
Set-Acl $keyPath $acl
```

**Critical details:**
- `@($acl.Access)` — snapshot the collection before iterating; modifying
  live collection during enumeration causes issues in some .NET versions
- `| Out-Null` on RemoveAccessRule — it returns bool, suppress output
- Apply to: ssh_host_ed25519_key AND authorized_keys

### Rule 22: SSH private key ACL — client keys
ssh.exe refuses to use a private key readable by any account other
than the owning user. Pattern is same purge-and-set, but owner is
current user ($env:USERNAME), NOT SYSTEM:

```powershell
$currentUser = [System.Security.Principal.NTAccount]$env:USERNAME
$acl = Get-Acl $keyPath
$acl.SetAccessRuleProtection($true, $false)
foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRule($rule) | Out-Null }
$acl.SetOwner($currentUser)
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    $currentUser, 'FullControl', 'Allow')))
Set-Acl $keyPath $acl
```

---

## SECTION 4: SSH / OPENSSH RULES

### Rule 23: known_hosts format for non-default port
When SSH port is not 22, OpenSSH known_hosts MUST use bracketed format:
`[address]:port` not bare `address`.

```powershell
$khHost = if ($SshPort -ne 22) { "[$ServerAddress]:$SshPort" } else { $ServerAddress }
$knownHostsLine = "$khHost $hostKeyType $hostKeyBody"
```

On the client side, Connect-SecureRDP.ps1 passes `-p $SSH_PORT` to ssh.exe.
When port != 22, ssh.exe looks up `[address]:port` in known_hosts.
If the entry is bare `address`, StrictHostKeyChecking=yes causes immediate
"Host key verification failed" abort.

### Rule 24: SSH argument quoting for ProcessStartInfo
When building ssh.exe argument strings for ProcessStartInfo.Arguments,
do NOT embed literal quote characters inside array elements.
Quote paths at join time only, and only when they contain spaces:

```powershell
function ConvertTo-QuotedArg {
    param([string]$s)
    if ($s -match '\s') { return "`"$s`"" }
    return $s
}

$sshArgs = @(
    '-i', (ConvertTo-QuotedArg $keyFileFull)
    '-o', "UserKnownHostsFile=$(ConvertTo-QuotedArg $knownHostsFull)"
    ...
)
$pinfo.Arguments = $sshArgs -join ' '
```

Embedded backtick-quotes like `"`"$path`""` in array elements cause
the literal quote characters to be passed to ssh.exe as part of the
filename, causing "file not found" errors.

### Rule 25: Always capture ssh-keygen exit code
Never discard ssh-keygen output. Always capture and check:

```powershell
$output   = & $keygenPath @keygenArgs 2>&1
$exitCode = $LASTEXITCODE
try { Write-SrdpLog "ssh-keygen exit=$exitCode output=$($output -join ' | ')" -Level DEBUG } catch {}
if ($exitCode -ne 0) {
    # Handle failure -- do not proceed to verify key file
}
```

### Rule 26: ssh.exe fast-fail options
Always include these in SSH argument lists to prevent invisible hangs:
```
-o PasswordAuthentication=no
-o KbdInteractiveAuthentication=no
-o ConnectTimeout=20
```
Without `PasswordAuthentication=no`, ssh.exe may silently block waiting
for a password on a hidden stdin, causing a timeout with no useful error.

### Rule 27: Async stderr race condition
When capturing ssh.exe stderr via `BeginErrorReadLine`, the process may
have exited but buffered data is still in transit through the async handler.
Before reading `$stderrLines` after process exit, flush the pipe:

```powershell
try { $sshProc.WaitForExit(500) } catch {}  # flush buffered stderr
$stderr = $stderrLines -join "`n"
```

---

## SECTION 5: WINFORMS RULES

### Rule 28: WinForms closure capture
Variables used inside `.GetNewClosure()` scriptblocks must be captured
as LOCAL variables BEFORE the closure, not referenced as automatic
variables inside the closure. Automatic variables (like `$PSScriptRoot`)
may not resolve correctly when the closure executes later.

```powershell
# WRONG -- $PSScriptRoot may not resolve inside closure
$click = {
    $path = Join-Path $PSScriptRoot 'some\path'
}.GetNewClosure()

# CORRECT -- capture before closure
$capturedPath = Join-Path $PSScriptRoot 'some\path'
$click = {
    $path = $capturedPath
}.GetNewClosure()
```

### Rule 29: Wire ALL child controls for click/hover
WinForms labels and panels consume mouse events. If a tile or button
contains child labels, wire ALL children for click and hover events,
not just the parent container. Otherwise clicking/hovering on text
within the tile appears to do nothing.

```powershell
# CORRECT -- iterate all controls in tile
$allControls = @($tile) + @($tile.Controls)
foreach ($ctrl in $allControls | Where-Object { $null -ne $_ }) {
    $ctrl.Add_Click($clickScript)
    $ctrl.Add_MouseEnter($enterScript)
    $ctrl.Add_MouseLeave($leaveScript)
}
```

### Rule 30: ToolTip disposal on refresh
`New-Object System.Windows.Forms.ToolTip` creates a component object,
not a Control. It is NOT automatically disposed when its parent panel
is cleared. Store in button.Tag and dispose explicitly:

```powershell
# In button creation
$tt = New-Object System.Windows.Forms.ToolTip
$tt.SetToolTip($button, $tipText)
$button.Tag = $tt  # store for disposal

# In Dispose-PanelControls
if ($null -ne $ctrl.Tag -and $ctrl.Tag -is [System.Windows.Forms.ToolTip]) {
    try { $ctrl.Tag.Dispose() } catch {}
}
```

### Rule 31: MessageBox TopMost ownership
To make a MessageBox steal focus correctly, the owner form must be
visible (not minimized). A minimized owner causes the MessageBox to
appear without stealing focus on many Windows versions.
Use a small off-screen form:

```powershell
$owner             = New-Object System.Windows.Forms.Form
$owner.TopMost     = $true
$owner.Width       = 1; $owner.Height = 1
$owner.Left        = -2000; $owner.Top = -2000
$owner.FormBorderStyle = 'None'
$owner.Show()
[System.Windows.Forms.MessageBox]::Show($owner, $message, ...) | Out-Null
$owner.Close()
```

---

## SECTION 6: MODULE IMPORT RULES

### Rule 32: Existence guard on every import
Every Import-Module call must include a pre-existence check:

```powershell
$modulePath = Join-Path $BuildRoot 'RDPCheckModules\RDPStatus.psm1'
if (-not (Test-Path $modulePath)) {
    Write-Host "ERROR: RDPStatus.psm1 not found at: $modulePath" -ForegroundColor Red
    exit 1
}
Import-Module $modulePath -Force
$ErrorActionPreference = 'Stop'  # Reset after import
```

### Rule 33: EAP reset after every Import-Module
See Rule 14. Module top-level statements execute in caller scope and
may alter EAP. Always reset immediately after each Import-Module.

### Rule 34: Pre-generation dependency check (MANDATORY)
Before generating ANY script, list every external function call and
verify its source module is imported. Check against the Dependency Map
(Section 7 of Project Record). This check MUST be documented in the
build log pre-generation review section.

Missing imports are the single most recurring class of error in this
codebase. The failure mode is always the same: script runs, throws
"term not recognized as the name of a cmdlet" deep in execution.

---

## SECTION 7: UTIL SCRIPT RULES

### Rule 35: Util script BuildRoot resolution
Util scripts live in `Util\` — exactly one level below the project root.
Use `$BuildRoot = Split-Path $PSScriptRoot -Parent` to get project root.
Do NOT use sentinel file search or other patterns — the Util folder
location is fixed by design.

### Rule 36: $ScriptDir vs $PSScriptRoot
Util scripts use `$ScriptDir = Split-Path $PSScriptRoot -Parent` for
build root, but `$PSScriptRoot` itself is the Util folder.
Don't conflate them.

---

## SECTION 8: KNOWN PLATFORM QUIRKS

### Quirk 1: Windows OpenSSH 8.1 (installed via Optional Features)
The test machine has Windows OpenSSH 8.1 installed (not bundled 9.5).
All functionality works. Version < 9.5 triggers a compatibility advisory
in Engine 1 (quantum-resistant/hardware-key features may not be available).

### Quirk 2: sshd service permissions on host key
Windows OpenSSH sshd (running as SYSTEM) performs a strict permissions
check on startup. If ANY account other than SYSTEM and Administrators
has ANY access to the host key private file, sshd refuses to start with
"terminated unexpectedly". This check happens at service start time,
not at ssh-keygen time. The file may look fine immediately after creation
but have extra ACEs from the creating user that must be explicitly purged.

### Quirk 3: mstsc.exe process lifetime
`Start-Process mstsc.exe -PassThru` returns a Process object that may
not track the actual RDP window lifetime correctly. mstsc can spawn a
child process and exit its main process. Use `WaitForInputIdle` before
polling `HasExited` to avoid false early exit detection.

### Quirk 4: ProcessStartInfo.Arguments vs array
When calling native executables via ProcessStartInfo, the Arguments
string is parsed by the Windows command-line parser, not by PowerShell.
This means embedded quotes behave differently than expected. Quote paths
only when they contain spaces; never pre-embed quotes in array elements.

### Quirk 5: Set-Content UTF-8 BOM in PowerShell 5.1
`Set-Content -Encoding UTF8` in PowerShell 5.1 writes a UTF-8 BOM
(EF BB BF bytes at start of file). OpenSSH parsers reject BOM.
Use `[System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))`.

### Quirk 6: switch -Regex concatenates all matching branches
PowerShell's `switch -Regex` does NOT stop at first match by default.
All matching branches execute and their outputs concatenate. Use
`if/elseif` or add `break` to each case when only one result is wanted.

### Quirk 7: BeginConnect/EndConnect pairing
`TcpClient.BeginConnect` MUST be paired with `EndConnect`. Calling
`Close()` without `EndConnect` may not release the socket promptly and
the `Connected` property may report stale data until `EndConnect` is called.

---

## SECTION 9: WHAT NOT TO DO (ANTI-PATTERNS)

These have all caused real bugs in this codebase:

1. **Don't use `-is [hashtable]` to check function return type.**
   Functions return PSCustomObject. Use `-isnot [string]`.

2. **Don't omit `.Trim()` from public keys but don't use it on private keys.**
   Private keys need `TrimEnd() + "\`n"`. Public keys use `Trim()`.

3. **Don't call `Add-WindowsCapability` without handling the PendingReboot case.**
   Installation may succeed but binaries are inaccessible until reboot.

4. **Don't assume SetAccessRuleProtection removes existing ACEs.**
   It blocks inheritance only. Explicit ACEs from the creating user survive.
   Always do the foreach purge loop first.

5. **Don't use $PSScriptRoot inside GetNewClosure() for path construction.**
   Capture the path in a local variable before the closure.

6. **Don't continue engine execution after recording a CRITICAL error.**
   If host key generation fails, don't attempt to start sshd.
   Gate on `$Result.Errors.Count -gt 0` and return early.

7. **Don't write state.json to ProgramData without also writing to InstalledModes.**
   The dashboard reads from InstalledModes. The default in Write-StateFile
   is wrong — always pass the correct StateFilePath parameter.

8. **Don't wire only the parent tile for click/hover.**
   Child labels consume mouse events. Wire `@($tile) + @($tile.Controls)`.

9. **Don't use Launch.cmd to call Unpack.ps1 for unencrypted packages.**
   New-TestClientConfig creates unencrypted packages. Launch.cmd calls
   Connect-SecureRDP.ps1 directly. Unpack.ps1 is for future encrypted
   package delivery only.
