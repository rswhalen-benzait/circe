import Foundation

/// Google Cloud operations for the guided setup, through the user's own gcloud CLI.
///
/// Every call pins `--account`, never changes gcloud's active account or configuration, disables
/// interactive prompts, and has a timeout. Results are plain values the UI layer can map; failures are
/// classified so each one can be shown with a single, specific remedy.
public enum GoogleCloud {
    public struct Account: Sendable, Equatable, Codable {
        public var email: String
        public var isActive: Bool
    }

    public enum Credential: Sendable, Equatable {
        case valid
        /// Credentials exist but must be refreshed in the browser (expired, revoked, reauth policy).
        case expired
        /// gcloud has never signed in with this account on this Mac.
        case notSignedIn
    }

    public struct Project: Sendable, Equatable, Codable {
        public var id: String
        public var name: String
    }

    public struct Instance: Sendable, Equatable, Codable {
        /// Google's numeric ID: stays the same across restarts, changes if the VM is recreated.
        public var id: String?
        public var name: String
        public var zone: String
        /// PROVISIONING, STAGING, RUNNING, STOPPING, STOPPED, SUSPENDING, SUSPENDED, REPAIRING, TERMINATED.
        public var status: String
        public var machineType: String
        public var gpu: String?
        public var hasExternalIP: Bool
        /// Linux logins suggested by the instance's metadata (custom `*-user` keys, `ssh-keys` owners).
        public var suggestedUsers: [String]
        public var osLogin: Bool?

        public init(id: String?, name: String, zone: String, status: String, machineType: String, gpu: String?, hasExternalIP: Bool,
                    suggestedUsers: [String], osLogin: Bool?) {
            self.id = id; self.name = name; self.zone = zone; self.status = status; self.machineType = machineType; self.gpu = gpu
            self.hasExternalIP = hasExternalIP; self.suggestedUsers = suggestedUsers; self.osLogin = osLogin
        }
        public var isRunning: Bool { status == "RUNNING" }
        /// Names this VM's SSH host key in Circe's known_hosts: a recreated VM gets a new ID, so it can't
        /// silently inherit (or be blocked by) the old machine's key.
        public func hostKeyAlias(project: String) -> String {
            if let id, id.allSatisfy(\.isNumber) { return "circe-gce-\(id)" }
            return "circe-gce-\(project)-\(zone)-\(name)"
        }
        public var canStart: Bool { ["STOPPED", "TERMINATED", "SUSPENDED"].contains(status) }
        public var isTransitioning: Bool { ["PROVISIONING", "STAGING", "STOPPING", "SUSPENDING", "REPAIRING"].contains(status) }
    }

    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case cliMissing
        case signInRequired(account: String)
        /// The account lacks a permission (e.g. `compute.instances.list`). `permission` is the IAM permission when known.
        case permissionDenied(permission: String?)
        case notFound
        case apiDisabled(service: String?)
        case quotaExceeded(String)
        /// e.g. ZONE_RESOURCE_POOL_EXHAUSTED: Google has no capacity for this machine (often a GPU) in the zone right now.
        case capacityUnavailable
        case timedOut
        /// Google couldn't be reached at all (DNS, proxy, TLS, no network) — not a sign-in problem.
        case offline
        case cancelled
        /// The browser signed in a different Google account than the one this computer uses.
        case wrongAccount(expected: String, actual: String)
        /// The organization doesn't allow this sign-in (admin_policy_enforced / access_denied).
        case signInBlocked
        /// The VM was deleted and created again under the same name since the user approved the action.
        case replaced
        case other(String)

        public var description: String {
            switch self {
            case .cliMissing: return "The Google Cloud CLI isn’t installed."
            case let .signInRequired(account): return "Sign in to Google as \(account) to continue."
            case let .permissionDenied(permission): return "This Google account doesn’t have access\(permission.map { " (\($0))" } ?? "")."
            case .notFound: return "Google Cloud couldn’t find it. Check the name, zone and project."
            case let .apiDisabled(service): return "The \(service ?? "required Google Cloud") API isn’t enabled for this project."
            case let .quotaExceeded(detail): return "A Google Cloud quota stops this: \(detail)"
            case .capacityUnavailable: return "Google doesn’t have capacity for this machine in its zone right now. Try again in a few minutes."
            case .timedOut: return "Google Cloud didn’t answer in time. Check your internet connection and try again."
            case .offline: return "Circe couldn’t reach Google. Check your internet connection (or proxy), then try again."
            case .cancelled: return "Cancelled."
            case let .wrongAccount(expected, actual): return "You signed in as \(actual). This computer uses \(expected)."
            case .replaced: return "This computer was deleted and created again since you chose it. Check it before starting it."
            case .signInBlocked: return "Your organization hasn’t allowed this Google sign-in. Ask your administrator."
            case let .other(message): return message
            }
        }
    }

    // MARK: Running gcloud

    struct Output: Sendable { var status: Int32; var stdout: String; var stderr: String; var timedOut: Bool }

    /// Test hook: substitute gcloud (CIRCE_GCLOUD_PATH), as CIRCE_SSH_PATH substitutes ssh.
    public static func executableURL() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["CIRCE_GCLOUD_PATH"] { return URL(fileURLWithPath: path) }
        do { return try GCloud.executable() } catch { throw Failure.cliMissing }
    }

    public static var isInstalled: Bool { (try? executableURL()) != nil }

    /// Settings that would silently override the pinned account, project or zone, or replace the identity
    /// entirely (a raw token or impersonation defeats `--account`). Circe passes all of these explicitly.
    static let overridingVariables = ["CLOUDSDK_CORE_ACCOUNT", "CLOUDSDK_CORE_PROJECT", "CLOUDSDK_COMPUTE_ZONE", "CLOUDSDK_COMPUTE_REGION",
                                      "CLOUDSDK_AUTH_ACCESS_TOKEN", "CLOUDSDK_AUTH_ACCESS_TOKEN_FILE", "CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT",
                                      "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE", "CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE_UNSAFE",
                                      "CLOUDSDK_AUTH_DISABLE_SSL_VALIDATION", "GOOGLE_APPLICATION_CREDENTIALS"]

    /// Circe runs gcloud under its own configuration in the user's gcloud folder: sign-ins (the credential store)
    /// are shared, but the active configuration's account, project, token-file, credential-override and
    /// impersonation settings can't apply. Proxy, certificate and context-aware-access settings are copied over
    /// so corporate networks keep working.
    public static let configurationName = "circe-app"

    static var configDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["CLOUDSDK_CONFIG"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/gcloud", isDirectory: true)
    }

    /// The Circe configuration's contents, derived from the user's active configuration.
    static func configuration(from active: String) -> String {
        var out = "# Written by Circe. Network settings come from your active gcloud configuration; nothing else applies.\n[core]\ndisable_usage_reporting = True\n"
        var section = ""
        var kept: [String: [String]] = [:]
        for raw in active.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line; continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            if section == "[proxy]" || section == "[context_aware]" || (section == "[core]" && key == "custom_ca_certs_file") {
                kept[section, default: []].append(line)
            }
        }
        if let core = kept["[core]"] { out += core.joined(separator: "\n") + "\n" }
        for name in ["[proxy]", "[context_aware]"] { if let lines = kept[name] { out += name + "\n" + lines.joined(separator: "\n") + "\n" } }
        return out
    }

    /// Writes Circe's configuration and verifies it; throws (so nothing runs) if it can't be made exactly so.
    public static func prepareConfiguration() throws {
        let fm = FileManager.default
        let directory = configDirectory.appendingPathComponent("configurations", isDirectory: true)
        let activeName = ((try? String(contentsOf: configDirectory.appendingPathComponent("active_config"), encoding: .utf8)) ?? "default")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let active = activeName == configurationName || activeName.contains("/") ? "" :
            ((try? String(contentsOf: directory.appendingPathComponent("config_\(activeName)"), encoding: .utf8)) ?? "")
        let wanted = configuration(from: active)
        let url = directory.appendingPathComponent("config_\(configurationName)")
        if (try? String(contentsOf: url, encoding: .utf8)) == wanted { return }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? Data(wanted.utf8).write(to: url, options: .atomic)
        guard (try? String(contentsOf: url, encoding: .utf8)) == wanted else {
            throw Failure.other("Circe couldn’t prepare its Google Cloud settings in \(directory.path). Check that folder’s permissions.")
        }
    }

    /// The environment for every gcloud Circe starts (including the IAP ProxyCommand, via ssh).
    public static func environment(prompts: Bool = false, cLocale: Bool = true, circeConfiguration: Bool = true) -> [String: String] {
        var environment = GCloud.environment
        for key in overridingVariables { environment.removeValue(forKey: key) }
        if circeConfiguration { environment["CLOUDSDK_ACTIVE_CONFIG_NAME"] = configurationName }
        if let gcloud = try? GCloud.executable() { environment.merge(GoogleCloudInstaller.environment(for: gcloud)) { _, new in new } }
        if cLocale { environment["LC_ALL"] = "C" }
        if prompts { environment.removeValue(forKey: "CLOUDSDK_CORE_DISABLE_PROMPTS") } else { environment["CLOUDSDK_CORE_DISABLE_PROMPTS"] = "1" }
        return environment
    }

    /// Runs gcloud with prompts disabled and the account pinned; kills it after `timeout`.
    static func run(_ arguments: [String], account: String?, timeout: TimeInterval, cancel: CancelToken? = nil) throws -> Output {
        let process = Process()
        process.executableURL = try executableURL()
        process.arguments = arguments + (account.map { ["--account=\($0)"] } ?? []) + ["--quiet", "--verbosity=error"]
        try prepareConfiguration()
        process.environment = environment()
        if cancel?.isCancelled == true { throw Failure.cancelled }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err; process.standardInput = FileHandle.nullDevice
        let collected = Collected()
        out.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; if !d.isEmpty { collected.append(out: d) } }
        err.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; if !d.isEmpty { collected.append(err: d) } }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        cancel?.onCancel { if process.isRunning { process.terminate() } }
        let finished = done.wait(timeout: .now() + timeout) == .success
        if !finished { process.terminate(); _ = done.wait(timeout: .now() + 3) }
        // Don't read to EOF: a child gcloud started (ssh, its IAP proxy) can keep the pipes open.
        collected.settle()
        out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil
        if cancel?.isCancelled == true { throw Failure.cancelled }
        return Output(status: finished ? process.terminationStatus : -1, stdout: collected.stdout, stderr: collected.stderr, timedOut: !finished)
    }

    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()
        func append(out d: Data) { lock.withLock { out.append(d) } }
        func append(err d: Data) { lock.withLock { err.append(d) } }
        var stdout: String { lock.withLock { String(decoding: out, as: UTF8.self) } }
        var stderr: String { lock.withLock { String(decoding: err, as: UTF8.self) } }
        /// Waits (≤0.5 s) until no more output arrives, so the last lines aren't lost.
        func settle() {
            var last = lock.withLock { out.count + err.count }
            for _ in 0..<10 {
                usleep(50_000)
                let now = lock.withLock { out.count + err.count }
                if now == last { return }
                last = now
            }
        }
    }

    /// Lets the UI abandon a long call (sign-in in the browser, starting a VM).
    public final class CancelToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var handlers: [() -> Void] = []
        public init() {}
        public var isCancelled: Bool { lock.withLock { cancelled } }
        public func cancel() {
            let run: [() -> Void] = lock.withLock { cancelled = true; defer { handlers = [] }; return handlers }
            run.forEach { $0() }
        }
        func onCancel(_ handler: @escaping () -> Void) {
            let now: Bool = lock.withLock { if cancelled { return true }; handlers.append(handler); return false }
            if now { handler() }
        }
    }

    /// Maps gcloud's stderr to a failure with a single remedy.
    static func classify(_ output: Output, account: String?) -> Failure {
        if output.timedOut { return .timedOut }
        let s = output.stderr
        let lower = s.lowercased()
        // A gcloud that can't start (too-old Python, broken install) is a tools problem, not a sign-in one.
        if lower.contains("gcloud failed to load") || lower.contains("no longer supported by gcloud") || lower.contains("bad interpreter") { return .cliMissing }
        if isNetworkFailure(lower) { return .offline }
        if lower.contains("reauthentication") || lower.contains("does not have any valid credentials") || lower.contains("invalid_rapt")
            || lower.contains("rapt_required") || lower.contains("invalid_grant") || lower.contains("token has been expired or revoked")
            || lower.contains("there was a problem refreshing your current auth tokens") || lower.contains("cannot prompt during non-interactive execution") {
            return .signInRequired(account: account ?? "your Google account")
        }
        if let range = s.range(of: #"(?<=Required ')[a-zA-Z]+\.[a-zA-Z.]+(?=' permission)"#, options: .regularExpression) {
            return .permissionDenied(permission: String(s[range]))
        }
        if lower.contains("zone_resource_pool_exhausted") || lower.contains("does not have enough resources available") {
            return .capacityUnavailable
        }
        if lower.contains("quota") && (lower.contains("exceeded") || lower.contains("quota_exceeded")) {
            return .quotaExceeded(lastErrorLine(s))
        }
        if lower.contains("service_disabled") || lower.contains("has not been used in project") || lower.contains("api has not been used") {
            let service = s.range(of: #"[a-z]+\.googleapis\.com"#, options: .regularExpression).map { String(s[$0]) }
            return .apiDisabled(service: service)
        }
        if lower.contains("permission_denied") || lower.contains("permission denied") || lower.contains("forbidden") || lower.contains("does not have permission") {
            return .permissionDenied(permission: nil)
        }
        if lower.contains("was not found") || lower.contains("notfound") || lower.contains("not_found") || lower.contains("could not find") {
            return .notFound
        }
        return .other(lastErrorLine(s).isEmpty ? "gcloud stopped (exit \(output.status))." : lastErrorLine(s))
    }

    static func isNetworkFailure(_ lower: String) -> Bool {
        ["unable to find the server", "nodename nor servname", "name or service not known", "temporary failure in name resolution",
         "network is unreachable", "max retries exceeded", "connection reset by peer", "failed to establish a new connection",
         "certificate verify failed", "proxy error", "407 proxy authentication", "no route to host"].contains { lower.contains($0) }
    }

    static func lastErrorLine(_ stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("WARNING") && !$0.contains("NumPy") && !$0.contains("increasing_the_tcp") }
        return (lines.last(where: { $0.hasPrefix("ERROR") || $0.hasPrefix("- ") }) ?? lines.last ?? "")
            .replacingOccurrences(of: #"^ERROR: \([a-z0-9.\-]+\) "#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^- "#, with: "", options: .regularExpression)
    }

    // MARK: Accounts and sign-in

    /// Accounts gcloud holds credentials for. Never changes which one is active.
    public static func accounts() throws -> [Account] {
        let output = try run(["auth", "list", "--format=json"], account: nil, timeout: 20)
        guard output.status == 0 else { throw classify(output, account: nil) }
        // "Listed 0 items" goes to stderr; an unreadable answer means the tools are broken, not that there are no accounts.
        struct Row: Decodable { var account: String; var status: String? }
        let rows = (try? JSONDecoder().decode([Row].self, from: Data(output.stdout.utf8))) ?? []
        return rows.map { Account(email: $0.account, isActive: $0.status == "ACTIVE") }
    }

    /// Whether `account` can act right now, by asking gcloud for a token (refreshing it if needed).
    public static func credential(for account: String) throws -> Credential {
        guard try accounts().contains(where: { $0.email.caseInsensitiveCompare(account) == .orderedSame }) else { return .notSignedIn }
        // The token goes to a private buffer and is dropped; it never reaches logs or the UI.
        let output = try run(["auth", "print-access-token"], account: account, timeout: 30)
        if output.status == 0, !output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .valid }
        if output.timedOut { throw Failure.timedOut }
        switch classify(output, account: account) {
        case .offline: throw Failure.offline
        case .cliMissing: throw Failure.cliMissing
        case .signInRequired: return .expired
        case let failure: throw failure
        }
    }

    public enum SignInEvent: Sendable { case page(URL), needsCode }

    /// Where a verification code typed in Circe goes: the waiting `gcloud auth login`'s stdin.
    public final class SignInChannel: @unchecked Sendable {
        private let lock = NSLock()
        private var handle: FileHandle?
        func attach(_ handle: FileHandle) { lock.withLock { self.handle = handle } }
        func detach() { lock.withLock { handle = nil } }
        public init(ignoringSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN); return () }()) {}
        public func submit(_ code: String) {
            guard !code.contains(where: \.isNewline) else { return }
            lock.withLock { try? handle?.write(contentsOf: Data((code + "\n").utf8)) }
        }
    }

    /// Opens Google's sign-in page in the browser and waits for the user to finish (up to 10 minutes).
    /// `--no-activate` keeps gcloud's active account as it was, so other tools aren't affected.
    /// Returns the email the user actually signed in with (it can differ from the hint).
    /// `useCode`: don't open the browser from gcloud; show the page link and take the code Google displays.
    public static func signIn(hint account: String?, useCode: Bool = false, cancel: CancelToken, channel: SignInChannel? = nil,
                              events: @escaping @Sendable (SignInEvent) -> Void = { _ in }) throws -> String {
        let before = Set(((try? accounts()) ?? []).map { $0.email.lowercased() })
        var arguments = ["auth", "login", "--no-activate", "--brief", "--force"]
        if useCode { arguments.append("--no-launch-browser") }
        if let account, !account.isEmpty { arguments.insert(account, at: 2) }
        let output = try runSignIn(arguments, cancel: cancel, channel: channel, hint: account, events: events)
        guard output.status == 0 else {
            if output.timedOut { throw Failure.timedOut }
            let text = output.stderr
            if let range = text.range(of: #"(?<=received credentials were for account \[)[^\]]+"#, options: .regularExpression) {
                throw Failure.wrongAccount(expected: account ?? "", actual: String(text[range]))
            }
            if text.contains("access_denied") || text.contains("admin_policy_enforced") { throw Failure.signInBlocked }
            throw Failure.other(lastErrorLine(text).isEmpty ? "Google sign-in didn’t finish." : lastErrorLine(text))
        }
        // gcloud prints "You are now logged in as [x]"; fall back to the account list.
        let text = output.stdout + output.stderr
        if let range = text.range(of: #"(?<=logged in as \[)[^\]]+"#, options: .regularExpression) { return String(text[range]) }
        let after = ((try? accounts()) ?? []).map(\.email)
        if let account, after.contains(where: { $0.caseInsensitiveCompare(account) == .orderedSame }) { return account }
        if let new = after.first(where: { !before.contains($0.lowercased()) }) { return new }
        throw Failure.other("Google sign-in finished, but gcloud didn’t report which account was used.")
    }

    /// `auth login` opens the browser and waits for Google to redirect back to a local port. Prompts stay
    /// enabled (it may ask for a code if the browser can't return), and stdin stays open but unused.
    static func runSignIn(_ arguments: [String], cancel: CancelToken, channel: SignInChannel? = nil, hint: String? = nil,
                          events: @escaping @Sendable (SignInEvent) -> Void = { _ in }) throws -> Output {
        let process = Process()
        process.executableURL = try executableURL()
        process.arguments = arguments + ["--verbosity=error"]
        try prepareConfiguration()
        process.environment = environment(prompts: true)
        if cancel.isCancelled { throw Failure.cancelled }
        signal(SIGPIPE, SIG_IGN) // a code typed after gcloud exits must not kill Circe
        let input = Pipe(), out = Pipe(), err = Pipe()
        process.standardInput = input; process.standardOutput = out; process.standardError = err
        let collected = Collected()
        // Report the sign-in page (for "open it again") and a code prompt, once each, even though stdout and
        // stderr are read on different threads. The URL stays in memory.
        let pageOnce = Once(), codeOnce = Once()
        let watch: @Sendable () -> Void = {
            let text = collected.stdout + collected.stderr
            if !pageOnce.done, let url = signInPage(in: text, hint: hint), pageOnce.claim() { events(.page(url)) }
            let lower = text.lowercased()
            if !codeOnce.done, lower.contains("verification code") || lower.contains("authorization code"), codeOnce.claim() {
                events(.needsCode)
            }
        }
        out.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; if !d.isEmpty { collected.append(out: d); watch() } }
        err.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; if !d.isEmpty { collected.append(err: d); watch() } }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        channel?.attach(input.fileHandleForWriting)
        defer { channel?.detach() }
        cancel.onCancel { if process.isRunning { process.terminate() } }
        let finished = done.wait(timeout: .now() + 600) == .success
        if !finished { process.terminate(); _ = done.wait(timeout: .now() + 3) }
        try? input.fileHandleForWriting.close()
        collected.settle()
        out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil
        if cancel.isCancelled { throw Failure.cancelled }
        return Output(status: finished ? process.terminationStatus : -1, stdout: collected.stdout, stderr: collected.stderr, timedOut: !finished)
    }

    /// True for exactly one caller.
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        var done: Bool { lock.withLock { claimed } }
        func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
    }

    /// The Google sign-in link gcloud printed, with the account pre-selected (`login_hint`) when Circe knows it.
    static func signInPage(in text: String, hint: String?) -> URL? {
        // Only a complete link: output arrives in pieces, and a link at the very end of what's arrived so far
        // may still be growing (gcloud ends the line after it).
        guard let range = text.range(of: #"https://accounts\.google\.com/[^\s"'<>]+(?=[\s"'<>])"#, options: .regularExpression),
              var parts = URLComponents(string: String(text[range])), parts.scheme == "https", parts.host == "accounts.google.com"
        else { return nil }
        // Appended to the query as-is, so gcloud's own encoding of the other parameters is untouched.
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        if let hint, hint.contains("@"), let encoded = hint.addingPercentEncoding(withAllowedCharacters: allowed),
           !(parts.queryItems ?? []).contains(where: { $0.name == "login_hint" }) {
            let query = parts.percentEncodedQuery ?? ""
            parts.percentEncodedQuery = (query.isEmpty ? "" : query + "&") + "login_hint=" + encoded
        }
        return parts.url
    }

    // MARK: Projects and instances

    public static func projects(account: String) throws -> [Project] {
        // gcloud pages through every project itself; no cap, so a large organization isn't silently cut off.
        let output = try run(["projects", "list", "--format=json(projectId,name)", "--sort-by=projectId"], account: account, timeout: 180)
        guard output.status == 0 else { throw classify(output, account: account) }
        struct Row: Decodable { var projectId: String; var name: String? }
        guard let rows = try? JSONDecoder().decode([Row].self, from: Data(output.stdout.utf8)) else {
            throw Failure.other("Google returned a project list Circe couldn’t read. Enter the project ID instead.")
        }
        return rows.map { Project(id: $0.projectId, name: $0.name ?? $0.projectId) }
    }

    /// All VMs in the project, across zones.
    public static func instances(account: String, project: String) throws -> [Instance] {
        let output = try run(["compute", "instances", "list", "--project=\(project)", "--format=json"], account: account, timeout: 90)
        guard output.status == 0 else { throw classify(output, account: account) }
        return try parseInstances(output.stdout)
    }

    public static func instance(account: String, project: String, zone: String, name: String) throws -> Instance {
        let output = try run(["compute", "instances", "describe", name, "--zone=\(zone)", "--project=\(project)", "--format=json"],
                             account: account, timeout: 60)
        guard output.status == 0 else { throw classify(output, account: account) }
        guard let first = try parseInstances("[\(output.stdout)]").first else { throw Failure.notFound }
        return first
    }

    static func parseInstances(_ json: String) throws -> [Instance] {
        struct Item: Decodable { var key: String; var value: String? }
        struct Metadata: Decodable { var items: [Item]? }
        struct Accelerator: Decodable { var acceleratorType: String; var acceleratorCount: Int? }
        struct Access: Decodable { var natIP: String? }
        struct Interface: Decodable { var accessConfigs: [Access]? }
        struct Row: Decodable {
            var id: String?
            var name: String; var zone: String; var status: String; var machineType: String
            var guestAccelerators: [Accelerator]?; var networkInterfaces: [Interface]?; var metadata: Metadata?
            struct Effective: Decodable { var enableOsloginMetadataValue: Bool? }
            struct Status: Decodable { var effectiveInstanceMetadata: Effective? }
            var resourceStatus: Status?
        }
        let rows: [Row]
        do { rows = try JSONDecoder().decode([Row].self, from: Data(json.utf8)) }
        catch { throw Failure.other("Google Cloud returned VM details Circe couldn’t read.") }
        return rows.map { row in
            let items = row.metadata?.items ?? []
            let gpu = row.guestAccelerators?.first.map { a in
                "\(a.acceleratorCount.map { $0 > 1 ? "\($0)× " : "" } ?? "")\(lastPathComponent(a.acceleratorType).uppercased().replacingOccurrences(of: "NVIDIA-", with: "NVIDIA "))"
            }
            // Google's resolved value (instance, zone and project precedence) when present; else the VM's own item.
            let osLogin = row.resourceStatus?.effectiveInstanceMetadata?.enableOsloginMetadataValue
                ?? items.first(where: { $0.key == "enable-oslogin" }).map { ($0.value ?? "").uppercased() == "TRUE" }
            return Instance(id: row.id, name: row.name, zone: lastPathComponent(row.zone), status: row.status, machineType: lastPathComponent(row.machineType),
                            gpu: gpu, hasExternalIP: row.networkInterfaces?.contains { $0.accessConfigs?.contains { $0.natIP != nil } ?? false } ?? false,
                            suggestedUsers: suggestedUsers(metadata: items.map { ($0.key, $0.value ?? "") }), osLogin: osLogin)
        }
    }

    static func lastPathComponent(_ url: String) -> String { url.split(separator: "/").last.map(String.init) ?? url }

    /// Linux logins hinted by metadata, best first: explicit `*user` keys, then owners of `ssh-keys` entries
    /// holding this Mac's gcloud key, then other `ssh-keys` owners.
    static func suggestedUsers(metadata: [(String, String)], localKey: String? = localPublicKey()) -> [String] {
        func valid(_ name: String) -> Bool { name.range(of: "^[A-Za-z_][A-Za-z0-9_.-]{0,31}$", options: .regularExpression) != nil }
        var ordered: [String] = []
        func add(_ name: String) { if valid(name), !ordered.contains(name) { ordered.append(name) } }
        for (key, value) in metadata where key == "user" || key.hasSuffix("-user") || key.hasSuffix("_user") {
            add(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let keyBody = localKey.flatMap { $0.split(separator: " ").dropFirst().first.map(String.init) }
        var owners: [(String, Bool)] = []
        for (key, value) in metadata where key == "ssh-keys" || key == "sshKeys" || key.hasSuffix("ssh-keys") {
            for line in value.split(whereSeparator: \.isNewline) {
                let text = String(line)
                if key == "ssh-keys" || key == "sshKeys", let colon = text.firstIndex(of: ":") {
                    owners.append((String(text[..<colon]), keyBody.map { text.contains($0) } ?? false))
                }
            }
        }
        owners.filter(\.1).forEach { add($0.0) }
        owners.filter { !$0.1 }.forEach { add($0.0) }
        return ordered
    }

    static func localPublicKey() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/google_compute_engine.pub")
        return try? String(contentsOf: path, encoding: .utf8)
    }

    // MARK: Power

    /// Starts (or resumes) the VM and waits until Google reports it RUNNING, reporting each status it passes
    /// through. Waits for a VM that is still stopping before starting it; never starts one twice.
    public static func start(_ instance: Instance, account: String, project: String, cancel: CancelToken,
                             progress: @escaping @Sendable (String) -> Void = { _ in }) throws {
        func current() throws -> Instance {
            let latest = try self.instance(account: account, project: project, zone: instance.zone, name: instance.name)
            // Never start (or wait on) a different machine that took the approved one's name.
            if let approved = instance.id, let now = latest.id, approved != now { throw Failure.replaced }
            return latest
        }
        func pause(_ attempt: Int) throws {
            if cancel.isCancelled { throw Failure.cancelled }
            Thread.sleep(forTimeInterval: min(5, 1 + Double(attempt) * 0.5))
            if cancel.isCancelled { throw Failure.cancelled }
        }
        var state = try current()
        var attempt = 0
        while ["STOPPING", "SUSPENDING"].contains(state.status), attempt < 120 {
            progress(state.status); try pause(attempt); attempt += 1; state = try current()
        }
        if state.isRunning { return }
        var operation: String?
        if state.canStart {
            let verb = state.status == "SUSPENDED" ? "resume" : "start"
            progress(verb == "resume" ? "RESUMING" : "STARTING")
            let output = try run(["compute", "instances", verb, instance.name, "--zone=\(instance.zone)", "--project=\(project)", "--async", "--format=json(name)"],
                                 account: account, timeout: 120, cancel: cancel)
            guard output.status == 0 else { throw classify(output, account: account) }
            operation = operationName(output.stdout + "\n" + output.stderr)
        }
        attempt = 0
        var stillStopped = 0
        while attempt < 240 {
            try pause(attempt); attempt += 1
            // The operation is the authority on failure (stockout, quota); the VM's status shows progress.
            if let operation, let failure = try operationFailure(operation, zone: instance.zone, account: account, project: project) { throw failure }
            state = try current()
            if state.isRunning { return }
            // Google moves a starting VM to STAGING within seconds. Still stopped after ~90 s means the start
            // failed and the operation couldn't be read (permission): say so instead of waiting 20 minutes.
            stillStopped = state.canStart ? stillStopped + 1 : 0
            if stillStopped >= 20 {
                throw Failure.other("Google Cloud accepted the request, but \(instance.name) is still stopped. Google may not have capacity in \(instance.zone) right now, or a quota may be in the way. Try again in a few minutes.")
            }
            progress(state.status)
        }
        throw Failure.timedOut
    }

    static func operationName(_ text: String) -> String? {
        text.range(of: #"operation-[A-Za-z0-9-]+"#, options: .regularExpression).map { String(text[$0]) }
    }

    /// nil while the operation runs or if it succeeded; the classified error if it finished with one.
    static func operationFailure(_ name: String, zone: String, account: String, project: String) throws -> Failure? {
        let output = try run(["compute", "operations", "describe", name, "--zone=\(zone)", "--project=\(project)", "--format=json(status,error)"],
                             account: account, timeout: 30)
        guard output.status == 0 else { return nil } // can't track it (permission): fall back to the VM's status
        struct Item: Decodable { var code: String?; var message: String? }
        struct Errors: Decodable { var errors: [Item]? }
        struct Operation: Decodable { var status: String?; var error: Errors? }
        guard let op = try? JSONDecoder().decode(Operation.self, from: Data(output.stdout.utf8)), op.status == "DONE",
              let first = op.error?.errors?.first else { return nil }
        let text = "\(first.code ?? "") \(first.message ?? "")"
        let failure = classify(Output(status: 1, stdout: "", stderr: text, timedOut: false), account: account)
        if case .other = failure { return .other(first.message ?? "Google Cloud couldn’t start this computer.") }
        return failure
    }

    public static func stop(_ instance: Instance, account: String, project: String) throws {
        let output = try run(["compute", "instances", "stop", instance.name, "--zone=\(instance.zone)", "--project=\(project)", "--async"],
                             account: account, timeout: 120)
        guard output.status == 0 else { throw classify(output, account: account) }
    }

    // MARK: Linux sign-in

    /// The Linux name Google's OS Login gives this account (read-only). nil when the account has no profile.
    public static func osLoginUsername(account: String, project: String) -> String? {
        guard let output = try? run(["compute", "os-login", "describe-profile", "--project=\(project)", "--format=json(posixAccounts)"],
                                    account: account, timeout: 30), output.status == 0 else { return nil }
        struct Posix: Decodable { var username: String?; var primary: Bool? }
        struct Profile: Decodable { var posixAccounts: [Posix]? }
        let accounts = (try? JSONDecoder().decode(Profile.self, from: Data(output.stdout.utf8)))?.posixAccounts ?? []
        return (accounts.first(where: { $0.primary == true }) ?? accounts.first)?.username
    }

    /// The project's `enable-oslogin` metadata (nil when unset or the account can't read the project).
    public static func projectOSLogin(account: String, project: String) -> Bool? {
        guard let output = try? run(["compute", "project-info", "describe", "--project=\(project)", "--format=json(commonInstanceMetadata.items)"],
                                    account: account, timeout: 30), output.status == 0 else { return nil }
        struct Item: Decodable { var key: String; var value: String? }
        struct Metadata: Decodable { var items: [Item]? }
        struct Info: Decodable { var commonInstanceMetadata: Metadata? }
        let items = (try? JSONDecoder().decode(Info.self, from: Data(output.stdout.utf8)))?.commonInstanceMetadata?.items ?? []
        return items.first(where: { $0.key == "enable-oslogin" }).map { ($0.value ?? "").uppercased() == "TRUE" }
    }

    /// Pins the VM's published host keys (if any) under its Circe alias before first contact.
    /// Returns false if the VM now publishes host keys that differ from the ones Circe pinned.
    @discardableResult
    public static func pinPublishedHostKeys(account: String, project: String, instance: Instance) -> Bool {
        IAPSSH.pin(hostKeys: publishedHostKeys(account: account, project: project, zone: instance.zone, instance: instance.name),
                   alias: instance.hostKeyAlias(project: project))
    }

    /// Host keys the VM published to its guest attributes (when the guest agent and org policy allow it).
    public static func publishedHostKeys(account: String, project: String, zone: String, instance: String) -> [String] {
        guard let output = try? run(["compute", "instances", "get-guest-attributes", instance, "--zone=\(zone)", "--project=\(project)",
                                     "--query-path=hostkeys/", "--format=json"], account: account, timeout: 30), output.status == 0 else { return [] }
        struct Attribute: Decodable { var key: String; var value: String }
        return ((try? JSONDecoder().decode([Attribute].self, from: Data(output.stdout.utf8))) ?? []).map { "\($0.key) \($0.value)" }
    }

    public enum LoginCheck: Sendable, Equatable {
        /// Signed in; `user`/`uid` are what Linux reports.
        case ok(user: String, uid: Int)
        case keyRefused
        case notAuthorized
        case unreachable
        case hostKeyChanged
        case failed(String)
    }

    /// Signs in over `.iap` and runs `id` — read-only on the VM and in Google Cloud.
    public static func verifyLogin(_ tunnel: RFBTunnel, timeout: TimeInterval = 45) -> LoginCheck {
        guard let (exe, args) = try? tunnel.remoteCommand("printf 'CIRCE_ID %s %s\\n' \"$(id -un)\" \"$(id -u)\"") else { return .failed("Not a Google Cloud connection.") }
        let pipe = ProcessPipe(executable: exe, arguments: args)
        pipe.process.environment = environment()
        do { try pipe.start() } catch { return .failed(error.localizedDescription) }
        try? pipe.stdinClose()
        var text = ""
        let deadline = Date().addingTimeInterval(timeout)
        let reader = DispatchQueue(label: "circe.gcloud.verify")
        let done = DispatchSemaphore(value: 0)
        let box = Collected()
        reader.async { while true { let d = pipe.read(); if d.isEmpty { break }; box.append(out: d) }; done.signal() }
        if done.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .timedOut { pipe.terminate(); return .unreachable }
        text = box.stdout
        if let line = text.split(separator: "\n").first(where: { $0.hasPrefix("CIRCE_ID ") }) {
            let parts = line.split(separator: " ")
            if parts.count == 3, let uid = Int(parts[2]) { return .ok(user: String(parts[1]), uid: uid) }
        }
        let err = pipe.settledErrorOutput().lowercased()
        if err.contains("permission denied (publickey") || err.contains("too many authentication failures") { return .keyRefused }
        if err.contains("host identification has changed") || err.contains("host key verification failed") { return .hostKeyChanged }
        if err.contains("4033") || err.contains("not authorized") { return .notAuthorized }
        if err.contains("4003") || err.contains("timed out") || err.contains("connection refused") || err.contains("failed to connect to backend") { return .unreachable }
        return .failed(ProcessPipe.explain(err, tunnel: tunnel))
    }

    /// The one cloud write in setup, run only after the user agrees: lets gcloud make sure this Mac's key
    /// can sign in (it adds the public key to the account's OS Login profile, or to the VM's SSH keys).
    /// Returns the Linux user gcloud signed in as.
    ///
    /// OS Login: `os-login ssh-keys add` — only the key registration, no SSH. Otherwise gcloud's own key flow
    /// (`compute ssh`), with strict host-key checking against the key Circe already pinned for this VM.
    public static func authorizeKey(account: String, project: String, zone: String, instance: Instance, user: String?, osLogin: Bool) throws -> String? {
        let publicKey = IAPSSH.identity.appendingPathExtension("pub")
        try ensureLocalKey(publicKey: publicKey)
        if osLogin {
            let output = try run(["compute", "os-login", "ssh-keys", "add", "--key-file=\(publicKey.path)", "--project=\(project)", "--format=json(loginProfile.posixAccounts)"],
                                 account: account, timeout: 60)
            guard output.status == 0 else { throw classify(output, account: account) }
            return osLoginUsername(account: account, project: project)
        }
        let alias = instance.hostKeyAlias(project: project)
        guard let id = instance.id else { throw Failure.other("Circe needs to read this computer’s details to add your key. Ask for access to view it.") }
        switch IAPSSH.seedGCloudKnownHosts(from: alias, as: "compute.\(id)") {
        case .ready: break
        case .noPin: throw Failure.other("Circe needs this computer’s security key before adding yours. Check the connection again first.")
        case .mismatch: throw Failure.other("This computer’s security key doesn’t match the one gcloud recorded for it. Confirm with whoever manages it before continuing.")
        }
        let target = user.flatMap { $0.isEmpty ? nil : "\($0)@\(instance.name)" } ?? instance.name
        let output = try run(["compute", "ssh", target, "--zone=\(zone)", "--project=\(project)", "--tunnel-through-iap", "--strict-host-key-checking=yes",
                              "--command=id -un", "--", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=20"], account: account, timeout: 180)
        let name = output.stdout.split(whereSeparator: \.isNewline).last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if output.status == 0, name.range(of: "^[A-Za-z_][A-Za-z0-9_.-]{0,31}$", options: .regularExpression) != nil { return name }
        if output.stderr.lowercased().contains("permission denied (publickey") {
            throw Failure.other("Google added your key, but the computer still refused it. It may not accept Google-managed keys; ask whoever set it up for a Linux user and key.")
        }
        throw classify(output, account: account)
    }

    /// gcloud's key pair (~/.ssh/google_compute_engine), created the way gcloud would if it's missing.
    static func ensureLocalKey(publicKey: URL) throws {
        if FileManager.default.fileExists(atPath: publicKey.path) { return }
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-q", "-t", "rsa", "-b", "3072", "-N", "", "-C", "\(NSUserName())@\(Host.current().localizedName ?? "mac")", "-f", IAPSSH.identity.path]
        keygen.standardInput = FileHandle.nullDevice; keygen.standardOutput = FileHandle.nullDevice; keygen.standardError = FileHandle.nullDevice
        try FileManager.default.createDirectory(at: IAPSSH.identity.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try keygen.run(); keygen.waitUntilExit()
        guard keygen.terminationStatus == 0 else { throw Failure.other("Circe couldn’t create a sign-in key on this Mac.") }
    }

    /// Logins this Mac already uses for the VM, read (never executed) from ~/.ssh/config: blocks whose Host or
    /// HostName is exactly the instance name, with their User and IdentityFile.
    public struct SSHConfigLogin: Sendable, Equatable { public var user: String; public var identityFile: String? }
    public static func sshConfigLogins(instance: String, configText: String? = nil) -> [SSHConfigLogin] {
        let text = configText ?? (try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config"), encoding: .utf8)) ?? ""
        var found: [SSHConfigLogin] = []
        var hosts: [String] = [], hostName: String?, user: String?, identity: String?
        func flush() {
            if (hosts.contains(instance) || hostName == instance), let user,
               user.range(of: "^[A-Za-z_][A-Za-z0-9_.-]{0,31}$", options: .regularExpression) != nil {
                let login = SSHConfigLogin(user: user, identityFile: identity)
                if !found.contains(login) { found.append(login) }
            }
            hosts = []; hostName = nil; user = nil; identity = nil
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t=\"")) }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "host": flush(); hosts = parts[1].split(separator: " ").map(String.init)
            case "match": flush()
            case "hostname": hostName = parts[1]
            case "user": user = parts[1]
            case "identityfile": if identity == nil { identity = parts[1] }
            default: break
            }
        }
        flush()
        return found
    }

    // MARK: Reachability

    public enum TunnelCheck: Sendable, Equatable {
        case reachable
        /// IAP refused this account (4033): missing "IAP-secured Tunnel User", or wrong account.
        case notAuthorized
        /// IAP couldn't reach port 22 (4003): firewall lacks 35.235.240.0/20, or sshd isn't up yet.
        case backendUnreachable
        case failed(String)
    }

    /// Opens an IAP tunnel to port 22 and waits for the SSH banner. Read-only: it never pushes keys.
    public static func checkTunnel(account: String, project: String, zone: String, instance: String, timeout: TimeInterval = 40) throws -> TunnelCheck {
        let process = Process()
        process.executableURL = try executableURL()
        process.arguments = ["compute", "start-iap-tunnel", instance, "22", "--listen-on-stdin", "--zone=\(zone)", "--project=\(project)",
                             "--account=\(account)", "--verbosity=error", "--quiet"]
        try prepareConfiguration()
        process.environment = environment()
        let input = Pipe(), out = Pipe(), err = Pipe()
        process.standardInput = input; process.standardOutput = out; process.standardError = err
        let collected = Collected()
        let banner = DispatchSemaphore(value: 0)
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            collected.append(out: d)
            if collected.stdout.contains("SSH-") { banner.signal() }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            collected.append(err: d)
            let s = collected.stderr
            if s.contains("4033") || s.contains("4003") || s.contains("ERROR") { banner.signal() }
        }
        process.terminationHandler = { _ in banner.signal() }
        try process.run()
        let answered = banner.wait(timeout: .now() + timeout) == .success
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil
        if collected.stdout.contains("SSH-") { return .reachable }
        let s = collected.stderr
        if s.contains("4033") || s.lowercased().contains("not authorized") { return .notAuthorized }
        if s.contains("4003") || s.lowercased().contains("failed to connect to backend") { return .backendUnreachable }
        if !answered { return .failed("The secure tunnel didn’t answer in time.") }
        let failure = classify(Output(status: process.terminationStatus, stdout: "", stderr: s, timedOut: false), account: account)
        if case .other = failure { return .failed(failure.description) }
        throw failure
    }
}
