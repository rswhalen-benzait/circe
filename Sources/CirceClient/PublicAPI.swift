import AppKit
import CirceCore
import Combine
import CryptoKit
import Foundation
import Network

public enum ClientState: Equatable, Sendable {
    case idle
    case connecting
    /// Host doesn't know us yet: ask the user for the PIN shown on the host, or the host's account password.
    case authenticating(methods: [AuthMethod], error: String?)
    case streaming
    /// Network dropped; retrying automatically with the paired key (no prompt).
    case reconnecting(attempt: Int)
    case disconnected(reason: String?)
}

public struct SessionStats: Equatable, Sendable {
    public var fps: Double = 0
    public var bitrateMbps: Double = 0
    /// Host capture -> client receive (encode + network), smoothed.
    public var latencyMs: Double = 0
    public var roundTripMs: Double = 0
    public var codec: String = ""
    public var resolution: String = ""
    public init() {}
}

/// One remote desktop session. Create, call `connect()`, embed `displayView`.
@MainActor
public final class ClientSession: ObservableObject, Identifiable {
    public let id = UUID()
    public let endpoint: NWEndpoint
    @Published public private(set) var hostName: String
    @Published public private(set) var state: ClientState = .idle
    @Published public private(set) var stats = SessionStats()
    @Published public private(set) var displays: [DisplayDescriptor] = []
    @Published public private(set) var currentDisplay: DisplayDescriptor?
    @Published public private(set) var hostFingerprint: String?
    @Published public private(set) var config: StreamConfig

    @Published public var clipboardSyncEnabled = true { didSet { updateClipboard() } }
    @Published public var audioMuted = false { didSet { link.setMuted(audioMuted) } }
    /// Resize the remote Mac's display to fit this window (like Screen Sharing's dynamic resolution).
    @Published public var matchesWindowResolution = false { didSet { sendViewport(displayView.bounds.size) } }

    /// The remote screen. Put it in a window; it handles all input.
    public let displayView = SessionDisplayView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))

    private let link: Link
    private var userClosed = false
    private var reconnectAttempt = 0
    private var wasStreaming = false
    private var clipboard: ClipboardSync?
    private var statsTimer: Timer?
    private var hasFocus = false
    private var pendingClipboard: ClipboardPayload?

    public init(endpoint: NWEndpoint, name: String, config: StreamConfig = StreamConfig(),
                identity: DeviceIdentity = .loadOrCreate(), trust: TrustStore = TrustStore(name: "trusted-hosts.json")) {
        self.endpoint = endpoint
        self.hostName = name
        self.config = config
        self.link = Link(endpoint: endpoint, identity: identity, trust: trust, renderer: displayView.renderer)
        link.session = self
        displayView.onInput = { [weak self] e in self?.link.send(.input(e)) }
        displayView.localCursor = config.localCursor
        displayView.onSettledResize = { [weak self] size in self?.sendViewport(size) }
        displayView.onDropFiles = { [weak self] urls in self?.sendFiles(urls) }
        displayView.onFocusChange = { [weak self] focused in
            guard let self else { return }
            self.hasFocus = focused
            if focused, let p = self.pendingClipboard, self.clipboardSyncEnabled, self.state == .streaming {
                self.pendingClipboard = nil
                self.link.send(.clipboard(p))
            }
        }
        displayView.onVisibilityChange = { [weak self] visible in
            guard let self, self.config.videoPaused != !visible else { return }
            self.update { $0.videoPaused = !visible }
        }
    }

    private func sendViewport(_ size: CGSize) {
        guard state == .streaming || state == .connecting else { return }
        update {
            $0.matchResolution = matchesWindowResolution
            $0.viewportPointWidth = matchesWindowResolution ? Double(size.width) : nil
            $0.viewportPointHeight = matchesWindowResolution ? Double(size.height) : nil
        }
    }

    public convenience init(host: DiscoveredHost, config: StreamConfig = StreamConfig()) {
        self.init(endpoint: host.endpoint, name: host.name, config: config)
    }

    /// "studio.local", "10.0.0.2:47800", "circe://host" …
    public convenience init?(address: String, config: StreamConfig = StreamConfig()) {
        guard let ep = parseEndpoint(address) else { return nil }
        self.init(endpoint: ep, name: address, config: config)
    }

    public func connect() {
        userClosed = false
        reconnectAttempt = 0
        state = .connecting
        link.open(config: config)
        startStatsTimer()
    }

    public func submitPIN(_ pin: String) {
        link.send(.auth(AuthRequest(method: .pin, pin: pin.filter(\.isNumber))))
        state = .connecting
    }

    public func submitPassword(username: String, password: String) {
        link.send(.auth(AuthRequest(method: .password, username: username, password: password)))
        state = .connecting
    }

    public func disconnect() {
        userClosed = true
        link.close(reason: "Client disconnected")
        finish(reason: nil)
    }

    public func update(_ change: (inout StreamConfig) -> Void) {
        var c = config
        change(&c)
        guard c != config else { return }
        config = c
        displayView.localCursor = c.localCursor
        link.send(.configure(c))
    }

    public func selectDisplay(_ id: UInt32) { update { $0.displayID = id } }
    public func setQuality(_ q: QualityPreset) { update { $0.quality = q } }
    public func setAudioEnabled(_ on: Bool) { update { $0.audioEnabled = on } }

    /// Grab ⌘-Tab etc. for the remote Mac while focused (requires Accessibility for Circe).
    public var capturesSystemShortcuts: Bool {
        get { displayView.capturesSystemShortcuts }
        set { displayView.capturesSystemShortcuts = newValue }
    }

    /// Return keyboard/mouse to this Mac; clicking the remote screen captures again.
    public func releaseInput() { displayView.releaseInput() }
    public func captureInput() { displayView.captureInput() }

    /// Copy files to the remote Mac's Downloads folder (also triggered by dragging onto `displayView`).
    public func sendFiles(_ urls: [URL]) { link.sendFiles(urls) }

    /// Ask the host for a fresh full frame (e.g. after visual corruption).
    public func refresh() { link.send(.requestKeyframe) }

    // MARK: Link callbacks (main thread)

    fileprivate func linkServerHello(_ sh: ServerHello) {
        hostName = sh.deviceName
        hostFingerprint = keyFingerprint(sh.staticKey)
    }

    fileprivate func linkNeedsAuth(methods: [AuthMethod], error: String?) {
        state = .authenticating(methods: methods, error: error)
    }

    fileprivate func linkStreamStart(_ s: StreamStart) {
        displays = s.displays
        currentDisplay = s.display
        displayView.remoteSize = CGSize(width: s.display.pointWidth, height: s.display.pointHeight)
        stats.codec = s.codec == .hevc ? "HEVC" : "H.264"
        stats.resolution = "\(s.encodedWidth)×\(s.encodedHeight)"
        state = .streaming
        wasStreaming = true
        reconnectAttempt = 0
        updateClipboard()
    }

    fileprivate func linkCursor(_ c: CursorShape) { displayView.setCursorShape(c) }

    fileprivate func linkClipboard(_ p: ClipboardPayload) {
        guard clipboardSyncEnabled else { return }
        clipboard?.apply(p)
    }

    fileprivate func linkClosed(reason: String?, deliberate: Bool) {
        guard !userClosed else { return }
        // Transparent recovery from Wi-Fi blips / sleep: paired sessions reconnect without a prompt.
        if wasStreaming && !deliberate && reconnectAttempt < 8 {
            reconnectAttempt += 1
            state = .reconnecting(attempt: reconnectAttempt)
            let delay = min(0.25 * pow(2, Double(reconnectAttempt - 1)), 8)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.userClosed else { return }
                self.link.open(config: self.config)
            }
            return
        }
        finish(reason: reason ?? "The connection was lost.")
    }

    private func finish(reason: String?) {
        state = .disconnected(reason: reason)
        clipboard?.stop()
        clipboard = nil
        statsTimer?.invalidate()
        statsTimer = nil
    }

    private func updateClipboard() {
        if clipboardSyncEnabled && state == .streaming {
            guard clipboard == nil else { return }
            let c = ClipboardSync()
            // Only hand our clipboard to the remote Mac while the user is working in it,
            // so copying a password elsewhere doesn't leak it. Latest copy is sent on focus.
            c.onLocalChange = { [weak self] p in
                guard let self else { return }
                if self.hasFocus { self.link.send(.clipboard(p)) } else { self.pendingClipboard = p }
            }
            c.start()
            clipboard = c
        } else {
            clipboard?.stop()
            clipboard = nil
        }
    }

    private func startStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.link.ping()
                let s = self.link.snapshot()
                self.stats.fps = s.fps
                self.stats.bitrateMbps = s.bitrateMbps
                self.stats.latencyMs = s.latencyMs
                self.stats.roundTripMs = s.rttMs
            }
        }
    }
}

// MARK: - Network side (runs on its own queue)

private final class Link: @unchecked Sendable {
    let endpoint: NWEndpoint
    let identity: DeviceIdentity
    let trust: TrustStore
    let renderer: VideoRenderer
    weak var session: ClientSession?

    private let queue = DispatchQueue(label: "circe.client.link", qos: .userInteractive)
    private var conn: FramedConnection?
    private var ephemeral = Curve25519.KeyAgreement.PrivateKey()
    private var hello: ClientHello?
    private var serverHello: ServerHello?
    private var config = StreamConfig()
    private var audio: AudioPlayer?
    private var muted = false
    private var deliberateClose = false
    private var goodbyeReason: String?

    // Stats (queue-confined)
    private var fpsMeter = RateMeter()
    private var bytesMeter = RateMeter()
    private var clockOffset: Double?
    private var latencyEMA: Double = 0
    private var rttEMA: Double = 0
    private var pingID: UInt32 = 0
    private var lastKeyframeRequest: UInt64 = 0

    struct Snapshot { var fps: Double; var bitrateMbps: Double; var latencyMs: Double; var rttMs: Double }

    init(endpoint: NWEndpoint, identity: DeviceIdentity, trust: TrustStore, renderer: VideoRenderer) {
        self.endpoint = endpoint
        self.identity = identity
        self.trust = trust
        self.renderer = renderer
        renderer.onNeedKeyframe = { [weak self] in self?.requestKeyframeThrottled() }
    }

    private func main(_ f: @escaping @MainActor (ClientSession) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let s = self?.session else { return }
            MainActor.assumeIsolated { f(s) }
        }
    }

    func open(config: StreamConfig) {
        queue.async { [self] in
            conn?.onClose = nil
            conn?.close()
            self.config = config
            deliberateClose = false
            goodbyeReason = nil
            serverHello = nil
            clockOffset = nil
            ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let c = FramedConnection(connection: NWConnection(to: endpoint, using: FramedConnection.parameters()), queue: queue)
            conn = c
            c.onReady = { [weak self, weak c] in
                guard let self, let c else { return }
                let h = ClientHello(version: circeProtocolVersion, deviceID: identity.deviceID,
                                    deviceName: MachineInfo.computerName, staticKey: identity.publicKey,
                                    ephemeralKey: ephemeral.publicKey.rawRepresentation)
                hello = h
                c.send(.clientHello(h))
            }
            c.onMessage = { [weak self] m in self?.handle(m) }
            c.onClose = { [weak self] err in self?.closed(err) }
            c.start()
        }
    }

    func close(reason: String) {
        queue.async { [self] in
            deliberateClose = true
            conn?.onClose = nil
            conn?.close(goodbye: reason)
            conn = nil
            stopAudio()
            renderer.flush()
        }
    }

    func send(_ m: Message) {
        queue.async { [self] in
            if case .configure(let c) = m { config = c }
            conn?.send(m)
        }
    }

    private var nextFileID: UInt32 = 0

    /// Streams files in 256 KB chunks, yielding to video whenever the socket has a backlog.
    func sendFiles(_ urls: [URL]) {
        queue.async { [self] in
            for url in urls {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      (attrs[.type] as? FileAttributeType) == .typeRegular,
                      let size = (attrs[.size] as? NSNumber)?.uint64Value,
                      let handle = try? FileHandle(forReadingFrom: url) else { continue }
                nextFileID &+= 1
                let id = nextFileID
                conn?.send(.fileBegin(id: id, name: url.lastPathComponent, size: size))
                pump(id: id, handle: handle)
            }
        }
    }

    private func pump(id: UInt32, handle: FileHandle) {
        guard let conn else { try? handle.close(); return }
        if conn.pendingSendBytes > 2 << 20 {
            queue.asyncAfter(deadline: .now() + 0.005) { [weak self] in self?.pump(id: id, handle: handle) }
            return
        }
        let data = (try? handle.read(upToCount: 256 << 10)) ?? Data()
        if data.isEmpty {
            try? handle.close()
            conn.send(.fileEnd(id: id, cancelled: false))
            return
        }
        conn.send(.fileChunk(id: id, data: data))
        queue.async { [weak self] in self?.pump(id: id, handle: handle) }
    }

    func setMuted(_ m: Bool) { queue.async { [self] in muted = m; audio?.setMuted(m) } }

    func ping() {
        queue.async { [self] in
            guard serverHello != nil else { return }
            pingID &+= 1
            conn?.send(.ping(id: pingID, sentMicros: Clock.micros()))
        }
    }

    func snapshot() -> Snapshot {
        queue.sync {
            Snapshot(fps: fpsMeter.rate(), bitrateMbps: bytesMeter.rate() * 8 / 1_000_000,
                     latencyMs: latencyEMA, rttMs: rttEMA)
        }
    }

    private func requestKeyframeThrottled() {
        let now = Clock.micros()
        guard now &- lastKeyframeRequest > 250_000 else { return }
        lastKeyframeRequest = now
        conn?.send(.requestKeyframe)
    }

    private func handle(_ m: Message) {
        switch m {
        case .serverHello(let sh): handleServerHello(sh)
        case .authResult(let r):
            if r.ok {
                if let sh = serverHello { trust.trust(deviceID: sh.deviceID, name: sh.deviceName, key: sh.staticKey) }
                conn?.send(.configure(config))
            } else if r.retryMethods.isEmpty {
                deliberateClose = true
                goodbyeReason = r.reason
            } else {
                main { $0.linkNeedsAuth(methods: r.retryMethods, error: r.reason) }
            }
        case .streamStart(let s):
            renderer.reset(codec: s.codec)
            stopAudio()
            if let fmt = s.audio {
                let a = AudioPlayer(format: fmt)
                a.start()
                a.setMuted(muted)
                audio = a
            }
            main { $0.linkStreamStart(s) }
        case .video(let f):
            fpsMeter.add()
            bytesMeter.add(Double(f.data.count))
            if let off = clockOffset {
                let lat = (Double(Clock.micros()) + off - Double(f.captureMicros)) / 1000
                if lat > -50 && lat < 5000 { latencyEMA = latencyEMA == 0 ? lat : latencyEMA * 0.9 + lat * 0.1 }
            }
            renderer.display(f)
        case .audio(let a):
            bytesMeter.add(Double(a.data.count))
            audio?.enqueue(a)
        case .cursorShape(let c): main { $0.linkCursor(c) }
        case .clipboard(let p): main { $0.linkClipboard(p) }
        case let .pong(_, sent, peer):
            let now = Clock.micros()
            let rtt = Double(now &- sent)
            // Host clock minus ours, assuming a symmetric path.
            let off = Double(peer) - (Double(sent) + rtt / 2)
            clockOffset = clockOffset.map { $0 * 0.8 + off * 0.2 } ?? off
            rttEMA = rttEMA == 0 ? rtt / 1000 : rttEMA * 0.8 + rtt / 1000 * 0.2
        case .ping(let id, let t):
            conn?.send(.pong(id: id, sentMicros: t, peerMicros: Clock.micros()))
        case .goodbye(let g):
            deliberateClose = true
            goodbyeReason = g.reason
            conn?.close()
        default:
            break
        }
    }

    private func handleServerHello(_ sh: ServerHello) {
        guard let hello, sh.version == circeProtocolVersion else {
            deliberateClose = true
            goodbyeReason = "This Mac runs an incompatible version of Circe."
            conn?.close(); return
        }
        if let known = trust.peer(sh.deviceID), known.publicKey != sh.staticKey {
            deliberateClose = true
            goodbyeReason = "\(sh.deviceName)'s identity has changed. If you reinstalled Circe there, forget it and pair again."
            conn?.close(); return
        }
        do {
            let transcript = try Message.clientHello(hello).encoded() + Message.serverHello(sh).encoded()
            let keys = try SessionKeys.derive(isClient: true, localStatic: identity.privateKey, localEphemeral: ephemeral,
                                              remoteStatic: sh.staticKey, remoteEphemeral: sh.ephemeralKey,
                                              transcript: transcript)
            conn?.channel = SecureChannel(keys: keys)
        } catch {
            deliberateClose = true
            goodbyeReason = "Secure handshake failed."
            conn?.close(); return
        }
        serverHello = sh
        main { $0.linkServerHello(sh) }
        if sh.authMethods.contains(.trustedKey) {
            conn?.send(.auth(AuthRequest(method: .trustedKey)))
        } else if sh.authMethods.contains(.none) {
            conn?.send(.auth(AuthRequest(method: .none)))
        } else {
            main { $0.linkNeedsAuth(methods: sh.authMethods, error: nil) }
        }
        ping()
    }

    private func closed(_ error: Error?) {
        conn = nil
        stopAudio()
        let deliberate = deliberateClose
        let reason = goodbyeReason ?? error.map(Self.describe)
        main { $0.linkClosed(reason: reason, deliberate: deliberate) }
    }

    private func stopAudio() { audio?.stop(); audio = nil }

    static func describe(_ e: Error) -> String {
        if let nw = e as? NWError {
            switch nw {
            case .posix(let code) where code == .ECONNREFUSED: return "That Mac isn't accepting Circe connections."
            case .posix(let code) where code == .ETIMEDOUT: return "That Mac didn't respond."
            case .posix(let code) where code == .EHOSTUNREACH || code == .ENETUNREACH: return "That Mac can't be reached on this network."
            case .dns: return "Couldn't find that Mac. Check the name or address."
            default: break
            }
        }
        return e.localizedDescription
    }
}
