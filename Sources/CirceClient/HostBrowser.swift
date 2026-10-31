import CirceCore
import Combine
import Foundation
import Network

/// A Circe host found on the local network via Bonjour.
public struct DiscoveredHost: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let modelIdentifier: String
    public let endpoint: NWEndpoint

    public init(id: String, name: String, modelIdentifier: String, endpoint: NWEndpoint) {
        self.id = id; self.name = name; self.modelIdentifier = modelIdentifier; self.endpoint = endpoint
    }
}

/// Live list of Circe hosts on the network. Starts browsing on `start()`.
@MainActor
public final class HostBrowser: ObservableObject {
    @Published public private(set) var hosts: [DiscoveredHost] = []
    @Published public private(set) var error: String?

    private var browser: NWBrowser?
    private let excludeDeviceID: String?

    /// - Parameter excludeDeviceID: hide this device (normally our own host identity).
    public init(excludeDeviceID: String? = nil) {
        self.excludeDeviceID = excludeDeviceID
    }

    public func start() {
        guard browser == nil else { return }
        error = nil
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: circeBonjourType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = results.compactMap { r -> DiscoveredHost? in
                guard case let .service(name, _, _, _) = r.endpoint else { return nil }
                var id = name, model = "Mac"
                if case let .bonjour(txt) = r.metadata {
                    id = txt["id"] ?? name
                    model = txt["model"] ?? model
                }
                return DiscoveredHost(id: id, name: name, modelIdentifier: model, endpoint: r.endpoint)
            }
            Task { @MainActor in
                guard let self else { return }
                self.hosts = hosts.filter { $0.id != self.excludeDeviceID }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        }
        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .failed(let e):
                    self?.error = "Can't look for Macs: \(e.localizedDescription)"
                    self?.restart()
                case .waiting(let e):
                    self?.error = "Local network unavailable: \(e.localizedDescription)"
                case .ready:
                    self?.error = nil
                default: break
                }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    public func restart() {
        stop()
        start()
    }
}

/// Parses user-typed addresses: "studio.local", "10.0.0.5:47800", "[fe80::1]:47800", "circe://host".
public func parseEndpoint(_ text: String) -> NWEndpoint? {
    var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in ["circe://", "vnc://"] where s.lowercased().hasPrefix(prefix) { s.removeFirst(prefix.count) }
    while s.hasSuffix("/") { s.removeLast() }
    guard !s.isEmpty else { return nil }
    var host = s
    var port = circeDefaultPort
    if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
        host = String(s[s.index(after: s.startIndex)..<close])
        let rest = s[s.index(after: close)...]
        if rest.hasPrefix(":"), let p = UInt16(rest.dropFirst()) { port = p }
    } else if s.filter({ $0 == ":" }).count == 1, let colon = s.lastIndex(of: ":") {
        host = String(s[..<colon])
        guard let p = UInt16(s[s.index(after: colon)...]) else { return nil }
        port = p
    }
    guard !host.isEmpty, let p = NWEndpoint.Port(rawValue: port) else { return nil }
    return .hostPort(host: NWEndpoint.Host(host), port: p)
}
