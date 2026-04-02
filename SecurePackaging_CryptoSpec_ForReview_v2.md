# SecureRDP Secure Packaging — Cryptographic Design Specification
## Draft v2 — April 2026
## For External Security Review

---

## 1. Problem Statement

SecureRDP generates client connection packages containing SSH private
keys, server identity material, and connection scripts. These packages
must be delivered from a server administrator to remote users. The
system must protect key material:

- In transit (package delivery via email, file share, USB, etc.)
- At rest on the server (stored passphrases for admin recall)
- At rest on the client (extracted private key on disk)

The system targets Windows environments running PowerShell 5.1 /
.NET Framework 4.x. No external cryptographic libraries are used —
all primitives are from System.Security.Cryptography.

---

## 2. Threat Model

### In Scope

- Accidental exposure: keys caught in logs, backups, file shares,
  troubleshooting dumps, screenshot captures
- Commodity attackers: malware scanning for key files by name/pattern,
  opportunistic access to shared folders
- Offline disk access: stolen laptop, disk imaged on different hardware
- Log forwarding exposure: PowerShell Module Logging, Script Block
  Logging, and Transcription forwarded to centralized SIEM systems
- Casual package interception: package obtained without the passphrase

### Out of Scope

- Attacker with code execution as the same user on the target machine
  (can derive machine-binding keys via the same code paths)
- Admin-level attacker on either server or client
- State-level adversaries / targeted attacks on cryptographic primitives
- Side-channel attacks on the host machine

### Accepted Limitations

- Client-side key protection uses machine-derived binding keys. An
  attacker who can run code as the user can replicate the derivation.
  This is a deliberate usability tradeoff — no passphrase entry is
  required for routine connections.
- Server-side passphrase storage uses the same class of machine-derived
  keys. An attacker with access to the machine-level registry and
  knowledge of the derivation scheme can decrypt stored passphrases.
  This is consistent with the threat model: such an attacker already
  has admin access to the server.

---

## 3. Transport Encryption (Package Delivery)

### 3.1 Passphrase Generation

Passphrases are generated using the diceware method: 6 words selected
independently from the EFF large wordlist (7,776 words).

Entropy: log2(7776^6) = ~77.5 bits.

Word selection uses cryptographically secure random indices via
System.Security.Cryptography.RandomNumberGenerator with rejection
sampling to eliminate modulo bias.

User-chosen passphrases are not permitted. The system enforces
generated passphrases only.

The passphrase is delivered to the recipient via a separate channel
from the encrypted package (out-of-band delivery).

### 3.2 Encryption Scheme

```
Algorithm:    AES-256-CBC with PKCS7 padding
Key derivation: PBKDF2-HMAC-SHA256
  - Input:      UTF-8 encoded passphrase
  - Salt:       32 bytes, cryptographically random, per-package
  - Iterations: 600,000
  - Output:     64 bytes
  - Split:      bytes[0..31] = AES encryption key
                bytes[32..63] = HMAC authentication key
Authentication: HMAC-SHA256 (encrypt-then-MAC)
  - Key:        HMAC key from PBKDF2 output
  - Input:      header bytes (magic + version + salt + IV) ||
                ciphertext bytes
  - Output:     32-byte authentication tag
```

### 3.3 Wire Format

```
Offset  Length  Field
0       4       Magic: 0x53524450 ("SRDP")
4       4       Version: 0x00000002 (big-endian)
8       32      PBKDF2 salt
40      16      AES-CBC initialization vector
56      32      HMAC-SHA256 authentication tag
88      ...     AES-256-CBC ciphertext
```

Minimum valid blob: 104 bytes (88 header/tag + 16 minimum ciphertext).

Big-endian encoding verified in implementation: version bytes are
written as 0x00, 0x00, 0x00, 0x02 and read via big-endian shift
reconstruction.

### 3.4 Decryption and Verification

Authenticate-then-decrypt:

1. Validate magic bytes and version field.
2. Extract salt, IV, stored HMAC tag, and ciphertext from fixed offsets.
3. Re-derive 64-byte master key via PBKDF2 with identical parameters.
4. Recompute HMAC-SHA256 over header + ciphertext.
5. Constant-time comparison of computed tag vs stored tag (bitwise OR
   accumulator over all 32 bytes — no early exit).
6. If tags do not match: reject. No decryption is attempted.
7. If tags match: decrypt ciphertext with AES-256-CBC.

### 3.5 Plaintext Structure

The plaintext is a standard ZIP archive containing the client
connection files (SSH private key, public key, server configuration,
host key verification data, connection scripts).

---

## 4. Server-Side Passphrase Storage

### 4.1 Purpose

Allows the administrator to retrieve a previously generated passphrase
if the administrator or the client user loses it.

### 4.2 Storage Key Derivation

```
Components:
  - Random salt:   32 bytes, generated on first use, stored in
                   machine-level registry (HKLM), requires admin
                   elevation to write, readable by any admin account
  - Machine SID:   Windows machine security identifier
  - Machine GUID:  Per-installation GUID from system registry
  - Processor ID:  CPU identifier string

Derivation:
  PBKDF2-HMAC-SHA256(
    password   = UTF-8( MachineSID || MachineGuid || ProcessorId ),
    salt       = random salt bytes,
    iterations = 600,000,
    output     = 32 bytes (AES-256 key)
  )
```

The random salt provides secrecy — it is unguessable even if an
attacker knows all three machine property values. The machine
properties provide binding — the salt alone is useless on a
different machine. Neither component alone is sufficient.

The salt is stored in HKLM (machine-level, admin-accessible) rather
than HKCU (per-user) so that any administrator account on the server
can derive the same storage key. This is necessary for multi-admin
environments where different admins may create packages at different
times and any admin may need to retrieve any passphrase.

### 4.3 Per-Entry Encryption

```
For each stored passphrase:
  IV         = 16 bytes, cryptographically random, unique per entry
  Ciphertext = AES-256-CBC( storage key, IV, UTF-8(passphrase) )
  Stored     = Base64( IV || Ciphertext )
```

Entry metadata (creation date, label, server address) is stored in
plaintext alongside the encrypted passphrase — metadata contains no
secret material.

### 4.4 Security Properties

- Storage key cannot be derived without access to both the HKLM
  registry salt and the machine's hardware/identity values.
- Each passphrase entry uses a unique IV (no IV reuse across entries).
- Compromise of the storage file without the registry salt yields only
  encrypted blobs.
- Compromise of the registry salt without the storage file yields no
  passphrases.
- Any admin account on the server can access the store (HKLM is shared
  across admin accounts; HKCU is not).

---

## 5. Client-Side Private Key Protection

### 5.1 Purpose

After the encrypted package is decrypted and extracted on the client
machine, the SSH private key is re-encrypted using a machine-derived
key. This binds the key to the specific machine without requiring
passphrase entry on subsequent connections.

### 5.2 Binding Key Derivation

Identical derivation pattern to server-side storage key (Section 4.2),
but with an independently generated salt stored in a separate registry
location on the client machine. The client salt is stored in HKCU
(user-level) because the client does not run with admin elevation.

```
Components:
  - Random salt:   32 bytes, generated on first extraction, stored
                   in user-level registry (HKCU) on the client
  - Machine SID:   Client machine's SID
  - Machine GUID:  Client machine's per-installation GUID
  - Processor ID:  Client machine's CPU identifier

Derivation:
  PBKDF2-HMAC-SHA256(
    password   = UTF-8( MachineSID || MachineGuid || ProcessorId ),
    salt       = random salt bytes,
    iterations = 600,000,
    output     = 32 bytes (AES-256 key)
  )
```

### 5.3 Key Protection at Rest

```
After extraction:
  1. Read plaintext private key file.
  2. Derive machine-binding key.
  3. Generate 16-byte random IV.
  4. Encrypt: AES-256-CBC( binding key, IV, key bytes )
  5. Write: encrypted key file = IV || ciphertext
  6. Delete plaintext key file.

At connection time:
  1. Derive machine-binding key (same derivation).
  2. Read encrypted key file.
  3. Decrypt to temporary file with restrictive ACLs.
  4. Use temporary key file for SSH authentication.
  5. Delete temporary file immediately after use.
```

### 5.4 Security Properties

- Key file is unusable on a different machine (different machine
  values produce a different binding key).
- Key file is not readable as plaintext from a disk image read on
  different hardware.
- No passphrase entry required for routine connections.
- If the registry salt is lost (deleted, machine reimaged), the
  binding key cannot be reconstructed. The user must re-extract from
  the original encrypted package using the transport passphrase, or
  request a new package.

---

## 6. Passphrase Handling in Code

The passphrase string is treated as sensitive throughout its lifecycle:

1. Generated as a plain string for display to the administrator only.
2. Immediately converted to a SecureString container after display.
   SecureString is opaque to PowerShell's logging infrastructure
   (Module Logging, Script Block Logging, Transcription).
3. When raw bytes are needed for cryptographic operations, a brief
   extraction is performed within a try/finally block. The extracted
   BSTR memory is zeroed in the finally clause.
4. The passphrase is never passed as a named string parameter to any
   function. This prevents capture by Module Logging, which records
   function parameter names and values.
5. Variable bindings holding the plaintext string are removed after
   conversion to SecureString. Note: this is a hygiene measure — it
   removes the variable reference but does not guarantee the underlying
   string object is zeroed from managed memory before garbage collection.
   The primary protection is architectural (items 2-4 above), not
   memory-level.
6. Internal logging never includes passphrase values. Retrieval
   operations are logged (who, when, which label) but content is not.

---

## 7. Primitive Summary

| Use Case                | Cipher      | KDF                  | Auth         | Key Bits | Iterations |
|--------------------------|-------------|----------------------|--------------|----------|------------|
| Transport encryption     | AES-256-CBC | PBKDF2-HMAC-SHA256   | HMAC-SHA256  | 256      | 600,000    |
| Passphrase storage       | AES-256-CBC | PBKDF2-HMAC-SHA256   | (implicit)   | 256      | 600,000    |
| Client key at-rest       | AES-256-CBC | PBKDF2-HMAC-SHA256   | (implicit)   | 256      | 600,000    |

All random material: System.Security.Cryptography.RandomNumberGenerator.
All PBKDF2: System.Security.Cryptography.Rfc2898DeriveBytes with
SHA-256 hash algorithm.

---

## 8. Known Limitations and Future Considerations

1. **No authenticated encryption for storage/key-protection layers.**
   Sections 4 and 5 use AES-256-CBC without a separate MAC. Tampering
   with the ciphertext would produce garbage plaintext rather than a
   clean authentication failure. Acceptable for the current threat
   model (attacker who can modify the ciphertext already has registry
   access and can derive the key). AES-GCM or an explicit HMAC could
   be added if the threat model expands.

2. **Machine-binding values are discoverable.** MachineSID, MachineGuid,
   and ProcessorId can be read by any process running as the user. The
   security of Sections 4 and 5 rests on the random salt, not on the
   secrecy of the machine values. The machine values provide binding
   (portability resistance), not secrecy.

3. **ProcessorId in virtual machines.** VM hypervisors frequently return
   static, predictable, or zeroed values for the CPU identifier. When
   ProcessorId is empty or constant across VMs, it contributes zero
   entropy to the key derivation. The effective binding inputs become
   MachineSID + MachineGuid only. This is acceptable: the random salt
   provides secrecy, and MachineSID + MachineGuid are reliable and
   unique in properly provisioned VMs (post-sysprep). ProcessorId adds
   value on physical hardware but should not be relied upon as a
   meaningful entropy source in virtualized environments.

4. **SecureString uses DPAPI internally.** We use SecureString solely
   as a logging-opaque container, not for its encryption properties.
   DPAPI's known weaknesses do not affect our security model.

5. **PBKDF2 iteration count.** 600,000 iterations is consistent with
   current (2025-2026) OWASP recommendations for PBKDF2-HMAC-SHA256.
   Should be reviewed periodically as hardware improves. A version
   field in the blob format allows future increases without breaking
   backward compatibility.

6. **No AES-GCM.** .NET Framework 4.x (PowerShell 5.1) does not
   expose AES-GCM via the managed API. AES-CBC with PKCS7 + separate
   HMAC-SHA256 (encrypt-then-MAC) is used for transport encryption.
   This is a well-established construction with equivalent security
   properties when correctly implemented.

7. **Remove-Variable is not a security operation.** Removing a variable
   binding in PowerShell does not zero the underlying string from
   managed memory. The string may persist until garbage collection.
   The architecture is designed so that the plaintext passphrase never
   reaches a logging-visible code path regardless of GC timing.

8. **Phased deployment.** Transport encryption (passphrase-protected
   archives) ships in the initial release. Client-side machine-binding
   key protection ships in a subsequent release. Between these releases,
   the extracted private key exists as a plaintext file on the client
   machine after first use. This is an explicit, documented gap — not
   an oversight. The transport encryption is the primary security
   improvement; at-rest key protection is an enhancement.
