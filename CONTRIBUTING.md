# Contributing to DuoDisplay

Thanks for helping out! DuoDisplay turns one Mac into a low-latency second display for another
Mac over Thunderbolt, and shares sound, camera and microphone between them. This guide covers
what you need to build, test and send changes.

The user-facing [README](README.md) is currently in German. Code, comments, commit messages,
issues and pull requests are in English. Issues in German are welcome too.

## Ways to help

- **Test with real hardware.** Some features have only been checked on a single Mac. Issues
  labelled [`needs-two-macs`](../../labels/needs-two-macs) list them: system gestures, the edge
  switch, picture-in-picture, and latency between two machines. A detailed report helps even
  without a fix.
- **Report bugs** with the bug report template. It asks for the details we need.
- **Fix bugs or add features.** For anything bigger than a small fix, please open an issue first
  so we can agree on the approach before you put time into it.
- **Translate the README** into English (`README.md`, German moves to `README.de.md`).

## Requirements

- macOS 14 or newer to run. Building needs the **macOS 26 SDK** (Xcode 26 or its Command Line
  Tools) because the UI uses Liquid Glass when available.
- The Command Line Tools are enough (`xcode-select --install`). With full Xcode, `build.sh` also
  recompiles the app icon from `Resources/AppIcon.icon`.
- For end-to-end testing: two Macs and a Thunderbolt cable. Most of the code can be worked on
  and tested with one Mac (see below).
- For the **virtual camera** only: a paid Apple Developer account, because macOS refuses system
  extensions from apps that are not provisioned. Sound and microphone work without it. See
  “Virtuelle Kamera” in the README.

## Building

```bash
./build.sh
```

This produces `build/DuoDisplay.app`. Without any signing setup it is signed ad-hoc, which means
macOS asks for the Accessibility and Screen Recording permissions again after every rebuild. To
avoid that, create the local signing identity described under “Signatur” in the README, or pass
your own certificate with `SIGN_IDENTITY="Apple Development: …" ./build.sh`.

For quick compile checks while editing, `swift build` is enough.

## Tests

The tests are built into the app and selected with a command-line flag:

```bash
APP=build/DuoDisplay.app/Contents/MacOS/DuoDisplay
$APP --inputtest      # input event serialization, media keys
$APP --pairtest       # pairing, authentication, encryption of control and media channels
$APP --edgetest       # edge detection and entry points, picture-in-picture geometry
$APP --transporttest  # network transport, encrypted vs. unencrypted (~1 min)
$APP --mediatest      # audio packets, jitter buffer with clock drift, camera path, playback
$APP --selftest       # whole video pipeline over loopback, including packet loss
$APP --displaytest    # virtual display: HiDPI mode and placement
```

Each prints `ERGEBNIS: OK` and exits with status 0 on success. The README lists further tests
that open windows or move the pointer (`--piptest`, `--rendertest --window`, `--uisnapshot`).

CI runs the first four on every pull request. The last three need a hardware video encoder, audio
devices or a window server, so CI runs them on a best-effort basis. Please run them locally when
you touch the video, media or display code.

When you add behaviour that can be checked without a second Mac, add a check to the matching
self-test (`SelfTest.swift`, `PairingSelfTest.swift`, `Media/MediaSelfTest.swift`, …).

## Code layout

| Path | What's there |
|---|---|
| `Sources/DuoDisplay/Sender` | the Mac whose screen is shown: capture, encoding, input injection |
| `Sources/DuoDisplay/Receiver` | the Mac that shows it: decoding, rendering, input capture |
| `Sources/DuoDisplay/Media` | sound, camera and microphone streams |
| `Sources/DuoDisplay/Common` | pairing, transport, encryption, shared models |
| `Sources/DuoDisplay/UI` | shared SwiftUI components and `--uisnapshot`; each side's window is in `Sender`/`Receiver`, the menu bar app in `App.swift` |
| `Sources/DuoDisplayCamera` | Core Media I/O camera system extension |
| `Sources/CGVirtualDisplayPrivate` | declarations for Apple's private `CGVirtualDisplay` API |
| `Plugins/DuoDisplayMic` | Core Audio driver for the virtual microphone (C) |

“Wie es funktioniert” in the README explains the data flow and the latency budget.

## Guidelines

- **Latency is the core feature.** For changes in the capture, encode, transport, decode or
  render path, include before/after numbers from `--selftest` (and `--rendertest` if rendering
  changed) in the pull request.
- **Security matters.** The app injects input, captures the screen and talks over the network.
  Changes to pairing, encryption or input handling need a clear explanation and a test in
  `--pairtest` or `--inputtest`. Report vulnerabilities privately, see [SECURITY.md](SECURITY.md).
- **Private APIs:** keep their use minimal and isolated, and make the app degrade gracefully
  when they are missing after a macOS update.
- Follow the style of the surrounding code. Keep comments in English and explain *why*, not
  *what*.
- Keep pull requests focused: one topic per pull request.

## Commits and pull requests

- Write commit messages in the imperative (“Fix cursor jump on edge switch”), with a short
  summary line and, if needed, a body explaining why.
- Fill in the pull request template, including which tests you ran and on which Macs.
- Add a line to the “Unreleased” section of [CHANGELOG.md](CHANGELOG.md) for user-visible
  changes.

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE),
and you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
