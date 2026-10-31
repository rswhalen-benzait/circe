import Foundation

/// Big-endian binary writer used by the wire protocol.
public struct ByteWriter {
    public private(set) var data = Data()

    public init(capacity: Int = 64) { data.reserveCapacity(capacity) }

    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func bool(_ v: Bool) { data.append(v ? 1 : 0) }
    public mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    public mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    public mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    public mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    public mutating func f32(_ v: Float) { u32(v.bitPattern) }
    public mutating func f64(_ v: Double) { u64(v.bitPattern) }
    public mutating func bytes(_ d: Data) { data.append(d) }
    /// Length-prefixed (u32) blob.
    public mutating func blob(_ d: Data) { u32(UInt32(d.count)); data.append(d) }
    public mutating func string(_ s: String) { blob(Data(s.utf8)) }
}

public enum WireError: Error, CustomStringConvertible {
    case truncated
    case malformed(String)
    case unknownMessage(UInt8)
    case decryptFailed
    case protocolViolation(String)

    public var description: String {
        switch self {
        case .truncated: return "truncated message"
        case .malformed(let s): return "malformed message: \(s)"
        case .unknownMessage(let t): return "unknown message type \(t)"
        case .decryptFailed: return "decryption failed"
        case .protocolViolation(let s): return "protocol violation: \(s)"
        }
    }
}

/// Big-endian binary reader used by the wire protocol.
public struct ByteReader {
    private let data: Data
    private var offset: Int

    public init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    public var remaining: Int { data.endIndex - offset }

    private mutating func take(_ n: Int) throws -> Data {
        guard n >= 0, remaining >= n else { throw WireError.truncated }
        let slice = data[offset..<(offset + n)]
        offset += n
        return slice
    }

    private mutating func integer<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let slice = try take(MemoryLayout<T>.size)
        var v: T = 0
        for b in slice { v = (v << 8) | T(b) }
        return v
    }

    public mutating func u8() throws -> UInt8 { try integer(UInt8.self) }
    public mutating func bool() throws -> Bool { try u8() != 0 }
    public mutating func u16() throws -> UInt16 { try integer(UInt16.self) }
    public mutating func u32() throws -> UInt32 { try integer(UInt32.self) }
    public mutating func u64() throws -> UInt64 { try integer(UInt64.self) }
    public mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    public mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    public mutating func f64() throws -> Double { Double(bitPattern: try u64()) }
    public mutating func bytes(_ n: Int) throws -> Data { Data(try take(n)) }
    public mutating func blob() throws -> Data { try bytes(Int(try u32())) }
    public mutating func string() throws -> String {
        guard let s = String(data: try blob(), encoding: .utf8) else { throw WireError.malformed("utf8") }
        return s
    }
    public mutating func rest() -> Data { (try? bytes(remaining)) ?? Data() }
}
