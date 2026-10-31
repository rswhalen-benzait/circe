import AppKit
import Combine
import Foundation

public enum HostTransport: String, Codable { case circe, vnc }

public struct NearbyMac: Identifiable, Equatable {
    public let id: String
    public var name: String
    public var model: String
    public var address: String
    public var transport: HostTransport
    public var service: BonjourServiceAddress?
    public var symbol: String {
        let model = model.lowercased()
        if model.contains("macbook") { return "laptopcomputer" }
        if model.contains("mini") || model.contains("studio") { return "macmini" }
        if model.contains("pro") && !model.contains("imac") { return "macpro.gen3" }
        return "desktopcomputer"
    }
    public init(id: String, name: String, model: String = "Mac", address: String = "", transport: HostTransport = .circe, service: BonjourServiceAddress? = nil) {
        self.id = id; self.name = name; self.model = model; self.address = address; self.transport = transport; self.service = service
    }
}

public struct SharingConnection: Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let isStreaming: Bool
}

public struct PairedComputer: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let fingerprint: String
}

public struct RemoteDisplay: Identifiable, Equatable {
    public let id: UInt32
    public let name: String
}

public enum ConnectionPhase: Equatable {
    case connecting, pairing, streaming, reconnecting(Int), disconnected(String?)
}

public enum DisplayScale: String, CaseIterable, Identifiable {
    case fit = "Fit to window", actual = "Actual size"
    public var id: Self { self }
}

public enum StreamQuality: String, CaseIterable, Identifiable {
    case automatic = "Automatic", text = "Sharp text", motion = "Smooth motion"
    public var id: Self { self }
}

@MainActor
public final class CircePreferences: ObservableObject {
    public static let sharingKey = "shareThisMac"
    @Published public var accessibilityHintShown: Bool { didSet { defaults.set(accessibilityHintShown, forKey: "accessibilityHintShown") } }
    @Published public var shareThisMac: Bool { didSet { defaults.set(shareThisMac, forKey: Self.sharingKey) } }
    @Published public var clipboard: Bool { didSet { defaults.set(clipboard, forKey: "clipboard") } }
    @Published public var audio: Bool { didSet { defaults.set(audio, forKey: "audio") } }
    @Published public var captureShortcuts: Bool { didSet { defaults.set(captureShortcuts, forKey: "captureShortcuts") } }
    @Published public var showStats: Bool { didSet { defaults.set(showStats, forKey: "showStats") } }
    @Published public var matchesWindowResolution: Bool { didSet { defaults.set(matchesWindowResolution, forKey: "matchesWindowResolution") } }
    @Published public var quality: StreamQuality { didSet { defaults.set(quality.rawValue, forKey: "quality") } }
    private let defaults: UserDefaults
    var storageDefaults: UserDefaults { defaults }
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["clipboard": true, "audio": true, "captureShortcuts": true, "showStats": false])
        accessibilityHintShown = defaults.bool(forKey: "accessibilityHintShown")
        shareThisMac = defaults.bool(forKey: Self.sharingKey)
        clipboard = defaults.bool(forKey: "clipboard")
        audio = defaults.bool(forKey: "audio")
        captureShortcuts = defaults.bool(forKey: "captureShortcuts")
        showStats = defaults.bool(forKey: "showStats")
        matchesWindowResolution = defaults.bool(forKey: "matchesWindowResolution")
        quality = StreamQuality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .automatic
    }
}

@MainActor
public final class RemoteSession: ObservableObject, Identifiable {
    public let id = UUID()
    @Published public var name: String
    public let address: String
    @Published public var phase: ConnectionPhase = .connecting {
        didSet { if phase != .streaming { isDraggingFiles = false } }
    }
    @Published public var isDraggingFiles = false
    @Published public var fps: Double = 0
    @Published public var latencyMs: Double = 0
    @Published public var bitrateMbps: Double = 0
    @Published public var roundTripMs: Double = 0
    @Published public var transport = ""
    @Published public var droppedFrames = 0
    @Published public var scale: DisplayScale = .fit
    @Published public var matchesWindowResolution = false
    @Published public var resolutionMatchingAvailable = false
    @Published public var showStats = false
    @Published public var pinError: String?
    @Published public var allowsPIN = true
    @Published public var allowsPassword = false
    @Published public var requiresUsername = true
    @Published public var remotePixelSize = CGSize(width: 1280, height: 800)
    @Published public var displays: [RemoteDisplay] = []
    @Published public var selectedDisplayID: UInt32?
    @Published public var quality: StreamQuality = .automatic
    @Published public var clipboardEnabled = true
    @Published public var audioEnabled = true
    @Published public var controlsAvailable = false
    @Published public var scaleAvailable = false
    @Published public var clipboardAvailable = false
    @Published public var audioAvailable = false
    @Published public var qualityAvailable = false
    @Published public var keyboardReleaseAvailable = false
    @Published public var showAccessibilityHint = false
    public var displayView: NSView?
    var onPIN: ((String) -> Void)?
    var onPassword: ((String, String) -> Void)?
    var onDisconnect: (() -> Void)?
    var onReconnect: (() -> Void)?
    var onScale: ((DisplayScale) -> Void)?
    var onMatchResolution: ((Bool) -> Void)?
    var onClipboard: ((Bool) -> Void)?
    var onAudio: ((Bool) -> Void)?
    var onQuality: ((StreamQuality) -> Void)?
    var onReleaseKeyboard: (() -> Void)?
    var onScreenReaderChange: ((Bool) -> Void)?
    var onSelectDisplay: ((UInt32) -> Void)?
    var onRequestAccessibility: (() -> Void)?
    public init(name: String, address: String) { self.name = name; self.address = address }
    public func submitPIN(_ pin: String) {
        guard pin.count == 6, pin.allSatisfy(\.isNumber) else { return }
        pinError = nil; onPIN?(pin)
    }
    public func submitPassword(username: String, password: String) { pinError = nil; onPassword?(username, password) }
    public func disconnect() {
        if case .disconnected = phase { return }
        onDisconnect?(); phase = .disconnected(nil)
    }
    public var canReconnect: Bool { onReconnect != nil }
    public func reconnect() { guard let onReconnect else { return }; phase = .connecting; pinError = nil; onReconnect() }
    public func setScale(_ value: DisplayScale) {
        if value == .actual && matchesWindowResolution { setMatchesWindowResolution(false) }
        scale = value; onScale?(value)
    }
    public func setMatchesWindowResolution(_ enabled: Bool) {
        if enabled && scale != .fit { setScale(.fit) }
        matchesWindowResolution = enabled; onMatchResolution?(enabled)
    }
    public func setClipboard(_ value: Bool) { clipboardEnabled = value; onClipboard?(value) }
    public func setAudio(_ value: Bool) { audioEnabled = value; onAudio?(value) }
    public func setQuality(_ value: StreamQuality) { quality = value; onQuality?(value) }
    public func releaseKeyboard() { if phase == .streaming { onReleaseKeyboard?() } }
    public func setScreenReaderActive(_ enabled: Bool) { onScreenReaderChange?(enabled) }
    public func selectDisplay(_ id: UInt32) { selectedDisplayID = id; onSelectDisplay?(id) }
    public func requestAccessibility() { releaseKeyboard(); onRequestAccessibility?() }
    public func dismissAccessibilityHint() { showAccessibilityHint = false }
}

@MainActor
public final class CirceModel: ObservableObject {
    @Published public var hosts: [NearbyMac] = []
    @Published public private(set) var recentConnections: [RecentConnection] = []
    @Published public var sessions: [UUID: RemoteSession] = [:]
    @Published public var isHosting = false
    @Published public var pairingPIN: String?
    @Published public var connectedClientCount = 0
    @Published public var sharingConnections: [SharingConnection] = []
    @Published public var pairedComputers: [PairedComputer] = []
    @Published public var fingerprint = ""
    @Published public var allowPasswordAuthentication = true
    @Published public var isHostStarting = false
    @Published public var screenRecordingGranted = false
    @Published public var accessibilityGranted = false
    @Published public var hostError: String?
    @Published public var discoveryError: String?
    @Published public var loginItemStatus: LoginItemStatus = .notRegistered
    @Published public var loginItemError: String?
    public var openAtLogin: Bool { loginItemStatus.isRegistered }
    public var sharingEnabled: Bool { isHosting || preferences.shareThisMac }
    public let preferences: CircePreferences
    private var preferenceObservation: AnyCancellable?
    private let recentStore: RecentConnectionsStore
    private var recentObservations: [UUID: AnyCancellable] = [:]
    public let computerName = Host.current().localizedName ?? "This Mac"
    var onConnect: ((NearbyMac?, String) -> RemoteSession)?
    var onHostToggle: ((Bool) -> Void)?
    var onRefreshPermissions: (() -> Void)?
    var onRequestScreen: (() -> Void)?
    var onRequestAccessibility: (() -> Void)?
    var onRefreshDiscovery: (() -> Void)?
    var onDisconnectClient: ((UUID) -> Void)?
    var onForgetComputer: ((String) -> Void)?
    var onPasswordAuthentication: ((Bool) -> Void)?
    var onCloseSession: ((UUID) -> Void)?
    var onSetOpenAtLogin: ((Bool) -> Void)?
    var onOpenLoginSettings: (() -> Void)?
    var onShutdown: (() -> Void)?
    public init(preferences: CircePreferences? = nil) {
        self.preferences = preferences ?? CircePreferences()
        recentStore = RecentConnectionsStore(defaults: self.preferences.storageDefaults)
        recentConnections = recentStore.connections
        preferenceObservation = self.preferences.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    @discardableResult
    public func connect(to host: NearbyMac) -> RemoteSession { begin(host: host, address: host.address) }
    @discardableResult
    public func connect(address: String) -> RemoteSession { begin(host: nil, address: address.trimmingCharacters(in: .whitespacesAndNewlines)) }
    @discardableResult
    public func connect(to recent: RecentConnection) -> RemoteSession { begin(host: recent.nearbyHost, address: recent.address) }
    public func removeRecent(_ id: String) { recentStore.remove(id); recentConnections = recentStore.connections }
    public func clearRecents() { recentStore.clear(); recentConnections = [] }
    private func begin(host: NearbyMac?, address: String) -> RemoteSession {
        let session = onConnect?(host, address) ?? RemoteSession(name: host?.name ?? address, address: address)
        if onConnect == nil { session.phase = .disconnected("The connection engine is not available in this preview.") }
        session.showStats = preferences.showStats
        sessions[session.id] = session
        session.onRequestAccessibility = { [weak self] in self?.requestAccessibility() }
        recentObservations[session.id] = session.$phase.filter { $0 == .streaming }.prefix(1).sink { [weak self, weak session] _ in
            guard let self, let session else { return }
            self.refreshPermissions()
            if !self.accessibilityGranted && self.preferences.captureShortcuts && !self.preferences.accessibilityHintShown {
                self.preferences.accessibilityHintShown = true
                session.showAccessibilityHint = true
            }
            self.recentStore.record(host: host, address: address, name: session.name)
            self.recentConnections = self.recentStore.connections
        }
        return session
    }
    public func closeSession(_ id: UUID) { sessions[id]?.disconnect(); sessions.removeValue(forKey: id); recentObservations.removeValue(forKey: id)?.cancel(); onCloseSession?(id) }
    public func setHosting(_ enabled: Bool) { hostError = nil; preferences.shareThisMac = enabled; onHostToggle?(enabled) }
    public func refreshPermissions() { onRefreshPermissions?() }
    public func requestScreenRecording() { onRequestScreen?() }
    public func requestAccessibility() { onRequestAccessibility?() }
    public func refreshDiscovery() { discoveryError = nil; onRefreshDiscovery?() }
    public func disconnectClient(_ id: UUID) { onDisconnectClient?(id) }
    public func forgetComputer(_ id: String) { onForgetComputer?(id) }
    public func setPasswordAuthentication(_ allowed: Bool) { onPasswordAuthentication?(allowed) }
    public func setOpenAtLogin(_ enabled: Bool) { loginItemError = nil; onSetOpenAtLogin?(enabled) }
    public func openLoginSettings() { onOpenLoginSettings?() }
    public func shutdown() { for session in sessions.values { session.disconnect() }; onShutdown?() }
}
