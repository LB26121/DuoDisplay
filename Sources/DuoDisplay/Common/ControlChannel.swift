import Foundation
import Network
import CryptoKit

enum Net {
    /// TCP parameters tuned for a tiny, latency-sensitive control channel.
    static func tcpParameters(requiredInterface: NWInterface?) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .interactiveVideo
        params.includePeerToPeer = false
        if let requiredInterface { params.requiredInterface = requiredInterface }
        return params
    }
}

/// Length-prefixed JSON messages over a TCP NWConnection. Callbacks run on `queue`.
final class ControlChannel {
    let connection: NWConnection
    var onReady: (() -> Void)?
    var onMessage: ((ControlMessage) -> Void)?
    var onBinary: ((BinaryKind, Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    private let queue: DispatchQueue
    private var closed = false
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// Encrypted bodies start with this byte (plain ones with "{" or a BinaryKind).
    private static let encryptedMarker: UInt8 = 0xE5
    /// Serialises sends from any thread, so the message counter matches the order on the wire.
    private let sendLock = NSLock()
    private var sealer: ChannelCipher?   // sendLock
    private var opener: ChannelCipher?   // queue only

    /// Call on the channel's queue, right after the last plain handshake message was sent or
    /// received. From then on everything is encrypted, and anything plain closes the channel.
    func enableEncryption(send: SymmetricKey, receive: SymmetricKey) {
        sendLock.lock()
        sealer = ChannelCipher(key: send)
        sendLock.unlock()
        opener = ChannelCipher(key: receive)
    }

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.receiveHeader()
            case .failed(let error):
                self.finish(error)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Thread-safe.
    func send(_ message: ControlMessage) {
        guard let body = try? encoder.encode(message) else { return }
        write(body)
    }

    /// Thread-safe. Used for high-rate input / cursor traffic (no JSON).
    func send(_ kind: BinaryKind, _ payload: Data) {
        var body = Data(capacity: payload.count + 1)
        body.append(kind.rawValue)
        body.append(payload)
        write(body)
    }

    private func write(_ body: Data) {
        sendLock.lock()
        defer { sendLock.unlock() }
        var payload = body
        if sealer != nil {
            guard let sealed = try? sealer!.seal(body) else { return }
            payload = Data([Self.encryptedMarker])
            payload.append(sealed)
        }
        var frame = Data(capacity: payload.count + 4)
        Swift.withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        connection.send(content: frame, completion: .idempotent)
    }

    func close() {
        connection.cancel()
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { self.finish(error); return }
            guard let data, data.count == 4 else {
                if isComplete { self.finish(nil) } else { self.receiveHeader() }
                return
            }
            let length = data.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
            guard length > 0, length < 1_000_000 else { self.finish(DDError("Invalid control message")); return }
            self.receiveBody(Int(length))
        }
    }

    private func receiveBody(_ length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { self.finish(error); return }
            guard var data, data.count == length else { self.finish(nil); return }
            if self.opener != nil {
                guard data.first == Self.encryptedMarker, let plain = try? self.opener!.open(Data(data.dropFirst())),
                      !plain.isEmpty else {
                    self.finish(DDError("Control message not authentic"))
                    return
                }
                data = plain
            }
            if data.first == UInt8(ascii: "{") {
                if let message = try? self.decoder.decode(ControlMessage.self, from: data) {
                    self.onMessage?(message)
                }
            } else if let kind = BinaryKind(rawValue: data[data.startIndex]) {
                self.onBinary?(kind, Data(data.dropFirst()))
            }
            if isComplete { self.finish(nil) } else { self.receiveHeader() }
        }
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?(error)
    }
}
