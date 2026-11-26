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
                return fail("Invalid response from the iMac.")
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
            guard let id = message.deviceID, !id.isEmpty else { return fail("Invalid response from the iMac.") }
            peerID = id
            peerName = message.name ?? peerName
            guard message.mediaCrypto == MediaCrypto.version else { return failVersion(message.mediaCrypto) }
            pairOrStop()

        case .authFailed:
            fail("“\(message.name ?? peerName)” didn’t recognize this MacBook. To pair again, choose “Unpair” on both Macs, then “Connect” here.")

        case .pairKey:
            guard var ex = exchange, ex.result == nil, let id = peerID, let peerKey = message.publicKey else { return }
            do {
                ex.result = try PairingCrypto.pairing(privateKey: ex.privateKey, peerPublicKey: peerKey,
                                                      senderID: ownID, receiverID: id,
                                                      senderKey: ex.publicKey, receiverKey: peerKey)
            } catch {
                return fail("Pairing failed (invalid key).")
            }
            exchange = ex
            var reveal = ControlMessage(.pairReveal)
            reveal.publicKey = ex.publicKey
            channel.send(reveal)
            onEvent?(.pairingCode(code: ex.result!.code, peerName: peerName))

        case .pairConfirm:
            guard var ex = exchange, let result = ex.result else { return }
            guard PairingCrypto.verify(message.mac, result.key, PairingCrypto.Label.confirmReceiver, [result.transcript]) else {
                return fail("Pairing failed: the codes don’t match.")
            }
            ex.peerConfirmed = true
            exchange = ex
            finishPairingIfDone()

        case .pairCancel:
            fail(message.text ?? "Pairing was cancelled on the iMac.")

        case .ping:
            // An older DuoDisplay on the iMac skips the handshake and starts pinging right away.
            fail("The iMac runs an older DuoDisplay version. Please update both Macs.")

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
        cancel.text = "Pairing was cancelled on the MacBook."
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
            return fail("This MacBook is already paired with “\(paired.name)”. To pair with “\(peerName)”, choose “Unpair” here first, then “Connect”.")
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
            return fail("Could not save the pairing: \(error.localizedDescription)")
        }
        onEvent?(.paired(peer))
        // The iMac now sends a fresh authChallenge.
    }

    /// The iMac's media encryption version (nil = before it existed) differs from ours.
    private func failVersion(_ peerVersion: Int?) {
        let older = (peerVersion ?? 0) < MediaCrypto.version
        fail("“\(peerName)” runs \(older ? "an older" : "a newer") DuoDisplay version. Please update both Macs.")
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
                return fail("“\(message.name ?? "Mac")” runs an older DuoDisplay version. Please update both Macs.")
            }
            guard message.mediaCrypto == MediaCrypto.version else {
                // Understands pairCancel, so it can tell the user why.
                let peerIsOlder = (message.mediaCrypto ?? 0) < MediaCrypto.version
                return cancelPairing("“\(ownName)” runs \(peerIsOlder ? "a newer" : "an older") DuoDisplay version. Please update both Macs.",
                                     local: "“\(message.name ?? "Mac")” runs \(peerIsOlder ? "an older" : "a newer") DuoDisplay version. Please update both Macs.")
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
                return fail("“\(peer.name)” could not prove it is the paired Mac.")
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
                    // The paired MacBook itself lost its key ("Unpair" only there).
                    return cancelPairing(
                        "“\(ownName)” still has the old pairing with this MacBook. To pair again, choose “Unpair” there too.",
                        local: "Pairing request from “\(paired.name)” refused. To pair again, choose “Unpair” here first.")
                }
                return cancelPairing(
                    "“\(ownName)” is already paired with another Mac. Choose “Unpair” there first.",
                    local: "Pairing request from “\(peer?.name ?? "Mac")” refused: this Mac is already paired with “\(paired.name)”.")
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
                return cancelPairing("Pairing failed (invalid data).")
            }
            do {
                ex.result = try PairingCrypto.pairing(privateKey: ex.privateKey, peerPublicKey: peerKey,
                                                      senderID: peer.id, receiverID: ownID,
                                                      senderKey: peerKey, receiverKey: ex.publicKey)
            } catch {
                return cancelPairing("Pairing failed (invalid key).")
            }
            exchange = ex
            onEvent?(.pairingCode(code: ex.result!.code, peer: peer))

        case .pairConfirm:
            guard var ex = exchange, let result = ex.result else { return }
            guard PairingCrypto.verify(message.mac, result.key, PairingCrypto.Label.confirmSender, [result.transcript]) else {
                return cancelPairing("Pairing failed: the codes don’t match.")
            }
            ex.peerConfirmed = true
            exchange = ex
            finishPairingIfDone()

        case .pairCancel:
            exchange = nil
            fail(message.text ?? "Pairing was cancelled on the MacBook.")

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
            return cancelPairing("Could not save the pairing on the iMac: \(error.localizedDescription)")
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
