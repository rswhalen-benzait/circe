import Foundation

public enum ComputerConnection: Codable, Equatable {
    case googleCloud(instance: String, zone: String, project: String?, useIAP: Bool)
    case ssh(destination: String, port: Int?)
}

public struct SavedComputer: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var connection: ComputerConnection
    public var display: Int
    public var commandActsAsControl: Bool
    public var audioEnabled: Bool
    public var videoEnabled: Bool
    public var fitsDesktopToWindow: Bool
    public var lastConnected: Date?
    public var vncPort: Int { 5900 + display }
    public var symbol: String { if case .googleCloud = connection { return "cloud" }; return "server.rack" }
    public var detail: String {
        switch connection {
        case let .googleCloud(instance, zone, _, iap): return "\(instance) · \(zone)\(iap ? " · IAP" : " · SSH")"
        case let .ssh(destination, port): return "\(destination)\(port.map { " · port \($0)" } ?? "") · SSH"
        }
    }
    public init(id: UUID = UUID(), name: String, connection: ComputerConnection, display: Int = 1,
                commandActsAsControl: Bool = true, audioEnabled: Bool = true, videoEnabled: Bool = true,
                fitsDesktopToWindow: Bool = true, lastConnected: Date? = nil) {
        self.id = id; self.name = name; self.connection = connection; self.display = display
        self.commandActsAsControl = commandActsAsControl; self.audioEnabled = audioEnabled
        self.videoEnabled = videoEnabled; self.fitsDesktopToWindow = fitsDesktopToWindow; self.lastConnected = lastConnected
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, connection, display, commandActsAsControl, audioEnabled, videoEnabled, fitsDesktopToWindow, lastConnected
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(UUID.self, forKey: .id), name: try values.decode(String.self, forKey: .name),
                  connection: try values.decode(ComputerConnection.self, forKey: .connection), display: try values.decode(Int.self, forKey: .display),
                  commandActsAsControl: try values.decode(Bool.self, forKey: .commandActsAsControl),
                  audioEnabled: try values.decode(Bool.self, forKey: .audioEnabled), videoEnabled: try values.decodeIfPresent(Bool.self, forKey: .videoEnabled) ?? true,
                  fitsDesktopToWindow: try values.decode(Bool.self, forKey: .fitsDesktopToWindow), lastConnected: try values.decodeIfPresent(Date.self, forKey: .lastConnected))
    }
}

public enum ComputerConnectionKind: String, CaseIterable, Identifiable {
    case googleCloud = "Google Cloud", ssh = "SSH"
    public var id: Self { self }
}

public struct ComputerDraft: Equatable {
    public var id = UUID()
    public var kind: ComputerConnectionKind = .googleCloud
    public var name = ""
    public var instance = ""
    public var zone = ""
    public var project = ""
    public var useIAP = true
    public var destination = ""
    public var sshPort = ""
    public var display = "1"
    public var commandActsAsControl = true
    public var audioEnabled = true
    public var videoEnabled = true
    public var fitsDesktopToWindow = true
    private var lastConnected: Date?

    public init(computer: SavedComputer? = nil) {
        guard let computer else { return }
        id = computer.id; name = computer.name; display = String(computer.display)
        commandActsAsControl = computer.commandActsAsControl
        audioEnabled = computer.audioEnabled; videoEnabled = computer.videoEnabled; fitsDesktopToWindow = computer.fitsDesktopToWindow
        lastConnected = computer.lastConnected
        switch computer.connection {
        case let .googleCloud(i, z, p, iap): kind = .googleCloud; instance = i; zone = z; project = p ?? ""; useIAP = iap
        case let .ssh(d, p): kind = .ssh; destination = d; sshPort = p.map(String.init) ?? ""
        }
    }

    public func computer() throws -> SavedComputer {
        func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
        let label = trimmed(name)
        guard label.count <= 100, !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ComputerValidationError("Use a name of 100 characters or fewer, without line breaks.") }
        let displayText = trimmed(display).hasPrefix(":") ? String(trimmed(display).dropFirst()) : trimmed(display)
        guard matches(displayText, "^[0-9]{1,2}$"), let number = Int(displayText), (1...99).contains(number) else { throw ComputerValidationError("Enter a VNC display from 1 to 99. The usual display is 1.") }
        let connection: ComputerConnection
        let defaultName: String
        switch kind {
        case .googleCloud:
            let i = trimmed(instance), z = trimmed(zone), p = trimmed(project)
            guard matches(i, "^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$") else { throw ComputerValidationError("Enter the Google Cloud instance name, such as linux-workstation.") }
            guard matches(z, "^[a-z][a-z0-9]*(-[a-z0-9]+)+$"), z.count <= 80 else { throw ComputerValidationError("Enter the instance’s zone, such as us-central1-a.") }
            guard p.isEmpty || (matches(p, "^[a-zA-Z0-9][a-zA-Z0-9._:-]*$") && p.count <= 128) else { throw ComputerValidationError("Enter a project ID or number, or leave it empty to use your gcloud default.") }
            connection = .googleCloud(instance: i, zone: z, project: p.isEmpty ? nil : p, useIAP: useIAP)
            defaultName = i
        case .ssh:
            let d = trimmed(destination), p = trimmed(sshPort)
            guard !d.isEmpty, d.count <= 255, !d.hasPrefix("-"), !d.contains("://"),
                  d.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
                  matches(d, "^[a-zA-Z0-9_][a-zA-Z0-9_.@%:+\\[\\]-]*$"), d.filter({ $0 == "@" }).count <= 1,
                  !d.hasSuffix("@") else { throw ComputerValidationError("Enter user@host or an SSH-config alias, without spaces or command options.") }
            let port: Int?
            if p.isEmpty { port = nil }
            else {
                guard matches(p, "^[0-9]{1,5}$"), let value = Int(p), (1...65535).contains(value) else { throw ComputerValidationError("SSH port must be between 1 and 65535, or empty for the default.") }
                port = value
            }
            connection = .ssh(destination: d, port: port)
            defaultName = d
        }
        return SavedComputer(id: id, name: label.isEmpty ? defaultName : label, connection: connection, display: number,
                             commandActsAsControl: commandActsAsControl, audioEnabled: audioEnabled,
                             videoEnabled: videoEnabled, fitsDesktopToWindow: fitsDesktopToWindow, lastConnected: lastConnected)
    }
}

public struct ComputerValidationError: LocalizedError {
    public let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@MainActor
final class SavedComputersStore {
    private let defaults: UserDefaults
    private let key = "savedComputers.v1"
    private(set) var computers: [SavedComputer]
    init(defaults: UserDefaults) {
        self.defaults = defaults
        computers = (defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([SavedComputer].self, from: $0) } ?? [])
            .filter { (try? ComputerDraft(computer: $0).computer()) != nil }
    }
    func save(_ computer: SavedComputer) throws {
        let validated = try ComputerDraft(computer: computer).computer()
        if let index = computers.firstIndex(where: { $0.id == computer.id }) { computers[index] = validated }
        else { computers.append(validated) }
        persist()
    }
    func connected(_ id: UUID) { if let index = computers.firstIndex(where: { $0.id == id }) { computers[index].lastConnected = Date(); persist() } }
    func remove(_ id: UUID) { computers.removeAll { $0.id == id }; persist() }
    private func persist() { if let data = try? JSONEncoder().encode(computers) { defaults.set(data, forKey: key) } }
}

public enum ComputerSetupPhase: Equatable { case running, failed(String), complete }
public struct ComputerSetupStatus: Equatable {
    public var phase: ComputerSetupPhase = .running
    public var output = ""
}

public enum LinuxHostSetup {
    public static var scriptURL: URL? {
        if let bundled = Bundle.main.url(forResource: "setup-circe-host", withExtension: "sh", subdirectory: "Linux") { return bundled }
        #if DEBUG
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/linux/setup-circe-host.sh")
        if FileManager.default.fileExists(atPath: development.path) { return development }
        #endif
        return nil
    }
    /// A Terminal fallback, with each argument quoted independently. No shell runs inside Circe.
    public static func command(for computer: SavedComputer, scriptURL: URL) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let remote = "bash -s -- --display \(computer.display)"
        let arguments: [String]
        switch computer.connection {
        case let .ssh(destination, port): arguments = ["ssh", "-T"] + (port.map { ["-p", String($0)] } ?? []) + ["--", destination, remote]
        case let .googleCloud(instance, zone, project, iap):
            arguments = ["gcloud", "compute", "ssh", instance, "--zone", zone] + (project.map { ["--project", $0] } ?? []) + (iap ? ["--tunnel-through-iap"] : []) + ["--command", remote, "--", "-T"]
        }
        return arguments.map(quote).joined(separator: " ") + " < " + quote(scriptURL.path)
    }
}
