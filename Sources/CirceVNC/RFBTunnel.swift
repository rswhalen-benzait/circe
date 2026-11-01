import Foundation
import Network

/// How Circe reaches a VNC server.
///
/// For machines that aren't on the local network (e.g. a Linux VM in Google Cloud) Circe never
/// exposes VNC to the internet: it runs over an SSH channel (`ssh -W`) — optionally through Google's
/// Identity-Aware Proxy, so the VM needs neither a public IP nor a firewall hole for VNC.
public enum RFBTunnel: Hashable, Sendable, Codable {
    /// Plain TCP (LAN, Apple Screen Sharing, or a VPN such as Tailscale).
    case direct(host: String, port: Int)
    /// `ssh -W localhost:<vncPort> <destination>` — destination is `user@host` or an ~/.ssh/config alias.
    case ssh(destination: String, port: Int?, vncPort: Int)
    /// `gcloud compute ssh [user@]<instance> --zone … [--account …] [--tunnel-through-iap] -- -W localhost:<vncPort>`.
    /// `account` pins the gcloud sign-in, so switching gcloud's active account elsewhere can't break this
    /// computer; `user` is the Linux login when it differs from the Mac's (gcloud's default).
    case gcloud(instance: String, zone: String, project: String?, useIAP: Bool, vncPort: Int, account: String? = nil, user: String? = nil)
    /// System ssh through an account-pinned `gcloud compute start-iap-tunnel` ProxyCommand. Unlike `gcloud compute
    /// ssh`, it never looks the instance up or publishes keys, ignores ~/.ssh/config, and pins the host key under
    /// `hostKeyAlias` in Circe's own known_hosts. Used once Circe has verified the Linux user.
    /// `identity` is a private key file to use instead of gcloud's ~/.ssh/google_compute_engine.
    case iap(instance: String, zone: String, project: String, account: String, user: String, hostKeyAlias: String, vncPort: Int, identity: String? = nil)

    /// VNC display number → TCP port (":1" → 5901).
    public static func vncPort(display: Int) -> Int { 5900 + display }

    var isGCloud: Bool {
        switch self { case .gcloud, .iap: return true; default: return false }
    }

    public var isTunneled: Bool {
        if case .direct = self { return false }
        return true
    }

    /// Human-readable name for the UI and Keychain.
    public var displayName: String {
        switch self {
        case let .direct(host, port): return port == 5900 ? host : "\(host):\(port)"
        case let .ssh(dest, _, _): return dest
        case let .gcloud(instance, _, _, _, _, _, _), let .iap(instance, _, _, _, _, _, _, _): return instance
        }
    }

    var keychainAccount: String {
        switch self {
        case let .direct(host, port): return "vnc:\(host):\(port)"
        case let .ssh(dest, port, vnc): return "ssh:\(dest):\(port ?? 22):\(vnc)"
        // Account and user are left out so passwords saved before they existed are still found.
        case let .gcloud(i, z, p, _, vnc, _, _): return "gcloud:\(p ?? "-"):\(z):\(i):\(vnc)"
        case let .iap(i, z, p, _, _, _, vnc, _): return "gcloud:\(p):\(z):\(i):\(vnc)"
        }
    }

    /// The VNC port on the remote machine (nil for `.direct`).
    var remoteVNCPort: Int? {
        switch self {
        case .direct: return nil
        case let .ssh(_, _, vnc), let .gcloud(_, _, _, _, vnc, _, _), let .iap(_, _, _, _, _, _, vnc, _): return vnc
        }
    }

    /// Child process that carries the VNC byte stream on stdin/stdout (nil for `.direct`).
    func streamCommand() throws -> (URL, [String]) {
        switch self {
        case .direct:
            throw RFBError.unsupported("direct connections don't use a tunnel process")
        case let .ssh(dest, port, vnc):
            return (SSHCommand.executable, SSHCommand.base(port: port) + ["-W", "localhost:\(vnc)", dest])
        case let .gcloud(instance, zone, project, iap, vnc, account, user):
            return (try GCloud.executable(), GCloud.sshArgs(instance: instance, zone: zone, project: project, iap: iap, account: account, user: user)
                    + ["--"] + SSHCommand.base(port: nil) + ["-W", "localhost:\(vnc)"])
        case let .iap(instance, zone, project, account, user, alias, vnc, identity):
            return (SSHCommand.executable, try IAPSSH.arguments(instance: instance, zone: zone, project: project, account: account, user: user, alias: alias, identity: identity)
                    + ["-W", "localhost:\(vnc)", alias])
        }
    }

    /// `command` for /bin/sh whatever the account's login shell is (fish, say, can't run POSIX syntax).
    public static func posix(_ command: String) -> String {
        "exec /bin/sh -c '" + command.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Child process that runs `remoteCommand` (POSIX sh) on the machine, e.g. for audio. nil for `.direct`.
    func remoteCommand(_ command: String) throws -> (URL, [String])? {
        let remoteCommand = Self.posix(command)
        switch self {
        case .direct:
            return nil
        case let .ssh(dest, port, _):
            return (SSHCommand.executable, SSHCommand.base(port: port) + ["-T", dest, remoteCommand])
        case let .gcloud(instance, zone, project, iap, _, account, user):
            return (try GCloud.executable(), GCloud.sshArgs(instance: instance, zone: zone, project: project, iap: iap, account: account, user: user)
                    + ["--command", remoteCommand, "--"] + SSHCommand.base(port: nil) + ["-T"])
        case let .iap(instance, zone, project, account, user, alias, _, identity):
            return (SSHCommand.executable, try IAPSSH.arguments(instance: instance, zone: zone, project: project, account: account, user: user, alias: alias, identity: identity)
                    + ["-T", alias, remoteCommand])
        }
    }
}

/// ssh options for `.iap`: an account-pinned IAP ProxyCommand, gcloud's key, and Circe's own host keys.
enum IAPSSH {
    /// Test hook: CIRCE_IAP_PROXY replaces the ProxyCommand (e.g. `nc localhost 22`).
    static func proxyCommand(instance: String, zone: String, project: String, account: String) throws -> String {
        if let fake = ProcessInfo.processInfo.environment["CIRCE_IAP_PROXY"] { return fake }
        // ssh runs ProxyCommand through /bin/sh and expands %-tokens, so quote each word and escape %.
        func word(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''").replacingOccurrences(of: "%", with: "%%") + "'" }
        let gcloud = try GoogleCloud.executableURL().path
        try GoogleCloud.prepareConfiguration()
        // ssh runs this as `exec <command>` in the login shell, so variables go through /usr/bin/env.
        return "/usr/bin/env CLOUDSDK_ACTIVE_CONFIG_NAME=\(GoogleCloud.configurationName) CLOUDSDK_CORE_DISABLE_PROMPTS=1 " + ([gcloud, "compute", "start-iap-tunnel", instance, "22", "--listen-on-stdin", "--zone=\(zone)", "--project=\(project)",
                 "--account=\(account)", "--verbosity=error", "--quiet"]).map(word).joined(separator: " ")
    }

    static var knownHosts: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Circe", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent("known_hosts")
    }

    static var identity: URL {
        if let path = ProcessInfo.processInfo.environment["CIRCE_IAP_IDENTITY"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/google_compute_engine")
    }

    static func arguments(instance: String, zone: String, project: String, account: String, user: String, alias: String, identity: String? = nil) throws -> [String] {
        let key = identity.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? Self.identity
        // -F /dev/null: the user's ssh config (ControlMaster, other ProxyCommands, identities) must not apply.
        return ["-F", "/dev/null"] + SSHCommand.base(port: nil) + [
            "-o", "ProxyCommand=\(try proxyCommand(instance: instance, zone: zone, project: project, account: account))",
            "-o", "ProxyUseFdpass=no", "-o", "CheckHostIP=no",
            // ssh splits UserKnownHostsFile on whitespace ("Application Support"); a quoted value is one path.
            "-o", "HostKeyAlias=\(alias)", "-o", "UserKnownHostsFile=\"\(knownHosts.path)\"", "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "IdentitiesOnly=yes", "-i", key.path, "-l", user]
    }

    /// Copies the host key Circe pinned under `alias` into gcloud's known_hosts as `gcloudAlias` (unless gcloud
    /// already has one), so `gcloud compute ssh --strict-host-key-checking=yes` verifies the same machine.
    enum Seed { case ready, noPin, mismatch }
    static func seedGCloudKnownHosts(from alias: String, as gcloudAlias: String) -> Seed {
        let ours = pinnedKeys(alias: alias, in: (try? String(contentsOf: knownHosts, encoding: .utf8)) ?? "")
        guard !ours.isEmpty else { return .noPin }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/google_compute_known_hosts")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        // One trust decision: gcloud's existing entry must agree with Circe's pin, or nothing proceeds.
        let theirs = pinnedKeys(alias: gcloudAlias, in: existing)
        if !theirs.isEmpty { return agree(theirs, ours) ? .ready : .mismatch }
        let added = ours.sorted().map { "\(gcloudAlias) \($0)\n" }.joined()
        let text = existing + (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n") + added
        do { try Data(text.utf8).write(to: url, options: .atomic) } catch { return .noPin }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return .ready
    }

    /// Records host keys Google published for the VM (guest attributes), so first contact is verified
    /// rather than trusted on first use. Keeps every other line; replaces nothing already pinned.
    /// Returns false when Circe already pinned different keys for `alias` than the VM now publishes — a
    /// changed or replaced machine, which the user must review. Never overwrites an existing pin.
    @discardableResult
    static func pin(hostKeys: [String], alias: String) -> Bool {
        let url = knownHosts
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = hostKeys.filter { $0.range(of: "^(ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|ssh-rsa) [A-Za-z0-9+/=]+$", options: .regularExpression) != nil }
        let pinned = pinnedKeys(alias: alias, in: existing)
        if !pinned.isEmpty { return lines.isEmpty || agree(Set(lines), pinned) }
        guard !lines.isEmpty else { return true }
        let text = existing + (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n") + lines.map { "\(alias) \($0)\n" }.joined()
        try? Data(text.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }

    /// Two key sets agree when every key type both contain has the same key (a disjoint overlap isn't enough).
    static func agree(_ a: Set<String>, _ b: Set<String>) -> Bool {
        func byType(_ set: Set<String>) -> [String: Set<String>] { Dictionary(grouping: set, by: { String($0.split(separator: " ").first ?? "") }).mapValues(Set.init) }
        let x = byType(a), y = byType(b)
        let shared = Set(x.keys).intersection(y.keys)
        return !shared.isEmpty && shared.allSatisfy { x[$0] == y[$0] }
    }

    /// "type base64" for each line pinned under `alias`.
    static func pinnedKeys(alias: String, in text: String) -> Set<String> {
        Set(text.split(separator: "\n").filter { $0.hasPrefix("\(alias) ") }.map { String($0.dropFirst(alias.count + 1)) })
    }
}

enum SSHCommand {
    /// Test hook: substitute ssh (e.g. a script that maps `-W host:port` onto `nc`).
    static var executable: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["CIRCE_SSH_PATH"] ?? "/usr/bin/ssh")
    }

    /// Non-interactive (keys / ssh-agent only — a GUI app can't answer a tty prompt), fast dead-peer
    /// detection, first-contact host keys accepted then pinned in known_hosts, and no connection sharing.
    static func base(port: Int?) -> [String] {
        var a = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=5",
                 "-o", "ServerAliveCountMax=3", "-o", "StrictHostKeyChecking=accept-new",
                 "-o", "ExitOnForwardFailure=yes", "-o", "LogLevel=ERROR",
                 // Own TCP connection per channel: a user's ControlMaster would otherwise put video,
                 // audio and input back into one stream, each waiting behind the others.
                 "-o", "ControlMaster=no", "-o", "ControlPath=none"]
        if let port { a += ["-p", "\(port)"] }
        return a
    }
}

public enum GCloud {
    /// GUI apps get a minimal PATH, so look where the Cloud SDK is normally installed.
    static func executable() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Circe's own copy first: it exists only because the Mac had no working gcloud.
        if let managed = GoogleCloudInstaller.managedGCloud { return managed }
        let candidates = ["/opt/homebrew/bin/gcloud", "/usr/local/bin/gcloud",
                          "\(home)/google-cloud-sdk/bin/gcloud",
                          "/opt/homebrew/share/google-cloud-sdk/bin/gcloud",
                          "/usr/local/share/google-cloud-sdk/bin/gcloud",
                          "/opt/homebrew/Caskroom/google-cloud-sdk/latest/google-cloud-sdk/bin/gcloud"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: found)
        }
        throw RFBError.unsupported("Circe couldn't find the Google Cloud CLI (gcloud). Install it, run “gcloud auth login”, then try again.")
    }

    static func sshArgs(instance: String, zone: String, project: String?, iap: Bool,
                        account: String? = nil, user: String? = nil) -> [String] {
        let target = user.flatMap { $0.isEmpty ? nil : "\($0)@\(instance)" } ?? instance
        var a = ["compute", "ssh", target, "--zone", zone, "--quiet"]
        if let project, !project.isEmpty { a += ["--project", project] }
        // gcloud passes --account on to the IAP proxy it starts for ssh, so one flag covers both.
        if let account, !account.isEmpty { a.append("--account=\(account)") }
        if iap { a.append("--tunnel-through-iap") }
        return a
    }

    /// The account gcloud uses when none is pinned: CLOUDSDK_CORE_ACCOUNT, else the active
    /// configuration's `[core] account`. Read from gcloud's files, so it costs no subprocess.
    public static func activeAccount(environment: [String: String] = ProcessInfo.processInfo.environment,
                                     home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String? {
        func clean(_ value: String?) -> String? {
            guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return v
        }
        if let pinned = clean(environment["CLOUDSDK_CORE_ACCOUNT"]) { return pinned }
        let directory = URL(fileURLWithPath: clean(environment["CLOUDSDK_CONFIG"]) ?? "\(home)/.config/gcloud")
        let name = clean(environment["CLOUDSDK_ACTIVE_CONFIG_NAME"])
            ?? clean(try? String(contentsOf: directory.appendingPathComponent("active_config"), encoding: .utf8)) ?? "default"
        guard !name.contains("/"),
              let text = try? String(contentsOf: directory.appendingPathComponent("configurations/config_\(name)"), encoding: .utf8)
        else { return nil }
        var inCore = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inCore = line == "[core]"; continue }
            guard inCore, let eq = line.firstIndex(of: "="),
                  line[..<eq].trimmingCharacters(in: .whitespaces) == "account" else { continue }
            return clean(String(line[line.index(after: eq)...]))
        }
        return nil
    }

    /// PATH for child processes: gcloud needs python and friends.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (env["PATH"].map { "\($0):" } ?? "") + extra
        env["CLOUDSDK_CORE_DISABLE_PROMPTS"] = "1"
        return env
    }
}

/// A child process whose stdout/stdin are a byte stream; stderr is kept for error messages.
final class ProcessPipe: @unchecked Sendable {
    let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let errLock = NSLock()
    private var stderrText = ""
    private let writeQueue = DispatchQueue(label: "circe.vnc.tunnel.write")

    /// Writing to a tunnel whose ssh/gcloud already exited must fail with EPIPE, not kill the app.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    init(executable: URL, arguments: [String]) {
        _ = Self.ignoreSIGPIPE
        process.executableURL = executable
        process.arguments = arguments
        // ssh forwards LC_* to the server, so leave the locale alone here; only gcloud's own runs use C.
        // Older saved computers may rely on gcloud's active account/project, so tunnels keep the user's configuration;
        // `.iap` names Circe's configuration inside its ProxyCommand, and GoogleCloud.run always uses it.
        process.environment = GoogleCloud.environment(cLocale: false, circeConfiguration: false)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { return }
            self.errLock.withLock { self.stderrText += String(decoding: d, as: UTF8.self) }
        }
    }

    func start() throws { try process.run() }
    func stdinClose() throws { try stdinPipe.fileHandleForWriting.close() }

    /// Blocks until data arrives; empty Data = end of stream.
    func read() -> Data { stdoutPipe.fileHandleForReading.availableData }

    func write(_ d: Data) {
        writeQueue.async { [weak self] in try? self?.stdinPipe.fileHandleForWriting.write(contentsOf: d) }
    }

    /// Writes `d` and then closes stdin (e.g. a script piped into `bash -s`).
    func writeAndClose(_ d: Data) {
        writeQueue.async { [weak self] in
            try? self?.stdinPipe.fileHandleForWriting.write(contentsOf: d)
            try? self?.stdinPipe.fileHandleForWriting.close()
        }
    }

    var errorOutput: String { errLock.withLock { stderrText.trimmingCharacters(in: .whitespacesAndNewlines) } }

    /// stderr once the process has exited. stdout can reach EOF a moment before ssh's last stderr line is
    /// delivered (`stdio forwarding failed` arrives with the close), so wait briefly for exit and for the
    /// reader to catch up. Never blocks on EOF: a ProxyCommand grandchild may still hold stderr open.
    func settledErrorOutput(timeout: TimeInterval = 1.5) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        let settle = Date().addingTimeInterval(0.3)
        var last = errorOutput
        while Date() < settle {
            usleep(30_000)
            let now = errorOutput
            if !now.isEmpty && now == last { break }
            last = now
        }
        return errorOutput
    }

    func terminate() {
        if process.isRunning { process.terminate() }
        try? stdinPipe.fileHandleForWriting.close()
    }

    /// Turns ssh/gcloud stderr into something a person can act on.
    static func explain(_ stderr: String, tunnel: RFBTunnel, activeAccount: () -> String? = { GCloud.activeAccount() }) -> String {
        let s = stderr.lowercased()
        if s.contains("reauthentication") || s.contains("gcloud auth login") || s.contains("refresh") && s.contains("token") {
            return "Google Cloud sign-in has expired. Run “gcloud auth login” in Terminal, then reconnect."
        }
        let cloud: (project: String?, account: String?, user: String?)? = {
            switch tunnel {
            case let .gcloud(_, _, project, _, _, account, user): return (project, account, user)
            case let .iap(_, _, project, account, user, _, _, _): return (project, account, user)
            default: return nil
            }
        }()
        if s.contains("remote host identification has changed") || s.contains("host key verification failed") {
            return "This computer’s security key changed since Circe last connected. If it was rebuilt, confirm with whoever manages it, then set it up again in Circe."
        }
        if let (project, pinned, user) = cloud {
            let account = pinned.flatMap { $0.isEmpty ? nil : $0 } ?? activeAccount()
            let who = account.map { "The Google account \($0)" } ?? "Your gcloud account"
            let fix = pinned?.isEmpty == false
                ? "Check this computer’s Google account in Edit connection, or ask for access to the VM."
                : "If another of your Google accounts owns this VM, enter it as this computer’s Google account in Edit connection."
            // gcloud looks the instance up before connecting; an account without access fails right here.
            if s.contains("required 'compute.") && s.contains("permission") {
                return "\(who) can’t see this VM\(project.map { " in project \($0)" } ?? ""). \(fix)"
            }
            if s.contains("4033") || s.contains("iap") && s.contains("not authorized") {
                return "Google’s Identity-Aware Proxy refused \(account ?? "your gcloud account"). \(fix) Otherwise, grant it “IAP-secured Tunnel User” and allow SSH from 35.235.240.0/20."
            }
            if s.contains("permission denied") && s.contains("publickey") {
                // ssh names the login it tried: "developer@compute.123: Permission denied (publickey)."
                let tried = stderr.range(of: #"[A-Za-z0-9_.-]+(?=@compute\.[0-9]+: Permission denied)"#, options: .regularExpression).map { String(stderr[$0]) }
                let login = tried ?? user.flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
                return "The VM refused the SSH key for Linux user “\(login)”. If you sign in to it as someone else, enter that name as the Linux user in Edit connection."
            }
        }
        if s.contains("permission denied") {
            return "SSH refused the login. Circe uses your SSH keys (or ssh-agent); make sure “ssh \(tunnel.displayName)” works in Terminal without a password prompt."
        }
        // With LogLevel=ERROR, ssh -W reports a refused VNC port only as "stdio forwarding failed".
        if s.contains("connect_to localhost port") || s.contains("open failed") || s.contains("stdio forwarding failed")
            || s.contains("connection refused") && s.contains("channel") {
            if tunnel.isGCloud {
                return "Circe reached this computer, but there’s no desktop running on it yet. Choose Add a computer → Google Cloud computer, pick this computer, and Circe will set one up (or find the one that’s there)."
            }
            return "Connected over SSH, but no VNC server is running on the machine. Use Set up & connect in this computer’s settings (Add a computer)."
        }
        if s.contains("could not resolve") || s.contains("not found") && s.contains("instance") {
            return "Couldn't find that machine. Check the name\(tunnel.isTunneled ? ", zone and project" : "")."
        }
        if s.contains("timed out") || s.contains("operation timed out") {
            return "The machine didn't respond. Is it running?"
        }
        if s.contains("4033") || s.contains("iap") && s.contains("not authorized") {
            return "Google's Identity-Aware Proxy refused the tunnel. Allow IAP TCP forwarding to port 22 (firewall source 35.235.240.0/20) and grant yourself “IAP-secured Tunnel User”."
        }
        let last = stderr.split(separator: "\n").last.map(String.init) ?? ""
        return last.isEmpty ? "The tunnel closed unexpectedly." : last
    }
}

/// Installs / repairs Circe's Linux host setup (desktop, VNC on localhost, audio) over the same tunnel
/// Circe connects through — one click, no files to copy, nothing exposed to the internet.
public enum LinuxSetup {
    public struct Report: Codable, Sendable, Equatable {
        public var display: Int
        public var password: String?
        public var audio: Bool?
        /// false when the account may not keep services running (no lingering): Circe starts the desktop on connect.
        public var persistent: Bool?
        public var withoutAdmin: Bool?
        /// The desktop shows a session that was already open: "chrome-remote-desktop" or "rdp" (nil: Circe's own).
        public var sharedSession: String?
    }

    /// What the read-only `--probe` found on the machine.
    public struct Probe: Codable, Sendable, Equatable {
        public struct OS: Codable, Sendable, Equatable { public var id: String; public var like: String; public var name: String }
        public struct Installation: Codable, Sendable, Equatable {
            public var installed: Bool; public var display: Int?; public var running: Bool
            /// Set up by this version of Circe's helpers (false: an older desktop Circe should update; nil: older script).
            public var current: Bool?
            /// It's showing a session that was already open ("chrome-remote-desktop" or "rdp"), not one of its own.
            public var shared: String?
        }
        public struct VNCServer: Codable, Sendable, Equatable {
            public var port: Int; public var display: Int; public var address: String; public var loopback: Bool; public var process: String
            /// The port answered with an RFB greeting (nil from older scripts that didn't check).
            public var rfb: Bool?
        }
        public var user: String
        public var os: OS
        /// apt, dnf, pacman, or none.
        public var packageManager: String
        /// root, passwordless, password, or none.
        public var sudo: String
        public var adminGroup: Bool
        public var systemd: Bool
        public var ffmpeg: Bool
        public var circe: Installation
        public var vnc: [VNCServer]
        public var sessions: [String]
        /// X displays with a socket in /tmp/.X11-unix (nil from older scripts).
        public var xDisplays: [Int]?
        /// A desktop can be installed into the user's own folder, without sudo.
        public var withoutAdmin: Bool?
        /// The account may enable lingering for itself (desktop keeps running after disconnecting).
        public var selfLinger: Bool?
        /// The account's services already keep running after its last session ends (systemd linger).
        public var lingering: Bool?
        /// The computer's own X11 desktop (GNOME, KDE…), which Circe's desktop runs instead of its own (nil: none, or an older script).
        public var systemDesktop: SystemDesktop?
        public struct SystemDesktop: Codable, Sendable, Equatable {
            /// The session's file name, e.g. "ubuntu"; name is what the login screen shows, e.g. "Ubuntu".
            public var id: String
            public var name: String
        }

        public var canInstall: Bool { packageManager != "none" && systemd && sudo != "none" }
        public var needsSudoPassword: Bool { sudo == "password" }
        /// Existing desktops Circe can show as they are: loopback VNC servers that aren't Circe's own.
        public var existingDesktops: [VNCServer] {
            // ss reports IPv4 and IPv6 listeners separately. They reach the same desktop/port,
            // and SwiftUI must never receive two choices with the same display identity.
            let candidates = vnc.filter { $0.loopback && $0.rfb != false && $0.port == 5900 + $0.display
                && (0...99).contains($0.display) && !(circe.installed && $0.display == circe.display) }
            return Dictionary(grouping: candidates, by: \.display).values.compactMap { listeners in
                // Prefer the endpoint the tunnel checks, then one with an identifiable process.
                listeners.sorted {
                    if ($0.address == "127.0.0.1") != ($1.address == "127.0.0.1") { return $0.address == "127.0.0.1" }
                    if $0.process.isEmpty != $1.process.isEmpty { return !$0.process.isEmpty }
                    return $0.process < $1.process
                }.first
            }.sorted { $0.display < $1.display }
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case tunnel(String)
        case script(exitCode: Int32, lastLines: String)
        /// The script stopped with a stable code (CIRCE_SETUP_ERROR), e.g. sudo_password_required.
        case code(String, message: String)
        case noResult

        public var description: String {
            switch self {
            case .tunnel(let s): return s
            case let .script(code, lines): return "Setup stopped (exit \(code)).\n\(lines)"
            case let .code(_, message): return message
            case .noResult: return "Setup finished but didn't report how to connect."
            }
        }
        public var code: String? { if case let .code(code, _) = self { return code }; return nil }
    }

    /// Starts Circe's desktop services (for desktops that can't keep running between connections). Waits up to
    /// ~20 s for the VNC port; returns whether it answered.
    /// Holds a real login session on the computer while Circe is connected. A desktop set up without
    /// lingering belongs to the account's service manager, which the system stops once the account's last
    /// session ends — and the VNC channel itself (`ssh -W`) isn't a session. Ending the lease lets it stop.
    public final class DesktopLease: @unchecked Sendable {
        let pipe: ProcessPipe
        private let lock = NSLock()
        private var ended = false
        private var lostHandler: (() -> Void)?
        init(pipe: ProcessPipe) { self.pipe = pipe }
        public var isActive: Bool { pipe.process.isRunning }
        public func end() {
            lock.withLock { ended = true; lostHandler = nil }
            try? pipe.stdinClose(); pipe.terminate()
        }
        /// Called once if the session ends without `end()` (network loss, the computer restarting).
        public func onLost(_ handler: @escaping @Sendable () -> Void) {
            let lostAlready: Bool = lock.withLock { if ended { return false }; if !pipe.process.isRunning { return true }; lostHandler = handler; return false }
            if lostAlready { handler() }
        }
        fileprivate func processEnded() {
            let handler: (() -> Void)? = lock.withLock { if ended { return nil }; defer { lostHandler = nil }; return lostHandler }
            handler?()
        }
        deinit { end() }
    }

    public static let desktopReadyMarker = "CIRCE_DESKTOP_READY"

    /// Starts Circe's desktop and waits until its VNC port answers, then keeps the session open (see DesktopLease).
    public static func desktopStartCommand(port: Int) -> String {
        "systemctl --user start circe-audio.service circe-desktop.service 2>/dev/null; "
            + "i=0; while [ $i -lt 60 ]; do "
            + "if bash -c 'exec 3<>/dev/tcp/127.0.0.1/\(port)' 2>/dev/null; then echo \(desktopReadyMarker); exec cat >/dev/null; fi; "
            + "i=$((i + 1)); sleep 0.5; done; "
            + "echo \"Circe’s desktop didn’t start: $(systemctl --user is-active circe-desktop.service 2>&1)\" >&2; exit 1"
    }

    /// Starts the desktop (≤45 s) and returns the lease that keeps it running; `cancel` stops waiting and the lease.
    /// Success needs the READY line itself: output ending without it, or a session that has already gone, is a failure.
    public static func startDesktop(tunnel: RFBTunnel, cancel: GoogleCloud.CancelToken, timeout: TimeInterval = 45) -> Result<DesktopLease, Failure> {
        let cancelled = Failure.code("cancelled", message: "Cancelled.")
        if cancel.isCancelled { return .failure(cancelled) }
        let port = tunnel.remoteVNCPort ?? 5901
        guard let (exe, args) = try? tunnel.remoteCommand(desktopStartCommand(port: port)) else { return .failure(.tunnel("This connection can’t start a desktop.")) }
        let pipe = ProcessPipe(executable: exe, arguments: args)
        let lease = DesktopLease(pipe: pipe)
        // Launch and cancellation are serialised: work cancelled before it starts never reaches the computer.
        let gate = NSLock()
        var stopped = false
        cancel.onCancel { gate.withLock { stopped = true }; lease.end() }
        pipe.process.terminationHandler = { [weak lease] _ in lease?.processEnded() }
        let launched: Bool = gate.withLock { stopped ? false : (try? pipe.start()) != nil }
        if cancel.isCancelled { lease.end(); return .failure(cancelled) }
        guard launched else { return .failure(.tunnel("Couldn’t start ssh.")) }
        let wake = DispatchSemaphore(value: 0)
        let readyLine = GoogleCloud.Once(), finished = GoogleCloud.Once()
        let reader = Thread {
            var text = ""
            while true {
                let d = pipe.read()
                if d.isEmpty { break }
                text += String(decoding: d, as: UTF8.self)
                if text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().contains(where: { $0 == desktopReadyMarker }),
                   readyLine.claim() { wake.signal() }
                if text.count > 4096 { text = String(text.suffix(256)) }
            }
            if finished.claim(), !readyLine.done { wake.signal() } // ended without READY: wake the waiter to report it
        }
        reader.start()
        _ = wake.wait(timeout: .now() + timeout)
        if cancel.isCancelled { lease.end(); return .failure(cancelled) }
        guard readyLine.done, lease.isActive else {
            let why = pipe.settledErrorOutput()
            lease.end()
            return .failure(.code("desktop_not_started", message: why.isEmpty ? "Circe’s desktop didn’t start in time." : ProcessPipe.explain(why, tunnel: tunnel)))
        }
        return .success(lease)
    }

    public static let resultMarker = "CIRCE_SETUP_RESULT "
    public static let secretMarker = "CIRCE_SETUP_SECRET "
    public static let errorMarker = "CIRCE_SETUP_ERROR "
    public static let probeMarker = "CIRCE_PROBE_RESULT "

    /// The remote shell command: the first stdin line is the sudo password (empty for none), the rest is
    /// the script. The password reaches the script only on descriptor 3 — never argv, files or environment.
    static func remoteWrapper(arguments: [String]) -> String {
        let quoted = arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        // Upload to a temp file first, then run it with stdin at EOF. Piping straight into `bash -s` lets
        // any command that reads stdin (apt, sudo, …) swallow the rest of the script.
        // set +x first: a login shell that traces commands would otherwise print the password.
        return "set +x; f=$(mktemp) && IFS= read -r p && cat > \"$f\" && { printf '%s\\n' \"$p\" | CIRCE_SUDO_PASSWORD_FD=3 bash \"$f\" \(quoted) 3<&0 </dev/null; }; rc=$?; unset p; rm -f \"$f\"; exit $rc"
    }

    /// Runs the script read-only (`--probe`) and reports what's on the machine.
    @discardableResult
    public static func probe(tunnel: RFBTunnel, script: Data, completion: @escaping @Sendable (Result<Probe, Failure>) -> Void) -> (() -> Void)? {
        let found = ProbeBox()
        return run(tunnel: tunnel, script: script, arguments: ["--probe"], onOutput: { line in
            if line.hasPrefix(probeMarker) { found.value = try? JSONDecoder().decode(Probe.self, from: Data(line.dropFirst(probeMarker.count).utf8)) }
        }, completion: { result in
            switch result {
            case .failure(.noResult):
                if let probe = found.value { completion(.success(probe)) }
                else { completion(.failure(.script(exitCode: 0, lastLines: "The computer didn’t report its setup."))) }
            case .failure(let failure): completion(.failure(failure))
            case .success: completion(.failure(.noResult))
            }
        })
    }
    private final class ProbeBox: @unchecked Sendable { var value: Probe? }

    /// Runs `script` remotely with `arguments`. Output lines stream to `onOutput` (main queue).
    @discardableResult
    public static func run(tunnel: RFBTunnel, script: Data, arguments: [String] = [], sudoPassword: String? = nil,
                           onPassword: (@Sendable (String) -> Void)? = nil,
                           onOutput: @escaping @Sendable (String) -> Void,
                           completion: @escaping @Sendable (Result<Report, Failure>) -> Void) -> (() -> Void)? {
        if let sudoPassword, sudoPassword.contains(where: \.isNewline) {
            completion(.failure(.code("sudo_password_incorrect", message: "Passwords can’t contain line breaks.")))
            return nil
        }
        let remote = remoteWrapper(arguments: arguments)
        guard let (exe, args) = try? tunnel.remoteCommand(remote) else {
            completion(.failure(.tunnel("Setup needs an SSH or Google Cloud connection.")))
            return nil
        }
        let pipe = ProcessPipe(executable: exe, arguments: args)
        do { try pipe.start() } catch {
            completion(.failure(.tunnel("Couldn't start \(exe.lastPathComponent): \(error.localizedDescription)")))
            return nil
        }
        pipe.writeAndClose(Data(((sudoPassword ?? "") + "\n").utf8) + script)
        // Defense in depth: if anything on the far side echoes the sudo password, it never reaches the UI.
        @Sendable func scrub(_ text: String) -> String {
            guard let sudoPassword, !sudoPassword.isEmpty else { return text }
            return text.replacingOccurrences(of: sudoPassword, with: "••••••")
        }
        let thread = Thread {
            var pending = ""
            var lines: [String] = []
            var report: Report?
            var errorCode: String?
            func emit(_ raw: String) {
                // Protocol records are recognised and parsed from the raw line (scrubbing could mangle them);
                // only text shown to people is scrubbed.
                let line = raw  // result/secret records carry the new VNC password: never logged, decoded or not
                if line.contains(resultMarker.trimmingCharacters(in: .whitespaces)) {
                    if line.hasPrefix(resultMarker) { report = try? JSONDecoder().decode(Report.self, from: Data(line.dropFirst(resultMarker.count).utf8)) }
                    return
                }
                if line.contains(secretMarker.trimmingCharacters(in: .whitespaces)) {
                    struct Secret: Decodable { var password: String }
                    if line.hasPrefix(secretMarker), let secret = try? JSONDecoder().decode(Secret.self, from: Data(line.dropFirst(secretMarker.count).utf8)) {
                        onPassword?(secret.password)
                    }
                    return
                }
                if line.hasPrefix(errorMarker) {
                    struct Coded: Decodable { var code: String }
                    errorCode = (try? JSONDecoder().decode(Coded.self, from: Data(line.dropFirst(errorMarker.count).utf8)))?.code
                    return
                }
                let shown = scrub(line)
                lines.append(shown)
                if lines.count > 40 { lines.removeFirst() }
                DispatchQueue.main.async { onOutput(shown) }
            }
            while true {
                let chunk = pipe.read()
                if chunk.isEmpty { break }
                pending += String(decoding: chunk, as: UTF8.self)
                while let nl = pending.firstIndex(of: "\n") {
                    emit(String(pending[..<nl]))
                    pending = String(pending[pending.index(after: nl)...])
                }
            }
            if !pending.isEmpty { emit(pending) }
            pipe.process.waitUntilExit()
            _ = pipe.settledErrorOutput()
            let code = pipe.process.terminationStatus
            let result: Result<Report, Failure>
            if code == 0, let report {
                result = .success(report)
            } else if let errorCode {
                let message = scrub(pipe.errorOutput).split(separator: "\n").last(where: { $0.hasPrefix("Circe: ") }).map { String($0.dropFirst(7)) }
                result = .failure(.code(errorCode, message: message ?? "Setup stopped (\(errorCode))."))
            } else if code == 255 {
                result = .failure(.tunnel(ProcessPipe.explain(scrub(pipe.errorOutput), tunnel: tunnel)))
            } else if code != 0 {
                let tail = (lines.suffix(6) + [scrub(pipe.errorOutput)]).filter { !$0.isEmpty }.joined(separator: "\n")
                result = .failure(.script(exitCode: code, lastLines: tail))
            } else {
                result = .failure(.noResult)
            }
            DispatchQueue.main.async { completion(result) }
        }
        thread.name = "circe.linux.setup"
        thread.start()
        return { pipe.terminate() }
    }
}
