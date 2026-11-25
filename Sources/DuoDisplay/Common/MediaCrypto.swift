import Foundation
import CryptoKit
import os

/// Per-connection keys for the UDP media streams, one per direction. Derived in the handshake
/// from the pairing key and both connection nonces (PairingCrypto.mediaKeys).
struct MediaKeys {
    /// MacBook → iMac: screen video, picture-in-picture, sound.
    let toReceiver: SymmetricKey
    /// iMac → MacBook: camera, microphone.
    let toSender: SymmetricKey
}

/// AES-GCM for the UDP media datagrams (video, sound, camera, microphone). Without it anyone who
/// can reach the UDP port – on any interface, Wi-Fi included – could feed frames and sound into
/// the iMac's screen or the MacBook's virtual camera and microphone, and read them.
///
/// On the wire:
///   [0]      magic (plain, authenticated: a video datagram cannot be turned into a sound one)
///   [1..8]   counter (UInt64 big endian) = the nonce
///   [9...]   AES-GCM ciphertext of everything that followed the magic byte in the plain datagram
///   last 16  tag
/// The receiver gets the datagram back exactly as it was before sealing, so the stream formats
/// themselves (chunk header, audio header) are unchanged.
///
/// Cost on an M4: one core needs ~0.7 ms (jumbo datagrams) to ~2.3 ms (1400 B) per ProRes frame
/// (~420 KB) at a 60 Hz pace – hot in a loop it is 4–5× faster, but between frames the core
/// clocks down. Hence UDPVideoSender seals large frames on several cores while sending, and
/// UDPReceiver opens batches of queued datagrams on several cores. `--transporttest` measures
/// what is left: ~+0.3 ms per frame in jumbo datagrams between two Macs (estimated from one side
/// at a time).
enum MediaCrypto {
    /// Sent in hello / authChallenge / pairRequired: both Macs must seal their media datagrams.
    static let version = 1
    static let counterSize = 8
    static let tagSize = 16
    /// How much longer a sealed datagram is than the plain one.
    static let overhead = counterSize + tagSize

    static func nonce(_ counter: UInt64) -> AES.GCM.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        withUnsafeBytes(of: counter.bigEndian) { bytes.replaceSubrange(4..<12, with: $0) }
        return try! AES.GCM.Nonce(data: bytes)   // 12 bytes: always valid
    }
}

/// Seals the datagrams of one direction of one connection. Every sender of that direction
/// (e.g. screen video and sound) shares one instance, so a counter value – the nonce – is never
/// used twice with the key. Thread-safe.
final class MediaSealer: @unchecked Sendable {
    private let key: SymmetricKey
    private let counter = OSAllocatedUnfairLock(initialState: UInt64(0))

    init(key: SymmetricKey) { self.key = key }

    /// Reserves `count` consecutive counters and returns the first; the caller seals each of its
    /// datagrams with one of them (e.g. on several threads at once).
    func reserve(_ count: Int) -> UInt64 {
        counter.withLock { c -> UInt64 in
            let first = c + 1
            c += UInt64(count)
            return first
        }
    }

    /// Seals with a counter from `reserve` into `out` (needs 1 + body + MediaCrypto.overhead bytes)
    /// and returns the datagram's length. `body` is everything that follows the magic byte in the
    /// plain datagram. Thread-safe.
    func seal(magic: UInt8, _ body: some DataProtocol, counter n: UInt64, into out: UnsafeMutableRawBufferPointer) -> Int? {
        guard out.count >= 1 + MediaCrypto.overhead + body.count,
              let box = try? AES.GCM.seal(body, using: key, nonce: MediaCrypto.nonce(n), authenticating: [magic]) else {
            return nil
        }
        out[0] = magic
        withUnsafeBytes(of: n.bigEndian) {
            UnsafeMutableRawBufferPointer(rebasing: out[1..<(1 + MediaCrypto.counterSize)]).copyMemory(from: $0)
        }
        var length = 1 + MediaCrypto.counterSize
        length += box.ciphertext.copyBytes(to: UnsafeMutableRawBufferPointer(rebasing: out[length...]))
        length += box.tag.copyBytes(to: UnsafeMutableRawBufferPointer(rebasing: out[length...]))
        return length
    }

    /// One datagram on its own (sound, tests).
    func seal(magic: UInt8, _ body: some DataProtocol) -> Data? {
        var datagram = Data(count: 1 + MediaCrypto.overhead + body.count)
        let n = reserve(1)
        guard let length = datagram.withUnsafeMutableBytes({ seal(magic: magic, body, counter: n, into: $0) }) else { return nil }
        datagram.count = length
        return datagram
    }
}

/// Opens the datagrams of one direction of one connection and rejects forged, altered and
/// replayed ones. `decrypt` is thread-safe; `accept` and `open` (replay window) belong to the
/// UDP receive thread.
final class MediaOpener: @unchecked Sendable {
    private let key: SymmetricKey
    /// Replay window: counters this far behind the highest one seen are still accepted once
    /// (the senders of one direction share the counter, so e.g. a sound datagram can arrive
    /// behind a burst of video datagrams sealed after it). UDPVideoSender reserves a whole frame's
    /// counters at once, so this must exceed the datagrams of the largest frame (a 6 MB keyframe
    /// is ~4500 at 1400 B).
    private static let window: UInt64 = 16_384
    private var seen = [UInt64](repeating: 0, count: Int(window / 64))
    private var highest: UInt64 = 0

    init(key: SymmetricKey) { self.key = key }

    /// Writes the plain datagram (magic + body) to `out` and returns its length, or nil if the
    /// datagram is not authentic, was seen before, or does not fit.
    func open(_ datagram: UnsafeRawBufferPointer, into out: UnsafeMutableRawBufferPointer) -> Int? {
        guard let opened = decrypt(datagram, into: out), accept(opened.counter) else { return nil }
        return opened.length
    }

    /// Authenticates and decrypts without the replay check (call `accept` with the counter
    /// before using the result). Thread-safe.
    func decrypt(_ datagram: UnsafeRawBufferPointer, into out: UnsafeMutableRawBufferPointer) -> (counter: UInt64, length: Int)? {
        guard datagram.count > 1 + MediaCrypto.overhead else { return nil }
        let magic = datagram[0]
        let counter = UInt64(bigEndian: datagram.loadUnaligned(fromByteOffset: 1, as: UInt64.self))
        guard counter > 0 else { return nil }
        let start = 1 + MediaCrypto.counterSize
        let tagStart = datagram.count - MediaCrypto.tagSize
        guard let box = try? AES.GCM.SealedBox(nonce: MediaCrypto.nonce(counter),
                                               ciphertext: UnsafeRawBufferPointer(rebasing: datagram[start..<tagStart]),
                                               tag: UnsafeRawBufferPointer(rebasing: datagram[tagStart...])),
              let plain = try? AES.GCM.open(box, using: key, authenticating: [magic]),
              plain.count + 1 <= out.count else { return nil }
        out[0] = magic
        return (counter, 1 + plain.copyBytes(to: UnsafeMutableRawBufferPointer(rebasing: out[1...])))
    }

    /// Receive thread: true the first time `counter` (of an authentic datagram) comes in.
    func accept(_ counter: UInt64) -> Bool {
        guard isFresh(counter) else { return false }
        mark(counter)
        return true
    }

    private func isFresh(_ counter: UInt64) -> Bool {
        if counter > highest { return true }
        if highest - counter >= Self.window { return false }
        let bit = Int(counter % Self.window)
        return seen[bit >> 6] & (1 << UInt64(bit & 63)) == 0
    }

    private func mark(_ counter: UInt64) {
        if counter > highest {
            // The slots of the counters the window moves over still hold entries from one window ago.
            if counter - highest >= Self.window {
                for i in seen.indices { seen[i] = 0 }
            } else {
                var c = highest + 1
                while c <= counter {
                    let bit = Int(c % Self.window)
                    seen[bit >> 6] &= ~(1 << UInt64(bit & 63))
                    c += 1
                }
            }
            highest = counter
        }
        let bit = Int(counter % Self.window)
        seen[bit >> 6] |= 1 << UInt64(bit & 63)
    }
}
