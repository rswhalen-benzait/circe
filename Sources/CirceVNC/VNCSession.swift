import AppKit
import CirceClient
import CirceCore
import Combine
import Foundation
import Network
import Security

/// What ⌘ means on the remote machine.
public enum CommandKeyMapping: String, Codable, Sendable {
    /// ⌘C / ⌘V copy and paste on Linux & Windows (⌘ sends Control). Default for non-Mac servers.
    case control
    /// ⌘ sends Super (the "Windows" key).
    case `super`
}

/// Session with a VNC server: a Linux/cloud machine (over SSH or Google Cloud IAP), a Mac's built-in
/// Screen Sharing, or any VNC server on the network. Mirrors `ClientSession`'s shape for the UI.
@MainActor
public final class VNCSession: ObservableObject, Identifiable {
    public let id = UUID()
    public let tunnel: RFBTunnel
    @Published public private(set) var hostName: String
    @Published public private(set) var state: ClientState = .idle
    @Published public private(set) var stats = SessionStats()
    /// True when the server wants an account name too (Mac / VeNCrypt Plain); false = password only.
    @Published public private(set) var needsUsername = true
    @Published public var clipboardSyncEnabled = true { didSet { updateClipboard() } }
    /// Remote sound over SSH (PulseAudio/PipeWire `parec`). Tunnelled connections only.
    @Published public var remoteAudioEnabled = true { didSet { updateAudio() } }
    @Published public var audioMuted = false { didSet { audio?.setMuted(audioMuted) } }
    /// True once the remote audio stream is actually playing.
    @Published public private(set) var audioActive = false
    /// ⌘ → Control (default for non-Mac servers) or Super.
    @Published public var commandKeyMapping: CommandKeyMapping = .control {
        didSet { displayView.commandMapping = commandKeyMapping }
    }
    /// Resize the remote desktop to the window (servers with ExtendedDesktopSize, e.g. TigerVNC).
    @Published public var fitsRemoteDesktopToWindow = true { didSet { requestFit() } }
    /// The server supports resizing its desktop.
    @Published public private(set) var canResizeDesktop = false
    /// Stream the desktop as hardware-decoded H.264 from Circe's Linux helper (SSH/IAP only), with
    /// VNC kept for input, clipboard and cursor. Falls back to VNC pixels whenever video isn't available.
    @Published public var remoteVideoEnabled = true { didSet { updateVideo() } }
    /// What is currently drawing the screen.
    @Published public private(set) var videoMode: VideoMode = .vnc
    /// Why the screen is VNC pixels although video is enabled (helper missing, stream failed…).
    @Published public private(set) var videoFallbackReason: String?
    public enum VideoMode: Equatable, Sendable {
        case vnc
        case starting
        /// `encoder` as reported by the helper, e.g. "x264" or "nvenc".
        case h264(encoder: String)
    }

    public let displayView = VNCDisplayView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))

    /// Kept for Bonjour-discovered Macs (service endpoints can't be expressed as host:port).
    private let bonjourEndpoint: NWEndpoint?
    private var client: RFBClient?
    private var userClosed = false
    private var clipboard: ClipboardSync?
    private var fpsMeter = RateMeter()
    private var statsTimer: Timer?
    private var credentials: RFBClient.Credentials?
    private let keychainAccount: String
    private var hasFocus = false
    private var pendingClipboard: String?
    private var audio: AudioPlayer?
    private var audioPipe: ProcessPipe?
    private var wasStreaming = false
    private var reconnectAttempt = 0
    private var lastBytes: UInt64 = 0
    private var audioRetries = 0
    private var video: VideoRenderer?
    /// Video frames handed to the decoder this session (diagnostics / tests).
    public private(set) var videoFramesShown = 0
    /// VNC framebuffer updates received while video was showing (should be ~0: pixels are suppressed).
    public private(set) var vncUpdatesDuringVideo = 0
    public var videoDecodeFailed: Bool { video?.failed ?? false }
    private var videoPipe: ProcessPipe?
    private var videoRetries = 0
    private var videoFPS = RateMeter()
    /// Bitrate ceiling after the stream fell behind the network (nil = the helper's own choice).
    public private(set) var videoBitrateKbps: Int?
    private var videoConfig: VideoConfig?
    /// Remember credentials in the Keychain (off for tests / one-off connections).
    public var savesCredentials = true

    public init(tunnel: RFBTunnel, name: String) {
        self.tunnel = tunnel
        self.bonjourEndpoint = nil
        self.hostName = name
        keychainAccount = tunnel.keychainAccount
        setUp()
    }

    public init(endpoint: NWEndpoint, name: String) {
        if case let .hostPort(host, port) = endpoint {
            tunnel = .direct(host: "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)", port: Int(port.rawValue))
            bonjourEndpoint = nil
        } else {
            tunnel = .direct(host: name, port: 5900)
            bonjourEndpoint = endpoint
        }
        hostName = name
        keychainAccount = bonjourEndpoint.map { "\($0)" } ?? tunnel.keychainAccount
        setUp()
    }

    /// "vnc://host[:port]" or "host:5900".
    public convenience init?(address: String) {
        var s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("vnc://") { s.removeFirst(6) }
        guard case let .hostPort(host, port)? = parseEndpoint(s) else { return nil }
        let p = s.contains(":") && !s.hasPrefix("[") || s.contains("]:") ? Int(port.rawValue) : 5900
        self.init(tunnel: .direct(host: "\(host)", port: p), name: "\(host)")
    }

    private func setUp() {
        displayView.commandMapping = commandKeyMapping
        displayView.onFocusChange = { [weak self] focused in
            guard let self else { return }
            self.hasFocus = focused
            if focused, let text = self.pendingClipboard, self.clipboardSyncEnabled {
                self.pendingClipboard = nil
                self.client?.sendClipboard(text)
            }
        }
        displayView.onSettledResize = { [weak self] _ in self?.requestFit() }
    }

    public func connect() {
        userClosed = false
        if case .reconnecting = state {} else { state = .connecting }
        let c = RFBClient(tunnel: tunnel, bonjourEndpoint: bonjourEndpoint) { [weak self] e in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(e) } }
        }
        if let credentials {
            c.initialCredentials = credentials // reconnect within this session
        } else if savesCredentials, let saved = Keychain.load(account: keychainAccount) {
            c.initialCredentials = RFBClient.Credentials(username: saved.0, password: saved.1)
        }
        client = c
        displayView.client = c
        lastBytes = 0 // each connection's byte counter starts from zero
        c.start()
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stats.fps = self.video != nil ? self.videoFPS.rate() : self.fpsMeter.rate()
                // No client between reconnects; and a new connection's counter restarts below the old one.
                guard let bytes = self.client?.bytesRead else { self.lastBytes = 0; return }
                self.stats.bitrateMbps = bytes >= self.lastBytes ? Double(bytes - self.lastBytes) * 8 * 2 / 1_000_000 : 0
                self.lastBytes = bytes
            }
        }
    }

    /// Remember a password learned out of band (e.g. from LinuxSetup) so connecting needs no prompt.
    public static func savePassword(_ password: String, username: String = "", for tunnel: RFBTunnel) {
        Keychain.save(account: tunnel.keychainAccount, username: username, password: password)
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

    /// Ask the server for a specific desktop size (diagnostics / tests; normally driven by the window).
    public func requestDesktopSize(width: Int, height: Int) { client?.requestDesktopSize(width: width, height: height) }

    private var lastFramebuffer: RFBFramebuffer?
    /// Most recent clipboard text received from the server (diagnostics / tests).
    public private(set) var lastRemoteClipboard: String?
    /// Why the connection last dropped (shown while reconnecting; diagnostics).
    @Published public private(set) var lastCloseReason: String?

    private func requestFit() {
        guard fitsRemoteDesktopToWindow, canResizeDesktop, state == .streaming, displayView.window != nil else { return }
        let size = displayView.bounds.size
        client?.requestDesktopSize(width: Int(size.width), height: Int(size.height))
    }

    private func handle(_ e: RFBClient.Event) {
        switch e {
        case .needsCredentials(let user, let err):
            needsUsername = user
            state = .authenticating(methods: [.password], error: err)
        case let .connected(name, w, h, apple):
            if !name.isEmpty { hostName = name }
            displayView.isApple = apple
            if apple { commandKeyMapping = .super } // Macs: Meta = ⌘ (see KeySyms)
            displayView.framebufferSize = CGSize(width: w, height: h)
            stats.codec = apple ? "Screen Sharing" : (tunnel.isTunneled ? "VNC · Tight" : "VNC")
            stats.resolution = "\(w)×\(h)"
            stats.transport = tunnel.isTunneled ? (tunnel.isGCloud ? "IAP" : "SSH") : "TCP"
            if savesCredentials, let c = credentials { Keychain.save(account: keychainAccount, username: c.username, password: c.password) }
            state = .streaming
            wasStreaming = true
            reconnectAttempt = 0
            updateClipboard()
            updateAudio()
            updateVideo()
        case .canResizeDesktop:
            canResizeDesktop = true
            requestFit()
        case let .resized(w, h):
            displayView.framebufferSize = CGSize(width: w, height: h)
            stats.resolution = "\(w)×\(h)"
            restartVideo() // the encoder captures a fixed size
        case .frameUpdated(let fb):
            fpsMeter.add()
            if video != nil { vncUpdatesDuringVideo += 1 }
            lastFramebuffer = fb
            displayView.show(fb)
            if video == nil { displayView.setVideoLayer(nil) } // VNC pixels are current again
        case .cursor(let c):
            displayView.setCursor(c)
        case .clipboard(let text):
            lastRemoteClipboard = text
            guard clipboardSyncEnabled else { return }
            clipboard?.apply(ClipboardPayload(items: [NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)], changeCount: 0))
        case .bell:
            NSSound.beep()
        case .closed(let reason):
            guard !userClosed else { return }
            lastCloseReason = reason
            let authFailure: Bool = {
                if case .authenticating = state { return true }
                return reason?.hasPrefix("Authentication failed") == true || reason == "Incorrect name or password."
            }()
            if authFailure {
                credentials = nil
                if savesCredentials { Keychain.delete(account: keychainAccount) }
            }
            // Internet links (and VM restarts) blip: reconnect quietly with the saved credentials.
            if wasStreaming && !authFailure && reconnectAttempt < 6 {
                reconnectAttempt += 1
                stopAudio()
                stopVideo()
                client = nil
                displayView.client = nil
                state = .reconnecting(attempt: reconnectAttempt)
                let delay = min(0.5 * pow(2, Double(reconnectAttempt - 1)), 8)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, !self.userClosed else { return }
                    self.connect()
                }
                return
            }
            finish(reason ?? "The connection was lost.")
        }
    }

    // MARK: Remote audio over SSH

    /// Records the default PulseAudio/PipeWire output's monitor as raw 48 kHz stereo PCM.
    /// `@DEFAULT_MONITOR@` is resolved by PulseAudio and PipeWire-pulse themselves (locale-independent).
    static let remoteAudioCommand =
        "exec parec --device=@DEFAULT_MONITOR@ --format=s16le --rate=48000 --channels=2 --raw --latency-msec=20"

    private func updateAudio() {
        guard remoteAudioEnabled, state == .streaming, tunnel.isTunneled else { stopAudio(); return }
        guard audioPipe == nil, let (exe, args) = try? tunnel.remoteCommand(Self.remoteAudioCommand) else { return }
        let fmt = AudioFormatDescriptor(encoding: .pcm16, sampleRate: 48_000, channels: 2)
        let player = AudioPlayer(format: fmt, targetLatency: 0.080) // internet jitter headroom
        player.setMuted(audioMuted)
        player.start()
        let pipe = ProcessPipe(executable: exe, arguments: args)
        guard (try? pipe.start()) != nil else { player.stop(); return }
        audio = player
        audioPipe = pipe
        let pipeRef = pipe
        let reader = Thread { [weak self, weak pipe] in
            var carry = Data()
            var announced = false
            while let pipe {
                let chunk = pipe.read()
                if chunk.isEmpty { break }
                carry.append(chunk)
                let usable = carry.count - carry.count % 4 // whole stereo frames only
                guard usable > 0 else { continue }
                player.enqueue(AudioPacket(captureMicros: Clock.micros(), frames: UInt32(usable / 4), data: carry.prefix(usable)))
                carry = Data(carry.dropFirst(usable))
                if !announced {
                    announced = true
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.audioRetries = 0 } }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.audioActive = true } }
                }
            }
            // Stream ended (audio server restarted, channel dropped…): clear it and try again shortly.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.audioPipe === pipeRef else { return }
                    self.stopAudio()
                    self.audioRetries += 1
                    guard self.audioRetries <= 5 else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.updateAudio() }
                }
            }
        }
        reader.name = "circe.vnc.audio"
        reader.qualityOfService = .userInteractive
        reader.start()
    }

    private func stopAudio() {
        audioPipe?.terminate()
        audioPipe = nil
        audio?.stop()
        audio = nil
        audioActive = false
    }

    // MARK: H.264 video over SSH (Linux helper installed by setup-circe-host.sh)

    /// The helper writes an H.264 FLV stream of the X display to stdout; diagnostics go to stderr.
    func remoteVideoCommand() -> String {
        let display: Int = {
            switch tunnel {
            case let .ssh(_, _, vnc), let .gcloud(_, _, _, _, vnc): return vnc - 5900
            case .direct: return 0
            }
        }()
        var cmd = "exec \"$HOME/.local/libexec/circe/video\" --display \(display)"
        if let kbps = videoBitrateKbps { cmd += " --bitrate-kbps \(kbps)" }
        return cmd
    }

    /// The helper's `CIRCE_VIDEO_CONFIG {json}` stderr line (what it chose, not proof of frames).
    struct VideoConfig: Decodable, Equatable {
        var encoder: String
        var width: Int?
        var height: Int?
        var fps: Int?
        var bitrateKbps: Int?
    }

    static func reportedConfig(_ stderr: String) -> VideoConfig? {
        let marker = "CIRCE_VIDEO_CONFIG "
        guard let line = stderr.split(separator: "\n").last(where: { $0.hasPrefix(marker) }) else { return nil }
        return try? JSONDecoder().decode(VideoConfig.self, from: Data(line.dropFirst(marker.count).utf8))
    }

    /// Helper exit status → reason to stay on VNC for this connection (nil = transient, retry).
    static func videoUnavailable(exitCode: Int32) -> String? {
        switch exitCode {
        case 64: return "This Mac and the machine's video helper don't agree on options. Re-run setup on the machine."
        case 69, 127: return "Smooth video isn't installed on the machine (needs ffmpeg). Re-run setup to add it."
        case 77: return "The video helper couldn't open the remote desktop's display."
        default: return nil
        }
    }

    private func updateVideo() {
        guard remoteVideoEnabled, state == .streaming, tunnel.isTunneled, !displayView.isApple else { stopVideo(); return }
        guard videoPipe == nil, let (exe, args) = try? tunnel.remoteCommand(remoteVideoCommand()) else { return }
        let pipe = ProcessPipe(executable: exe, arguments: args)
        guard (try? pipe.start()) != nil else { return }
        videoPipe = pipe
        videoMode = .starting
        let renderer = VideoRenderer()
        renderer.reset(codec: .h264)
        let pipeRef = pipe
        let reader = Thread { [weak self, weak pipe] in
            var framer = LinuxVideoFramer()
            var started = false
            var behindSince: UInt64?
            while let pipe {
                let chunk = pipe.read()
                if chunk.isEmpty { break }
                guard let frames = try? framer.feed(chunk) else { pipe.terminate(); break }
                // TCP never drops: when the network can't carry the bitrate, frames queue up and the
                // picture drifts behind. Seconds of sustained lag → restart lighter (fresh, empty pipe).
                if framer.lagMillis > Self.maxVideoLagMillis {
                    let now = Clock.micros()
                    if now - (behindSince ?? now) > 1_500_000 {
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.videoFellBehind(pipeRef) } }
                        behindSince = nil
                    } else if behindSince == nil { behindSince = now }
                } else { behindSince = nil }
                for f in frames {
                    let first = !started && f.isKeyframe
                    if first { started = true }
                    guard started else { continue }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, self.videoPipe === pipeRef else { return }
                            if first { self.videoStarted(renderer, pipe: pipeRef) }
                            renderer.display(f)
                            self.videoFPS.add()
                            self.videoFramesShown += 1
                        }
                    }
                }
            }
            pipe?.process.waitUntilExit()
            let code = pipe?.process.terminationStatus ?? 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.videoPipe === pipeRef else { return }
                    self.stopVideo()
                    // Not installed / not possible on this machine: VNC pixels it is.
                    if let reason = Self.videoUnavailable(exitCode: code) { self.videoFallbackReason = reason; return }
                    self.videoFallbackReason = "The video stream stopped; showing VNC until it's back."
                    self.videoRetries += 1
                    guard self.videoRetries <= 5, self.state == .streaming else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.updateVideo() }
                }
            }
        }
        reader.name = "circe.vnc.video"
        reader.qualityOfService = .userInteractive
        reader.start()
    }

    /// First keyframe decoded: show the video and stop VNC spending bandwidth on pixels.
    private func videoStarted(_ renderer: VideoRenderer, pipe: ProcessPipe) {
        video = renderer
        videoRetries = 0
        videoFallbackReason = nil
        displayView.setVideoLayer(renderer.layer)
        client?.setPixelsSuppressed(true)
        videoConfig = Self.reportedConfig(pipe.errorOutput)
        let encoder = videoConfig?.encoder ?? "H.264"
        videoMode = .h264(encoder: encoder)
        stats.codec = "H.264 · \(encoder)"
    }

    static let maxVideoLagMillis = 350

    private func videoFellBehind(_ pipe: ProcessPipe) {
        guard videoPipe === pipe else { return }
        let current = videoBitrateKbps ?? videoConfig?.bitrateKbps ?? 6000
        videoBitrateKbps = max(1000, current * 6 / 10)
        restartVideo()
    }

    private func restartVideo() {
        guard videoPipe != nil else { return }
        stopVideo()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.updateVideo() }
    }

    private func stopVideo() {
        videoPipe?.terminate()
        videoPipe = nil
        let wasShowing = video != nil
        video = nil
        if videoMode != .vnc { videoMode = .vnc }
        guard wasShowing else { return }
        // Keep the last video image up until VNC has sent a fresh full frame (see .frameUpdated).
        client?.setPixelsSuppressed(false)
        if client == nil { displayView.setVideoLayer(nil) }
        stats.codec = tunnel.isTunneled ? "VNC · Tight" : "VNC"
    }

    private func finish(_ reason: String?) {
        state = .disconnected(reason: reason)
        stopAudio()
        stopVideo()
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
