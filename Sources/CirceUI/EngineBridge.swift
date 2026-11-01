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
    /// Sessions held open so desktops without lingering keep running while their window is connected.
    private var desktopLeases: [UUID: LinuxSetup.DesktopLease] = [:]
    private var setupCancellations: [UUID: () -> Void] = [:]

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
            self?.setupCancellations.values.forEach { $0() }; self?.setupCancellations.removeAll()
        }
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification).sink { [weak self] _ in
            self?.model.shutdown()
        }.store(in: &observations)
        model.onConnect = { [weak self] host, address in
            guard let self else { return RemoteSession(name: host?.name ?? address, address: address) }
            return self.makeSession(host: host, address: address)
        }
        model.onCloseSession = { [weak self] id in
            self?.connections.removeValue(forKey: id)
            self?.desktopLeases.removeValue(forKey: id)?.end()
        }
        model.onConnectComputer = { [weak self] computer in
            let presentation = RemoteSession(name: computer.name, address: computer.detail)
            guard let self else { return presentation }
            if case .googleCloud(_, _, .some, _, .some, _, _, _) = computer.connection {
                // Sign-in and power state first, so a stopped VM or expired sign-in is one click, not a timeout.
                // The desktop connection is only made once those checks pass.
                var preflight = CloudPreflight()
                presentation.onDisconnect = { [weak self, weak presentation] in
                    preflight.cancel()
                    guard let presentation else { return }
                    (self?.connections[presentation.id] as? VNCSessionBinding)?.engine.disconnect()
                }
                weak var owner = self
                weak var target = presentation
                func run() {
                    MainActor.assumeIsolated {
                        guard let self = owner, let presentation = target else { return }
                        if preflight.cancelled { preflight = CloudPreflight() }
                        let attempt = preflight
                        self.prepareCloudConnection(computer.id, presentation: presentation, preflight: attempt) { [weak self] in
                            MainActor.assumeIsolated { self?.attachVNC(computer.id, fallback: computer, presentation: presentation, preflight: attempt, rerun: run) }
                        }
                    }
                }
                presentation.onReconnect = { run() }
                run()
            } else if computer.startsDesktopOnConnect {
                // An SSH computer whose desktop doesn't keep running on its own: start it and hold it while connected.
                var preflight = CloudPreflight()
                presentation.onDisconnect = { [weak self, weak presentation] in
                    preflight.cancel()
                    guard let presentation else { return }
                    (self?.connections[presentation.id] as? VNCSessionBinding)?.engine.disconnect()
                }
                weak var owner = self
                weak var target = presentation
                func run() {
                    MainActor.assumeIsolated {
                        guard let self = owner, let presentation = target else { return }
                        if preflight.cancelled { preflight = CloudPreflight() }
                        let attempt = preflight
                        let latest = self.model.computers.first(where: { $0.id == computer.id }) ?? computer
                        self.ensureDesktop(latest, presentation: presentation, preflight: attempt, retry: run) { [weak self] in
                            MainActor.assumeIsolated { self?.attachVNC(computer.id, fallback: computer, presentation: presentation, preflight: attempt, rerun: run) }
                        }
                    }
                }
                presentation.onReconnect = { run() }
                run()
            } else {
                self.attachVNC(computer.id, fallback: computer, presentation: presentation)
            }
            return presentation
        }
        model.onComputerReplaced = { old in VNCSession.forgetPassword(for: tunnel(for: old)) }
        model.onUpdateComputer = { [weak self] computer in
            self?.connections.values.compactMap { $0 as? VNCSessionBinding }
                .filter { $0.computerID == computer.id }.forEach { $0.update(computer) }
        }
        model.onSetupComputer = { [weak self] computer, completion in self?.setUp(computer, completion: completion) }
        model.onActiveGoogleAccount = { GCloud.activeAccount() }
        model.cloudServices = makeCloudServices()
        refreshPermissions()
        browser.start()
        screenSharingBrowser.start()
        if model.preferences.shareThisMac { startHosting() }
    }

    private func setUp(_ computer: SavedComputer, sudoPassword: String? = nil, withoutAdmin: Bool = false, resetPassword: Bool = false, output: ((String) -> Void)? = nil,
                       completion: @escaping (Result<SavedComputer, Error>) -> Void) {
        guard let url = LinuxHostSetup.scriptURL, let script = try? Data(contentsOf: url) else {
            completion(.failure(ComputerValidationError("The Linux installer is missing. Reinstall Circe, then try setup again.")))
            return
        }
        // The installer reports a new VNC password as soon as it exists; keep it even if a later step fails.
        let keychainRoute = tunnel(for: computer)
        let savedEarly = SavedFlag()
        // If Circe holds no password for this desktop, a kept remote one would be unknown to everyone: make a new one.
        let reset = resetPassword || !VNCSession.hasSavedPassword(for: keychainRoute) ? ["--reset-password"] : []
        let cancellation = LinuxSetup.run(tunnel: tunnel(for: computer), script: script,
                                          arguments: ["--display", String(computer.display)] + reset + (withoutAdmin ? ["--without-admin"] : []),
                                          sudoPassword: sudoPassword, onPassword: { password in
            DispatchQueue.main.async { MainActor.assumeIsolated { savedEarly.value = VNCSession.savePassword(password, for: keychainRoute) ? .saved : .failed } }
        }, onOutput: { [weak self] line in
            Task { @MainActor in
                if let output { output(CirceModel.redactSetupOutput(line)) } else { self?.model.appendSetupOutput(line, for: computer.id) }
            }
        }, completion: { [weak self] result in
            Task { @MainActor in
                self?.setupCancellations.removeValue(forKey: computer.id)
                switch result {
                case .success(let report):
                    guard (1...99).contains(report.display) else { completion(.failure(ComputerValidationError("Setup returned an invalid display number."))); return }
                    var updated = computer; updated.display = report.display
                    updated.startsDesktopOnConnect = report.persistent == false
                    // Chrome Remote Desktop sends ⌘ as Super, and sessions set up for it expect that (Mac-style
                    // shortcuts on Super, Control for Control): showing that same session, Circe does the same.
                    if report.sharedSession == "chrome-remote-desktop" { updated.commandActsAsControl = false }
                    if let password = report.password, !VNCSession.savePassword(password, for: tunnel(for: updated)) {
                        completion(.failure(ComputerValidationError("The desktop is set up, but Circe couldn’t save its password in your Keychain. Unlock the Keychain, then run setup again — Circe will give the desktop a new password.")))
                        return
                    }
                    completion(.success(updated))
                case .failure(let error) where savedEarly.value == .failed:
                    // The desktop's new password exists only on the VM now; say so rather than lose it silently.
                    completion(.failure(LinuxSetup.Failure.code("keychain_failed", message: "\(error) Circe also couldn’t save the new desktop password in your Keychain; run setup again after unlocking the Keychain and Circe will give the desktop a new password.")))
                case .failure(let error): completion(.failure(error))
                }
            }
        })
        if let cancellation { setupCancellations[computer.id] = cancellation }
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
        let requestedShortcuts = engine.capturesSystemShortcuts
        presentation.onScreenReaderChange = { [weak engine] enabled in engine?.capturesSystemShortcuts = requestedShortcuts && !enabled }
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
            presentation?.roundTripMs = stats.roundTripMs; presentation?.transport = stats.transport; presentation?.droppedFrames = stats.droppedFrames
            presentation?.codec = stats.codec
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
    let computerID: UUID?
    private var observations = Set<AnyCancellable>()
    var suppressState = false
    var recoveryPreflight: CloudPreflight?
    var recoveryObservations = Set<AnyCancellable>()
    var recoveryCancel: (() -> Void)?
    deinit { recoveryCancel?() }
    init(engine: VNCSession, presentation: RemoteSession, computerID: UUID? = nil) {
        self.engine = engine; self.presentation = presentation; self.computerID = computerID
        presentation.displayView = engine.displayView
        presentation.controlsAvailable = true
        presentation.scaleAvailable = true
        presentation.clipboardAvailable = true
        presentation.audioAvailable = engine.tunnel.isTunneled
        presentation.videoControlsAvailable = engine.tunnel.isTunneled
        presentation.videoEnabled = engine.remoteVideoEnabled
        presentation.onVideo = { [weak engine] enabled in engine?.remoteVideoEnabled = enabled }
        engine.$remoteVideoEnabled.sink { [weak presentation] in presentation?.videoEnabled = $0 }.store(in: &observations)
        engine.$videoMode.sink { [weak presentation] mode in
            switch mode {
            case .vnc: presentation?.videoMode = .vnc
            case .starting: presentation?.videoMode = .starting
            case .h264(let encoder): presentation?.videoMode = .h264(encoder: encoder)
            }
        }.store(in: &observations)
        engine.$videoFallbackReason.sink { [weak presentation] in presentation?.videoFallbackReason = $0 }.store(in: &observations)
        presentation.audioEnabled = engine.tunnel.isTunneled && engine.remoteAudioEnabled && !engine.audioMuted
        presentation.onAudio = { [weak engine] enabled in engine?.audioMuted = !enabled; engine?.remoteAudioEnabled = enabled }
        presentation.onMatchResolution = { [weak engine] enabled in engine?.fitsRemoteDesktopToWindow = enabled }
        presentation.microphoneAvailable = engine.tunnel.isTunneled
        engine.$microphoneEnabled.sink { [weak presentation] in presentation?.microphoneEnabled = $0 }.store(in: &observations)
        engine.$microphoneProblem.sink { [weak presentation] in presentation?.microphoneProblem = $0 }.store(in: &observations)
        engine.$microphoneActive.sink { [weak presentation] in presentation?.microphoneActive = $0 }.store(in: &observations)
        engine.$canResizeDesktop.sink { [weak presentation, weak engine] in
            presentation?.resolutionMatchingAvailable = $0
            presentation?.matchesWindowResolution = $0 && engine?.fitsRemoteDesktopToWindow == true
        }.store(in: &observations)
        engine.$fitsRemoteDesktopToWindow.sink { [weak presentation, weak engine] in presentation?.matchesWindowResolution = $0 && engine?.canResizeDesktop == true }.store(in: &observations)
        engine.$remoteAudioEnabled.sink { [weak presentation, weak engine] in presentation?.audioEnabled = $0 && engine?.audioMuted == false }.store(in: &observations)
        engine.$audioMuted.sink { [weak presentation, weak engine] in presentation?.audioEnabled = !$0 && engine?.remoteAudioEnabled == true }.store(in: &observations)
        presentation.keyboardReleaseAvailable = true
        presentation.clipboardEnabled = engine.clipboardSyncEnabled
        presentation.onReleaseKeyboard = { [weak engine] in engine?.releaseInput() }
        let requestedShortcuts = engine.capturesSystemShortcuts
        presentation.onScreenReaderChange = { [weak engine] enabled in engine?.capturesSystemShortcuts = requestedShortcuts && !enabled }
        presentation.onPassword = { [weak engine] username, password in engine?.submitPassword(username: username, password: password) }
        presentation.onDisconnect = { [weak engine] in engine?.disconnect() }
        presentation.onReconnect = { [weak engine] in engine?.connect() }
        presentation.onClipboard = { [weak engine] in engine?.clipboardSyncEnabled = $0 }
        engine.$needsUsername.sink { [weak presentation] in presentation?.requiresUsername = $0 }.store(in: &observations)
        engine.$hostName.sink { [weak presentation] in presentation?.name = $0 }.store(in: &observations)
        engine.$state.sink { [weak self, weak presentation] state in
            guard let presentation, self?.suppressState != true else { return }
            apply(state, to: presentation)
        }.store(in: &observations)
        engine.$stats.sink { [weak presentation] stats in
            presentation?.fps = stats.fps; presentation?.latencyMs = stats.latencyMs; presentation?.bitrateMbps = stats.bitrateMbps
            presentation?.roundTripMs = stats.roundTripMs; presentation?.transport = stats.transport; presentation?.droppedFrames = stats.droppedFrames
            presentation?.codec = stats.codec.contains("Tight") ? "VNC (Tight/JPEG)" : stats.codec
            let size = stats.resolution.split(separator: "×").compactMap { Double($0) }
            if size.count == 2, size[0] > 0, size[1] > 0 { presentation?.remotePixelSize = CGSize(width: size[0], height: size[1]) }
        }.store(in: &observations)
    }
    /// Stops mirroring the engine into the presentation (before retiring the engine).
    func detach() { recoveryCancel?(); recoveryCancel = nil; recoveryObservations.removeAll(); observations.removeAll() }
    func update(_ computer: SavedComputer) {
        let mapping: CommandKeyMapping = computer.commandActsAsControl ? .control : .super
        if engine.commandKeyMapping != mapping { if engine.state == .streaming { engine.releaseInput() }; engine.commandKeyMapping = mapping }
        if engine.remoteAudioEnabled != computer.audioEnabled { engine.remoteAudioEnabled = computer.audioEnabled }
        if engine.tunnel.isTunneled, engine.microphoneEnabled != computer.microphoneEnabled { engine.microphoneEnabled = computer.microphoneEnabled }
        if engine.remoteVideoEnabled != computer.videoEnabled { engine.remoteVideoEnabled = computer.videoEnabled }
        if engine.fitsRemoteDesktopToWindow != computer.fitsDesktopToWindow { engine.fitsRemoteDesktopToWindow = computer.fitsDesktopToWindow }
    }
}

// MARK: - Google Cloud

/// Runs `work` off the main thread; delivers its result (engine errors mapped for the UI) on the main actor.
private func inBackground<T>(_ work: @escaping () throws -> T, _ done: @escaping @MainActor (Result<T, CloudError>) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        let result: Result<T, CloudError>
        do { result = .success(try work()) } catch { result = .failure(cloudError(error)) }
        DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
    }
}

private func cloudError(_ error: Error) -> CloudError {
    guard let failure = error as? GoogleCloud.Failure else { return CloudError(.other, error.localizedDescription) }
    let kind: CloudError.Kind
    switch failure {
    case .cliMissing: kind = .cliMissing
    case .signInRequired: kind = .signInRequired
    case let .permissionDenied(permission): kind = .permissionDenied(permission)
    case .notFound: kind = .notFound
    case .apiDisabled: kind = .apiDisabled
    case .quotaExceeded: kind = .quota
    case .capacityUnavailable: kind = .capacity
    case .timedOut: kind = .timedOut
    case .offline: kind = .offline
    case .cancelled: kind = .cancelled
    case let .wrongAccount(_, actual): kind = .wrongAccount(actual: actual)
    case .signInBlocked: kind = .signInBlocked
    case .replaced: kind = .replaced
    case .other: kind = .other
    }
    return CloudError(kind, failure.description)
}

private func cloudInstance(_ i: GoogleCloud.Instance, project: String) -> CloudInstance {
    var instance = CloudInstance(instanceID: i.id, name: i.name, zone: i.zone, status: i.status, machineType: i.machineType, gpu: i.gpu,
                                 suggestedUsers: i.suggestedUsers, hostKeyAlias: i.hostKeyAlias(project: project), osLogin: i.osLogin)
    instance.sshConfigLogins = GoogleCloud.sshConfigLogins(instance: i.name).map { CloudSSHLogin(user: $0.user, keyFile: $0.identityFile) }
    return instance
}

private func engineInstance(_ c: CloudInstance) -> GoogleCloud.Instance {
    GoogleCloud.Instance(id: c.instanceID, name: c.name, zone: c.zone, status: c.status, machineType: c.machineType, gpu: c.gpu,
                         hasExternalIP: false, suggestedUsers: c.suggestedUsers, osLogin: c.osLogin)
}

private func hostReport(_ probe: LinuxSetup.Probe) -> CloudHostReport {
    var report = CloudHostReport(user: probe.user, osName: probe.os.name, packageManager: probe.packageManager, sudo: probe.sudo, adminGroup: probe.adminGroup,
                                 systemd: probe.systemd, circeInstalled: probe.circe.installed, circeDisplay: probe.circe.display, circeRunning: probe.circe.running,
                                 desktops: probe.existingDesktops.map { CloudDesktop(display: $0.display, process: $0.process) }, sessions: probe.sessions)
    report.usedDisplays = Array(Set(probe.vnc.map(\.display) + (probe.xDisplays ?? []))).sorted()
    report.withoutAdmin = probe.withoutAdmin ?? false
    report.selfLinger = probe.selfLinger ?? false
    report.lingering = probe.lingering
    report.systemDesktop = probe.systemDesktop?.name
    report.circeCurrent = probe.circe.current ?? true
    report.circeShared = probe.circe.shared
    return report
}

extension CirceRuntime {
    func makeCloudServices() -> CloudServices {
        CloudServices(
            isInstalled: { GoogleCloud.isInstalled },
            install: { progress, completion in
                let cancel = GoogleCloud.CancelToken()
                inBackground({ try GoogleCloudInstaller.install(cancel: cancel) { line in DispatchQueue.main.async { MainActor.assumeIsolated { progress(line) } } } }, completion)
                return CloudCancel { cancel.cancel() }
            },
            accounts: { completion in
                inBackground({ try GoogleCloud.accounts().map { CloudAccount(email: $0.email, isActive: $0.isActive) } }, completion)
            },
            credential: { account, completion in
                inBackground({ () -> CloudCredential in
                    switch try GoogleCloud.credential(for: account) { case .valid: return .valid; case .expired: return .expired; case .notSignedIn: return .notSignedIn }
                }, completion)
            },
            signIn: { account, useCode, events, completion in
                let cancel = GoogleCloud.CancelToken(), channel = GoogleCloud.SignInChannel()
                inBackground({ try GoogleCloud.signIn(hint: account, useCode: useCode, cancel: cancel, channel: channel) { event in
                    DispatchQueue.main.async { MainActor.assumeIsolated {
                        switch event { case .page(let url): events(.page(url)); case .needsCode: events(.needsCode) }
                    } }
                } }, completion)
                return CloudCancel({ cancel.cancel() }, submit: { channel.submit($0) })
            },
            projects: { account, completion in
                inBackground({ try GoogleCloud.projects(account: account).map { CloudProject(id: $0.id, name: $0.name) } }, completion)
            },
            instances: { account, project, completion in
                inBackground({ try GoogleCloud.instances(account: account, project: project).map { cloudInstance($0, project: project) } }, completion)
            },
            instance: { account, project, zone, name, completion in
                inBackground({ cloudInstance(try GoogleCloud.instance(account: account, project: project, zone: zone, name: name), project: project) }, completion)
            },
            start: { account, project, instance, progress, completion in
                let cancel = GoogleCloud.CancelToken()
                inBackground({ try GoogleCloud.start(engineInstance(instance), account: account, project: project, cancel: cancel) { state in
                    DispatchQueue.main.async { MainActor.assumeIsolated { progress(state) } }
                } }, completion)
                return CloudCancel { cancel.cancel() }
            },
            checkTunnel: { account, project, instance, completion in
                inBackground({ () -> CloudReachability in
                    switch try GoogleCloud.checkTunnel(account: account, project: project, zone: instance.zone, instance: instance.name) {
                    case .reachable: return .reachable
                    case .notAuthorized: return .notAuthorized
                    case .backendUnreachable: return .backendUnreachable
                    case .failed(let message): return .failed(message)
                    }
                }, completion)
            },
            osLoginUser: { account, project, completion in
                inBackground({ GoogleCloud.osLoginUsername(account: account, project: project) }) { completion((try? $0.get()) ?? nil) }
            },
            pinHostKeys: { account, project, instance, completion in
                inBackground({ GoogleCloud.pinPublishedHostKeys(account: account, project: project, instance: engineInstance(instance)) }) { completion((try? $0.get()) ?? true) }
            },
            verifyLogin: { computer, completion in
                let route = tunnel(for: computer)
                inBackground({ () -> CloudLogin in
                    switch GoogleCloud.verifyLogin(route) {
                    case let .ok(user, uid): return .ok(user: user, uid: uid)
                    case .keyRefused: return .keyRefused
                    case .notAuthorized: return .notAuthorized
                    case .unreachable: return .unreachable
                    case .hostKeyChanged: return .hostKeyChanged
                    case .failed(let message): return .failed(message)
                    }
                }) { completion((try? $0.get()) ?? .failed("Circe couldn’t check the Linux sign-in.")) }
            },
            authorizeKey: { account, project, instance, user, completion in
                inBackground({ () -> String in
                    // Only the VM's or project's own setting counts. Otherwise gcloud's ssh flow decides (it handles
                    // both OS Login and metadata keys), so a profile used elsewhere can't misroute the key.
                    let osLogin = instance.osLogin ?? GoogleCloud.projectOSLogin(account: account, project: project) ?? false
                    guard let name = try GoogleCloud.authorizeKey(account: account, project: project, zone: instance.zone, instance: engineInstance(instance),
                                                                  user: user, osLogin: osLogin) else {
                        throw GoogleCloud.Failure.other("Google added your key, but didn’t report your Linux user name.")
                    }
                    return name
                }, completion)
            },
            probe: { computer, completion in
                guard let url = LinuxHostSetup.scriptURL, let script = try? Data(contentsOf: url) else {
                    completion(.failure(CloudError(.other, "The Linux installer is missing. Reinstall Circe."))); return CloudCancel {}
                }
                let cancel = LinuxSetup.probe(tunnel: tunnel(for: computer), script: script) { result in
                    DispatchQueue.main.async { MainActor.assumeIsolated {
                        switch result {
                        case .success(let probe): completion(.success(hostReport(probe)))
                        case .failure(let failure): completion(.failure(CloudError(.other, failure.description)))
                        }
                    } }
                }
                return CloudCancel { cancel?() }
            },
            setUp: { [weak self] computer, password, withoutAdmin, output, completion in
                self?.setUp(computer, sudoPassword: password, withoutAdmin: withoutAdmin, output: output) { result in
                    completion(result.mapError { error in
                        if let failure = error as? LinuxSetup.Failure { return CloudSetupError(code: failure.code, message: failure.description) }
                        return CloudSetupError(code: nil, message: error.localizedDescription)
                    })
                }
                return CloudCancel { [weak self] in self?.setupCancellations.removeValue(forKey: computer.id)?() }
            },
            localUserName: { NSUserName() })
    }

    /// Creates (or reuses, if its route is unchanged) the VNC engine for a session and connects it.
    func attachVNC(_ id: UUID, fallback: SavedComputer, presentation: RemoteSession, preflight: CloudPreflight? = nil, rerun: (() -> Void)? = nil) {
        let computer = model.computers.first(where: { $0.id == id }) ?? fallback
        let route = tunnel(for: computer)
        guard preflight?.cancelled != true else { return }
        if let existing = connections[presentation.id] as? VNCSessionBinding {
            if existing.engine.tunnel == route {
                existing.recoveryPreflight = preflight
                existing.update(computer)
                if let preflight, let rerun {
                    presentation.onDisconnect = { [weak self, weak presentation, weak engine = existing.engine] in
                        preflight.cancel(); engine?.disconnect()
                        if let presentation { self?.desktopLeases.removeValue(forKey: presentation.id)?.end() }
                    }
                    presentation.onReconnect = rerun
                }
                existing.engine.connect(); return
            }
            // The saved route changed (e.g. a replaced VM was accepted): retire the old engine quietly.
            existing.detach(); existing.engine.disconnect(); connections.removeValue(forKey: presentation.id)
        }
        let engine = VNCSession(tunnel: route, name: computer.name)
        engine.clipboardSyncEnabled = model.preferences.clipboard
        engine.capturesSystemShortcuts = model.preferences.captureShortcuts
        let binding = VNCSessionBinding(engine: engine, presentation: presentation, computerID: computer.id)
        presentation.onVideo = { [weak self, weak engine] enabled in
            if engine?.remoteVideoEnabled != enabled { engine?.remoteVideoEnabled = enabled }
            guard let self, var saved = self.model.computers.first(where: { $0.id == id }) else { return }
            saved.videoEnabled = enabled; try? self.model.saveComputer(saved)
        }
        presentation.onMicrophone = { [weak self, weak engine] enabled in
            engine?.microphoneEnabled = enabled
            guard let self, var saved = self.model.computers.first(where: { $0.id == id }) else { return }
            saved.microphoneEnabled = enabled; try? self.model.saveComputer(saved)
        }
        binding.update(computer)
        connections[presentation.id] = binding
        binding.recoveryPreflight = preflight
        var checkingRecovery = false
        engine.$state.sink { [weak self, weak engine, weak presentation] state in
            guard let self, let engine, let presentation else { return }
            if state == .streaming || state == .connecting { checkingRecovery = false; return }
            let needsPassword: Bool
            if case .authenticating = state { needsPassword = !engine.needsUsername }
            else { needsPassword = engine.passwordRejected }
            guard needsPassword, !checkingRecovery else { return }
            checkingRecovery = true
            self.offerDesktopPasswordRecovery(computer, engine: engine, presentation: presentation,
                                              preflight: (self.connections[presentation.id] as? VNCSessionBinding)?.recoveryPreflight)
        }.store(in: &binding.recoveryObservations)
        if let preflight, let rerun {
            presentation.onDisconnect = { [weak self, weak presentation, weak engine] in
                preflight.cancel(); engine?.disconnect()
                if let presentation { self?.desktopLeases.removeValue(forKey: presentation.id)?.end() }
            }
            presentation.onReconnect = rerun
        }
        engine.connect()
    }

    /// A Circe-managed desktop's password is an implementation detail, not something a person should know.
    /// Confirm ownership read-only; replacing that password is always an explicit user action.
    private func offerDesktopPasswordRecovery(_ original: SavedComputer, engine: VNCSession,
                                               presentation: RemoteSession, preflight: CloudPreflight?) {
        guard engine.tunnel.isTunneled, let url = LinuxHostSetup.scriptURL,
              let script = try? Data(contentsOf: url),
              let binding = connections[presentation.id] as? VNCSessionBinding else { return }
        binding.recoveryCancel = LinuxSetup.probe(tunnel: engine.tunnel, script: script) { [weak self, weak engine, weak presentation] result in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, let engine, let presentation, preflight?.cancelled != true,
                      let current = self.connections[presentation.id] as? VNCSessionBinding, current.engine === engine,
                      case .success(let probe) = result, probe.circe.installed, probe.circe.display == original.display,
                      engine.state != .streaming else { return }
                // Never change a desktop chosen from the existing-desktops list or another account's server.
                presentation.notice = SessionNotice(title: "Restore this desktop’s sign-in",
                    message: "Circe couldn’t use its saved desktop password. Repair this desktop’s setup and save a new password securely on this Mac. Other viewers of this Circe desktop may disconnect.",
                    actionTitle: "Repair & reconnect", action: { [weak self, weak current, weak engine, weak presentation] in
                        guard let self, let current, let engine, let presentation, preflight?.cancelled != true,
                              (self.connections[presentation.id] as? VNCSessionBinding)?.engine === engine else { return }
                        let latest = self.model.computers.first { $0.id == original.id } ?? original
                        guard tunnel(for: latest) == engine.tunnel else { return }
                        presentation.notice = nil
                        presentation.phase = .connecting
                        presentation.connectingDetail = "Restoring this desktop’s sign-in…"
                        // Suppress the intentional clean close while the replacement password is generated.
                        current.suppressState = true
                        engine.disconnect()
                        self.setUp(latest, withoutAdmin: probe.withoutAdmin == true && probe.sudo != "passwordless" && probe.sudo != "root",
                                   resetPassword: true) { [weak self, weak current, weak engine, weak presentation] result in
                            guard let self, let current, let engine, let presentation, preflight?.cancelled != true,
                                  (self.connections[presentation.id] as? VNCSessionBinding)?.engine === engine else { return }
                            current.suppressState = false
                            switch result {
                            case .success(let updated):
                                do { try self.model.saveComputer(updated) }
                                catch { presentation.phase = .disconnected(error.localizedDescription); return }
                                presentation.connectingDetail = nil
                                // Disconnect clears the old client's handshake, but may retain its credentials.
                                // Rebuild against the freshly saved password and preserve the same session window.
                                current.detach(); self.connections.removeValue(forKey: presentation.id)
                                self.attachVNC(updated.id, fallback: updated, presentation: presentation, preflight: preflight,
                                               rerun: presentation.onReconnect)
                            case .failure(let error): presentation.phase = .disconnected(String(describing: error))
                            }
                        }
                    })
                presentation.phase = .connecting
            } }
        }
    }

    /// Before connecting a saved Google Cloud computer: make sure its account is signed in, that it's the same
    /// machine Circe verified, and that it's running (starting it only with consent, or automatically when the
    /// user chose that for this computer), then wait for SSH. Every step stops if the session is closed.
    func prepareCloudConnection(_ id: UUID, presentation: RemoteSession, preflight: CloudPreflight, then connect: @escaping () -> Void) {
        guard !preflight.cancelled else { return }
        guard let computer = model.computers.first(where: { $0.id == id }),
              case let .googleCloud(name, zone, .some(project), _, .some(account), _, savedAlias, _) = computer.connection else { connect(); return }
        func retry() {
            guard !preflight.cancelled else { return }
            presentation.notice = nil; presentation.phase = .connecting
            prepareCloudConnection(id, presentation: presentation, preflight: preflight, then: connect)
        }
        presentation.notice = nil
        presentation.connectingDetail = "Checking your Google sign-in…"
        inBackground({ try GoogleCloud.credential(for: account) }) { [weak self] result in
            guard let self, !preflight.cancelled else { return }
            switch result {
            case .success(.valid): break
            case .success:
                presentation.notice = SessionNotice(title: "Sign in to Google", message: "Google needs you to sign in again as \(account) to reach \(name).",
                                                    actionTitle: "Sign in with Google", action: { [weak self] in
                    self?.signInAgain(account: account, name: name, presentation: presentation, preflight: preflight, retry: retry)
                })
                return
            case .failure(let error) where error.kind == .cliMissing:
                presentation.notice = SessionNotice(title: "Google Cloud tools are missing",
                                                    message: "Circe needs Google’s command-line tools to reach \(name). It can download its own copy (about 150 MB); nothing else on this Mac changes.",
                                                    actionTitle: "Install tools", action: {
                    guard !preflight.cancelled else { return }
                    presentation.notice = nil; presentation.connectingDetail = "Downloading Google Cloud tools…"
                    let cancel = preflight.token()
                    inBackground({ try GoogleCloudInstaller.install(cancel: cancel) { _ in } }) { installed in
                        guard !preflight.cancelled else { return }
                        if case let .failure(error) = installed {
                            presentation.connectingDetail = nil
                            presentation.notice = SessionNotice(title: "The tools didn’t install", message: error.message, actionTitle: "Try again", action: retry)
                        } else { retry() }
                    }
                })
                return
            case .failure(let error):
                presentation.notice = SessionNotice(title: "Can’t reach Google", message: error.message, actionTitle: "Try again", action: retry)
                return
            }
            presentation.connectingDetail = "Checking \(name)…"
            inBackground({ try GoogleCloud.instance(account: account, project: project, zone: zone, name: name) }) { [weak self] described in
                guard let self, !preflight.cancelled else { return }
                switch described {
                case .success(let instance):
                    // A VM deleted and created again under the same name has a new ID: never treat it as the old one.
                    let alias = instance.hostKeyAlias(project: project)
                    if let savedAlias, savedAlias.range(of: "^circe-gce-[0-9]+$", options: .regularExpression) != nil, savedAlias != alias {
                        presentation.notice = SessionNotice(title: "\(name) was replaced",
                            message: "Google Cloud has a new computer named \(name) — the one Circe set up was deleted and created again. Circe won’t send it your saved desktop password or start it automatically until you confirm it’s yours.",
                            actionTitle: "Use the new computer", action: { [weak self] in
                                guard let self, var saved = self.model.computers.first(where: { $0.id == id }),
                                      case let .googleCloud(i, z, p, iap, a, u, _, key) = saved.connection else { return }
                                VNCSession.forgetPassword(for: tunnel(for: saved))
                                saved.connection = .googleCloud(instance: i, zone: z, project: p, useIAP: iap, account: a, user: u, hostKeyAlias: alias, keyFile: key)
                                // Nothing that was agreed for or learned about the old machine carries over.
                                saved.startsWhenConnecting = false; saved.microphoneEnabled = false; saved.startsDesktopOnConnect = false
                                try? self.model.saveComputer(saved)
                                retry()
                            })
                        return
                    }
                    if instance.isRunning { self.ensureDesktop(computer, presentation: presentation, preflight: preflight, retry: retry, then: connect); return }
                    if instance.canStart {
                        let start = { [weak self] (remember: Bool) in
                            guard let self, !preflight.cancelled else { return }
                            if remember, var saved = self.model.computers.first(where: { $0.id == id }) { saved.startsWhenConnecting = true; try? self.model.saveComputer(saved) }
                            presentation.notice = nil
                            self.startThenConnect(instance, account: account, project: project, presentation: presentation, preflight: preflight, connect: connect, retry: retry)
                        }
                        if computer.startsWhenConnecting { start(false); return }
                        let gpu = instance.gpu.map { "It has an \($0) GPU. " } ?? ""
                        presentation.notice = SessionNotice(
                            title: "\(name) is \(instance.status == "SUSPENDED" ? "suspended" : "stopped")",
                            message: "\(gpu)Starting it begins Google Cloud charges until it’s stopped again — closing Circe doesn’t stop it.",
                            actionTitle: instance.status == "SUSPENDED" ? "Resume computer" : "Start computer", action: { start(false) },
                            secondaryTitle: "Start, and don’t ask again", secondary: { start(true) })
                        return
                    }
                    // Shutting down, starting or being repaired: watch (read-only), then decide again.
                    presentation.connectingDetail = GoogleCloudSetup.describe(power: instance.status, name: name)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { MainActor.assumeIsolated { retry() } }
                case .failure(let error) where { if case .permissionDenied = error.kind { return true }; return false }():
                    // Can't read its state; the connection itself may still work (and may need the desktop started).
                    self.ensureDesktop(computer, presentation: presentation, preflight: preflight, retry: retry, then: connect)
                case .failure(let error):
                    presentation.notice = SessionNotice(title: error.kind == .notFound ? "Circe can’t find \(name)" : "Can’t check \(name)",
                                                        message: error.kind == .notFound ? "It may have been deleted or moved. Check it in Google Cloud." : error.message,
                                                        actionTitle: "Try again", action: retry)
                }
            }
        }
    }

    /// Signing in again from a saved computer: the browser opens; while it's open the session offers to show
    /// Google's page again (a closed tab is the usual way this gets stuck) or to use a code instead (when the
    /// browser can't hand the sign-in back to this Mac). The code goes only to the waiting gcloud.
    private func signInAgain(account: String, name: String, presentation: RemoteSession, preflight: CloudPreflight,
                             retry: @escaping () -> Void, useCode: Bool = false) {
        guard !preflight.cancelled else { return }
        let cancel = preflight.token(), channel = GoogleCloud.SignInChannel()
        let page = PageBox()
        let again: (Bool) -> Void = { [weak self] code in
            self?.signInAgain(account: account, name: name, presentation: presentation, preflight: preflight, retry: retry, useCode: code)
        }
        presentation.connectingDetail = nil
        if useCode {
            presentation.notice = SessionNotice(title: "Enter the code from Google",
                message: "Sign in as \(account) on Google’s page, then enter the verification code it shows.",
                actionTitle: "Enter code…", action: { if let code = Self.askForSignInCode(account: account) { channel.submit(code) } },
                secondaryTitle: "Open Google’s page", secondary: { if let url = page.url { NSWorkspace.shared.open(url) } })
        } else {
            presentation.notice = SessionNotice(title: "Finish signing in in your browser",
                message: "Sign in as \(account). If you closed the page, open it again.",
                actionTitle: "Open Google again", action: { if let url = page.url { NSWorkspace.shared.open(url) } },
                secondaryTitle: "Use a code instead", secondary: { cancel.cancel(); again(true) })
        }
        inBackground({ try GoogleCloud.signIn(hint: account, useCode: useCode, cancel: cancel, channel: channel) { event in
            // With a code, gcloud doesn't open the browser itself.
            if case let .page(url) = event { DispatchQueue.main.async { page.url = url; if useCode { NSWorkspace.shared.open(url) } } }
        } }) { signed in
            guard !preflight.cancelled, !cancel.isCancelled else { return }
            if case let .success(actual) = signed, actual.caseInsensitiveCompare(account) == .orderedSame { presentation.notice = nil; retry(); return }
            presentation.notice = SessionNotice(title: "Sign-in didn’t finish",
                message: { if case let .success(actual) = signed { return "You signed in as \(actual), but \(name) uses \(account). Sign in again and pick \(account)." }
                           if case let .failure(error) = signed { return error.message }; return "" }(),
                actionTitle: "Try again", action: { again(false) }, secondaryTitle: "Use a code", secondary: { again(true) })
        }
    }

    /// A one-line secure prompt for Google's verification code. Never stored.
    private static func askForSignInCode(account: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Enter the code from Google"
        alert.informativeText = "After signing in as \(account), Google shows a verification code. Paste it here."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Verification code"
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let code = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty || code.contains(where: \.isNewline) ? nil : code
    }

    /// A desktop set up without lingering stopped when its last connection ended: start it and hold a session
    /// open for as long as this window is connected. Failure or cancellation never leads to a VNC attempt.
    private func ensureDesktop(_ computer: SavedComputer, presentation: RemoteSession, preflight: CloudPreflight,
                               retry: @escaping () -> Void, then connect: @escaping () -> Void) {
        guard computer.startsDesktopOnConnect else { presentation.connectingDetail = nil; connect(); return }
        if let lease = desktopLeases[presentation.id], lease.isActive { presentation.connectingDetail = nil; connect(); return }
        presentation.connectingDetail = "Starting the desktop on \(computer.name)…"
        let route = tunnel(for: computer), cancel = preflight.token()
        inBackground({ LinuxSetup.startDesktop(tunnel: route, cancel: cancel) }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.success(let lease)):
                guard !preflight.cancelled else { lease.end(); return }
                self.hold(lease, for: computer, presentation: presentation, preflight: preflight)
                presentation.connectingDetail = nil; connect()
            case .success(.failure(let failure)):
                guard !preflight.cancelled else { return }
                presentation.connectingDetail = nil
                presentation.notice = SessionNotice(title: "The desktop on \(computer.name) didn’t start", message: failure.description,
                                                    actionTitle: "Try again", action: retry)
            case .failure(let error):
                guard !preflight.cancelled else { return }
                presentation.connectingDetail = nil
                presentation.notice = SessionNotice(title: "The desktop on \(computer.name) didn’t start", message: error.message, actionTitle: "Try again", action: retry)
            }
        }
    }

    /// Keeps the lease for this window. If it's lost (network drop, the computer restarting), Circe quietly starts
    /// the desktop again and takes a new lease, so the VNC connection's own reconnect finds a running desktop.
    private func hold(_ lease: LinuxSetup.DesktopLease, for computer: SavedComputer, presentation: RemoteSession, preflight: CloudPreflight) {
        desktopLeases.removeValue(forKey: presentation.id)?.end()
        desktopLeases[presentation.id] = lease
        lease.onLost { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.renew(lost: lease, computer: computer, presentation: presentation, preflight: preflight, attempt: 0) } }
        }
    }

    private func renew(lost: LinuxSetup.DesktopLease, computer: SavedComputer, presentation: RemoteSession, preflight: CloudPreflight, attempt: Int) {
        guard !preflight.cancelled, desktopLeases[presentation.id] === lost, attempt < 120 else { return }
        let route = tunnel(for: model.computers.first(where: { $0.id == computer.id }) ?? computer), cancel = preflight.token()
        inBackground({ LinuxSetup.startDesktop(tunnel: route, cancel: cancel) }) { [weak self] result in
            guard let self, !preflight.cancelled, self.desktopLeases[presentation.id] === lost else {
                if case let .success(.success(lease)) = result { lease.end() }
                return
            }
            if case let .success(.success(lease)) = result { self.hold(lease, for: computer, presentation: presentation, preflight: preflight); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { MainActor.assumeIsolated {
                self.renew(lost: lost, computer: computer, presentation: presentation, preflight: preflight, attempt: attempt + 1)
            } }
        }
    }

    private func startThenConnect(_ instance: GoogleCloud.Instance, account: String, project: String, presentation: RemoteSession,
                                  preflight: CloudPreflight, connect: @escaping () -> Void, retry: @escaping () -> Void) {
        let cancel = preflight.token()
        presentation.connectingDetail = "Starting \(instance.name)… This usually takes under a minute."
        inBackground({ try GoogleCloud.start(instance, account: account, project: project, cancel: cancel) { state in
            DispatchQueue.main.async { MainActor.assumeIsolated { presentation.connectingDetail = GoogleCloudSetup.describe(power: state, name: instance.name) } }
        } }) { result in
            guard !preflight.cancelled else { return }
            switch result {
            case .success:
                presentation.connectingDetail = "Waiting for \(instance.name) to finish starting…"
                // After SSH answers, the full check runs again (sign-in, same machine, running) before connecting.
                let connect = retry
                func wait(_ left: Int) {
                    guard !preflight.cancelled else { return }
                    inBackground({ try GoogleCloud.checkTunnel(account: account, project: project, zone: instance.zone, instance: instance.name) }) { check in
                        guard !preflight.cancelled else { return }
                        if case .success(.reachable) = check { presentation.connectingDetail = nil; connect() }
                        else if left > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 5) { MainActor.assumeIsolated { wait(left - 1) } } }
                        else { presentation.connectingDetail = nil; connect() }
                    }
                }
                wait(18)
            case .failure(let error) where error.kind == .replaced: retry() // shows the replacement review
            case .failure(let error):
                presentation.notice = SessionNotice(title: "\(instance.name) didn’t start", message: error.message, actionTitle: "Try again", action: retry)
            }
        }
    }
}

/// The sign-in page gcloud opened, kept so it can be shown again.
final class PageBox: @unchecked Sendable { var url: URL? }

/// Whether a password reported early by the installer reached the Keychain.
final class SavedFlag: @unchecked Sendable { enum State { case none, saved, failed }; var value: State = .none }

/// One session's pre-connect work. Closing the session cancels it: nothing it scheduled runs afterwards,
/// and running gcloud calls are stopped (a start Google already accepted can't be taken back). Main thread only.
final class CloudPreflight: @unchecked Sendable {
    private(set) var cancelled = false
    private var tokens: [GoogleCloud.CancelToken] = []
    func token() -> GoogleCloud.CancelToken {
        let token = GoogleCloud.CancelToken()
        if cancelled { token.cancel() } else { tokens.append(token) }
        return token
    }
    func cancel() { cancelled = true; tokens.forEach { $0.cancel() }; tokens.removeAll() }
}

private func tunnel(for computer: SavedComputer) -> RFBTunnel {
    switch computer.connection {
    case let .googleCloud(instance, zone, project, iap, account, user, alias, keyFile):
        if iap, let project, let account, let user, let alias {
            return .iap(instance: instance, zone: zone, project: project, account: account, user: user, hostKeyAlias: alias, vncPort: computer.vncPort, identity: keyFile)
        }
        return .gcloud(instance: instance, zone: zone, project: project, useIAP: iap, vncPort: computer.vncPort, account: account, user: user)
    case let .ssh(destination, port): return .ssh(destination: destination, port: port, vncPort: computer.vncPort)
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
