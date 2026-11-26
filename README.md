# DuoDisplay

Use one Mac as a low-latency second display for another, connected by a **Thunderbolt cable**.

- **⌃⌥⌘D** switches modes at any time.
- **⌃⌥⌘P** shows the MacBook screen as picture-in-picture on the iMac.

Example setup: MacBook on the left, iMac on the right, keyboard and trackpad on the iMac.

| Mode | iMac shows | iMac keyboard and trackpad control |
|---|---|---|
| **Second Display** | an extra display of the MacBook | the MacBook, including gestures |
| **Normal Use** | its own desktop | the iMac. Push the pointer past the left edge to control the MacBook, past the MacBook's right edge to come back |

In Second Display mode the MacBook's **sound** plays on the iMac. The MacBook also gets two new devices, **iMac Camera (DuoDisplay)** and **iMac Microphone (DuoDisplay)**, for FaceTime, Zoom, Teams etc. They only run while an app uses them.

The same app runs on both Macs. It lives in the menu bar and appears in the Dock only while its window is open.

## Build

Needs macOS 14+ and the Command Line Tools (Xcode optional):

```bash
./build.sh
```

Copy `build/DuoDisplay.app` to `/Applications` on both Macs. If macOS blocks it on the second Mac ("unverified developer"):

```bash
xattr -dr com.apple.quarantine /Applications/DuoDisplay.app
```

## Setup (once)

1. **Cable:** Connect both Macs with a Thunderbolt 3/4/5 or USB4 cable. Recommended on both: System Settings → Network → Thunderbolt Bridge → Details → Hardware → Configure *Manually*, MTU *Jumbo (9000)*.
2. **Turn off Universal Control** on both Macs (System Settings → Displays → Advanced), otherwise both react at the same screen edge.
3. **iMac:** open DuoDisplay → *Use as Display*.
4. **MacBook:** open DuoDisplay → *Extend Display*, set *iMac position* to *Right*, click **Connect** next to the iMac.
5. **Pair:** both Macs show a 6-digit code. If they match, click **Pair** on both. From now on the MacBook connects automatically (in *Normal Use*). A Mac that is already paired refuses new pairings: *Unpair* it first.
6. **Microphone** (MacBook): *Sound, Camera & Microphone* → *iMac Microphone* → **Install…** (asks for an admin password).
7. **Camera** (MacBook): *iMac Camera* → **Activate…**, then allow it in System Settings → General → Login Items & Extensions → Camera Extensions. Requires an Apple Developer signature, see [Virtual camera](#virtual-camera).
8. **iMac:** under *Camera & Microphone for the MacBook*, allow camera and microphone.

**Uninstall the microphone driver:**

```bash
sudo rm -rf /Library/Audio/Plug-Ins/HAL/DuoDisplayMic.driver && sudo killall coreaudiod
```

The camera extension is removed when you move DuoDisplay to the Trash.

### Permissions

| Mac | Permission | Used for |
|---|---|---|
| both | Local Network | connection over Thunderbolt |
| both | Accessibility | iMac: capture input · MacBook: inject input, track pointer |
| MacBook | Screen & System Audio Recording | capture the extra display |
| MacBook | System Audio Recording Only | send sound to the iMac |
| MacBook | Camera | feed the virtual iMac camera |
| iMac | Camera, Microphone | send them to the MacBook |

The app shows what is missing and offers a button to grant it.

### Signing

`build.sh` creates a self-signed certificate, **DuoDisplay Local Signing**, so permissions survive rebuilds. It lives in its own keychain (`~/Library/Keychains/duodisplay-signing.keychain-db`), whose password is in `~/Library/Application Support/DuoDisplay/`. Gatekeeper still treats the app as unverified.

- Remove: `security delete-keychain ~/Library/Keychains/duodisplay-signing.keychain-db` and delete `~/Library/Application Support/DuoDisplay`.
- Use your own certificate: `SIGN_IDENTITY="Apple Development: …" ./build.sh`.

### Virtual camera

The iMac camera is a system extension, which macOS only activates in apps signed with an Apple certificate **and** provisioning profiles (paid Apple Developer account). Sound and microphone work without it.

1. **Certificate:** Xcode → Settings → Accounts → your team → *Manage Certificates…* → **+** → *Apple Development*. Check with `security find-identity -v -p codesigning`.
2. **Register both Macs** under Certificates, IDs & Profiles → Devices. Get the ID with `system_profiler SPHardwareDataType | grep "Provisioning UDID"`.
3. **Two App IDs:** `local.duodisplay.DuoDisplay` with *System Extension*, `local.duodisplay.DuoDisplay.CameraExtension` with *App Groups*.
4. **Two profiles** (*macOS App Development*), one per App ID, with your certificate and both Macs.
5. **Build:**
   ```bash
   SIGN_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)" \
   APP_PROFILE=~/Downloads/DuoDisplay.provisionprofile \
   CAMERA_PROFILE=~/Downloads/DuoDisplayCamera.provisionprofile \
   ./build.sh
   ```
   Or save the profiles as `DuoDisplay_Development.provisionprofile` and `DuoDisplay_Camera_Development.provisionprofile` in `~/Library/Application Support/DuoDisplay/apple-dev/` and just run `./build.sh`. If Apple rejects the bundle ID, use your own (`BUNDLE_ID=com.yourname.DuoDisplay`) and adjust the App IDs.
6. Copy the app to `/Applications` on both Macs and click *iMac Camera* → *Activate…* on the MacBook. macOS asks for all permissions once more.

## Usage

- **⌃⌥⌘D** (on either Mac, the menu bar icon or the window) switches modes. On the iMac it is never forwarded, so it always gets you out, even if the MacBook hangs. If the connection drops, the iMac gets its input back immediately.
- **Second Display:** all iMac input goes to the MacBook: clicks, scrolling, gestures, ⌘-Tab, media keys. Volume keys control the iMac while its speakers play the MacBook's sound. Switching back moves the extra display's windows to the MacBook.
- **Edge switch (Normal Use):** push the pointer past the iMac's edge and it appears on the MacBook at the same height. A small resistance (6 pt) prevents accidental switches; while a button is held the pointer stays put. Mirrored if the iMac is on the left. ⌃⌥⌘D, or 1.5 s without reply from the MacBook, returns control to the iMac.
- **Picture-in-picture (⌃⌥⌘P):** a floating window on the iMac shows the MacBook screen, either *Mirrored* or *Extended* (an extra display). Move the pointer into the window to control the MacBook, out past any edge to return. Drag the title bar to move, the edges to resize. The iMac remembers position, size and whether it was open.
- **Settings** on the MacBook (codec, resolution, frame rate, bitrate, pointer) apply immediately.
  - **Codec:** *ProRes* (default) is fastest but needs ~250–600 Mbit/s, i.e. Thunderbolt with Jumbo MTU. Otherwise DuoDisplay falls back to *HEVC*: far less data, ~4 ms slower.
  - **Frame rate:** *Match iMac* (60 Hz) by default. 120 Hz saves a few ms but doubles the MacBook's work.
  - **Resolution** steps down automatically (2× → 1.5× → 1×) if the encoder can't keep up.
  - **Draw pointer locally** (default): the iMac draws the pointer itself, so it moves with network latency (<1 ms) instead of video latency.
- **Video calls on the MacBook:** choose *iMac Camera (DuoDisplay)* and *iMac Microphone (DuoDisplay)*. The camera works in both modes while the Macs are paired.

## Latency

Measured on an M4 with `--selftest` (frame → decoded):

| Resolution | Encoder | Frame → decoded |
|---|---|---|
| Retina 2×, **ProRes** (default) | 4.5 ms | ~7 ms |
| Retina 2×, HEVC | 7.6 ms | ~11 ms |
| Balanced 1.5× | 5.1 ms | ~7 ms |
| Fast 1× @120 Hz | 2.9 ms | ~4.4 ms |

Add screen capture and up to one display refresh (16.7 ms at 60 Hz). The window shows live "capture → receive" latency.

- **Sound:** uncompressed 16-bit PCM in 5 ms packets, ~30–40 ms in total.
- **Camera:** 1080p30, HEVC, 12 Mbit/s.
- **Input:** raw `CGEvent` bytes over TCP with `TCP_NODELAY`, so gestures and scroll momentum arrive unchanged.

Both Macs log stats every second:

```bash
log show --last 10m --info --style compact --predicate 'subsystem == "local.duodisplay"'
```

## How it works

```
iMac (Second Display)                           MacBook
event tap captures all input ─────────────────► CGEventPost
full-screen window ◄── UDP video (ProRes/HEVC) ─ CGVirtualDisplay → ScreenCaptureKit → VideoToolbox
  + locally drawn pointer ◄── position/shape ── event tap + NSCursor
speakers ◄── UDP audio (PCM) ────────────────── Core Audio tap (MacBook muted)
camera → HEVC ── UDP ─────────────────────────► camera extension → "iMac Camera"
microphone ───── UDP audio ───────────────────► loopback driver → "iMac Microphone"
          ◄── TCP control channel (paired, encrypted): mode, keyframes, stats ──►
```

In *Normal Use* the iMac only forwards input after the pointer crosses the edge (or enters the picture-in-picture window).

## Pairing and security

Only the paired Mac can connect, so other devices on the network can neither take over the iMac nor read input, screen, camera or microphone.

- Pairing shows a 6-digit code on both Macs. Confirm only if you started the connection and the codes match. A warning appears if the request doesn't come over Thunderbolt.
- The shared key is stored in the keychain. Each Mac has exactly one partner and refuses new pairings until you *Unpair*.
- Every connection derives fresh keys. The control channel and every UDP media packet are encrypted with AES-GCM; foreign, modified and replayed packets are dropped.
- Both Macs need the same DuoDisplay version.
- After a rejected pairing the iMac ignores new attempts for 10 s, and always in Second Display mode.

## Limitations

- **System gestures** (Spaces, Mission Control) are forwarded, but whether macOS runs them on the MacBook is untested with two Macs.
- **Edge switch** hides the iMac pointer using a private WindowServer setting. If a macOS update removes it, the pointer stays visible at the edge.
- **Picture-in-picture** is only tested on one Mac. With several MacBook displays the pointer is limited to the main one.
- **Universal Control** in Second Display mode: don't push the MacBook's own trackpad past the iMac's right edge.
- **Password fields:** macOS *Secure Input* blocks injected keystrokes.
- `CGVirtualDisplay` is a **private Apple API** and may break with macOS updates.
- **Sound** uses the output device active when switching modes. After plugging in headphones, press ⌃⌥⌘D twice.
- **iMac Microphone** is mono 48 kHz; echo cancellation is up to the call app.

## Tests

```bash
APP=build/DuoDisplay.app/Contents/MacOS/DuoDisplay
$APP --selftest       # video pipeline over loopback, incl. packet loss
$APP --inputtest      # input events survive transfer, volume keys
$APP --pairtest       # pairing, authentication, encryption (--keychain: real keychain)
$APP --displaytest    # virtual display: HiDPI mode and placement
$APP --edgetest       # edge detection, picture-in-picture entry/exit
$APP --mediatest      # audio packets, jitter buffer, camera path
$APP --transporttest  # network only: encrypted vs. unencrypted
$APP --rendertest --window          # rendering in a real window (--prores for ProRes)
$APP --uisnapshot build/ui-snapshots  # all windows as PNG, light and dark
open -n -W build/DuoDisplay.app --args --piptest /tmp/piptest.txt  # PiP window (moves the pointer)
```

## Contributing

Contributions are welcome, especially tests with two real Macs. See [CONTRIBUTING.md](CONTRIBUTING.md), report vulnerabilities as described in [SECURITY.md](SECURITY.md), and follow the [Code of Conduct](CODE_OF_CONDUCT.md). Changes are listed in the [CHANGELOG](CHANGELOG.md).

## License

[MIT](LICENSE). DuoDisplay uses private Apple APIs, so it can't be in the Mac App Store.
