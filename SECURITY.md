# Security Policy

DuoDisplay captures the screen, injects keyboard and pointer input, and streams audio, camera
and microphone data between two paired Macs. Vulnerabilities can therefore be serious, and we
are grateful for responsible reports.

## Reporting a vulnerability

**Please do not open a public issue.** Instead use GitHub's private reporting:
*Security* tab → *Report a vulnerability*.

Please include:

- what an attacker can do, and from where (same network, Thunderbolt link, local user, …)
- steps to reproduce or a proof of concept
- the DuoDisplay version or commit, and the macOS versions involved

You can expect a first reply within a week. We will keep you informed about the fix and, if you
like, credit you in the release notes.

## Scope

Particularly relevant areas:

- pairing and authentication between the two Macs, including re-pairing
- encryption of the control channel and of the UDP media streams (AES-GCM)
- forwarded input events and the input injection on the receiving Mac
- the virtual camera system extension and the Core Audio microphone driver
- anything that lets a third device on the network connect, inject input or read the stream

“Kopplung und Sicherheit” in the README describes the design.

## Supported versions

Security fixes go into the latest release only.
