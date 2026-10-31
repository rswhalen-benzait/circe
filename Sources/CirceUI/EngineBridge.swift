#if !CIRCE_UI_PREVIEW
import AppKit
import CirceClient
import CirceCore
import CirceHost
import Combine
import Network

/// The only layer that knows both engine types and presentation models.
/// Views never retain transports or make network calls themselves.
@MainActor
public final class CirceRuntime: ObservableObject {
    public let model: CirceModel
    private let browser: HostBrowser
    private let host: HostService
    private var observations = Set<AnyCancellable>()
    private var discovered: [String: DiscoveredHost] = [:]
    private var connections: [UUID: NativeSessionBinding] = [:]

    public init() {
        model = CirceModel()
        host = .shared
        browser = HostBrowser(excludeDeviceID: DeviceIdentity.loadOrCreate().deviceID)
        model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        attachDiscovery()
        attachHosting()
        model.onConnect = { [weak self] host, address in
            guard let self else { return RemoteSession(name: host?.name ?? address, address: address) }
            return self.makeSession(host: host, address: address)
        }
        model.onCloseSession = { [weak self] id in self?.connections.removeValue(forKey: id) }
        refreshPermissions()
        browser.start()
    }

    private func makeSession(host: NearbyMac?, address: String) -> RemoteSession {
        let presentation = RemoteSession(name: host?.name ?? address, address: address)
        do {
            let engine: ClientSession
            let config = StreamConfig(audioEnabled: model.preferences.audio)
            if let host, let found = discovered[host.id] {
                engine = ClientSession(host: found, config: config)
            } else {
                let parsed = try ConnectionAddress(address)
                guard parsed.connectionProtocol == .circe else {
                    presentation.phase = .disconnected("VNC compatibility is coming in the next milestone. Connect to a Mac running Circe for now.")
                    return presentation
                }
                let endpoint = NWEndpoint.hostPort(host: .init(parsed.host), port: .init(rawValue: parsed.port)!)
                engine = ClientSession(endpoint: endpoint, name: parsed.host, config: config)
            }
            engine.clipboardSyncEnabled = model.preferences.clipboard
            engine.capturesSystemShortcuts = model.preferences.captureShortcuts
            let binding = NativeSessionBinding(engine: engine, presentation: presentation)
            connections[presentation.id] = binding
            engine.connect()
        } catch { presentation.phase = .disconnected(error.localizedDescription) }
        return presentation
    }

    private func attachDiscovery() {
        browser.$hosts.sink { [weak self] hosts in
            guard let self else { return }
            self.discovered = Dictionary(hosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            self.model.hosts = hosts.map { NearbyMac(id: $0.id, name: $0.name, model: $0.modelIdentifier, address: $0.endpoint.debugDescription) }
        }.store(in: &observations)
        browser.$error.sink { [weak self] in self?.model.discoveryError = $0 }.store(in: &observations)
        model.onRefreshDiscovery = { [weak self] in self?.browser.restart() }
    }

    private func attachHosting() {
        host.$isRunning.sink { [weak self] running in
            self?.model.isHosting = running
            if running { self?.model.isHostStarting = false }
        }.store(in: &observations)
        host.$pairingPIN.sink { [weak self] in self?.model.pairingPIN = $0 }.store(in: &observations)
        host.$clients.sink { [weak self] clients in
            self?.model.connectedClientCount = clients.filter(\.isStreaming).count
            self?.model.sharingConnections = clients.map { SharingConnection(id: $0.id, name: $0.name, isStreaming: $0.isStreaming) }
        }.store(in: &observations)
        host.$lastError.sink { [weak self] error in
            self?.model.hostError = error
            if error != nil { self?.model.isHostStarting = false }
        }.store(in: &observations)
        host.$allowPasswordAuth.sink { [weak self] in self?.model.allowPasswordAuthentication = $0 }.store(in: &observations)
        host.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshTrustedComputers() }
        }.store(in: &observations)
        model.onHostToggle = { [weak self] enabled in
            guard let self else { return }
            self.refreshPermissions()
            if enabled {
                guard self.model.screenRecordingGranted, self.model.accessibilityGranted else {
                    self.model.hostError = "Allow Screen Recording and Accessibility to share this Mac."
                    return
                }
                self.model.isHostStarting = true
                self.host.start()
            } else {
                self.model.isHostStarting = false
                self.host.stop()
            }
        }
        model.onRefreshPermissions = { [weak self] in self?.refreshPermissions() }
        model.onRequestScreen = { [weak self] in
            _ = Permissions.requestScreenRecording()
            Permissions.openScreenRecordingSettings()
            self?.refreshPermissions()
        }
        model.onRequestAccessibility = { [weak self] in
            _ = Permissions.requestAccessibility()
            Permissions.openAccessibilitySettings()
            self?.refreshPermissions()
        }
        model.onDisconnectClient = { [weak self] in self?.host.disconnect($0) }
        model.onForgetComputer = { [weak self] id in self?.host.forgetDevice(id); self?.refreshTrustedComputers() }
        model.onPasswordAuthentication = { [weak self] in self?.host.allowPasswordAuth = $0 }
        refreshTrustedComputers()
    }

    private func refreshPermissions() {
        model.screenRecordingGranted = Permissions.screenRecording
        model.accessibilityGranted = Permissions.accessibility
    }

    private func refreshTrustedComputers() {
        model.fingerprint = host.fingerprint
        model.pairedComputers = host.trustedDevices.map { PairedComputer(id: $0.deviceID, name: $0.name, fingerprint: keyFingerprint($0.publicKey)) }
    }
}
@MainActor
private final class NativeSessionBinding {
    let engine: ClientSession
    let presentation: RemoteSession
    private var observations = Set<AnyCancellable>()
    init(engine: ClientSession, presentation: RemoteSession) {
        self.engine = engine; self.presentation = presentation
        presentation.displayView = engine.displayView
        presentation.controlsAvailable = true
        presentation.qualityAvailable = true
        presentation.keyboardReleaseAvailable = true
        presentation.onReleaseKeyboard = { [weak engine] in engine?.releaseInput() }
        presentation.onSelectDisplay = { [weak engine] in engine?.selectDisplay($0) }
        presentation.clipboardEnabled = engine.clipboardSyncEnabled
        presentation.audioEnabled = engine.config.audioEnabled
        presentation.onPIN = { [weak engine] in engine?.submitPIN($0) }
        presentation.onPassword = { [weak engine] username, password in engine?.submitPassword(username: username, password: password) }
        presentation.onDisconnect = { [weak engine] in engine?.disconnect() }
        presentation.onReconnect = { [weak engine] in engine?.connect() }
        presentation.onClipboard = { [weak engine] in engine?.clipboardSyncEnabled = $0 }
        presentation.onAudio = { [weak engine] enabled in engine?.audioMuted = !enabled; engine?.setAudioEnabled(enabled) }
        presentation.onQuality = { [weak engine] quality in
            engine?.update { config in
                switch quality {
                case .automatic: config.quality = .high; config.maxFPS = 60
                case .text: config.quality = .ultra; config.maxFPS = 60
                case .motion: config.quality = .balanced; config.maxFPS = 120
                }
            }
        }
        engine.$state.sink { [weak presentation] state in
            guard let presentation else { return }
            switch state {
            case .idle, .connecting: presentation.phase = .connecting
            case .authenticating(let methods, let error):
                presentation.allowsPIN = methods.contains(.pin)
                presentation.allowsPassword = methods.contains(.password)
                presentation.pinError = error
                presentation.phase = .pairing
            case .streaming: presentation.phase = .streaming
            case .reconnecting(let attempt): presentation.phase = .reconnecting(attempt)
            case .disconnected(let reason): presentation.phase = .disconnected(reason)
            }
        }.store(in: &observations)
        engine.$hostName.sink { [weak presentation] in presentation?.name = $0 }.store(in: &observations)
        engine.$stats.sink { [weak presentation] stats in
            presentation?.fps = stats.fps; presentation?.latencyMs = stats.latencyMs; presentation?.bitrateMbps = stats.bitrateMbps
        }.store(in: &observations)
        engine.$displays.sink { [weak presentation] displays in
            presentation?.displays = displays.map { RemoteDisplay(id: $0.displayID, name: $0.name) }
        }.store(in: &observations)
        engine.$currentDisplay.sink { [weak presentation] display in
            guard let display else { return }
            presentation?.remotePixelSize = CGSize(width: display.pixelWidth, height: display.pixelHeight)
            presentation?.selectedDisplayID = display.displayID
        }.store(in: &observations)
    }
}
#endif
