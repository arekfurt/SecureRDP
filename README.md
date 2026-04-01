
Files incoming. Standby...

## Known Issues ##

While installing OpenSSH Server using Windows Optional Features manager, the process may appear to go abnormally slowly or hang, while also being stuck on a status of "assessing OpenSSH installed on the host" or such. In reality, as long as the PS install progress bar that should be showing in the background does not freeze for a long time installation is in fact occurring.
The RDP port firewall assessment widget, in its current design, may err on the side of overestimating your RDP port/s degree of openness to incoming network traffic. Especially if you have many precise rules affecting that exposure.
If RDP is open to IPv6 traffic from anywhere else the current code of the firewall widget may show a red alarm state claiming that RDP is open to traffic from anywhere on the Internet.
The initial public build does not contain certificate pinning functionality on the client to ensure the server is strongly authenticated, nor to suppress user-facing warnings about untrusted RDP connections. Both are high priorities, but the SecureRDP implementations needed to be held back for more consideration.
See the pre-release updates file for more info on planned features that did not quite make the first public build.




