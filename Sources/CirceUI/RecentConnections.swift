import Foundation

/// A stable Bonjour route; Network.framework resolves its current address at connection time.
public struct BonjourServiceAddress: Codable, Equatable {
    public var name: String
    public var type: String
    public var domain: String
    public var displayAddress: String { "\(name).\(type).\(domain)" }
}

public struct RecentConnection: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var address: String
    public var transport: HostTransport
    public var model: String
    public var hostID: String?
    public var service: BonjourServiceAddress?
    public var lastUsed: Date
    public var nearbyHost: NearbyMac? {
        guard let hostID else { return nil }
        return NearbyMac(id: hostID, name: name, model: model, address: address, transport: transport, service: service)
    }
    public var detail: String {
        if service != nil { return transport == .vnc ? "Screen Sharing" : "Circe" }
        return address.replacingOccurrences(of: "circe://", with: "").replacingOccurrences(of: "vnc://", with: "")
    }
}

@MainActor
public final class RecentConnectionsStore {
    public static let limit = 8
    private let defaults: UserDefaults
    private let key = "recentConnections.v1"
    public private(set) var connections: [RecentConnection]
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        connections = (defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([RecentConnection].self, from: $0) } ?? [])
            .filter { connection in
                if let service = connection.service {
                    return !service.name.isEmpty && service.type == (connection.transport == .vnc ? "_rfb._tcp" : "_circe._tcp")
                }
                return (try? ConnectionAddress(connection.address)) != nil
            }.sorted { $0.lastUsed > $1.lastUsed }
        connections = Array(connections.prefix(Self.limit))
    }
    public func record(host: NearbyMac?, address: String, name: String, at date: Date = Date()) {
        let route: String
        let transport: HostTransport
        if let service = host?.service {
            route = service.displayAddress
            transport = host?.transport ?? .circe
        } else {
            guard let parsed = try? ConnectionAddress(address) else { return }
            route = parsed.normalized
            transport = parsed.connectionProtocol == .vnc ? .vnc : .circe
        }
        let id = host.map { "\($0.transport.rawValue):\($0.id)" } ?? "address:\(route.lowercased())"
        let connection = RecentConnection(id: id, name: name, address: route, transport: transport,
                                          model: host?.model ?? "Mac", hostID: host?.id, service: host?.service, lastUsed: date)
        connections.removeAll { $0.id == id || ($0.transport == transport && $0.address.caseInsensitiveCompare(route) == .orderedSame) }
        connections.insert(connection, at: 0)
        connections = Array(connections.prefix(Self.limit))
        persist()
    }
    public func remove(_ id: String) { connections.removeAll { $0.id == id }; persist() }
    public func clear() { connections = []; persist() }
    private func persist() { if let data = try? JSONEncoder().encode(connections) { defaults.set(data, forKey: key) } }
}
