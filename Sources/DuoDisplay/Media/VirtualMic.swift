import Foundation
import CoreAudio

/// The "iMac-Mikrofon (DuoDisplay)" audio device (Plugins/DuoDisplayMic, a loopback HAL driver).
/// The app plays the iMac microphone into its output side; apps record it from its input side.
enum VirtualMic {
    static let deviceUID = "DuoDisplayMic_UID"
    static let driverName = "DuoDisplayMic.driver"
    static let installPath = "/Library/Audio/Plug-Ins/HAL/" + driverName
    private static let clientsSelector = fourCharCode("ddcl")

    static var bundledDriver: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/" + driverName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var device: AudioObjectID? { CA.device(uid: deviceUID) }

    /// The installed driver differs from the one inside this app (e.g. after an update).
    static var needsUpdate: Bool {
        guard let bundled = bundledDriver else { return false }
        let a = bundled.appendingPathComponent("Contents/MacOS/DuoDisplayMic")
        let b = URL(fileURLWithPath: installPath).appendingPathComponent("Contents/MacOS/DuoDisplayMic")
        guard let x = try? Data(contentsOf: a), let y = try? Data(contentsOf: b) else { return true }
        return x != y
    }

    /// Process IDs of other apps that are recording from the virtual microphone right now.
    static func otherClients(of device: AudioObjectID) -> [pid_t] {
        var addr = CA.address(clientsSelector)
        var value: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr, let value else { return [] }
        let pids = (value.takeRetainedValue() as? [NSNumber])?.map { pid_t($0.int32Value) } ?? []
        let own = getpid()
        return pids.filter { $0 != own }
    }

    /// Copies the driver to /Library/Audio/Plug-Ins/HAL and restarts Core Audio.
    /// macOS shows its own administrator password prompt.
    static func install(completion: @escaping (String?) -> Void) {
        guard let bundled = bundledDriver else {
            completion("Der Treiber fehlt in der App – bitte mit build.sh neu bauen.")
            return
        }
        func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let shell = [
            "mkdir -p /Library/Audio/Plug-Ins/HAL",
            "rm -rf \(quoted(installPath))",
            "cp -R \(quoted(bundled.path)) \(quoted(installPath))",
            "chown -R root:wheel \(quoted(installPath))",
            "xattr -dr com.apple.quarantine \(quoted(installPath)) 2>/dev/null || true",
            "killall coreaudiod",
        ].joined(separator: " && ")
        let script = "do shell script \"\(shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges with prompt \"DuoDisplay möchte das virtuelle iMac-Mikrofon installieren.\""
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            let message = error.map { ($0[NSAppleScript.errorMessage] as? String) ?? "Installation fehlgeschlagen" }
            DispatchQueue.main.async { completion(message) }
        }
    }
}
