import AppKit
import CirceClient
import CirceCore
import Combine
import Foundation
import Network
import Security

/// Session with a standard VNC server or a Mac's built-in Screen Sharing (no Circe install needed).
/// Mirrors `ClientSession`'s shape so the UI can treat both the same way.
@MainActor
public final class VNCSession: ObservableObject, Identifiable {
    public let id = UUID()
    public let endpoint: NWEndpoint
    @Published public private(set) var hostName: String
    @Published public private(set) var state: ClientState = .idle
    @Published public private(set) var stats = SessionStats()
    /// True when the server is a Mac (Apple Remote Desktop auth) — the UI asks for name + password.
    @Published public private(set) var needsUsername = true
    @Published public var clipboardSyncEnabled = true { didSet { updateClipboard() } }

    public let displayView = VNCDisplayView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))

    private var client: RFBClient?
    private var userClosed = false
    private var clipboard: ClipboardSync?
    private var fpsMeter = RateMeter()
    private var statsTimer: Timer?
    private var lastBytes: UInt64 = 0
    private var credentials: RFBClient.Credentials?
    private let keychainAccount: String
    private var hasFocus = false
    private var pendingClipboard: String?

    public init(endpoint: NWEndpoint, name: String) {
        self.endpoint = endpoint
        self.hostName = name
        keychainAccount = "\(endpoint)"
        displayView.onFocusChange = { [weak self] focused in
            guard let self else { return }
            self.hasFocus = focused
            if focused, let text = self.pendingClipboard, self.clipboardSyncEnabled {
                self.pendingClipboard = nil
                self.client?.sendClipboard(text)
            }
        }
    }

    /// "vnc://host[:port]" or "host:5900".
    public convenience init?(address: String) {
        var s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("vnc://") { s.removeFirst(6) }
        guard case let .hostPort(host, port)? = parseEndpoint(s) else { return nil }
        let p = s.contains(":") && !s.hasPrefix("[") || s.contains("]:") ? port : NWEndpoint.Port(rawValue: 5900)!
        self.init(endpoint: .hostPort(host: host, port: p), name: "\(host)")
    }

    public func connect() {
        userClosed = false
        state = .connecting
        let c = RFBClient(endpoint: endpoint) { [weak self] e in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(e) } }
        }
        if let saved = Keychain.load(account: keychainAccount) {
            c.initialCredentials = RFBClient.Credentials(username: saved.0, password: saved.1)
        }
        client = c
        displayView.client = c
        c.start()
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stats.fps = self?.fpsMeter.rate() ?? 0 }
        }
    }

    public func submitPassword(username: String, password: String) {
        credentials = RFBClient.Credentials(username: username, password: password)
        state = .connecting
        client?.provideCredentials(credentials!)
    }

    public func disconnect() {
        userClosed = true
        client?.stop()
        finish(nil)
    }

    public func releaseInput() { displayView.releaseInput() }
    public func captureInput() { displayView.captureInput() }

    public var capturesSystemShortcuts: Bool {
        get { displayView.capturesSystemShortcuts }
        set { displayView.capturesSystemShortcuts = newValue }
    }

    public func refresh() { client?.requestUpdate(incremental: false) }

    /// BGRA pixel at framebuffer coordinates (diagnostics / tests).
    public func samplePixel(x: Int, y: Int) -> UInt32? {
        guard let fb = lastFramebuffer, x >= 0, y >= 0, x < fb.width, y < fb.height else { return nil }
        fb.lock()
        defer { fb.unlock() }
        return fb.base[y * fb.stride + x]
    }

    private var lastFramebuffer: RFBFramebuffer?

    private func handle(_ e: RFBClient.Event) {
        switch e {
        case .needsCredentials(let user, let err):
            needsUsername = user
            state = .authenticating(methods: [.password], error: err)
        case let .connected(name, w, h, apple):
            if !name.isEmpty { hostName = name }
            displayView.isApple = apple
            displayView.framebufferSize = CGSize(width: w, height: h)
            stats.codec = apple ? "Screen Sharing" : "VNC"
            stats.resolution = "\(w)×\(h)"
            if let c = credentials { Keychain.save(account: keychainAccount, username: c.username, password: c.password) }
            state = .streaming
            updateClipboard()
        case let .resized(w, h):
            displayView.framebufferSize = CGSize(width: w, height: h)
            stats.resolution = "\(w)×\(h)"
        case .frameUpdated(let fb):
            fpsMeter.add()
            lastFramebuffer = fb
            displayView.show(fb)
        case .cursor(let c):
            displayView.setCursor(c)
        case .clipboard(let text):
            guard clipboardSyncEnabled else { return }
            clipboard?.apply(ClipboardPayload(items: [NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)], changeCount: 0))
        case .bell:
            NSSound.beep()
        case .closed(let reason):
            guard !userClosed else { return }
            if case .authenticating = state { Keychain.delete(account: keychainAccount) }
            if reason?.hasPrefix("Authentication failed") == true || reason == "Incorrect name or password." {
                Keychain.delete(account: keychainAccount)
            }
            finish(reason ?? "The connection was lost.")
        }
    }

    private func finish(_ reason: String?) {
        state = .disconnected(reason: reason)
        statsTimer?.invalidate()
        statsTimer = nil
        clipboard?.stop()
        clipboard = nil
        displayView.client = nil
        client = nil
    }

    private func updateClipboard() {
        if clipboardSyncEnabled && state == .streaming {
            guard clipboard == nil else { return }
            let c = ClipboardSync()
            c.onLocalChange = { [weak self] p in
                guard let self, let d = p.items[NSPasteboard.PasteboardType.string.rawValue],
                      let s = String(data: d, encoding: .utf8) else { return }
                // Same rule as native sessions: only share our clipboard while the session is focused.
                if self.hasFocus { self.client?.sendClipboard(s) } else { self.pendingClipboard = s }
            }
            c.start()
            clipboard = c
        } else {
            clipboard?.stop()
            clipboard = nil
        }
    }
}

/// Saved VNC / Screen Sharing credentials, so you only type them once.
enum Keychain {
    static let service = "Circe Screen Sharing"

    static func save(account: String, username: String, password: String) {
        delete(account: account)
        let blob = (try? JSONEncoder().encode([username, password])) ?? Data()
        SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                    kSecValueData: blob] as CFDictionary, nil)
    }

    static func load(account: String) -> (String, String)? {
        var out: CFTypeRef?
        guard SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                   kSecReturnData: true] as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data, let a = try? JSONDecoder().decode([String].self, from: d), a.count == 2 else { return nil }
        return (a[0], a[1])
    }

    static func delete(account: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
    }
}

/// Macs (and other machines) advertising built-in Screen Sharing / VNC via Bonjour (`_rfb._tcp`).
@MainActor
public final class ScreenSharingBrowser: ObservableObject {
    public struct Host: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let endpoint: NWEndpoint
    }

    @Published public private(set) var hosts: [Host] = []
    private var browser: NWBrowser?

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_rfb._tcp", domain: nil), using: NWParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = results.compactMap { r -> Host? in
                guard case let .service(name, _, _, _) = r.endpoint else { return nil }
                return Host(id: name, name: name, endpoint: r.endpoint)
            }
            Task { @MainActor in
                let own = MachineInfo.computerName
                self?.hosts = hosts.filter { $0.name != own }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    public func stop() { browser?.cancel(); browser = nil }
}
