import Foundation
import Network

/// Length-prefixed, optionally encrypted message stream over a Network.framework connection.
/// All callbacks are delivered on `queue`; all methods must be called on `queue`.
public final class FramedConnection: @unchecked Sendable {
    public let connection: NWConnection
    public let queue: DispatchQueue
    public var channel: SecureChannel?

    public var onReady: (() -> Void)?
    public var onMessage: ((Message) -> Void)?
    public var onClose: ((Error?) -> Void)?

    /// Bytes handed to the network stack but not yet acknowledged as sent. Used for backpressure.
    public private(set) var pendingSendBytes = 0
    public private(set) var bytesReceived: UInt64 = 0
    public private(set) var bytesSent: UInt64 = 0

    private var closed = false
    private static let maxFrame = 64 * 1024 * 1024

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Connection parameters tuned for interactivity: no Nagle, fast keepalive-based dead peer detection.
    public static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 8
        let p = NWParameters(tls: nil, tcp: tcp)
        p.serviceClass = .interactiveVideo
        p.includePeerToPeer = true
        return p
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.readHeader()
            case .failed(let e):
                self.finish(e)
            case .cancelled:
                self.finish(nil)
            case .waiting(let e):
                // Unreachable right now; treat as failure so the UI can react immediately.
                self.finish(e)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    /// Starts reading on an already-ready connection (e.g. inbound from a listener).
    public func send(_ message: Message, completion: ((Error?) -> Void)? = nil) {
        guard !closed else { completion?(WireError.protocolViolation("closed")); return }
        do {
            var body = try message.encoded()
            if channel != nil { body = try channel!.seal(body) }
            var frame = Data(capacity: body.count + 4)
            withUnsafeBytes(of: UInt32(body.count).bigEndian) { frame.append(contentsOf: $0) }
            frame.append(body)
            let size = frame.count
            pendingSendBytes += size
            bytesSent += UInt64(size)
            connection.send(content: frame, completion: .contentProcessed { [weak self] err in
                guard let self else { return }
                self.pendingSendBytes -= size
                completion?(err)
                if let err { self.finish(err) }
            })
        } catch {
            completion?(error)
            finish(error)
        }
    }

    public func close(goodbye reason: String? = nil) {
        guard !closed else { return }
        if let reason {
            send(.goodbye(Goodbye(reason: reason))) { [weak self] _ in self?.connection.cancel() }
            // Don't let a stuck peer keep us open.
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.connection.cancel() }
        } else {
            connection.cancel()
        }
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        let cb = onClose
        onClose = nil
        onMessage = nil
        cb?(error)
    }

    private func readHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let error { self.finish(error); return }
            guard let data, data.count == 4 else {
                self.finish(isComplete ? nil : WireError.truncated); return
            }
            let len = data.reduce(0) { ($0 << 8) | Int($1) }
            guard len > 0, len <= Self.maxFrame else { self.finish(WireError.malformed("frame length \(len)")); return }
            self.readBody(len)
        }
    }

    private func readBody(_ len: Int) {
        connection.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let error { self.finish(error); return }
            guard let data, data.count == len else {
                self.finish(isComplete ? nil : WireError.truncated); return
            }
            self.bytesReceived += UInt64(len + 4)
            do {
                var body = data
                if self.channel != nil { body = try self.channel!.open(body) }
                let msg = try Message.decode(body)
                self.onMessage?(msg)
            } catch {
                self.finish(error); return
            }
            if !self.closed { self.readHeader() }
        }
    }
}

/// Simple rolling rate meter (e.g. fps or bitrate) over a 1s window.
public struct RateMeter: Sendable {
    private var samples: [(t: UInt64, v: Double)] = []
    public init() {}
    public mutating func add(_ v: Double = 1, at t: UInt64 = Clock.micros()) {
        samples.append((t, v))
        let cutoff = t &- 1_000_000
        if let i = samples.firstIndex(where: { $0.t >= cutoff }), i > 0 { samples.removeFirst(i) }
    }
    public func rate(at t: UInt64 = Clock.micros()) -> Double {
        let cutoff = t &- 1_000_000
        return samples.filter { $0.t >= cutoff }.reduce(0) { $0 + $1.v }
    }
}

/// Reads this Mac's marketing-friendly name and model identifier.
public enum MachineInfo {
    public static var computerName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
    public static var modelIdentifier: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
