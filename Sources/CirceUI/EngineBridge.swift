#if !CIRCE_UI_PREVIEW
import AppKit
import CirceClient
import CirceCore
import CirceHost
import CirceVNC
import Combine
import Network

/// The only layer that knows both engine types and presentation models.
/// Views never retain transports or make network calls themselves.
@MainActor
public final class CirceRuntime: ObservableObject {
    public let model: CirceModel
    private let browser: HostBrowser
    private let host: HostService
    private let loginService: any LoginItemServicing
    private let screenSharingBrowser = ScreenSharingBrowser()
    private var observations = Set<AnyCancellable>()
    private var discovered: [String: DiscoveredHost] = [:]
    private var screenSharingHosts: [String: ScreenSharingBrowser.Host] = [:]
    private var connections: [UUID: AnyObject] = [:]

    public init(preferences: CircePreferences? = nil, loginService: (any LoginItemServicing)? = nil) {
        model = CirceModel(preferences: preferences)
        self.loginService = loginService ?? SystemLoginItemService()
        host = .shared
        browser = HostBrowser(excludeDeviceID: DeviceIdentity.loadOrCreate().deviceID)
        model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        attachDiscovery()
        attachHosting()
        model.onSetOpenAtLogin = { [weak self] in self?.setOpenAtLogin($0) }
        model.onOpenLoginSettings = { [weak self] in self?.loginService.openSettings() }
        model.onShutdown = { [weak self] in
            self?.host.stop(); self?.browser.stop(); self?.screenSharingBrowser.stop()
        }
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification).sink { [weak self] _ in
            self?.model.shutdown()
        }.store(in: &observations)
        model.onConnect = { [weak self] host, address in
            guard let self else { return RemoteSession(name: host?.name ?? address, address: address) }
            return self.makeSession(host: host, address: address)
        }
        model.onCloseSession = { [weak self] id in self?.connections.removeValue(forKey: id) }
        refreshPermissions()
        browser.start()
        screenSharingBrowser.start()
        if model.preferences.shareThisMac { startHosting() }
    }

    private func makeSession(host: NearbyMac?, address: String) -> RemoteSession {
        let presentation = RemoteSession(name: host?.name ?? address, address: address)
        do {
            if let host, host.transport == .vnc, let found = screenSharingHosts[host.id] {
                let engine = VNCSession(endpoint: found.endpoint, name: found.name)
                connectVNC(engine, presentation: presentation)
                return presentation
            }
            let engine: ClientSession
            let config = StreamConfig(audioEnabled: model.preferences.audio)
            if let host, let found = discovered[host.id] {
                engine = ClientSession(host: found, config: config)
            } else if let host, let service = host.service {
                let endpoint = NWEndpoint.service(name: service.name, type: service.type, domain: service.domain, interface: nil)
                if host.transport == .vnc {
                    connectVNC(VNCSession(endpoint: endpoint, name: host.name), presentation: presentation)
                    return presentation
                }
                engine = ClientSession(endpoint: endpoint, name: host.name, config: config)
            } else {
                let parsed = try ConnectionAddress(address)
                let endpoint = NWEndpoint.hostPort(host: .init(parsed.host), port: .init(rawValue: parsed.port)!)
                if parsed.connectionProtocol == .vnc {
                    connectVNC(VNCSession(endpoint: endpoint, name: parsed.host), presentation: presentation)
                    return presentation
                }
                engine = ClientSession(endpoint: endpoint, name: parsed.host, config: config)
            }
            engine.matchesWindowResolution = model.preferences.matchesWindowResolution
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
            self.publishHosts()
        }.store(in: &observations)
        browser.$error.sink { [weak self] in self?.model.discoveryError = $0 }.store(in: &observations)
        screenSharingBrowser.$hosts.sink { [weak self] hosts in
            guard let self else { return }
            self.screenSharingHosts = Dictionary(hosts.map { ("vnc:\($0.id)", $0) }, uniquingKeysWith: { first, _ in first })
            self.publishHosts()
        }.store(in: &observations)
        model.onRefreshDiscovery = { [weak self] in
            self?.browser.restart()
            self?.screenSharingBrowser.stop(); self?.screenSharingBrowser.start()
        }
    }

    private func connectVNC(_ engine: VNCSession, presentation: RemoteSession) {
        engine.clipboardSyncEnabled = model.preferences.clipboard
        engine.capturesSystemShortcuts = model.preferences.captureShortcuts
        connections[presentation.id] = VNCSessionBinding(engine: engine, presentation: presentation)
        engine.connect()
    }

    private func publishHosts() {
        let native = discovered.values.map { nearbyMac(id: $0.id, name: $0.name, model: $0.modelIdentifier, endpoint: $0.endpoint, transport: .circe) }
        let nativeNames = Set(native.map { $0.name.lowercased() })
        let compatibility = screenSharingHosts.compactMap { id, host -> NearbyMac? in
            guard !nativeNames.contains(host.name.lowercased()) else { return nil }
            return nearbyMac(id: id, name: host.name, model: "Mac", endpoint: host.endpoint, transport: .vnc)
        }
        model.hosts = (native + compatibility).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func nearbyMac(id: String, name: String, model: String, endpoint: NWEndpoint, transport: HostTransport) -> NearbyMac {
        if case let .service(serviceName, type, domain, _) = endpoint {
            let service = BonjourServiceAddress(name: serviceName, type: type, domain: domain)
            return NearbyMac(id: id, name: name, model: model, address: service.displayAddress, transport: transport, service: service)
        }
        if case let .hostPort(host, port) = endpoint {
            let hostname = "\(host)"
            let address = "\(transport.rawValue)://\(hostname.contains(":") ? "[\(hostname)]" : hostname):\(port.rawValue)"
            return NearbyMac(id: id, name: name, model: model, address: address, transport: transport)
        }
        return NearbyMac(id: id, name: name, model: model, address: endpoint.debugDescription, transport: transport)
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
            if enabled {
                self.setOpenAtLogin(true)
                self.startHosting()
            } else {
                self.model.isHostStarting = false
                self.host.stop()
            }
        }

        model.onRefreshPermissions = { [weak self] in
            guard let self else { return }
            self.refreshPermissions()
            if self.model.preferences.shareThisMac && !self.model.isHosting && !self.model.isHostStarting &&
                self.model.screenRecordingGranted && self.model.accessibilityGranted { self.startHosting() }
        }
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

    private func startHosting() {
        refreshPermissions()
        guard model.screenRecordingGranted, model.accessibilityGranted else {
            model.hostError = "Allow Screen Recording and Accessibility to share this Mac."
            return
        }
        model.isHostStarting = true
        host.start()
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do { try loginService.setEnabled(enabled); model.loginItemError = nil }
        catch { model.loginItemError = "Couldn’t change Open Circe at login: \(error.localizedDescription)" }
        model.loginItemStatus = loginService.status
    }

    private func refreshPermissions() {
        model.loginItemStatus = loginService.status
        model.screenRecordingGranted = Permissions.screenRecording
        model.accessibilityGranted = Permissions.accessibility
        if model.accessibilityGranted {
            for session in model.sessions.values { session.showAccessibilityHint = false }
        }
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
        engine.displayView.onDragHover = { [weak presentation] hovering in
            guard let presentation else { return }
            presentation.isDraggingFiles = hovering && presentation.phase == .streaming
        }
        presentation.controlsAvailable = true
        presentation.scaleAvailable = true
        presentation.clipboardAvailable = true
        presentation.audioAvailable = true
        presentation.resolutionMatchingAvailable = true
        presentation.matchesWindowResolution = engine.matchesWindowResolution
        presentation.onMatchResolution = { [weak engine] in engine?.matchesWindowResolution = $0 }
        engine.$matchesWindowResolution.sink { [weak presentation] in presentation?.matchesWindowResolution = $0 }.store(in: &observations)
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
            apply(state, to: presentation)

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
@MainActor
private final class VNCSessionBinding {
    let engine: VNCSession
    let presentation: RemoteSession
    private var observations = Set<AnyCancellable>()
    init(engine: VNCSession, presentation: RemoteSession) {
        self.engine = engine; self.presentation = presentation
        presentation.displayView = engine.displayView
        presentation.controlsAvailable = true
        presentation.scaleAvailable = true
        presentation.clipboardAvailable = true
        presentation.audioAvailable = false
        presentation.audioEnabled = false
        presentation.keyboardReleaseAvailable = true
        presentation.clipboardEnabled = engine.clipboardSyncEnabled
        presentation.onReleaseKeyboard = { [weak engine] in engine?.releaseInput() }
        presentation.onPassword = { [weak engine] username, password in engine?.submitPassword(username: username, password: password) }
        presentation.onDisconnect = { [weak engine] in engine?.disconnect() }
        presentation.onReconnect = { [weak engine] in engine?.connect() }
        presentation.onClipboard = { [weak engine] in engine?.clipboardSyncEnabled = $0 }
        engine.$needsUsername.sink { [weak presentation] in presentation?.requiresUsername = $0 }.store(in: &observations)
        engine.$hostName.sink { [weak presentation] in presentation?.name = $0 }.store(in: &observations)
        engine.$state.sink { [weak presentation] state in
            guard let presentation else { return }
            apply(state, to: presentation)
        }.store(in: &observations)
        engine.$stats.sink { [weak presentation] stats in
            presentation?.fps = stats.fps; presentation?.latencyMs = stats.latencyMs; presentation?.bitrateMbps = stats.bitrateMbps
            let size = stats.resolution.split(separator: "×").compactMap { Double($0) }
            if size.count == 2, size[0] > 0, size[1] > 0 { presentation?.remotePixelSize = CGSize(width: size[0], height: size[1]) }
        }.store(in: &observations)
    }
}

@MainActor
private func apply(_ state: ClientState, to presentation: RemoteSession) {
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
}

#endif
