import AppKit
import Foundation

// The Google Cloud setup flow: plain values, the engine operations it needs (supplied by EngineBridge),
// and the step-by-step state machine behind GoogleCloudSetupView. No engine imports, so the UI checks and
// previews can compile this file on its own.

public struct CloudAccount: Equatable, Sendable { public var email: String; public var isActive: Bool
    public init(email: String, isActive: Bool) { self.email = email; self.isActive = isActive } }

public enum CloudCredential: Equatable, Sendable { case valid, expired, notSignedIn }

public struct CloudProject: Equatable, Hashable, Sendable, Identifiable {
    public var id: String; public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct CloudInstance: Equatable, Sendable, Identifiable {
    public var instanceID: String?
    public var name: String
    public var zone: String
    public var status: String
    public var machineType: String
    public var gpu: String?
    public var suggestedUsers: [String]
    public var hostKeyAlias: String
    /// The VM's own `enable-oslogin` metadata, when set.
    public var osLogin: Bool?
    /// Logins this Mac already uses for the VM (from ~/.ssh/config): user and key file.
    public var sshConfigLogins: [CloudSSHLogin] = []
    public var id: String { "\(zone)/\(name)" }
    public var isRunning: Bool { status == "RUNNING" }
    public var canStart: Bool { ["STOPPED", "TERMINATED", "SUSPENDED"].contains(status) }
    public var isSuspended: Bool { status == "SUSPENDED" }
    public var statusText: String {
        switch status {
        case "RUNNING": return "Running"
        case "TERMINATED", "STOPPED": return "Stopped"
        case "SUSPENDED": return "Suspended"
        case "PROVISIONING", "STAGING": return "Starting"
        case "STOPPING": return "Stopping"
        case "SUSPENDING": return "Suspending"
        case "REPAIRING": return "Being repaired"
        default: return status.capitalized
        }
    }
    public init(instanceID: String?, name: String, zone: String, status: String, machineType: String, gpu: String?, suggestedUsers: [String],
                hostKeyAlias: String, osLogin: Bool? = nil) {
        self.instanceID = instanceID; self.name = name; self.zone = zone; self.status = status; self.machineType = machineType
        self.gpu = gpu; self.suggestedUsers = suggestedUsers; self.hostKeyAlias = hostKeyAlias; self.osLogin = osLogin
    }
}

public struct CloudSSHLogin: Equatable, Sendable {
    public var user: String; public var keyFile: String?
    public init(user: String, keyFile: String?) { self.user = user; self.keyFile = keyFile }
}

public enum CloudSignInEvent: Equatable, Sendable {
    /// Google's sign-in page, to reopen if the browser didn't appear (kept in memory only).
    case page(URL)
    /// gcloud is waiting for the verification code shown in the browser.
    case needsCode
}

public enum CloudReachability: Equatable, Sendable { case reachable, notAuthorized, backendUnreachable, failed(String) }

public enum CloudLogin: Equatable, Sendable { case ok(user: String, uid: Int), keyRefused, notAuthorized, unreachable, hostKeyChanged, failed(String) }

public struct CloudDesktop: Equatable, Sendable, Identifiable {
    public var display: Int; public var process: String
    public var id: Int { display }
    public var isWayland: Bool { process == "wayvnc" }
    public var title: String {
        switch process {
        case "wayvnc": return "Your current desktop"
        case "Xtigervnc", "Xvnc": return "Existing VNC desktop"
        case "x11vnc": return "Your current desktop (x11vnc)"
        default: return process.isEmpty ? "Existing desktop" : "Existing desktop (\(process))"
        }
    }
    public init(display: Int, process: String) { self.display = display; self.process = process }
}

public struct CloudHostReport: Equatable, Sendable {
    public var user: String
    public var osName: String
    /// apt, dnf, pacman or none.
    public var packageManager: String
    /// root, passwordless, password or none.
    public var sudo: String
    public var adminGroup: Bool
    public var systemd: Bool
    public var circeInstalled: Bool
    public var circeDisplay: Int?
    public var circeRunning: Bool
    public var desktops: [CloudDesktop]
    public var sessions: [String]
    /// One choice per port, excluding the desktop already offered as Circe's own.
    public var availableDesktops: [CloudDesktop] {
        var seen = Set<Int>()
        return desktops.filter { (0...99).contains($0.display)
            && !(circeInstalled && $0.display == circeDisplay) && seen.insert($0.display).inserted
        }.sorted { $0.display < $1.display }
    }
    /// X displays and VNC displays already in use; a new Circe desktop avoids them.
    public var usedDisplays: [Int] = []
    /// A desktop can be installed into the user's own folder without sudo.
    public var withoutAdmin = false
    public var canInstall: Bool { packageManager != "none" && systemd && sudo != "none" }
    /// The account can keep its own services running after sign-out (systemd linger) without an administrator.
    public var selfLinger = false
    /// Whether its services already do (nil: older script, unknown).
    public var lingering: Bool?
    /// The computer's own desktop (e.g. "Ubuntu"), which Circe shows instead of installing one.
    public var systemDesktop: String?
    /// Circe's desktop was set up by this version of Circe (false: an update is available).
    public var circeCurrent = true
    /// Circe's desktop is showing a session that was already open ("chrome-remote-desktop" or "rdp").
    public var circeShared: String?
    /// Circe's own display if it's set up (to repair it in place), else the first free one.
    public var setupDisplay: Int { circeDisplay ?? (1...99).first { !usedDisplays.contains($0) } ?? 1 }
    public init(user: String, osName: String, packageManager: String, sudo: String, adminGroup: Bool, systemd: Bool, circeInstalled: Bool,
                circeDisplay: Int?, circeRunning: Bool, desktops: [CloudDesktop], sessions: [String]) {
        self.user = user; self.osName = osName; self.packageManager = packageManager; self.sudo = sudo; self.adminGroup = adminGroup
        self.systemd = systemd; self.circeInstalled = circeInstalled; self.circeDisplay = circeDisplay; self.circeRunning = circeRunning
        self.desktops = desktops; self.sessions = sessions
    }
}

public struct CloudError: Error, Equatable, Sendable, LocalizedError {
    public enum Kind: Equatable, Sendable {
        case cliMissing, signInRequired, permissionDenied(String?), notFound, apiDisabled, quota, capacity, timedOut, offline, cancelled
        case wrongAccount(actual: String), signInBlocked, replaced, other
    }
    public var kind: Kind
    public var message: String
    public var errorDescription: String? { message }
    public init(_ kind: Kind, _ message: String) { self.kind = kind; self.message = message }
}

/// Setup failures keep the script's stable code (sudo_password_required, …) so the flow can respond to it.
public struct CloudSetupError: Error, Equatable, Sendable { public var code: String?; public var message: String
    public init(code: String?, message: String) { self.code = code; self.message = message } }

/// Cancels a long engine operation (sign-in in the browser, starting a VM, installing); sign-in can also take a code.
public final class CloudCancel {
    private let action: () -> Void
    private let submitter: ((String) -> Void)?
    public init(_ action: @escaping () -> Void, submit: ((String) -> Void)? = nil) { self.action = action; submitter = submit }
    public func cancel() { action() }
    public func submit(_ text: String) { submitter?(text) }
}

/// What the setup flow needs from the engine. Every completion is called on the main actor.
@MainActor
public struct CloudServices {
    public var isInstalled: () -> Bool
    public var install: (_ progress: @escaping (String) -> Void, _ completion: @escaping (Result<Void, CloudError>) -> Void) -> CloudCancel
    public var accounts: (_ completion: @escaping (Result<[CloudAccount], CloudError>) -> Void) -> Void
    public var credential: (_ account: String, _ completion: @escaping (Result<CloudCredential, CloudError>) -> Void) -> Void
    public var signIn: (_ account: String, _ useCode: Bool, _ events: @escaping (CloudSignInEvent) -> Void,
                        _ completion: @escaping (Result<String, CloudError>) -> Void) -> CloudCancel
    public var projects: (_ account: String, _ completion: @escaping (Result<[CloudProject], CloudError>) -> Void) -> Void
    public var instances: (_ account: String, _ project: String, _ completion: @escaping (Result<[CloudInstance], CloudError>) -> Void) -> Void
    public var instance: (_ account: String, _ project: String, _ zone: String, _ name: String, _ completion: @escaping (Result<CloudInstance, CloudError>) -> Void) -> Void
    public var start: (_ account: String, _ project: String, _ instance: CloudInstance, _ progress: @escaping (String) -> Void,
                       _ completion: @escaping (Result<Void, CloudError>) -> Void) -> CloudCancel
    public var checkTunnel: (_ account: String, _ project: String, _ instance: CloudInstance, _ completion: @escaping (Result<CloudReachability, CloudError>) -> Void) -> Void
    public var osLoginUser: (_ account: String, _ project: String, _ completion: @escaping (String?) -> Void) -> Void
    public var pinHostKeys: (_ account: String, _ project: String, _ instance: CloudInstance, _ completion: @escaping (_ agrees: Bool) -> Void) -> Void
    public var verifyLogin: (_ computer: SavedComputer, _ completion: @escaping (CloudLogin) -> Void) -> Void
    public var authorizeKey: (_ account: String, _ project: String, _ instance: CloudInstance, _ user: String?, _ completion: @escaping (Result<String, CloudError>) -> Void) -> Void
    public var probe: (_ computer: SavedComputer, _ completion: @escaping (Result<CloudHostReport, CloudError>) -> Void) -> CloudCancel
    public var setUp: (_ computer: SavedComputer, _ sudoPassword: String?, _ withoutAdmin: Bool, _ output: @escaping (String) -> Void,
                       _ completion: @escaping (Result<SavedComputer, CloudSetupError>) -> Void) -> CloudCancel
    public var localUserName: () -> String

    public init(isInstalled: @escaping () -> Bool,
                install: @escaping (_ progress: @escaping (String) -> Void, _ completion: @escaping (Result<Void, CloudError>) -> Void) -> CloudCancel,
                accounts: @escaping (_ completion: @escaping (Result<[CloudAccount], CloudError>) -> Void) -> Void,
                credential: @escaping (_ account: String, _ completion: @escaping (Result<CloudCredential, CloudError>) -> Void) -> Void,
                signIn: @escaping (_ account: String, _ useCode: Bool, _ events: @escaping (CloudSignInEvent) -> Void,
                                   _ completion: @escaping (Result<String, CloudError>) -> Void) -> CloudCancel,
                projects: @escaping (_ account: String, _ completion: @escaping (Result<[CloudProject], CloudError>) -> Void) -> Void,
                instances: @escaping (_ account: String, _ project: String, _ completion: @escaping (Result<[CloudInstance], CloudError>) -> Void) -> Void,
                instance: @escaping (_ account: String, _ project: String, _ zone: String, _ name: String, _ completion: @escaping (Result<CloudInstance, CloudError>) -> Void) -> Void,
                start: @escaping (_ account: String, _ project: String, _ instance: CloudInstance, _ progress: @escaping (String) -> Void,
                                  _ completion: @escaping (Result<Void, CloudError>) -> Void) -> CloudCancel,
                checkTunnel: @escaping (_ account: String, _ project: String, _ instance: CloudInstance, _ completion: @escaping (Result<CloudReachability, CloudError>) -> Void) -> Void,
                osLoginUser: @escaping (_ account: String, _ project: String, _ completion: @escaping (String?) -> Void) -> Void,
                pinHostKeys: @escaping (_ account: String, _ project: String, _ instance: CloudInstance, _ completion: @escaping (_ agrees: Bool) -> Void) -> Void,
                verifyLogin: @escaping (_ computer: SavedComputer, _ completion: @escaping (CloudLogin) -> Void) -> Void,
                authorizeKey: @escaping (_ account: String, _ project: String, _ instance: CloudInstance, _ user: String?, _ completion: @escaping (Result<String, CloudError>) -> Void) -> Void,
                probe: @escaping (_ computer: SavedComputer, _ completion: @escaping (Result<CloudHostReport, CloudError>) -> Void) -> CloudCancel,
                setUp: @escaping (_ computer: SavedComputer, _ sudoPassword: String?, _ withoutAdmin: Bool, _ output: @escaping (String) -> Void,
                                  _ completion: @escaping (Result<SavedComputer, CloudSetupError>) -> Void) -> CloudCancel,
                localUserName: @escaping () -> String) {
        self.isInstalled = isInstalled; self.install = install; self.accounts = accounts; self.credential = credential; self.signIn = signIn
        self.projects = projects; self.instances = instances; self.instance = instance; self.start = start; self.checkTunnel = checkTunnel
        self.osLoginUser = osLoginUser; self.pinHostKeys = pinHostKeys; self.verifyLogin = verifyLogin; self.authorizeKey = authorizeKey
        self.probe = probe; self.setUp = setUp; self.localUserName = localUserName
    }
}

@MainActor
public final class GoogleCloudSetup: ObservableObject {
    public enum Step: Int, Comparable, CaseIterable, Sendable {
        case account, project, computer, power, access, desktop, install, finished
        public static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }
    public enum Status: Equatable { case idle, working(String), failed(String) }
    public enum AccountState: Equatable {
        case unknown, checking, needsTools, installingTools(String), signedIn, needsSignIn(expired: Bool)
        case signingIn(page: URL?, needsCode: Bool)
        case wrongAccount(actual: String), failed(String)
    }
    public enum CheckState: Equatable { case pending, running, ok(String), failed(String) }
    public struct Check: Identifiable, Equatable {
        public enum ID: String, CaseIterable { case google, network, linux, desktop }
        public var id: ID; public var title: String; public var state: CheckState = .pending
    }
    public enum DesktopChoice: Equatable { case existing(CloudDesktop), circe(display: Int), install }
    /// Who to show "Copy request for your administrator" to and what it says.
    public enum AdminRequest: Equatable { case tunnel, firewall, start, linuxUser, sudo, updates }

    @Published public private(set) var step: Step = .account
    /// Choosing another account drops whatever was found or pending for the previous one.
    @Published public var email: String { didSet { if email != oldValue { accountChanged() } } }
    @Published public private(set) var knownAccounts: [CloudAccount] = []
    @Published public private(set) var accountState: AccountState = .unknown
    @Published public private(set) var projects: [CloudProject] = []
    @Published public private(set) var projectsStatus: Status = .idle
    @Published public var projectQuery = ""
    @Published public var manualProject = ""
    @Published public private(set) var project: String?
    @Published public private(set) var instances: [CloudInstance] = []
    @Published public private(set) var instancesStatus: Status = .idle
    @Published public var instanceQuery = ""
    @Published public var manualInstance = ""
    @Published public var manualZone = ""
    @Published public private(set) var instance: CloudInstance?
    @Published public private(set) var powerStatus: Status = .idle
    @Published public var startsWhenConnecting = false
    @Published public private(set) var checks: [Check] = GoogleCloudSetup.freshChecks()
    @Published public private(set) var needsKeyConsent = false
    @Published public var manualLinuxUser = ""
    @Published public private(set) var linuxUser: String?
    @Published public private(set) var linuxKeyFile: String?
    @Published public var signInCode = ""
    @Published public private(set) var report: CloudHostReport?
    @Published public var desktopChoice: DesktopChoice? {
        // A computer that can't get a desktop from here: the exact request for its administrator, right away.
        didSet { if desktopChoice == .install, installBlocker != nil { adminRequest = .sudo } else if adminRequest == .sudo { adminRequest = nil } }
    }
    @Published public var sudoPassword = ""
    @Published public private(set) var needsSudoPassword = false
    /// Install into the user's own folder instead of system-wide (no sudo, no password).
    @Published public var installWithoutAdmin = false
    @Published public private(set) var installStatus: Status = .idle
    @Published public private(set) var installOutput = ""
    @Published public private(set) var adminRequest: AdminRequest?
    @Published public private(set) var computer: SavedComputer?

    let services: CloudServices
    private let model: CirceModel?
    private var running: CloudCancel?
    /// Multiplies retry waits (tests make them instant).
    var delayScale = 1.0
    /// Bumped when the user goes back or changes account/project/VM, so late results are ignored.
    private var generation = 0
    /// The account the project/computer lists were loaded for.
    private var listsAccount: String?
    private var forgotReplaced = false

    /// The setup always starts on the account step with the suggested (or gcloud's active) account chosen,
    /// and waits there: the person picks the account and presses Continue.
    public init(services: CloudServices, model: CirceModel? = nil, suggestedEmail: String? = nil) {
        self.services = services; self.model = model
        email = suggestedEmail ?? ""
        services.accounts { [weak self] result in
            guard let self, case let .success(accounts) = result else { return }
            self.knownAccounts = accounts
            if self.email.isEmpty, let active = accounts.first(where: \.isActive) ?? accounts.first { self.email = active.email }
        }
    }

    private func accountChanged() {
        guard step == .account else { return }
        switch accountState {
        case .installingTools: return
        case .signingIn: cancelRunning()
        default: break
        }
        generation += 1
        accountState = .unknown
    }

    /// The account signed in on this Mac that matches the email, if any.
    public func knownAccount(_ email: String) -> CloudAccount? {
        let wanted = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return knownAccounts.first { $0.email.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    static func freshChecks() -> [Check] {
        [Check(id: .google, title: "Google Cloud access"), Check(id: .network, title: "Private connection"),
         Check(id: .linux, title: "Linux sign-in"), Check(id: .desktop, title: "Desktop")]
    }

    public var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var emailIsValid: Bool {
        trimmedEmail.count <= 254 && trimmedEmail.range(of: "^[A-Za-z0-9][A-Za-z0-9._%+-]*@[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\\.[A-Za-z]{2,}$", options: .regularExpression) != nil
    }

    // MARK: Navigation

    public func back() {
        cancelRunning(); generation += 1
        sudoPassword = ""; signInCode = ""; needsSudoPassword = false; installStatus = .idle
        switch step {
        case .account, .finished: break
        case .project: step = .account
        case .computer: step = .project
        case .power, .access: step = .computer
        case .desktop: step = .computer
        case .install: step = .desktop
        }
        adminRequest = nil
    }

    public func cancelRunning() { running?.cancel(); running = nil }

    // MARK: Account

    /// `signInIfNeeded`: the person pressed Continue, so an account that isn't signed in goes straight to Google.
    public func continueWithAccount(signInIfNeeded: Bool = false) {
        guard emailIsValid else { accountState = .failed("Enter the Google email address that has access to your computer."); return }
        guard services.isInstalled() else { accountState = .needsTools; return }
        let account = trimmedEmail, token = bump()
        if listsAccount?.caseInsensitiveCompare(account) != .orderedSame {
            // Another account sees other projects and computers: nothing from the previous one carries over.
            projects = []; projectsStatus = .idle; project = nil; projectQuery = ""
            instances = []; instancesStatus = .idle; instance = nil; instanceQuery = ""
            sudoPassword = ""; report = nil; linuxUser = nil; linuxKeyFile = nil; manualLinuxUser = ""
            listsAccount = account
        }
        accountState = .checking
        services.credential(account) { [weak self] result in
            guard let self, self.current(token) else { return }
            switch result {
            case .success(.valid): self.accountState = .signedIn; self.showProjects()
            case .success(.expired): self.accountState = .needsSignIn(expired: true); if signInIfNeeded { self.signIn() }
            case .success(.notSignedIn): self.accountState = .needsSignIn(expired: false); if signInIfNeeded { self.signIn() }
            case .failure(let error): self.accountState = error.kind == .cliMissing ? .needsTools : .failed(error.message)
            }
        }
    }

    public func installTools() {
        accountState = .installingTools("Preparing…")
        running = services.install({ [weak self] line in self?.accountState = .installingTools(line) }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success: self.continueWithAccount()
            case .failure(let error): self.accountState = .failed(error.message)
            }
        }
    }

    public func signIn(useCode: Bool = false) {
        cancelRunning()
        let account = trimmedEmail, token = bump()
        accountState = .signingIn(page: nil, needsCode: false); signInCode = ""
        running = services.signIn(account, useCode, { [weak self] event in
            guard let self, self.current(token), case let .signingIn(page, needsCode) = self.accountState else { return }
            switch event {
            case .page(let url): self.accountState = .signingIn(page: url, needsCode: needsCode)
            case .needsCode: self.accountState = .signingIn(page: page, needsCode: true)
            }
        }) { [weak self] result in
            guard let self, self.current(token) else { return }
            switch result {
            case .success(let actual) where actual.caseInsensitiveCompare(account) != .orderedSame:
                self.accountState = .wrongAccount(actual: actual)
            case .success: self.continueWithAccount()
            case .failure(let error):
                if case let .wrongAccount(actual) = error.kind { self.accountState = .wrongAccount(actual: actual) }
                else if error.kind == .cancelled { self.accountState = .needsSignIn(expired: false) }
                else { self.accountState = .failed(error.message) }
            }
        }
    }

    /// The verification code from Google's page (only when gcloud asked for one). Never stored.
    public func submitSignInCode() {
        let code = signInCode.trimmingCharacters(in: .whitespacesAndNewlines)
        signInCode = ""
        guard !code.isEmpty, !code.contains(where: \.isNewline) else { return }
        running?.submit(code)
    }

    /// After signing in with a different account than typed: use that one instead.
    public func useSignedInAccount(_ actual: String) { email = actual; continueWithAccount() }

    // MARK: Project

    private func showProjects() {
        step = .project
        guard projects.isEmpty || projectsStatus != .idle else { return }
        loadProjects()
    }

    public func loadProjects() {
        let account = trimmedEmail, token = bump()
        projectsStatus = .working("Finding your projects…")
        services.projects(account) { [weak self] result in
            guard let self, self.current(token) else { return }
            switch result {
            case .success(let found):
                self.projects = found
                self.projectsStatus = found.isEmpty ? .failed("Google didn’t return any projects for \(account). If you know your project’s ID, enter it below.") : .idle
            case .failure(let error):
                self.projects = []
                self.projectsStatus = .failed(error.kind == .signInRequired ? "Google needs you to sign in again." :
                    "This account can’t browse projects (\(error.message)) You can still enter a project ID.")
            }
        }
    }

    public var filteredProjects: [CloudProject] {
        let q = projectQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return projects }
        return projects.filter { $0.id.lowercased().contains(q) || $0.name.lowercased().contains(q) }
    }

    public func choose(project id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: "^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}$", options: .regularExpression) != nil else {
            projectsStatus = .failed("Enter the project ID (such as my-project-123), not its display name."); return
        }
        project = trimmed; instances = []; instance = nil; sudoPassword = ""
        step = .computer
        loadInstances()
    }

    // MARK: Computer

    public func loadInstances() {
        guard let project else { return }
        let account = trimmedEmail, token = bump()
        instancesStatus = .working("Looking for computers in \(project)…")
        services.instances(account, project) { [weak self] result in
            guard let self, self.current(token) else { return }
            switch result {
            case .success(let found):
                self.instances = self.ranked(found)
                self.instancesStatus = found.isEmpty ? .failed("No computers were found in this project. If yours is in another project, go back and choose it.") : .idle
            case .failure(let error):
                self.instances = []
                switch error.kind {
                case .permissionDenied: self.instancesStatus = .failed("This account can’t list computers here. Enter your computer’s name and zone below.")
                case .apiDisabled: self.instancesStatus = .failed("Google Cloud computers aren’t enabled for this project. Check the project ID.")
                default: self.instancesStatus = .failed(error.message)
                }
            }
        }
    }

    /// Computers whose name contains part of the user's email (cloud-developer-workstation for developer@example.org)
    /// come first, then running ones, then by name.
    func ranked(_ list: [CloudInstance]) -> [CloudInstance] {
        let local = trimmedEmail.split(separator: "@").first.map(String.init)?.lowercased() ?? ""
        let tokens = local.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 }
        func score(_ i: CloudInstance) -> Int { tokens.filter { i.name.lowercased().contains($0) }.count }
        return list.sorted { a, b in
            if score(a) != score(b) { return score(a) > score(b) }
            if a.isRunning != b.isRunning { return a.isRunning }
            return a.name < b.name
        }
    }

    public var filteredInstances: [CloudInstance] {
        let q = instanceQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return instances }
        return instances.filter { $0.name.lowercased().contains(q) || $0.zone.contains(q) }
    }

    public func chooseManualInstance() {
        let name = manualInstance.trimmingCharacters(in: .whitespacesAndNewlines), zone = manualZone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.range(of: "^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$", options: .regularExpression) != nil else { instancesStatus = .failed("Enter the computer’s name exactly as Google Cloud shows it."); return }
        guard zone.range(of: "^[a-z][a-z0-9]*(-[a-z0-9]+)+$", options: .regularExpression) != nil else { instancesStatus = .failed("Enter the computer’s zone, such as us-central1-a."); return }
        guard let project else { return }
        let account = trimmedEmail, token = bump()
        instancesStatus = .working("Finding \(name)…")
        services.instance(account, project, zone, name) { [weak self] result in
            guard let self, self.current(token) else { return }
            switch result {
            case .success(let found): self.instancesStatus = .idle; self.choose(found)
            case .failure(let error) where { if case .permissionDenied = error.kind { return true }; return false }():
                // Some accounts may use a VM through IAP without reading its details. Try the connection anyway.
                self.instancesStatus = .idle
                self.choose(CloudInstance(instanceID: nil, name: name, zone: zone, status: "RUNNING", machineType: "", gpu: nil, suggestedUsers: [],
                                          hostKeyAlias: "circe-gce-\(project)-\(zone)-\(name)"))
            case .failure(let error): self.instancesStatus = .failed(error.kind == .notFound ? "Circe couldn’t find \(name) in \(zone). Check the name and zone." : error.message)
            }
        }
    }

    public func choose(_ chosen: CloudInstance) {
        cancelRunning()
        instance = chosen; adminRequest = nil
        checks = Self.freshChecks(); needsKeyConsent = false; linuxUser = nil; linuxKeyFile = nil; report = nil; desktopChoice = nil
        manualLinuxUser = "" // a user typed for another computer must not hide this one's own sign-in
        sudoPassword = ""; needsSudoPassword = false; installStatus = .idle
        // Approval to start belongs to one machine: kept only when this is the machine it was given for.
        startsWhenConnecting = savedSameMachine(chosen)?.startsWhenConnecting ?? false
        if chosen.isRunning { step = .access; runChecks() }
        else {
            step = .power
            if chosen.canStart { powerStatus = .idle }
            else { powerStatus = .working(Self.describe(power: chosen.status, name: chosen.name)); watchUntilSettled(token: bump(), polls: 0) }
        }
    }

    /// A VM that's stopping, starting or being repaired: watch it (read-only) until it settles. If it ends up
    /// stopped, the user decides whether to start it — Circe never starts a computer on its own here.
    private func watchUntilSettled(token: Int, polls: Int) {
        guard current(token), let instance, let project else { return }
        guard polls < 90 else { powerStatus = .failed("\(instance.name) is taking unusually long to change state. Check it in Google Cloud."); return }
        after(4) { flow in
            guard flow.current(token) else { return }
            flow.services.instance(flow.trimmedEmail, project, instance.zone, instance.name) { [weak flow] result in
                guard let flow, flow.current(token) else { return }
                switch result {
                case .success(let latest) where latest.isRunning:
                    flow.instance = latest; flow.powerStatus = .idle; flow.step = .access; flow.runChecks(justStarted: true)
                case .success(let latest) where latest.canStart:
                    flow.instance = latest; flow.powerStatus = .idle
                case .success(let latest):
                    flow.instance = latest; flow.powerStatus = .working(Self.describe(power: latest.status, name: latest.name))
                    flow.watchUntilSettled(token: token, polls: polls + 1)
                case .failure(let error): flow.powerStatus = .failed(error.message)
                }
            }
        }
    }

    // MARK: Power

    public var startWarning: String {
        guard let instance else { return "" }
        let charges = "Starting it begins Google Cloud charges, which continue until it’s stopped — closing Circe doesn’t stop it."
        if let gpu = instance.gpu { return "This computer has an \(gpu) GPU. \(charges) Starting can fail if Google has no GPUs free in \(instance.zone) right now." }
        return charges
    }

    public func startComputer() {
        guard let instance, let project else { return }
        let account = trimmedEmail, token = bump()
        powerStatus = .working(instance.isSuspended ? "Resuming \(instance.name)…" : "Starting \(instance.name)…")
        running = services.start(account, project, instance, { [weak self] state in
            guard let self, self.current(token) else { return }
            self.powerStatus = .working(Self.describe(power: state, name: instance.name))
        }) { [weak self] result in
            guard let self, self.current(token) else { return }
            switch result {
            case .success:
                var started = instance; started.status = "RUNNING"
                self.instance = started; self.powerStatus = .idle
                self.step = .access; self.runChecks(justStarted: true)
            case .failure(let error):
                switch error.kind {
                case .permissionDenied: self.powerStatus = .failed("\(account) can use this computer but isn’t allowed to start it."); self.adminRequest = .start
                case .capacity: self.powerStatus = .failed("Google Cloud doesn’t have enough capacity in \(instance.zone) to start this computer right now. Try again in a few minutes.")
                case .quota: self.powerStatus = .failed("A Google Cloud limit for this project is stopping the computer from starting. \(error.message)"); self.adminRequest = .start
                case .cancelled: self.powerStatus = .failed("Circe stopped waiting. Google Cloud may still finish starting the computer, and charges apply once it runs.")
                default: self.powerStatus = .failed(error.message)
                }
            }
        }
    }

    static func describe(power state: String, name: String) -> String {
        switch state {
        case "STOPPING", "SUSPENDING": return "Waiting for \(name) to finish shutting down…"
        case "STARTING", "PROVISIONING": return "Asking Google Cloud to start \(name)…"
        case "STAGING": return "Google Cloud is preparing \(name)…"
        case "RESUMING": return "Resuming \(name)…"
        case "REPAIRING": return "Google Cloud is repairing \(name)…"
        default: return "Starting \(name)…"
        }
    }

    // MARK: Access checks

    private func set(_ id: Check.ID, _ state: CheckState) {
        if let index = checks.firstIndex(where: { $0.id == id }) { checks[index].state = state }
    }

    /// Google access → private connection → Linux sign-in → desktop, each read-only.
    public func runChecks(justStarted: Bool = false) {
        guard let instance, let project else { return }
        let account = trimmedEmail, token = bump()
        checks = Self.freshChecks(); needsKeyConsent = false; adminRequest = nil
        set(.google, .ok(instance.instanceID == nil ? "Signed in as \(account)" : "\(account) can use \(instance.name)"))
        set(.network, .running)
        services.pinHostKeys(account, project, instance) { [weak self] agrees in
            guard let self, self.current(token) else { return }
            guard agrees else {
                self.set(.network, .failed("This computer’s security key doesn’t match the one Circe recorded for it. If it was rebuilt, confirm with whoever manages it before connecting."))
                return
            }
            self.checkTunnel(account: account, project: project, instance: instance, attemptsLeft: justStarted ? 12 : 2, token: token)
        }
    }

    private func checkTunnel(account: String, project: String, instance: CloudInstance, attemptsLeft: Int, token: Int) {
        guard current(token) else { return }
        services.checkTunnel(account, project, instance) { [weak self] result in
            guard let self, self.current(token) else { return }
            switch result {
            case .success(.reachable):
                self.set(.network, .ok("Connected through Google’s private connection"))
                self.findLinuxUser(token: token)
            case .success(.backendUnreachable) where attemptsLeft > 0:
                // A VM that just started needs a little while before SSH answers.
                self.after(5) { $0.checkTunnel(account: account, project: project, instance: instance, attemptsLeft: attemptsLeft - 1, token: token) }
            case .success(.backendUnreachable):
                self.set(.network, .failed("Google’s private connection couldn’t reach SSH on this computer. Its network may not allow Google’s connection (35.235.240.0/20, port 22), or SSH isn’t running."))
                self.adminRequest = .firewall
            case .success(.notAuthorized):
                self.set(.network, .failed("Google’s private connection refused \(account). The account may need the “IAP-secured Tunnel User” role for this computer."))
                self.adminRequest = .tunnel
            case .success(.failed(let message)): self.set(.network, .failed(message))
            case .failure(let error): self.set(.network, .failed(error.message))
            }
        }
    }

    /// Runs `work` on the main actor after `seconds`, unless the flow has moved on.
    private func after(_ seconds: Double, _ work: @escaping @MainActor (GoogleCloudSetup) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds * delayScale) { [weak self] in
            MainActor.assumeIsolated { if let self { work(self) } }
        }
    }

    /// Candidates from evidence, best first: OS Login's name, the VM's metadata hints, gcloud's default
    /// (this Mac's user name). At most three, each verified by actually signing in.
    private func findLinuxUser(token: Int) {
        guard let instance, let project else { return }
        let account = trimmedEmail
        set(.linux, .running)
        services.osLoginUser(account, project) { [weak self] osLogin in
            guard let self, self.current(token) else { return }
            var candidates: [CloudSSHLogin] = []
            func add(_ login: CloudSSHLogin) { if !login.user.isEmpty, !candidates.contains(login) { candidates.append(login) } }
            let typed = self.manualLinuxUser.trimmingCharacters(in: .whitespaces)
            if !typed.isEmpty { add(CloudSSHLogin(user: typed, keyFile: nil)); instance.sshConfigLogins.filter { $0.user == typed }.forEach(add) }
            else {
                // Evidence first: how this Mac already signs in, Google's OS Login name, the VM's own hints.
                instance.sshConfigLogins.prefix(2).forEach(add)
                [osLogin].compactMap { $0 }.map { CloudSSHLogin(user: $0, keyFile: nil) }.forEach(add)
                instance.suggestedUsers.map { CloudSSHLogin(user: $0, keyFile: nil) }.forEach(add)
                add(CloudSSHLogin(user: self.services.localUserName(), keyFile: nil))
            }
            self.tryUsers(Array(candidates.prefix(typed.isEmpty ? 4 : 2)), token: token)
        }
    }

    private func tryUsers(_ candidates: [CloudSSHLogin], token: Int) {
        guard let login = candidates.first else {
            set(.linux, .failed("This computer didn’t accept this Mac’s sign-in key."))
            needsKeyConsent = true
            return
        }
        services.verifyLogin(draftComputer(user: login.user, keyFile: login.keyFile, display: 1)) { [weak self] result in
            guard let self, self.current(token) else { return }
            switch result {
            case let .ok(actual, uid):
                guard uid != 0 else { self.set(.linux, .failed("This connection signs in as root. Enter the Linux account that owns the desktop.")); self.needsKeyConsent = true; return }
                self.linuxUser = actual; self.linuxKeyFile = login.keyFile
                self.set(.linux, .ok("Signed in as \(actual)"))
                self.probeDesktop(token: token)
            case .keyRefused: self.tryUsers(Array(candidates.dropFirst()), token: token)
            case .hostKeyChanged:
                self.set(.linux, .failed("This computer’s security key doesn’t match the one Circe saw before. If it was rebuilt, confirm with whoever manages it."))
            case .notAuthorized: self.set(.linux, .failed("Google’s private connection refused this account.")); self.adminRequest = .tunnel
            case .unreachable: self.set(.linux, .failed("The computer stopped answering. Check that it’s running, then try again."))
            case .failed(let message): self.set(.linux, .failed(message))
            }
        }
    }

    /// The one cloud change in setup, after the user agrees: gcloud adds this Mac's public key to the
    /// account's OS Login profile or the VM's SSH keys. Then Circe re-verifies with backoff.
    public func authorizeKey() {
        guard let instance, let project else { return }
        let account = trimmedEmail, token = bump()
        let typed = manualLinuxUser.trimmingCharacters(in: .whitespaces)
        needsKeyConsent = false
        set(.linux, .running)
        services.authorizeKey(account, project, instance, typed.isEmpty ? (instance.suggestedUsers.first) : typed) { [weak self] result in
            guard let self, self.current(token) else { return }
            switch result {
            case .success(let user): self.verifyAuthorizedKey(user: user, delay: 1, token: token)
            case .failure(let error):
                self.set(.linux, .failed(error.message)); self.needsKeyConsent = true
                if case .permissionDenied = error.kind { self.adminRequest = .linuxUser }
            }
        }
    }

    /// Google's key changes take a little while to reach the VM: retry at 1, 2, 4, 8, 16 seconds.
    private func verifyAuthorizedKey(user: String, delay: Double, token: Int) {
        guard current(token) else { return }
        services.verifyLogin(draftComputer(user: user, display: 1)) { [weak self] login in
            guard let self, self.current(token) else { return }
            if case let .ok(actual, uid) = login, uid != 0 {
                self.linuxUser = actual; self.set(.linux, .ok("Signed in as \(actual)")); self.probeDesktop(token: token)
            } else if delay < 32 {
                self.after(delay) { $0.current(token) ? $0.verifyAuthorizedKey(user: user, delay: delay * 2, token: token) : () }
            } else {
                self.set(.linux, .failed("Google added the key, but the computer hasn’t accepted it yet. Try again in a minute."))
                self.needsKeyConsent = true
            }
        }
    }

    /// Retry the Linux sign-in after the user typed a user name.
    public func retryLinuxUser() { guard current(generation) else { return }; let token = bump(); needsKeyConsent = false; findLinuxUser(token: token) }

    private func probeDesktop(token: Int) {
        guard let user = linuxUser else { return }
        set(.desktop, .running)
        running = services.probe(draftComputer(user: user, keyFile: linuxKeyFile, display: 1)) { [weak self] result in
            guard let self, self.current(token) else { return }
            switch result {
            case .success(let report):
                self.report = report
                self.needsSudoPassword = report.sudo == "password"
                // No password needed is the easier path for most people (OS Login accounts often have no Linux
                // password at all), so prefer it whenever sudo isn't freely available.
                self.installWithoutAdmin = report.withoutAdmin && !["passwordless", "root"].contains(report.sudo)
                if report.circeInstalled, report.circeRunning, !report.circeCurrent, report.canInstall || report.withoutAdmin {
                    // Set up by an older Circe: update it in place (same password and settings), e.g. to show
                    // the computer's own desktop rather than Circe's light one.
                    self.desktopChoice = .install
                    self.set(.desktop, .ok("An update for Circe’s desktop is ready"))
                } else if report.circeInstalled, report.circeRunning, let display = report.circeDisplay {
                    self.desktopChoice = .circe(display: display)
                    self.set(.desktop, .ok("Circe’s desktop is ready"))
                } else if report.circeInstalled {
                    // Set up before but not running (interrupted setup, stopped service): repair, don't pretend.
                    self.desktopChoice = report.availableDesktops.first.map { .existing($0) } ?? .install
                    self.set(.desktop, .ok("Circe’s desktop needs repair"))
                } else if let existing = report.availableDesktops.first {
                    self.desktopChoice = .existing(existing)
                    self.set(.desktop, .ok("\(existing.title) is ready"))
                } else {
                    self.desktopChoice = .install
                    self.set(.desktop, .ok(report.canInstall ? "Ready to set up a desktop" : "Needs a desktop"))
                }
                self.step = .desktop
            case .failure(let error): self.set(.desktop, .failed(error.message))
            }
        }
    }

    // MARK: Desktop and setup

    public var installPlan: [String] {
        guard let report else { return [] }
        // The same desktop and apps as the computer's own login screen, RDP or Chrome Remote Desktop.
        let own = report.systemDesktop.map { "This computer’s own \($0) desktop, with all its apps" }
        let repair = report.circeRunning ? "Updates Circe’s desktop, keeping its password and settings" : "Repairs Circe’s desktop and starts it again"
        if installWithoutAdmin {
            var lines = [own ?? "A private desktop in \(report.user)’s account, with your apps, Terminal and Files",
                         "No administrator password — nothing changes for anyone else on this computer",
                         "Only reachable through Circe’s encrypted connection"]
            if report.circeInstalled { lines.insert(repair, at: 0) }
            return lines
        }
        var lines = [report.circeInstalled ? repair : (own ?? "A private desktop for \(report.user)"),
                     "Only reachable through Circe’s encrypted connection",
                     "Starts automatically when the computer starts"]
        let software = report.systemDesktop == nil ? "XFCE and TigerVNC" : "TigerVNC"
        switch report.packageManager {
        case "apt": lines.insert("Installs \(software) with apt", at: 1)
        case "dnf": lines.insert("Installs \(software) with dnf", at: 1)
        case "pacman": lines.insert("Installs \(software) with pacman (no system upgrade)", at: 1)
        default: break
        }
        if report.circeInstalled, let own { lines.insert(own, at: 1) }
        if !report.sessions.isEmpty { lines.append("Leaves everything already on the computer as it is") }
        return lines
    }

    public var installBlocker: String? {
        guard let report else { return nil }
        let software = report.systemDesktop == nil ? "TigerVNC and XFCE" : "TigerVNC"
        if installWithoutAdmin { return report.withoutAdmin ? nil : "This computer can’t get a desktop without administrator access. Ask whoever manages it to install \(software)." }
        if report.sudo == "none" && !report.withoutAdmin { return "\(report.user) can’t install software on this computer, and it can’t get a desktop without administrator access either. Ask whoever manages it to install \(software)." }
        if report.packageManager == "none" { return "Circe can set up desktops on Ubuntu, Debian, Fedora, RHEL and Arch. \(report.osName.isEmpty ? "This computer" : report.osName) needs its desktop set up by whoever manages it." }
        if !report.systemd { return "This computer doesn’t use systemd, so Circe can’t keep a desktop running on it." }
        return nil
    }

    /// Use the chosen desktop as is (existing or already-installed Circe desktop), or install one.
    public func continueWithDesktop() {
        guard let choice = desktopChoice, let user = linuxUser else { return }
        // The saved computer of this name now leads to a different machine: its old VNC password must never be
        // offered to the new one. Forgotten before setup, which may save the new machine's password.
        if let old = savedEntry(), savedSameMachine(instance) == nil, !forgotReplaced { forgotReplaced = true; model?.computerReplaced(old) }
        switch choice {
        case let .existing(desktop):
            var computer = draftComputer(user: user, keyFile: linuxKeyFile, display: desktop.display, video: !desktop.isWayland)
            // Wayland desktops such as Hyprland need Super for their main shortcuts. Physical Control
            // still sends Control for Linux app shortcuts when Command sends Super. A desktop the person
            // already set up keeps their own choice.
            if savedSameMachine(instance)?.display != desktop.display { computer.commandActsAsControl = !desktop.isWayland }
            finish(computer)
        case let .circe(display):
            var computer = draftComputer(user: user, keyFile: linuxKeyFile, display: display)
            // Showing a Chrome Remote Desktop session: ⌘ arrives as Super there, as that session expects. A
            // computer already saved keeps the person's own choice.
            if report?.circeShared == "chrome-remote-desktop", savedSameMachine(instance) == nil { computer.commandActsAsControl = false }
            // Already set up: whether it keeps running on its own is the account's actual linger state.
            if let lingering = report?.lingering { computer.startsDesktopOnConnect = !lingering }
            finish(computer)
        case .install:
            if installBlocker != nil { adminRequest = .sudo; return }
            if needsSudoPassword && !installWithoutAdmin && sudoPassword.isEmpty { installStatus = .failed("Enter \(user)’s Linux password so Circe can install software. This isn’t your Google password."); return }
            install()
        }
    }

    private func install() {
        guard let user = linuxUser else { return }
        let token = bump()
        step = .install; installOutput = ""
        installStatus = .working("Setting up the desktop… This can take a few minutes.")
        let withoutAdmin = installWithoutAdmin
        let password = needsSudoPassword && !withoutAdmin ? sudoPassword : nil
        sudoPassword = ""
        running = services.setUp(draftComputer(user: user, keyFile: linuxKeyFile, display: report?.setupDisplay ?? 1), password, withoutAdmin, { [weak self] line in
            guard let self, self.current(token) else { return }
            self.installOutput = String((self.installOutput + line + "\n").suffix(12_000))
        }) { [weak self] result in
            guard let self, self.current(token) else { return }
            switch result {
            case .success(let computer): self.installStatus = .idle; self.finish(computer)
            case .failure(let error):
                self.step = .desktop
                switch error.code {
                case "sudo_password_required": self.needsSudoPassword = true; self.installStatus = .failed("This computer needs \(user)’s Linux password to install software.")
                case "sudo_password_incorrect": self.needsSudoPassword = true; self.installStatus = .failed("That Linux password wasn’t accepted. Try again.")
                case "sudo_not_allowed" where self.report?.withoutAdmin == true && !withoutAdmin:
                    // Nothing was changed; carry straight on with the private install instead of asking again.
                    self.installWithoutAdmin = true
                    self.install()
                    self.installStatus = .working("\(user) can’t install software system-wide, so Circe is setting up the desktop in \(user)’s own folder instead…")
                case "sudo_not_allowed": self.installStatus = .failed("\(user) isn’t allowed to install software on this computer."); self.adminRequest = .sudo
                case "without_admin_unsupported": self.installStatus = .failed(error.message); self.adminRequest = .sudo
                case "system_outdated": self.installStatus = .failed(error.message); self.adminRequest = .updates
                default: self.installStatus = .failed(error.message)
                }
            }
        }
    }

    private func finish(_ computer: SavedComputer) {
        var saved = computer
        saved.startsWhenConnecting = startsWhenConnecting
        do { try model?.saveComputer(saved) } catch { installStatus = .failed(error.localizedDescription); return }
        self.computer = saved
        step = .finished
    }

    /// The saved computer for this project/zone/name, whichever machine it was set up for.
    private func savedEntry() -> SavedComputer? {
        guard let instance else { return nil }
        return model?.computers.first { if case let .googleCloud(i, z, p, _, _, _, _, _) = $0.connection { return i == instance.name && z == instance.zone && p == project }; return false }
    }

    /// That saved computer, only if it was set up for this very machine (same host identity).
    func savedSameMachine(_ instance: CloudInstance?) -> SavedComputer? {
        guard let instance, let existing = savedEntry(), case let .googleCloud(_, _, _, _, _, _, alias, _) = existing.connection,
              alias == instance.hostKeyAlias else { return nil }
        return existing
    }

    func draftComputer(user: String, keyFile: String? = nil, display: Int, video: Bool = true) -> SavedComputer {
        let instance = self.instance!
        let connection = ComputerConnection.googleCloud(instance: instance.name, zone: instance.zone, project: project, useIAP: true,
                                                        account: trimmedEmail, user: user, hostKeyAlias: instance.hostKeyAlias, keyFile: keyFile)
        // Setting up the same machine again keeps the person's own choices for it (name, keyboard, sound, video,
        // microphone, desktop lifetime); only the route and desktop are refreshed. A replaced machine starts fresh.
        if var same = savedSameMachine(instance) {
            same.connection = connection
            if same.display != display { same.display = display; same.videoEnabled = video }
            same.startsWhenConnecting = startsWhenConnecting
            return same
        }
        return SavedComputer(id: savedEntry()?.id ?? UUID(), name: savedEntry()?.name ?? instance.name, connection: connection,
                             display: display, videoEnabled: video, startsWhenConnecting: startsWhenConnecting)
    }

    // MARK: Administrator handoff

    /// A precise request to paste into an email or chat to whoever manages the Google Cloud project.
    public var adminRequestText: String {
        guard let instance, let project else { return "" }
        let who = trimmedEmail
        let target = "computer \(instance.name) (project \(project), zone \(instance.zone))"
        switch adminRequest {
        case .tunnel?: return "Hi — could you give \(who) the “IAP-secured Tunnel User” role (roles/iap.tunnelResourceAccessor) for the \(target)? I connect to it with Circe through Google’s Identity-Aware Proxy on port 22."
        case .firewall?: return "Hi — the \(target) doesn’t accept Google’s Identity-Aware Proxy. Could you allow ingress TCP port 22 from 35.235.240.0/20 to it, and check that SSH is running? It doesn’t need a public IP."
        case .start?: return "Hi — could you allow \(who) to start and stop the \(target) (compute.instances.start / stop / resume), or start it for me?"
        case .linuxUser?: return "Hi — could you allow \(who) to sign in to Linux on the \(target)? For OS Login that’s roles/compute.osLogin; otherwise, which Linux user and SSH key should I use?"
        case .sudo?:
            let user = report?.user.isEmpty == false ? report!.user : "my Linux account"
            return "Hi — could you install a desktop on the \(target) so I can use it with Circe? As an administrator:\n\n"
                + Self.desktopInstallCommand(report?.packageManager, systemDesktop: report?.systemDesktop != nil)
                + "\nsudo loginctl enable-linger \(user)\n\nCirce sets up the rest in \(user)’s own folder. The desktop listens only on localhost and is reached through Google’s private tunnel, so no firewall change is needed."
        case .updates?:
            let command: String
            switch report?.packageManager {
            case "apt": command = "sudo apt-get update && sudo apt-get upgrade"
            case "dnf": command = "sudo dnf upgrade"
            case "pacman": command = "sudo pacman -Syu"
            default: command = "the distribution’s usual system update"
            }
            return "Hi — could you install the latest system updates on the \(target)? (\(command)) Circe needs a current C library to set up my desktop; it installs everything else in my own account."
        case nil: return ""
        }
    }

    /// What an administrator runs so Circe can finish setup without one (matches setup-circe-host.sh's checks).
    static func desktopInstallCommand(_ packageManager: String?, systemDesktop: Bool = false) -> String {
        // The computer's own desktop stays; Circe only needs its VNC server and helpers.
        if systemDesktop {
            switch packageManager {
            case "apt": return "sudo apt-get install -y --no-install-recommends tigervnc-standalone-server tigervnc-common xauth x11-utils pulseaudio-utils openssl\n(on Ubuntu 22.04+/Debian 12+ also: tigervnc-tools)"
            case "dnf": return "sudo dnf install -y tigervnc-server xorg-x11-xauth xdpyinfo pulseaudio-utils openssl"
            case "pacman": return "sudo pacman -S --needed tigervnc xorg-xauth xorg-xdpyinfo xorg-xset libpulse openssl"
            default: return "Install TigerVNC (the Xvnc server and vncpasswd) from the distribution’s packages."
            }
        }
        switch packageManager {
        case "apt": return "sudo apt-get install -y --no-install-recommends xfce4 xfce4-terminal tigervnc-standalone-server tigervnc-common dbus-x11 xauth x11-utils pulseaudio-utils openssl\n(on Ubuntu 22.04+/Debian 12+ also: tigervnc-tools; for sound, pulseaudio unless PipeWire is installed)"
        case "dnf": return "sudo dnf install -y tigervnc-server xfce4-session xfce4-panel xfce4-settings xfce4-terminal xfdesktop xfwm4 Thunar dbus-x11 xorg-x11-xauth xdpyinfo pulseaudio-utils openssl\n(RHEL/Rocky/Alma need EPEL first: sudo dnf install -y epel-release)"
        case "pacman": return "sudo pacman -S --needed tigervnc xfce4-session xfce4-panel xfce4-settings xfce4-terminal xfdesktop xfwm4 thunar dbus xorg-xauth xorg-xdpyinfo xorg-xset libpulse openssl"
        default: return "Install XFCE and TigerVNC (the Xvnc server and vncpasswd) from the distribution’s packages."
        }
    }

    public func copyAdminRequest() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(adminRequestText, forType: .string)
    }

    // MARK: Generations

    private func bump() -> Int { generation += 1; return generation }
    private func current(_ token: Int) -> Bool { token == generation }
}
