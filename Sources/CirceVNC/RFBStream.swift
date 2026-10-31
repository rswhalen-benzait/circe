import Compression
import Foundation
import Network

enum RFBError: Error, CustomStringConvertible {
    case closed
    case protocolError(String)
    case authFailed(String)
    case unsupported(String)

    var description: String {
        switch self {
        case .closed: return "The connection was closed."
        case .protocolError(let s): return "Protocol error: \(s)"
        case .authFailed(let s): return s
        case .unsupported(let s): return s
        }
    }
}

/// Blocking, buffered reads over an NWConnection for a protocol parser running on its own thread.
final class RFBStream: @unchecked Sendable {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "circe.vnc.net", qos: .userInteractive)
    private var buffer = Data()
    private var offset = 0
    private var failed: Error?
    private let writeLock = NSLock()

    init(endpoint: NWEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 8
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .interactiveVideo
        connection = NWConnection(to: endpoint, using: params)
    }

    /// Blocks until connected or failed.
    func open() throws {
        let sem = DispatchSemaphore(value: 0)
        var result: Error?
        var signaled = false
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if !signaled { signaled = true; sem.signal() }
            case .failed(let e), .waiting(let e):
                result = e
                if !signaled { signaled = true; sem.signal() }
            case .cancelled:
                result = result ?? RFBError.closed
                if !signaled { signaled = true; sem.signal() }
            default: break
            }
        }
        connection.start(queue: queue)
        if sem.wait(timeout: .now() + 10) == .timedOut { throw RFBError.protocolError("Timed out connecting") }
        if let result { throw result }
    }

    func close() { connection.cancel() }

    private func fill(_ need: Int) throws {
        while buffer.count - offset < need {
            if let failed { throw failed }
            let sem = DispatchSemaphore(value: 0)
            var chunk: Data?
            var err: Error?
            var done = false
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                chunk = data; err = error; done = complete
                sem.signal()
            }
            sem.wait()
            if offset > 0 && offset == buffer.count { buffer.removeAll(keepingCapacity: true); offset = 0 }
            if let chunk, !chunk.isEmpty { buffer.append(chunk) }
            if let err { failed = err; throw err }
            if done && (chunk?.isEmpty ?? true) { failed = RFBError.closed; throw RFBError.closed }
        }
    }

    func read(_ n: Int) throws -> Data {
        guard n > 0 else { return Data() }
        try fill(n)
        let out = buffer.subdata(in: (buffer.startIndex + offset)..<(buffer.startIndex + offset + n))
        offset += n
        if offset > 4 << 20 { buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + offset)); offset = 0 }
        return out
    }

    func u8() throws -> UInt8 { try read(1).first! }
    func u16() throws -> UInt16 { let d = try read(2); return UInt16(d[d.startIndex]) << 8 | UInt16(d[d.startIndex + 1]) }
    func u32() throws -> UInt32 { try read(4).reduce(0) { $0 << 8 | UInt32($1) } }
    func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    func skip(_ n: Int) throws { _ = try read(n) }

    func write(_ d: Data) {
        writeLock.withLock { connection.send(content: d, completion: .contentProcessed { _ in }) }
    }
}

/// Persistent raw-deflate stream for ZRLE (one zlib stream for the whole connection).
final class ZlibStream {
    private var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
    private var initialized = false
    private var headerSkipped = false

    deinit { if initialized { compression_stream_destroy(&stream) } }

    func inflate(_ input: Data) throws -> Data {
        if !initialized {
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                throw RFBError.protocolError("zlib init")
            }
            initialized = true
        }
        var src = input
        // Compression's ZLIB is raw DEFLATE; drop the 2-byte zlib header that starts the stream.
        if !headerSkipped {
            guard src.count >= 2 else { throw RFBError.protocolError("zlib header") }
            src = src.dropFirst(2)
            headerSkipped = true
        }
        var out = Data()
        let chunk = 1 << 18
        var dst = [UInt8](repeating: 0, count: chunk)
        try src.withUnsafeBytes { (s: UnsafeRawBufferPointer) in
            stream.src_ptr = s.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer<UInt8>(bitPattern: 1)!
            stream.src_size = s.count
            repeat {
                try dst.withUnsafeMutableBufferPointer { d in
                    stream.dst_ptr = d.baseAddress!
                    stream.dst_size = chunk
                    let st = compression_stream_process(&stream, 0)
                    guard st != COMPRESSION_STATUS_ERROR else { throw RFBError.protocolError("zlib data") }
                    out.append(d.baseAddress!, count: chunk - stream.dst_size)
                }
            } while stream.src_size > 0 || stream.dst_size == 0
        }
        return out
    }
}
