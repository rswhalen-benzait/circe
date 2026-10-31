import AppKit
import CirceClient
import CirceCore
import CirceHost
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
                if case .streaming = session.state { start = Date() }
                if case .disconnected(let r) = session.state { log("disconnected: \(r ?? "-")"); exit(4) }
            }
            if let start {
                let s = session.stats
                maxFPS = max(maxFPS, s.fps)
                if Date().timeIntervalSince(start) >= seconds {
                    log(String(format: "RESULT codec=%@ res=%@ fps=%.0f (max %.0f) bitrate=%.1fMbps latency=%.1fms rtt=%.1fms",
                               s.codec, s.resolution, s.fps, maxFPS, s.bitrateMbps, s.latencyMs, s.roundTripMs))
                    session.disconnect()
                    exit(maxFPS > 0 ? 0 : 5)
                }
            }
        }
    }
    session.connect()
    sessionRef = session
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

let app = NSApplication.shared
app.setActivationPolicy(args.contains("--window") ? .regular : .accessory)
MainActor.assumeIsolated {
    switch args.first {
    case "host": runHost()
    case "connect": runConnect()
    case "displays": runDisplays()
    default:
        log("usage: circe-cli host [--open] [--port N] | connect <address> [--seconds N] [--pin CODE] [--window]")
        exit(2)
    }
}
app.run()
