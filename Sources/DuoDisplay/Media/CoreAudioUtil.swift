import Foundation
import CoreAudio
import AudioToolbox

/// Small typed wrappers around the Core Audio property API.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default value: T) -> T? {
        var addr = address(selector, scope)
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &result)
        return status == noErr ? result : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func devices() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func device(uid: String) -> AudioObjectID? {
        devices().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static var defaultOutputDevice: AudioObjectID? {
        Self.get(system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0)).flatMap { $0 == 0 ? nil : $0 }
    }

    static var defaultInputDevice: AudioObjectID? {
        Self.get(system, kAudioHardwarePropertyDefaultInputDevice, default: AudioObjectID(0)).flatMap { $0 == 0 ? nil : $0 }
    }

    static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw DDError("\(what) fehlgeschlagen (\(fourCC(status)))") }
    }

    /// Readable OSStatus: 'abcd' when it is a four-char code, otherwise the number.
    static func fourCC(_ status: OSStatus) -> String {
        let n = UInt32(bitPattern: status)
        let bytes = [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) { return "'" + String(decoding: bytes, as: UTF8.self) + "'" }
        return String(status)
    }
}

/// FourCharCode from a 4-character ASCII string.
func fourCharCode(_ s: String) -> UInt32 {
    s.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
}
