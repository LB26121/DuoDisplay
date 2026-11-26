import Foundation
import Network
import CryptoKit
import os

/// `DuoDisplay --pairtest`: pairing, authentication and encryption of the control channel.
/// Both Macs run in this process over loopback TCP, with in-memory key stores (the Keychain is
/// not touched).
enum PairingSelfTest {
    static func run() -> Bool {
        print("DuoDisplay pairing self-test\n")
        var ok = true
        func check(_ name: String, _ condition: Bool) {
            print((condition ? "  ✓ " : "  ✗ ") + name)
            ok = ok && condition
        }

        print("▶︎ Control channel encryption")
        let key = SymmetricKey(size: .bits256)
        var sealer = ChannelCipher(key: key)
        let first = (try? sealer.seal(Data("hello".utf8))) ?? Data()
        let second = (try? sealer.seal(Data("world".utf8))) ?? Data()
        var opener = ChannelCipher(key: key)
        check("decrypts in order",
              (try? opener.open(first)) == Data("hello".utf8) && (try? opener.open(second)) == Data("world".utf8))
        var replay = ChannelCipher(key: key)
        check("skipped / replayed message rejected", (try? replay.open(second)) == nil)
        var tamperedOpener = ChannelCipher(key: key)
        var tampered = first
        tampered[tampered.startIndex] ^= 1
        check("modified byte rejected", (try? tamperedOpener.open(tampered)) == nil)
        var wrongKey = ChannelCipher(key: SymmetricKey(size: .bits256))
        check("wrong key rejected", (try? wrongKey.open(first)) == nil)

        print("▶︎ Media packet encryption (UDP)")
        let mediaKey = SymmetricKey(size: .bits256)
        let mediaSealer = MediaSealer(key: mediaKey)
        let plainDatagram: [UInt8] = [DD.magic, 7] + Array(repeating: 0x42, count: 200)
        func seal(_ sealer: MediaSealer = mediaSealer, _ plain: [UInt8] = plainDatagram) -> Data {
            sealer.seal(magic: plain[0], plain.dropFirst())!
        }
        func open(_ opener: MediaOpener, _ datagram: Data) -> [UInt8]? {
            var out = [UInt8](repeating: 0, count: 65_536)
            let n = datagram.withUnsafeBytes { raw in out.withUnsafeMutableBytes { opener.open(raw, into: $0) } }
            return n.map { Array(out[0..<$0]) }
        }
        let mediaOpener = MediaOpener(key: mediaKey)
        let d1 = seal(), d2 = seal(), d3 = seal()
        check("yields exactly the original datagram", open(mediaOpener, d1) == plainDatagram)
        check("content is encrypted", d1.range(of: Data(repeating: 0x42, count: 16)) == nil)
        check("reordered packets accepted", open(mediaOpener, d3) != nil && open(mediaOpener, d2) != nil)
        check("replayed packet rejected", open(mediaOpener, d2) == nil && open(mediaOpener, d1) == nil)
        var flipped = seal()
        flipped[flipped.count - 30] ^= 1
        check("modified byte rejected", open(mediaOpener, flipped) == nil)
        var otherKind = seal()
        otherKind[0] = AudioPacket.magic
        check("rewritten packet kind rejected", open(mediaOpener, otherKind) == nil)
        check("other key rejected", open(mediaOpener, seal(MediaSealer(key: SymmetricKey(size: .bits256)))) == nil)
        check("unencrypted packet rejected", open(mediaOpener, Data(plainDatagram)) == nil)
        let sound = seal()
        var frame = Data()
        for _ in 0..<5_000 { frame = seal() }
        check("sound after a large frame (5000 packets) accepted", open(mediaOpener, frame) != nil && open(mediaOpener, sound) != nil)
        let old = seal()
        var newest = Data()
        for _ in 0..<20_000 { newest = seal() }
        check("packet far behind the newest rejected", open(mediaOpener, newest) != nil && open(mediaOpener, old) == nil)

        print("▶︎ Code comparison")
        let s = Curve25519.KeyAgreement.PrivateKey()
        let r = Curve25519.KeyAgreement.PrivateKey()
        let m = Curve25519.KeyAgreement.PrivateKey()
        let a = s.publicKey.rawRepresentation, b = r.publicKey.rawRepresentation, x = m.publicKey.rawRepresentation
        let onS = try? PairingCrypto.pairing(privateKey: s, peerPublicKey: b, senderID: "S", receiverID: "R", senderKey: a, receiverKey: b)
        let onR = try? PairingCrypto.pairing(privateKey: r, peerPublicKey: a, senderID: "S", receiverID: "R", senderKey: a, receiverKey: b)
        check("both Macs: same code and same key",
              onS != nil && onS?.code == onR?.code && keyData(onS?.key) == keyData(onR?.key))
        check("code has 6 digits", onS?.code.filter(\.isNumber).count == 6)
        // A machine in the middle runs one key exchange with each Mac: the codes differ.
        let middleS = try? PairingCrypto.pairing(privateKey: s, peerPublicKey: x, senderID: "S", receiverID: "R", senderKey: a, receiverKey: x)
        let middleR = try? PairingCrypto.pairing(privateKey: r, peerPublicKey: x, senderID: "S", receiverID: "R", senderKey: x, receiverKey: b)
        check("man in the middle: different codes", middleS != nil && middleS?.code != middleR?.code)
        check("commitment matches only its own key",
              PairingCrypto.commitment(to: a) == PairingCrypto.commitment(to: a) && PairingCrypto.commitment(to: a) != PairingCrypto.commitment(to: x))

        print("▶︎ First connection: pairing (loopback TCP)")
        let macbook = PairingStore.inMemory(), imac = PairingStore.inMemory()
        var o = connect(client: macbook, server: imac, allowPairing: true, serverConfirms: true)
        check("both Macs show the same code", o.clientCode != nil && o.clientCode == o.serverCode)
        check("both sides paired and authenticated", o.clientAuthenticated && o.serverAuthenticated)
        check("same key stored",
              macbook.peer?.id == "imac-test" && imac.peer?.id == "macbook-test"
                  && keyData(macbook.key(for: "imac-test")) == keyData(imac.key(for: "macbook-test"))
                  && macbook.key(for: "imac-test") != nil)
        check("encrypted messages arrive (JSON + input event + reply)",
              o.serverGot.contains("ping") && o.serverGot.contains("binary1:100") && o.clientGot.contains("pong"))
        check("both Macs share media keys, one per direction", sameMediaKeys(o))
        let firstMedia = o.clientMedia

        print("▶︎ Reconnecting with stored key")
        o = connect(client: macbook, server: imac, allowPairing: false, serverConfirms: false)
        check("authenticated without code", o.clientAuthenticated && o.serverAuthenticated && o.clientCode == nil && o.serverCode == nil)
        check("messages arrive", o.serverGot.contains("ping") && o.clientGot.contains("pong"))
        check("fresh media keys for this connection",
              sameMediaKeys(o) && keyData(o.clientMedia?.toReceiver) != keyData(firstMedia?.toReceiver))

        print("▶︎ Unknown MacBook connects automatically")
        o = connect(client: .inMemory(), server: imac, allowPairing: false, serverConfirms: true)
        check("no authentication, no code on the iMac",
              !o.serverAuthenticated && !o.clientAuthenticated && o.serverCode == nil && o.clientEvents.contains("notPaired"))

        print("▶︎ iMac declines pairing")
        let strangerStore = PairingStore.inMemory(), fresh = PairingStore.inMemory()
        o = connect(client: strangerStore, server: fresh, allowPairing: true, serverConfirms: false)
        check("MacBook learns of the refusal", o.clientEvents.contains { $0.hasPrefix("failed") })
        check("nothing stored, no authentication",
              strangerStore.peer == nil && fresh.peer == nil && !o.serverAuthenticated && !o.clientAuthenticated)

        print("▶︎ Fake iMac with wrong key")
        let fakeIMac = PairingStore.inMemory()
        try? fakeIMac.save(peer: PairedPeer(id: "macbook-test", name: "Test-MacBook"), key: SymmetricKey(size: .bits256))
        o = connect(client: macbook, server: fakeIMac, allowPairing: false, serverConfirms: false)
        check("MacBook rejects it", !o.clientAuthenticated && !o.serverAuthenticated && o.clientEvents.contains("notPaired"))
        check("stored pairing remains", macbook.peer?.id == "imac-test")

        print("▶︎ Paired iMac: another device wants to pair (e.g. over Wi-Fi)")
        o = connect(client: .inMemory(), clientID: "other-macbook", server: imac, allowPairing: true, serverConfirms: true)
        check("no code, no authentication", o.serverCode == nil && o.clientCode == nil && !o.serverAuthenticated && !o.clientAuthenticated)
        check("the device learns why", o.clientEvents.contains { $0.hasPrefix("failed") && $0.contains("Unpair") })
        check("iMac pairing remains", imac.peer?.id == "macbook-test")

        print("▶︎ Paired MacBook: another “iMac” wants to pair")
        o = connect(client: macbook, server: .inMemory(), serverID: "other-imac", allowPairing: true, serverConfirms: true)
        check("no code, no authentication", o.serverCode == nil && o.clientCode == nil && !o.serverAuthenticated && !o.clientAuthenticated)
        check("MacBook says why", o.clientEvents.contains { $0.hasPrefix("failed") && $0.contains("Unpair") })
        check("MacBook pairing remains", macbook.peer?.id == "imac-test")

        print("▶︎ After “Unpair” on both Macs: pair again")
        imac.forget()
        let newMacBook = PairingStore.inMemory()
        o = connect(client: newMacBook, clientID: "new-macbook", server: imac, allowPairing: true, serverConfirms: true)
        check("paired and authenticated", o.clientCode != nil && o.clientCode == o.serverCode && o.clientAuthenticated && o.serverAuthenticated)
        check("iMac knows only the new MacBook", imac.peer?.id == "new-macbook" && imac.key(for: "macbook-test") == nil)

        if CommandLine.arguments.contains("--keychain") {
            print("▶︎ Keychain (separate test entry, deleted afterwards)")
            let service = "local.duodisplay.pairing.selftest"
            let store = PairingStore(keychainService: service)
            store.forget()
            let stored = SymmetricKey(size: .bits256)
            do {
                try store.save(peer: PairedPeer(id: "keychain-test", name: "Test"), key: stored)
                let reloaded = PairingStore(keychainService: service)
                check("pairing survives a restart",
                      reloaded.peer == PairedPeer(id: "keychain-test", name: "Test")
                          && keyData(reloaded.key(for: "keychain-test")) == keyData(stored))
                reloaded.forget()
                check("unpairing deletes the entry", PairingStore(keychainService: service).peer == nil)
            } catch {
                check("save: \(error.localizedDescription)", false)
            }
        }

        print(ok ? "\nRESULT: OK" : "\nRESULT: FAILED")
        return ok
    }

    private static func keyData(_ key: SymmetricKey?) -> Data? {
        key?.withUnsafeBytes { Data($0) }
    }

    private static func sameMediaKeys(_ o: Outcome) -> Bool {
        guard let c = o.clientMedia, let s = o.serverMedia else { return false }
        return keyData(c.toReceiver) == keyData(s.toReceiver) && keyData(c.toSender) == keyData(s.toSender)
            && keyData(c.toReceiver) != keyData(c.toSender)
    }

    private struct Outcome {
        var clientEvents: [String] = []
        var clientCode: String?
        var serverCode: String?
        var clientAuthenticated = false
        var serverAuthenticated = false
        var serverGot: [String] = []
        var clientGot: [String] = []
        var clientMedia: MediaKeys?
        var serverMedia: MediaKeys?
    }

    private final class Keep { var objects: [AnyObject] = [] }

    /// One connection MacBook → iMac with the real ControlChannel and handshakes.
    private static func connect(client clientStore: PairingStore, clientID: String = "macbook-test",
                                server serverStore: PairingStore, serverID: String = "imac-test",
                                allowPairing: Bool, serverConfirms: Bool) -> Outcome {
        let out = OSAllocatedUnfairLock(initialState: Outcome())
        let done = DispatchSemaphore(value: 0)
        let serverQueue = DispatchQueue(label: "pairtest.server")
        let clientQueue = DispatchQueue(label: "pairtest.client")
        let keep = Keep()   // serverQueue only

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: params) else { return Outcome() }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { connection in
            let channel = ControlChannel(connection: connection, queue: serverQueue)
            let handshake = ServerHandshake(channel: channel, store: serverStore, ownID: serverID, ownName: "Test-iMac")
            handshake.onEvent = { event in
                switch event {
                case .authenticated(_, _, let media):
                    out.withLock { $0.serverAuthenticated = true; $0.serverMedia = media }
                case .pairingCode(let code, _):
                    out.withLock { $0.serverCode = code }
                    serverQueue.async {
                        if serverConfirms { handshake.confirmPairing() } else { handshake.cancelPairing("declined") }
                    }
                case .paired, .failed:
                    break
                }
            }
            channel.onMessage = { [weak channel] message in
                guard handshake.isAuthenticated else { return handshake.handle(message) }
                out.withLock { $0.serverGot.append(message.kind.rawValue) }
                if message.kind == .ping { channel?.send(ControlMessage(.pong)) }
            }
            channel.onBinary = { kind, data in
                out.withLock { $0.serverGot.append("binary\(kind.rawValue):\(data.count)") }
            }
            keep.objects.append(channel)
            channel.start()
        }
        listener.start(queue: serverQueue)
        guard ready.wait(timeout: .now() + 3) == .success, let port = listener.port else {
            listener.cancel()
            return Outcome()
        }

        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let channel = ControlChannel(connection: connection, queue: clientQueue)
        let handshake = ClientHandshake(channel: channel, store: clientStore, ownID: clientID, allowPairing: allowPairing)
        handshake.onEvent = { [weak channel] event in
            switch event {
            case .authenticated(_, let media):
                out.withLock { $0.clientAuthenticated = true; $0.clientMedia = media }
                channel?.send(ControlMessage(.ping))
                channel?.send(.inputEvent, Data(repeating: 7, count: 100))
            case .pairingCode(let code, _):
                out.withLock { $0.clientCode = code }
                clientQueue.async { handshake.confirmPairing() }
            case .paired:
                out.withLock { $0.clientEvents.append("paired") }
            case .notPaired:
                out.withLock { $0.clientEvents.append("notPaired") }
                done.signal()
            case .failed(let text):
                out.withLock { $0.clientEvents.append("failed: \(text)") }
                done.signal()
            }
        }
        channel.onReady = { [weak channel] in channel?.send(handshake.hello(name: "Test-MacBook", udpPort: 1234)) }
        channel.onMessage = { message in
            guard handshake.isAuthenticated else { return handshake.handle(message) }
            out.withLock { $0.clientGot.append(message.kind.rawValue) }
            if message.kind == .pong { done.signal() }
        }
        channel.onClose = { _ in done.signal() }
        channel.start()

        _ = done.wait(timeout: .now() + 5)
        Thread.sleep(forTimeInterval: 0.1)   // let the iMac side record its last messages
        channel.close()
        listener.cancel()
        serverQueue.sync {
            keep.objects.forEach { ($0 as? ControlChannel)?.close() }
            keep.objects.removeAll()
        }
        return out.withLock { $0 }
    }
}
