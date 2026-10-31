import CryptoKit
import Foundation
import Network

/// Splits encoded video frames into encrypted datagrams with XOR parity (FEC) and reassembles them.
/// One parity shard protects each group of `groupSize` data shards, so any single loss per group
/// is repaired without a retransmit; heavier loss drops the frame and the client asks for a keyframe.
public enum VideoDatagrams {
    public static let shardSize = 1_150
    public static let groupSize = 8
    static let headerSize = 16

    /// Datagram header (plaintext inside the encryption):
    /// u32 frameNumber, u16 shardIndex, u16 dataShards, u16 parityShards, u32 payloadLength, u16 groupSize.
    /// `groupSize` is adaptive: smaller groups = more parity = more loss tolerance.
    public static func packetize(frameNumber: UInt32, payload: Data, groupSize: Int = groupSize) -> [Data] {
        let groupSize = max(1, groupSize)
        let dataShards = max(1, (payload.count + shardSize - 1) / shardSize)
        let parityShards = (dataShards + groupSize - 1) / groupSize
        var shards: [Data] = []
        shards.reserveCapacity(dataShards + parityShards)
        var parity = [[UInt8]](repeating: [UInt8](repeating: 0, count: shardSize), count: parityShards)
        payload.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for i in 0..<dataShards {
                let start = i * shardSize
                let end = min(start + shardSize, payload.count)
                var w = ByteWriter(capacity: headerSize + shardSize)
                header(&w, frameNumber, UInt16(i), UInt16(dataShards), UInt16(parityShards), UInt32(payload.count), UInt16(groupSize))
                let chunk = UnsafeRawBufferPointer(rebasing: p[start..<end])
                w.bytes(Data(chunk))
                let g = i / groupSize
                for (k, b) in chunk.enumerated() { parity[g][k] ^= b }
                shards.append(w.data)
            }
        }
        for g in 0..<parityShards {
            var w = ByteWriter(capacity: headerSize + shardSize)
            header(&w, frameNumber, UInt16(dataShards + g), UInt16(dataShards), UInt16(parityShards), UInt32(payload.count), UInt16(groupSize))
            w.bytes(Data(parity[g]))
            shards.append(w.data)
        }
        return shards
    }

    private static func header(_ w: inout ByteWriter, _ f: UInt32, _ i: UInt16, _ d: UInt16, _ p: UInt16, _ len: UInt32, _ g: UInt16) {
        w.u32(f); w.u16(i); w.u16(d); w.u16(p); w.u32(len); w.u16(g)
    }
}

/// Reassembles frames from shards; repairs single losses per group using parity.
public final class FrameReassembler {
    private struct Partial {
        var dataShards: Int
        var parityShards: Int
        var groupSize: Int
        var length: Int
        var shards: [Int: Data] = [:]
        var firstSeen: UInt64
    }

    private var partials: [UInt32: Partial] = [:]
    private var completed = Set<UInt32>()
    private var highestDelivered: UInt32?
    public private(set) var framesLost = 0
    public private(set) var framesRepaired = 0

    public init() {}

    /// Returns any frame completed by this shard, plus whether an older frame was declared lost.
    public func add(_ datagram: Data, now: UInt64 = Clock.micros()) -> (frames: [(UInt32, Data)], lost: Bool) {
        var r = ByteReader(datagram)
        guard let f = try? r.u32(), let idx = try? r.u16(), let d = try? r.u16(), let p = try? r.u16(),
              let len = try? r.u32(), let g = try? r.u16() else { return ([], false) }
        let dataShards = Int(d), parityShards = Int(p), length = Int(len), groupSize = Int(g)
        guard dataShards > 0, groupSize > 0, parityShards == (dataShards + groupSize - 1) / groupSize, Int(idx) < dataShards + parityShards, length <= dataShards * VideoDatagrams.shardSize,
              dataShards <= 60_000 else { return ([], false) }
        if completed.contains(f) { return ([], false) }
        if let h = highestDelivered, f &- h > UInt32.max / 2 { return ([], false) } // older than delivered

        // Every shard must have exactly the size its position implies; malformed input is dropped, never trusted.
        let i = Int(idx)
        let payloadSize = r.remaining
        let expected = i >= dataShards ? VideoDatagrams.shardSize
            : i == dataShards - 1 ? length - i * VideoDatagrams.shardSize : VideoDatagrams.shardSize
        guard length > (dataShards - 1) * VideoDatagrams.shardSize, payloadSize == expected else { return ([], false) }

        var part = partials[f] ?? Partial(dataShards: dataShards, parityShards: parityShards, groupSize: groupSize,
                                              length: length, firstSeen: now)
        guard part.dataShards == dataShards, part.parityShards == parityShards, part.groupSize == groupSize,
              part.length == length else { return ([], false) }
        part.shards[Int(idx)] = r.rest()
        var out: [(UInt32, Data)] = []
        if let frame = tryComplete(&part) {
            partials[f] = nil
            completed.insert(f)
            if completed.count > 256 { completed.remove(completed.min()!) }
            out.append((f, frame))
            if highestDelivered == nil || f &- highestDelivered! < UInt32.max / 2 { highestDelivered = f }
        } else {
            partials[f] = part
        }
        // Once a newer frame is complete, older partial frames are useless to the decoder: count them lost.
        // Stragglers that never complete are dropped after 250 ms.
        var lost = false
        for (k, v) in partials {
            let superseded = highestDelivered.map { h in k != h && h &- k < UInt32.max / 2 } ?? false
            if superseded || now &- v.firstSeen > 250_000 {
                partials[k] = nil
                framesLost += 1
                lost = true
            }
        }
        return (out, lost)
    }

    private func tryComplete(_ part: inout Partial) -> Data? {
        let n = part.dataShards
        if (0..<n).allSatisfy({ part.shards[$0] != nil }) { return assemble(part) }
        // Repair: for each group with exactly one missing data shard and its parity present.
        var repaired = false
        for g in 0..<part.parityShards {
            let members = Array((g * part.groupSize)..<min(n, (g + 1) * part.groupSize))
            let missing = members.filter { part.shards[$0] == nil }
            guard missing.count == 1, let parity = part.shards[n + g] else { continue }
            var rec = [UInt8](parity)
            for m in members where m != missing[0] {
                for (k, b) in part.shards[m]!.enumerated() { rec[k] ^= b }
            }
            let m = missing[0]
            let size = m == n - 1 ? part.length - m * VideoDatagrams.shardSize : VideoDatagrams.shardSize
            part.shards[m] = Data(rec.prefix(size))
            repaired = true
        }
        if repaired, (0..<n).allSatisfy({ part.shards[$0] != nil }) {
            framesRepaired += 1
            return assemble(part)
        }
        return nil
    }

    private func assemble(_ part: Partial) -> Data {
        var out = Data(capacity: part.length)
        for i in 0..<part.dataShards { out.append(part.shards[i]!) }
        return out.prefix(part.length)
    }
}

/// Encrypts datagrams with a per-direction key and explicit 64-bit counters (order-independent).
public struct DatagramCipher: Sendable {
    private let key: SymmetricKey
    private var counter: UInt64 = 0
    private var highest: UInt64 = 0
    private var window: UInt64 = 0 // bitmap of the 64 counters below `highest`

    public init(key: SymmetricKey) { self.key = key }

    /// Derives the UDP keys from the TCP session's transcript-bound material.
    public static func keys(from s: SessionKeys, isClient: Bool) -> (send: DatagramCipher, receive: DatagramCipher) {
        func derive(_ base: SymmetricKey) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: base, salt: s.transcriptHash, info: Data("circe v1 udp".utf8), outputByteCount: 32)
        }
        return (DatagramCipher(key: derive(s.send)), DatagramCipher(key: derive(s.receive)))
    }

    public mutating func seal(_ plain: Data) -> Data {
        counter += 1
        var n = Data(repeating: 0, count: 4)
        withUnsafeBytes(of: counter.bigEndian) { n.append(contentsOf: $0) }
        let box = try! ChaChaPoly.seal(plain, using: key, nonce: try! ChaChaPoly.Nonce(data: n))
        var out = Data(capacity: plain.count + 24)
        out.append(n.suffix(8))
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    public mutating func open(_ data: Data) -> Data? {
        guard data.count >= 24 else { return nil }
        let bytes = Data(data)
        let c = bytes.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        // Replay protection: bit k of `window` marks counter (highest - k) as seen.
        if c <= highest {
            let k = highest - c
            if k >= 64 || window & (1 << k) != 0 { return nil }
        }
        let nonce = try! ChaChaPoly.Nonce(data: Data(repeating: 0, count: 4) + bytes.prefix(8))
        guard let box = try? ChaChaPoly.SealedBox(nonce: nonce, ciphertext: bytes.dropFirst(8).dropLast(16), tag: bytes.suffix(16)),
              let plain = try? ChaChaPoly.open(box, using: key) else { return nil }
        if c > highest {
            let shift = c - highest
            window = shift >= 64 ? 0 : window << shift
            highest = c
            window |= 1
        } else {
            window |= 1 << (highest - c)
        }
        return plain
    }
}

/// Client -> host UDP hello/keepalive: magic + session ID in clear (for routing), then a sealed marker.
public enum UDPHello {
    public static let magic = Data("CIRC".utf8)

    public static func make(sessionID: Data, cipher: inout DatagramCipher) -> Data {
        magic + sessionID + cipher.seal(Data("hello".utf8))
    }

    public static func sessionID(of datagram: Data) -> Data? {
        let d = Data(datagram)
        guard d.count > 20 + 24, d.prefix(4) == magic else { return nil }
        return d.subdata(in: 4..<20)
    }

    public static func verify(_ datagram: Data, cipher: inout DatagramCipher) -> Bool {
        let d = Data(datagram)
        guard d.count > 20 else { return false }
        return cipher.open(d.subdata(in: 20..<d.count)) == Data("hello".utf8)
    }
}

extension NWParameters {
    /// UDP tuned for interactive video.
    public static func circeUDP() -> NWParameters {
        let p = NWParameters.udp
        p.serviceClass = .interactiveVideo
        p.includePeerToPeer = true
        return p
    }
}
