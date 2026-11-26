#!/bin/bash
# Builds DuoDisplay.app (no Xcode needed – the Command Line Tools are enough).
#
# Signing, in this order:
#   1. SIGN_IDENTITY="Apple Development: …" ./build.sh   – your own certificate
#   2. the local "DuoDisplay Local Signing" identity in
#      ~/Library/Keychains/duodisplay-signing.keychain-db (created once, see README)
#   3. ad-hoc
# With 1 or 2 the code signature stays the same across rebuilds, so macOS keeps the
# Accessibility and Screen Recording permissions after updating.
#
# Virtual camera (iMac camera on the MacBook) additionally needs an Apple Developer account,
# because macOS only activates system extensions from properly provisioned apps:
#   SIGN_IDENTITY="Apple Development: …" \
#   APP_PROFILE=~/Downloads/DuoDisplay.provisionprofile \
#   CAMERA_PROFILE=~/Downloads/DuoDisplayCamera.provisionprofile \
#   ./build.sh
# Optional: TEAM_ID (otherwise read from the certificate), BUNDLE_ID (default local.duodisplay.DuoDisplay).
#
# Release (what GitHub Releases and the Homebrew cask ship):
#   RELEASE=1 ./build.sh
# Universal binary, Developer ID signature with hardened runtime, notarized and stapled, zipped
# to build/DuoDisplay-<version>.zip. Defaults: the first "Developer ID Application" identity, the
# profiles in ~/Library/Application Support/DuoDisplay/developer-id/, BUNDLE_ID
# io.github.lb26121.DuoDisplay, version from the latest git tag (vX.Y), notarytool keychain
# profile "duodisplay-notary". In CI pass NOTARY_KEY (.p8 path), NOTARY_KEY_ID and NOTARY_ISSUER
# instead. NOTARIZE=0 skips notarization.
set -euo pipefail
cd "$(dirname "$0")"

RELEASE="${RELEASE:-0}"
if [[ $RELEASE == 1 ]]; then
    REL_DIR="$HOME/Library/Application Support/DuoDisplay/developer-id"
    SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application:/ {print $2; exit}')}"
    [[ -n "$SIGN_IDENTITY" ]] || { echo "✗ No valid “Developer ID Application” identity in the keychain"; exit 1; }
    APP_PROFILE="${APP_PROFILE:-$REL_DIR/DuoDisplay_DeveloperID.provisionprofile}"
    CAMERA_PROFILE="${CAMERA_PROFILE:-$REL_DIR/DuoDisplay_Camera_DeveloperID.provisionprofile}"
    for p in "$APP_PROFILE" "$CAMERA_PROFILE"; do [[ -f "$p" ]] || { echo "✗ Missing $p"; exit 1; }; done
    BUNDLE_ID="${BUNDLE_ID:-io.github.lb26121.DuoDisplay}"
    VERSION="${VERSION:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//' || true)}"
    BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
fi

# Defaults from the one-time Apple Developer setup (see README), if present.
DEV_DIR="$HOME/Library/Application Support/DuoDisplay/apple-dev"
if [[ $RELEASE != 1 && -z "${SIGN_IDENTITY:-}" && -f "$DEV_DIR/DuoDisplay_Development.provisionprofile" ]]; then
    DEV_IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development:/ {print $2; exit}')"
    if [[ -n "$DEV_IDENTITY" ]]; then
        SIGN_IDENTITY="$DEV_IDENTITY"
        APP_PROFILE="${APP_PROFILE:-$DEV_DIR/DuoDisplay_Development.provisionprofile}"
        CAMERA_PROFILE="${CAMERA_PROFILE:-$DEV_DIR/DuoDisplay_Camera_Development.provisionprofile}"
    fi
fi

BUNDLE_ID="${BUNDLE_ID:-local.duodisplay.DuoDisplay}"
CAMERA_ID="$BUNDLE_ID.CameraExtension"

ARCH_ARGS=()
CS_FLAGS=(--timestamp=none)
if [[ $RELEASE == 1 ]]; then
    ARCH_ARGS=(--arch arm64 --arch x86_64)   # Intel iMacs are common Target Display Mode hosts
    CS_FLAGS=(--options runtime --timestamp)  # both required for notarization
fi
swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)"

# SwiftPM writes the deployment target (14.0) into the binary as its SDK version as well. macOS then
# runs the app in compatibility mode with the pre-Liquid Glass look (old window buttons, title bar
# and controls). Stamp the real SDK version; the minimum system version stays 14.0.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
stamp_sdk() { vtool -set-build-version macos 14.0 "$SDK_VERSION" -replace -output "$1" "$1" 2>/dev/null; }

APP="build/DuoDisplay.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DuoDisplay" "$APP/Contents/MacOS/DuoDisplay"
stamp_sdk "$APP/Contents/MacOS/DuoDisplay"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
[[ -n "${VERSION:-}" ]] && plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
[[ -n "${BUILD_NUMBER:-}" ]] && plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"

# App icon (Liquid Glass, Resources/AppIcon.icon – editable with Icon Composer). Compiled with
# Xcode's actool when available, otherwise the precompiled copy in Resources/AppIconCompiled is used.
XCODE_DEV="${XCODE_DEV:-/Applications/Xcode.app/Contents/Developer}"
ICON_TMP="$(mktemp -d)"
if [[ -d "$XCODE_DEV" ]] && DEVELOPER_DIR="$XCODE_DEV" xcrun actool Resources/AppIcon.icon \
        --compile "$ICON_TMP" --app-icon AppIcon --platform macosx --target-device mac \
        --minimum-deployment-target 14.0 --output-partial-info-plist "$ICON_TMP/partial.plist" >/dev/null 2>&1 \
        && [[ -f "$ICON_TMP/Assets.car" ]]; then
    cp "$ICON_TMP/Assets.car" "$ICON_TMP/AppIcon.icns" Resources/AppIconCompiled/
fi
rm -rf "$ICON_TMP"
cp Resources/AppIconCompiled/Assets.car Resources/AppIconCompiled/AppIcon.icns "$APP/Contents/Resources/"

KEYCHAIN="$HOME/Library/Keychains/duodisplay-signing.keychain-db"
KEYCHAIN_PW_FILE="$HOME/Library/Application Support/DuoDisplay/signing-keychain-password"
LOCAL_IDENTITY="DuoDisplay Local Signing"

SIGN_ARGS=()
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    SIGN_ARGS=(--sign "$SIGN_IDENTITY")
    SIGNED_WITH="$SIGN_IDENTITY"
elif [[ -f "$KEYCHAIN" && -f "$KEYCHAIN_PW_FILE" ]]; then
    security unlock-keychain -p "$(cat "$KEYCHAIN_PW_FILE")" "$KEYCHAIN"
    SIGN_ARGS=(--keychain "$KEYCHAIN" --sign "$LOCAL_IDENTITY")
    SIGNED_WITH="$LOCAL_IDENTITY (stable: permissions survive rebuilds)"
else
    SIGN_ARGS=(--sign -)
    SIGNED_WITH="ad-hoc (permissions must be granted again after every rebuild)"
fi

# --- Virtual microphone: Core Audio driver (installed from inside the app on request) ---
DRIVER="$APP/Contents/Resources/DuoDisplayMic.driver"
mkdir -p "$DRIVER/Contents/MacOS"
cp Plugins/DuoDisplayMic/Info.plist "$DRIVER/Contents/Info.plist"
clang -bundle -O2 -Wall -mmacosx-version-min=14.0 -arch arm64 -arch x86_64 \
    -framework CoreAudio -framework CoreFoundation \
    -o "$DRIVER/Contents/MacOS/DuoDisplayMic" Plugins/DuoDisplayMic/DuoDisplayMic.c
if [[ $RELEASE == 1 ]]; then
    codesign --force "${SIGN_ARGS[@]}" "${CS_FLAGS[@]}" "$DRIVER"   # notarization checks nested code
else
    # Ad-hoc: coreaudiod loads it like any locally built driver (e.g. BlackHole built from source).
    codesign --force --sign - --timestamp=none "$DRIVER"
fi

# --- Virtual camera: Core Media I/O system extension ---
TEAM_ID="${TEAM_ID:-}"
if [[ -z "$TEAM_ID" && -n "${SIGN_IDENTITY:-}" ]]; then
    TEAM_ID="$(security find-certificate -c "$SIGN_IDENTITY" -p 2>/dev/null \
        | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
        | awk -F' = ' '/organizationalUnitName/ {print $2; exit}')" || true
fi
CAMERA_SIGNED=0
if [[ -n "${SIGN_IDENTITY:-}" && -n "${APP_PROFILE:-}" && -n "${CAMERA_PROFILE:-}" && -n "$TEAM_ID" ]]; then
    CAMERA_SIGNED=1
fi
if [[ $RELEASE == 1 && $CAMERA_SIGNED != 1 ]]; then
    echo "✗ Release builds must include the signed camera extension (team ID not found for $SIGN_IDENTITY)"; exit 1
fi
EXT_TEAM="${TEAM_ID:-LOCAL}"

EXT="$APP/Contents/Library/SystemExtensions/$CAMERA_ID.systemextension"
mkdir -p "$EXT/Contents/MacOS"
cp "$BIN_DIR/DuoDisplayCamera" "$EXT/Contents/MacOS/$CAMERA_ID"
stamp_sdk "$EXT/Contents/MacOS/$CAMERA_ID"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" -e "s/__TEAM_ID__/$EXT_TEAM/g" \
    Plugins/CameraExtension/Info.plist > "$EXT/Contents/Info.plist"

TMP_ENT="$(mktemp -d)"
trap 'rm -rf "$TMP_ENT"' EXIT
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" -e "s/__TEAM_ID__/$EXT_TEAM/g" \
    Plugins/CameraExtension/CameraExtension.entitlements > "$TMP_ENT/camera.entitlements"

if [[ $CAMERA_SIGNED == 1 ]]; then
    # Check the profiles before signing – a mismatch otherwise only shows up as a refused activation.
    check_profile() {   # <profile> <bundle id> <must contain entitlement or "">
        local plist="$TMP_ENT/$(basename "$1").plist"
        security cms -D -i "$1" > "$plist" 2>/dev/null || { echo "✗ $1 is not a valid provisioning profile"; exit 1; }
        local appid
        appid="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$plist" 2>/dev/null)"
        if [[ "$appid" != "$TEAM_ID.$2" ]]; then
            echo "✗ $(basename "$1") belongs to “$appid”, expected “$TEAM_ID.$2”"; exit 1
        fi
        if [[ -n "$3" ]] && ! /usr/libexec/PlistBuddy -c "Print :Entitlements:$3" "$plist" >/dev/null 2>&1; then
            echo "✗ $(basename "$1") lacks “$3”. Enable the “System Extension” capability for the App ID and recreate the profile"; exit 1
        fi
        local udid
        udid="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Provisioning UDID/ {print $2}')"
        if [[ -n "$udid" ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$plist" 2>/dev/null)" != true ]] \
                && ! /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$plist" 2>/dev/null | grep -q "$udid"; then
            echo "⚠︎ $(basename "$1") doesn’t include this Mac ($udid), so the app won’t start here."
        fi
    }
    check_profile "$APP_PROFILE" "$BUNDLE_ID" "com.apple.developer.system-extension.install"
    check_profile "$CAMERA_PROFILE" "$CAMERA_ID" ""

    # Identity entitlements that must match the profiles (Xcode adds these automatically).
    cp Resources/DuoDisplay-SystemExtension.entitlements "$TMP_ENT/app.entitlements"
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM_ID.$BUNDLE_ID" \
                            -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$TMP_ENT/app.entitlements"
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM_ID.$CAMERA_ID" \
                            -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$TMP_ENT/camera.entitlements"

    cp "$CAMERA_PROFILE" "$EXT/Contents/embedded.provisionprofile"
    cp "$APP_PROFILE" "$APP/Contents/embedded.provisionprofile"
    codesign --force "${SIGN_ARGS[@]}" "${CS_FLAGS[@]}" --entitlements "$TMP_ENT/camera.entitlements" "$EXT"
    codesign --force "${SIGN_ARGS[@]}" "${CS_FLAGS[@]}" --entitlements "$TMP_ENT/app.entitlements" "$APP"
    CAMERA_NOTE="Virtual camera: signed for team $TEAM_ID. Copy to /Applications and activate it in the app."
else
    # Without a provisioning profile the restricted install entitlement would stop the app from
    # launching, so the extension is only bundled; activating it will be refused by macOS.
    codesign --force "${SIGN_ARGS[@]}" "${CS_FLAGS[@]}" --entitlements "$TMP_ENT/camera.entitlements" "$EXT"
    codesign --force "${SIGN_ARGS[@]}" "${CS_FLAGS[@]}" --entitlements Resources/DuoDisplay.entitlements "$APP"
    CAMERA_NOTE="Virtual camera: unavailable (needs SIGN_IDENTITY, APP_PROFILE, CAMERA_PROFILE, see README). Sound and microphone work."
fi

echo "Signed with: $SIGNED_WITH"

if [[ $RELEASE == 1 ]]; then
    codesign --verify --deep --strict "$APP"
    ZIP="build/DuoDisplay-$VERSION.zip"
    rm -f "$ZIP"
    if [[ "${NOTARIZE:-1}" == 1 ]]; then
        if [[ -n "${NOTARY_KEY:-}" ]]; then
            NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
        else
            NOTARY_ARGS=(--keychain-profile "${NOTARY_PROFILE:-duodisplay-notary}")
        fi
        ditto -c -k --keepParent "$APP" "$ZIP"
        echo "Notarizing (usually a few minutes)…"
        RESULT="$(xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait --output-format json)"
        STATUS="$(plutil -extract status raw - <<<"$RESULT")"
        if [[ "$STATUS" != Accepted ]]; then
            echo "✗ Notarization: $STATUS"
            xcrun notarytool log "$(plutil -extract id raw - <<<"$RESULT")" "${NOTARY_ARGS[@]}" || true
            exit 1
        fi
        xcrun stapler staple "$APP"
        rm -f "$ZIP"
        spctl --assess --type execute "$APP"
        echo "Notarized and stapled; Gatekeeper accepts it."
    fi
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Release: $(pwd)/$ZIP (version $VERSION)"
    echo "sha256:  $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
fi
echo "$CAMERA_NOTE"
echo "Done: $(pwd)/$APP"
