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
    /// `gcloud compute ssh <instance> --zone … [--tunnel-through-iap] -- -W localhost:<vncPort>`.
    case gcloud(instance: String, zone: String, project: String?, useIAP: Bool, vncPort: Int)

    /// VNC display number → TCP port (":1" → 5901).
    public static func vncPort(display: Int) -> Int { 5900 + display }

    var isGCloud: Bool {
        if case .gcloud = self { return true }
        return false
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
        case let .gcloud(instance, _, _, _, _): return instance
        }
    }

    var keychainAccount: String {
        switch self {
        case let .direct(host, port): return "vnc:\(host):\(port)"
        case let .ssh(dest, port, vnc): return "ssh:\(dest):\(port ?? 22):\(vnc)"
        case let .gcloud(i, z, p, _, vnc): return "gcloud:\(p ?? "-"):\(z):\(i):\(vnc)"
        }
    }

    /// Child process that carries the VNC byte stream on stdin/stdout (nil for `.direct`).
    func streamCommand() throws -> (URL, [String]) {
        switch self {
        case .direct:
            throw RFBError.unsupported("direct connections don't use a tunnel process")
        case let .ssh(dest, port, vnc):
            return (SSHCommand.executable, SSHCommand.base(port: port) + ["-W", "localhost:\(vnc)", dest])
        case let .gcloud(instance, zone, project, iap, vnc):
            return (try GCloud.executable(), GCloud.sshArgs(instance: instance, zone: zone, project: project, iap: iap)
                    + ["--"] + SSHCommand.base(port: nil) + ["-W", "localhost:\(vnc)"])
        }
    }

    /// Child process that runs `remoteCommand` on the machine (used for audio). nil for `.direct`.
    func remoteCommand(_ remoteCommand: String) throws -> (URL, [String])? {
        switch self {
        case .direct:
            return nil
        case let .ssh(dest, port, _):
            return (SSHCommand.executable, SSHCommand.base(port: port) + ["-T", dest, remoteCommand])
        case let .gcloud(instance, zone, project, iap, _):
            return (try GCloud.executable(), GCloud.sshArgs(instance: instance, zone: zone, project: project, iap: iap)
                    + ["--command", remoteCommand, "--"] + SSHCommand.base(port: nil) + ["-T"])
        }
    }
}

enum SSHCommand {
    /// Test hook: substitute ssh (e.g. a script that maps `-W host:port` onto `nc`).
    static var executable: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["CIRCE_SSH_PATH"] ?? "/usr/bin/ssh")
    }

    /// Non-interactive (keys / ssh-agent only — a GUI app can't answer a tty prompt), fast dead-peer
    /// detection, and first-contact host keys accepted then pinned in known_hosts.
    static func base(port: Int?) -> [String] {
        var a = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=5",
                 "-o", "ServerAliveCountMax=3", "-o", "StrictHostKeyChecking=accept-new",
                 "-o", "ExitOnForwardFailure=yes", "-o", "LogLevel=ERROR"]
        if let port { a += ["-p", "\(port)"] }
        return a
    }
}

enum GCloud {
    /// GUI apps get a minimal PATH, so look where the Cloud SDK is normally installed.
    static func executable() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
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

    static func sshArgs(instance: String, zone: String, project: String?, iap: Bool) -> [String] {
        var a = ["compute", "ssh", instance, "--zone", zone, "--quiet"]
        if let project, !project.isEmpty { a += ["--project", project] }
        if iap { a.append("--tunnel-through-iap") }
        return a
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

    init(executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = GCloud.environment
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

    func terminate() {
        if process.isRunning { process.terminate() }
        try? stdinPipe.fileHandleForWriting.close()
    }

    /// Turns ssh/gcloud stderr into something a person can act on.
    static func explain(_ stderr: String, tunnel: RFBTunnel) -> String {
        let s = stderr.lowercased()
        if s.contains("reauthentication") || s.contains("gcloud auth login") || s.contains("refresh") && s.contains("token") {
            return "Google Cloud sign-in has expired. Run “gcloud auth login” in Terminal, then reconnect."
        }
        if s.contains("permission denied") {
            return "SSH refused the login. Circe uses your SSH keys (or ssh-agent); make sure “ssh \(tunnel.displayName)” works in Terminal without a password prompt."
        }
        if s.contains("connect_to localhost port") || s.contains("open failed") || s.contains("connection refused") && s.contains("channel") {
            return "Connected over SSH, but no VNC server is running on the machine. Run Circe's setup script on it (see Add Computer)."
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
    }

    public enum Failure: Error, CustomStringConvertible {
        case tunnel(String)
        case script(exitCode: Int32, lastLines: String)
        case noResult

        public var description: String {
            switch self {
            case .tunnel(let s): return s
            case let .script(code, lines): return "Setup stopped (exit \(code)).\n\(lines)"
            case .noResult: return "Setup finished but didn't report how to connect."
            }
        }
    }

    public static let resultMarker = "CIRCE_SETUP_RESULT "

    /// Runs `script` remotely with `arguments`. Output lines stream to `onOutput` (main queue).
    @discardableResult
    public static func run(tunnel: RFBTunnel, script: Data, arguments: [String] = [],
                           onOutput: @escaping @Sendable (String) -> Void,
                           completion: @escaping @Sendable (Result<Report, Failure>) -> Void) -> (() -> Void)? {
        let quoted = arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        // Upload to a temp file first, then run it with stdin at EOF. Piping straight into `bash -s` lets
        // any command that reads stdin (apt, sudo, …) swallow the rest of the script.
        let remote = "f=$(mktemp) && cat > \"$f\" && bash \"$f\" \(quoted) </dev/null; rc=$?; rm -f \"$f\"; exit $rc"
        guard let (exe, args) = try? tunnel.remoteCommand(remote) else {
            completion(.failure(.tunnel("Setup needs an SSH or Google Cloud connection.")))
            return nil
        }
        let pipe = ProcessPipe(executable: exe, arguments: args)
        do { try pipe.start() } catch {
            completion(.failure(.tunnel("Couldn't start \(exe.lastPathComponent): \(error.localizedDescription)")))
            return nil
        }
        pipe.writeAndClose(script)
        let thread = Thread {
            var pending = ""
            var lines: [String] = []
            var report: Report?
            func emit(_ line: String) {
                if line.hasPrefix(resultMarker),
                   let r = try? JSONDecoder().decode(Report.self, from: Data(line.dropFirst(resultMarker.count).utf8)) {
                    report = r
                    return // never echo the generated password into the visible log
                }
                lines.append(line)
                if lines.count > 40 { lines.removeFirst() }
                DispatchQueue.main.async { onOutput(line) }
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
            let code = pipe.process.terminationStatus
            let result: Result<Report, Failure>
            if code == 0, let report {
                result = .success(report)
            } else if code == 255 {
                result = .failure(.tunnel(ProcessPipe.explain(pipe.errorOutput, tunnel: tunnel)))
            } else if code != 0 {
                let tail = (lines.suffix(6) + [pipe.errorOutput]).filter { !$0.isEmpty }.joined(separator: "\n")
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
