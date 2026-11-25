import Foundation
import Network
import CryptoKit
import os

/// `DuoDisplay --pairtest`: pairing, authentication and encryption of the control channel.
/// Both Macs run in this process over loopback TCP, with in-memory key stores (the Keychain is
/// not touched).
enum PairingSelfTest {
    static func run() -> Bool {
        print("DuoDisplay Kopplungs-Selbsttest\n")
        var ok = true
        func check(_ name: String, _ condition: Bool) {
            print((condition ? "  ✓ " : "  ✗ ") + name)
            ok = ok && condition
        }

        print("▶︎ Verschlüsselung des Steuerkanals")
        let key = SymmetricKey(size: .bits256)
        var sealer = ChannelCipher(key: key)
        let first = (try? sealer.seal(Data("hallo".utf8))) ?? Data()
        let second = (try? sealer.seal(Data("welt".utf8))) ?? Data()
        var opener = ChannelCipher(key: key)
        check("entschlüsselt in Reihenfolge",
              (try? opener.open(first)) == Data("hallo".utf8) && (try? opener.open(second)) == Data("welt".utf8))
        var replay = ChannelCipher(key: key)
        check("ausgelassene / wiederholte Nachricht abgelehnt", (try? replay.open(second)) == nil)
        var tamperedOpener = ChannelCipher(key: key)
        var tampered = first
        tampered[tampered.startIndex] ^= 1
        check("verändertes Byte abgelehnt", (try? tamperedOpener.open(tampered)) == nil)
        var wrongKey = ChannelCipher(key: SymmetricKey(size: .bits256))
        check("falscher Schlüssel abgelehnt", (try? wrongKey.open(first)) == nil)

        print("▶︎ Verschlüsselung der Medienpakete (UDP)")
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
        check("ergibt genau das Datagramm von vorher", open(mediaOpener, d1) == plainDatagram)
        check("Inhalt ist verschlüsselt", d1.range(of: Data(repeating: 0x42, count: 16)) == nil)
        check("vertauschte Reihenfolge wird angenommen", open(mediaOpener, d3) != nil && open(mediaOpener, d2) != nil)
        check("wiederholtes Paket abgelehnt", open(mediaOpener, d2) == nil && open(mediaOpener, d1) == nil)
        var flipped = seal()
        flipped[flipped.count - 30] ^= 1
        check("verändertes Byte abgelehnt", open(mediaOpener, flipped) == nil)
        var otherKind = seal()
        otherKind[0] = AudioPacket.magic
        check("umgeschriebene Paketart abgelehnt", open(mediaOpener, otherKind) == nil)
        check("anderer Schlüssel abgelehnt", open(mediaOpener, seal(MediaSealer(key: SymmetricKey(size: .bits256)))) == nil)
        check("unverschlüsseltes Paket abgelehnt", open(mediaOpener, Data(plainDatagram)) == nil)
        let sound = seal()
        var frame = Data()
        for _ in 0..<5_000 { frame = seal() }
        check("Ton hinter einem großen Bild (5000 Pakete) angenommen", open(mediaOpener, frame) != nil && open(mediaOpener, sound) != nil)
        let old = seal()
        var newest = Data()
        for _ in 0..<20_000 { newest = seal() }
        check("Paket weit hinter dem neuesten abgelehnt", open(mediaOpener, newest) != nil && open(mediaOpener, old) == nil)

        print("▶︎ Code-Vergleich")
        let s = Curve25519.KeyAgreement.PrivateKey()
        let r = Curve25519.KeyAgreement.PrivateKey()
        let m = Curve25519.KeyAgreement.PrivateKey()
        let a = s.publicKey.rawRepresentation, b = r.publicKey.rawRepresentation, x = m.publicKey.rawRepresentation
        let onS = try? PairingCrypto.pairing(privateKey: s, peerPublicKey: b, senderID: "S", receiverID: "R", senderKey: a, receiverKey: b)
        let onR = try? PairingCrypto.pairing(privateKey: r, peerPublicKey: a, senderID: "S", receiverID: "R", senderKey: a, receiverKey: b)
        check("beide Macs: gleicher Code und gleicher Schlüssel",
              onS != nil && onS?.code == onR?.code && keyData(onS?.key) == keyData(onR?.key))
        check("Code hat 6 Ziffern", onS?.code.filter(\.isNumber).count == 6)
        // A machine in the middle runs one key exchange with each Mac: the codes differ.
        let middleS = try? PairingCrypto.pairing(privateKey: s, peerPublicKey: x, senderID: "S", receiverID: "R", senderKey: a, receiverKey: x)
        let middleR = try? PairingCrypto.pairing(privateKey: r, peerPublicKey: x, senderID: "S", receiverID: "R", senderKey: x, receiverKey: b)
        check("Mann in der Mitte: unterschiedliche Codes", middleS != nil && middleS?.code != middleR?.code)
        check("Zusage (Commitment) passt nur zum eigenen Schlüssel",
              PairingCrypto.commitment(to: a) == PairingCrypto.commitment(to: a) && PairingCrypto.commitment(to: a) != PairingCrypto.commitment(to: x))

        print("▶︎ Erstes Verbinden: koppeln (Loopback-TCP)")
        let macbook = PairingStore.inMemory(), imac = PairingStore.inMemory()
        var o = connect(client: macbook, server: imac, allowPairing: true, serverConfirms: true)
        check("beide Macs zeigen denselben Code", o.clientCode != nil && o.clientCode == o.serverCode)
        check("beide Seiten gekoppelt und angemeldet", o.clientAuthenticated && o.serverAuthenticated)
        check("gleicher Schlüssel gespeichert",
              macbook.peer?.id == "imac-test" && imac.peer?.id == "macbook-test"
                  && keyData(macbook.key(for: "imac-test")) == keyData(imac.key(for: "macbook-test"))
                  && macbook.key(for: "imac-test") != nil)
        check("verschlüsselte Nachrichten kommen an (JSON + Eingabe-Event + Antwort)",
              o.serverGot.contains("ping") && o.serverGot.contains("binary1:100") && o.clientGot.contains("pong"))
        check("beide Macs haben dieselben Medienschlüssel, je Richtung einen eigenen", sameMediaKeys(o))
        let firstMedia = o.clientMedia

        print("▶︎ Wiederverbinden mit gespeichertem Schlüssel")
        o = connect(client: macbook, server: imac, allowPairing: false, serverConfirms: false)
        check("ohne Code angemeldet", o.clientAuthenticated && o.serverAuthenticated && o.clientCode == nil && o.serverCode == nil)
        check("Nachrichten kommen an", o.serverGot.contains("ping") && o.clientGot.contains("pong"))
        check("neue Medienschlüssel für diese Verbindung",
              sameMediaKeys(o) && keyData(o.clientMedia?.toReceiver) != keyData(firstMedia?.toReceiver))

        print("▶︎ Fremdes MacBook verbindet sich automatisch")
        o = connect(client: .inMemory(), server: imac, allowPairing: false, serverConfirms: true)
        check("keine Anmeldung, kein Code auf dem iMac",
              !o.serverAuthenticated && !o.clientAuthenticated && o.serverCode == nil && o.clientEvents.contains("notPaired"))

        print("▶︎ iMac lehnt die Kopplung ab")
        let strangerStore = PairingStore.inMemory(), fresh = PairingStore.inMemory()
        o = connect(client: strangerStore, server: fresh, allowPairing: true, serverConfirms: false)
        check("MacBook erfährt die Ablehnung", o.clientEvents.contains { $0.hasPrefix("failed") })
        check("nichts gespeichert, keine Anmeldung",
              strangerStore.peer == nil && fresh.peer == nil && !o.serverAuthenticated && !o.clientAuthenticated)

        print("▶︎ Gefälschter iMac mit falschem Schlüssel")
        let fakeIMac = PairingStore.inMemory()
        try? fakeIMac.save(peer: PairedPeer(id: "macbook-test", name: "Test-MacBook"), key: SymmetricKey(size: .bits256))
        o = connect(client: macbook, server: fakeIMac, allowPairing: false, serverConfirms: false)
        check("MacBook erkennt ihn nicht an", !o.clientAuthenticated && !o.serverAuthenticated && o.clientEvents.contains("notPaired"))
        check("gespeicherte Kopplung bleibt", macbook.peer?.id == "imac-test")

        print("▶︎ Gekoppelter iMac: ein anderes Gerät will koppeln (z. B. über WLAN)")
        o = connect(client: .inMemory(), clientID: "fremdes-macbook", server: imac, allowPairing: true, serverConfirms: true)
        check("kein Code, keine Anmeldung", o.serverCode == nil && o.clientCode == nil && !o.serverAuthenticated && !o.clientAuthenticated)
        check("das Gerät erfährt, warum", o.clientEvents.contains { $0.hasPrefix("failed") && $0.contains("Kopplung aufheben") })
        check("Kopplung des iMac bleibt", imac.peer?.id == "macbook-test")

        print("▶︎ Gekoppeltes MacBook: ein anderer „iMac“ will koppeln")
        o = connect(client: macbook, server: .inMemory(), serverID: "fremder-imac", allowPairing: true, serverConfirms: true)
        check("kein Code, keine Anmeldung", o.serverCode == nil && o.clientCode == nil && !o.serverAuthenticated && !o.clientAuthenticated)
        check("MacBook sagt, warum", o.clientEvents.contains { $0.hasPrefix("failed") && $0.contains("Kopplung aufheben") })
        check("Kopplung des MacBook bleibt", macbook.peer?.id == "imac-test")

        print("▶︎ Nach „Kopplung aufheben“ auf beiden Macs: neu koppeln")
        imac.forget()
        let newMacBook = PairingStore.inMemory()
        o = connect(client: newMacBook, clientID: "neues-macbook", server: imac, allowPairing: true, serverConfirms: true)
        check("gekoppelt und angemeldet", o.clientCode != nil && o.clientCode == o.serverCode && o.clientAuthenticated && o.serverAuthenticated)
        check("iMac kennt nur noch das neue MacBook", imac.peer?.id == "neues-macbook" && imac.key(for: "macbook-test") == nil)

        if CommandLine.arguments.contains("--keychain") {
            print("▶︎ Schlüsselbund (eigener Test-Eintrag, wird wieder gelöscht)")
            let service = "local.duodisplay.pairing.selftest"
            let store = PairingStore(keychainService: service)
            store.forget()
            let stored = SymmetricKey(size: .bits256)
            do {
                try store.save(peer: PairedPeer(id: "keychain-test", name: "Test"), key: stored)
                let reloaded = PairingStore(keychainService: service)
                check("Kopplung übersteht einen Neustart",
                      reloaded.peer == PairedPeer(id: "keychain-test", name: "Test")
                          && keyData(reloaded.key(for: "keychain-test")) == keyData(stored))
                reloaded.forget()
                check("Kopplung aufheben löscht den Eintrag", PairingStore(keychainService: service).peer == nil)
            } catch {
                check("speichern: \(error.localizedDescription)", false)
            }
        }

        print(ok ? "\nERGEBNIS: OK" : "\nERGEBNIS: FEHLER")
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
                        if serverConfirms { handshake.confirmPairing() } else { handshake.cancelPairing("abgelehnt") }
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
