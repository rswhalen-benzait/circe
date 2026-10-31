import AppKit
import CirceUI
import OSLog
import SwiftUI

private let lifecycleLog = Logger(subsystem: "com.circe.desktop", category: "lifecycle")

@main
struct CirceApp: App {
    @NSApplicationDelegateAdaptor(CirceAppDelegate.self) private var appDelegate
    @StateObject private var runtime = CirceRuntime()

    init() { NSApplication.shared.setActivationPolicy(.regular); lifecycleLog.info("App initialized") }

    var body: some Scene {
        WindowGroup("Circe", id: "launcher") {
            LauncherView(model: runtime.model)
                .onAppear { lifecycleLog.info("Launcher appeared")
                    DispatchQueue.main.async { lifecycleLog.info("Visible app windows: \(NSApp.windows.filter { $0.isVisible }.count)") } }
        }
        .defaultSize(width: 640, height: 650)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { ShowLauncherButton() }
            CommandGroup(after: .toolbar) {
                Button("Toggle Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
                    .keyboardShortcut("f", modifiers: [.control, .option, .command])
                Button("Show Connection Stats") { NotificationCenter.default.post(name: .circeToggleStats, object: nil) }
                    .keyboardShortcut("s", modifiers: [.control, .option, .command])
                Divider()
                Button("Release Remote Input") { NotificationCenter.default.post(name: .circeReleaseInput, object: nil) }
                    .keyboardShortcut(.escape, modifiers: [.control, .option, .command])
                Button("Disconnect") { NotificationCenter.default.post(name: .circeDisconnectSession, object: nil) }
                    .keyboardShortcut("d", modifiers: [.control, .option, .command])
            }

        }

        WindowGroup(for: UUID.self) { $sessionID in
            if let id = sessionID, let session = runtime.model.sessions[id] {
                SessionView(session: session).onDisappear { runtime.model.closeSession(id) }
            } else {
                ContentUnavailableView("Session closed", systemImage: "rectangle.slash", description: Text("Open Circe to connect to a Mac."))
                    .frame(minWidth: 600, minHeight: 420)
            }
        }
        .defaultSize(width: 1280, height: 800)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("Circe", systemImage: runtime.model.isHosting ? "sparkles" : "moon") {
            HostMenuView(model: runtime.model)
        }.menuBarExtraStyle(.window)

        Settings { CirceSettingsView(model: runtime.model) }
    }
}

private struct ShowLauncherButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Show Circe") { if !CirceWindows.showLauncherIfOpen() { openWindow(id: "launcher") }; NSApp.activate(ignoringOtherApps: true) }
            .keyboardShortcut("n", modifiers: .command)
    }
}

@MainActor
final class CirceAppDelegate: NSObject, NSApplicationDelegate {
    private var finishedLaunching = false
    private func configureStartup() {
        CirceStartup.configure(sharingEnabled: UserDefaults.standard.bool(forKey: CircePreferences.sharingKey))
        NSApp.setActivationPolicy(CirceStartup.isQuietLaunch ? .accessory : .regular)
    }
    func applicationWillFinishLaunching(_ notification: Notification) { configureStartup() }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if finishedLaunching { return true }
        configureStartup()
        return !CirceStartup.isQuietLaunch
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStartup(); finishedLaunching = true
        if CirceStartup.isQuietLaunch {
            for window in NSApp.windows where window.identifier?.rawValue == "circe.launcher" { window.orderOut(nil) }
        } else { NSApp.activate(ignoringOtherApps: true) }
        lifecycleLog.info("Application launched; quiet: \(CirceStartup.isQuietLaunch)")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let hasMainWindow = sender.windows.contains { $0.isVisible && $0.canBecomeMain }
        if CirceStartup.isQuietLaunch || !hasMainWindow { _ = CirceWindows.showLauncherIfOpen() }
        return true
    }
}
