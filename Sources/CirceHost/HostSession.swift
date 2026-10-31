import CirceCore
import CoreGraphics
import CoreMedia
import CryptoKit
import Foundation
import IOKit.pwr_mgt
import Network

/// Shared, thread-safe host policy consulted by sessions.
final class HostPolicy: @unchecked Sendable {
    let identity: DeviceIdentity
    let trust: TrustStore
    let allowUnauthenticated: Bool
    var syntheticCapture = false
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
    private var videoPaused = false

    // Adaptive bitrate: back off when the link can't keep up, creep back when it can.
    private var skippedFrames = 0
    private var targetBitrate = 0
    private var currentBitrate = 0
    private var cleanSeconds = 0
    private var abrTimer: DispatchSourceTimer?

    // Keep the host awake and its display on while someone is using it.
    private var powerAssertion: IOPMAssertionID = 0

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
        case let (.streaming, .fileBegin(id, name, size)):
            files.begin(id: id, name: name, size: size)
        case let (.streaming, .fileChunk(id, data)):
            files.chunk(id: id, data: data)
        case let (.streaming, .fileEnd(id, cancelled)):
            files.end(id: id, cancelled: cancelled)
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

    private let modeMatcher = DisplayModeMatcher()
    private let files = FileReceiver()

    private func reconfigure(_ cfg: StreamConfig) {
        var modeChanged = false
        if cfg.matchResolution == true, let w = cfg.viewportPointWidth, let h = cfg.viewportPointHeight, w > 200, h > 150 {
            if cfg.viewportPointWidth != config.viewportPointWidth || cfg.viewportPointHeight != config.viewportPointHeight
                || config.matchResolution != true || cfg.displayID != config.displayID {
                let target = cfg.displayID ?? capturer?.display?.displayID ?? CGMainDisplayID()
                modeChanged = modeMatcher.match(display: target, pointWidth: w, pointHeight: h)
            }
        } else if config.matchResolution == true {
            modeMatcher.restore()
            modeChanged = true
        }
        let needsRestart = modeChanged || (capturer == nil && synthetic == nil) || cfg.displayID != config.displayID || cfg.maxFPS != config.maxFPS
            || cfg.localCursor != config.localCursor || cfg.audioEnabled != config.audioEnabled
            || cfg.viewportPixelWidth != config.viewportPixelWidth || cfg.viewportPixelHeight != config.viewportPixelHeight
        let bitrateChanged = cfg.bitrate != config.bitrate || cfg.quality != config.quality
        let resumed = config.videoPaused == true && cfg.videoPaused != true
        pipeLock.withLock { videoPaused = cfg.videoPaused == true }
        config = cfg
        if resumed && !needsRestart { refreshKeyframe() }
        if needsRestart {
            startPipeline()
        } else if bitrateChanged, let enc = encoder {
            startAdaptiveBitrate(cfg.bitrate ?? defaultBitrate(width: enc.width, height: enc.height, fps: cfg.maxFPS, quality: cfg.quality))
        }
    }

    private var synthetic: SyntheticCapturer?

    private var restartPending = false

    private func startPipeline() {
        guard !startingPipeline else { restartPending = true; return }
        startingPipeline = true
        stopPipeline()
        let cfg = config
        let fps = max(15, min(cfg.maxFPS, 120))
        if policy.syntheticCapture {
            startSynthetic(fps: fps)
            return
        }
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
                    self.restartPending = false
                    self.conn.close(goodbye: Permissions.screenRecording
                                    ? "Couldn't capture the screen: \(error.localizedDescription)"
                                    : "This Mac hasn't allowed Circe to record the screen yet")
                }
            }
        }
    }

    private func startSynthetic(fps: Int) {
        startingPipeline = false
        let synth = SyntheticCapturer()
        let d = synth.display
        guard let encoder = VideoEncoder(width: d.pixelWidth, height: d.pixelHeight, fps: fps,
                                         bitrate: defaultBitrate(width: d.pixelWidth, height: d.pixelHeight, fps: fps, quality: config.quality),
                                         preferred: config.codecs) else {
            conn.close(goodbye: "No hardware video encoder available"); return
        }
        self.encoder = encoder
        self.synthetic = synth
        encoder.onFrame = { [weak self] frame in
            guard let self else { return }
            self.queue.async { self.conn.send(.video(frame)) { [weak self] _ in self?.frameSent() } }
        }
        synth.onVideo = { [weak self] pb, t in self?.captured(pb, t) }
        conn.send(.streamStart(StreamStart(codec: encoder.codec, display: d, displays: [d],
                                           encodedWidth: d.pixelWidth, encodedHeight: d.pixelHeight, audio: nil,
                                           hostClockMicros: Clock.micros())))
        startAdaptiveBitrate(defaultBitrate(width: d.pixelWidth, height: d.pixelHeight, fps: fps, quality: config.quality))
        synth.start(fps: fps)
        onStreamingStarted?(self)
    }

    private func pipelineStarted(_ capturer: ScreenCapturer, displays: [DisplayDescriptor], fps: Int) {
        startingPipeline = false
        if restartPending {
            // Config changed while ScreenCaptureKit was starting; start over with the latest settings.
            restartPending = false
            capturer.stop()
            startPipeline()
            return
        }
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
        let audio = AudioPacketizer()
        capturer.onAudio = { [weak self] sb in
            guard let self else { return }
            let packets = audio.packets(from: sb, captureMicros: Clock.micros())
            guard !packets.isEmpty else { return }
            self.queue.async { if self.phase == .streaming { for p in packets { self.conn.send(.audio(p)) } } }
        }
        capturer.onStop = { [weak self] err in
            self?.queue.async { self?.conn.close(goodbye: "Screen capture stopped: \(err?.localizedDescription ?? "")") }
        }

        startAdaptiveBitrate(bitrate)
        holdPowerAssertion()

        conn.send(.streamStart(StreamStart(codec: encoder.codec, display: display, displays: displays,
                                           encodedWidth: w, encodedHeight: h,
                                           audio: config.audioEnabled ? audio.format : nil,
                                           hostClockMicros: Clock.micros())))
        onStreamingStarted?(self)
    }

    private func startAdaptiveBitrate(_ bitrate: Int) {
        targetBitrate = bitrate
        currentBitrate = bitrate
        cleanSeconds = 0
        encoder?.setBitrate(bitrate)
        abrTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.adaptBitrate() }
        t.resume()
        abrTimer = t
    }

    private func adaptBitrate() {
        guard let encoder else { return }
        let skipped = pipeLock.withLock { () -> Int in let s = skippedFrames; skippedFrames = 0; return s }
        var next = currentBitrate
        if skipped > 2 {
            next = max(2_000_000, Int(Double(currentBitrate) * 0.7))
            cleanSeconds = 0
        } else {
            cleanSeconds += 1
            if cleanSeconds >= 3 && currentBitrate < targetBitrate {
                next = min(targetBitrate, Int(Double(currentBitrate) * 1.15))
            }
        }
        if next != currentBitrate {
            currentBitrate = next
            encoder.setBitrate(next)
        }
    }

    private func holdPowerAssertion() {
        // Wakes a sleeping display (like touching the mouse) and keeps it on for the session.
        var activity: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Circe remote session" as CFString, kIOPMUserActiveLocal, &activity)
        guard powerAssertion == 0 else { return }
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Circe remote session" as CFString, &powerAssertion)
    }

    private func releasePowerAssertion() {
        if powerAssertion != 0 { IOPMAssertionRelease(powerAssertion); powerAssertion = 0 }
    }

    private func captured(_ pb: CVPixelBuffer, _ t: UInt64) {
        let encodeNow: Bool = pipeLock.withLock {
            lastBuffer = (pb, t)
            if videoPaused { return false }
            if inFlight >= maxInFlight {
                if pendingBuffer != nil { skippedFrames += 1 }
                pendingBuffer = (pb, t)
                return false
            }
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
        abrTimer?.cancel()
        abrTimer = nil
        synthetic?.onVideo = nil
        synthetic?.stop()
        synthetic = nil
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
        modeMatcher.restore()
        files.cancelAll()
        releasePowerAssertion()
        injector?.releaseAll()
        injector = nil
        conn.close()
        if wasAuth { onNeedsPIN?(false) }
        onClosed?(self, reason)
    }
}
