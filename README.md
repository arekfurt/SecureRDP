
# SecureRDP initial public testing/dev/alpha release - Version 0.85 #
#### released: March 31, 2026 ####


## What is SecureRDP, and why should anyone care? ##

Microsoft's ubiquitous Remote Desktop Protocol and the software implementing it remain vital to practical computing in 2026, certainly for those organizations and individuals who use Windows heavily. But unfortunately Microsoft—-by which I mean senior Microsoft executives collectively—-has not seen fit to make RDP security a priority, at least in terms of how easy it is for customers to secure RDP against very common attacks. This is despite the tremendous amount of harm RDP-involved breaches and compromises have caused. And despite the fact that there are technical capabilities that are part of Windows today (and some of which have been in there for many, many years) that can be used by experts to secure RDP quite robustly. And without Windows users having to be dependent on external software or services that drive increased cost and potentially come with other concerns.

The goal of the SecureRDP project is to help people and organizations make use of these capabilities already in Windows to better protect themselves. And without those people and organizations having to be or employ RDP security experts to do it. Or to conclude they have no option but to turn to Microsoft or third-party security industry add-on or RDP replacement services. 

## What SecureRDP Does ##

SecureRDP tries to make it much easier to understand and improve RDP security for remotely accessing important Windows machines and networks over very low trust networks between clients and servers.
SecureRDP tries to make it much easier to understand and improve RDP security for remotely accessing important Windows machines and networks over very low trust networks between clients and servers.

Put another way, SecureRDP is intended to help people and organizations protect and secure their use of RDP using technologies already within Windows more easily than they could today.

How?

1. SecureRDP includes a dashboard and widgets that are intended to help you easily visualize and appreciate your current RDP-related security posture against remote, over-the-network attack--which is an very important part of securing Windows well generally. In version 0.85 there is a firewall configuration assessment widget that tries to calculate the effective total exposure of your RDP port/s to inbound traffic allowed by the currently active firewall profile in Windows Firewall. This is paired with a currently off-by-default widget that attempts to read your Windows Event 261 logs (and starts keeping those logs if you aren't right now) to spot actual connection attempts made against RDP on your machine from the Internet. More widgets and more advanced versions of these two are coming, but already today if both these widgets are showing red alarm states you need to evaluate or reevaluate whether you have a very serious problem. (Any time RDP is directly exposed to inbound traffic from arbitrary Internet addresses you should start with a presumption that you have a very serious problem.)
   
2. SecureRDP introduces the concept of RDP protection "modes", which are intended to help those who today may feel they have to leave RDP exposed to inbound traffic from presumably hostile networks (like the Internet, although this can apply to situations where you are trying to secure access to critical assets and key administrative machines inside a normal organizational network as well) with mere password protection or with password + phishable-MFA defenses in place. SecureRDP modes will protect RDP by making sure it is wrapped in cryptographically sound tunnels and, most importantly, by implementing cryptographic mutual authentication. This far better ensures that both client and remote host are who they say they are and, by defintion, breaks the password-based and MFA-bypass-based attacks that RDP alone is usually subject to. Right now, the only Mode in SecureRDP is a prototype SSH ---> RDP Mode that tunnels RDP--with no changes to an existing configuration--through a SSH tunnel created by hardened configurations on both ends. But it is intended that more options will be available in the near-ish future.

3. SecureRDP currently contains what you might call two "lockdown" measures you can enable that are designed to literally force any RDP access to a machine to go through a protective mode instead of happening directly. SecureRDP can, at your option, enable firewall rules to block all direct RDP access (TCP and UDP), and additionally tell the RDP listener to only listen for and allow RDP connections to come from a Secure RDP mode tunnel (over port forwarding and localhost). Note: Changing what this RDP listener listens to regarding inbound RDP connections is officially documented but has so little existing information widely available about it that I am currently labeling this "experimental".

4. Other features related to RDP security are in the works in various stages of development and internal testing but did not make the cut for this initial public testing release.

-------------------------------------

## Getting Started + An Important Notice ##
To get started:
On a machine that you would like to enable (more) secure access to using a SSH + RDP tunnel, unzip the SecureRPD archive and find the file ServerWizard.ps1 in the root of the folder. Right-click on it, click "run as Powershell", and make your way through the expected security dialogs. You'll see a welcome screen on first-launch that will direct you onward to the main status dashboard. Click the Quick Start tile on the left to launch a wizard that will take you through installing SecureRPD setup and management on  the machine and generating your first client key and client archive package. Move the client package archive via some appropriately secure means (it contains an unencrypted private key!) to your test client Windows machine, extract the folder, open it, and double click the Connect.cmd file.

(Note: A feature that uses a passphase-encrypted archive to protect the client private key in transit will ship very shortly.) 

### Notice: ###

I'm happy to have the interest of anyone thinking of trying out SecureRDP v.0.85, but before you actually do please understand the following:

This first release is primarily intended for folks who want to help me find breaking bugs (I'm one guy, without access to a serious enterprise testing environment that I can use for personal projects.) and those who want to give me feedback at a early phase in the software's life (when that feedback can have the most impact). It is not intended for day-to-day use at this point. If you try it, you will find bugs. It is only about the severity of the bugs, and whether they are already on the list of the project's Known Issues for .85.(Please check that before filing bug reports in the Issues area.)

To be totally clear:
DO NOT USE THIS VERSION OF THE SOFTWARE IN PRODUCTION. DO NOT USE IT ON ANY MACHINES THAT YOU NEED TO REMAIN OPERATIONAL, OR THAT HOST UNBACKED-UP IMPORTANT DATA.

----------------------------------

### Known Issues ###

-While installing OpenSSH Server using Windows Optional Features manager, the process may appear to go abnormally slowly or hang, while also being stuck on a status of "assessing OpenSSH installed on the host" or such. In reality, as long as the PS install progress bar that should be showing in the background does not freeze for a long time installation is in fact occurring.

-The RDP port firewall assessment widget, in its current design, may err on the side of overestimating your RDP port/s degree of openness to incoming network traffic. Especially if you have many precise rules affecting that exposure.

-If RDP is open to IPv6 traffic from anywhere else the current code of the firewall widget may show a red alarm state claiming that RDP is open to traffic from anywhere on the Internet.

-After you create a new client key and package, the center SSH mode tile on the dashboard may still show an error message in red saying that it can't find any authorized keys. Tap the Manage button to be taken to the SSH mode management page and confirm whether the key has actually been created.

-Unfortunately, version 0.85 is not compatible with Constrained Language Mode.  Add-Type is currently used in a number of places. CLM compatibilty is important to me, but I made a decision that making it happen for 0.85 would have delayed initial release too substantially to be worth it at this stage. I have actively tried to minimize use of non-compliant mechanisms, however, in hopes it will be reasonably achieveable sooner vs later.  

-There are, not surprisingly, numerous points where the UI needs some fixes and polishing.

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




