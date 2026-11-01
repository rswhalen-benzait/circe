import AppKit
import CirceClient
import CirceCore
import Combine
import Foundation
import Darwin
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
    /// Send this Mac's microphone to the remote desktop as a virtual microphone (Linux over SSH/IAP).
    @Published public var microphoneEnabled = false {
        didSet {
            // Repeated true is an explicit Retry from the session controls.
            microphoneRetries = 0
            stopMicrophone()
            microphoneProblem = nil
            updateMicrophone()
        }
    }
    @Published public private(set) var microphoneActive = false
    @Published public private(set) var microphoneProblem: String?
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
    private var connectionGeneration: UInt64 = 0
    private var reconnectWork: DispatchWorkItem?
    @Published public private(set) var passwordRejected = false
    // Injectable for deterministic credential-lifecycle tests without touching the login Keychain.
    var credentialStore = VNCCredentialStore()
    private var userClosed = false
    private var clipboard: ClipboardSync?
    private var fpsMeter = RateMeter()
    private var statsTimer: Timer?
    private var credentials: RFBClient.Credentials?
    private var credentialsNeedSaving = false
    private let keychainAccount: String
    private var hasFocus = false
    private var pendingClipboard: String?
    private var audio: AudioPlayer?
    private var audioPipe: ProcessPipe?
    /// The clipboard of an open session Circe's desktop is showing (its sharing server has none), over SSH.
    private var clipboardBridge: ProcessPipe?
    private var microphonePipe: ProcessPipe?
    private var microphone: MicrophoneCapture?
    private var microphoneRetries = 0
    private var microphoneGeneration: UInt64 = 0
    private var microphonePermissionPending = false
    private var microphoneCaptureRunning = false
    private var microphoneReadiness: Timer?
    private var microphoneWriter: MicrophonePCMWriter?

    deinit {
        // Mic work must not retain a closed session or keep transmitting after its binding is retired.
        client?.stop()
        reconnectWork?.cancel()
        microphoneReadiness?.invalidate()
        microphone?.stop()
        microphoneWriter?.close()
        microphonePipe?.terminate()
    }
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
    /// Frame-rate ceiling after repeated lag (a busy VM CPU, not just the network).
    public private(set) var videoFPSLimit: Int?
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
                self.sendRemoteClipboard(text)
            }
        }
        displayView.onSettledResize = { [weak self] _ in self?.requestFit() }
    }

    public func connect() {
        // A repeated Connect/Retry focuses the existing attempt rather than opening another tunnel.
        guard client == nil else { return }
        reconnectWork?.cancel(); reconnectWork = nil
        connectionGeneration &+= 1
        let generation = connectionGeneration
        passwordRejected = false
        userClosed = false
        if case .reconnecting = state {} else { state = .connecting }
        let c = RFBClient(tunnel: tunnel, bonjourEndpoint: bonjourEndpoint) { [weak self] e in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, self.connectionGeneration == generation, !self.userClosed else { return }
                self.handle(e)
            } }
        }
        // A setup/another window may have replaced the desktop password since this session connected.
        // Prefer that saved value on a new attempt; keep our in-memory value if Keychain is temporarily locked.
        if savesCredentials, !credentialsNeedSaving, let saved = credentialStore.load(keychainAccount) {
            credentials = saved
        }
        if let credentials { c.initialCredentials = credentials }
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
    @discardableResult
    public static func savePassword(_ password: String, username: String = "", for tunnel: RFBTunnel) -> Bool {
        Keychain.save(account: tunnel.keychainAccount, username: username, password: password)
    }

    public static func forgetPassword(for tunnel: RFBTunnel) { Keychain.delete(account: tunnel.keychainAccount) }
    public static func hasSavedPassword(for tunnel: RFBTunnel) -> Bool { Keychain.load(account: tunnel.keychainAccount) != nil }

    public func submitPassword(username: String, password: String) {
        credentials = RFBClient.Credentials(username: username, password: password)
        credentialsNeedSaving = true
        state = .connecting
        client?.provideCredentials(credentials!)
    }

    public func disconnect() {
        userClosed = true
        finish(nil)
    }

    public func releaseInput() { displayView.releaseInput() }
    public func captureInput() { displayView.captureInput() }

    public var capturesSystemShortcuts: Bool {
        get { displayView.capturesSystemShortcuts }
        set { displayView.capturesSystemShortcuts = newValue }
    }

    public func refresh() { client?.requestUpdate(incremental: false) }

    /// The current framebuffer as PNG data (diagnostics / tests).
    public func snapshotPNG() -> Data? {
        guard let fb = lastFramebuffer else { return nil }
        fb.lock(); defer { fb.unlock() }
        let bytes = Data(bytes: fb.base, count: fb.stride * fb.height * 4)
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: fb.width, height: fb.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: fb.stride * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    /// BGRA pixel at framebuffer coordinates (diagnostics / tests).
    /// Tests: click at (x, y), then type `text` (ASCII) and Return through the same RFB key path as the keyboard.
    public func typeForTesting(_ text: String, clickAt point: (x: Int, y: Int)) {
        guard let client else { return }
        client.sendPointer(x: point.x, y: point.y, buttons: 0)
        client.sendPointer(x: point.x, y: point.y, buttons: 1)
        client.sendPointer(x: point.x, y: point.y, buttons: 0)
        for scalar in text.unicodeScalars where scalar.value >= 0x20 && scalar.value < 0x7f {
            client.sendKey(scalar.value, down: true); client.sendKey(scalar.value, down: false)
        }
        client.sendKey(0xff0d, down: true); client.sendKey(0xff0d, down: false)
    }

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
        case .credentialsAccepted(let accepted):
            credentials = accepted
            // Loaded credentials are already saved. Rewriting them could overwrite a password just reset
            // by another setup/window while this handshake's callback was queued.
            if savesCredentials, credentialsNeedSaving {
                credentialsNeedSaving = !credentialStore.save(keychainAccount, accepted)
            }
        case .credentialsRejected(let rejected):
            passwordRejected = true
            if credentials == rejected { credentials = nil; credentialsNeedSaving = false }
            // Another window/setup may already have saved a newer password for this endpoint.
            if savesCredentials { credentialStore.removeIfMatching(keychainAccount, rejected) }
        case let .connected(name, w, h, apple):
            if !name.isEmpty { hostName = name }
            displayView.isApple = apple
            if apple { commandKeyMapping = .super } // Macs: Meta = ⌘ (see KeySyms)
            displayView.framebufferSize = CGSize(width: w, height: h)
            stats.codec = apple ? "Screen Sharing" : (tunnel.isTunneled ? "VNC · Tight" : "VNC")
            stats.resolution = "\(w)×\(h)"
            stats.transport = tunnel.isTunneled ? (tunnel.isGCloud ? "IAP" : "SSH") : "TCP"
            state = .streaming
            wasStreaming = true
            reconnectAttempt = 0
            updateClipboard()
            updateClipboardBridge()
            updateAudio()
            updateMicrophone()
            updateVideo()
        case .canResizeDesktop:
            canResizeDesktop = true
            requestFit()
        case let .resized(w, h):
            displayView.framebufferSize = CGSize(width: w, height: h)
            stats.resolution = "\(w)×\(h)"
            restartVideo() // the encoder captures a fixed size
        case let .frameUpdated(fb, coverage):
            fpsMeter.add()
            if video != nil { vncUpdatesDuringVideo += 1 }
            lastFramebuffer = fb
            displayView.show(fb)
            // Video stopped: keep its last image until VNC has repainted (most of) the screen,
            // not just a cursor-sized update that was already in flight.
            if video == nil, displayView.videoLayer != nil, coverage >= 0.9 { displayView.setVideoLayer(nil) }
        case .cursor(let c):
            displayView.setCursor(c)
        case .clipboard(let text):
            receiveRemoteClipboard(text)
        case .bell:
            NSSound.beep()
        case .closed(let reason):
            guard !userClosed else { return }
            lastCloseReason = reason
            let authFailure = passwordRejected
            retireClient()
            // Internet links (and VM restarts) blip: reconnect quietly with the saved credentials.
            if wasStreaming && !authFailure && reconnectAttempt < 6 {
                reconnectAttempt += 1
                stopClipboardBridge()
                stopAudio()
                stopMicrophone()
                stopVideo()
                state = .reconnecting(attempt: reconnectAttempt)
                let delay = min(0.5 * pow(2, Double(reconnectAttempt - 1)), 8)
                let generation = connectionGeneration
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, !self.userClosed, self.connectionGeneration == generation, self.client == nil else { return }
                        self.connect()
                    }
                }
                reconnectWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                return
            }
            finish(reason ?? "The connection was lost.")
        }
    }

    // MARK: Remote audio over SSH

    /// Circe's audio helper (Ogg/Opus, ~128 kb/s) when installed; it exits 69 before writing anything
    /// if it can't run, and then — or on machines set up before it existed — `parec` sends raw 48 kHz
    /// stereo PCM. `@DEFAULT_MONITOR@` is resolved by PulseAudio and PipeWire-pulse themselves
    /// (locale-independent).
    ///
    /// Circe's own desktop plays into the `circe` sink (PULSE_SINK) without changing the account's default output,
    /// so when this connection is to that desktop's display, record `circe.monitor`; any other desktop (an
    /// existing wayvnc session, say) is recorded from the default output, as before.
    ///
    /// When Circe's desktop is showing a session that was already open (Chrome Remote Desktop runs its own sound
    /// server), desktop.env names that session's server and output, and those are recorded instead.
    public nonisolated static func remoteAudioCommand(display: Int) -> String {
        """
        [ -r "$HOME/.config/circe/prefix.env" ] && . "$HOME/.config/circe/prefix.env"; \
        d=@DEFAULT_MONITOR@; c="$HOME/.config/circe/host.conf"; e="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/circe/desktop.env"; \
        if [ -r "$c" ] && grep -qx 'DISPLAY_NUMBER=\(display)' "$c"; then \
        if [ -r "$e" ] && grep -q '^CIRCE_SHARED_DISPLAY=' "$e"; then . "$e"; if [ -n "${CIRCE_PULSE_SERVER:-}" ]; then export PULSE_SERVER="$CIRCE_PULSE_SERVER"; fi; d="${CIRCE_AUDIO_SOURCE:-@DEFAULT_MONITOR@}"; \
        elif pactl list short sources 2>/dev/null | grep -q '[[:space:]]circe.monitor[[:space:]]'; then d=circe.monitor; fi; fi; \
        h="$HOME/.local/libexec/circe/audio"; if [ -x "$h" ]; then CIRCE_AUDIO_DEVICE="$d" "$h"; s=$?; [ $s -eq 69 ] || exit $s; fi; \
        exec parec --device="$d" --format=s16le --rate=48000 --channels=2 --raw --latency-msec=20
        """
    }

    /// How remote audio is arriving (diagnostics / tests).
    public private(set) var audioEncoding: AudioFormatDescriptor.Encoding?

    private func updateAudio() {
        guard remoteAudioEnabled, state == .streaming, tunnel.isTunneled else { stopAudio(); return }
        guard audioPipe == nil, let (exe, args) = try? tunnel.remoteCommand(Self.remoteAudioCommand(display: tunnel.remoteVNCPort.map { $0 - 5900 } ?? 1)) else { return }
        let pipe = ProcessPipe(executable: exe, arguments: args)
        guard (try? pipe.start()) != nil else { return }
        audioPipe = pipe
        let muted = audioMuted
        let pipeRef = pipe
        let reader = Thread { [weak self, weak pipe] in
            var stream = RemoteAudioStream()
            var player: AudioPlayer?
            while let pipe {
                let chunk = pipe.read()
                if chunk.isEmpty { break }
                guard let payloads = try? stream.feed(chunk) else { break }
                if player == nil, stream.kind != .unknown {
                    let encoding: AudioFormatDescriptor.Encoding = stream.kind == .opus ? .opus : .pcm16
                    let p = AudioPlayer(format: AudioFormatDescriptor(encoding: encoding, sampleRate: 48_000, channels: 2),
                                        targetLatency: 0.080) // internet jitter headroom
                    p.setMuted(muted)
                    p.start()
                    player = p
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, self.audioPipe === pipeRef else { p.stop(); return }
                            p.setMuted(self.audioMuted)
                            self.audio = p
                            self.audioEncoding = encoding
                            self.audioRetries = 0
                            self.audioActive = true
                        }
                    }
                }
                for d in payloads {
                    let frames = stream.kind == .opus ? 480 : d.count / 4
                    player?.enqueue(AudioPacket(captureMicros: Clock.micros(), frames: UInt32(frames), data: d))
                }
            }
            // Stream ended (audio server restarted, channel dropped…): clear it and try again shortly.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.audioPipe === pipeRef else { player?.stop(); return }
                    self.stopAudio()
                    player?.stop()
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

    // MARK: Microphone over SSH

    /// Gives the remote desktop a microphone: a private null sink fed with this Mac's microphone, remapped into
    /// a source named "Mac microphone (Circe)" and made the default input while connected. Everything is
    /// undone when the stream ends. Needs only the account's own PulseAudio/PipeWire (pactl, pacat); no sudo.
    public nonisolated static let remoteMicrophoneCommand: String = {
        let script = #"""
        set -u
        umask 077
        # A session that was already open (Chrome Remote Desktop) has its own sound server: give the microphone to it.
        session_env="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/circe/desktop.env"
        if [[ -r "$session_env" ]]; then
            # shellcheck disable=SC1090
            . "$session_env"
            [[ -z "${CIRCE_PULSE_SERVER:-}" ]] || export PULSE_SERVER="$CIRCE_PULSE_SERVER"
        fi
        owner=$$
        s=circe_mic_feed_$owner
        m=circe_mic_$owner
        ids=""
        prev=""
        baseline=""
        player=""
        sweeper=""
        locked=false
        state="$HOME/.cache/circe/microphone"

        fail() { printf 'CIRCE_MIC_ERROR %s\n' "$1" >&2; exit 69; }
        lock_state() {
            $locked && return 0
            [[ ! -L "$state/lock" ]] || return 1
            exec 9>"$state/lock" || return 1
            flock -w 5 -x 9 || { exec 9>&-; return 1; }
            locked=true
        }
        unlock_state() {
            if $locked; then flock -u 9 || true; exec 9>&-; locked=false; fi
        }
        source_exists() {
            local name="$1" found
            [[ -n "$name" ]] || return 1
            if [[ "$name" =~ ^circe_mic_([0-9]+)$ ]]; then kill -0 "${BASH_REMATCH[1]}" 2>/dev/null || return 1; fi
            found=$(pactl list short sources 2>/dev/null) || return 1
            awk -v name="$name" '$2 == name { found=1 } END { exit !found }' <<< "$found"
        }
        non_circe_source() {
            local sources
            sources=$(pactl list short sources 2>/dev/null) || return 1
            awk '$2 !~ /^circe_mic_[0-9]+$/ && $2 !~ /^circe_mic_feed_[0-9]+\.monitor$/ { print $2; exit }' <<< "$sources"
        }
        restore_default() {
            local pid="$1" current prev="" base=""
            current=$(pactl get-default-source 2>/dev/null) || return 0
            [[ "$current" == "circe_mic_$pid" ]] || return 0
            if [[ -r "$state/$pid" ]]; then
                prev=$(sed -n '1p' "$state/$pid")
                base=$(sed -n '2p' "$state/$pid")
            fi
            if ! source_exists "$prev"; then prev="$base"; fi
            if ! source_exists "$prev"; then prev=$(non_circe_source) || prev=""; fi
            if [[ -n "$prev" && "$prev" != "$current" && "$(pactl get-default-source 2>/dev/null)" == "circe_mic_$pid" ]]; then pactl set-default-source "$prev" >/dev/null 2>&1 || true; fi
        }
        unload_pid() {
            local pid="$1" modules id
            modules=$(pactl list short modules 2>/dev/null) || return 1
            # Remap first, then its backing sink. Never unload an ID without checking its current name/owner.
            while read -r id; do
                [[ -z "$id" ]] || pactl unload-module "$id" >/dev/null 2>&1 || return 1
            done < <(awk -v pid="$pid" '$2 == "module-remap-source" { for(i=3;i<=NF;i++) if($i == "source_name=circe_mic_" pid) print $1 }' <<< "$modules")
            modules=$(pactl list short modules 2>/dev/null) || return 1
            while read -r id; do
                [[ -z "$id" ]] || pactl unload-module "$id" >/dev/null 2>&1 || return 1
            done < <(awk -v pid="$pid" '$2 == "module-null-sink" { for(i=3;i<=NF;i++) if($i == "sink_name=circe_mic_feed_" pid) print $1 }' <<< "$modules")
        }
        sweep_stale() {
            local modules pid
            modules=$(pactl list short modules 2>/dev/null) || return 1
            while read -r pid; do
                [[ "$pid" =~ ^[0-9]+$ ]] || continue
                if ! kill -0 "$pid" 2>/dev/null; then
                    restore_default "$pid"
                    unload_pid "$pid" || return 1
                    rm -f -- "$state/$pid"
                fi
            done < <(awk '($2 == "module-null-sink" || $2 == "module-remap-source") {
                for(i=3;i<=NF;i++) if($i ~ /^sink_name=circe_mic_feed_[0-9]+$/ || $i ~ /^source_name=circe_mic_[0-9]+$/) {
                    value=$i; sub(/^.*=/,"",value); sub(/^circe_mic_feed_/,"",value); sub(/^circe_mic_/,"",value); print value
                }
            }' <<< "$modules" | sort -u)
        }
        cleanup() {
            trap - EXIT HUP TERM INT
            [[ -z "$player" ]] || kill "$player" 2>/dev/null || true
            [[ -z "$sweeper" ]] || kill "$sweeper" 2>/dev/null || true
            [[ -z "$player" ]] || wait "$player" 2>/dev/null || true
            [[ -z "$sweeper" ]] || wait "$sweeper" 2>/dev/null || true
            if [[ -d "$state" ]] && lock_state; then
                restore_default "$owner"
                unload_pid "$owner" || true
                rm -f -- "$state/$owner"
                unlock_state
            fi
        }
        trap cleanup EXIT
        trap 'exit 0' HUP TERM INT
        command -v pacat >/dev/null && command -v pactl >/dev/null && command -v flock >/dev/null || fail missing_tools
        pactl info >/dev/null 2>&1 || fail no_audio_server
        [[ ! -L "$state" ]] || fail unsafe_state_directory
        mkdir -p "$state" || fail state_directory
        chmod 700 "$state" || fail state_directory
        lock_state || fail state_lock
        sweep_stale || fail stale_cleanup
        prev=$(pactl get-default-source 2>/dev/null) || fail default_source
        baseline="$prev"
        if [[ "$prev" =~ ^circe_mic_([0-9]+)$ ]]; then
            previous_owner=${BASH_REMATCH[1]}
            if [[ -r "$state/$previous_owner" ]]; then baseline=$(sed -n '2p' "$state/$previous_owner"); fi
            if ! source_exists "$baseline"; then baseline=$(non_circe_source) || baseline=""; fi
        fi
        printf '%s\n%s\n' "$prev" "$baseline" > "$state/$owner" || fail state_record
        sink_id=$(pactl load-module module-null-sink sink_name=$s rate=48000 channels=1 "sink_properties=\"device.description='Circe microphone feed'\"") || fail sink_create
        [[ "$sink_id" =~ ^[0-9]+$ ]] || fail sink_create
        ids="$sink_id"
        source_id=$(pactl load-module module-remap-source master=$s.monitor source_name=$m channels=1 channel_map=mono "source_properties=\"device.description='Mac microphone (Circe)'\"") || fail source_create
        [[ "$source_id" =~ ^[0-9]+$ ]] || fail source_create
        ids="$source_id $ids"
        source_exists "$m" || fail source_missing
        pactl set-default-source "$m" >/dev/null 2>&1 || fail routing
        [[ "$(pactl get-default-source 2>/dev/null)" == "$m" ]] || fail routing
        unlock_state
        pacat --playback --device="$s" --format=s16le --rate=48000 --channels=1 --raw --latency-msec=40 --client-name=Circe --stream-name='Mac microphone' <&0 &
        player=$!
        kill -0 "$player" 2>/dev/null || fail playback
        # A separate watcher also cleans a shell killed with SIGKILL; it has its own lock descriptor.
        (
            trap - EXIT
            trap 'exit 0' HUP TERM INT
            player=""; sweeper=""; locked=false
            while :; do
                sleep 2 & wait $!
                if lock_state; then sweep_stale || true; unlock_state; fi
                kill -0 "$owner" 2>/dev/null || exit 0
            done
        ) </dev/null >/dev/null 2>&1 &
        sweeper=$!
        printf 'CIRCE_MIC_READY {"pid":%s,"source":"%s","sink":"%s"}\n' "$owner" "$m" "$s" >&2
        wait "$player"
        status=$?
        player=""
        [[ "$status" == 0 ]] || { printf 'CIRCE_MIC_ERROR playback\n' >&2; exit 75; }
        """#
        // Keep the user's runtime discovery, then use Bash explicitly rather than their login shell.
        return "[ -r \"$HOME/.config/circe/prefix.env\" ] && . \"$HOME/.config/circe/prefix.env\"; "
            + "exec /bin/bash -c '" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }()

    private func updateMicrophone() {
        guard microphoneEnabled, state == .streaming, tunnel.isTunneled else { stopMicrophone(); return }
        guard microphonePipe == nil, !microphonePermissionPending else { return }
        microphonePermissionPending = true
        let generation = microphoneGeneration
        MicrophoneCapture.requestAccess { [weak self] granted in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, self.microphoneGeneration == generation else { return }
                self.microphonePermissionPending = false
                self.startMicrophone(granted: granted, generation: generation)
            } }
        }
    }

    private func startMicrophone(granted: Bool, generation: UInt64) {
        guard microphoneGeneration == generation, microphoneEnabled, state == .streaming, microphonePipe == nil else { return }
        guard granted else { microphoneProblem = MicrophoneCapture.Failure.denied.description; return }
        do {
            guard let (exe, args) = try tunnel.remoteCommand(Self.remoteMicrophoneCommand) else { return }
            let pipe = ProcessPipe(executable: exe, arguments: args)
            guard let input = pipe.process.standardInput as? Pipe else {
                microphoneProblem = "Circe couldn’t open the microphone connection."; return
            }
            // Write directly through a bounded, nonblocking PCM writer. ProcessPipe.write's
            // asynchronous queue is deliberately not used for real-time microphone samples.
            let writer = try MicrophonePCMWriter(handle: input.fileHandleForWriting, onFirstWrite: { [weak self, weak pipe] in
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    guard let self, let pipe, self.microphonePipe === pipe, self.microphoneGeneration == generation else { return }
                    self.microphoneDidStream(pipe: pipe, generation: generation)
                } }
            }, onError: { [weak self, weak pipe] in
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    guard let self, let pipe else { return }
                    self.microphoneFailed(pipe: pipe, generation: generation, message: "The microphone connection stopped accepting audio.", retry: true)
                } }
            })
            do { try pipe.start() } catch { writer.close(); throw error }
            microphonePipe = pipe
            microphoneWriter = writer
            microphoneProblem = nil
            microphoneActive = false
            let deadline = ProcessInfo.processInfo.systemUptime + 25
            microphoneReadiness = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self, weak pipe] timer in
                MainActor.assumeIsolated {
                    guard let self, let pipe, self.microphonePipe === pipe, self.microphoneGeneration == generation else { timer.invalidate(); return }
                    let status = MicrophoneRemoteStatus(stderr: pipe.errorOutput)
                    if let error = status.error {
                        self.microphoneFailed(pipe: pipe, generation: generation, message: status.message, retry: !MicrophoneRemoteStatus.permanentErrors.contains(error))
                    } else if status.ready {
                        timer.invalidate(); self.microphoneReadiness = nil
                        self.beginMicrophoneCapture(pipe: pipe, writer: writer, generation: generation)
                    } else if ProcessInfo.processInfo.systemUptime >= deadline {
                        self.microphoneFailed(pipe: pipe, generation: generation, message: "The remote microphone didn’t become ready. Try again.", retry: true)
                    }
                }
            }
            let watcher = Thread { [weak self] in
                while !pipe.read().isEmpty {}
                pipe.process.waitUntilExit()
                let reason = pipe.settledErrorOutput()
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    guard let self, self.microphonePipe === pipe, self.microphoneGeneration == generation else { return }
                    let status = MicrophoneRemoteStatus(stderr: reason)
                    self.microphoneFailed(pipe: pipe, generation: generation, message: status.message,
                                          retry: status.error.map { !MicrophoneRemoteStatus.permanentErrors.contains($0) } ?? true)
                } }
            }
            watcher.name = "circe.vnc.microphone"
            watcher.start()
        } catch {
            microphoneProblem = "The microphone connection couldn’t start: \(error.localizedDescription)"
        }
    }

    private func beginMicrophoneCapture(pipe: ProcessPipe, writer: MicrophonePCMWriter, generation: UInt64) {
        guard microphonePipe === pipe, microphoneGeneration == generation, microphoneEnabled, state == .streaming else { return }
        let capture = MicrophoneCapture(onData: { [weak writer] data in writer?.enqueue(data) }, onState: { [weak self, weak pipe, weak writer] state in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, let pipe, self.microphonePipe === pipe, self.microphoneGeneration == generation else { return }
                switch state {
                case .recovering:
                    self.microphoneCaptureRunning = false
                    self.microphoneActive = false
                    self.microphoneProblem = nil
                    writer?.resetActivation()
                case .running:
                    self.microphoneCaptureRunning = true
                    self.microphoneDidStream(pipe: pipe, generation: generation)
                case .failed(let error):
                    self.microphoneCaptureRunning = false
                    self.microphoneActive = false
                    self.microphoneProblem = error.description
                    writer?.resetActivation()
                }
            } }
        })
        microphone = capture
        do { try capture.start() }
        catch {
            microphoneFailed(pipe: pipe, generation: generation,
                             message: (error as? MicrophoneCapture.Failure)?.description ?? error.localizedDescription, retry: false)
        }
    }

    private func microphoneDidStream(pipe: ProcessPipe, generation: UInt64) {
        guard microphonePipe === pipe, microphoneGeneration == generation, microphoneCaptureRunning,
              microphoneWriter?.hasWritten == true else { return }
        let first = !microphoneActive
        microphoneActive = true; microphoneProblem = nil
        guard first else { return }
        // A healthy interval resets the budget; flapping READY/exit loops do not.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak pipe] in MainActor.assumeIsolated {
            guard let self, let pipe else { return }
            if self.microphonePipe === pipe, self.microphoneGeneration == generation, self.microphoneActive { self.microphoneRetries = 0 }
        } }
    }

    private func microphoneFailed(pipe: ProcessPipe, generation: UInt64, message: String, retry: Bool) {
        guard microphonePipe === pipe, microphoneGeneration == generation else { return }
        stopMicrophone()
        microphoneProblem = message
        guard retry, microphoneEnabled, state == .streaming else { return }
        microphoneRetries += 1
        guard microphoneRetries <= 5 else { microphoneProblem = message + " Turn the microphone off and on to try again."; return }
        let next = microphoneGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in MainActor.assumeIsolated {
            guard let self, self.microphoneGeneration == next, self.microphoneEnabled, self.state == .streaming else { return }
            self.updateMicrophone()
        } }
    }

    private func stopMicrophone() {
        microphoneGeneration &+= 1
        microphonePermissionPending = false
        microphoneCaptureRunning = false
        microphoneReadiness?.invalidate(); microphoneReadiness = nil
        microphone?.stop(); microphone = nil
        microphoneWriter?.close(); microphoneWriter = nil
        // EOF drains only the small OS pipe, not an unbounded queue of stale speech.
        if let pipe = microphonePipe { DispatchQueue.global().asyncAfter(deadline: .now() + 3) { pipe.terminate() } }
        microphonePipe = nil
        microphoneActive = false
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
            tunnel.remoteVNCPort.map { $0 - 5900 } ?? 0
        }()
        var cmd = "exec \"$HOME/.local/libexec/circe/video\" --display \(display)"
        if let kbps = videoBitrateKbps { cmd += " --bitrate-kbps \(kbps)" }
        if let fps = videoFPSLimit { cmd += " --fps \(fps)" }
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
        // Still behind after a lighter bitrate: the VM may be out of CPU, so also capture less often.
        if videoBitrateKbps != nil, let fps = videoFPSLimit ?? videoConfig?.fps { videoFPSLimit = max(10, fps * 2 / 3) }
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
        stats.codec = tunnel.isTunneled ? "VNC · Tight" : "VNC"
        // Keep the last video image up until VNC has sent a fresh full frame (see .frameUpdated).
        client?.setPixelsSuppressed(false)
        if client == nil { displayView.setVideoLayer(nil); return }
        // Servers may send the refresh as several updates; don't leave a frozen video image regardless.
        let layer = displayView.videoLayer
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.video == nil, self.displayView.videoLayer === layer else { return }
            self.displayView.setVideoLayer(nil)
        }
    }

    private func retireClient() {
        connectionGeneration &+= 1
        reconnectWork?.cancel(); reconnectWork = nil
        client?.stop()
        client = nil
        displayView.client = nil
    }

    private func finish(_ reason: String?) {
        retireClient()
        state = .disconnected(reason: reason)
        stopClipboardBridge()
        stopAudio()
        stopMicrophone()
        stopVideo()
        statsTimer?.invalidate()
        statsTimer = nil
        clipboard?.stop()
        clipboard = nil
        displayView.client = nil
        client = nil
    }

    private func receiveRemoteClipboard(_ text: String) {
        lastRemoteClipboard = text
        guard clipboardSyncEnabled else { return }
        clipboard?.apply(ClipboardPayload(items: [NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)], changeCount: 0))
    }

    private func sendRemoteClipboard(_ text: String) {
        client?.sendClipboard(text)
        clipboardBridge?.write(Data("SET \(Data(text.utf8).base64EncodedString())\n".utf8))
    }

    /// Circe's clipboard helper, which exits at once (69) unless this display is showing an open session.
    public nonisolated static func remoteClipboardCommand(display: Int) -> String {
        "h=\"$HOME/.local/libexec/circe/clipboard\"; [ -x \"$h\" ] || exit 69; exec \"$h\" --display \(display)"
    }

    /// A session that was already open (Chrome Remote Desktop, RDP) is shown by a sharing server without a
    /// clipboard; Circe's helper carries it over SSH instead. Elsewhere the helper ends immediately.
    private func updateClipboardBridge() {
        guard state == .streaming, tunnel.isTunneled else { stopClipboardBridge(); return }
        guard clipboardBridge == nil,
              let (exe, args) = try? tunnel.remoteCommand(Self.remoteClipboardCommand(display: tunnel.remoteVNCPort.map { $0 - 5900 } ?? 1)) else { return }
        let pipe = ProcessPipe(executable: exe, arguments: args)
        guard (try? pipe.start()) != nil else { return }
        clipboardBridge = pipe
        let reader = Thread { [weak self, weak pipe] in
            var buffer = Data()
            while let pipe {
                let chunk = pipe.read()
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard line.hasPrefix("CLIP "), let data = Data(base64Encoded: String(line.dropFirst(5))),
                          let text = String(data: data, encoding: .utf8) else { continue }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.receiveRemoteClipboard(text) } }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if let self, self.clipboardBridge === pipe { self.clipboardBridge = nil } }
            }
        }
        reader.name = "circe.vnc.clipboard"
        reader.start()
    }

    private func stopClipboardBridge() {
        clipboardBridge?.terminate()
        clipboardBridge = nil
    }

    private func updateClipboard() {
        if clipboardSyncEnabled && state == .streaming {
            guard clipboard == nil else { return }
            let c = ClipboardSync()
            c.onLocalChange = { [weak self] p in
                guard let self, let d = p.items[NSPasteboard.PasteboardType.string.rawValue],
                      let s = String(data: d, encoding: .utf8) else { return }
                // Same rule as native sessions: only share our clipboard while the session is focused.
                if self.hasFocus { self.sendRemoteClipboard(s) } else { self.pendingClipboard = s }
            }
            c.start()
            clipboard = c
        } else {
            clipboard?.stop()
            clipboard = nil
        }
    }
}

/// Credential operations stay on the session's main actor. A rejected old session cannot remove a
/// password a newer setup/session has already stored. Tests replace these closures with an in-memory store.
struct VNCCredentialStore {
    var load: (String) -> RFBClient.Credentials? = { account in
        Keychain.load(account: account).map { RFBClient.Credentials(username: $0.0, password: $0.1) }
    }
    var save: (String, RFBClient.Credentials) -> Bool = { account, credentials in
        Keychain.save(account: account, username: credentials.username, password: credentials.password)
    }
    var removeIfMatching: (String, RFBClient.Credentials) -> Void = { account, rejected in
        guard let saved = Keychain.load(account: account), saved.0 == rejected.username, saved.1 == rejected.password else { return }
        Keychain.delete(account: account)
    }
}

/// Saved VNC / Screen Sharing credentials, so you only type them once.
enum Keychain {
    static let service = "Circe Screen Sharing"

    /// Update in place, or add; never deletes the old item first, so a failure can't lose it.
    @discardableResult
    static func save(account: String, username: String, password: String) -> Bool {
        guard let blob = try? JSONEncoder().encode([username, password]) else { return false }
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary
        let updated = SecItemUpdate(query, [kSecValueData: blob] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        return SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                           kSecValueData: blob] as CFDictionary, nil) == errSecSuccess
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


/// A bounded, frame-aligned queue. Timestamps also prevent replaying old queued speech after a stall.
struct MicrophonePCMBuffer {
    static let bytesPerSecond = 48_000 * 2
    let capacity: Int
    let maximumAge: TimeInterval
    private var chunks: [(Data, TimeInterval)] = []
    private(set) var count = 0
    init(milliseconds: Int = 200) {
        capacity = max(2, milliseconds * Self.bytesPerSecond / 1000 / 2 * 2)
        maximumAge = Double(milliseconds) / 1000
    }
    mutating func append(_ data: Data, now: TimeInterval) {
        guard !data.isEmpty, data.count.isMultiple(of: 2) else { return }
        expire(now: now)
        let fresh = data.count > capacity ? Data(data.suffix(capacity)) : data
        while count + fresh.count > capacity, !chunks.isEmpty { count -= chunks.removeFirst().0.count }
        chunks.append((fresh, now)); count += fresh.count
    }
    mutating func peek(maximum: Int, now: TimeInterval) -> Data {
        expire(now: now)
        guard let first = chunks.first else { return Data() }
        return Data(first.0.prefix(maximum / 2 * 2))
    }
    mutating func consume(_ bytes: Int) {
        precondition(bytes.isMultiple(of: 2) && bytes <= (chunks.first?.0.count ?? 0))
        guard bytes > 0 else { return }
        count -= bytes
        if bytes == chunks[0].0.count { chunks.removeFirst() }
        else { chunks[0].0.removeFirst(bytes) }
    }
    mutating func removeAll() { chunks.removeAll(); count = 0 }
    private mutating func expire(now: TimeInterval) {
        while let first = chunks.first, now - first.1 >= maximumAge { count -= chunks.removeFirst().0.count }
    }
}

/// One worker, nonblocking atomic pipe writes: no Dispatch block or retained buffer per audio callback.
/// OS/SSH/server buffers remain separate from the 200 ms application queue.
final class MicrophonePCMWriter: @unchecked Sendable {
    private let condition = NSCondition()
    private var buffer = MicrophonePCMBuffer()
    private let handle: FileHandle
    private let descriptor: Int32
    private let maximumWrite: Int
    private var closed = false
    private var announced = false
    private let onFirstWrite: @Sendable () -> Void
    private let onError: @Sendable () -> Void

    init(handle: FileHandle, onFirstWrite: @escaping @Sendable () -> Void, onError: @escaping @Sendable () -> Void) throws {
        self.handle = handle; descriptor = handle.fileDescriptor
        self.onFirstWrite = onFirstWrite; self.onError = onError
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else { throw POSIXError(.EIO) }
        // Nonblocking writes <= PIPE_BUF are all-or-nothing, preserving 16-bit PCM framing.
        maximumWrite = max(2, min(512, Int(fpathconf(descriptor, _PC_PIPE_BUF))) / 2 * 2)
        let thread = Thread { [self] in run() }
        thread.name = "circe.vnc.microphone.writer"; thread.qualityOfService = .userInitiated; thread.start()
    }
    func enqueue(_ data: Data) {
        condition.lock(); defer { condition.unlock() }
        guard !closed else { return }
        buffer.append(data, now: ProcessInfo.processInfo.systemUptime); condition.signal()
    }
    func resetActivation() {
        condition.lock(); defer { condition.unlock() }
        buffer.removeAll(); announced = false
    }
    func close() {
        condition.lock(); defer { condition.unlock() }
        guard !closed else { return }
        closed = true; buffer.removeAll(); try? handle.close(); condition.broadcast()
    }
    var pendingBytes: Int { condition.lock(); defer { condition.unlock() }; return buffer.count }
    var hasWritten: Bool { condition.lock(); defer { condition.unlock() }; return announced }
    private func run() {
        while true {
            condition.lock()
            while !closed && buffer.count == 0 { condition.wait() }
            if closed { condition.unlock(); return }
            let data = buffer.peek(maximum: maximumWrite, now: ProcessInfo.processInfo.systemUptime)
            if data.isEmpty { condition.unlock(); continue }
            let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!, $0.count) }
            let status = errno
            if written == data.count {
                buffer.consume(written)
                let announce = !announced; announced = true
                condition.unlock()
                if announce { onFirstWrite() }
            } else if written < 0 && (status == EAGAIN || status == EWOULDBLOCK || status == EINTR) {
                condition.unlock()
                var waiting = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                _ = poll(&waiting, 1, 20)
            } else {
                closed = true; buffer.removeAll(); try? handle.close(); condition.unlock()
                onError(); return
            }
        }
    }
}

struct MicrophoneRemoteStatus {
    let ready: Bool
    let error: String?
    static let permanentErrors: Set<String> = ["missing_tools", "no_audio_server", "sink_create", "source_create", "source_missing", "routing", "unsafe_state_directory", "state_directory", "state_lock", "state_record", "default_source", "stale_cleanup"]
    init(stderr: String) {
        struct Ready: Decodable { let pid: Int; let source: String; let sink: String }
        let lines = stderr.split(separator: "\n").map(String.init)
        error = lines.last(where: { $0.hasPrefix("CIRCE_MIC_ERROR ") }).map { String($0.dropFirst("CIRCE_MIC_ERROR ".count)).split(separator: " ").first.map(String.init) ?? "unknown" }
        ready = error == nil && lines.contains { line in
            guard line.hasPrefix("CIRCE_MIC_READY "), let data = line.dropFirst("CIRCE_MIC_READY ".count).data(using: .utf8),
                  let row = try? JSONDecoder().decode(Ready.self, from: data), row.pid > 1 else { return false }
            return row.source == "circe_mic_\(row.pid)" && row.sink == "circe_mic_feed_\(row.pid)"
        }
    }
    var message: String {
        switch error {
        case "missing_tools": return "The remote computer needs PulseAudio tools (pactl, pacat and flock) to receive a microphone."
        case "no_audio_server": return "The remote computer’s sound server isn’t running, so it can’t receive a microphone."
        case "sink_create", "source_create", "source_missing": return "The remote sound server couldn’t create a microphone. Turn the microphone off and on to try again."
        case "routing", "default_source": return "The remote computer couldn’t select Circe’s microphone. Turn it off and on to try again."
        case .some: return "The remote microphone couldn’t start (\(error!)). Turn it off and on to try again."
        case .none: return "The microphone connection ended."
        }
    }
}
