import Foundation
import CoreMedia
import SystemConfiguration

/// Shared constants of the DuoDisplay wire protocol.
///
/// Control channel: TCP (Bonjour `_duodisplay._tcp`), 4-byte big-endian length + JSON `ControlMessage`;
///                  after the pairing handshake every body is AES-GCM encrypted (ControlChannel).
/// Video channel:   UDP, each datagram = 10-byte chunk header + slice of one encoded frame,
///                  sealed with AES-GCM like every media datagram (MediaCrypto; the layout below
///                  is the plain datagram).
///
/// Chunk header (little endian):
///   [0]    magic 0xD7
///   [1]    session id (assigned by receiver per connection)
///   [2..5] frame id (UInt32, increments per encoded frame)
///   [6..7] chunk index
///   [8..9] chunk count
enum DD {
    static let bonjourType = "_duodisplay._tcp"
    static let magic: UInt8 = 0xD7
    static let cameraMagic: UInt8 = 0xC7   // iMac camera → MacBook (same chunk header as the screen video)
    static let chunkHeaderSize = 10
    static let minDatagramSize = 1200
    static let maxDatagramSize = 8900   // below macOS' default net.inet.udp.maxdgram (9216)
}

struct DDError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum VideoCodec: UInt8, CaseIterable, Identifiable {
    case h264 = 0
    case hevc = 1
    /// ProRes 422 Proxy: every frame stands on its own (no keyframe waits after a loss). Measured on an
    /// M4 at 3024×1890: encode Ø 4.8 ms, decode Ø 1.6 ms (HEVC: 9.1 / 3.5 ms), but ~4× the data rate
    /// (≈ 250–600 Mbit/s at 60 fps) – Thunderbolt only.
    case prores = 2

    var id: UInt8 { rawValue }
    var cmCodecType: CMVideoCodecType {
        switch self {
        case .h264: return kCMVideoCodecType_H264
        case .hevc: return kCMVideoCodecType_HEVC
        case .prores: return kCMVideoCodecType_AppleProRes422Proxy
        }
    }
    var label: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .prores: return "ProRes"
        }
    }
    /// Every frame is a keyframe; there is no bitrate to set.
    var isIntraOnly: Bool { self == .prores }
}

/// Monotonic host time in nanoseconds (same clock as mach_absolute_time / CMClockGetHostTimeClock).
@inline(__always) func hostTimeNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// Converts a host-clock CMTime (e.g. a ScreenCaptureKit presentation timestamp) to nanoseconds.
func hostTimeNs(of time: CMTime) -> UInt64 {
    guard time.isValid, time.isNumeric else { return hostTimeNs() }
    let ns = CMTimeConvertScale(time, timescale: 1_000_000_000, method: .roundTowardZero).value
    return ns > 0 ? UInt64(ns) : hostTimeNs()
}

func localComputerName() -> String {
    if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
    return Host.current().localizedName ?? "Mac"
}

/// Stable 32-bit FNV-1a hash (used as virtual display serial so macOS remembers the arrangement).
func stableHash(_ s: String) -> UInt32 {
    var h: UInt32 = 2_166_136_261
    for b in s.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
    return h
}

/// What the receiver Mac (iMac) is currently used for.
enum LinkMode: String, Codable {
    case display   // shows the sender's extra screen, its keyboard/trackpad control the sender
    case local     // normal standalone use; the pointer can still cross over to the sender (EdgeSwitch)
}

/// Binary messages on the control channel (body does not start with "{").
enum BinaryKind: UInt8 {
    case inputEvent = 1       // receiver → sender: serialized CGEvent (CGEventCreateData)
    case cursorPosition = 2   // sender → receiver: Float32 x, Float32 y (points in virtual display), UInt8 visible
}

struct ControlMessage: Codable {
    enum Kind: String, Codable {
        case hello, displayInfo, keyframeRequest, ping, pong, stats
        case setMode        // sender → receiver: switch to `mode`
        case requestMode    // receiver → sender: user pressed the hotkey on the receiver
        case cursorImage    // sender → receiver: current cursor shape
        case mediaDemand    // sender → receiver: apps on the MacBook use the iMac `camera` / `microphone`
        case cameraKeyframe // sender → receiver: camera stream needs a keyframe
        case mediaStatus    // receiver → sender: `text` = problem with camera / microphone (nil = all fine)
        case audioRoute     // sender → receiver: `audio` = the sender's sound plays on the receiver now
                            // (display mode): the volume keys then act on the receiver, not the sender
        case edgeConfig     // sender → receiver: `edge` of the receiver's screen that leads to the sender (nil = off)
        case edgeEnter      // receiver → sender: pointer crossed over at `fraction`; input events follow
        case edgeLeave      // sender → receiver: pointer came back at `fraction` (+ `eventTime`);
                            // receiver → sender: input taken back (⌃⌥⌘D / timeout), stop injecting
        // picture-in-picture ("Normal nutzen"): the MacBook's own main screen in a window on the iMac
        case pipStart       // receiver → sender: stream the main screen (udpPort, session, mtu, proRes, refreshRate),
                            // or with `pipExtended` an extra virtual screen; sent again to switch between the two
        case pipStop        // receiver → sender: window closed, stop that stream
        case pipState       // sender → receiver: `pip` = streaming (pointWidth/Height, localCursor, pipControl, pipExtended)
                            // or failed (`text`)
        case pipToggle      // sender → receiver: ⌃⌥⌘P was pressed on the MacBook
        // pairing + authentication (Pairing.swift); everything else follows encrypted
        case authChallenge  // receiver → sender: `deviceID`, `name`, `nonce`, `mac`
        case authResponse   // sender → receiver: `mac`
        case authFailed     // receiver → sender: the MacBook's proof was wrong
        case pairRequired   // receiver → sender: not paired with this MacBook (`deviceID`, `name`)
        case pairStart      // sender → receiver: `commit` to its key
        case pairKey        // receiver → sender: `publicKey`, `deviceID`, `name`
        case pairReveal     // sender → receiver: `publicKey`
        case pairConfirm    // both: `mac` – the user confirmed the code
        case pairCancel     // both: `text` = why
    }

    var kind: Kind
    // modes
    var mode: LinkMode?
    var localCursor: Bool?
    // media
    var camera: Bool?
    var microphone: Bool?
    var audio: Bool?
    var text: String?
    // edge switching ("Normal nutzen")
    var edge: ScreenEdge?
    var fraction: Double?
    /// edgeLeave from the sender: the receiver's own timestamp of the forwarded event that pushed the
    /// pointer out. Motion the receiver forwarded after it is replayed locally instead of being lost.
    var eventTime: UInt64?
    /// Picture-in-picture: edgeEnter / edgeLeave through the window instead of the screen edge –
    /// pointer position relative to the MacBook's main screen (0…1, top-left origin), the side it
    /// left through (edgeLeave) and how many MacBook points one iMac point of motion is (edgeEnter).
    var pipX: Double?
    var pipY: Double?
    var pipSide: PiPSide?
    var pipScale: Double?
    /// pipState: streaming (true) or not; pipControl: the MacBook can inject input (Accessibility).
    var pip: Bool?
    var pipControl: Bool?
    /// pipStart: show an extra (virtual) screen of the MacBook instead of mirroring its main screen.
    /// pipState: what is streamed (nil = a MacBook version that can only mirror).
    var pipExtended: Bool?
    // cursorImage
    var png: Data?
    var cursorWidth: Double?
    var cursorHeight: Double?
    var hotspotX: Double?
    var hotspotY: Double?
    // hello / displayInfo
    var name: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var pointWidth: Int?
    var pointHeight: Int?
    var refreshRate: Int?
    var udpPort: UInt16?
    var session: UInt8?
    var mtu: Int?
    /// displayInfo: the receiver can decode ProRes in hardware (nil from older versions = no).
    var proRes: Bool?
    // pairing + authentication
    var deviceID: String?
    var nonce: Data?
    var mac: Data?
    var publicKey: Data?
    var commit: Data?
    /// hello / authChallenge / pairRequired: this Mac seals its UDP media datagrams
    /// (MediaCrypto.version; nil = an older version that sends them in plain text).
    var mediaCrypto: Int?
    // ping / pong (clock sync)
    var t0: UInt64?
    var t1: UInt64?
    // stats (receiver -> sender)
    var latencyMs: Double?
    var latencyMaxMs: Double?
    var fps: Double?
    var mbps: Double?
    var lost: Int?

    init(_ kind: Kind) { self.kind = kind }
}

extension Data {
    @inline(__always) mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

extension UnsafeRawBufferPointer {
    @inline(__always) func readLE<T: FixedWidthInteger>(_ offset: Int, as: T.Type) -> T {
        T(littleEndian: loadUnaligned(fromByteOffset: offset, as: T.self))
    }
}
