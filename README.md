# RDP Armoring (RDPA) testing/dev/alpha release - Version 0.86 #
#### Released: April 7, 2026 ####

## Getting Started + An Important Notice ##
To get started:
On a Windows 10 or 11 test machine (Pro SKU or above) that will act as the RDP server that you want to enable more secure access to, unzip the RDP-Armoring archive and find the file ServerWizard.ps1 in the root of the folder. Right-click on it, click "Run with PowerShell", and make your way through the expected security dialogs. You'll see a welcome screen on first launch, and then you'll be taken to the main status dashboard. Clicking the Quick Start tile on the left will launch a wizard that will walk you through the process of installing and configuring needed SSH server components and generating your first client key and connection package. Move the client package zip archive via some appropriate means (it contains an unencrypted private key) to a test client machine, extract and open the folder, and double-click the Connect.cmd file to start the SSH--RDP connection.

(Note: A feature that uses a passphrase-encrypted archive to protect the client private key in transit will ship very shortly.)

### Notice: ###

I'm happy to have the interest of anyone thinking of trying out RDP-Armoring v0.851, but before you actually do please understand the following:

This first release is primarily intended for folks who want to help me find breaking bugs (I'm one guy, without access to a serious enterprise testing environment that I can use for personal projects) and those who want to give me feedback at an early phase in the software's life (when that feedback can have the most impact). It is not intended for day-to-day use at this point. If you try it, you will find bugs. It is only about the severity of the bugs, and whether they are already on the list of the project's Known Issues for v0.851. (Please check that before filing bug reports in the Issues area.)

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
[updated 04/04/2026]


- The RDP port firewall assessment widget, in its current design, will often err on the side of overestimating your RDP port/s degree of openness to incoming network traffic. In particular, currently:

  - (a) block rules don't subtract from allow rule exposure as long as those allow rules remain enabled;
  - (b) application-specific allow rules (which Windows loves to create and try to automatically re-enable if you disable them) are treated as ordinary port-open rules, because the widget does not currently examine application filters when assessing rules;
  - (c) if RDP is open to any inbound IPv6 traffic from anywhere the firewall widget may show a red alarm state claiming that RDP is open to traffic from the entire Internet.

  These shortcomings will be systematically addressed in future builds in the coming weeks.

- While installing OpenSSH Server using Windows Optional Features Manager, the process may appear to go abnormally slowly or hang, while also being stuck on a status of "assessing OpenSSH installed on the host" or similar. In reality, as long as the PowerShell install progress bar that should be showing in the background does not freeze for a long time, installation is in fact occurring.

- After you create a new client key and package, the center SSH mode tile on the dashboard may still show an error message in red saying that it can't find any authorized keys. Click the Manage button to be taken to the SSH mode management page and confirm whether the key has actually been created.

- Version 0.851 is not compatible with Constrained Language Mode. Add-Type is currently used in a number of places. CLM compatibility is important to me, but I made a decision that making it happen for the initial release would have delayed shipping too substantially to be worth it at this stage. I have actively tried to minimize use of non-compliant mechanisms, however, in hopes it will be reasonably achievable sooner rather than later.

- There are, not surprisingly, numerous points where the UI needs some fixes and polishing.

- The initial public build does not contain certificate pinning functionality on the client to ensure the RDP server tunnel is strongly authenticated, nor to suppress user-facing warnings about untrusted RDP connections. Both are high priorities, but the RDP-Armoring implementations needed to be held back for more consideration. (The SSH tunnel still provides cryptographic mutual authentication.)

  See the pre-release updates file for more information on planned features that did not quite make the first public build.
