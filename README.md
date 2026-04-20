# RDP Armoring (RDPA) testing/alpha release - Version 0.87 
--------------------------------

### What is RDPA? ###

Simply put, RDPA (RDP Armoring) is about making highly secure remote desktop access easy to achieve for Windows-using organizations and individuals, at no additional cost beyond the OS itself. Using proven technologies that are maintained and serviced as part of Windows.

RDPA seeks to make using RDP much more secure than it is today, at least compared to how RDP is most commonly configured and employed. It does this by placing RDP in an outer tunnel that uses mutual cryptographic authentication, protecting RDP from essentially all real-world tactics employed by attackers against it. RDPA requires no installation of any third-party code to handle that (meaning: it just configures and monitors Windows components) or any connection to cloud services. 

Currently, RDPA is in a late alpha/early beta phase of development. It supports protecting RDP with an outer SSH tunnel that uses public key mutual auth and hardened client and server configurations.

#### 04/19/2026 Update: ####

I'm quite pleased, after a considerable amount of work, to finally announce the public release of RDP Armor (RDPA) version 0.87. 

Most notably 0.87 includes a client-side automatic encryption system for the remote user's private key/s intended to prevent theft of them by commodity malware or loss/exposure of them by accidental means. Moreover, the RDPA software now supports using IPv6 for remote SSH tunnel connectivity and has added an array of small usability improvements. But probably most importantly, extensive efforts have been invested over the last 10 days in making the RDPA codebase better and the software considerably more reliable. And more secure. This release marks a substantial advance toward achieving beta quality release status and begins a march toward being ready for wider use in the very near future. 

#### 04/07/2026 Update: ####

After a first initial public release with version 0.85 last Tuesday and a project renaming event involving 0.851 build on Saturday, I'm pleased today to present a more capable, more fleshed out, hopefully somewhat less buggy v. 0.86.  

Aside from a number of bug fixes that have accumulated over the last week, this build includes the encrypted client package generator to protect keys and config files with secure generated passphrases that I had originally very much hoped to include with 0.85. Additionally, and perhaps even more notably, I have started building the first elements into what is now-named RDPA to enable upgrading from one build to another while bringing along your configuration state with you in a well-supported way. (From now onward, on first run of a new build on a test system that already has a previous build from 0.86 or higher installed on it RDPA should ask you if you want "take over the existing instance" to give control of it to your new build folder. Or you can use the manual import configuration files from another RDPA project version.) Moreover, the firewall rule risk widget has had some improvements fixing some of its more significant tendencies towards overstating exposure to different kinds of network traffic.

## Getting Started + An Important Notice ##

#### Requirements: ####
A Windows 10 or 11 machine of Pro SKU or higher to act as the server you want to allow remote access to. 

Also note that for the present time use of NTLM2 must be allowed for connecting via RDP to the server, as unfortunately Windows does not yet support Kerberos use with an SSH tunnel. (RDPA options beyond SSH tunneling are coming.) Additionally, either Windows needs to be able to reach Windows Update online infrastructure to download and install the OpenSSH server optional feature or you must install this yourself using your own configuration/deployment tools or manual means.

#### To get started: ####
On a Windows 10 or 11 test machine (Pro SKU or above) that will act as the RDP server that you want to enable more secure access to, unzip the RDP-Armoring archive and find the file ServerWizard.ps1 in the root of the folder. Right-click on it, click "Run with PowerShell", and make your way through the expected security dialogs. You'll see a welcome screen on first launch, and then you'll be taken to the main status dashboard. Clicking the Quick Start tile on the left will launch a wizard that will walk you through the process of installing and configuring needed SSH server components and generating your first client key and connection package. Make sure to note the generated passphrase that appears on-screen; it protects the private key and configuration info in the archive and you will need it to connect. Move the client package zip archive to a test client machine, extract and open the folder, and doubleclick the setup shortcut file. When prompted enter the passphrase, and wait while the SSH tunnel is established and the RDP client is started. Then connect via RDP as you normally would. (Note: The field showing the computer address to be connected to will say "localhost" or "127.0.0.1.")


### Notice: ###

I'm happy to have the interest of anyone thinking of trying out RDPA, but before you actually do please understand the following:

This release is primarily intended for folks who want to help me find bugs (I'm one guy, without access to a serious enterprise testing environment that I can use for personal projects.) and to provide feedback for improvements. It is not intended for day-to-day use at this point. If you try it, you should expect that you may very well find some bugs. Perhaps even in the functioning of major/core features. I would greatly appreciate it if you would file a bug report for any significant/breaking problems, (Please check the Known Issues area of this readme before filing.) Indeed, you are welcome to file an Issue even if you experience no significant difficulties at all, for even that provides very valuable info for me to have at this stage.

To be totally clear:
DO NOT USE THIS VERSION OF THE SOFTWARE IN PRODUCTION. DO NOT USE IT ON ANY MACHINES THAT YOU NEED TO REMAIN OPERATIONAL, OR THAT HOST UNBACKED-UP IMPORTANT DATA.

----------------------------------

## What is RDP-Armoring, and why should anyone care? ##

Microsoft's ubiquitous Remote Desktop Protocol and the software implementing it remain vital to practical computing in 2026, certainly for those organizations and individuals who use Windows heavily. But unfortunately Microsoft — by which I mean senior Microsoft executives collectively — has not seen fit to make RDP security a priority, at least in terms of how easy it is for customers to secure RDP against very common attacks. This is despite the tremendous amount of harm RDP-involved breaches and compromises have caused. And despite the fact that there are technical capabilities that are part of Windows today (and some of which have been there for many, many years) that can be used by experts to secure RDP quite robustly — and without Windows users having to be dependent on external software or services that drive increased cost and potentially come with other concerns.

The goal of the RDP-Armoring project is to help people and organizations make use of these capabilities already in Windows to better protect themselves — and without those people and organizations having to be or employ RDP security experts to do it, or to conclude they have no option but to turn to Microsoft or third-party security industry add-on or RDP replacement services.

## What RDP-Armoring Does ##

RDP-Armoring tries to make it much easier to understand and improve RDP security for remotely accessing important Windows machines and networks over very low trust networks between clients and servers.

Put another way, RDP-Armoring is intended to help people and organizations protect and secure their use of RDP using technologies already within Windows more easily than they could today.

How?

1. RDP-Armoring includes a dashboard and widgets that are intended to help you easily visualize and appreciate your current RDP-related security posture against remote, over-the-network attack — which is a very important part of securing Windows well generally. In version 0.851 there is a firewall configuration assessment widget that tries to calculate the effective total exposure of your RDP port/s to inbound traffic allowed by the currently active firewall profile in Windows Firewall. This is paired with a currently off-by-default widget that attempts to read your Windows Event 261 logs (and starts keeping those logs if you aren't right now) to spot actual connection attempts made against RDP on your machine from the Internet. More widgets and more advanced versions of these two are coming, but already today if both these widgets are showing red alarm states you need to evaluate or reevaluate whether you have a very serious problem. (Any time RDP is directly exposed to inbound traffic from arbitrary Internet addresses you should start with a presumption that you have a very serious problem.)

2. RDP-Armoring introduces the concept of RDP protection "modes", which are intended to help those who today may feel they have to leave RDP exposed to inbound traffic from presumably hostile networks (like the Internet, although this can apply to situations where you are trying to secure access to critical assets and key administrative machines inside a normal organizational network as well) with mere password protection or with password + phishable-MFA defenses in place. RDP-Armoring modes will protect RDP by making sure it is wrapped in cryptographically sound tunnels and, most importantly, by implementing cryptographic mutual authentication. This far better ensures that both client and remote host are who they say they are and, by definition, breaks the password-based and MFA-bypass-based attacks that RDP alone is usually subject to. Right now, the only Mode in RDP-Armoring is a prototype SSH ---> RDP Mode that tunnels RDP — with no changes to an existing configuration — through an SSH tunnel created by hardened configurations on both ends. It is intended that more options will be available in the near future.

3. RDP-Armoring currently contains what you might call two "lockdown" measures you can enable that are designed to literally force any RDP access to a machine to go through a protective mode instead of happening directly. RDP-Armoring can, at your option, enable firewall rules to block all direct RDP access (TCP and UDP), and additionally tell the RDP listener to only listen for and allow RDP connections to come from an RDP-Armoring mode tunnel (over port forwarding and localhost). Note: Changing what this RDP listener listens to regarding inbound RDP connections is officially documented but has so little existing information widely available about it that I am currently labeling this "experimental".

4. Other features related to RDP security are in the works in various stages of development and internal testing but did not make the cut for this initial public testing release.

-------------------------------------

### Known Issues ###
[updated 04/08/2026]


- The RDP port firewall assessment widget still will sometimes err on the side of overestimating your RDP port/s degree of openness to incoming network traffic. In particular, currently:
   
  - (a) application-specific allow rules (which Windows loves to create and try to automatically re-enable if you disable them) are treated as ordinary port-open rules, because the widget does not currently examine application filters when assessing rules;
  - (b) if RDP is open to any inbound IPv6 traffic from anywhere the firewall widget may show a red alarm state claiming that RDP is open to traffic from the entire Internet.


- While RDPA is installing the OpenSSH Server using Windows Optional Features Manager, the process may appear to go abnormally slowly or hang, while also being stuck on a status of "assessing OpenSSH installed on the host" or similar. In reality, as long as the PowerShell install progress bar that should be showing in the background does not freeze for a long time, installation is in fact occurring.


- This Powershell-based software is currently not compatible with Constrained Language Mode. Add-Type is used in a number of places. CLM compatibility is important to me, but I made a decision that making it happen for the initial release would have delayed shipping too substantially to be worth it at this stage. I have actively tried to minimize use of non-compliant mechanisms, however, in hopes it will be reasonably achievable sooner rather than later.

- There remain numerous points where the UI needs some fixes and polishing. These are being dealt with over time.

- Certificate pinning functionality on the client to ensure the RDP server tunnel is strongly authenticated is still not included. Nor are any measures taken to suppress user-facing warnings about untrusted RDP connections. At some point I intend to introduce configurable options to deal with these. (The SSH tunnel still provides cryptographic mutual authentication.)

  See the pre-release updates file for more information on some of the planned features that haven't made public release yet.
