import Foundation
import AppKit
import CoreGraphics
import os

/// Receiver side: while active, swallows every keyboard / mouse / trackpad event on this Mac
/// (incl. gestures and system shortcuts like ⌘-Tab) and hands the raw serialized CGEvent over
/// for forwarding. ⌃⌥⌘D and ⌃⌥⌘P are never forwarded – they switch modes / picture-in-picture.
/// The volume keys stay on this Mac while `volumeKeysStayHere` is set (MacBook sound plays here).
final class InputCapture {
    /// Called on the tap thread with CGEventCreateData() bytes.
    var onEvent: ((Data) -> Void)?
    /// Called on the tap thread when ⌃⌥⌘D is pressed.
    var onHotkey: (() -> Void)?
    /// Called on the tap thread when ⌃⌥⌘P is pressed (picture-in-picture on / off).
    var onPiPHotkey: (() -> Void)?

    private var tapThread: EventTapThread?
    /// Key code of a hotkey whose key-up is still to be swallowed.
    private var swallowHotkeyUp: Int64?
    /// Recently forwarded pointer motion (event timestamp, delta), written on the tap thread.
    private struct Motion { var time: UInt64; var received: UInt64; var dx: Double; var dy: Double }

    struct Carry {
        var motion = CGVector.zero
        var events = 0
        /// How long ago the event that pushed the pointer out passed through here (nil = not found).
        var exitAgeMs: Double?
    }
    private let recentMotion = OSAllocatedUnfairLock(initialState: [Motion]())
    private let volumeHereBox = OSAllocatedUnfairLock(initialState: false)

    /// Volume up / down / mute act on this Mac instead of being forwarded (any thread).
    var volumeKeysStayHere: Bool {
        get { volumeHereBox.withLock { $0 } }
        set { volumeHereBox.withLock { $0 = newValue } }
    }

    var isInstalled: Bool { tapThread?.isInstalled ?? false }

    /// Installs the (initially disabled) tap. Needs the Accessibility permission.
    @discardableResult
    func install() -> Bool {
        if isInstalled { return true }
        let thread = EventTapThread { [weak self] _, type, event in
            guard let self else { return Unmanaged.passUnretained(event) }
            return self.handle(type: type.rawValue, event: event)
        }
        // HID level = before WindowServer hotkeys, Dock gestures and Universal Control see the event.
        if thread.install(location: .cghidEventTap, options: .defaultTap, types: EventTypes.allInput, enabled: false)
            || thread.install(location: .cgSessionEventTap, options: .defaultTap, types: EventTypes.allInput, enabled: false) {
            tapThread = thread
            return true
        }
        return false
    }

    func setActive(_ active: Bool) {
        swallowHotkeyUp = nil
        if active { recentMotion.withLock { $0.removeAll(keepingCapacity: true) } }
        tapThread?.setEnabled(active)
    }

    /// Pointer motion forwarded after the event with timestamp `time` (any thread). Used when the
    /// pointer comes back from the MacBook: these moves were still underway and are replayed here.
    func motion(after time: UInt64) -> Carry {
        let now = hostTimeNs()
        return recentMotion.withLock { list in
            var carry = Carry()
            for m in list {
                if m.time > time {
                    carry.motion.dx += m.dx
                    carry.motion.dy += m.dy
                    carry.events += 1
                } else if m.time == time {
                    carry.exitAgeMs = Double(now &- m.received) / 1e6
                }
            }
            return carry
        }
    }

    private func handle(type: UInt32, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == EventTypes.keyDown, GlobalHotKey.matches(event) || GlobalHotKey.matchesPiP(event) {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            swallowHotkeyUp = keyCode
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                keyCode == Int64(GlobalHotKey.pipKeyCode) ? onPiPHotkey?() : onHotkey?()
            }
            return nil
        }
        if volumeHereBox.withLock({ $0 }), VolumeKey.matches(type: type, event: event) {
            return Unmanaged.passUnretained(event)   // this Mac's own volume (with its on-screen display)
        }
        if type == EventTypes.keyUp, let swallow = swallowHotkeyUp,
           event.getIntegerValueField(.keyboardEventKeycode) == swallow {
            swallowHotkeyUp = nil
            return nil
        }
        if type == EventTypes.mouseMoved {
            let m = Motion(time: event.timestamp, received: hostTimeNs(),
                           dx: event.getDoubleValueField(.mouseEventDeltaX),
                           dy: event.getDoubleValueField(.mouseEventDeltaY))
            recentMotion.withLock { list in
                if list.count >= 256 { list.removeFirst(128) }
                list.append(m)
            }
        }
        if let data = event.data {
            onEvent?(data as Data)
        }
        return nil   // swallow: this Mac must not react while it acts as a display
    }
}

/// The volume keys (also with ⇧⌥ for fine steps): a system-defined event of subtype 8 (aux control
/// button, key in the upper 16 bits of data1) on Apple keyboards; some keyboards send key codes instead.
enum VolumeKey {
    static let systemDefined: UInt32 = 14
    /// NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_SOUND_DOWN, NX_KEYTYPE_MUTE (IOKit ev_keymap.h).
    static let auxKeys: Set<Int> = [0, 1, 7]
    /// kVK_VolumeUp, kVK_VolumeDown, kVK_Mute.
    static let keyCodes: Set<Int64> = [0x48, 0x49, 0x4A]

    static func matches(type: UInt32, event: CGEvent) -> Bool {
        switch type {
        case EventTypes.keyDown, EventTypes.keyUp:
            return keyCodes.contains(event.getIntegerValueField(.keyboardEventKeycode))
        case systemDefined:
            guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else { return false }
            return auxKeys.contains((ns.data1 >> 16) & 0xFFFF)
        default:
            return false
        }
    }
}
