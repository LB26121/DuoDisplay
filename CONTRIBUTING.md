# Contributing

Thanks for helping! Code, comments, commits, issues and pull requests are in English.

## Ways to help

- **Test with two Macs.** Some features are only tested on one Mac (system gestures, edge switch, picture-in-picture, latency). See issues labelled [`needs-two-macs`](../../labels/needs-two-macs). A detailed report helps even without a fix.
- **Report bugs** with the bug report template.
- **Fix bugs or add features.** For anything bigger than a small fix, open an issue first to agree on the approach.

## Requirements

- Running: macOS 14+. Building: the **macOS 26 SDK** (Xcode 26 or its Command Line Tools), for Liquid Glass.
- With full Xcode, `build.sh` also recompiles the app icon from `Resources/AppIcon.icon`.
- End-to-end testing needs two Macs and a Thunderbolt cable; most code can be tested on one Mac.
- The virtual camera needs a paid Apple Developer account, see [README](README.md#virtual-camera).

## Build

```bash
./build.sh        # → build/DuoDisplay.app
swift build       # quick compile check
```

Ad-hoc builds lose their permissions on every rebuild. To avoid that, see [Signing](README.md#signing).

## Tests

The tests are built into the app:

```bash
APP=build/DuoDisplay.app/Contents/MacOS/DuoDisplay
$APP --inputtest      # input event serialization, media keys
$APP --pairtest       # pairing, authentication, encryption
$APP --edgetest       # edge detection, picture-in-picture geometry
$APP --transporttest  # network transport (~1 min)
$APP --mediatest      # audio, jitter buffer, camera path
$APP --selftest       # video pipeline over loopback
$APP --displaytest    # virtual display
```

Each prints `RESULT: OK` and exits 0 on success. CI requires the first four; the last three need hardware CI may lack, so run them locally when you touch video, media or display code. Add checks for new behaviour to the matching self-test (`SelfTest.swift`, `PairingSelfTest.swift`, `Media/MediaSelfTest.swift`, …).

## Code layout

| Path | Contents |
|---|---|
| `Sources/DuoDisplay/Sender` | Mac whose screen is shown: capture, encoding, input injection |
| `Sources/DuoDisplay/Receiver` | Mac that shows it: decoding, rendering, input capture |
| `Sources/DuoDisplay/Media` | sound, camera, microphone |
| `Sources/DuoDisplay/Common` | pairing, transport, encryption, shared models |
| `Sources/DuoDisplay/UI` | shared SwiftUI components, `--uisnapshot` (menu bar app: `App.swift`) |
| `Sources/DuoDisplayCamera` | camera system extension |
| `Sources/CGVirtualDisplayPrivate` | private `CGVirtualDisplay` API declarations |
| `Plugins/DuoDisplayMic` | Core Audio driver for the virtual microphone (C) |

## Guidelines

- **Latency is the core feature.** For changes to capture, encode, transport, decode or render, include before/after numbers from `--selftest` (and `--rendertest`).
- **Security matters.** Changes to pairing, encryption or input handling need an explanation and a test in `--pairtest` or `--inputtest`.
- **Private APIs:** keep them minimal and isolated; the app must degrade gracefully when they disappear.
- Match the surrounding style. Comments explain *why*, not *what*.
- One topic per pull request. Imperative commit messages ("Fix cursor jump on edge switch").
- Fill in the PR template and add user-visible changes to [CHANGELOG.md](CHANGELOG.md) under "Unreleased".

Contributions are licensed under the [MIT License](LICENSE) and follow the [Code of Conduct](CODE_OF_CONDUCT.md).
