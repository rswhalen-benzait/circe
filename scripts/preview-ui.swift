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
            model.hosts = [NearbyMac(id: "studio", name: "Studio Mac", model: "Mac Studio", address: "studio.local"), NearbyMac(id: "laptop", name: "Developer’s MacBook Pro", model: "MacBookPro", address: "macbook.local")]
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
            // Guided Google Cloud setup, driven by canned engine answers.
            func cloudServices(tunnel: CloudReachability = .reachable, login: CloudLogin = .ok(user: "developer", uid: 1000), credential: CloudCredential = .valid,
                               report: CloudHostReport) -> CloudServices {
                CloudServices(isInstalled: { true }, install: { _, done in done(.success(())); return CloudCancel {} },
                    accounts: { $0(.success([CloudAccount(email: "developer@example.org", isActive: true), CloudAccount(email: "developer@work.example", isActive: false)])) },
                    credential: { _, done in done(.success(credential)) }, signIn: { a, _, _, done in done(.success(a)); return CloudCancel {} },
                    projects: { _, done in done(.success([CloudProject(id: "personal-lab", name: "Personal lab"), CloudProject(id: "team-workstations", name: "Team workstations"),
                                                         CloudProject(id: "sandbox-2291", name: "sandbox-2291")])) },
                    instances: { _, _, done in done(.success([
                        CloudInstance(instanceID: "1", name: "developer-omarchy", zone: "us-central1-a", status: "TERMINATED", machineType: "g2-standard-8", gpu: "NVIDIA L4", suggestedUsers: ["developer"], hostKeyAlias: "circe-gce-1"),
                        CloudInstance(instanceID: "2", name: "linux-workstation", zone: "us-east4-a", status: "RUNNING", machineType: "e2-standard-4", gpu: nil, suggestedUsers: [], hostKeyAlias: "circe-gce-2"),
                        CloudInstance(instanceID: "3", name: "build-runner", zone: "europe-west1-b", status: "RUNNING", machineType: "e2-small", gpu: nil, suggestedUsers: [], hostKeyAlias: "circe-gce-3")])) },
                    instance: { _, _, _, _, done in done(.failure(CloudError(.notFound, "not found"))) },
                    start: { _, _, _, progress, _ in progress("STAGING"); return CloudCancel {} },
                    checkTunnel: { _, _, _, done in done(.success(tunnel)) }, osLoginUser: { _, _, done in done(nil) }, pinHostKeys: { _, _, _, done in done(true) },
                    verifyLogin: { _, done in done(login) }, authorizeKey: { _, _, _, _, done in done(.success("developer")) },
                    probe: { _, done in done(.success(report)); return CloudCancel {} },
                    setUp: { _, _, _, output, _ in output("Installing XFCE and TigerVNC with apt…"); output("Starting the desktop…"); return CloudCancel {} },
                    localUserName: { "developer" })
            }
            let wayland = CloudHostReport(user: "developer", osName: "Omarchy", packageManager: "pacman", sudo: "password", adminGroup: true, systemd: true, circeInstalled: false,
                                          circeDisplay: nil, circeRunning: false, desktops: [CloudDesktop(display: 0, process: "wayvnc")], sessions: ["Hyprland", "wayvnc", "sunshine"])
            let ubuntu = CloudHostReport(user: "developer_example_org", osName: "Ubuntu 24.04.5 LTS", packageManager: "apt", sudo: "password", adminGroup: true, systemd: true,
                                         circeInstalled: false, circeDisplay: nil, circeRunning: false, desktops: [], sessions: ["gnome-shell", "xrdp", "chrome-remote-desktop"])
            var ubuntuNoAdmin = ubuntu; ubuntuNoAdmin.withoutAdmin = true; ubuntuNoAdmin.selfLinger = true
            let cloudModel = CirceModel(preferences: CircePreferences(defaults: defaults))
            func flow(_ services: CloudServices) -> GoogleCloudSetup { GoogleCloudSetup(services: services, model: cloudModel, suggestedEmail: "developer@example.org") }
            let signIn = flow(cloudServices(credential: .notSignedIn, report: wayland)); signIn.continueWithAccount()
            try save("cloud-account-sign-in", GoogleCloudSetupView(model: cloudModel, flow: signIn))
            let projects = flow(cloudServices(report: wayland)); projects.continueWithAccount()
            try save("cloud-projects", GoogleCloudSetupView(model: cloudModel, flow: projects))
            let computers = flow(cloudServices(report: wayland)); computers.continueWithAccount(); computers.choose(project: "personal-lab")
            try save("cloud-computers", GoogleCloudSetupView(model: cloudModel, flow: computers))
            let power = flow(cloudServices(report: wayland)); power.continueWithAccount(); power.choose(project: "personal-lab"); power.choose(power.instances[0])
            try save("cloud-start", GoogleCloudSetupView(model: cloudModel, flow: power))
            let key = flow(cloudServices(login: .keyRefused, report: wayland)); key.continueWithAccount(); key.choose(project: "personal-lab"); key.choose(key.instances[1])
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            try save("cloud-access-key", GoogleCloudSetupView(model: cloudModel, flow: key))
            let refused = flow(cloudServices(tunnel: .notAuthorized, report: wayland)); refused.continueWithAccount(); refused.choose(project: "team-workstations"); refused.choose(refused.instances[1])
            try save("cloud-access-refused", GoogleCloudSetupView(model: cloudModel, flow: refused))
            let existing = flow(cloudServices(report: wayland)); existing.continueWithAccount(); existing.choose(project: "personal-lab"); existing.choose(existing.instances[1])
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            try save("cloud-desktop-existing", GoogleCloudSetupView(model: cloudModel, flow: existing))
            let install = flow(cloudServices(login: .ok(user: "developer_example_org", uid: 1504), report: ubuntu)); install.continueWithAccount(); install.choose(project: "team-workstations"); install.choose(install.instances[1])
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            try save("cloud-desktop-install", GoogleCloudSetupView(model: cloudModel, flow: install))
            let noAdmin = flow(cloudServices(login: .ok(user: "developer_example_org", uid: 1504), report: ubuntuNoAdmin)); noAdmin.continueWithAccount(); noAdmin.choose(project: "team-workstations"); noAdmin.choose(noAdmin.instances[1])
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            try save("cloud-desktop-without-admin", GoogleCloudSetupView(model: cloudModel, flow: noAdmin))
            let stopped = RemoteSession(name: "developer-omarchy", address: "developer-omarchy · us-central1-a")
            stopped.notice = SessionNotice(title: "developer-omarchy is stopped", message: "It has an NVIDIA L4 GPU. Starting it begins Google Cloud charges until it’s stopped again — closing Circe doesn’t stop it.",
                                           actionTitle: "Start computer", action: {}, secondaryTitle: "Start, and don’t ask again", secondary: {})
            try save("session-cloud-stopped", SessionView(session: stopped).frame(width: 900, height: 560))
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
            live.videoControlsAvailable = true; live.videoMode = .h264(encoder: "x264"); live.fps = 28.4
            try save("session-linux-video-x264", SessionView(session: live).frame(width: 800, height: 520))
            live.videoMode = .h264(encoder: "nvenc"); live.fps = 59.7
            try save("session-linux-video-nvenc", SessionView(session: live).frame(width: 800, height: 520))
            let micSession = RemoteSession(name: "developer-omarchy", address: "developer-omarchy")
            micSession.remotePixelSize = .zero; micSession.phase = .streaming; micSession.microphoneAvailable = true
            try save("session-linux-mic-off", SessionView(session: micSession).frame(width: 800, height: 520))
            micSession.microphoneEnabled = true; micSession.microphoneActive = true
            try save("session-linux-mic-sending", SessionView(session: micSession).frame(width: 800, height: 520))
            live.videoMode = .starting; live.fps = 0
            try save("session-linux-video-starting", SessionView(session: live).frame(width: 800, height: 520))
            live.videoMode = .vnc; live.videoFallbackReason = "Smooth video isn’t installed on this computer. Run setup again to add it."; live.fps = 12
            try save("session-linux-video-fallback", SessionView(session: live).frame(width: 800, height: 520))
            let ended = RemoteSession(name: "Studio Mac", address: "studio.local")
            ended.phase = .disconnected("The remote Mac stopped responding. Check that it is awake and connected to the network.")
            try save("disconnected", SessionView(session: ended).frame(width: 800, height: 520))
        }
        print("Rendered light/dark UI previews in \(root.path)")
    }
}
