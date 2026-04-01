
## SecureRDP initial public testing/dev/alpha release - Version 0.85 ##
#### March 31, 2026 ####

To get started:
Unzip the archive and find the file ServerWizard.ps1 in the root of the folder. Right-click on it, click "run as Powershell", and make your way through the expected security dialogs. You'll see a welcome screen on first-launch that will direct you onward.

### Known Issues ###

-While installing OpenSSH Server using Windows Optional Features manager, the process may appear to go abnormally slowly or hang, while also being stuck on a status of "assessing OpenSSH installed on the host" or such. In reality, as long as the PS install progress bar that should be showing in the background does not freeze for a long time installation is in fact occurring.

-The RDP port firewall assessment widget, in its current design, may err on the side of overestimating your RDP port/s degree of openness to incoming network traffic. Especially if you have many precise rules affecting that exposure.

-If RDP is open to IPv6 traffic from anywhere else the current code of the firewall widget may show a red alarm state claiming that RDP is open to traffic from anywhere on the Internet.

-The initial public build does not contain certificate pinning functionality on the client to ensure the RDP server tunnel is strongly authenticated, nor to suppress user-facing warnings about untrusted RDP connections. Both are high priorities, but the SecureRDP implementations needed to be held back for more consideration. (The SSH tunnel still provides crypto mutual auth.)
See the pre-release updates file for more info on planned features that did not quite make the first public build.

## Current and Very-Near Term Features ##
[For sake of efficency as I'm busy uploading files, for the moment I will have Opus 4.6 extended provide you a placeholder description of features:]

# SecureRDP Features

## Features in v0.85 (Current Test Build)

SecureRDP v0.85 is the first public test build. It targets Windows Server and Pro editions running PowerShell 5.1 and provides a GUI-driven workflow for hardening RDP access using SSH tunnels with public key authentication.

### Security Dashboard

The main screen provides a live overview of your machine's RDP security posture, including four status widgets covering RDP service state, firewall exposure for RDP traffic, mode operational status, and attack exposure monitoring. Widgets are color-coded by severity and update on each refresh.

### Quick Start Wizards (Phase 1 + Phase 2)

A two-phase guided setup installs and configures OpenSSH Server with hardened settings (ED25519 keys, no password authentication), then creates Windows Firewall rules to control SSH and RDP traffic. Each step is shown before execution and requires explicit confirmation. The wizard detects existing installations, handles reboot-required scenarios, and provides detailed activity logs throughout.

### Client Package Creator

Generates portable connection packages for remote users. Each package contains an SSH key pair, server host key verification data, and connection scripts. The remote user extracts the package and double-clicks to connect — the SSH tunnel is established automatically, and they see a standard Windows login prompt through the tunnel. Multiple packages can be created for different users, each with their own key.

### Enhanced Security Controls

Optionally blocks direct inbound RDP connections via firewall rules and restricts the RDP listener to the loopback adapter only, so RDP is reachable exclusively through the SSH tunnel. These controls can be toggled independently and are session-aware — the program prevents you from accidentally locking yourself out if you're connected via RDP or the tunnel.

### SSH Management Screen

View and control the SSH service, toggle firewall rules, and manage authorized client keys. Each key shows its label, creation date, target server, and SSH username. Keys can be deauthorized individually (with immediate effect on active tunnels), and a notes field is provided for tracking purposes.

### Attack Exposure Monitoring

An opt-in feature that analyzes Windows Event Log 261 to determine whether your RDP port has received connection attempts from public internet addresses in the last 72 hours. No IP addresses are stored or displayed — only a safe/exposed verdict is shown. Uses your existing log configuration if already enabled.

### Revert / Uninstall

All changes made by SecureRDP can be reverted from the dashboard. The revert process restores backed-up configurations, removes firewall rules, and returns the machine to its pre-installation state.

### Additional Details

- Bundles Microsoft OpenSSH 9.5 binaries (x64/x86) but also works with existing Windows OpenSSH installations (8.1+).
- Central logging to `C:\ProgramData\SecureRDP\Logs\` for diagnostics and bug reporting.
- Includes a log sanitizer tool (`Tools\LowEffortLogSanitizer.ps1`) that redacts usernames, IPs, SIDs, and key material before you submit logs to GitHub.
- No external dependencies, no internet access required after initial download, no telemetry.

---

## Coming Soon

### Passphrase-Encrypted Client Packages

Client packages will be encrypted with AES-256 before delivery. The remote user enters a passphrase to decrypt and connect. The encryption engine is already built — integration with the package creation wizard is next.

### Client / User Management

A dedicated section for viewing all issued client packages across users, revoking access, and tracking connection history from a single screen.

### Other RDP Security Widget

The dashboard will display additional RDP security details including NLA status, certificate expiry, group membership analysis, and dangerous principal detection. The assessment engine is built; the widget is pending integration.

### Deep Firewall Risk Check

An expanded firewall analysis going beyond the current per-port summary to provide rule-by-rule detail and specific remediation guidance.




