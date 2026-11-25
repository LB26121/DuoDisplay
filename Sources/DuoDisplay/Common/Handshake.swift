import Foundation
import CryptoKit

/// Pairing state shared by both handshake sides (see Pairing.swift for the protocol).
private struct PairingExchange {
    let privateKey = Curve25519.KeyAgreement.PrivateKey()
    var peerCommit: Data?              // iMac: the MacBook's commitment
    var result: PairingCrypto.Pairing?
    var localConfirmed = false
    var peerConfirmed = false

    var publicKey: Data { privateKey.publicKey.rawRepresentation }
}

/// MacBook side of the connection handshake. Call everything on the channel's queue;
/// `onEvent` is called there too.
final class ClientHandshake {
    enum Event {
        case authenticated(PairedPeer, MediaKeys)
        /// Show the code and ask the user to compare it with the iMac.
        case pairingCode(code: String, peerName: String)
        case paired(PairedPeer)
        /// Automatic connection to a Mac this one is not paired with (pairing needs the user).
        case notPaired(peerName: String)
        case failed(String)
    }

    var onEvent: ((Event) -> Void)?
    private(set) var isAuthenticated = false

    private weak var channel: ControlChannel?
    private let store: PairingStore
    private let ownID: String
    private let allowPairing: Bool
    private let nonce = PairingCrypto.random()
    private var peerID: String?
    private var peerName = "iMac"
    private var exchange: PairingExchange?
    private var finished = false

    init(channel: ControlChannel, store: PairingStore = .shared, ownID: String = DeviceIdentity.id, allowPairing: Bool) {
        self.channel = channel
        self.store = store
        self.ownID = ownID
        self.allowPairing = allowPairing
    }

    func hello(name: String, udpPort: UInt16?) -> ControlMessage {
        var hello = ControlMessage(.hello)
        hello.name = name
        hello.udpPort = udpPort
        hello.deviceID = ownID
        hello.nonce = nonce
        hello.mediaCrypto = MediaCrypto.version
        return hello
    }

    func handle(_ message: ControlMessage) {
        guard !isAuthenticated, !finished, let channel else { return }
        switch message.kind {
        case .authChallenge:
            guard let id = message.deviceID, let nonceR = message.nonce, nonceR.count == 32 else {
                return fail("Ungültige Antwort vom iMac.")
            }
            peerID = id
            peerName = message.name ?? peerName
            guard message.mediaCrypto == MediaCrypto.version else { return failVersion(message.mediaCrypto) }
            guard let key = store.key(for: id) else { return pairOrStop() }
            let fields = [Data(ownID.utf8), Data(id.utf8), nonce, nonceR]
            // Wrong key on one side (e.g. the iMac was paired again): needs a new pairing.
            guard PairingCrypto.verify(message.mac, key, PairingCrypto.Label.authReceiver, fields) else { return pairOrStop() }
            var response = ControlMessage(.authResponse)
            response.mac = PairingCrypto.mac(key, PairingCrypto.Label.authSender, fields)
            channel.send(response)
            let keys = PairingCrypto.sessionKeys(key, nonceS: nonce, nonceR: nonceR)
            channel.enableEncryption(send: keys.toReceiver, receive: keys.toSender)
            isAuthenticated = true
            onEvent?(.authenticated(PairedPeer(id: id, name: peerName),
                                    PairingCrypto.mediaKeys(key, nonceS: nonce, nonceR: nonceR)))

        case .pairRequired:
            guard let id = message.deviceID, !id.isEmpty else { return fail("Ungültige Antwort vom iMac.") }
            peerID = id
            peerName = message.name ?? peerName
            guard message.mediaCrypto == MediaCrypto.version else { return failVersion(message.mediaCrypto) }
            pairOrStop()

        case .authFailed:
            fail("„\(message.name ?? peerName)“ hat dieses MacBook nicht erkannt – zum neu Koppeln auf beiden Macs „Kopplung aufheben“, dann hier „Verbinden“.")

        case .pairKey:
            guard var ex = exchange, ex.result == nil, let id = peerID, let peerKey = message.publicKey else { return }
            do {
                ex.result = try PairingCrypto.pairing(privateKey: ex.privateKey, peerPublicKey: peerKey,
                                                      senderID: ownID, receiverID: id,
                                                      senderKey: ex.publicKey, receiverKey: peerKey)
            } catch {
                return fail("Kopplung fehlgeschlagen (ungültiger Schlüssel).")
            }
            exchange = ex
            var reveal = ControlMessage(.pairReveal)
            reveal.publicKey = ex.publicKey
            channel.send(reveal)
            onEvent?(.pairingCode(code: ex.result!.code, peerName: peerName))

        case .pairConfirm:
            guard var ex = exchange, let result = ex.result else { return }
            guard PairingCrypto.verify(message.mac, result.key, PairingCrypto.Label.confirmReceiver, [result.transcript]) else {
                return fail("Kopplung fehlgeschlagen: Die Codes stimmen nicht überein.")
            }
            ex.peerConfirmed = true
            exchange = ex
            finishPairingIfDone()

        case .pairCancel:
            fail(message.text ?? "Die Kopplung wurde am iMac abgebrochen.")

        case .ping:
            // An older DuoDisplay on the iMac skips the handshake and starts pinging right away.
            fail("Auf dem iMac läuft eine ältere DuoDisplay-Version – bitte auf beiden Macs aktualisieren.")

        default:
            break
        }
    }

    /// The user confirmed that both Macs show the same code.
    func confirmPairing() {
        guard var ex = exchange, let result = ex.result, !ex.localConfirmed else { return }
        ex.localConfirmed = true
        exchange = ex
        var confirm = ControlMessage(.pairConfirm)
        confirm.mac = PairingCrypto.mac(result.key, PairingCrypto.Label.confirmSender, [result.transcript])
        channel?.send(confirm)
        finishPairingIfDone()
    }

    func cancelPairing() {
        guard exchange != nil else { return }
        exchange = nil
        var cancel = ControlMessage(.pairCancel)
        cancel.text = "Die Kopplung wurde am MacBook abgebrochen."
        channel?.send(cancel)
    }

    private func pairOrStop() {
        guard allowPairing else {
            finished = true
            onEvent?(.notPaired(peerName: peerName))
            return
        }
        // Never replace a pairing in passing: a fake "iMac" on the network would otherwise only
        // need one click on this Mac's prompt to receive its screen and control it.
        if let paired = store.peer {
            return fail("Dieses MacBook ist schon mit „\(paired.name)“ gekoppelt. Zum Koppeln mit „\(peerName)“ hier zuerst „Kopplung aufheben“ wählen, dann „Verbinden“.")
        }
        guard exchange == nil, peerID != nil else { return }
        let ex = PairingExchange()
        exchange = ex
        var start = ControlMessage(.pairStart)
        start.commit = PairingCrypto.commitment(to: ex.publicKey)
        channel?.send(start)
    }

    private func finishPairingIfDone() {
        guard let ex = exchange, ex.localConfirmed, ex.peerConfirmed, let result = ex.result, let id = peerID else { return }
        exchange = nil
        let peer = PairedPeer(id: id, name: peerName)
        do {
            try store.save(peer: peer, key: result.key)
        } catch {
            return fail("Die Kopplung konnte nicht gespeichert werden: \(error.localizedDescription)")
        }
        onEvent?(.paired(peer))
        // The iMac now sends a fresh authChallenge.
    }

    /// The iMac's media encryption version (nil = before it existed) differs from ours.
    private func failVersion(_ peerVersion: Int?) {
        let older = (peerVersion ?? 0) < MediaCrypto.version
        fail("Auf „\(peerName)“ läuft eine \(older ? "ältere" : "neuere") DuoDisplay-Version – bitte auf beiden Macs aktualisieren.")
    }

    private func fail(_ text: String) {
        exchange = nil
        finished = true
        onEvent?(.failed(text))
    }
}

/// iMac side of the connection handshake. Call everything on the channel's queue;
/// `onEvent` is called there too.
final class ServerHandshake {
    enum Event {
        case authenticated(hello: ControlMessage, peer: PairedPeer, media: MediaKeys)
        /// Show the code and ask the user to compare it with the MacBook.
        case pairingCode(code: String, peer: PairedPeer)
        case paired(PairedPeer)
        case failed(String)
    }

    var onEvent: ((Event) -> Void)?
    private(set) var isAuthenticated = false

    private weak var channel: ControlChannel?
    private let store: PairingStore
    private let ownID: String
    private let ownName: String
    private var hello: ControlMessage?
    private var nonceR: Data?
    private var exchange: PairingExchange?
    private var finished = false

    init(channel: ControlChannel, store: PairingStore = .shared, ownID: String = DeviceIdentity.id, ownName: String) {
        self.channel = channel
        self.store = store
        self.ownID = ownID
        self.ownName = ownName
    }

    private var peer: PairedPeer? {
        guard let hello, let id = hello.deviceID else { return nil }
        return PairedPeer(id: id, name: hello.name ?? "Mac")
    }

    func handle(_ message: ControlMessage) {
        guard !isAuthenticated, !finished, let channel else { return }
        switch message.kind {
        case .hello:
            guard hello == nil else { return }
            guard let id = message.deviceID, !id.isEmpty, let nonce = message.nonce, nonce.count == 32 else {
                return fail("„\(message.name ?? "Mac")“ nutzt eine ältere DuoDisplay-Version – bitte auf beiden Macs aktualisieren.")
            }
            guard message.mediaCrypto == MediaCrypto.version else {
                // Understands pairCancel, so it can tell the user why.
                let peerIsOlder = (message.mediaCrypto ?? 0) < MediaCrypto.version
                return cancelPairing("Auf „\(ownName)“ läuft eine \(peerIsOlder ? "neuere" : "ältere") DuoDisplay-Version – bitte auf beiden Macs aktualisieren.",
                                     local: "„\(message.name ?? "Mac")“ nutzt eine \(peerIsOlder ? "ältere" : "neuere") DuoDisplay-Version – bitte auf beiden Macs aktualisieren.")
            }
            hello = message
            if store.key(for: id) != nil {
                sendChallenge()
            } else {
                var required = ControlMessage(.pairRequired)
                required.deviceID = ownID
                required.name = ownName
                required.mediaCrypto = MediaCrypto.version
                channel.send(required)
            }

        case .authResponse:
            guard let hello, let peer, let nonceS = hello.nonce, let nonceR, let key = store.key(for: peer.id) else { return }
            let fields = [Data(peer.id.utf8), Data(ownID.utf8), nonceS, nonceR]
            guard PairingCrypto.verify(message.mac, key, PairingCrypto.Label.authSender, fields) else {
                var failed = ControlMessage(.authFailed)
                failed.deviceID = ownID
                failed.name = ownName
                channel.send(failed)
                return fail("„\(peer.name)“ konnte sich nicht als gekoppelter Mac ausweisen.")
            }
            let keys = PairingCrypto.sessionKeys(key, nonceS: nonceS, nonceR: nonceR)
            channel.enableEncryption(send: keys.toSender, receive: keys.toReceiver)
            isAuthenticated = true
            onEvent?(.authenticated(hello: hello, peer: peer,
                                    media: PairingCrypto.mediaKeys(key, nonceS: nonceS, nonceR: nonceR)))

        case .pairStart:
            guard hello != nil, exchange == nil, let commit = message.commit, commit.count == 32 else { return }
            // Already paired: no prompt at all. Otherwise anyone on the network could bring one up,
            // and a single click would hand them this Mac's keyboard, camera and microphone.
            if let paired = store.peer {
                if paired.id == peer?.id {
                    // The paired MacBook itself lost its key ("Kopplung aufheben" only there).
                    return cancelPairing(
                        "„\(ownName)“ hat noch die alte Kopplung mit diesem MacBook. Zum neu Koppeln dort ebenfalls „Kopplung aufheben“ wählen.",
                        local: "Kopplungsanfrage von „\(paired.name)“ abgelehnt – zum neu Koppeln hier zuerst „Kopplung aufheben“ wählen.")
                }
                return cancelPairing(
                    "„\(ownName)“ ist schon mit einem anderen Mac gekoppelt. Zum Koppeln dort zuerst „Kopplung aufheben“ wählen.",
                    local: "Kopplungsanfrage von „\(peer?.name ?? "Mac")“ abgelehnt – dieser Mac ist schon mit „\(paired.name)“ gekoppelt.")
            }
            var ex = PairingExchange()
            ex.peerCommit = commit
            exchange = ex
            var key = ControlMessage(.pairKey)
            key.publicKey = ex.publicKey
            key.deviceID = ownID
            key.name = ownName
            channel.send(key)

        case .pairReveal:
            guard var ex = exchange, ex.result == nil, let peer, let peerKey = message.publicKey else { return }
            guard PairingCrypto.commitment(to: peerKey) == ex.peerCommit else {
                return cancelPairing("Kopplung fehlgeschlagen (ungültige Daten).")
            }
            do {
                ex.result = try PairingCrypto.pairing(privateKey: ex.privateKey, peerPublicKey: peerKey,
                                                      senderID: peer.id, receiverID: ownID,
                                                      senderKey: peerKey, receiverKey: ex.publicKey)
            } catch {
                return cancelPairing("Kopplung fehlgeschlagen (ungültiger Schlüssel).")
            }
            exchange = ex
            onEvent?(.pairingCode(code: ex.result!.code, peer: peer))

        case .pairConfirm:
            guard var ex = exchange, let result = ex.result else { return }
            guard PairingCrypto.verify(message.mac, result.key, PairingCrypto.Label.confirmSender, [result.transcript]) else {
                return cancelPairing("Kopplung fehlgeschlagen: Die Codes stimmen nicht überein.")
            }
            ex.peerConfirmed = true
            exchange = ex
            finishPairingIfDone()

        case .pairCancel:
            exchange = nil
            fail(message.text ?? "Die Kopplung wurde am MacBook abgebrochen.")

        default:
            break   // nothing else counts before the MacBook has authenticated itself
        }
    }

    /// The user confirmed that both Macs show the same code.
    func confirmPairing() {
        guard var ex = exchange, let result = ex.result, !ex.localConfirmed else { return }
        ex.localConfirmed = true
        exchange = ex
        var confirm = ControlMessage(.pairConfirm)
        confirm.mac = PairingCrypto.mac(result.key, PairingCrypto.Label.confirmReceiver, [result.transcript])
        channel?.send(confirm)
        finishPairingIfDone()
    }

    /// Declines (or aborts) a pairing; the MacBook is told `reason`, this Mac reports `local`
    /// (default: the same text).
    func cancelPairing(_ reason: String, local: String? = nil) {
        exchange = nil
        var cancel = ControlMessage(.pairCancel)
        cancel.text = reason
        channel?.send(cancel)
        fail(local ?? reason)
    }

    private func finishPairingIfDone() {
        guard let ex = exchange, ex.localConfirmed, ex.peerConfirmed, let result = ex.result, let peer else { return }
        exchange = nil
        do {
            try store.save(peer: peer, key: result.key)
        } catch {
            return cancelPairing("Die Kopplung konnte auf dem iMac nicht gespeichert werden: \(error.localizedDescription)")
        }
        onEvent?(.paired(peer))
        sendChallenge()
    }

    private func sendChallenge() {
        guard let peer, let nonceS = hello?.nonce, let key = store.key(for: peer.id) else { return }
        let nonceR = PairingCrypto.random()
        self.nonceR = nonceR
        var challenge = ControlMessage(.authChallenge)
        challenge.deviceID = ownID
        challenge.name = ownName
        challenge.nonce = nonceR
        challenge.mediaCrypto = MediaCrypto.version
        challenge.mac = PairingCrypto.mac(key, PairingCrypto.Label.authReceiver,
                                          [Data(peer.id.utf8), Data(ownID.utf8), nonceS, nonceR])
        channel?.send(challenge)
    }

    private func fail(_ text: String) {
        guard !finished else { return }
        exchange = nil
        finished = true
        onEvent?(.failed(text))
    }
}
