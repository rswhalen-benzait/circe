import CommonCrypto
import CryptoKit
import Foundation

/// Minimal unsigned big integer (little-endian 32-bit limbs) — just enough for ARD's Diffie-Hellman.
struct BigUInt: Equatable {
    var limbs: [UInt32]

    init(_ limbs: [UInt32]) { self.limbs = limbs; normalize() }

    /// Big-endian bytes.
    init(bytes: Data) {
        var l: [UInt32] = []
        var i = bytes.endIndex
        while i > bytes.startIndex {
            let lo = max(bytes.startIndex, i - 4)
            var v: UInt32 = 0
            for b in bytes[lo..<i] { v = (v << 8) | UInt32(b) }
            l.append(v)
            i = lo
        }
        self.init(l)
    }

    func bytes(count: Int) -> Data {
        var out = Data(count: count)
        for i in 0..<count {
            let limb = i / 4, shift = (i % 4) * 8
            let v = limb < limbs.count ? UInt8((limbs[limb] >> shift) & 0xFF) : 0
            out[count - 1 - i] = v
        }
        return out
    }

    private mutating func normalize() { while limbs.count > 1 && limbs.last == 0 { limbs.removeLast() }; if limbs.isEmpty { limbs = [0] } }

    var bitWidth: Int {
        guard let top = limbs.last, top != 0 else { return 0 }
        return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    func bit(_ i: Int) -> Bool {
        let l = i / 32
        return l < limbs.count && (limbs[l] >> (i % 32)) & 1 == 1
    }

    static func compare(_ a: BigUInt, _ b: BigUInt) -> Int {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count ? -1 : 1 }
        for i in stride(from: a.limbs.count - 1, through: 0, by: -1) where a.limbs[i] != b.limbs[i] {
            return a.limbs[i] < b.limbs[i] ? -1 : 1
        }
        return 0
    }

    /// a - b, requires a >= b.
    static func sub(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        var r = a.limbs
        var borrow: Int64 = 0
        for i in 0..<r.count {
            var d = Int64(r[i]) - borrow - (i < b.limbs.count ? Int64(b.limbs[i]) : 0)
            borrow = 0
            if d < 0 { d += 1 << 32; borrow = 1 }
            r[i] = UInt32(d)
        }
        return BigUInt(r)
    }

    static func add(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        let n = max(a.limbs.count, b.limbs.count)
        var r = [UInt32](repeating: 0, count: n + 1)
        var carry: UInt64 = 0
        for i in 0..<n {
            let s = UInt64(i < a.limbs.count ? a.limbs[i] : 0) + UInt64(i < b.limbs.count ? b.limbs[i] : 0) + carry
            r[i] = UInt32(s & 0xFFFF_FFFF)
            carry = s >> 32
        }
        r[n] = UInt32(carry)
        return BigUInt(r)
    }

    /// base^exp mod m (m odd) using Montgomery multiplication — fast enough for 4096-bit ARD primes.
    static func powMod(_ base: BigUInt, _ exp: BigUInt, _ m: BigUInt) -> BigUInt {
        let n = m.limbs.count
        let mod = m.limbs
        // -m^-1 mod 2^32 via Newton iteration.
        var inv: UInt32 = 1
        for _ in 0..<5 { inv = inv &* (2 &- mod[0] &* inv) }
        let n0 = 0 &- inv

        func montMul(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
            var t = [UInt32](repeating: 0, count: n + 2)
            for i in 0..<n {
                var c: UInt64 = 0
                let bi = UInt64(b[i])
                for j in 0..<n {
                    let s = UInt64(t[j]) + UInt64(a[j]) * bi + c
                    t[j] = UInt32(truncatingIfNeeded: s); c = s >> 32
                }
                var s = UInt64(t[n]) + c
                t[n] = UInt32(truncatingIfNeeded: s); t[n + 1] = UInt32(s >> 32)
                let q = UInt64(t[0] &* n0)
                s = UInt64(t[0]) + q * UInt64(mod[0])
                c = s >> 32
                for j in 1..<n {
                    s = UInt64(t[j]) + q * UInt64(mod[j]) + c
                    t[j - 1] = UInt32(truncatingIfNeeded: s); c = s >> 32
                }
                s = UInt64(t[n]) + c
                t[n - 1] = UInt32(truncatingIfNeeded: s)
                t[n] = t[n + 1] + UInt32(s >> 32)
                t[n + 1] = 0
            }
            var r = Array(t[0...n])
            // Conditional final subtraction.
            var ge = r[n] != 0
            if !ge {
                ge = true
                for j in stride(from: n - 1, through: 0, by: -1) where r[j] != mod[j] { ge = r[j] > mod[j]; break }
            }
            if ge {
                var borrow: Int64 = 0
                for j in 0..<n {
                    var d = Int64(r[j]) - Int64(mod[j]) - borrow
                    borrow = 0
                    if d < 0 { d += 1 << 32; borrow = 1 }
                    r[j] = UInt32(d)
                }
            }
            return Array(r[0..<n])
        }

        func padded(_ x: BigUInt) -> [UInt32] {
            var v = x
            while compare(v, m) >= 0 { v = sub(v, m) }
            return v.limbs + [UInt32](repeating: 0, count: n - v.limbs.count)
        }

        // R^2 mod m by doubling 1 (2 * 32n) times.
        var r2 = BigUInt([1])
        for _ in 0..<(64 * n) {
            r2 = add(r2, r2)
            if compare(r2, m) >= 0 { r2 = sub(r2, m) }
        }
        let rr = padded(r2)
        let bm = montMul(padded(base), rr)
        var acc = montMul(padded(BigUInt([1])), rr)
        for i in stride(from: exp.bitWidth - 1, through: 0, by: -1) {
            acc = montMul(acc, acc)
            if exp.bit(i) { acc = montMul(acc, bm) }
        }
        var one = [UInt32](repeating: 0, count: n)
        one[0] = 1
        return BigUInt(montMul(acc, one))
    }
}

enum RFBCrypto {
    /// Classic VNC authentication: DES-encrypt the 16-byte challenge with the (bit-reversed) password.
    static func vncAuthResponse(challenge: Data, password: String) -> Data {
        var key = [UInt8](repeating: 0, count: 8)
        for (i, b) in Array(password.utf8.prefix(8)).enumerated() {
            var r: UInt8 = 0
            for bit in 0..<8 where b & (1 << bit) != 0 { r |= 1 << (7 - bit) }
            key[i] = r
        }
        return ecb(kCCAlgorithmDES, key: key, data: challenge)
    }

    /// Apple Remote Desktop (security type 30) Diffie-Hellman credential exchange.
    /// Returns (encrypted credentials, client public key).
    static func ardResponse(generator: Data, prime: Data, serverPublic: Data, username: String, password: String) -> (Data, Data) {
        let keyLength = prime.count
        let p = BigUInt(bytes: prime)
        let g = BigUInt(bytes: generator)
        var privBytes = Data(count: 32)
        privBytes.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let priv = BigUInt(bytes: privBytes)
        let pub = BigUInt.powMod(g, priv, p)
        let shared = BigUInt.powMod(BigUInt(bytes: serverPublic), priv, p)
        let key = Array(Insecure.MD5.hash(data: shared.bytes(count: keyLength)))

        var creds = [UInt8](repeating: 0, count: 128)
        _ = SecRandomCopyBytes(kSecRandomDefault, 128, &creds)
        let u = Array(username.utf8.prefix(63)), pw = Array(password.utf8.prefix(63))
        for (i, b) in u.enumerated() { creds[i] = b }
        creds[u.count] = 0
        for (i, b) in pw.enumerated() { creds[64 + i] = b }
        creds[64 + pw.count] = 0
        let encrypted = ecb(kCCAlgorithmAES128, key: key, data: Data(creds))
        return (encrypted, pub.bytes(count: keyLength))
    }

    private static func ecb(_ alg: Int, key: [UInt8], data: Data) -> Data {
        var out = Data(count: data.count + 16)
        var moved = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { d in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(alg), CCOptions(kCCOptionECBMode), key, key.count, nil,
                        d.baseAddress, data.count, o.baseAddress, outCount, &moved)
            }
        }
        return status == kCCSuccess ? out.prefix(moved) : Data()
    }
}
