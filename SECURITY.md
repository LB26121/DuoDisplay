# Security Policy

DuoDisplay captures the screen, injects input and streams audio, camera and microphone between two Macs, so vulnerabilities can be serious.

## Reporting

**Don't open a public issue.** Use *Security* → *Report a vulnerability* on GitHub and include:

- what an attacker can do, and from where (same network, Thunderbolt, local user, …)
- steps to reproduce or a proof of concept
- DuoDisplay version or commit and macOS versions

You'll get a reply within a week, updates on the fix and, if you like, credit in the release notes.

## Scope

- pairing, authentication and re-pairing
- encryption of the control channel and UDP media (AES-GCM)
- input forwarding and injection
- the camera system extension and microphone driver
- anything letting a third device connect, inject input or read streams

The design is described in [Pairing and security](README.md#pairing-and-security). Fixes go into the latest release only.
