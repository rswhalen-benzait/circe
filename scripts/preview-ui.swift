import AppKit
import SwiftUI

@main
struct PreviewExporter {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/previews", isDirectory: true)
        for (mode, scheme, appearanceName) in [("light", ColorScheme.light, NSAppearance.Name.aqua), ("dark", ColorScheme.dark, .darkAqua)] {
            let output = root.appendingPathComponent(mode, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let appearance = NSAppearance(named: appearanceName)!
            NSApp.appearance = appearance
            let suite = "com.circe.preview.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(true, forKey: "hasSeenWelcome")
            let model = CirceModel(preferences: CircePreferences(defaults: defaults))
            func save<V: View>(_ name: String, _ view: V) throws {
                let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
                host.appearance = appearance
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = appearance; window.contentView = host
                window.setFrameOrigin(NSPoint(x: 80, y: 80)); window.makeKeyAndOrderFront(nil)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
                window.displayIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw NSError(domain: "CircePreview", code: 1) }
                appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
                if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: output.appendingPathComponent("\(name).png")) }
                window.orderOut(nil)
            }
            try save("welcome", WelcomeView { _ in })
            try save("launcher-empty", LauncherView(model: model).frame(width: 640, height: 650))
            model.hosts = [NearbyMac(id: "studio", name: "Studio Mac", model: "Mac Studio", address: "studio.local"), NearbyMac(id: "laptop", name: "Ralph’s MacBook Pro", model: "MacBookPro", address: "macbook.local")]
            try save("launcher", LauncherView(model: model).frame(width: 640, height: 650))
            model.onConnect = { _, address in
                let session = RemoteSession(name: address.contains("studio") ? "Studio Mac" : "Office Mac", address: address)
                session.phase = .streaming
                return session
            }
            for address in ["circe://studio.local:47800", "vnc://office.local:5900"] { let recent = model.connect(address: address); model.closeSession(recent.id) }
            try save("launcher-recents", LauncherView(model: model).frame(width: 640, height: 760))
            var cloudDraft = ComputerDraft()
            cloudDraft.name = "Cloud workstation"; cloudDraft.instance = "linux-workstation"; cloudDraft.zone = "us-central1-a"; cloudDraft.project = "personal-lab"
            let cloud = try cloudDraft.computer()
            var sshDraft = ComputerDraft(); sshDraft.kind = .ssh; sshDraft.name = "Linux development"; sshDraft.destination = "dev@linux-box"
            let linux = try sshDraft.computer()
            try model.saveComputer(cloud); try model.saveComputer(linux)
            try save("launcher-computers", LauncherView(model: model).frame(width: 640, height: 850))
            try save("computer-add", AddComputerView(model: model))
            try save("computer-add-google-cloud", AddComputerView(model: model, draft: cloudDraft))
            try save("computer-add-ssh", AddComputerView(model: model, draft: sshDraft))
            try save("computer-google-cloud", AddComputerView(model: model, computer: cloud))
            try save("computer-ssh", AddComputerView(model: model, computer: linux))
            try save("settings-computers", CirceSettingsView(model: model, initialTab: .computers))
            model.onSetupComputer = { computer, _ in
                model.appendSetupOutput("Installing XFCE and TigerVNC…", for: computer.id)
                model.appendSetupOutput("VNC will listen on 127.0.0.1:5901", for: computer.id)
                model.appendSetupOutput("Preparing headless audio…", for: computer.id)
            }
            model.setUpComputer(cloud) { _ in }
            try save("computer-setup-progress", AddComputerView(model: model, computer: cloud))
            model.onSetupComputer = { _, completion in completion(.failure(ComputerValidationError("SSH sign-in failed. Check your SSH keys and verify the connection in Terminal, then run setup again."))) }
            model.setUpComputer(linux) { _ in }
            try save("computer-setup-failed", AddComputerView(model: model, computer: linux))
            try save("hosting", HostingSetupView(model: model))
            model.screenRecordingGranted = true; model.accessibilityGranted = true; model.isHosting = true; model.pairingPIN = "731942"; model.loginItemStatus = .enabled
            model.sharingConnections = [SharingConnection(id: UUID(), name: "Office Mac", isStreaming: true)]
            model.connectedClientCount = 1
            model.pairedComputers = [PairedComputer(id: "office", name: "Office Mac", fingerprint: "3F9A-12C0-77DE")]
            try save("hosting-active", HostingSetupView(model: model))
            try save("host-menu", HostMenuView(model: model))
            try save("settings-general", CirceSettingsView(model: model))
            try save("settings-sharing", CirceSettingsView(model: model, initialTab: .sharing))
            try save("settings-about", CirceSettingsView(model: model, initialTab: .about))
            let pairing = RemoteSession(name: "Studio Mac", address: "studio.local")
            pairing.phase = .pairing
            try save("pairing-code", PairingView(session: pairing).frame(width: 680, height: 520))
            pairing.allowsPIN = false; pairing.allowsPassword = true
            try save("pairing-account", PairingView(session: pairing).frame(width: 680, height: 520))
            let live = RemoteSession(name: "Studio Mac", address: "studio.local")
            live.remotePixelSize = .zero // Keep fixed preview dimensions.
            live.phase = .streaming; live.showAccessibilityHint = true
            try save("session-accessibility", SessionView(session: live).frame(width: 800, height: 520))
            live.phase = .streaming; live.showAccessibilityHint = false; live.isDraggingFiles = true
            try save("session-drop", SessionView(session: live).frame(width: 800, height: 520))
            live.phase = .streaming; live.isDraggingFiles = false; live.showStats = true
            live.fps = 60; live.latencyMs = 4.8; live.bitrateMbps = 42.4; live.roundTripMs = 1.2; live.transport = "UDP"; live.droppedFrames = 12
            try save("session-stats", SessionView(session: live).frame(width: 800, height: 520))
            live.transport = "IAP"; live.codec = "VNC (Tight/JPEG)"
            try save("session-stats-linux", SessionView(session: live).frame(width: 800, height: 520))
            let ended = RemoteSession(name: "Studio Mac", address: "studio.local")
            ended.phase = .disconnected("The remote Mac stopped responding. Check that it is awake and connected to the network.")
            try save("disconnected", SessionView(session: ended).frame(width: 800, height: 520))
        }
        print("Rendered light/dark UI previews in \(root.path)")
    }
}
