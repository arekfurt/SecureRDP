SecureRDP — SSH + RDP Prototype Connection Package
===================================================

HOW TO CONNECT
--------------
1. Double-click Connect.cmd
   (or right-click Connect-SecureRDP.ps1 and choose "Run with PowerShell")

2. A progress window will appear while the secure tunnel is established.

3. Remote Desktop will launch automatically once the tunnel is ready.

4. On first use, you will be asked to install the server's RDP certificate
   into your personal trust store. This is a one-time step and prevents
   certificate warning dialogs on future connections.

5. When you close the RDP session, the tunnel is cleaned up automatically.


REQUIREMENTS
------------
- Windows 10 or Windows 11
- No installation required — all required files are in this package


!!!  SECURITY WARNING — READ BEFORE USING  !!!
-------------------------------------------------
This package contains an UNPROTECTED PRIVATE KEY FILE (client_key).

  • Anyone who obtains this package can connect to the server as:
    Account  : See config.json
    Server   : See config.json

  • Do NOT email this package or upload it to cloud storage.
  • Do NOT leave this package on shared, public, or untrusted machines.
  • Store it on an encrypted drive or password-protected archive.
  • If this package is lost or compromised, notify the server administrator
    immediately so a new package can be generated (which will revoke this one).

One package = one authorized user. Do not copy or share this package.


TROUBLESHOOTING
---------------
"Port 13389 is already in use"
  Another application is using local port 13389. Close it and try again.
  (Hint: check if another SecureRDP tunnel is already open.)

"Permission denied" at SSH step
  The server rejected the key. The authorized_keys on the server may have been
  changed, or a new package may have been generated (which revokes older ones).
  Request a fresh package from the server administrator.

"Connection refused" at SSH step
  The SSH service may not be running on the server, or port 22 may be blocked
  by a firewall. Contact the server administrator.

"The identity of the remote computer cannot be verified"
  If you declined the certificate install step, you will see this warning in
  mstsc. Run Connect.cmd again and accept the certificate prompt when offered.

Certificate warning appears but cert install was accepted
  This can happen if the server was reconfigured and a new certificate was
  issued. Request a new client package.


WHAT IS IN THIS PACKAGE
------------------------
  Connect.cmd                 Double-click launcher (Windows batch wrapper)
  Connect-SecureRDP.ps1       PowerShell tunnel launcher (main script)
  client_key                  *** PRIVATE SSH KEY — keep secure ***
  client_key.pub              SSH public key (not secret)
  known_hosts                 Server host key fingerprint (prevents MITM)
  connection.rdp              Remote Desktop connection file
  config.json                 Server address and connection settings
  ssh\ssh.exe                 SSH client binary
  ssh\ssh-keygen.exe          SSH key utility binary
  README.txt                  This file


ABOUT SECURERDP
---------------
SecureRDP is a prototype tool for replacing direct RDP exposure with an
SSH-tunnelled connection. This is a development/test prototype — not
a production security product.

GitHub: https://github.com/arekfurt/SecureRDP
Version: 0.821 - SSH + RDP Basic Prototype Mode
