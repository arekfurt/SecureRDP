03/31/2026 Update:

Launch day. :)

Go for main engine start.

Check back here this evening (EDT).


03/30/2026 Update:


Key end-to-end tests of essential functionality in core scenarios are passing. Now moving from debugging last breaking issues that I've personally found in core features into handling more of some fit & finish things. Tonight: more tests, more bug fixes, working on some basic documentation. Then working down the final public release build pre-launch checklist begins.
Come back tomorrow. :)


03/29/2026 Update:

Alas, won't ship today. Between ongoing bug hunting in UI wizards and Claude session limits progress is back to being a bit slower than I'd like. Hoping for tomorrow, but not going to push something that has enough problems with usability of core functionality that asking people to test and evaluate it would mean asking them to waste their time. 
On the good side, I am going to bring back into the initial release a couple of features that are near-core in significance and that I can get ready in the periods I'm waiting for my Claude session limits to reset.


03/28/2026 Update #2:

On track for initial public release either tomorrow or early in the work week. Decision on that will come tonight.


03/28/2026 Update:

At just before 7:00am EDT this morning the first real end-to-end test of Secure RDP SSH/RDP protection mode succeeded. 


03/27/2026

At the point where I have begun doing--or at least attempting--end-to-end tests of user flows. In other words, one flow might be starting the software-->evaluating & confirming what the dashboard says about current posture-->installing & configuring the SSH/RDP protection mode--->generating first client/user packages-->decrypting and running a package on client-->connecting-->actually using RDP to do stuff. (Also in other tests checking things like uninstall/revert mechanisms and post-install configuration & management options.)
So many, many bugs. [nervous, tired laugh] But at least we are now at the stage where it is productive to do such realistic testing at all.
If you're interested in when the initial public release will ship, watch this space in the coming few days. (Or my Twitter/X feed, if you like. Same user name as here.) The determiner will be when the end-to-end tests on my machines start going (basically) cleanly; I'll probably be posting 2-3 quick progress reports a day on that.  

 
03/26/2026 Update:

Have made the annoying decision to cut all on-by default RDP hardening from the SSH--RDP security mode that will power Secure RDP's RDP protection from the inital public release. In particular, it was, and remains, my aim that enforced RDP server authentication (meaning that if the RDP server certificate doesn't match what is expected clients will not connect; no choice by the client-side user involved) be put in place by default as part of the process that installs and configures the SSH--RDP security mode. (With RDP server auth being a defense-in-depth measure acting to backup the security of the outer SSH tunnel.) But trying to achieve this without requiring replacement of the server machinee's RDP certificates and without the client-side user being confronted with additional security warnings has proven to be a thorny problem. And I'm now reconsidering the desirability of replacing the existing RDP certs as standard proceedure.

Without that feature in there, for the sake of simplicity I've also decided to remove the functionality that turns NLA on (if it is off) from the default SSH mode install/setup flow. The initial public build will entirely leave the user's RDP connection security as it finds it by default. Which is not an entirely bad thing in a testing & early evaluation-focused build.

(As a reminder, the outer SSH tunnel does very much still do mutual cryptographic authentication using host and client keys. That is project-essential functionality.)

On the good side, I'm increasingly confident that first public build will be dropping... well, pretty darn soon.



03/24/2026 Update:

Got some decent refactoring, refactoring planning, and testing work done last night. And had intended to move today to conducting an almost-end-to-end type test that would reveal a lot about how just how much work remains to done on the client key/package generator before first public release. Still hopw to get that in before the night/early morning is out, but my limited availble time today so far has instead been mosly occupied by a security review of what I believe is the only portion of the project's code that could potentially be reachable with attacker-determnined input without authentication. It was a very small amount of cofe, but of course I wanted to thoughly scrutinize that obscure but but critical attack path. 

The irony, however? I had just tentatively concluded the code was very probably unexploitable and started to plan the intended  tessting and work for the day I had mentioned again when I happened to realize that the code I was looking at didnt actually achieve the aim the LLM said it would. At all.

So, this evening I removed both the code of original concern and the broader "feature" it implemented that actually would have turned out to be almost useless in context.



03-23/2026 Update #2:

It occurs to me that I should probably explain what is going to be in the first publicly shipping alpha/prototype version, which I've already designated as version 0.85. The key elements will be: 

-A dashboard, that combines RDP status and risk assessment information presentment with installation and management features for the "Modes" that will be used to protect RDP. 

-A prototype SSH --> RDP mode that employs an outer SSH tunnel that uses cryptographic mutual authentication to securely connect a client to the machine being accessed. 

-An accompanying client key creator/client package generator that produces an (optionally) passphrase-encrypted package that can be run in standard user mode on Windows machines. The package includes portable SSH binaries and a custom RDP connect file. The only installation required involves the user approving addition of the RDP server's leaf certificate to the user store to allow enforced auth of the RDP server without (hopefully) the user needing to see/deal with message box prompts.

Of note, other than RDP server certificate pinning being enforced there will be no required changes to how you use RDP itself. An initial goal is that whatever RDP setup you have in place can largely remain in place if you so choose. However, some RDP configurations may be more compatible with tunneling than others. (Also, currently I'm only pursuing compatibility with scenarios that have NLA on.)



03/23/2026 Project Update:

My intent coming into this just-finished weekend was to ship a first public alpha/preview build on Sunday. (And, against a voice in my head telling me I should err on the side of caution in what I publicly commit to, I made a statement to that effect on Twitter.) It did seem like a reasonable expectation in some ways. The prototype was feature locked, all necessary functionality was in place, some important tests were passing, etc. All that seemed left to do was to test wnd debug the actual UI/combined user experience of using the progrem.

If you are acquainted with writing Powershell GUI programs, you are probably laughing at me right now. (No offense taken.)
I learned some hard lessons about how difficult debugging Powershell GUI code can be, especially if you are using LLMs which are not particularly adept at writing complex Powershell elements to produce said code in the first place.

I managed to debug the main dashboard experience enough to get it reliably loading and showing current RDP/etc. security state. Aftet a good bit of storm and stress. However, on getting to the key and carefully specced out SSH + RDP install and initial configuration script (plus accompanying modules/pfunctions) it became clear that getting it working was going to be a massive and legthy debugging mess. At best. At worst, getting it working reliably may have been beyond the realm of my skills and the amount of time I can devote to this.

Anyway, it became apparent to me that I needed to rebuild/refactor that 2000 line component entirely. Breaking things down into the smallest chunks reasonably possible, making sure different components have contract/agreed upon ways to exchange information, etc. So that is what I have begun to do, in earnest. To show that this project is indeed alive and being concertedly worked on. I will put updates about the pre-initial preview release (version .85) here about every day or two. I'm not going to make the mistake of projecting exactly when the initial release will ship until basically it is ready and Im just writing documentation. But my hope is certainly that we are talking a matter of days.


--------------------------------

Testable prototype coming soon.
