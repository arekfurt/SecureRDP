---
name: SecureRDP basic bug report (v.1)
about: File a bug report
title: ''
labels: ''
assignees: ''

---

# SecureRDP Bug Report

## Bug Summary
[Provide a brief description of the issue]

## Environment Details

**Does the bug occur on the machine to be connected to or on the client side?**
[Specify: server-side / client-side / unclear]

**Windows edition/s and version/s:**
[Example: Windows Server 2022, Windows 11 Pro]

**Are you running at least PowerShell 5.1?**
[Yes / No / Unknown]

**Are you running in a Virtual Machine, or on real hardware?**
[VM / Hardware / Unknown]

## Error Messages

[Redact any personally identifiable information that you do not wish to be publicly visible here.]

## Program Logs

For serious errors (meaning core functionality doesn't work, the currently running part of the program crashes, etc.), it would be very helpful if you could include the program logs for the user session.

- **Server-side logs:** `C:\ProgramData\SecureRDP\Logs\`
- **Client-side logs:** `.log` file or files in the same directory your client package is in

**Note:** No private keys should be contained in these log files, but identifying information or information about your computing environment that you may not want to share might well be. To aid you in redacting such logs, use the `LowEffortLogSanitizer.ps1` script found in the Tools directory. Place the logs you want help sanitizing in that directory and run the script.

```
[Paste sanitized log entries here]
```
