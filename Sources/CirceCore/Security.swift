import CryptoKit
import Foundation

/// Where Circe keeps its small amount of local state.
public enum CirceStorage {
    public static var directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Circe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }()
}

/// Long-term device identity (Curve25519). Stored with 0600 permissions; never leaves the device.
public final class DeviceIdentity: @unchecked Sendable {
    public let deviceID: String
    public let privateKey: Curve25519.KeyAgreement.PrivateKey
    public var publicKey: Data { privateKey.publicKey.rawRepresentation }

    public init(deviceID: String, privateKey: Curve25519.KeyAgreement.PrivateKey) {
        self.deviceID = deviceID
        self.privateKey = privateKey
    }

    private struct Stored: Codable { var deviceID: String; var key: Data }

    /// Loads (or creates) the identity at `name` inside Circe's storage directory.
    public static func loadOrCreate(name: String = "identity.json") -> DeviceIdentity {
        let url = CirceStorage.directory.appendingPathComponent(name)
        if let data = try? Data(contentsOf: url),
           let s = try? JSONDecoder().decode(Stored.self, from: data),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: s.key) {
            return DeviceIdentity(deviceID: s.deviceID, privateKey: key)
        }
        let id = DeviceIdentity(deviceID: UUID().uuidString, privateKey: .init())
        if let data = try? JSONEncoder().encode(Stored(deviceID: id.deviceID, key: id.privateKey.rawRepresentation)) {
            FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
        return id
    }

    public static func ephemeral() -> DeviceIdentity { DeviceIdentity(deviceID: UUID().uuidString, privateKey: .init()) }
}

/// Short human-comparable fingerprint of a public key, e.g. "3F9A-12C0-77DE".
public func keyFingerprint(_ key: Data) -> String {
    let h = SHA256.hash(data: key).prefix(6).map { String(format: "%02X", $0) }.joined()
    return stride(from: 0, to: h.count, by: 4).map { i -> String in
        let s = h.index(h.startIndex, offsetBy: i)
        return String(h[s..<h.index(s, offsetBy: 4)])
    }.joined(separator: "-")
}

/// Persistent set of peers we trust, keyed by device ID.
public final class TrustStore: @unchecked Sendable {
    public struct Peer: Codable, Sendable, Equatable {
        public var deviceID: String
        public var name: String
        public var publicKey: Data
        public var lastSeen: Date
    }

    private let url: URL
    private let lock = NSLock()
    private var peers: [String: Peer]

    public init(name: String) {
        url = CirceStorage.directory.appendingPathComponent(name)
        peers = (try? JSONDecoder().decode([String: Peer].self, from: Data(contentsOf: url))) ?? [:]
    }

    public func peer(_ id: String) -> Peer? { lock.withLock { peers[id] } }
    public var all: [Peer] { lock.withLock { Array(peers.values) } }

    public func isTrusted(deviceID: String, key: Data) -> Bool {
        lock.withLock { peers[deviceID]?.publicKey == key }
    }

    public func trust(deviceID: String, name: String, key: Data) {
        lock.withLock {
            peers[deviceID] = Peer(deviceID: deviceID, name: name, publicKey: key, lastSeen: Date())
            save()
        }
    }

    public func forget(deviceID: String) {
        lock.withLock { peers[deviceID] = nil; save() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(peers) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Symmetric session keys derived from the handshake. ChaCha20-Poly1305 with counter nonces.
public struct SessionKeys: Sendable {
    public let send: SymmetricKey
    public let receive: SymmetricKey
    /// Bound to the full handshake transcript; used for confirmation / channel binding.
    public let transcriptHash: Data

    /// Mutual key derivation. Both static keys participate so possession of each static key is proven.
    /// - es/se terms bind identities; ee gives forward secrecy.
    public static func derive(isClient: Bool,
                              localStatic: Curve25519.KeyAgreement.PrivateKey,
                              localEphemeral: Curve25519.KeyAgreement.PrivateKey,
                              remoteStatic: Data, remoteEphemeral: Data,
                              transcript: Data) throws -> SessionKeys {
        let rs = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteStatic)
        let re = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteEphemeral)
        let ee = try localEphemeral.sharedSecretFromKeyAgreement(with: re)
        // Order the static/ephemeral mixes identically on both sides.
        let clientStaticHostEph = isClient ? try localStatic.sharedSecretFromKeyAgreement(with: re)
                                           : try localEphemeral.sharedSecretFromKeyAgreement(with: rs)
        let clientEphHostStatic = isClient ? try localEphemeral.sharedSecretFromKeyAgreement(with: rs)
                                           : try localStatic.sharedSecretFromKeyAgreement(with: re)
        var ikm = Data()
        for s in [ee, clientStaticHostEph, clientEphHostStatic] { s.withUnsafeBytes { ikm.append(contentsOf: $0) } }
        let th = Data(SHA256.hash(data: transcript))
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: th,
                                         info: Data("circe v1 session".utf8), outputByteCount: 64)
        let bytes = okm.withUnsafeBytes { Data($0) }
        let c2h = SymmetricKey(data: bytes.prefix(32))
        let h2c = SymmetricKey(data: bytes.suffix(32))
        return SessionKeys(send: isClient ? c2h : h2c, receive: isClient ? h2c : c2h, transcriptHash: th)
    }
}

/// Seals/opens frames with strictly increasing counters (replay & reorder protection over a reliable stream).
public struct SecureChannel: Sendable {
    private let keys: SessionKeys
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    public init(keys: SessionKeys) { self.keys = keys }

    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var n = Data(repeating: 0, count: 4)
        withUnsafeBytes(of: counter.bigEndian) { n.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: n)
    }

    public mutating func seal(_ plaintext: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: keys.send, nonce: Self.nonce(sendCounter))
        sendCounter += 1
        return box.ciphertext + box.tag
    }

    public mutating func open(_ data: Data) throws -> Data {
        guard data.count >= 16 else { throw WireError.decryptFailed }
        let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(receiveCounter),
                                           ciphertext: data.prefix(data.count - 16),
                                           tag: data.suffix(16))
        guard let plain = try? ChaChaPoly.open(box, using: keys.receive) else { throw WireError.decryptFailed }
        receiveCounter += 1
        return plain
    }
}

/// Generates a 6-digit pairing PIN.
public func generatePairingPIN() -> String {
    String(format: "%06d", Int.random(in: 0..<1_000_000))
}

/// Constant-time string comparison for secrets.
public func secureEquals(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<x.count { diff |= x[i] ^ y[i] }
    return diff == 0
}
