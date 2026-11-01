import Foundation

public enum ComputerConnection: Codable, Equatable {
    /// `account` pins the gcloud sign-in for this computer; `user` is its Linux login. Both optional
    /// (nil = gcloud's active account / gcloud's default user), and absent from older saved profiles.
    /// `hostKeyAlias` is set once Circe has verified the Linux sign-in (Google Cloud setup): connections then
    /// use ssh over an account-pinned IAP tunnel with that pinned host key, instead of `gcloud compute ssh`.
    /// `keyFile` is the private key for the Linux user when it isn't gcloud's own key.
    case googleCloud(instance: String, zone: String, project: String?, useIAP: Bool, account: String? = nil, user: String? = nil, hostKeyAlias: String? = nil, keyFile: String? = nil)
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
    /// Start (or resume) a stopped Google Cloud computer without asking when connecting. Off by default:
    /// starting costs money, so the user opts in per computer.
    public var startsWhenConnecting: Bool
    /// Set up without lingering: the desktop stops when the last connection ends, so Circe starts it on connect.
    public var startsDesktopOnConnect: Bool = false
    /// Send this Mac's microphone to the remote desktop, only after an explicit per-computer choice.
    public var microphoneEnabled: Bool = false
    // Older builds defaulted this on, so an old saved `true` is not evidence of consent.
    private var microphoneConsentVersion = 1
    public var vncPort: Int { 5900 + display }
    public var isVerifiedGoogleCloud: Bool {
        if case let .googleCloud(_, _, project, _, account, user, alias, _) = connection { return project != nil && account != nil && user != nil && alias != nil }
        return false
    }
    public var symbol: String { if case .googleCloud = connection { return "cloud" }; return "server.rack" }
    public var detail: String {
        switch connection {
        case let .googleCloud(instance, zone, _, iap, account, user, _, _):
            return "\(user.map { "\($0)@" } ?? "")\(instance) · \(zone)\(iap ? " · IAP" : " · SSH")\(account.map { " · \($0)" } ?? "")"
        case let .ssh(destination, port): return "\(destination)\(port.map { " · port \($0)" } ?? "") · SSH"
        }
    }
    public init(id: UUID = UUID(), name: String, connection: ComputerConnection, display: Int = 1,
                commandActsAsControl: Bool = true, audioEnabled: Bool = true, videoEnabled: Bool = true,
                fitsDesktopToWindow: Bool = true, lastConnected: Date? = nil, startsWhenConnecting: Bool = false) {
        self.id = id; self.name = name; self.connection = connection; self.display = display
        self.commandActsAsControl = commandActsAsControl; self.audioEnabled = audioEnabled
        self.videoEnabled = videoEnabled; self.fitsDesktopToWindow = fitsDesktopToWindow; self.lastConnected = lastConnected
        self.startsWhenConnecting = startsWhenConnecting
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, connection, display, commandActsAsControl, audioEnabled, videoEnabled, fitsDesktopToWindow, lastConnected, startsWhenConnecting, startsDesktopOnConnect, microphoneEnabled, microphoneConsentVersion
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(UUID.self, forKey: .id), name: try values.decode(String.self, forKey: .name),
                  connection: try values.decode(ComputerConnection.self, forKey: .connection), display: try values.decode(Int.self, forKey: .display),
                  commandActsAsControl: try values.decode(Bool.self, forKey: .commandActsAsControl),
                  audioEnabled: try values.decode(Bool.self, forKey: .audioEnabled), videoEnabled: try values.decodeIfPresent(Bool.self, forKey: .videoEnabled) ?? true,
                  fitsDesktopToWindow: try values.decode(Bool.self, forKey: .fitsDesktopToWindow), lastConnected: try values.decodeIfPresent(Date.self, forKey: .lastConnected),
                  startsWhenConnecting: try values.decodeIfPresent(Bool.self, forKey: .startsWhenConnecting) ?? false)
        startsDesktopOnConnect = try values.decodeIfPresent(Bool.self, forKey: .startsDesktopOnConnect) ?? false
        let hasMicrophoneConsent = try values.decodeIfPresent(Int.self, forKey: .microphoneConsentVersion) == 1
        if hasMicrophoneConsent { microphoneEnabled = try values.decodeIfPresent(Bool.self, forKey: .microphoneEnabled) ?? false }
        else { microphoneEnabled = false }
    }
}

public enum ComputerConnectionKind: String, CaseIterable, Identifiable {
    case googleCloud = "Google Cloud", ssh = "SSH"
    public var id: Self { self }
}

public struct ComputerDraft: Equatable {
    public static func == (a: ComputerDraft, b: ComputerDraft) -> Bool {
        a.id == b.id && a.kind == b.kind && a.name == b.name && a.instance == b.instance && a.zone == b.zone && a.project == b.project
            && a.useIAP == b.useIAP && a.account == b.account && a.linuxUser == b.linuxUser && a.startsWhenConnecting == b.startsWhenConnecting
            && a.destination == b.destination && a.sshPort == b.sshPort && a.display == b.display && a.commandActsAsControl == b.commandActsAsControl
            && a.audioEnabled == b.audioEnabled && a.videoEnabled == b.videoEnabled && a.fitsDesktopToWindow == b.fitsDesktopToWindow
            && a.lastConnected == b.lastConnected && a.hostKeyAlias == b.hostKeyAlias && a.microphoneEnabled == b.microphoneEnabled
    }
    public var id = UUID()
    public var kind: ComputerConnectionKind = .googleCloud
    public var name = ""
    public var instance = ""
    public var zone = ""
    public var project = ""
    public var useIAP = true
    public var account = ""
    public var linuxUser = ""
    public var startsWhenConnecting = false
    public var microphoneEnabled = false
    private var startsDesktopOnConnect = false
    /// Carried through edits, but dropped when anything it vouches for changes.
    private var hostKeyAlias: String?
    private var keyFile: String?
    private var originalStartsWhenConnecting = false
    private var originalMachine: (instance: String, zone: String, project: String)?
    private var originalUser = ""
    private var originalDestination: (host: String, port: Int)?
    private var verified: (instance: String, zone: String, project: String, account: String, user: String)?
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
        lastConnected = computer.lastConnected; startsWhenConnecting = computer.startsWhenConnecting
        originalStartsWhenConnecting = computer.startsWhenConnecting
        startsDesktopOnConnect = computer.startsDesktopOnConnect
        microphoneEnabled = computer.microphoneEnabled
        switch computer.connection {
        case let .googleCloud(i, z, p, iap, a, u, alias, key):
            keyFile = key
            kind = .googleCloud; instance = i; zone = z; project = p ?? ""; useIAP = iap; account = a ?? ""; linuxUser = u ?? ""
            hostKeyAlias = alias
            originalMachine = (i, z, p ?? ""); originalUser = u ?? ""
            if let p, let a, let u { verified = (i, z, p, a, u) }
        case let .ssh(d, p): kind = .ssh; destination = d; sshPort = p.map(String.init) ?? ""; originalDestination = (d, p ?? 22)
        }
    }

    public func computer() throws -> SavedComputer {
        func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
        let label = trimmed(name)
        guard label.count <= 100, !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ComputerValidationError("Use a name of 100 characters or fewer, without line breaks.") }
        let displayText = trimmed(display).hasPrefix(":") ? String(trimmed(display).dropFirst()) : trimmed(display)
        // Display 0 (port 5900) is how existing desktops such as wayvnc are usually served.
        guard matches(displayText, "^[0-9]{1,2}$"), let number = Int(displayText), (0...99).contains(number) else { throw ComputerValidationError("Enter a VNC display from 0 to 99. The usual display is 1.") }
        let connection: ComputerConnection
        let defaultName: String
        var autoStart = startsWhenConnecting
        // Settings that describe one machine (whether its desktop must be started, consent to send it the
        // microphone) don't follow an edit to a different machine.
        var otherMachine = false
        switch kind {
        case .googleCloud:
            let i = trimmed(instance), z = trimmed(zone), p = trimmed(project)
            guard matches(i, "^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$") else { throw ComputerValidationError("Enter the Google Cloud instance name, such as linux-workstation.") }
            guard matches(z, "^[a-z][a-z0-9]*(-[a-z0-9]+)+$"), z.count <= 80 else { throw ComputerValidationError("Enter the instance’s zone, such as us-central1-a.") }
            guard p.isEmpty || (matches(p, "^[a-zA-Z0-9][a-zA-Z0-9._:-]*$") && p.count <= 128) else { throw ComputerValidationError("Enter a project ID or number, or leave it empty to use your gcloud default.") }
            let a = trimmed(account), u = trimmed(linuxUser)
            guard a.isEmpty || (matches(a, "^[A-Za-z0-9][A-Za-z0-9._%+-]*@[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$") && a.count <= 254) else { throw ComputerValidationError("Enter a Google account such as you@example.com, or leave it empty to use gcloud’s active account.") }
            guard u.isEmpty || matches(u, "^[A-Za-z_][A-Za-z0-9_.-]{0,31}$") else { throw ComputerValidationError("Enter a Linux user name such as developer, or leave it empty to use gcloud’s default.") }
            let stillVerified = verified.map { $0 == (i, z, p, a, u) } ?? false
            let sameMachine = originalMachine.map { $0 == (i, z, p) } ?? false
            // A computer set up by Circe stays on the verified route: no silent fallback to `gcloud compute ssh`.
            if hostKeyAlias != nil && useIAP && (a.isEmpty || u.isEmpty || p.isEmpty) {
                throw ComputerValidationError("This computer was set up with Google Cloud setup. Keep its Google account, project and Linux user, or set it up again with Add a computer → Google Cloud computer.")
            }
            // With an account, project and Linux user, connections use ssh over the account-pinned IAP tunnel. An
            // edit that changes what was verified starts a fresh host-key pin; it never falls back to
            // `gcloud compute ssh`, which can publish keys.
            // The machine's host-key trust is kept across login edits; a different machine starts a fresh pin.
            let alias: String? = !useIAP ? nil : (sameMachine && hostKeyAlias != nil) ? hostKeyAlias
                : (!a.isEmpty && !u.isEmpty && !p.isEmpty ? "circe-gce-\(p)-\(z)-\(i)" : nil)
            connection = .googleCloud(instance: i, zone: z, project: p.isEmpty ? nil : p, useIAP: useIAP,
                                      account: a.isEmpty ? nil : a, user: u.isEmpty ? nil : u,
                                      hostKeyAlias: alias, keyFile: (stillVerified || (sameMachine && u == originalUser)) ? keyFile : nil)
            _ = stillVerified
            // Permission to start a VM automatically belongs to that VM.
            if originalMachine != nil, !sameMachine, startsWhenConnecting == originalStartsWhenConnecting { autoStart = false }
            otherMachine = originalDestination != nil || (originalMachine != nil && !sameMachine)
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
            // Same host on another port can be another machine (port forwards, jump hosts).
            otherMachine = originalMachine != nil || (originalDestination.map { $0.host != d || $0.port != (port ?? 22) } ?? false)
            defaultName = d
        }
        var result = SavedComputer(id: id, name: label.isEmpty ? defaultName : label, connection: connection, display: number,
                             commandActsAsControl: commandActsAsControl, audioEnabled: audioEnabled,
                             videoEnabled: videoEnabled, fitsDesktopToWindow: fitsDesktopToWindow, lastConnected: lastConnected,
                             startsWhenConnecting: kind == .googleCloud && autoStart)
        result.startsDesktopOnConnect = otherMachine ? false : startsDesktopOnConnect
        result.microphoneEnabled = otherMachine ? false : microphoneEnabled
        return result
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
        case let .googleCloud(instance, zone, project, iap, account, user, _, _):
            arguments = ["gcloud", "compute", "ssh", user.map { "\($0)@\(instance)" } ?? instance, "--zone", zone] + (project.map { ["--project", $0] } ?? [])
                + (account.map { ["--account=\($0)"] } ?? []) + (iap ? ["--tunnel-through-iap"] : []) + ["--command", remote, "--", "-T"]
        }
        return arguments.map(quote).joined(separator: " ") + " < " + quote(scriptURL.path)
    }
}
