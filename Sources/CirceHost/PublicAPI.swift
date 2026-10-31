import CirceCore
import Combine
import Foundation
import Network

/// A client currently connected to this Mac.
public struct ConnectedClient: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let deviceID: String
    public let isStreaming: Bool
    public let connectedAt: Date
}

/// "Allow others to connect to this Mac." Advertises over Bonjour and serves Circe sessions.
@MainActor
public final class HostService: ObservableObject {
    public static let shared = HostService()

    @Published public private(set) var isRunning = false
    /// 6-digit code to show while an unpaired device is trying to connect; nil otherwise.
    @Published public private(set) var pairingPIN: String?
    @Published public private(set) var clients: [ConnectedClient] = []
    @Published public private(set) var lastError: String?
    @Published public private(set) var port: UInt16?
    /// Allow first-time connections with this Mac's account name + password (in addition to the PIN).
    @Published public var allowPasswordAuth = true {
        didSet { policy.allowPassword = allowPasswordAuth }
    }

    public var trustedDevices: [TrustStore.Peer] { policy.trust.all.sorted { $0.name < $1.name } }
    public var fingerprint: String { keyFingerprint(policy.identity.publicKey) }

    private let policy: HostPolicy
    private let preferredPort: UInt16
    private let serviceName: String?
    private var listener: NWListener?
    private var sessions: [UUID: HostSession] = [:]
    private var connectedAt: [UUID: Date] = [:]
    private var pinRequests = Set<UUID>()
    private let listenerQueue = DispatchQueue(label: "circe.host.listener")
    private var cursor: CursorMonitor?
    private var clipboard: ClipboardSync?

    /// - Parameters:
    ///   - allowUnauthenticated: accept anyone without pairing (tests / explicit opt-in only).
    public init(identity: DeviceIdentity = .loadOrCreate(),
                trust: TrustStore = TrustStore(name: "trusted-clients.json"),
                port: UInt16 = circeDefaultPort,
                serviceName: String? = nil,
                allowUnauthenticated: Bool = false) {
        policy = HostPolicy(identity: identity, trust: trust, allowUnauthenticated: allowUnauthenticated)
        preferredPort = port
        self.serviceName = serviceName
    }

    /// Stream generated test frames instead of the screen (tests / no Screen Recording permission).
    public var syntheticCapture: Bool {
        get { policy.syntheticCapture }
        set { policy.syntheticCapture = newValue }
    }

    public func start() {
        guard listener == nil else { return }
        lastError = nil
        do {
            let l: NWListener
            if let p = NWEndpoint.Port(rawValue: preferredPort), let fixed = try? NWListener(using: FramedConnection.parameters(), on: p) {
                l = fixed
            } else {
                l = try NWListener(using: FramedConnection.parameters())
            }
            let txt = NWTXTRecord(["id": policy.identity.deviceID, "model": MachineInfo.modelIdentifier, "v": "\(circeProtocolVersion)"])
            l.service = NWListener.Service(name: serviceName ?? MachineInfo.computerName, type: circeBonjourType,
                                           domain: nil, txtRecord: txt)
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerState(state) }
            }
            l.newConnectionHandler = { [weak self] c in
                Task { @MainActor in self?.accept(c) }
            }
            l.start(queue: listenerQueue)
            listener = l
        } catch {
            lastError = "Couldn't start sharing: \(error.localizedDescription)"
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for s in sessions.values { s.close(reason: "This Mac stopped sharing") }
        isRunning = false
        port = nil
        stopPeripherals()
    }

    public func disconnect(_ id: UUID) { sessions[id]?.close(reason: "Disconnected by host") }

    public func forgetDevice(_ deviceID: String) {
        policy.trust.forget(deviceID: deviceID)
        objectWillChange.send()
    }

    private func listenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            port = listener?.port?.rawValue
        case .failed(let e):
            lastError = "Sharing failed: \(e.localizedDescription)"
            listener?.cancel()
            listener = nil
            isRunning = false
        case .cancelled:
            isRunning = false
        default: break
        }
    }

    private func accept(_ c: NWConnection) {
        let s = HostSession(connection: c, policy: policy)
        sessions[s.id] = s
        connectedAt[s.id] = Date()
        s.onStateChange = { [weak self] _ in Task { @MainActor in self?.publishClients() } }
        s.onNeedsPIN = { [weak self, id = s.id] needs in Task { @MainActor in self?.pinNeeded(id, needs) } }
        s.onClosed = { [weak self, id = s.id] _, _ in Task { @MainActor in self?.closed(id) } }
        s.onClipboard = { [weak self] p in Task { @MainActor in self?.clipboard?.apply(p) } }
        s.onStreamingStarted = { [weak self] _ in Task { @MainActor in self?.startPeripherals(); self?.cursor?.resend() } }
        s.start()
        publishClients()
    }

    private func pinNeeded(_ id: UUID, _ needs: Bool) {
        if needs { pinRequests.insert(id) } else { pinRequests.remove(id) }
        if pinRequests.isEmpty {
            pairingPIN = nil
        } else if pairingPIN == nil {
            pairingPIN = generatePairingPIN()
        }
        policy.pin = pairingPIN
    }

    private func closed(_ id: UUID) {
        sessions[id] = nil
        connectedAt[id] = nil
        pinNeeded(id, false)
        publishClients()
        if !sessions.values.contains(where: { $0.isStreaming }) { stopPeripherals() }
    }

    private func publishClients() {
        clients = sessions.values.map {
            ConnectedClient(id: $0.id, name: $0.peerName, deviceID: $0.peerID, isStreaming: $0.isStreaming,
                            connectedAt: connectedAt[$0.id] ?? Date())
        }.sorted { $0.connectedAt < $1.connectedAt }
    }

    private func startPeripherals() {
        if cursor == nil {
            let c = CursorMonitor()
            c.onShape = { [weak self] shape in
                guard let self else { return }
                for s in self.sessions.values where s.isStreaming { s.sendCursor(shape) }
            }
            c.start()
            cursor = c
        }
        if clipboard == nil {
            let cb = ClipboardSync()
            cb.onLocalChange = { [weak self] p in
                guard let self else { return }
                for s in self.sessions.values where s.isStreaming { s.sendClipboard(p) }
            }
            cb.start()
            clipboard = cb
        }
    }

    private func stopPeripherals() {
        cursor?.stop(); cursor = nil
        clipboard?.stop(); clipboard = nil
    }
}
