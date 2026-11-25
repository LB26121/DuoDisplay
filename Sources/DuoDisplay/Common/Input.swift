import Foundation
import AppKit
import Carbon.HIToolbox
import ApplicationServices
import os

// MARK: - Permissions

enum Permissions {
    /// Needed to read (receiver) and inject (sender) keyboard / trackpad events.
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Global hotkeys ⌃⌥⌘D and ⌃⌥⌘P

/// Registers ⌃⌥⌘D (switch modes) and ⌃⌥⌘P (picture-in-picture of the MacBook) system-wide via
/// Carbon (works in the background, no permission needed). While the receiver captures all input,
/// the event tap recognises the combos itself (`matches`, `matchesPiP`).
final class GlobalHotKey {
    static let keyCode = UInt32(kVK_ANSI_D)
    static let label = "⌃⌥⌘D"
    static let pipKeyCode = UInt32(kVK_ANSI_P)
    static let pipLabel = "⌃⌥⌘P"
    private static let carbonModifiers = UInt32(cmdKey | optionKey | controlKey)
    private static let relevantFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
    private static let requiredFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
    private static let signature = OSType(0x4455_4F44)  // 'DUOD'

    /// ⌃⌥⌘D
    var action: (() -> Void)?
    /// ⌃⌥⌘P
    var pipAction: (() -> Void)?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { id.id == 2 ? me.pipAction?() : me.action?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        for (keyCode, id) in [(Self.keyCode, UInt32(1)), (Self.pipKeyCode, UInt32(2))] {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(keyCode, Self.carbonModifiers, EventHotKeyID(signature: Self.signature, id: id),
                                GetApplicationEventTarget(), 0, &ref)
            if let ref { hotKeyRefs.append(ref) }
        }
    }

    deinit {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// ⌃⌥⌘D
    static func matches(_ event: CGEvent) -> Bool { matches(event, keyCode: keyCode) }

    /// ⌃⌥⌘P
    static func matchesPiP(_ event: CGEvent) -> Bool { matches(event, keyCode: pipKeyCode) }

    private static func matches(_ event: CGEvent, keyCode: UInt32) -> Bool {
        event.getIntegerValueField(.keyboardEventKeycode) == Int64(keyCode)
            && event.flags.intersection(relevantFlags) == requiredFlags
    }
}

// MARK: - Event tap on its own thread

/// Raw CGEvent types we care about (some are private gesture types without a Swift case).
enum EventTypes {
    static let leftMouseDown: UInt32 = 1
    static let rightMouseDown: UInt32 = 3
    static let otherMouseDown: UInt32 = 25
    static let mouseMoved: UInt32 = 5
    static let leftDragged: UInt32 = 6
    static let rightDragged: UInt32 = 7
    static let otherDragged: UInt32 = 27
    static let keyDown: UInt32 = 10
    static let keyUp: UInt32 = 11

    /// Everything a keyboard, mouse or trackpad can produce, incl. gestures (29 gesture,
    /// 30 dock swipe, 31 fluid touch, 18–20 rotate/begin/end, 32 smart zoom, 34 force touch).
    static let allInput: [UInt32] = [1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 14, 18, 19, 20, 22, 23, 24,
                                     25, 26, 27, 29, 30, 31, 32, 33, 34, 37]
    static let pointerMotion: [UInt32] = [5, 6, 7, 27]

    static func mask(_ types: [UInt32]) -> CGEventMask {
        types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1)) }
    }
}

/// Owns a CGEventTap serviced by a dedicated high-priority run loop thread, so the main
/// thread (UI) can never delay input.
final class EventTapThread {
    typealias Handler = (CGEventTapProxy, CGEventType, CGEvent) -> Unmanaged<CGEvent>?

    private let handler: Handler
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private let wantEnabled = OSAllocatedUnfairLock(initialState: false)

    init(handler: @escaping Handler) { self.handler = handler }

    /// Returns false if macOS refused the tap (missing Accessibility permission).
    func install(location: CGEventTapLocation, options: CGEventTapOptions, types: [UInt32], enabled: Bool) -> Bool {
        guard tap == nil else { return true }
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            let me = Unmanaged<EventTapThread>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if me.wantEnabled.withLock({ $0 }), let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return me.handler(proxy, type, event)
        }
        guard let tap = CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: options,
                                          eventsOfInterest: EventTypes.mask(types), callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        wantEnabled.withLock { $0 = enabled }
        CGEvent.tapEnable(tap: tap, enable: enabled)

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            self?.runLoop = CFRunLoopGetCurrent()
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "duodisplay.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    var isInstalled: Bool { tap != nil }

    func setEnabled(_ enabled: Bool) {
        wantEnabled.withLock { $0 = enabled }
        if let tap { CGEvent.tapEnable(tap: tap, enable: enabled) }
    }

    func uninstall() {
        guard let tap else { return }
        setEnabled(false)
        CFMachPortInvalidate(tap)
        if let runLoop { CFRunLoopStop(runLoop) }
        self.tap = nil
        runLoop = nil
    }
}
