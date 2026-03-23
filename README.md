

03-23/2026 Update #2:

It occurs to me that I should probably explain what is going to be in the first publicly shipping alpha/prototype version, which I've already designated as version 0.85. The key elements will be: 

-A dashboard, that combines RDP status and risk assessment information presentment with installation and management features for the "Modes" that will be used to protect RDP. 
-A prototype SSH --> RDP mode that employs an outer SSH tunnel that uses cryptographic mutual authentication to securely connect a client to the machine being accessed. 
-An accompanying client key creator/client package generator that produces an (optionally) passphrase-encrypted package that can be run in standard user mode on Windows machines. The package includes portable SSH binaries and a custom RDP connect file. The only installation required involves the user approving addition of the RDP server's leaf certificate to the user store to allow enforced auth of the RDP server without (hopefully) the user needing to see/deal with message box prompts.

Of note, other than RDP server certificate pinning being enforced there will be no necessary changes to how you use RDP itself. Whatever setup you have in place can remain in place. (However, currently I'm only pursuing compatibility with scenarios that have NLA on.)


03/23/2026 Project Update:

My intent coming into this just-finished weekend was to ship a first public alpha/preview build on Sunday. (And, against a voice in my head telling me I should err on the side of caution in what I publicly commit to, I made a statement to that effect on Twitter.) It did seem like a reasonable expectation in some ways. The prototype was feature locked, all necessary functionality was in place, some important tests were passing, etc. All that seemed left to do was to test wnd debug the actual UI/combined user experience of using the progrem.

If you are acquainted with writing Powershell GUI programs, you are probably laughing at me right now. (No offense taken.)
I learned some hard lessons about how difficult debugging Powershell GUI code can be, especially if you are using LLMs which are not particularly adept at writing complex Powershell elements to produce said code in the first place.

I managed to debug the main dashboard experience enough to get it reliably loading and showing current RDP/etc. security state. Aftet a good bit of storm and stress. However, on getting to the key and carefully specced out SSH + RDP install and initial configuration script (plus accompanying modules/pfunctions) it became clear that getting it working was going to be a massive and legthy debugging mess. At best. At worst, getting it working reliably may have been beyond the realm of my skills and the amount of time I can devote to this.

Anyway, it became apparent to me that I needed to rebuild/refactor that 2000 line component entirely. Breaking things down into the smallest chunks reasonably possible, making sure different components have contract/agreed upon ways to exchange information, etc. So that is what I have begun to do, in earnest. To show that this project is indeed alive and being concertedly worked on. I will put updates about the pre-initial preview release (version .85) here about every day or two. I'm not going to make the mistake of projecting exactly when the initial release will ship until basically it is ready and Im just writing documentation. But my hope is certainly that we are talking a matter of days.


--------------------------------

Testable prototype coming soon.
