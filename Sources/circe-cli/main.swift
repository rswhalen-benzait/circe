import AppKit
import CirceClient
import CirceCore
import CirceHost
import CirceVNC
import Foundation

// circe-cli — headless host / client used for end-to-end testing.
//
//   circe-cli host [--open] [--port N]        share this Mac (--open: no pairing, testing only)
//   circe-cli connect <address> [--seconds N] [--pin 123456] [--window]
//   circe-cli displays                        list capturable displays

let args = Array(CommandLine.arguments.dropFirst())

func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func log(_ s: String) {
    FileHandle.standardError.write(Data("[circe] \(s)\n".utf8))
}

@MainActor
func runHost() {
    let open = args.contains("--open")
    let port = value("--port").flatMap(UInt16.init) ?? circeDefaultPort
    log("screen recording: \(Permissions.screenRecording), accessibility: \(Permissions.accessibility)")
    let host = HostService(identity: .loadOrCreate(name: "cli-host-identity.json"),
                           trust: TrustStore(name: "cli-trusted-clients.json"),
                           port: port, serviceName: value("--name"), allowUnauthenticated: open)
    var lastPIN: String?
    var lastClients = -1
    Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
        MainActor.assumeIsolated {
            if host.pairingPIN != lastPIN {
                lastPIN = host.pairingPIN
                if let p = lastPIN { log("pairing code: \(p)") }
            }
            if host.clients.count != lastClients {
                lastClients = host.clients.count
                log("clients: \(host.clients.map { "\($0.name)\($0.isStreaming ? " (streaming)" : "")" })")
            }
            if let e = host.lastError { log("error: \(e)"); exit(1) }
        }
    }
    host.syntheticCapture = args.contains("--synthetic")
    host.start()
    log("hosting on port \(port)\(open ? " (open, no pairing)" : "") — fingerprint \(host.fingerprint)")
    hostRef = host
}

@MainActor var hostRef: HostService?
@MainActor var sessionRef: ClientSession?
@MainActor var windowRef: NSWindow?

@MainActor
func runConnect() {
    guard args.count >= 2, let session = ClientSession(address: args[1]) else {
        log("usage: circe-cli connect <address>"); exit(2)
    }
    let seconds = value("--seconds").flatMap(Double.init) ?? 5
    let pin = value("--pin")
    if args.contains("--window") {
        let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1280, height: 800),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Circe — \(args[1])"
        w.contentView = session.displayView
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        windowRef = w
    }
    var lastState: ClientState?
    var start: Date?
    var maxFPS = 0.0
    var restarted = false
    Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
        MainActor.assumeIsolated {
            if session.state != lastState {
                lastState = session.state
                log("state: \(session.state)")
                if case .authenticating = session.state {
                    if var pin {
                        // "@file": read the latest code a `circe-cli host` logged (test automation).
                        if pin.hasPrefix("@"), let text = try? String(contentsOfFile: String(pin.dropFirst()), encoding: .utf8),
                           let line = text.split(separator: "\n").last(where: { $0.contains("pairing code: ") }) {
                            pin = String(line.split(separator: " ").last ?? "")
                        }
                        session.submitPIN(pin)
                    } else { log("host needs pairing; pass --pin"); exit(3) }
                }
                if case .streaming = session.state {
                    start = Date()
                    if let f = value("--send") { session.sendFiles([URL(fileURLWithPath: f)]) }
                }
                if case .disconnected(let r) = session.state { log("disconnected: \(r ?? "-")"); exit(4) }
            }
            if let start, let after = value("--restart-after").flatMap(Double.init), !restarted,
               Date().timeIntervalSince(start) >= after {
                // Forces a host pipeline restart (new capturer + encoder) mid-session.
                restarted = true
                session.setQuality(.ultra)
                session.update { $0.maxFPS = 59 }
                log("requested pipeline restart")
            }
            if let start {
                let s = session.stats
                maxFPS = max(maxFPS, s.fps)
                if Date().timeIntervalSince(start) >= seconds {
                    log(String(format: "RESULT transport=%@ codec=%@ res=%@ fps=%.0f (max %.0f) bitrate=%.1fMbps latency=%.1fms rtt=%.1fms dropped=%d",
                               s.transport, s.codec, s.resolution, s.fps, maxFPS, s.bitrateMbps, s.latencyMs, s.roundTripMs, s.droppedFrames))
                    session.disconnect()
                    exit(maxFPS > 0 ? 0 : 5)
                }
            }
        }
    }
    session.connect()
    sessionRef = session
}

@MainActor var vncRef: VNCSession?

/// circe-cli vnc <address> | --ssh user@host [--ssh-port N] | --gcloud INSTANCE --zone Z [--project P] [--account A] [--ssh-user U] [--no-iap]
///   [--display N] [--seconds N] [--user U --password P] [--expect x,y=0xRRGGBB ...] [--tolerance N]
///   [--resize WxH] [--expect-clipboard TEXT] [--expect-audio] [--expect-audio-encoding pcm16|opus] [--expect-video] [--no-video]
@MainActor
func runVNC() {
    let display = value("--display").flatMap(Int.init) ?? 1
    let session: VNCSession
    if let dest = value("--ssh") {
        let t = RFBTunnel.ssh(destination: dest, port: value("--ssh-port").flatMap(Int.init), vncPort: RFBTunnel.vncPort(display: display))
        session = VNCSession(tunnel: t, name: dest)
    } else if let inst = value("--gcloud"), let zone = value("--zone"), let alias = value("--iap-alias") {
        guard let project = value("--project"), let account = value("--account"), let user = value("--ssh-user") else {
            log("--iap-alias needs --project, --account and --ssh-user"); exit(2)
        }
        let t = RFBTunnel.iap(instance: inst, zone: zone, project: project, account: account, user: user, hostKeyAlias: alias,
                              vncPort: RFBTunnel.vncPort(display: display))
        session = VNCSession(tunnel: t, name: inst)
    } else if let inst = value("--gcloud"), let zone = value("--zone") {
        let t = RFBTunnel.gcloud(instance: inst, zone: zone, project: value("--project"), useIAP: !args.contains("--no-iap"),
                                 vncPort: RFBTunnel.vncPort(display: display), account: value("--account"), user: value("--ssh-user"))
        session = VNCSession(tunnel: t, name: inst)
    } else if args.count >= 2, let s = VNCSession(address: args[1]) {
        session = s
    } else {
        log("usage: circe-cli vnc <address> | --ssh user@host | --gcloud INSTANCE --zone ZONE"); exit(2)
    }
    session.clipboardSyncEnabled = false // never touch this Mac's real clipboard from tests
    session.audioMuted = true            // verify the audio stream without playing it
    session.savesCredentials = false     // and never write test passwords to the Keychain
    if args.contains("--no-video") { session.remoteVideoEnabled = false }
    let seconds = value("--seconds").flatMap(Double.init) ?? 3
    let tolerance = value("--tolerance").flatMap(Int.init) ?? 0
    var lastState: ClientState?
    var start: Date?
    var resized = false
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
        MainActor.assumeIsolated {
            if session.state != lastState {
                lastState = session.state
                log("state: \(session.state)")
                if case .reconnecting = session.state { log("dropped: \(session.lastCloseReason ?? "-")") }
                if case .authenticating = session.state {
                    guard let pw = value("--password") else { log("server requires credentials (username needed: \(session.needsUsername))"); exit(3) }
                    session.submitPassword(username: value("--user") ?? NSUserName(), password: pw)
                }
                if case .streaming = session.state, start == nil {
                    start = Date()
                    // --type TEXT: after the desktop settles, click the middle of the screen and type TEXT + Return.
                    if let text = value("--type") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            MainActor.assumeIsolated {
                                session.typeForTesting(text, clickAt: (800, 500))
                                log("typed \(text.count) characters")
                            }
                        }
                    }
                }
                if case .disconnected(let r) = session.state { log("disconnected: \(r ?? "-")"); exit(4) }
            }
            guard let start else { return }
            if let size = value("--resize"), !resized, Date().timeIntervalSince(start) > 0.5 {
                resized = true
                let wh = size.split(separator: "x").compactMap { Int($0) }
                session.requestDesktopSize(width: wh[0], height: wh[1])
            }
            guard Date().timeIntervalSince(start) >= seconds else { return }
            if let path = value("--snapshot"), let png = session.snapshotPNG() { try? png.write(to: URL(fileURLWithPath: path)) }
            var bad = 0
            var i = 0
            while i < args.count {
                if args[i] == "--expect", i + 1 < args.count {
                    let parts = args[i + 1].split(separator: "=")
                    let xy = parts[0].split(separator: ",").compactMap { Int($0) }
                    let want = UInt32(parts[1].dropFirst(2), radix: 16)!
                    let got = session.samplePixel(x: xy[0], y: xy[1]) ?? 0
                    let diff = [16, 8, 0].map { abs(Int((got >> $0) & 0xFF) - Int((want >> $0) & 0xFF)) }.max()!
                    if diff > tolerance { bad += 1; log(String(format: "pixel (%d,%d) = %08X, expected %06X", xy[0], xy[1], got, want)) }
                }
                i += 1
            }
            if let size = value("--resize"), session.stats.resolution != size.replacingOccurrences(of: "x", with: "×") {
                bad += 1; log("resize: got \(session.stats.resolution), wanted \(size)")
            }
            if let clip = value("--expect-clipboard"), session.lastRemoteClipboard != clip {
                bad += 1; log("clipboard: got \(session.lastRemoteClipboard ?? "nil")")
            }
            if args.contains("--expect-audio"), !session.audioActive { bad += 1; log("audio: not playing") }
            if let enc = value("--expect-audio-encoding"), session.audioEncoding?.rawValue != enc {
                bad += 1; log("audio encoding: \(session.audioEncoding?.rawValue ?? "none"), wanted \(enc)")
            }
            if args.contains("--expect-video") {
                if case .h264 = session.videoMode {} else { bad += 1; log("video: \(session.videoMode) \(session.videoFallbackReason ?? "")") }
                if session.videoDecodeFailed { bad += 1; log("video: decoder failed") }
                // Xvnc's pixels must stop once video is up (a few in-flight updates are fine).
                if session.vncUpdatesDuringVideo > 5 { bad += 1; log("video: VNC still sent \(session.vncUpdatesDuringVideo) pixel updates") }
            }
            if let minFPS = value("--min-fps").flatMap(Double.init), session.stats.fps < minFPS {
                bad += 1; log("fps \(session.stats.fps) < \(minFPS)")
            }
            log(String(format: "RESULT %@ via %@ %@ fps=%.0f audio=%@ resizable=%@ video=%d videoLimit=%d fpsLimit=%d mismatches=%d", session.stats.codec,
                       session.stats.transport, session.stats.resolution, session.stats.fps,
                       session.audioActive ? "yes" : "no", session.canResizeDesktop ? "yes" : "no", session.videoFramesShown, session.videoBitrateKbps ?? 0, session.videoFPSLimit ?? 0, bad))
            session.disconnect()
            exit(bad == 0 ? 0 : 6)
        }
    }
    session.connect()
    vncRef = session
}

/// circe-cli linux-setup --ssh user@host | --gcloud INSTANCE --zone Z [--project P] [--account A] [--ssh-user U]  SCRIPT [-- script args]
@MainActor
func runLinuxSetup() {
    let display = value("--display").flatMap(Int.init) ?? 1
    let tunnel: RFBTunnel
    if let dest = value("--ssh") {
        tunnel = .ssh(destination: dest, port: value("--ssh-port").flatMap(Int.init), vncPort: RFBTunnel.vncPort(display: display))
    } else if let inst = value("--gcloud"), let zone = value("--zone") {
        tunnel = .gcloud(instance: inst, zone: zone, project: value("--project"), useIAP: !args.contains("--no-iap"),
                         vncPort: RFBTunnel.vncPort(display: display), account: value("--account"), user: value("--ssh-user"))
    } else { log("usage: circe-cli linux-setup --ssh user@host SCRIPT"); exit(2) }
    guard let path = value("--script"), let script = FileManager.default.contents(atPath: path) else { log("--script PATH required"); exit(2) }
    let extra = args.firstIndex(of: "--").map { Array(args[($0 + 1)...]) } ?? []
    LinuxSetup.run(tunnel: tunnel, script: script, arguments: extra, onOutput: { log("remote: \($0)") }) { result in
        switch result {
        case .success(let r): log("RESULT display=\(r.display) password=\(r.password == nil ? "none" : "<received>") audio=\(r.audio ?? false)"); exit(0)
        case .failure(let e): log("FAILED: \(e)"); exit(7)
        }
    }
}

/// circe-cli linux-desktop --ssh user@host [--ssh-port N] [--display N] [--hold SECONDS]
/// Starts a desktop set up without lingering and holds its session (as the app does while connected).
@MainActor
func runLinuxDesktop() {
    let display = value("--display").flatMap(Int.init) ?? 1
    guard let dest = value("--ssh") else { log("usage: circe-cli linux-desktop --ssh user@host [--hold SECONDS]"); exit(2) }
    let tunnel = RFBTunnel.ssh(destination: dest, port: value("--ssh-port").flatMap(Int.init), vncPort: RFBTunnel.vncPort(display: display))
    let hold = value("--hold").flatMap(Double.init) ?? 0
    DispatchQueue.global().async {
        let started = Date()
        switch LinuxSetup.startDesktop(tunnel: tunnel, cancel: GoogleCloud.CancelToken()) {
        case .success(let lease):
            log(String(format: "RESULT desktop ready in %.1fs; holding %.0fs", Date().timeIntervalSince(started), hold))
            Thread.sleep(forTimeInterval: hold)
            log("lease active before end: \(lease.isActive)")
            lease.end()
            exit(0)
        case .failure(let failure):
            log("FAILED: \(failure)"); exit(7)
        }
    }
}

@MainActor
func runDisplays() {
    Task {
        let content = try? await ScreenCaptureKitProbe.displays()
        log("displays: \(content ?? [])")
        exit(0)
    }
}

enum ScreenCaptureKitProbe {
    static func displays() async throws -> [String] {
        // Route through the host so permissions behave identically.
        [Permissions.screenRecording ? "screen recording granted" : "screen recording NOT granted"]
    }
}

/// circe-cli gcp accounts | credential EMAIL | projects EMAIL | instances EMAIL PROJECT
///              | describe EMAIL PROJECT ZONE NAME | tunnel EMAIL PROJECT ZONE NAME
///              | probe EMAIL PROJECT ZONE NAME --script PATH [--ssh-user U]   (all read-only)
func runGCP() -> Never {
    let rest = Array(args.dropFirst(2))
    func show<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self))
    }
    do {
        switch (args.dropFirst().first, rest.count) {
        case ("accounts", _): show(try GoogleCloud.accounts())
        case ("install", _):
            try GoogleCloudInstaller.install(cancel: GoogleCloud.CancelToken()) { log($0) }
            print(GoogleCloudInstaller.managedGCloud?.path ?? "not installed")
        case ("which", _): print((try? GoogleCloud.executableURL().path) ?? "none")
        case ("credential", 1...): print(try GoogleCloud.credential(for: rest[0]))
        case ("signin", 1...):
            // The app's "Use a code instead" flow: prints Google's page, then reads the code from a file when it appears.
            let channel = GoogleCloud.SignInChannel(), cancel = GoogleCloud.CancelToken()
            let codeFile = value("--code-file") ?? "/tmp/circe-signin-code"
            try? FileManager.default.removeItem(atPath: codeFile)
            DispatchQueue.global().async {
                while true {
                    if let code = try? String(contentsOfFile: codeFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty {
                        channel.submit(code); try? FileManager.default.removeItem(atPath: codeFile); return
                    }
                    usleep(300_000)
                }
            }
            let who = try GoogleCloud.signIn(hint: rest[0], useCode: args.contains("--code"), cancel: cancel, channel: channel) { event in
                switch event { case .page(let url): log("PAGE \(url.absoluteString)"); case .needsCode: log("NEEDS_CODE (write it to \(codeFile))") }
            }
            print("signed in as \(who)")
        case ("projects", 1...): show(try GoogleCloud.projects(account: rest[0]))
        case ("instances", 2...): show(try GoogleCloud.instances(account: rest[0], project: rest[1]))
        case ("describe", 4...): show(try GoogleCloud.instance(account: rest[0], project: rest[1], zone: rest[2], name: rest[3]))
        case ("tunnel", 4...): print(try GoogleCloud.checkTunnel(account: rest[0], project: rest[1], zone: rest[2], instance: rest[3]))
        case ("oslogin", 2...): print(GoogleCloud.osLoginUsername(account: rest[0], project: rest[1]) ?? "none")
        case ("verify", 6...):
            print(GoogleCloud.verifyLogin(.iap(instance: rest[3], zone: rest[2], project: rest[1], account: rest[0], user: rest[4], hostKeyAlias: rest[5], vncPort: 5901)))
        case ("probe", 4...):
            guard let path = value("--script"), let script = FileManager.default.contents(atPath: path) else { log("--script PATH required"); exit(2) }
            // Read-only route: ssh over IAP with an existing key (gcloud compute ssh could publish keys).
            guard let user = value("--ssh-user"), let alias = value("--iap-alias") else { log("probe needs --ssh-user and --iap-alias"); exit(2) }
            let tunnel = RFBTunnel.iap(instance: rest[3], zone: rest[2], project: rest[1], account: rest[0], user: user, hostKeyAlias: alias, vncPort: 5901)
            nonisolated(unsafe) var outcome: Result<LinuxSetup.Probe, LinuxSetup.Failure>?
            LinuxSetup.probe(tunnel: tunnel, script: script) { outcome = $0 }
            while outcome == nil { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1)) }
            switch outcome! { case .success(let probe): show(probe); case .failure(let failure): log("error: \(failure)"); exit(1) }
        default: log("usage: circe-cli gcp accounts | credential EMAIL | projects EMAIL | instances EMAIL PROJECT | describe|tunnel EMAIL PROJECT ZONE NAME"); exit(2)
        }
        exit(0)
    } catch { log("error: \(error)"); exit(1) }
}

if args.first == "gcp" { runGCP() }

let app = NSApplication.shared
app.setActivationPolicy(args.contains("--window") ? .regular : .accessory)
MainActor.assumeIsolated {
    switch args.first {
    case "host": runHost()
    case "connect": runConnect()
    case "displays": runDisplays()
    case "vnc": runVNC()
    case "linux-setup": runLinuxSetup()
    case "linux-desktop": runLinuxDesktop()
    case "remote-command":
        // The exact remote command Circe runs over SSH (already wrapped for /bin/sh), for tests and support.
        switch args.dropFirst().first {
        case "mic": print(RFBTunnel.posix(VNCSession.remoteMicrophoneCommand), terminator: "")
        case "audio": print(RFBTunnel.posix(VNCSession.remoteAudioCommand(display: value("--display").flatMap(Int.init) ?? 1)), terminator: "")
        case "desktop": print(RFBTunnel.posix(LinuxSetup.desktopStartCommand(port: 5900 + (value("--display").flatMap(Int.init) ?? 1))), terminator: "")
        default: log("usage: circe-cli remote-command mic|audio|desktop [--display N]"); exit(2)
        }
        exit(0)
    default:
        log("usage: circe-cli host [--open] [--port N] | connect <address> [--seconds N] [--pin CODE] [--window]")
        exit(2)
    }
}
app.run()
