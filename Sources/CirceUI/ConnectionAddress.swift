import Darwin
import Foundation

/// Validated user input. No credentials are accepted or retained in launcher addresses.
public struct ConnectionAddress: Equatable {
    public enum ConnectionProtocol: String { case circe, vnc }
    public let host: String
    public let port: UInt16
    public let connectionProtocol: ConnectionProtocol
    public var normalized: String {
        let name = host.contains(":") ? "[\(host)]" : host
        return "\(connectionProtocol.rawValue)://\(name):\(port)"
    }
    public init(_ input: String) throws {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw AddressError.invalidHost }
        var scheme = ConnectionProtocol.circe
        var explicitScheme = false
        if let separator = value.range(of: "://") {
            guard let supplied = ConnectionProtocol(rawValue: String(value[..<separator.lowerBound]).lowercased()) else { throw AddressError.invalidScheme }
            explicitScheme = true
            scheme = supplied
            value = String(value[separator.upperBound...])
            if value.hasSuffix("/") { value.removeLast() }
        }
        guard !value.contains("@"), !value.contains("/"), !value.contains("?"), !value.contains("#") else { throw AddressError.invalidHost }
        let parsedHost: String
        let parsedPort: String?
        if value.hasPrefix("[") {
            guard let end = value.firstIndex(of: "]") else { throw AddressError.invalidHost }
            parsedHost = String(value[value.index(after: value.startIndex)..<end])
            let suffix = value[value.index(after: end)...]
            if suffix.isEmpty { parsedPort = nil }
            else {
                guard suffix.hasPrefix(":"), suffix.count > 1 else { throw AddressError.invalidPort }
                parsedPort = String(suffix.dropFirst())
            }
            guard Self.isIPv6(parsedHost) else { throw AddressError.invalidHost }
        } else if value.filter({ $0 == ":" }).count > 1 {
            guard Self.isIPv6(value) else { throw AddressError.invalidHost }
            parsedHost = value; parsedPort = nil
        } else if let separator = value.lastIndex(of: ":") {
            parsedHost = String(value[..<separator]); parsedPort = String(value[value.index(after: separator)...])
        } else {
            parsedHost = value; parsedPort = nil
        }
        guard !parsedHost.isEmpty, parsedHost.count <= 253 else { throw AddressError.invalidHost }
        if !parsedHost.contains(":") {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
            guard parsedHost.unicodeScalars.allSatisfy({ allowed.contains($0) }),
                  !parsedHost.hasPrefix("."), !parsedHost.contains("..") else { throw AddressError.invalidHost }
        }
        if let supplied = parsedPort {
            guard !supplied.isEmpty, supplied.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = UInt16(supplied), number > 0 else { throw AddressError.invalidPort }
            port = number
        } else { port = scheme == .circe ? 47_800 : 5900 }
        if !explicitScheme && port == 5900 { scheme = .vnc }
        host = parsedHost; connectionProtocol = scheme
    }
    private static func isIPv6(_ input: String) -> Bool {
        let parts = input.split(separator: "%", omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.count == 1 || !parts[1].isEmpty else { return false }
        var address = in6_addr()
        return String(parts[0]).withCString { inet_pton(AF_INET6, $0, &address) } == 1
    }
    public enum AddressError: LocalizedError {
        case invalidHost, invalidPort, invalidScheme
        public var errorDescription: String? {
            switch self {
            case .invalidHost: return "Enter a hostname or IP address, such as studio.local or 192.168.1.20."
            case .invalidPort: return "Use a port between 1 and 65535, such as studio.local:47800."
            case .invalidScheme: return "Use a hostname, IP address, circe:// address, or vnc:// address."
            }
        }
    }
}
