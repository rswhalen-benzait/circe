import CirceCore
import CoreGraphics
import CoreMedia
import CryptoKit
import Foundation
import Network

/// Shared, thread-safe host policy consulted by sessions.
final class HostPolicy: @unchecked Sendable {
    let identity: DeviceIdentity
    let trust: TrustStore
    let allowUnauthenticated: Bool
    private let lock = NSLock()
    private var _pin: String?
    private var _allowPassword = true

    init(identity: DeviceIdentity, trust: TrustStore, allowUnauthenticated: Bool) {
        self.identity = identity
        self.trust = trust
        self.allowUnauthenticated = allowUnauthenticated
    }

    var pin: String? {
        get { lock.withLock { _pin } }
        set { lock.withLock { _pin = newValue } }
    }

    var allowPassword: Bool {
        get { lock.withLock { _allowPassword } }
        set { lock.withLock { _allowPassword = newValue } }
    }
}

/// One connected client: handshake, auth, then streaming.
final class HostSession: @unchecked Sendable {
    enum Phase { case hello, auth, streaming, closed }

    let id = UUID()
    let queue: DispatchQueue
    private let conn: FramedConnection
    private let policy: HostPolicy
    private var phase: Phase = .hello
    private var failedAttempts = 0
    private(set) var peerName = "Unknown"
    private(set) var peerID = ""
    private var peerStatic = Data()

    private var capturer: ScreenCapturer?
    private var encoder: VideoEncoder?
    private var injector: InputInjector?
    private var config = StreamConfig()
    private var startingPipeline = false

    // Backpressure: never queue more than `maxInFlight` encoded frames on the socket.
    private let pipeLock = NSLock()
    private var inFlight = 0
    private var pendingBuffer: (CVPixelBuffer, UInt64)?
    private var lastBuffer: (CVPixelBuffer, UInt64)?
    private let maxInFlight = 2

    var onStateChange: ((HostSession) -> Void)?
    var onNeedsPIN: ((Bool) -> Void)?
    var onClosed: ((HostSession, String?) -> Void)?
    var onClipboard: ((ClipboardPayload) -> Void)?
    var onStreamingStarted: ((HostSession) -> Void)?

    var isStreaming: Bool { phase == .streaming }

    init(connection: NWConnection, policy: HostPolicy) {
        queue = DispatchQueue(label: "circe.host.session", qos: .userInteractive)
        conn = FramedConnection(connection: connection, queue: queue)
        self.policy = policy
    }

    func start() {
        conn.onMessage = { [weak self] in self?.handle($0) }
        conn.onClose = { [weak self] err in self?.teardown(reason: err.map { "\($0)" }) }
        conn.start()
        // Drop half-open connections that never complete the handshake.
        queue.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, self.phase == .hello || self.phase == .auth else { return }
            self.conn.close(goodbye: "Authentication timed out")
        }
    }

    func close(reason: String) {
        queue.async { self.conn.close(goodbye: reason) }
    }

    func sendClipboard(_ p: ClipboardPayload) {
        queue.async { if self.phase == .streaming { self.conn.send(.clipboard(p)) } }
    }

    func sendCursor(_ c: CursorShape) {
        queue.async { if self.phase == .streaming && self.config.localCursor { self.conn.send(.cursorShape(c)) } }
    }

    // MARK: Protocol

    private func handle(_ msg: Message) {
        switch (phase, msg) {
        case (.hello, .clientHello(let hello)):
            handleHello(hello)
        case (.auth, .auth(let req)):
            handleAuth(req)
        case (.streaming, .configure(let cfg)):
            reconfigure(cfg)
        case (.streaming, .input(let e)):
            injector?.handle(e)
        case (.streaming, .requestKeyframe):
            refreshKeyframe()
        case (.streaming, .clipboard(let p)):
            onClipboard?(p)
        case (_, .ping(let id, let t)):
            conn.send(.pong(id: id, sentMicros: t, peerMicros: Clock.micros()))
        case (_, .goodbye(let g)):
            teardown(reason: g.reason)
        default:
            conn.close(goodbye: "Unexpected message")
        }
    }

    private func handleHello(_ hello: ClientHello) {
        guard hello.version == circeProtocolVersion else {
            conn.close(goodbye: "Incompatible Circe version"); return
        }
        peerName = hello.deviceName
        peerID = hello.deviceID
        peerStatic = hello.staticKey
        let trusted = policy.trust.isTrusted(deviceID: hello.deviceID, key: hello.staticKey)
        var methods: [AuthMethod]
        if trusted { methods = [.trustedKey] }
        else if policy.allowUnauthenticated { methods = [.none] }
        else { methods = policy.allowPassword ? [.pin, .password] : [.pin] }

        let eph = Curve25519.KeyAgreement.PrivateKey()
        let sh = ServerHello(version: circeProtocolVersion, deviceID: policy.identity.deviceID,
                             deviceName: MachineInfo.computerName, modelIdentifier: MachineInfo.modelIdentifier,
                             staticKey: policy.identity.publicKey, ephemeralKey: eph.publicKey.rawRepresentation,
                             clientIsTrusted: trusted, authMethods: methods)
        do {
            let transcript = try Message.clientHello(hello).encoded() + Message.serverHello(sh).encoded()
            let keys = try SessionKeys.derive(isClient: false, localStatic: policy.identity.privateKey,
                                              localEphemeral: eph, remoteStatic: hello.staticKey,
                                              remoteEphemeral: hello.ephemeralKey, transcript: transcript)
            conn.send(.serverHello(sh))
            conn.channel = SecureChannel(keys: keys)
            phase = .auth
            if !trusted && !policy.allowUnauthenticated { onNeedsPIN?(true) }
            onStateChange?(self)
        } catch {
            conn.close(goodbye: "Handshake failed")
        }
    }

    private func handleAuth(_ req: AuthRequest) {
        let trusted = policy.trust.isTrusted(deviceID: peerID, key: peerStatic)
        var ok = false
        switch req.method {
        case .trustedKey: ok = trusted
        case .none: ok = policy.allowUnauthenticated || trusted
        case .pin:
            if let pin = policy.pin, let given = req.pin { ok = secureEquals(pin, given) }
        case .password:
            ok = policy.allowPassword && AccountVerifier.verify(username: req.username ?? "", password: req.password ?? "")
        }
        if ok {
            if req.method == .pin || req.method == .password {
                policy.trust.trust(deviceID: peerID, name: peerName, key: peerStatic)
            }
            onNeedsPIN?(false)
            conn.send(.authResult(AuthResult(ok: true, reason: nil, retryMethods: [])))
            phase = .streaming
            injector = InputInjector(displayID: CGMainDisplayID())
            onStateChange?(self)
        } else {
            failedAttempts += 1
            if failedAttempts >= 5 {
                conn.send(.authResult(AuthResult(ok: false, reason: "Too many attempts", retryMethods: [])))
                conn.close(goodbye: "Too many attempts")
                return
            }
            // Slow down guessing.
            let methods: [AuthMethod] = policy.allowPassword ? [.pin, .password] : [.pin]
            queue.asyncAfter(deadline: .now() + Double(failedAttempts)) {
                self.conn.send(.authResult(AuthResult(ok: false, reason: req.method == .password
                                                      ? "Incorrect name or password" : "Incorrect code",
                                                      retryMethods: methods)))
            }
        }
    }

    // MARK: Streaming pipeline

    private func reconfigure(_ cfg: StreamConfig) {
        let needsRestart = capturer == nil || cfg.displayID != config.displayID || cfg.maxFPS != config.maxFPS
            || cfg.localCursor != config.localCursor || cfg.audioEnabled != config.audioEnabled
            || cfg.viewportPixelWidth != config.viewportPixelWidth || cfg.viewportPixelHeight != config.viewportPixelHeight
        let bitrateChanged = cfg.bitrate != config.bitrate || cfg.quality != config.quality
        config = cfg
        if needsRestart {
            startPipeline()
        } else if bitrateChanged, let enc = encoder {
            enc.setBitrate(cfg.bitrate ?? defaultBitrate(width: enc.width, height: enc.height, fps: cfg.maxFPS, quality: cfg.quality))
        }
    }

    private func startPipeline() {
        guard !startingPipeline else { return }
        startingPipeline = true
        stopPipeline()
        let cfg = config
        let fps = max(15, min(cfg.maxFPS, 120))
        let capturer = ScreenCapturer()
        let opts = ScreenCapturer.Options(displayID: cfg.displayID, fps: fps, showsCursor: !cfg.localCursor,
                                          captureAudio: cfg.audioEnabled,
                                          maxPixelWidth: cfg.viewportPixelWidth, maxPixelHeight: cfg.viewportPixelHeight)
        Task {
            do {
                let displays = try await ScreenCapturer.displays()
                try await capturer.start(opts)
                self.queue.async { self.pipelineStarted(capturer, displays: displays, fps: fps) }
            } catch {
                self.queue.async {
                    self.startingPipeline = false
                    self.conn.close(goodbye: Permissions.screenRecording
                                    ? "Couldn't capture the screen: \(error.localizedDescription)"
                                    : "This Mac hasn't allowed Circe to record the screen yet")
                }
            }
        }
    }

    private func pipelineStarted(_ capturer: ScreenCapturer, displays: [DisplayDescriptor], fps: Int) {
        startingPipeline = false
        guard phase == .streaming, let display = capturer.display else { capturer.stop(); return }
        let (w, h) = capturer.encodedSize
        let bitrate = config.bitrate ?? defaultBitrate(width: w, height: h, fps: fps, quality: config.quality)
        guard let encoder = VideoEncoder(width: w, height: h, fps: fps, bitrate: bitrate, preferred: config.codecs) else {
            capturer.stop()
            conn.close(goodbye: "No hardware video encoder available")
            return
        }
        self.capturer = capturer
        self.encoder = encoder
        injector?.setDisplay(display.displayID)

        encoder.onFrame = { [weak self] frame in
            guard let self else { return }
            self.queue.async {
                self.conn.send(.video(frame)) { [weak self] _ in self?.frameSent() }
            }
        }
        capturer.onVideo = { [weak self] pb, t in self?.captured(pb, t) }
        capturer.onAudio = { [weak self] sb in
            guard let self, let p = AudioPacketizer.packet(from: sb, captureMicros: Clock.micros()) else { return }
            self.queue.async { if self.phase == .streaming { self.conn.send(.audio(p)) } }
        }
        capturer.onStop = { [weak self] err in
            self?.queue.async { self?.conn.close(goodbye: "Screen capture stopped: \(err?.localizedDescription ?? "")") }
        }

        conn.send(.streamStart(StreamStart(codec: encoder.codec, display: display, displays: displays,
                                           encodedWidth: w, encodedHeight: h,
                                           audio: config.audioEnabled ? AudioPacketizer.format : nil,
                                           hostClockMicros: Clock.micros())))
        onStreamingStarted?(self)
    }

    private func captured(_ pb: CVPixelBuffer, _ t: UInt64) {
        let encodeNow: Bool = pipeLock.withLock {
            lastBuffer = (pb, t)
            if inFlight >= maxInFlight { pendingBuffer = (pb, t); return false }
            inFlight += 1
            return true
        }
        if encodeNow { encoder?.encode(pb, captureMicros: t) }
    }

    private func frameSent() {
        let next: (CVPixelBuffer, UInt64)? = pipeLock.withLock {
            inFlight = max(0, inFlight - 1)
            guard let p = pendingBuffer else { return nil }
            pendingBuffer = nil
            inFlight += 1
            return p
        }
        if let (pb, t) = next { encoder?.encode(pb, captureMicros: t) }
    }

    private func refreshKeyframe() {
        guard let encoder else { return }
        encoder.requestKeyframe()
        // Static screens produce no new frames, so re-encode the last one to deliver the keyframe now.
        let last: (CVPixelBuffer, UInt64)? = pipeLock.withLock {
            guard let l = lastBuffer else { return nil }
            inFlight += 1
            return l
        }
        if let (pb, _) = last { encoder.encode(pb, captureMicros: Clock.micros()) }
    }

    private func stopPipeline() {
        capturer?.onVideo = nil
        capturer?.onAudio = nil
        capturer?.onStop = nil
        capturer?.stop()
        capturer = nil
        encoder?.onFrame = nil
        encoder?.invalidate()
        encoder = nil
        pipeLock.withLock { inFlight = 0; pendingBuffer = nil; lastBuffer = nil }
    }

    private func teardown(reason: String?) {
        guard phase != .closed else { return }
        let wasAuth = phase == .auth
        phase = .closed
        stopPipeline()
        injector?.releaseAll()
        injector = nil
        conn.close()
        if wasAuth { onNeedsPIN?(false) }
        onClosed?(self, reason)
    }
}
