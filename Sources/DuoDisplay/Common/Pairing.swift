import Foundation
import CryptoKit
import Security

/// Pairing: only the one Mac this Mac was paired with may use the control channel.
///
/// First connection ("Connect" on the MacBook) – numeric comparison, like Bluetooth:
///   MacBook → iMac   hello (device id, nonce)
///   iMac → MacBook   pairRequired
///   MacBook → iMac   pairStart   SHA-256 commitment to its ephemeral X25519 key A
///   iMac → MacBook   pairKey     its ephemeral key B
///   MacBook → iMac   pairReveal  A (the iMac checks it against the commitment)
///   Both Macs show a 6-digit code derived from (ids, A, B); the user confirms on BOTH Macs that
///   the codes match. Because A was committed before B was known, a machine in the middle cannot
///   make the two codes match (1 : 1,000,000). Each side then sends pairConfirm (HMAC over the
///   transcript with the derived key) and stores the key in its Keychain.
///
/// Every connection – mutual challenge/response with the stored key:
///   MacBook → iMac   hello (nonce S)
///   iMac → MacBook   authChallenge (nonce R, HMAC proving the iMac knows the key)
///   MacBook → iMac   authResponse (HMAC proving the MacBook knows the key)
/// From then on every control message (keyboard, pointer, modes) is AES-GCM encrypted and
/// authenticated with per-connection keys (ControlChannel.enableEncryption), and so is every
/// UDP media datagram, with keys of its own (MediaCrypto).
///
/// A Mac that is already paired does not pair again: a new pairing needs "Unpair"
/// first. Otherwise anyone on the network could bring up the prompt on the iMac, and a single
/// click would replace the real MacBook.
enum DeviceIdentity {
    /// Random, stable id of this Mac (not secret).
    static let id: String = {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "pairing.deviceID"), !id.isEmpty { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "pairing.deviceID")
        return id
    }()
}

struct PairedPeer: Codable, Equatable {
    let id: String
    let name: String
}

/// The one Mac this Mac is paired with and the shared key, kept in the login Keychain.
/// Thread-safe.
final class PairingStore {
    static let shared = PairingStore(keychainService: "local.duodisplay.pairing")
    /// Posted on the main thread after the pairing was saved or removed.
    static let didChange = Notification.Name("DuoDisplayPairingDidChange")

    private struct Stored: Codable {
        var peer: PairedPeer
        var key: Data
    }

    private let service: String?   // nil: memory only (self tests)
    private let lock = NSLock()
    private var loaded = false
    private var stored: Stored?

    init(keychainService: String?) {
        service = keychainService
        loaded = keychainService == nil
    }

    static func inMemory() -> PairingStore { PairingStore(keychainService: nil) }

    var peer: PairedPeer? { withStored { $0?.peer } }

    func key(for peerID: String) -> SymmetricKey? {
        withStored { stored in
            guard let stored, stored.peer.id == peerID else { return nil }
            return SymmetricKey(data: stored.key)
        }
    }

    /// Replaces any previous pairing.
    func save(peer: PairedPeer, key: SymmetricKey) throws {
        let value = Stored(peer: peer, key: key.withUnsafeBytes { Data($0) })
        lock.lock()
        defer { lock.unlock() }
        if let service {
            let data = try JSONEncoder().encode(value)
            SecItemDelete(Self.query(service) as CFDictionary)
            var add = Self.query(service)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "DuoDisplay Pairing"
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw DDError("Keychain error \(status)")
            }
        }
        stored = value
        loaded = true
        notify()
    }

    func forget() {
        lock.lock()
        if let service { SecItemDelete(Self.query(service) as CFDictionary) }
        stored = nil
        loaded = true
        lock.unlock()
        notify()
    }

    private func withStored<T>(_ body: (Stored?) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        if !loaded, let service {
            loaded = true
            var query = Self.query(service)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
                stored = try? JSONDecoder().decode(Stored.self, from: data)
            }
        }
        return body(stored)
    }

    private static func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "peer"]
    }

    private func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }
}

enum PairingCrypto {
    enum Label {
        static let commit = "DuoDisplay commit v1"
        static let transcript = "DuoDisplay pair v1"
        static let code = "DuoDisplay code v1"
        static let pairingKey = "DuoDisplay pairing key v1"
        static let confirmSender = "DuoDisplay confirm MacBook v1"
        static let confirmReceiver = "DuoDisplay confirm iMac v1"
        static let authSender = "DuoDisplay auth MacBook v1"
        static let authReceiver = "DuoDisplay auth iMac v1"
        static let session = "DuoDisplay session v1"
    }

    struct Pairing {
        let key: SymmetricKey
        /// "123 456"
        let code: String
        let transcript: Data
    }

    static func random(_ count: Int = 32) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }

    /// Unambiguous encoding: label, then every field length-prefixed.
    static func pack(_ label: String, _ fields: [Data]) -> Data {
        var data = Data(label.utf8)
        for field in fields {
            data.appendLE(UInt32(field.count))
            data.append(field)
        }
        return data
    }

    static func commitment(to publicKey: Data) -> Data {
        Data(SHA256.hash(data: pack(Label.commit, [publicKey])))
    }

    /// Both sides call this with the same ids and public keys (A = MacBook's, B = iMac's).
    static func pairing(privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublicKey: Data,
                        senderID: String, receiverID: String, senderKey: Data, receiverKey: Data) throws -> Pairing {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let transcript = Data(SHA256.hash(data: pack(Label.transcript, [Data(senderID.utf8), Data(receiverID.utf8),
                                                                         senderKey, receiverKey])))
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript,
                                                 sharedInfo: Data(Label.pairingKey.utf8), outputByteCount: 32)
        let digest = Array(SHA256.hash(data: pack(Label.code, [transcript])))
        let number = (UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])) % 1_000_000
        let digits = String(format: "%06u", number)
        return Pairing(key: key, code: String(digits.prefix(3)) + " " + String(digits.suffix(3)), transcript: transcript)
    }

    static func mac(_ key: SymmetricKey, _ label: String, _ fields: [Data]) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: pack(label, fields), using: key))
    }

    /// Constant-time comparison.
    static func verify(_ mac: Data?, _ key: SymmetricKey, _ label: String, _ fields: [Data]) -> Bool {
        guard let mac else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: pack(label, fields), using: key)
    }

    /// Fresh keys for every connection, one per direction.
    static func sessionKeys(_ key: SymmetricKey, nonceS: Data, nonceR: Data) -> (toReceiver: SymmetricKey, toSender: SymmetricKey) {
        let salt = pack(Label.session, [nonceS, nonceR])
        func derive(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: Data(info.utf8), outputByteCount: 32)
        }
        return (derive("MacBook to iMac"), derive("iMac to MacBook"))
    }

    /// Fresh keys for the UDP media streams of every connection, one per direction
    /// (independent of the control channel keys: same salt, different info).
    static func mediaKeys(_ key: SymmetricKey, nonceS: Data, nonceR: Data) -> MediaKeys {
        let salt = pack(Label.session, [nonceS, nonceR])
        func derive(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: Data(info.utf8), outputByteCount: 32)
        }
        return MediaKeys(toReceiver: derive("media MacBook to iMac"), toSender: derive("media iMac to MacBook"))
    }
}

/// AES-GCM for one direction of a control channel. The nonce is the message counter, which is
/// never reused: every connection derives new keys.
struct ChannelCipher {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    init(key: SymmetricKey) { self.key = key }

    /// Returns ciphertext + 16-byte tag.
    mutating func seal(_ plain: Data) throws -> Data {
        let box = try AES.GCM.seal(plain, using: key, nonce: nextNonce())
        return box.ciphertext + box.tag
    }

    mutating func open(_ sealed: Data) throws -> Data {
        guard sealed.count >= 16 else { throw DDError("Message too short") }
        let box = try AES.GCM.SealedBox(nonce: nextNonce(), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        return try AES.GCM.open(box, using: key)
    }

    private mutating func nextNonce() throws -> AES.GCM.Nonce {
        counter += 1
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try AES.GCM.Nonce(data: bytes)
    }
}
