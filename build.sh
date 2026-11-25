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
set -euo pipefail
cd "$(dirname "$0")"

# Defaults from the one-time Apple Developer setup (see README), if present.
DEV_DIR="$HOME/Library/Application Support/DuoDisplay/apple-dev"
if [[ -z "${SIGN_IDENTITY:-}" && -f "$DEV_DIR/DuoDisplay_Development.provisionprofile" ]]; then
    DEV_IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development:/ {print $2; exit}')"
    if [[ -n "$DEV_IDENTITY" ]]; then
        SIGN_IDENTITY="$DEV_IDENTITY"
        APP_PROFILE="${APP_PROFILE:-$DEV_DIR/DuoDisplay_Development.provisionprofile}"
        CAMERA_PROFILE="${CAMERA_PROFILE:-$DEV_DIR/DuoDisplay_Camera_Development.provisionprofile}"
    fi
fi

BUNDLE_ID="${BUNDLE_ID:-local.duodisplay.DuoDisplay}"
CAMERA_ID="$BUNDLE_ID.CameraExtension"

swift build -c release

APP="build/DuoDisplay.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DuoDisplay "$APP/Contents/MacOS/DuoDisplay"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"

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
    SIGNED_WITH="$LOCAL_IDENTITY (stabil – Freigaben bleiben bei Updates erhalten)"
else
    SIGN_ARGS=(--sign -)
    SIGNED_WITH="ad-hoc (Freigaben müssen nach jedem Neubau neu erteilt werden)"
fi

# --- Virtual microphone: Core Audio driver (installed from inside the app on request) ---
DRIVER="$APP/Contents/Resources/DuoDisplayMic.driver"
mkdir -p "$DRIVER/Contents/MacOS"
cp Plugins/DuoDisplayMic/Info.plist "$DRIVER/Contents/Info.plist"
clang -bundle -O2 -Wall -mmacosx-version-min=14.0 -arch arm64 -arch x86_64 \
    -framework CoreAudio -framework CoreFoundation \
    -o "$DRIVER/Contents/MacOS/DuoDisplayMic" Plugins/DuoDisplayMic/DuoDisplayMic.c
# Ad-hoc: coreaudiod loads it like any locally built driver (e.g. BlackHole built from source).
codesign --force --sign - --timestamp=none "$DRIVER"

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
EXT_TEAM="${TEAM_ID:-LOCAL}"

EXT="$APP/Contents/Library/SystemExtensions/$CAMERA_ID.systemextension"
mkdir -p "$EXT/Contents/MacOS"
cp .build/release/DuoDisplayCamera "$EXT/Contents/MacOS/$CAMERA_ID"
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
        security cms -D -i "$1" > "$plist" 2>/dev/null || { echo "✗ $1 ist kein gültiges Provisioning-Profil"; exit 1; }
        local appid
        appid="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$plist" 2>/dev/null)"
        if [[ "$appid" != "$TEAM_ID.$2" ]]; then
            echo "✗ $(basename "$1") gehört zu „$appid“, erwartet „$TEAM_ID.$2“"; exit 1
        fi
        if [[ -n "$3" ]] && ! /usr/libexec/PlistBuddy -c "Print :Entitlements:$3" "$plist" >/dev/null 2>&1; then
            echo "✗ $(basename "$1") enthält „$3“ nicht – in der App-ID die Fähigkeit „System Extension“ aktivieren und das Profil neu erstellen"; exit 1
        fi
        local udid
        udid="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Provisioning UDID/ {print $2}')"
        if [[ -n "$udid" ]] && ! /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$plist" 2>/dev/null | grep -q "$udid"; then
            echo "⚠︎ $(basename "$1") enthält diesen Mac ($udid) nicht – hier startet die App dann nicht."
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
    codesign --force "${SIGN_ARGS[@]}" --timestamp=none --entitlements "$TMP_ENT/camera.entitlements" "$EXT"
    codesign --force "${SIGN_ARGS[@]}" --timestamp=none --entitlements "$TMP_ENT/app.entitlements" "$APP"
    CAMERA_NOTE="Virtuelle Kamera: signiert für Team $TEAM_ID – nach /Programme kopieren und in der App aktivieren."
else
    # Without a provisioning profile the restricted install entitlement would stop the app from
    # launching, so the extension is only bundled; activating it will be refused by macOS.
    codesign --force "${SIGN_ARGS[@]}" --timestamp=none --entitlements "$TMP_ENT/camera.entitlements" "$EXT"
    codesign --force "${SIGN_ARGS[@]}" --timestamp=none --entitlements Resources/DuoDisplay.entitlements "$APP"
    CAMERA_NOTE="Virtuelle Kamera: nicht aktivierbar (braucht SIGN_IDENTITY, APP_PROFILE, CAMERA_PROFILE – siehe README). Ton und Mikrofon funktionieren."
fi

echo "Signiert mit: $SIGNED_WITH"
echo "$CAMERA_NOTE"
echo "Fertig: $(pwd)/$APP"
